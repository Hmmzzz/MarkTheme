#import "MTThemeLibraryFilesystem.h"

#import <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/clonefile.h>
#import <sys/file.h>
#import <sys/mount.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTImportSession.h"

static NSString *const MTLibraryStoragePrefix = @"t-";
static NSString *const MTLibraryRevisionPrefix = @"r1-";
static NSString *const MTLibraryTransactionPrefix = @".transaction-";
static NSString *const MTLibraryDeletionPrefix = @".deletion-";
static NSString *const MTLibraryCurrentPartialPrefix = @".current-";

NSError *MTLibraryPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

NSError *MTLibraryError(MTThemeLibraryStoreErrorCode code,
                        NSString *description,
                        NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTThemeLibraryStoreErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL MTLibrarySetError(NSError **error,
                       MTThemeLibraryStoreErrorCode code,
                       NSString *description,
                       NSError *underlying) {
    if (error != NULL) *error = MTLibraryError(code, description, underlying);
    return NO;
}

static BOOL MTLibraryUUIDSuffixIsCanonical(NSString *name,
                                            NSString *prefix) {
    if (![name isKindOfClass:NSString.class] || ![name hasPrefix:prefix]) {
        return NO;
    }
    NSString *suffix = [name substringFromIndex:prefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

NSString *MTLibraryStorageIdentifierForThemeID(NSString *themeID) {
    NSString *normalized = MTNormalizeIdentifier(themeID, NULL);
    if (normalized == nil) return nil;
    NSString *digest = MTSHA256HexDigestForData(
        [normalized dataUsingEncoding:NSUTF8StringEncoding]);
    return [MTLibraryStoragePrefix stringByAppendingString:
        [digest substringToIndex:32]];
}

BOOL MTLibraryStorageIdentifierIsCanonical(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        identifier.length != MTLibraryStoragePrefix.length + 32 ||
        ![identifier hasPrefix:MTLibraryStoragePrefix]) {
        return NO;
    }
    NSString *suffix = [identifier substringFromIndex:MTLibraryStoragePrefix.length];
    for (NSUInteger index = 0; index < suffix.length; index++) {
        unichar character = [suffix characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return NO;
        }
    }
    return YES;
}

NSString *MTLibraryRevisionIdentifierForManifestDigest(
    NSString *manifestDigest) {
    return MTStringIsLowercaseSHA256Digest(manifestDigest)
        ? [MTLibraryRevisionPrefix stringByAppendingString:manifestDigest]
        : nil;
}

BOOL MTLibraryRevisionIdentifierIsCanonical(NSString *revisionIdentifier) {
    return [revisionIdentifier isKindOfClass:NSString.class] &&
        [revisionIdentifier hasPrefix:MTLibraryRevisionPrefix] &&
        MTStringIsLowercaseSHA256Digest(
            [revisionIdentifier substringFromIndex:MTLibraryRevisionPrefix.length]);
}

NSString *MTLibraryCreateTransactionName(void) {
    return [MTLibraryTransactionPrefix stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
}

BOOL MTLibraryTransactionNameIsCanonical(NSString *name) {
    return MTLibraryUUIDSuffixIsCanonical(name, MTLibraryTransactionPrefix);
}

NSString *MTLibraryCreateDeletionName(void) {
    return [MTLibraryDeletionPrefix stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
}

BOOL MTLibraryDeletionNameIsCanonical(NSString *name) {
    return MTLibraryUUIDSuffixIsCanonical(name, MTLibraryDeletionPrefix);
}

static BOOL MTLibraryStatIdentityMatches(const struct stat *left,
                                         const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static BOOL MTLibraryFileStatIsStable(const struct stat *before,
                                      const struct stat *after) {
    return MTLibraryStatIdentityMatches(before, after) &&
        before->st_mode == after->st_mode &&
        before->st_nlink == after->st_nlink &&
        before->st_uid == after->st_uid &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static BOOL MTLibraryValidatePrivateDirectory(int descriptor,
                                              struct stat *output,
                                              NSError **error) {
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0 || !S_ISDIR(status.st_mode) ||
        status.st_uid != geteuid() || fchmod(descriptor, 0700) != 0 ||
        fstat(descriptor, &status) != 0 || (status.st_mode & 0777) != 0700) {
        int savedError = errno;
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"A Library directory has an unsafe type, owner, or mode.",
            savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
    }
    if (output != NULL) *output = status;
    return YES;
}

static BOOL MTLibraryOpenOrCreatePrivateDirectoryAt(
    int parentDescriptor,
    NSString *name,
    BOOL create,
    int *outputDescriptor,
    struct stat *outputStatus,
    NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name containsString:@"/"]) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library directory name is invalid.", nil);
    }
    const char *fileName = name.fileSystemRepresentation;
    struct stat pathStatus = {0};
    BOOL created = NO;
    if (fstatat(parentDescriptor, fileName, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        int savedError = errno;
        if (!create && savedError == ENOENT) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorNotFound,
                @"The requested Library directory does not exist.", nil);
        }
        if (!create || savedError != ENOENT ||
            (mkdirat(parentDescriptor, fileName, 0700) != 0 &&
             errno != EEXIST)) {
            int finalError = savedError == ENOENT ? errno : savedError;
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to create a private Library directory.",
                MTLibraryPOSIXError(finalError));
        }
        created = YES;
        if (fstatat(parentDescriptor, fileName, &pathStatus,
                    AT_SYMLINK_NOFOLLOW) != 0) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to inspect a new Library directory.",
                MTLibraryPOSIXError(errno));
        }
    }
    if (!S_ISDIR(pathStatus.st_mode) || pathStatus.st_uid != geteuid()) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A Library path is not an app-owned directory.", nil);
    }
    int descriptor = openat(parentDescriptor, fileName,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat openedStatus = {0};
    if (descriptor < 0 ||
        !MTLibraryValidatePrivateDirectory(descriptor, &openedStatus, error) ||
        !MTLibraryStatIdentityMatches(&pathStatus, &openedStatus)) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        if (error == NULL || *error == nil) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"A Library directory changed while it was opened.",
                savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
        }
        return NO;
    }
    if (created && fsync(parentDescriptor) != 0) {
        int savedError = errno;
        close(descriptor);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to synchronize a new Library directory.",
            MTLibraryPOSIXError(savedError));
    }
    *outputDescriptor = descriptor;
    if (outputStatus != NULL) *outputStatus = openedStatus;
    return YES;
}

BOOL MTLibraryOpenPrivateDirectoryAt(int parentDescriptor,
                                     NSString *name,
                                     int *descriptor,
                                     NSError **error) {
    return MTLibraryOpenOrCreatePrivateDirectoryAt(parentDescriptor, name, NO,
                                                    descriptor, NULL, error);
}

