#import "MTGenerationFilesystem.h"
#import "MTGenerationFilesystemInternal.h"

#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTImportSession.h"

static NSString *const MTGenerationDirectoryName = @"generations";
static NSString *const MTGenerationLockName = @"transaction.lock";
static NSString *const MTGenerationPrefix = @"g1-";
static NSString *const MTGenerationTransactionPrefix = @".transaction-";

NSError *MTGenerationPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

NSError *MTGenerationWriterError(MTGenerationWriterErrorCode code,
                                 NSString *description,
                                 NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTGenerationWriterErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL MTGenerationWriterSetError(NSError **error,
                                MTGenerationWriterErrorCode code,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        *error = MTGenerationWriterError(code, description, underlying);
    }
    return NO;
}

static BOOL MTGenerationUUIDSuffixIsCanonical(NSString *name,
                                               NSString *prefix) {
    if (![name isKindOfClass:NSString.class] || ![name hasPrefix:prefix]) {
        return NO;
    }
    NSString *suffix = [name substringFromIndex:prefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

BOOL MTGenerationIdentifierIsCanonical(NSString *identifier) {
    return [identifier isKindOfClass:NSString.class] &&
        [identifier hasPrefix:MTGenerationPrefix] &&
        MTStringIsLowercaseSHA256Digest(
            [identifier substringFromIndex:MTGenerationPrefix.length]);
}

NSString *MTGenerationCreateTransactionName(void) {
    return [MTGenerationTransactionPrefix stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
}

BOOL MTGenerationTransactionNameIsCanonical(NSString *name) {
    return MTGenerationUUIDSuffixIsCanonical(name,
                                               MTGenerationTransactionPrefix);
}

BOOL MTGenerationStatIdentityMatches(const struct stat *left,
                                     const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

BOOL MTGenerationFileStatusIsStable(const struct stat *before,
                                    const struct stat *after) {
    return MTGenerationStatIdentityMatches(before, after) &&
        before->st_mode == after->st_mode &&
        before->st_uid == after->st_uid &&
        before->st_gid == after->st_gid &&
        before->st_nlink == after->st_nlink &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

BOOL MTGenerationPrivateDirectoryStatusIsValid(const struct stat *status) {
    return S_ISDIR(status->st_mode) && status->st_uid == geteuid() &&
        (status->st_mode & 0777) == 0700;
}

BOOL MTGenerationPrivateFileStatusIsValid(const struct stat *status,
                                          uint64_t maximumBytes) {
    return S_ISREG(status->st_mode) && status->st_nlink == 1 &&
        status->st_uid == geteuid() &&
        (status->st_mode & 0777) == 0600 && status->st_size >= 0 &&
        (uint64_t)status->st_size <= maximumBytes;
}

BOOL MTGenerationValidatePrivateDirectory(int descriptor,
                                          BOOL normalizeMode,
                                          struct stat *status,
                                          NSError **error) {
    struct stat value = {0};
    if (fstat(descriptor, &value) != 0 || !S_ISDIR(value.st_mode) ||
        value.st_uid != geteuid() ||
        (normalizeMode && fchmod(descriptor, 0700) != 0) ||
        fstat(descriptor, &value) != 0 ||
        !MTGenerationPrivateDirectoryStatusIsValid(&value)) {
        int savedError = errno;
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation directory has an unsafe type, owner, or mode.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
    }
    if (status != NULL) *status = value;
    return YES;
}

static BOOL MTGenerationOpenOrCreatePrivateDirectoryAt(
    int parentDescriptor,
    NSString *name,
    BOOL createIfMissing,
    int *outputDescriptor,
    struct stat *outputStatus,
    NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name containsString:@"/"]) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A Generation directory name is invalid.", nil);
    }
    BOOL created = NO;
    if (createIfMissing &&
        mkdirat(parentDescriptor, name.fileSystemRepresentation, 0700) == 0) {
        created = YES;
    } else if (createIfMissing && errno != EEXIST) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to create a private Generation directory.",
            MTGenerationPOSIXError(errno));
    }
    struct stat pathStatus = {0};
    if (fstatat(parentDescriptor, name.fileSystemRepresentation, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTGenerationPrivateDirectoryStatusIsValid(&pathStatus)) {
        int savedError = errno;
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation directory path is not private and safe.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
    }
    int descriptor = openat(parentDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat openedStatus = {0};
    if (descriptor < 0 ||
        !MTGenerationValidatePrivateDirectory(descriptor, NO, &openedStatus,
                                              error) ||
        !MTGenerationStatIdentityMatches(&pathStatus, &openedStatus)) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A Generation directory changed while it was opened.",
                savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
        }
        return NO;
    }
    if (created && fsync(parentDescriptor) != 0) {
        int savedError = errno;
        close(descriptor);
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to synchronize a new Generation directory.",
            MTGenerationPOSIXError(savedError));
    }
    *outputDescriptor = descriptor;
    if (outputStatus != NULL) *outputStatus = openedStatus;
    return YES;
}

