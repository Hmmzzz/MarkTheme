#import "MTGenerationReaderFilesystem.h"

#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <TargetConditionals.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTImportSession.h"

static NSString *const MTGenerationReaderGenerationsName = @"generations";

NSError *MTGenerationReaderPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:value
                           userInfo:nil];
}

NSError *MTGenerationReaderError(MTGenerationReaderErrorCode code,
                                 NSString *description,
                                 NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTGenerationReaderErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL MTGenerationReaderSetError(NSError **error,
                                MTGenerationReaderErrorCode code,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        *error = MTGenerationReaderError(code, description, underlying);
    }
    return NO;
}

BOOL MTGenerationReaderIdentifierIsCanonical(NSString *identifier) {
    static NSString *const prefix = @"g1-";
    return [identifier isKindOfClass:NSString.class] &&
        [identifier hasPrefix:prefix] &&
        MTStringIsLowercaseSHA256Digest(
            [identifier substringFromIndex:prefix.length]);
}

BOOL MTGenerationReaderCancelled(MTImportCancellationToken *token,
                                 NSString *description,
                                 NSError **error) {
    if (!token.isCancelled) return NO;
    MTGenerationReaderSetError(error, MTGenerationReaderErrorCancelled,
                               description, nil);
    return YES;
}

static BOOL MTGenerationReaderStatusIdentityMatches(
    const struct stat *left,
    const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static BOOL MTGenerationReaderStatusIsStable(const struct stat *before,
                                             const struct stat *after) {
    return MTGenerationReaderStatusIdentityMatches(before, after) &&
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

static uid_t MTGenerationReaderPublishedUserID(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    return geteuid();
#else
    return 0;
#endif
}

static gid_t MTGenerationReaderPublishedGroupID(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    return getegid();
#else
    return 0;
#endif
}

static BOOL MTGenerationReaderDirectoryStatusIsValid(
    const struct stat *status,
    MTGenerationReaderOwnershipProfile ownershipProfile) {
    if (!S_ISDIR(status->st_mode)) return NO;
    mode_t permissions = status->st_mode & 0777;
    BOOL privateTree = status->st_uid == geteuid() && permissions == 0700;
    BOOL publishedTree =
        status->st_uid == MTGenerationReaderPublishedUserID() &&
        status->st_gid == MTGenerationReaderPublishedGroupID() &&
        permissions == 0755;
    return ownershipProfile == MTGenerationReaderOwnershipProfilePrivate
        ? privateTree : publishedTree;
}

static BOOL MTGenerationReaderFileStatusIsValid(
    const struct stat *status,
    uint64_t maximumBytes,
    MTGenerationReaderOwnershipProfile ownershipProfile) {
    if (!S_ISREG(status->st_mode) || status->st_nlink != 1 ||
        status->st_size < 0 || (uint64_t)status->st_size > maximumBytes) {
        return NO;
    }
    mode_t permissions = status->st_mode & 0777;
    BOOL privateFile = status->st_uid == geteuid() && permissions == 0600;
    BOOL publishedFile =
        status->st_uid == MTGenerationReaderPublishedUserID() &&
        status->st_gid == MTGenerationReaderPublishedGroupID() &&
        permissions == 0644;
    return ownershipProfile == MTGenerationReaderOwnershipProfilePrivate
        ? privateFile : publishedFile;
}

static BOOL MTGenerationReaderNameIsSafe(NSString *name) {
    return [name isKindOfClass:NSString.class] && name.length > 0 &&
        ![name containsString:@"/"] &&
        ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

static BOOL MTGenerationReaderOpenDirectoryWithProfileAt(
    int parentDescriptor,
    NSString *name,
    MTGenerationReaderErrorCode missingCode,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    int *outputDescriptor,
    struct stat *outputStatus,
    NSError **error) {
    if (parentDescriptor < 0 || !MTGenerationReaderNameIsSafe(name) ||
        outputDescriptor == NULL || outputStatus == NULL) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation directory open request is invalid.", nil);
    }
    struct stat pathStatus = {0};
    if (fstatat(parentDescriptor, name.fileSystemRepresentation, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        int savedError = errno;
        return MTGenerationReaderSetError(error,
            savedError == ENOENT ? missingCode : MTGenerationReaderErrorStorage,
            savedError == ENOENT
                ? @"A required Generation directory does not exist."
                : @"Unable to inspect a Generation directory.",
            MTGenerationReaderPOSIXError(savedError));
    }
    if (!MTGenerationReaderDirectoryStatusIsValid(
            &pathStatus, ownershipProfile)) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation directory has an unsafe type, owner, or mode.",
            nil);
    }
    int descriptor = openat(parentDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int savedError = descriptor < 0 ? errno : 0;
    struct stat openedStatus = {0};
    BOOL opened = descriptor >= 0;
    if (opened && fstat(descriptor, &openedStatus) != 0) {
        savedError = errno;
        opened = NO;
    }
    if (opened &&
        (!MTGenerationReaderDirectoryStatusIsValid(
             &openedStatus, ownershipProfile) ||
         !MTGenerationReaderStatusIdentityMatches(&pathStatus,
                                                  &openedStatus))) {
        opened = NO;
    }
    if (!opened) {
        if (descriptor >= 0) close(descriptor);
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation directory changed while it was opened.",
            savedError == 0 ? nil
                            : MTGenerationReaderPOSIXError(savedError));
    }
    *outputDescriptor = descriptor;
    *outputStatus = openedStatus;
    return YES;
}

void MTGenerationReaderDirectoriesInitialize(
    MTGenerationReaderDirectories *directories) {
    memset(directories, 0, sizeof(*directories));
    directories->rootDescriptor = -1;
    directories->generationsDescriptor = -1;
    directories->generationDescriptor = -1;
}

void MTGenerationReaderDirectoriesClose(
    MTGenerationReaderDirectories *directories) {
    if (directories->generationDescriptor >= 0) {
        close(directories->generationDescriptor);
    }
    if (directories->generationsDescriptor >= 0) {
        close(directories->generationsDescriptor);
    }
    if (directories->rootDescriptor >= 0) {
        close(directories->rootDescriptor);
    }
    MTGenerationReaderDirectoriesInitialize(directories);
}

BOOL MTGenerationReaderOpenDirectories(
    MTGenerationReaderConfiguration *configuration,
    NSString *generationIdentifier,
    MTGenerationReaderDirectories *directories,
    NSError **error) {
    if (![configuration isKindOfClass:
            MTGenerationReaderConfiguration.class] ||
        !configuration.rootURL.isFileURL ||
        configuration.rootURL.path.length == 0 ||
        !MTGenerationReaderIdentifierIsCanonical(generationIdentifier) ||
        directories == NULL) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation reader store request is invalid.", nil);
    }
    MTGenerationReaderDirectoriesInitialize(directories);
    struct stat rootPathStatus = {0};
    if (lstat(configuration.rootURL.fileSystemRepresentation,
              &rootPathStatus) != 0) {
        int savedError = errno;
        return MTGenerationReaderSetError(error,
            savedError == ENOENT ? MTGenerationReaderErrorNotFound
                                 : MTGenerationReaderErrorStorage,
            savedError == ENOENT
                ? @"The Generation store does not exist."
                : @"Unable to inspect the Generation store root.",
            MTGenerationReaderPOSIXError(savedError));
    }
    if (!MTGenerationReaderDirectoryStatusIsValid(
            &rootPathStatus, configuration.ownershipProfile)) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"The Generation store root has an unsafe type, owner, or mode.",
            nil);
    }
    int rootDescriptor = open(configuration.rootURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int savedError = rootDescriptor < 0 ? errno : 0;
    struct stat rootStatus = {0};
    BOOL rootOpened = rootDescriptor >= 0;
    if (rootOpened && fstat(rootDescriptor, &rootStatus) != 0) {
        savedError = errno;
        rootOpened = NO;
    }
    if (rootOpened &&
        (!MTGenerationReaderDirectoryStatusIsValid(
             &rootStatus, configuration.ownershipProfile) ||
         !MTGenerationReaderStatusIdentityMatches(&rootPathStatus,
                                                  &rootStatus))) {
        rootOpened = NO;
    }
    if (!rootOpened) {
        if (rootDescriptor >= 0) close(rootDescriptor);
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"The Generation store root changed while it was opened.",
            savedError == 0 ? nil
                            : MTGenerationReaderPOSIXError(savedError));
    }
    directories->rootDescriptor = rootDescriptor;
    directories->rootStatus = rootStatus;
    if (!MTGenerationReaderOpenDirectoryWithProfileAt(rootDescriptor,
            MTGenerationReaderGenerationsName,
            MTGenerationReaderErrorNotFound,
            configuration.ownershipProfile,
            &directories->generationsDescriptor,
            &directories->generationsStatus, error) ||
        !MTGenerationReaderOpenDirectoryWithProfileAt(
            directories->generationsDescriptor, generationIdentifier,
            MTGenerationReaderErrorNotFound,
            configuration.ownershipProfile,
            &directories->generationDescriptor,
            &directories->generationStatus, error)) {
        MTGenerationReaderDirectoriesClose(directories);
        return NO;
    }
    return YES;
}