BOOL MTLibraryCreatePrivateDirectoryAt(int parentDescriptor,
                                       NSString *name,
                                       int *descriptor,
                                       NSError **error) {
    return MTLibraryOpenOrCreatePrivateDirectoryAt(parentDescriptor, name, YES,
                                                    descriptor, NULL, error);
}

void MTLibraryRootDirectoriesInitialize(MTLibraryRootDirectories *directories) {
    memset(directories, 0, sizeof(*directories));
    directories->rootDescriptor = -1;
    directories->themesDescriptor = -1;
}

void MTLibraryRootDirectoriesClose(MTLibraryRootDirectories *directories) {
    if (directories->themesDescriptor >= 0) close(directories->themesDescriptor);
    if (directories->rootDescriptor >= 0) close(directories->rootDescriptor);
    MTLibraryRootDirectoriesInitialize(directories);
}

BOOL MTOpenLibraryRootDirectories(
    MTThemeLibraryConfiguration *configuration,
    BOOL createIfMissing,
    MTLibraryRootDirectories *directories,
    NSError **error) {
    MTLibraryRootDirectoriesInitialize(directories);
    if (![configuration isKindOfClass:MTThemeLibraryConfiguration.class]) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A valid Library configuration is required.", nil);
    }
    NSString *path = configuration.rootURL.path;
    if (!configuration.rootURL.isFileURL || path.length == 0 ||
        ![path isEqualToString:path.stringByStandardizingPath]) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"The Library root is not a canonical local path.", nil);
    }
    struct stat pathStatus = {0};
    if (lstat(path.fileSystemRepresentation, &pathStatus) != 0) {
        int savedError = errno;
        if (savedError == ENOENT && !createIfMissing) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorNotFound,
                @"The requested Library root does not exist.", nil);
        }
        NSError *createError = nil;
        if (savedError != ENOENT ||
            ![NSFileManager.defaultManager createDirectoryAtURL:
                    configuration.rootURL
                                     withIntermediateDirectories:YES
                                                      attributes:@{
                NSFilePosixPermissions : @0700
            } error:&createError]) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to create the private Library root.",
                createError ?: MTLibraryPOSIXError(savedError));
        }
    }
    int root = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (root < 0 ||
        !MTLibraryValidatePrivateDirectory(root, &directories->rootStatus,
                                           error)) {
        int savedError = errno;
        if (root >= 0) close(root);
        if (error == NULL || *error == nil) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to open the private Library root.",
                MTLibraryPOSIXError(savedError));
        }
        return NO;
    }
    directories->rootDescriptor = root;
    if (!MTLibraryOpenOrCreatePrivateDirectoryAt(root, @"themes",
            createIfMissing,
            &directories->themesDescriptor, &directories->themesStatus,
            error)) {
        MTLibraryRootDirectoriesClose(directories);
        return NO;
    }
    return YES;
}

void MTLibraryThemeDirectoriesInitialize(MTLibraryThemeDirectories *directories) {
    memset(directories, 0, sizeof(*directories));
    directories->rootDescriptor = -1;
    directories->themesDescriptor = -1;
    directories->themeDescriptor = -1;
    directories->revisionsDescriptor = -1;
}

void MTLibraryThemeDirectoriesClose(MTLibraryThemeDirectories *directories) {
    if (directories->revisionsDescriptor >= 0) {
        close(directories->revisionsDescriptor);
    }
    if (directories->themeDescriptor >= 0) close(directories->themeDescriptor);
    if (directories->themesDescriptor >= 0) close(directories->themesDescriptor);
    if (directories->rootDescriptor >= 0) close(directories->rootDescriptor);
    MTLibraryThemeDirectoriesInitialize(directories);
}

BOOL MTOpenLibraryThemeDirectories(
    MTThemeLibraryConfiguration *configuration,
    NSString *storageIdentifier,
    BOOL createIfMissing,
    MTLibraryThemeDirectories *directories,
    NSError **error) {
    MTLibraryThemeDirectoriesInitialize(directories);
    if (![configuration isKindOfClass:MTThemeLibraryConfiguration.class] ||
        !MTLibraryStorageIdentifierIsCanonical(storageIdentifier)) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A valid Library configuration and storage identifier are required.",
            nil);
    }
    MTLibraryRootDirectories rootDirectories;
    if (!MTOpenLibraryRootDirectories(configuration, createIfMissing,
                                      &rootDirectories, error)) {
        return NO;
    }
    directories->rootDescriptor = rootDirectories.rootDescriptor;
    directories->themesDescriptor = rootDirectories.themesDescriptor;
    directories->rootStatus = rootDirectories.rootStatus;
    directories->themesStatus = rootDirectories.themesStatus;
    rootDirectories.rootDescriptor = -1;
    rootDirectories.themesDescriptor = -1;
    if (!MTLibraryOpenOrCreatePrivateDirectoryAt(
            directories->themesDescriptor, storageIdentifier, createIfMissing,
            &directories->themeDescriptor, &directories->themeStatus,
            error) ||
        !MTLibraryOpenOrCreatePrivateDirectoryAt(
            directories->themeDescriptor, @"revisions", createIfMissing,
            &directories->revisionsDescriptor,
            &directories->revisionsStatus, error)) {
        MTLibraryThemeDirectoriesClose(directories);
        return NO;
    }
    return YES;
}

static BOOL MTLibraryDirectoryPathMatches(int parentDescriptor,
                                          const char *name,
                                          int openedDescriptor,
                                          const struct stat *baseline) {
    struct stat pathStatus = {0};
    struct stat openedStatus = {0};
    return fstatat(parentDescriptor, name, &pathStatus,
                   AT_SYMLINK_NOFOLLOW) == 0 &&
        fstat(openedDescriptor, &openedStatus) == 0 &&
        MTLibraryStatIdentityMatches(&pathStatus, &openedStatus) &&
        MTLibraryStatIdentityMatches(baseline, &openedStatus) &&
        S_ISDIR(openedStatus.st_mode) && openedStatus.st_uid == geteuid() &&
        (openedStatus.st_mode & 0777) == 0700;
}

BOOL MTLibraryRootDirectoriesAreStable(
    MTThemeLibraryConfiguration *configuration,
    MTLibraryRootDirectories *directories,
    NSError **error) {
    struct stat rootPath = {0};
    struct stat rootOpened = {0};
    BOOL stable =
        [configuration isKindOfClass:MTThemeLibraryConfiguration.class] &&
        lstat(configuration.rootURL.path.fileSystemRepresentation,
              &rootPath) == 0 &&
        fstat(directories->rootDescriptor, &rootOpened) == 0 &&
        MTLibraryStatIdentityMatches(&rootPath, &rootOpened) &&
        MTLibraryStatIdentityMatches(&directories->rootStatus, &rootOpened) &&
        S_ISDIR(rootOpened.st_mode) && rootOpened.st_uid == geteuid() &&
        (rootOpened.st_mode & 0777) == 0700 &&
        MTLibraryDirectoryPathMatches(directories->rootDescriptor, "themes",
            directories->themesDescriptor, &directories->themesStatus);
    return stable ? YES : MTLibrarySetError(error,
        MTThemeLibraryStoreErrorVerification,
        @"The Library root directory chain changed during inspection.", nil);
}