void MTGenerationStoreDirectoriesInitialize(
    MTGenerationStoreDirectories *directories) {
    memset(directories, 0, sizeof(*directories));
    directories->rootDescriptor = -1;
    directories->generationsDescriptor = -1;
}

void MTGenerationStoreDirectoriesClose(
    MTGenerationStoreDirectories *directories) {
    if (directories->generationsDescriptor >= 0) {
        close(directories->generationsDescriptor);
    }
    if (directories->rootDescriptor >= 0) close(directories->rootDescriptor);
    MTGenerationStoreDirectoriesInitialize(directories);
}

BOOL MTOpenGenerationStoreDirectories(
    MTGenerationWriterConfiguration *configuration,
    BOOL createIfMissing,
    MTGenerationStoreDirectories *directories,
    NSError **error) {
    MTGenerationStoreDirectoriesInitialize(directories);
    if (![configuration isKindOfClass:MTGenerationWriterConfiguration.class] ||
        !configuration.rootURL.isFileURL ||
        configuration.rootURL.path.length == 0 ||
        ![configuration.rootURL.path isEqualToString:
            configuration.rootURL.path.stringByStandardizingPath]) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A canonical local Generation store configuration is required.",
            nil);
    }
    NSString *path = configuration.rootURL.path;
    struct stat pathStatus = {0};
    if (lstat(path.fileSystemRepresentation, &pathStatus) != 0) {
        int savedError = errno;
        if (savedError == ENOENT && !createIfMissing) {
            return MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"The Generation store does not exist.", nil);
        }
        NSError *createError = nil;
        if (savedError != ENOENT ||
            ![NSFileManager.defaultManager createDirectoryAtURL:
                    configuration.rootURL
                                     withIntermediateDirectories:YES
                                                      attributes:@{
                NSFilePosixPermissions : @0700
            } error:&createError]) {
            return MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to create the private Generation store root.",
                createError ?: MTGenerationPOSIXError(savedError));
        }
    }
    int root = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (root < 0 ||
        !MTGenerationValidatePrivateDirectory(root, YES,
                                              &directories->rootStatus,
                                              error)) {
        int savedError = errno;
        if (root >= 0) close(root);
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to open the private Generation store root.",
                MTGenerationPOSIXError(savedError));
        }
        return NO;
    }
    directories->rootDescriptor = root;
    if (!MTGenerationOpenOrCreatePrivateDirectoryAt(
            root, MTGenerationDirectoryName, createIfMissing,
            &directories->generationsDescriptor,
            &directories->generationsStatus, error)) {
        MTGenerationStoreDirectoriesClose(directories);
        return NO;
    }
    return YES;
}