BOOL MTGenerationReaderDirectoriesAreStable(
    MTGenerationReaderConfiguration *configuration,
    NSString *generationIdentifier,
    MTGenerationReaderDirectories *directories,
    NSError **error) {
    struct stat rootNow = {0};
    struct stat generationsNow = {0};
    struct stat generationNow = {0};
    struct stat rootPath = {0};
    struct stat generationsPath = {0};
    struct stat generationPath = {0};
    BOOL stable = directories != NULL &&
        fstat(directories->rootDescriptor, &rootNow) == 0 &&
        fstat(directories->generationsDescriptor, &generationsNow) == 0 &&
        fstat(directories->generationDescriptor, &generationNow) == 0 &&
        lstat(configuration.rootURL.fileSystemRepresentation, &rootPath) == 0 &&
        fstatat(directories->rootDescriptor,
                MTGenerationReaderGenerationsName.fileSystemRepresentation,
                &generationsPath, AT_SYMLINK_NOFOLLOW) == 0 &&
        fstatat(directories->generationsDescriptor,
                generationIdentifier.fileSystemRepresentation,
                &generationPath, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationReaderDirectoryStatusIsValid(
            &rootNow, configuration.ownershipProfile) &&
        MTGenerationReaderDirectoryStatusIsValid(
            &generationsNow, configuration.ownershipProfile) &&
        MTGenerationReaderDirectoryStatusIsValid(
            &generationNow, configuration.ownershipProfile) &&
        MTGenerationReaderStatusIdentityMatches(&directories->rootStatus,
                                                &rootNow) &&
        MTGenerationReaderStatusIdentityMatches(&rootNow, &rootPath) &&
        MTGenerationReaderStatusIdentityMatches(
            &directories->generationsStatus, &generationsNow) &&
        MTGenerationReaderStatusIdentityMatches(&generationsNow,
                                                &generationsPath) &&
        MTGenerationReaderStatusIsStable(&directories->generationStatus,
                                         &generationNow) &&
        MTGenerationReaderStatusIsStable(&generationNow, &generationPath);
    return stable ? YES : MTGenerationReaderSetError(error,
        MTGenerationReaderErrorVerification,
        @"The Generation store or final directory changed while it was read.",
        nil);
}

BOOL MTGenerationReaderOpenDirectoryAt(
    int parentDescriptor,
    NSString *name,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    int *descriptor,
    struct stat *status,
    NSError **error) {
    return MTGenerationReaderOpenDirectoryWithProfileAt(parentDescriptor, name,
        MTGenerationReaderErrorVerification, ownershipProfile,
        descriptor, status, error);
}

BOOL MTGenerationReaderDirectoryIsStableAt(
    int parentDescriptor,
    NSString *name,
    int descriptor,
    const struct stat *originalStatus,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error) {
    struct stat current = {0};
    struct stat path = {0};
    BOOL stable = parentDescriptor >= 0 && descriptor >= 0 &&
        originalStatus != NULL && MTGenerationReaderNameIsSafe(name) &&
        fstat(descriptor, &current) == 0 &&
        fstatat(parentDescriptor, name.fileSystemRepresentation, &path,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationReaderDirectoryStatusIsValid(
            &current, ownershipProfile) &&
        MTGenerationReaderStatusIsStable(originalStatus, &current) &&
        MTGenerationReaderStatusIsStable(&current, &path);
    return stable ? YES : MTGenerationReaderSetError(error,
        MTGenerationReaderErrorVerification,
        @"A Generation subdirectory changed while it was read.", nil);
}

BOOL MTGenerationReaderDirectoryDescriptorIsStable(
    int descriptor,
    const struct stat *originalStatus,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error) {
    struct stat current = {0};
    BOOL stable = descriptor >= 0 && originalStatus != NULL &&
        fstat(descriptor, &current) == 0 &&
        MTGenerationReaderDirectoryStatusIsValid(
            &current, ownershipProfile) &&
        MTGenerationReaderStatusIdentityMatches(originalStatus, &current) &&
        originalStatus->st_mode == current.st_mode &&
        originalStatus->st_uid == current.st_uid &&
        originalStatus->st_gid == current.st_gid &&
        originalStatus->st_nlink == current.st_nlink;
    return stable ? YES : MTGenerationReaderSetError(error,
        MTGenerationReaderErrorVerification,
        @"A retained Generation directory changed after validation.", nil);
}

BOOL MTGenerationReaderListDirectoryNames(
    int descriptor,
    NSUInteger maximumEntryCount,
    MTImportCancellationToken *token,
    NSArray<NSString *> **names,
    NSError **error) {
    if (descriptor < 0 || maximumEntryCount == 0 || names == NULL) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation directory enumeration request is invalid.", nil);
    }
    int enumerationDescriptor = openat(descriptor, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorStorage,
            @"Unable to enumerate a Generation directory.",
            MTGenerationReaderPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    BOOL success = YES;
    while (YES) {
        if (MTGenerationReaderCancelled(token,
                @"Generation directory enumeration was cancelled.", error)) {
            success = NO;
            break;
        }
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTGenerationReaderSetError(error,
                    MTGenerationReaderErrorStorage,
                    @"Generation directory enumeration failed.",
                    MTGenerationReaderPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (result.count >= maximumEntryCount) {
            success = MTGenerationReaderSetError(error,
                MTGenerationReaderErrorLimitExceeded,
                @"A Generation directory exceeds its entry-count limit.",
                nil);
            break;
        }
        NSString *name = [[NSString alloc]
            initWithBytes:entry->d_name length:strlen(entry->d_name)
                 encoding:NSUTF8StringEncoding];
        if (!MTGenerationReaderNameIsSafe(name)) {
            success = MTGenerationReaderSetError(error,
                MTGenerationReaderErrorVerification,
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

NSData *MTGenerationReaderReadFileAt(
    int directoryDescriptor,
    NSString *name,
    uint64_t maximumBytes,
    MTImportCancellationToken *token,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    struct stat *status,
    NSError **error) {
    if (directoryDescriptor < 0 || maximumBytes == 0 || status == NULL ||
        !MTGenerationReaderNameIsSafe(name)) {
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation file read request is invalid.", nil);
        return nil;
    }
    if (MTGenerationReaderCancelled(token,
            @"Generation file reading was cancelled before open.", error)) {
        return nil;
    }
    struct stat pathBefore = {0};
    if (fstatat(directoryDescriptor, name.fileSystemRepresentation,
                &pathBefore, AT_SYMLINK_NOFOLLOW) != 0) {
        int savedError = errno;
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A required Generation file does not exist.",
            MTGenerationReaderPOSIXError(savedError));
        return nil;
    }
    if (!MTGenerationReaderFileStatusIsValid(
            &pathBefore, maximumBytes, ownershipProfile) ||
        (uint64_t)pathBefore.st_size > NSUIntegerMax) {
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation file has unsafe metadata or exceeds its limit.",
            nil);
        return nil;
    }
    int descriptor = openat(directoryDescriptor, name.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int savedError = descriptor < 0 ? errno : 0;
    struct stat before = {0};
    BOOL opened = descriptor >= 0;
    if (opened && fstat(descriptor, &before) != 0) {
        savedError = errno;
        opened = NO;
    }
    if (opened &&
        (!MTGenerationReaderFileStatusIsValid(
             &before, maximumBytes, ownershipProfile) ||
         !MTGenerationReaderStatusIdentityMatches(&pathBefore, &before) ||
         (uint64_t)before.st_size > NSUIntegerMax)) {
        opened = NO;
    }
    if (!opened) {
        if (descriptor >= 0) close(descriptor);
        MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation file has unsafe metadata or exceeds its limit.",
            savedError == 0 ? nil
                            : MTGenerationReaderPOSIXError(savedError));
        return nil;
    }
    NSMutableData *data = [NSMutableData
        dataWithLength:(NSUInteger)(uint64_t)before.st_size];
    NSUInteger offset = 0;
    BOOL success = YES;
    while (offset < data.length) {
        if (MTGenerationReaderCancelled(token,
                @"Generation file reading was cancelled.", error)) {
            success = NO;
            break;
        }
        NSUInteger request = MIN((NSUInteger)(64 * 1024),
                                 data.length - offset);
        ssize_t count = read(descriptor,
            (unsigned char *)data.mutableBytes + offset, request);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedError = count == 0 ? EIO : errno;
            success = MTGenerationReaderSetError(error,
                MTGenerationReaderErrorStorage,
                @"Unable to read a complete Generation file.",
                MTGenerationReaderPOSIXError(savedError));
            break;
        }
        offset += (NSUInteger)count;
    }
    if (success && MTGenerationReaderCancelled(token,
            @"Generation file reading was cancelled after its bytes were read.",
            error)) {
        success = NO;
    }
    unsigned char extra = 0;
    ssize_t extraCount = 0;
    if (success) {
        do {
            extraCount = read(descriptor, &extra, 1);
        } while (extraCount < 0 && errno == EINTR);
    }
    struct stat after = {0};
    struct stat pathAfter = {0};
    success = success && extraCount == 0 &&
        fstat(descriptor, &after) == 0 &&
        MTGenerationReaderStatusIsStable(&before, &after) &&
        fstatat(directoryDescriptor, name.fileSystemRepresentation,
                &pathAfter, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationReaderStatusIsStable(&after, &pathAfter);
    close(descriptor);
    if (!success) {
        if (error == NULL || *error == nil) {
            MTGenerationReaderSetError(error,
                MTGenerationReaderErrorVerification,
                @"A Generation file changed while it was read.", nil);
        }
        return nil;
    }
    *status = after;
    return [data copy];
}

BOOL MTGenerationReaderFileIsStableAt(
    int directoryDescriptor,
    NSString *name,
    const struct stat *originalStatus,
    uint64_t expectedBytes,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    NSError **error) {
    struct stat current = {0};
    BOOL stable = directoryDescriptor >= 0 && originalStatus != NULL &&
        MTGenerationReaderNameIsSafe(name) &&
        fstatat(directoryDescriptor, name.fileSystemRepresentation, &current,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationReaderFileStatusIsValid(
            &current, expectedBytes, ownershipProfile) &&
        (uint64_t)current.st_size == expectedBytes &&
        MTGenerationReaderStatusIsStable(originalStatus, &current);
    return stable ? YES : MTGenerationReaderSetError(error,
        MTGenerationReaderErrorVerification,
        @"A Generation file changed after it was validated.", nil);
}

static NSString *MTGenerationReaderHexDigest(const unsigned char *bytes) {
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[(bytes[index] >> 4) & 0x0f];
        output[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return [NSString stringWithUTF8String:output];
}

BOOL MTGenerationReaderVerifyAssetAt(
    int assetsDescriptor,
    NSString *digest,
    uint64_t expectedBytes,
    MTImportCancellationToken *token,
    MTGenerationReaderOwnershipProfile ownershipProfile,
    struct stat *status,
    NSError **error) {
    if (assetsDescriptor < 0 || expectedBytes == 0 || status == NULL ||
        !MTStringIsLowercaseSHA256Digest(digest)) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorInvalidRequest,
            @"A Generation asset verification request is invalid.", nil);
    }
    if (MTGenerationReaderCancelled(token,
            @"Generation asset verification was cancelled before open.",
            error)) {
        return NO;
    }
    struct stat pathBefore = {0};
    int pathResult = fstatat(assetsDescriptor,
        digest.fileSystemRepresentation, &pathBefore, AT_SYMLINK_NOFOLLOW);
    int savedError = pathResult != 0 ? errno : 0;
    if (pathResult != 0 ||
        !MTGenerationReaderFileStatusIsValid(
            &pathBefore, expectedBytes, ownershipProfile) ||
        (uint64_t)pathBefore.st_size != expectedBytes) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation asset has unsafe or mismatched metadata.",
            savedError == 0 ? nil
                            : MTGenerationReaderPOSIXError(savedError));
    }
    int descriptor = openat(assetsDescriptor, digest.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    savedError = descriptor < 0 ? errno : 0;
    struct stat before = {0};
    BOOL opened = descriptor >= 0;
    if (opened && fstat(descriptor, &before) != 0) {
        savedError = errno;
        opened = NO;
    }
    if (opened &&
        (!MTGenerationReaderFileStatusIsValid(
             &before, expectedBytes, ownershipProfile) ||
         (uint64_t)before.st_size != expectedBytes ||
         !MTGenerationReaderStatusIdentityMatches(&pathBefore, &before))) {
        opened = NO;
    }
    if (!opened) {
        if (descriptor >= 0) close(descriptor);
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation asset changed while it was opened.",
            savedError == 0 ? nil
                            : MTGenerationReaderPOSIXError(savedError));
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    BOOL success = YES;
    while (total < expectedBytes) {
        if (MTGenerationReaderCancelled(token,
                @"Generation asset verification was cancelled.", error)) {
            success = NO;
            break;
        }
        size_t request = (size_t)MIN((uint64_t)sizeof(buffer),
                                     expectedBytes - total);
        ssize_t count = read(descriptor, buffer, request);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedError = count == 0 ? EIO : errno;
            success = MTGenerationReaderSetError(error,
                MTGenerationReaderErrorStorage,
                @"Unable to read complete Generation asset bytes.",
                MTGenerationReaderPOSIXError(savedError));
            break;
        }
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    unsigned char extra = 0;
    ssize_t extraCount = 0;
    if (success) {
        do {
            extraCount = read(descriptor, &extra, 1);
        } while (extraCount < 0 && errno == EINTR);
    }
    unsigned char digestBytes[CC_SHA256_DIGEST_LENGTH];
    if (success) CC_SHA256_Final(digestBytes, &context);
    struct stat after = {0};
    struct stat pathAfter = {0};
    success = success && total == expectedBytes && extraCount == 0 &&
        [MTGenerationReaderHexDigest(digestBytes) isEqualToString:digest] &&
        fstat(descriptor, &after) == 0 &&
        MTGenerationReaderStatusIsStable(&before, &after) &&
        fstatat(assetsDescriptor, digest.fileSystemRepresentation,
                &pathAfter, AT_SYMLINK_NOFOLLOW) == 0 &&
        MTGenerationReaderStatusIsStable(&after, &pathAfter);
    close(descriptor);
    if (!success && (error == NULL || *error == nil)) {
        return MTGenerationReaderSetError(error,
            MTGenerationReaderErrorVerification,
            @"A Generation asset failed full digest or stability validation.",
            nil);
    }
    if (!success) return NO;
    *status = after;
    return YES;
}