BOOL MTLibraryThemeDirectoriesAreStable(
    MTThemeLibraryConfiguration *configuration,
    MTLibraryThemeDirectories *directories,
    NSError **error) {
    NSString *themeName = nil;
    NSArray<NSString *> *themeEntries = nil;
    // The descriptor chain, not an untrusted path component, is authoritative.
    // Resolve the one canonical theme directory name only for the final
    // fstatat identity check.
    if (!MTLibraryListDirectoryNames(directories->themesDescriptor,
                                     &themeEntries, error)) {
        return NO;
    }
    for (NSString *entry in themeEntries) {
        struct stat candidate = {0};
        if (fstatat(directories->themesDescriptor,
                    entry.fileSystemRepresentation, &candidate,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            candidate.st_dev == directories->themeStatus.st_dev &&
            candidate.st_ino == directories->themeStatus.st_ino) {
            themeName = entry;
            break;
        }
    }
    MTLibraryRootDirectories rootDirectories = {
        .rootDescriptor = directories->rootDescriptor,
        .themesDescriptor = directories->themesDescriptor,
        .rootStatus = directories->rootStatus,
        .themesStatus = directories->themesStatus,
    };
    BOOL stable = MTLibraryRootDirectoriesAreStable(
            configuration, &rootDirectories, error) &&
        themeName != nil &&
        MTLibraryDirectoryPathMatches(directories->themesDescriptor,
            themeName.fileSystemRepresentation, directories->themeDescriptor,
            &directories->themeStatus) &&
        MTLibraryDirectoryPathMatches(directories->themeDescriptor, "revisions",
            directories->revisionsDescriptor,
            &directories->revisionsStatus);
    if (stable) return YES;
    if (error == NULL || *error == nil) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"The Library directory chain changed during the transaction.",
            nil);
    }
    return NO;
}

static int MTLibraryAcquireThemeLock(int themeDescriptor,
                                     int operation,
                                     NSString *busyDescription,
                                     NSError **error) {
    BOOL created = NO;
    int descriptor = openat(themeDescriptor, "transaction.lock",
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor >= 0) {
        created = YES;
    } else if (errno == EEXIST) {
        descriptor = openat(themeDescriptor, "transaction.lock",
            O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    }
    struct stat status = {0};
    if (descriptor < 0 || (created && fchmod(descriptor, 0600) != 0) ||
        fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_nlink != 1 || status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"The per-theme transaction lock is unsafe.",
            savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
        return -1;
    }
    if (created &&
        (fsync(descriptor) != 0 || fsync(themeDescriptor) != 0)) {
        int savedError = errno;
        close(descriptor);
        MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to synchronize the per-theme transaction lock.",
            MTLibraryPOSIXError(savedError));
        return -1;
    }
    if (flock(descriptor, operation | LOCK_NB) != 0) {
        int savedError = errno;
        close(descriptor);
        MTLibrarySetError(error,
            (savedError == EWOULDBLOCK || savedError == EAGAIN)
                ? MTThemeLibraryStoreErrorBusy
                : MTThemeLibraryStoreErrorStorage,
            busyDescription,
            MTLibraryPOSIXError(savedError));
        return -1;
    }
    return descriptor;
}

int MTLibraryAcquireThemeTransactionLock(int themeDescriptor,
                                         NSError **error) {
    return MTLibraryAcquireThemeLock(themeDescriptor, LOCK_EX,
        @"Another Library operation is changing this theme.", error);
}

int MTLibraryAcquireThemeReadLock(int themeDescriptor,
                                  NSError **error) {
    return MTLibraryAcquireThemeLock(themeDescriptor, LOCK_SH,
        @"Another Library operation is changing this theme.", error);
}

BOOL MTLibrarySynchronizeDirectoryDescriptor(int descriptor,
                                             NSError **error) {
    return fsync(descriptor) == 0 ? YES : MTLibrarySetError(error,
        MTThemeLibraryStoreErrorStorage,
        @"Unable to synchronize a Library directory.",
        MTLibraryPOSIXError(errno));
}

BOOL MTLibraryListDirectoryNames(int descriptor,
                                 NSArray<NSString *> **names,
                                 NSError **error) {
    // dup(2) shares the directory cursor with the original open file
    // description. Reopen "." relative to the trusted descriptor so repeated
    // and nested enumerations each receive an independent cursor.
    int enumerationDescriptor = openat(descriptor, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"Unable to enumerate a Library directory.",
            MTLibraryPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    BOOL success = YES;
    while (YES) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorVerification,
                    @"Library directory enumeration failed.",
                    MTLibraryPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        NSString *name = [[NSString alloc]
            initWithBytes:entry->d_name
                   length:strlen(entry->d_name)
                 encoding:NSUTF8StringEncoding];
        if (name == nil || name.length == 0 || [name containsString:@"/"]) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"A Library directory contains an invalid filename.", nil);
            break;
        }
        [result addObject:name];
    }
    closedir(directory);
    if (!success) return NO;
    *names = [result sortedArrayUsingSelector:@selector(compare:)];
    return YES;
}

static BOOL MTLibraryValidatePrivateFileStatus(const struct stat *status,
                                               uint64_t maximumBytes) {
    return S_ISREG(status->st_mode) && status->st_nlink == 1 &&
        status->st_uid == geteuid() && (status->st_mode & 0777) == 0600 &&
        status->st_size >= 0 && (uint64_t)status->st_size <= maximumBytes;
}

BOOL MTLibraryWriteDataExclusivelyAt(int directoryDescriptor,
                                     NSString *name,
                                     NSData *data,
                                     NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name containsString:@"/"] || ![data isKindOfClass:NSData.class]) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library file write request is invalid.", nil);
    }
    const char *fileName = name.fileSystemRepresentation;
    int descriptor = openat(directoryDescriptor, fileName,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to create a private Library file.",
            MTLibraryPOSIXError(errno));
    }
    BOOL success = fchmod(descriptor, 0600) == 0;
    NSUInteger offset = 0;
    while (success && offset < data.length) {
        ssize_t count = write(descriptor,
            (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            success = NO;
            break;
        }
        offset += (NSUInteger)count;
    }
    struct stat status = {0};
    if (success) success = fsync(descriptor) == 0;
    if (success) {
        success = fstat(descriptor, &status) == 0 &&
            MTLibraryValidatePrivateFileStatus(&status, data.length) &&
            (uint64_t)status.st_size == data.length;
    }
    int savedError = errno;
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        unlinkat(directoryDescriptor, fileName, 0);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to durably write a private Library file.",
            savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
    }
    return YES;
}