BOOL MTGenerationStoreDirectoriesAreStable(
    MTGenerationWriterConfiguration *configuration,
    MTGenerationStoreDirectories *directories,
    NSError **error) {
    struct stat rootNow = {0};
    struct stat generationsNow = {0};
    struct stat rootPath = {0};
    struct stat generationsPath = {0};
    BOOL stable = fstat(directories->rootDescriptor, &rootNow) == 0 &&
        fstat(directories->generationsDescriptor, &generationsNow) == 0 &&
        lstat(configuration.rootURL.path.fileSystemRepresentation,
              &rootPath) == 0 &&
        fstatat(directories->rootDescriptor,
                MTGenerationDirectoryName.fileSystemRepresentation,
                &generationsPath, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationStatIdentityMatches(&directories->rootStatus, &rootNow) &&
        MTGenerationStatIdentityMatches(&rootNow, &rootPath) &&
        MTGenerationStatIdentityMatches(&directories->generationsStatus,
                                        &generationsNow) &&
        MTGenerationStatIdentityMatches(&generationsNow, &generationsPath) &&
        MTGenerationPrivateDirectoryStatusIsValid(&rootNow) &&
        MTGenerationPrivateDirectoryStatusIsValid(&generationsNow);
    return stable ? YES : MTGenerationWriterSetError(error,
        MTGenerationWriterErrorVerification,
        @"The Generation store directories changed during the operation.", nil);
}

int MTGenerationAcquireTransactionLock(int rootDescriptor,
                                       NSError **error) {
    int descriptor = openat(rootDescriptor,
        MTGenerationLockName.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat status = {0};
    struct stat pathStatus = {0};
    if (descriptor < 0 || fstat(descriptor, &status) != 0 ||
        !S_ISREG(status.st_mode) || status.st_uid != geteuid() ||
        status.st_nlink != 1 || status.st_size != 0 ||
        fchmod(descriptor, 0600) != 0 || fstat(descriptor, &status) != 0 ||
        !MTGenerationPrivateFileStatusIsValid(&status, 0) ||
        fstatat(rootDescriptor,
                MTGenerationLockName.fileSystemRepresentation,
                &pathStatus, AT_SYMLINK_NOFOLLOW) != 0 ||
        !MTGenerationStatIdentityMatches(&status, &pathStatus) ||
        fsync(descriptor) != 0 || fsync(rootDescriptor) != 0) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"The Generation transaction lock is not a private empty file.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
        return -1;
    }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        int savedError = errno;
        close(descriptor);
        MTGenerationWriterSetError(error,
            savedError == EWOULDBLOCK || savedError == EAGAIN
                ? MTGenerationWriterErrorBusy
                : MTGenerationWriterErrorStorage,
            savedError == EWOULDBLOCK || savedError == EAGAIN
                ? @"Another Generation store operation is already running."
                : @"Unable to lock the Generation store.",
            MTGenerationPOSIXError(savedError));
        return -1;
    }
    return descriptor;
}

BOOL MTGenerationSynchronizeDirectory(int descriptor, NSError **error) {
    return fsync(descriptor) == 0 ? YES : MTGenerationWriterSetError(error,
        MTGenerationWriterErrorStorage,
        @"Unable to synchronize a Generation directory.",
        MTGenerationPOSIXError(errno));
}

BOOL MTGenerationListDirectoryNames(int descriptor,
                                    NSArray<NSString *> **names,
                                    NSError **error) {
    int enumerationDescriptor = openat(descriptor, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"Unable to enumerate a Generation directory.",
            MTGenerationPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    BOOL success = YES;
    while (YES) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTGenerationWriterSetError(error,
                    MTGenerationWriterErrorVerification,
                    @"Generation directory enumeration failed.",
                    MTGenerationPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        NSString *name = [[NSString alloc]
            initWithBytes:entry->d_name length:strlen(entry->d_name)
                 encoding:NSUTF8StringEncoding];
        if (name == nil || name.length == 0 || [name containsString:@"/"]) {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A Generation directory contains an invalid filename.", nil);
            break;
        }
        [result addObject:name];
    }
    closedir(directory);
    if (!success) return NO;
    *names = [result sortedArrayUsingSelector:@selector(compare:)];
    return YES;
}

BOOL MTGenerationOpenPrivateDirectoryAt(int parentDescriptor,
                                        NSString *name,
                                        int *descriptor,
                                        NSError **error) {
    return MTGenerationOpenOrCreatePrivateDirectoryAt(
        parentDescriptor, name, NO, descriptor, NULL, error);
}

BOOL MTGenerationCreatePrivateDirectoryAt(int parentDescriptor,
                                          NSString *name,
                                          int *descriptor,
                                          NSError **error) {
    return MTGenerationOpenOrCreatePrivateDirectoryAt(
        parentDescriptor, name, YES, descriptor, NULL, error);
}

BOOL MTGenerationWriteAll(int descriptor,
                          const void *bytes,
                          size_t length,
                          NSError **error) {
    const unsigned char *cursor = bytes;
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(descriptor, cursor + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to write Generation bytes.",
                MTGenerationPOSIXError(count == 0 ? EIO : errno));
        }
        offset += (size_t)count;
    }
    return YES;
}

BOOL MTGenerationWriteDataExclusivelyAt(int directoryDescriptor,
                                        NSString *name,
                                        NSData *data,
                                        NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name containsString:@"/"] || ![data isKindOfClass:NSData.class]) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A Generation file write request is invalid.", nil);
    }
    int descriptor = openat(directoryDescriptor,
        name.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to create a private Generation file.",
            MTGenerationPOSIXError(errno));
    }
    BOOL success = fchmod(descriptor, 0600) == 0 &&
        MTGenerationWriteAll(descriptor, data.bytes, data.length, error) &&
        fsync(descriptor) == 0;
    int savedError = errno;
    struct stat status = {0};
    struct stat pathStatus = {0};
    if (success) {
        success = fstat(descriptor, &status) == 0 &&
            MTGenerationPrivateFileStatusIsValid(&status, data.length) &&
            (uint64_t)status.st_size == data.length &&
            fstatat(directoryDescriptor, name.fileSystemRepresentation,
                    &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
            MTGenerationStatIdentityMatches(&status, &pathStatus);
    }
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        unlinkat(directoryDescriptor, name.fileSystemRepresentation, 0);
        if (error == NULL || *error == nil) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to durably write a private Generation file.",
                savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
        }
        return NO;
    }
    return YES;
}

NSData *MTGenerationReadPrivateFileAt(int directoryDescriptor,
                                      NSString *name,
                                      uint64_t maximumBytes,
                                      NSError **error) {
    if (maximumBytes == 0 || ![name isKindOfClass:NSString.class] ||
        name.length == 0 || [name containsString:@"/"]) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A Generation file read request is invalid.", nil);
        return nil;
    }
    int descriptor = openat(directoryDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat before = {0};
    if (descriptor < 0 || fstat(descriptor, &before) != 0 ||
        !MTGenerationPrivateFileStatusIsValid(&before, maximumBytes)) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation file has unsafe metadata or exceeds its limit.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
        return nil;
    }
    if ((uint64_t)before.st_size > NSUIntegerMax) {
        close(descriptor);
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorLimitExceeded,
            @"A Generation file cannot fit the current address space.", nil);
        return nil;
    }
    NSMutableData *data = [NSMutableData
        dataWithLength:(NSUInteger)(uint64_t)before.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor,
            (unsigned char *)data.mutableBytes + offset,
            data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedError = count == 0 ? EIO : errno;
            close(descriptor);
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to read a complete Generation file.",
                MTGenerationPOSIXError(savedError));
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
    struct stat pathStatus = {0};
    BOOL stable = extraCount == 0 && fstat(descriptor, &after) == 0 &&
        MTGenerationFileStatusIsStable(&before, &after) &&
        fstatat(directoryDescriptor, name.fileSystemRepresentation,
                &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationStatIdentityMatches(&after, &pathStatus);
    close(descriptor);
    if (!stable) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation file changed while it was read.", nil);
        return nil;
    }
    return [data copy];
}

BOOL MTGenerationCheckAvailableSpace(int descriptor,
                                     uint64_t requiredBytes,
                                     uint64_t reserveBytes,
                                     NSError **error) {
    struct statfs storage = {0};
    if (fstatfs(descriptor, &storage) != 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to inspect available Generation storage.",
            MTGenerationPOSIXError(errno));
    }
    uint64_t blocks = (uint64_t)storage.f_bavail;
    uint64_t blockSize = (uint64_t)storage.f_bsize;
    uint64_t available = blockSize != 0 && blocks > UINT64_MAX / blockSize
        ? UINT64_MAX : blocks * blockSize;
    if (reserveBytes > available || requiredBytes > available - reserveBytes) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInsufficientSpace,
            @"Insufficient private storage is available for the complete Generation and reserve.",
            nil);
    }
    return YES;
}