NSData *MTLibraryReadPrivateFileAt(int directoryDescriptor,
                                   NSString *name,
                                   uint64_t maximumBytes,
                                   NSError **error) {
    if (maximumBytes == 0 || ![name isKindOfClass:NSString.class] ||
        name.length == 0 || [name containsString:@"/"]) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library file read request is invalid.", nil);
        return nil;
    }
    int descriptor = openat(directoryDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        MTLibrarySetError(error,
            errno == ENOENT ? MTThemeLibraryStoreErrorNotFound
                            : MTThemeLibraryStoreErrorStorage,
            @"Unable to open a private Library file.",
            MTLibraryPOSIXError(errno));
        return nil;
    }
    struct stat before = {0};
    if (fstat(descriptor, &before) != 0 ||
        !MTLibraryValidatePrivateFileStatus(&before, maximumBytes)) {
        close(descriptor);
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A Library file has an unsafe type, owner, mode, link count, or size.",
            nil);
        return nil;
    }
    NSMutableData *data = [NSMutableData
        dataWithLength:(NSUInteger)(uint64_t)before.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor,
            (unsigned char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedError = count == 0 ? EIO : errno;
            close(descriptor);
            MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to read a complete Library file.",
                MTLibraryPOSIXError(savedError));
            return nil;
        }
        offset += (NSUInteger)count;
    }
    unsigned char extra = 0;
    ssize_t extraCount;
    do {
        extraCount = read(descriptor, &extra, 1);
    } while (extraCount < 0 && errno == EINTR);
    struct stat after = {0};
    BOOL stable = extraCount == 0 && fstat(descriptor, &after) == 0 &&
        MTLibraryFileStatIsStable(&before, &after);
    close(descriptor);
    if (!stable) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A Library file changed while it was read.", nil);
        return nil;
    }
    return [data copy];
}

BOOL MTLibraryReplaceCurrentData(int themeDescriptor,
                                 NSData *data,
                                 NSError **error) {
    NSString *temporaryName = [MTLibraryCurrentPartialPrefix
        stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    if (!MTLibraryWriteDataExclusivelyAt(themeDescriptor, temporaryName,
                                         data, error)) {
        return NO;
    }
    struct stat currentStatus = {0};
    int currentResult = fstatat(themeDescriptor, "current.json",
                                &currentStatus, AT_SYMLINK_NOFOLLOW);
    int currentError = errno;
    if (currentResult == 0 &&
        !MTLibraryValidatePrivateFileStatus(&currentStatus, 4096)) {
        unlinkat(themeDescriptor, temporaryName.fileSystemRepresentation, 0);
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The current revision pointer is not a private regular file.", nil);
    }
    if (currentResult != 0 && currentError != ENOENT) {
        unlinkat(themeDescriptor, temporaryName.fileSystemRepresentation, 0);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to inspect the current revision pointer.",
            MTLibraryPOSIXError(currentError));
    }
    if (renameat(themeDescriptor, temporaryName.fileSystemRepresentation,
                 themeDescriptor, "current.json") != 0) {
        int savedError = errno;
        unlinkat(themeDescriptor, temporaryName.fileSystemRepresentation, 0);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to atomically replace the current revision pointer.",
            MTLibraryPOSIXError(savedError));
    }
    return MTLibrarySynchronizeDirectoryDescriptor(themeDescriptor, error);
}

BOOL MTLibraryCheckAvailableSpace(int descriptor,
                                  uint64_t requiredBytes,
                                  uint64_t reserveBytes,
                                  NSError **error) {
    struct statfs storage = {0};
    if (fstatfs(descriptor, &storage) != 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to inspect available Library storage.",
            MTLibraryPOSIXError(errno));
    }
    uint64_t blocks = (uint64_t)storage.f_bavail;
    uint64_t blockSize = (uint64_t)storage.f_bsize;
    uint64_t available = blockSize != 0 && blocks > UINT64_MAX / blockSize
        ? UINT64_MAX : blocks * blockSize;
    if (reserveBytes > available || requiredBytes > available - reserveBytes) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInsufficientSpace,
            @"Insufficient private storage is available for the complete revision and reserve.",
            nil);
    }
    return YES;
}

static NSString *MTLibraryHexDigest(const unsigned char *bytes) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(bytes[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

static NSString *MTLibraryHashDescriptor(
    int descriptor,
    uint64_t maximumBytes,
    MTImportCancellationToken *token,
    uint64_t *bytesRead,
    NSError **error) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to seek a Library asset for hashing.",
            MTLibraryPOSIXError(errno));
        return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    while (YES) {
        if (token.isCancelled) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
                @"Library asset verification was cancelled.", nil);
            return nil;
        }
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to read a Library asset for hashing.",
                MTLibraryPOSIXError(errno));
            return nil;
        }
        if (count == 0) break;
        if ((uint64_t)count > maximumBytes - total) {
            MTLibrarySetError(error,
                MTThemeLibraryStoreErrorVerification,
                @"A Library asset exceeds its declared byte count.", nil);
            return nil;
        }
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    if (bytesRead != NULL) *bytesRead = total;
    return MTLibraryHexDigest(digest);
}

static BOOL MTLibraryWriteAll(int descriptor,
                              const void *bytes,
                              size_t length,
                              NSError **error) {
    const unsigned char *cursor = bytes;
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(descriptor, cursor + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                @"Unable to write a Library asset.",
                MTLibraryPOSIXError(count == 0 ? EIO : errno));
        }
        offset += (size_t)count;
    }
    return YES;
}

static BOOL MTLibraryCloneFailureAllowsStreamingFallback(int value) {
    return value == EXDEV || value == ENOTSUP || value == EINVAL ||
        value == ENOSYS || value == EPERM;
}

BOOL MTLibraryCopyVerifiedAsset(int sourceDirectoryDescriptor,
                                int destinationDirectoryDescriptor,
                                NSString *digest,
                                uint64_t expectedBytes,
                                MTImportCancellationToken *token,
                                BOOL *usedCloneFastPath,
                                NSError **error) {
    if (!MTStringIsLowercaseSHA256Digest(digest) || expectedBytes == 0) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library asset copy request is invalid.", nil);
    }
    if (token.isCancelled) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorCancelled,
            @"Library asset adoption was cancelled before copying.", nil);
    }
    const char *name = digest.fileSystemRepresentation;
    int source = openat(sourceDirectoryDescriptor, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat sourceBefore = {0};
    if (source < 0 || fstat(source, &sourceBefore) != 0 ||
        !MTLibraryValidatePrivateFileStatus(&sourceBefore, expectedBytes) ||
        (uint64_t)sourceBefore.st_size != expectedBytes) {
        int savedError = errno;
        if (source >= 0) close(source);
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"A provisional asset is not a stable private digest object.",
            savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
    }

    BOOL cloned = clonefileat(sourceDirectoryDescriptor, name,
        destinationDirectoryDescriptor, name,
        CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0;
    int cloneError = cloned ? 0 : errno;
    int destination = -1;
    BOOL success = YES;
    NSString *sourceDigest = nil;
    uint64_t sourceBytes = 0;
    if (cloned) {
        destination = openat(destinationDirectoryDescriptor, name,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (destination < 0 || fchmod(destination, 0600) != 0 ||
            fsync(destination) != 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to protect or synchronize a cloned Library asset.",
                MTLibraryPOSIXError(errno));
        }
        if (success) {
            sourceDigest = MTLibraryHashDescriptor(source, expectedBytes,
                token, &sourceBytes, error);
            success = sourceDigest != nil;
        }
    } else if (MTLibraryCloneFailureAllowsStreamingFallback(cloneError)) {
        unlinkat(destinationDirectoryDescriptor, name, 0);
        destination = openat(destinationDirectoryDescriptor, name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (destination < 0 || fchmod(destination, 0600) != 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to create the streamed Library asset destination.",
                MTLibraryPOSIXError(errno));
        }
        if (success && lseek(source, 0, SEEK_SET) < 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorStorage,
                @"Unable to seek the provisional asset for copying.",
                MTLibraryPOSIXError(errno));
        }
        CC_SHA256_CTX context;
        CC_SHA256_Init(&context);
        unsigned char buffer[64 * 1024];
        while (success) {
            if (token.isCancelled) {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorCancelled,
                    @"Library asset adoption was cancelled while copying.", nil);
                break;
            }
            ssize_t count = read(source, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorStorage,
                    @"Unable to read the provisional asset while copying.",
                    MTLibraryPOSIXError(errno));
                break;
            }
            if (count == 0) break;
            if ((uint64_t)count > expectedBytes - sourceBytes) {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorVerification,
                    @"The provisional asset grew while copying.", nil);
                break;
            }
            if (!MTLibraryWriteAll(destination, buffer, (size_t)count,
                                   error)) {
                success = NO;
                break;
            }
            sourceBytes += (uint64_t)count;
            CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        }
        if (success) {
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(hash, &context);
            sourceDigest = MTLibraryHexDigest(hash);
            success = fsync(destination) == 0;
            if (!success) {
                MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
                    @"Unable to synchronize a streamed Library asset.",
                    MTLibraryPOSIXError(errno));
            }
        }
    } else {
        success = MTLibrarySetError(error,
            MTThemeLibraryStoreErrorStorage,
            @"Unable to clone the provisional asset into the Library.",
            MTLibraryPOSIXError(cloneError));
    }

    struct stat sourceAfter = {0};
    struct stat sourcePath = {0};
    if (success) {
        success = sourceBytes == expectedBytes &&
            [sourceDigest isEqualToString:digest] &&
            fstat(source, &sourceAfter) == 0 &&
            MTLibraryFileStatIsStable(&sourceBefore, &sourceAfter) &&
            fstatat(sourceDirectoryDescriptor, name, &sourcePath,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            MTLibraryStatIdentityMatches(&sourceAfter, &sourcePath);
        if (!success) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The provisional asset changed or failed its digest while being adopted.",
                nil);
        }
    }

    struct stat destinationBefore = {0};
    if (success) {
        success = destination >= 0 &&
            fstat(destination, &destinationBefore) == 0 &&
            MTLibraryValidatePrivateFileStatus(&destinationBefore,
                                               expectedBytes) &&
            (uint64_t)destinationBefore.st_size == expectedBytes;
        if (!success) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The adopted Library asset failed its destination metadata check.",
                nil);
        }
    }
    uint64_t destinationBytes = 0;
    NSString *destinationDigest = success
        ? MTLibraryHashDescriptor(destination, expectedBytes, token,
                                  &destinationBytes, error)
        : nil;
    struct stat destinationAfter = {0};
    struct stat destinationPath = {0};
    if (success) {
        success = destinationDigest != nil &&
            destinationBytes == expectedBytes &&
            [destinationDigest isEqualToString:digest] &&
            fstat(destination, &destinationAfter) == 0 &&
            MTLibraryFileStatIsStable(&destinationBefore, &destinationAfter) &&
            fstatat(destinationDirectoryDescriptor, name, &destinationPath,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            MTLibraryStatIdentityMatches(&destinationAfter, &destinationPath);
        if (!success && (error == NULL || *error == nil)) {
            MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
                @"The independently read Library destination failed its digest or stability check.",
                nil);
        }
    }
    close(source);
    if (destination >= 0) close(destination);
    if (!success) {
        unlinkat(destinationDirectoryDescriptor, name, 0);
        return NO;
    }
    if (usedCloneFastPath != NULL) *usedCloneFastPath = cloned;
    return YES;
}

static int MTLibraryOpenAssetForInspection(int directoryDescriptor,
                                           NSString *digest,
                                           uint64_t expectedBytes,
                                           struct stat *status,
                                           NSError **error) {
    if (!MTStringIsLowercaseSHA256Digest(digest) || expectedBytes == 0) {
        MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library asset verification request is invalid.", nil);
        return -1;
    }
    const char *name = digest.fileSystemRepresentation;
    int descriptor = openat(directoryDescriptor, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat before = {0};
    if (descriptor < 0 || fstat(descriptor, &before) != 0 ||
        !MTLibraryValidatePrivateFileStatus(&before, expectedBytes) ||
        (uint64_t)before.st_size != expectedBytes) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"A revision asset failed its private-file metadata check.",
            savedError == 0 ? nil : MTLibraryPOSIXError(savedError));
        return -1;
    }
    struct stat pathStatus = {0};
    if (fstatat(directoryDescriptor, name, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTLibraryStatIdentityMatches(&before, &pathStatus)) {
        close(descriptor);
        MTLibrarySetError(error, MTThemeLibraryStoreErrorVerification,
            @"A revision asset changed while its metadata was inspected.",
            nil);
        return -1;
    }
    if (status != NULL) *status = before;
    return descriptor;
}