NSString *MTGenerationHexDigest(const unsigned char *bytes) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(bytes[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

NSString *MTGenerationHashDescriptor(
    int descriptor,
    uint64_t maximumBytes,
    MTImportCancellationToken *token,
    uint64_t *bytesRead,
    NSError **error) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        MTGenerationWriterSetError(error, MTGenerationWriterErrorStorage,
            @"Unable to seek a Generation file for hashing.",
            MTGenerationPOSIXError(errno));
        return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    while (YES) {
        if (token.isCancelled) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorCancelled,
                @"Generation verification was cancelled.", nil);
            return nil;
        }
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to read Generation bytes for hashing.",
                MTGenerationPOSIXError(errno));
            return nil;
        }
        if (count == 0) break;
        if ((uint64_t)count > maximumBytes - total) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"A Generation file exceeds its declared byte count.", nil);
            return nil;
        }
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    if (bytesRead != NULL) *bytesRead = total;
    return MTGenerationHexDigest(digest);
}

BOOL MTGenerationVerifyPrivateFileAt(int directoryDescriptor,
                                     NSString *name,
                                     uint64_t expectedBytes,
                                     NSString *expectedDigest,
                                     MTImportCancellationToken *token,
                                     NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name containsString:@"/"] ||
        (expectedDigest != nil &&
         !MTStringIsLowercaseSHA256Digest(expectedDigest))) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorInvalidRequest,
            @"A Generation file verification request is invalid.", nil);
    }
    int descriptor = openat(directoryDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat before = {0};
    if (descriptor < 0 || fstat(descriptor, &before) != 0 ||
        !MTGenerationPrivateFileStatusIsValid(&before, expectedBytes) ||
        (uint64_t)before.st_size != expectedBytes) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation file failed its exact metadata check.",
            savedError == 0 ? nil : MTGenerationPOSIXError(savedError));
    }
    uint64_t bytes = 0;
    NSString *digest = expectedDigest == nil ? nil :
        MTGenerationHashDescriptor(descriptor, expectedBytes, token,
                                   &bytes, error);
    struct stat after = {0};
    struct stat pathStatus = {0};
    BOOL success = (expectedDigest == nil ||
        (digest != nil && bytes == expectedBytes &&
         [digest isEqualToString:expectedDigest])) &&
        fstat(descriptor, &after) == 0 &&
        MTGenerationFileStatusIsStable(&before, &after) &&
        fstatat(directoryDescriptor, name.fileSystemRepresentation,
                &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationStatIdentityMatches(&after, &pathStatus);
    close(descriptor);
    if (!success && (error == NULL || *error == nil)) {
        MTGenerationWriterSetError(error,
            MTGenerationWriterErrorVerification,
            @"A Generation file failed its complete digest or stability check.",
            nil);
    }
    return success;
}

BOOL MTGenerationCreateTransactionDirectories(
    int generationsDescriptor,
    NSString *transactionName,
    int *transactionDescriptor,
    int *assetsDescriptor,
    NSError **error) {
    if (!MTGenerationTransactionNameIsCanonical(transactionName) ||
        mkdirat(generationsDescriptor,
                transactionName.fileSystemRepresentation, 0700) != 0) {
        return MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to create a unique Generation transaction directory.",
            MTGenerationPOSIXError(errno));
    }
    int transaction = -1;
    int assets = -1;
    BOOL success = MTGenerationOpenPrivateDirectoryAt(
        generationsDescriptor, transactionName, &transaction, error) &&
        MTGenerationCreatePrivateDirectoryAt(transaction, @"assets", &assets,
                                             error) &&
        MTGenerationSynchronizeDirectory(transaction, error) &&
        MTGenerationSynchronizeDirectory(generationsDescriptor, error);
    if (!success) {
        if (assets >= 0) close(assets);
        if (transaction >= 0) close(transaction);
        return NO;
    }
    *transactionDescriptor = transaction;
    *assetsDescriptor = assets;
    return YES;
}