BOOL MTLibraryInspectAssetMetadata(int directoryDescriptor,
                                   NSString *digest,
                                   uint64_t expectedBytes,
                                   NSError **error) {
    struct stat before = {0};
    int descriptor = MTLibraryOpenAssetForInspection(directoryDescriptor,
        digest, expectedBytes, &before, error);
    if (descriptor < 0) return NO;
    struct stat after = {0};
    struct stat pathStatus = {0};
    BOOL success = fstat(descriptor, &after) == 0 &&
        MTLibraryFileStatIsStable(&before, &after) &&
        fstatat(directoryDescriptor, digest.fileSystemRepresentation,
                &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTLibraryStatIdentityMatches(&after, &pathStatus);
    close(descriptor);
    return success ? YES : MTLibrarySetError(error,
        MTThemeLibraryStoreErrorVerification,
        @"A revision asset changed during metadata-only inspection.", nil);
}

BOOL MTLibraryVerifyAsset(int directoryDescriptor,
                          NSString *digest,
                          uint64_t expectedBytes,
                          MTImportCancellationToken *token,
                          NSError **error) {
    const char *name = digest.fileSystemRepresentation;
    struct stat before = {0};
    int descriptor = MTLibraryOpenAssetForInspection(directoryDescriptor,
        digest, expectedBytes, &before, error);
    if (descriptor < 0) return NO;
    uint64_t bytes = 0;
    NSString *actual = MTLibraryHashDescriptor(descriptor, expectedBytes,
                                               token, &bytes, error);
    struct stat after = {0};
    struct stat pathStatus = {0};
    BOOL success = actual != nil && bytes == expectedBytes &&
        [actual isEqualToString:digest] && fstat(descriptor, &after) == 0 &&
        MTLibraryFileStatIsStable(&before, &after) &&
        fstatat(directoryDescriptor, name, &pathStatus,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        MTLibraryStatIdentityMatches(&after, &pathStatus);
    close(descriptor);
    return success ? YES : MTLibrarySetError(error,
        MTThemeLibraryStoreErrorVerification,
        @"A revision asset failed its complete digest or stability check.", nil);
}

BOOL MTLibraryCreateTransactionDirectories(int revisionsDescriptor,
                                           NSString *transactionName,
                                           int *transactionDescriptor,
                                           int *assetsDescriptor,
                                           NSError **error) {
    if (!MTLibraryTransactionNameIsCanonical(transactionName) ||
        mkdirat(revisionsDescriptor,
                transactionName.fileSystemRepresentation, 0700) != 0) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorStorage,
            @"Unable to create a unique Library transaction directory.",
            MTLibraryPOSIXError(errno));
    }
    int transaction = -1;
    int assets = -1;
    BOOL success = MTLibraryOpenPrivateDirectoryAt(revisionsDescriptor,
        transactionName, &transaction, error) &&
        MTLibraryCreatePrivateDirectoryAt(transaction, @"assets", &assets,
                                           error) &&
        MTLibrarySynchronizeDirectoryDescriptor(transaction, error) &&
        MTLibrarySynchronizeDirectoryDescriptor(revisionsDescriptor, error);
    if (!success) {
        if (assets >= 0) close(assets);
        if (transaction >= 0) close(transaction);
        MTLibraryDiscardTransaction(revisionsDescriptor, transactionName, NULL);
        return NO;
    }
    *transactionDescriptor = transaction;
    *assetsDescriptor = assets;
    return YES;
}

static BOOL MTLibraryValidateCleanupFile(int descriptor,
                                         NSString *name,
                                         NSError **error) {
    struct stat status = {0};
    if (fstatat(descriptor, name.fileSystemRepresentation, &status,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTLibraryValidatePrivateFileStatus(&status, UINT64_MAX)) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"A Library recovery directory contains an unsafe file.", nil);
    }
    return YES;
}

static BOOL MTLibraryDiscardRecoveryDirectory(
    int revisionsDescriptor,
    NSString *directoryName,
    BOOL isDeletion,
    NSError **error) {
    BOOL canonical = isDeletion
        ? MTLibraryDeletionNameIsCanonical(directoryName)
        : MTLibraryTransactionNameIsCanonical(directoryName);
    if (!canonical) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Refusing to clean a non-canonical Library recovery directory.",
            nil);
    }
    struct stat pathStatus = {0};
    if (fstatat(revisionsDescriptor,
                directoryName.fileSystemRepresentation, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT ? YES : MTLibrarySetError(error,
            MTThemeLibraryStoreErrorRecovery,
            @"Unable to inspect a Library recovery directory.",
            MTLibraryPOSIXError(errno));
    }
    int recoveryDirectory = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(revisionsDescriptor, directoryName,
                                         &recoveryDirectory, error)) {
        return NO;
    }
    struct stat openedStatus = {0};
    if (fstat(recoveryDirectory, &openedStatus) != 0 ||
        !MTLibraryStatIdentityMatches(&pathStatus, &openedStatus)) {
        close(recoveryDirectory);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"A Library recovery directory changed before cleanup.", nil);
    }
    NSArray<NSString *> *entries = nil;
    BOOL success = MTLibraryListDirectoryNames(recoveryDirectory, &entries,
                                               error);
    NSSet<NSString *> *allowed = [NSSet setWithArray:
        @[@"assets", @"manifest.json", @"revision.json"]];
    for (NSString *entry in entries) {
        if (![allowed containsObject:entry]) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Refusing to delete a Library recovery directory with an unknown entry.",
                nil);
            break;
        }
    }
    int assets = -1;
    if (success && [entries containsObject:@"assets"]) {
        success = MTLibraryOpenPrivateDirectoryAt(recoveryDirectory, @"assets",
                                                  &assets, error);
    }
    NSArray<NSString *> *assetNames = nil;
    if (success && assets >= 0) {
        success = MTLibraryListDirectoryNames(assets, &assetNames, error);
        for (NSString *name in assetNames) {
            if (!MTStringIsLowercaseSHA256Digest(name) ||
                !MTLibraryValidateCleanupFile(assets, name, error)) {
                if (error == NULL || *error == nil) {
                    MTLibrarySetError(error,
                        MTThemeLibraryStoreErrorRecovery,
                        @"Refusing to delete an unknown recovery asset.", nil);
                }
                success = NO;
                break;
            }
        }
    }
    for (NSString *fileName in @[@"manifest.json", @"revision.json"]) {
        if (success && [entries containsObject:fileName]) {
            success = MTLibraryValidateCleanupFile(recoveryDirectory, fileName,
                                                   error);
        }
    }
    if (assets >= 0) {
        if (success) {
            for (NSString *name in assetNames) {
                if (unlinkat(assets, name.fileSystemRepresentation, 0) != 0) {
                    success = MTLibrarySetError(error,
                        MTThemeLibraryStoreErrorRecovery,
                        @"Unable to remove a Library recovery asset.",
                        MTLibraryPOSIXError(errno));
                    break;
                }
            }
        }
        if (success) {
            success = MTLibrarySynchronizeDirectoryDescriptor(assets, error);
        }
        close(assets);
        assets = -1;
        if (success && unlinkat(recoveryDirectory, "assets", AT_REMOVEDIR) != 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Unable to remove a Library recovery asset directory.",
                MTLibraryPOSIXError(errno));
        }
    }
    if (success) {
        for (NSString *fileName in @[@"manifest.json", @"revision.json"]) {
            if ([entries containsObject:fileName] &&
                unlinkat(recoveryDirectory,
                         fileName.fileSystemRepresentation, 0) != 0) {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorRecovery,
                    @"Unable to remove Library recovery metadata.",
                    MTLibraryPOSIXError(errno));
                break;
            }
        }
    }
    if (success) {
        success = MTLibrarySynchronizeDirectoryDescriptor(recoveryDirectory,
                                                          error);
    }
    close(recoveryDirectory);
    if (success && unlinkat(revisionsDescriptor,
            directoryName.fileSystemRepresentation, AT_REMOVEDIR) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Unable to remove a Library recovery directory.",
            MTLibraryPOSIXError(errno));
    }
    if (success) {
        success = MTLibrarySynchronizeDirectoryDescriptor(revisionsDescriptor,
                                                          error);
    }
    return success;
}

BOOL MTLibraryDiscardTransaction(int revisionsDescriptor,
                                 NSString *transactionName,
                                 NSError **error) {
    return MTLibraryDiscardRecoveryDirectory(revisionsDescriptor,
        transactionName, NO, error);
}

BOOL MTLibraryQuarantineRevisionForDeletion(
    int revisionsDescriptor,
    NSString *revisionIdentifier,
    NSString *deletionName,
    NSError **error) {
    if (!MTLibraryRevisionIdentifierIsCanonical(revisionIdentifier) ||
        !MTLibraryDeletionNameIsCanonical(deletionName)) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library deletion rename request is invalid.", nil);
    }
    struct stat sourceStatus = {0};
    if (fstatat(revisionsDescriptor,
                revisionIdentifier.fileSystemRepresentation, &sourceStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return MTLibrarySetError(error,
            errno == ENOENT ? MTThemeLibraryStoreErrorNotFound
                            : MTThemeLibraryStoreErrorStorage,
            @"Unable to inspect the revision selected for deletion.",
            MTLibraryPOSIXError(errno));
    }
    if (!S_ISDIR(sourceStatus.st_mode) || sourceStatus.st_uid != geteuid() ||
        (sourceStatus.st_mode & 0777) != 0700) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The revision selected for deletion is not a private directory.",
            nil);
    }
    if (renameatx_np(revisionsDescriptor,
            revisionIdentifier.fileSystemRepresentation,
            revisionsDescriptor, deletionName.fileSystemRepresentation,
            RENAME_EXCL) != 0) {
        int savedError = errno;
        return MTLibrarySetError(error,
            savedError == ENOENT ? MTThemeLibraryStoreErrorNotFound
                                 : MTThemeLibraryStoreErrorStorage,
            @"Unable to atomically quarantine the revision for deletion.",
            MTLibraryPOSIXError(savedError));
    }
    struct stat quarantinedStatus = {0};
    if (fstatat(revisionsDescriptor, deletionName.fileSystemRepresentation,
                &quarantinedStatus, AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTLibraryStatIdentityMatches(&sourceStatus, &quarantinedStatus)) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The quarantined revision changed identity after its deletion rename.",
            nil);
    }
    return MTLibrarySynchronizeDirectoryDescriptor(revisionsDescriptor, error);
}

BOOL MTLibraryDiscardDeletion(int revisionsDescriptor,
                              NSString *deletionName,
                              NSError **error) {
    return MTLibraryDiscardRecoveryDirectory(revisionsDescriptor,
        deletionName, YES, error);
}

// A compatibility-only revision directory holds a manifest and nothing else.
// Validate that shape before removing it, so an unexpected tree is reported
// rather than deleted.
static BOOL MTLibraryDiscardLegacyRevision(int revisionsDescriptor,
                                           NSString *revisionName,
                                           NSError **error) {
    int revisionDirectory = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(revisionsDescriptor, revisionName,
                                         &revisionDirectory, error)) {
        return NO;
    }
    NSArray<NSString *> *entries = nil;
    BOOL success = MTLibraryListDirectoryNames(revisionDirectory, &entries,
                                               error);
    for (NSString *entry in entries) {
        if (success && (![entry isEqualToString:@"manifest.json"] ||
                        !MTLibraryValidateCleanupFile(revisionDirectory, entry,
                                                      error))) {
            if (error == NULL || *error == nil) {
                MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
                    @"Refusing to delete an unknown legacy revision entry.",
                    nil);
            }
            success = NO;
        }
    }
    if (success && [entries containsObject:@"manifest.json"] &&
        unlinkat(revisionDirectory, "manifest.json", 0) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Unable to remove a legacy Library manifest.",
            MTLibraryPOSIXError(errno));
    }
    if (success) {
        success = MTLibrarySynchronizeDirectoryDescriptor(revisionDirectory,
                                                          error);
    }
    close(revisionDirectory);
    if (success && unlinkat(revisionsDescriptor,
            revisionName.fileSystemRepresentation, AT_REMOVEDIR) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Unable to remove a legacy Library revision directory.",
            MTLibraryPOSIXError(errno));
    }
    return success;
}

BOOL MTLibraryQuarantineThemeForDeletion(int themesDescriptor,
                                         NSString *storageIdentifier,
                                         NSString *deletionName,
                                         NSError **error) {
    if (!MTLibraryStorageIdentifierIsCanonical(storageIdentifier) ||
        !MTLibraryDeletionNameIsCanonical(deletionName)) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorInvalidRequest,
            @"A Library theme deletion rename request is invalid.", nil);
    }
    struct stat sourceStatus = {0};
    if (fstatat(themesDescriptor,
                storageIdentifier.fileSystemRepresentation, &sourceStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return MTLibrarySetError(error,
            errno == ENOENT ? MTThemeLibraryStoreErrorNotFound
                            : MTThemeLibraryStoreErrorStorage,
            @"Unable to inspect the theme selected for deletion.",
            MTLibraryPOSIXError(errno));
    }
    if (!S_ISDIR(sourceStatus.st_mode) || sourceStatus.st_uid != geteuid() ||
        (sourceStatus.st_mode & 0777) != 0700) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The theme selected for deletion is not a private directory.",
            nil);
    }
    if (renameatx_np(themesDescriptor,
            storageIdentifier.fileSystemRepresentation,
            themesDescriptor, deletionName.fileSystemRepresentation,
            RENAME_EXCL) != 0) {
        int savedError = errno;
        return MTLibrarySetError(error,
            savedError == ENOENT ? MTThemeLibraryStoreErrorNotFound
                                 : MTThemeLibraryStoreErrorStorage,
            @"Unable to atomically quarantine the theme for deletion.",
            MTLibraryPOSIXError(savedError));
    }
    struct stat quarantinedStatus = {0};
    if (fstatat(themesDescriptor, deletionName.fileSystemRepresentation,
                &quarantinedStatus, AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTLibraryStatIdentityMatches(&sourceStatus, &quarantinedStatus)) {
        return MTLibrarySetError(error,
            MTThemeLibraryStoreErrorVerification,
            @"The quarantined theme changed identity after its deletion rename.",
            nil);
    }
    return MTLibrarySynchronizeDirectoryDescriptor(themesDescriptor, error);
}

BOOL MTLibraryDiscardThemeDeletion(int themesDescriptor,
                                   NSString *deletionName,
                                   NSError **error) {
    if (!MTLibraryDeletionNameIsCanonical(deletionName)) {
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Refusing to clean a non-canonical Library theme deletion.", nil);
    }
    struct stat pathStatus = {0};
    if (fstatat(themesDescriptor, deletionName.fileSystemRepresentation,
                &pathStatus, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT ? YES : MTLibrarySetError(error,
            MTThemeLibraryStoreErrorRecovery,
            @"Unable to inspect a quarantined Library theme.",
            MTLibraryPOSIXError(errno));
    }
    int themeDirectory = -1;
    if (!MTLibraryOpenPrivateDirectoryAt(themesDescriptor, deletionName,
                                         &themeDirectory, error)) {
        return NO;
    }
    struct stat openedStatus = {0};
    if (fstat(themeDirectory, &openedStatus) != 0 ||
        !MTLibraryStatIdentityMatches(&pathStatus, &openedStatus)) {
        close(themeDirectory);
        return MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"A quarantined Library theme changed before cleanup.", nil);
    }

    // A quarantined theme holds only the exact top-level entries the Library
    // creates. Every revision below it is discarded through the same
    // revision-shaped cleanup used for single-revision deletion.
    NSArray<NSString *> *entries = nil;
    BOOL success = MTLibraryListDirectoryNames(themeDirectory, &entries, error);
    NSSet<NSString *> *allowed = [NSSet setWithArray:
        @[@"current.json", @"revisions", @"transaction.lock"]];
    for (NSString *entry in entries) {
        if (success && ![allowed containsObject:entry]) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Refusing to delete a quarantined theme with an unknown entry.",
                nil);
        }
    }
    int revisions = -1;
    if (success && [entries containsObject:@"revisions"]) {
        success = MTLibraryOpenPrivateDirectoryAt(themeDirectory, @"revisions",
                                                  &revisions, error);
    }
    if (success && revisions >= 0) {
        NSArray<NSString *> *revisionNames = nil;
        success = MTLibraryListDirectoryNames(revisions, &revisionNames, error);
        for (NSString *name in revisionNames) {
            if (!success) break;
            // Reuse the revision cleanup contract: published revisions are
            // renamed into a deletion name first, and recovery leftovers are
            // already in one.
            if (MTLibraryRevisionIdentifierIsCanonical(name)) {
                NSString *deletion = MTLibraryCreateDeletionName();
                success = MTLibraryQuarantineRevisionForDeletion(revisions,
                    name, deletion, error) &&
                    MTLibraryDiscardDeletion(revisions, deletion, error);
            } else if (MTStringIsLowercaseSHA256Digest(name)) {
                // Compatibility-only manifest revisions are stored under a
                // bare digest. Per-revision garbage collection leaves them
                // alone, but deleting the whole theme must take them too.
                success = MTLibraryDiscardLegacyRevision(revisions, name,
                                                         error);
            } else if (MTLibraryDeletionNameIsCanonical(name)) {
                success = MTLibraryDiscardDeletion(revisions, name, error);
            } else if (MTLibraryTransactionNameIsCanonical(name)) {
                success = MTLibraryDiscardTransaction(revisions, name, error);
            } else {
                success = MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorRecovery,
                    @"Refusing to delete an unknown Library revision entry.",
                    nil);
            }
        }
        if (success) {
            success = MTLibrarySynchronizeDirectoryDescriptor(revisions, error);
        }
    }
    if (revisions >= 0) close(revisions);
    if (success && [entries containsObject:@"revisions"] &&
        unlinkat(themeDirectory, "revisions", AT_REMOVEDIR) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Unable to remove a quarantined theme revisions directory.",
            MTLibraryPOSIXError(errno));
    }
    for (NSString *fileName in @[@"current.json", @"transaction.lock"]) {
        if (success && [entries containsObject:fileName] &&
            !MTLibraryValidateCleanupFile(themeDirectory, fileName, error)) {
            success = NO;
        }
    }
    for (NSString *fileName in @[@"current.json", @"transaction.lock"]) {
        if (success && [entries containsObject:fileName] &&
            unlinkat(themeDirectory, fileName.fileSystemRepresentation,
                     0) != 0) {
            success = MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Unable to remove quarantined theme metadata.",
                MTLibraryPOSIXError(errno));
        }
    }
    if (success) {
        success = MTLibrarySynchronizeDirectoryDescriptor(themeDirectory,
                                                          error);
    }
    close(themeDirectory);
    if (success && unlinkat(themesDescriptor,
            deletionName.fileSystemRepresentation, AT_REMOVEDIR) != 0) {
        success = MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
            @"Unable to remove a quarantined Library theme directory.",
            MTLibraryPOSIXError(errno));
    }
    if (success) {
        success = MTLibrarySynchronizeDirectoryDescriptor(themesDescriptor,
                                                          error);
    }
    return success;
}

BOOL MTLibraryRecoverAbandonedTransactions(int themeDescriptor,
                                           int revisionsDescriptor,
                                           NSError **error) {
    NSArray<NSString *> *revisionNames = nil;
    if (!MTLibraryListDirectoryNames(revisionsDescriptor, &revisionNames,
                                     error)) {
        return NO;
    }
    for (NSString *name in revisionNames) {
        if ([name hasPrefix:MTLibraryTransactionPrefix]) {
            if (!MTLibraryTransactionNameIsCanonical(name)) {
                return MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorRecovery,
                    @"The revisions directory contains a malformed transaction name.",
                    nil);
            }
            if (!MTLibraryDiscardTransaction(revisionsDescriptor, name,
                                             error)) {
                return NO;
            }
        } else if ([name hasPrefix:MTLibraryDeletionPrefix]) {
            if (!MTLibraryDeletionNameIsCanonical(name)) {
                return MTLibrarySetError(error,
                    MTThemeLibraryStoreErrorRecovery,
                    @"The revisions directory contains a malformed deletion name.",
                    nil);
            }
            if (!MTLibraryDiscardDeletion(revisionsDescriptor, name, error)) {
                return NO;
            }
        }
    }

    NSArray<NSString *> *themeNames = nil;
    if (!MTLibraryListDirectoryNames(themeDescriptor, &themeNames, error)) {
        return NO;
    }
    BOOL changed = NO;
    for (NSString *name in themeNames) {
        if (![name hasPrefix:MTLibraryCurrentPartialPrefix]) continue;
        if (!MTLibraryUUIDSuffixIsCanonical(name,
                MTLibraryCurrentPartialPrefix) ||
            !MTLibraryValidateCleanupFile(themeDescriptor, name, error)) {
            if (error == NULL || *error == nil) {
                MTLibrarySetError(error, MTThemeLibraryStoreErrorRecovery,
                    @"The theme directory contains an unsafe current-pointer partial.",
                    nil);
            }
            return NO;
        }
        if (unlinkat(themeDescriptor, name.fileSystemRepresentation, 0) != 0) {
            return MTLibrarySetError(error,
                MTThemeLibraryStoreErrorRecovery,
                @"Unable to remove an abandoned current-pointer partial.",
                MTLibraryPOSIXError(errno));
        }
        changed = YES;
    }
    return !changed || MTLibrarySynchronizeDirectoryDescriptor(themeDescriptor,
                                                               error);
}
