#import "MTAssetStagingFilesystem.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTImportSession.h"

static NSString *const MTAssetSessionPrefix = @"asset-session-";
static NSString *const MTAssetPartialPrefix = @".partial-";
static const char *MTAssetObjectsName = "objects";

NSError *MTAssetPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

NSError *MTAssetError(MTAssetStagingSessionErrorCode code,
                      NSString *description,
                      NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTAssetStagingSessionErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL MTAssetSetError(NSError **error,
                     MTAssetStagingSessionErrorCode code,
                     NSString *description,
                     NSError *underlying) {
    if (error != NULL) *error = MTAssetError(code, description, underlying);
    return NO;
}

BOOL MTAssetSessionIdentifierIsCanonical(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier hasPrefix:MTAssetSessionPrefix]) {
        return NO;
    }
    NSString *suffix = [identifier
        substringFromIndex:MTAssetSessionPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

NSString *MTAssetCreatePartialName(void) {
    return [MTAssetPartialPrefix stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
}

static BOOL MTAssetPartialNameIsCanonical(NSString *name) {
    if (![name isKindOfClass:NSString.class] ||
        ![name hasPrefix:MTAssetPartialPrefix]) {
        return NO;
    }
    NSString *suffix = [name substringFromIndex:MTAssetPartialPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

BOOL MTAssetStatIdentityMatches(const struct stat *left,
                                const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static BOOL MTAssetFileStatIsStable(const struct stat *before,
                                    const struct stat *after) {
    return MTAssetStatIdentityMatches(before, after) &&
        before->st_mode == after->st_mode &&
        before->st_nlink == after->st_nlink &&
        before->st_uid == after->st_uid &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

BOOL MTOpenAssetSessionsRoot(
    MTAssetStagingConfiguration *configuration,
    BOOL createIfMissing,
    int *rootDescriptor,
    struct stat *rootStatus,
    NSError **error) {
    NSString *path = configuration.sessionsRootURL.path;
    NSString *standardized = path.stringByStandardizingPath;
    if (path.length == 0 || ![path isEqualToString:standardized]) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"The asset-staging root is not a canonical local path.", nil);
    }

    struct stat pathStatus = {0};
    if (lstat(path.fileSystemRepresentation, &pathStatus) != 0) {
        int savedError = errno;
        if (savedError == ENOENT && !createIfMissing) {
            if (rootDescriptor != NULL) *rootDescriptor = -1;
            return YES;
        }
        if (savedError != ENOENT ||
            (mkdir(path.fileSystemRepresentation, 0700) != 0 &&
             errno != EEXIST)) {
            int finalError = savedError == ENOENT ? errno : savedError;
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorStorage,
                @"Unable to create the private asset-staging root.",
                MTAssetPOSIXError(finalError));
        }
    }

    int descriptor = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"Unable to open the asset-staging root without following links.",
            MTAssetPOSIXError(errno));
    }
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0 || !S_ISDIR(status.st_mode) ||
        status.st_uid != geteuid() || fchmod(descriptor, 0700) != 0 ||
        fstat(descriptor, &status) != 0 || (status.st_mode & 0777) != 0700) {
        int savedError = errno;
        close(descriptor);
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"The asset-staging root has an unsafe owner or mode.",
            savedError == 0 ? nil : MTAssetPOSIXError(savedError));
    }
    if (rootDescriptor != NULL) *rootDescriptor = descriptor;
    if (rootStatus != NULL) *rootStatus = status;
    return YES;
}

static BOOL MTAssetValidatePrivateDirectory(int descriptor,
                                            struct stat *status,
                                            NSError **error) {
    struct stat value = {0};
    if (fstat(descriptor, &value) != 0 || !S_ISDIR(value.st_mode) ||
        value.st_uid != geteuid() || fchmod(descriptor, 0700) != 0 ||
        fstat(descriptor, &value) != 0 || (value.st_mode & 0777) != 0700) {
        int savedError = errno;
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"An asset-staging directory has an unsafe owner or mode.",
            savedError == 0 ? nil : MTAssetPOSIXError(savedError));
    }
    if (status != NULL) *status = value;
    return YES;
}

BOOL MTCreateAssetSessionDirectory(
    int rootDescriptor,
    NSString **sessionIdentifier,
    struct stat *sessionStatus,
    NSError **error) {
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSString *identifier = [MTAssetSessionPrefix stringByAppendingString:
            NSUUID.UUID.UUIDString.lowercaseString];
        const char *name = identifier.fileSystemRepresentation;
        if (mkdirat(rootDescriptor, name, 0700) != 0) {
            if (errno == EEXIST) continue;
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorStorage,
                @"Unable to create a private asset-staging session.",
                MTAssetPOSIXError(errno));
        }
        int sessionDescriptor = openat(rootDescriptor, name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat createdStatus = {0};
        BOOL success = sessionDescriptor >= 0 &&
            MTAssetValidatePrivateDirectory(sessionDescriptor,
                                            &createdStatus, error);
        if (success && mkdirat(sessionDescriptor, MTAssetObjectsName, 0700) != 0) {
            success = MTAssetSetError(error,
                MTAssetStagingSessionErrorStorage,
                @"Unable to create the session object directory.",
                MTAssetPOSIXError(errno));
        }
        int objectsDescriptor = success ? openat(sessionDescriptor,
            MTAssetObjectsName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
        if (success && (objectsDescriptor < 0 ||
            !MTAssetValidatePrivateDirectory(objectsDescriptor, NULL, error))) {
            if (objectsDescriptor < 0 && (error == NULL || *error == nil)) {
                MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
                    @"Unable to open the session object directory.",
                    MTAssetPOSIXError(errno));
            }
            success = NO;
        }
        if (success && (fsync(objectsDescriptor) != 0 ||
                        fsync(sessionDescriptor) != 0 ||
                        fsync(rootDescriptor) != 0)) {
            success = MTAssetSetError(error,
                MTAssetStagingSessionErrorStorage,
                @"Unable to synchronize the new asset-staging session.",
                MTAssetPOSIXError(errno));
        }
        if (objectsDescriptor >= 0) close(objectsDescriptor);
        if (!success) {
            if (sessionDescriptor >= 0) {
                unlinkat(sessionDescriptor, MTAssetObjectsName, AT_REMOVEDIR);
                close(sessionDescriptor);
            }
            unlinkat(rootDescriptor, name, AT_REMOVEDIR);
            return NO;
        }
        close(sessionDescriptor);
        *sessionIdentifier = identifier;
        if (sessionStatus != NULL) *sessionStatus = createdStatus;
        return YES;
    }
    return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
        @"Unable to allocate a unique asset-staging session.", nil);
}

static BOOL MTAssetOwnedObjectNameIsCanonical(NSString *name) {
    return MTStringIsLowercaseSHA256Digest(name) ||
        MTAssetPartialNameIsCanonical(name);
}

static BOOL MTAssetValidateCleanupFile(int directoryDescriptor,
                                       const char *name,
                                       NSError **error) {
    struct stat status = {0};
    if (fstatat(directoryDescriptor, name, &status,
                AT_SYMLINK_NOFOLLOW) != 0) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to inspect an asset-staging object during cleanup.",
            MTAssetPOSIXError(errno));
    }
    if (!S_ISREG(status.st_mode) || status.st_nlink != 1 ||
        status.st_uid != geteuid() || (status.st_mode & 0077) != 0 ||
        (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"An asset-staging session contains an unsafe object.", nil);
    }
    return YES;
}

BOOL MTDiscardAssetSessionAtRootDescriptor(
    int rootDescriptor,
    NSString *sessionIdentifier,
    uint64_t expectedDevice,
    uint64_t expectedInode,
    NSError **error) {
    if (!MTAssetSessionIdentifierIsCanonical(sessionIdentifier)) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Refusing to clean a non-canonical asset session.", nil);
    }
    const char *sessionName = sessionIdentifier.fileSystemRepresentation;
    struct stat pathStatus = {0};
    if (fstatat(rootDescriptor, sessionName, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return YES;
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to inspect the asset session before cleanup.",
            MTAssetPOSIXError(errno));
    }
    if (!S_ISDIR(pathStatus.st_mode) || pathStatus.st_uid != geteuid() ||
        (expectedDevice != 0 &&
         ((uint64_t)pathStatus.st_dev != expectedDevice ||
          (uint64_t)pathStatus.st_ino != expectedInode))) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"The asset session to clean has an unsafe identity.", nil);
    }
    int sessionDescriptor = openat(rootDescriptor, sessionName,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat openedStatus = {0};
    if (sessionDescriptor < 0 || fstat(sessionDescriptor, &openedStatus) != 0 ||
        !MTAssetStatIdentityMatches(&pathStatus, &openedStatus) ||
        !S_ISDIR(openedStatus.st_mode) || openedStatus.st_uid != geteuid()) {
        int savedError = errno;
        if (sessionDescriptor >= 0) close(sessionDescriptor);
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"The asset session changed before cleanup.",
            savedError == 0 ? nil : MTAssetPOSIXError(savedError));
    }

    int sessionEnumerationDescriptor = dup(sessionDescriptor);
    DIR *sessionDirectory = sessionEnumerationDescriptor < 0
        ? NULL : fdopendir(sessionEnumerationDescriptor);
    if (sessionDirectory == NULL) {
        int savedError = errno;
        if (sessionEnumerationDescriptor >= 0) {
            close(sessionEnumerationDescriptor);
        }
        close(sessionDescriptor);
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to enumerate the asset session for cleanup.",
            MTAssetPOSIXError(savedError));
    }
    BOOL hasObjectsDirectory = NO;
    BOOL valid = YES;
    while (valid) {
        errno = 0;
        struct dirent *entry = readdir(sessionDirectory);
        if (entry == NULL) {
            if (errno != 0) {
                valid = MTAssetSetError(error,
                    MTAssetStagingSessionErrorCleanup,
                    @"Asset-session cleanup enumeration failed.",
                    MTAssetPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (strcmp(entry->d_name, MTAssetObjectsName) != 0 ||
            hasObjectsDirectory) {
            valid = MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"Refusing to delete an asset session with an unknown entry.",
                nil);
            break;
        }
        hasObjectsDirectory = YES;
    }
    closedir(sessionDirectory);
    if (!valid) {
        close(sessionDescriptor);
        return NO;
    }

    int objectsDescriptor = -1;
    if (hasObjectsDirectory) {
        struct stat objectsPathStatus = {0};
        if (fstatat(sessionDescriptor, MTAssetObjectsName,
                    &objectsPathStatus, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(objectsPathStatus.st_mode) ||
            objectsPathStatus.st_uid != geteuid()) {
            close(sessionDescriptor);
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"The asset object directory has an unsafe identity.", nil);
        }
        objectsDescriptor = openat(sessionDescriptor, MTAssetObjectsName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat openedObjects = {0};
        if (objectsDescriptor < 0 ||
            fstat(objectsDescriptor, &openedObjects) != 0 ||
            !MTAssetStatIdentityMatches(&objectsPathStatus, &openedObjects)) {
            int savedError = errno;
            if (objectsDescriptor >= 0) close(objectsDescriptor);
            close(sessionDescriptor);
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"The asset object directory changed before cleanup.",
                savedError == 0 ? nil : MTAssetPOSIXError(savedError));
        }

        int enumerationDescriptor = dup(objectsDescriptor);
        DIR *objectsDirectory = enumerationDescriptor < 0
            ? NULL : fdopendir(enumerationDescriptor);
        if (objectsDirectory == NULL) {
            int savedError = errno;
            if (enumerationDescriptor >= 0) close(enumerationDescriptor);
            close(objectsDescriptor);
            close(sessionDescriptor);
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"Unable to enumerate staged objects for cleanup.",
                MTAssetPOSIXError(savedError));
        }
        NSMutableArray<NSString *> *objectNames = [NSMutableArray array];
        while (valid) {
            errno = 0;
            struct dirent *entry = readdir(objectsDirectory);
            if (entry == NULL) {
                if (errno != 0) {
                    valid = MTAssetSetError(error,
                        MTAssetStagingSessionErrorCleanup,
                        @"Asset-object cleanup enumeration failed.",
                        MTAssetPOSIXError(errno));
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
            if (!MTAssetOwnedObjectNameIsCanonical(name) ||
                !MTAssetValidateCleanupFile(objectsDescriptor,
                                            entry->d_name, error)) {
                if (name != nil &&
                    !MTAssetOwnedObjectNameIsCanonical(name) &&
                    (error == NULL || *error == nil)) {
                    MTAssetSetError(error,
                        MTAssetStagingSessionErrorCleanup,
                        @"Refusing to delete an unknown staged object.", nil);
                }
                valid = NO;
                break;
            }
            [objectNames addObject:name];
        }
        closedir(objectsDirectory);
        if (valid) {
            for (NSString *name in objectNames) {
                if (unlinkat(objectsDescriptor,
                             name.fileSystemRepresentation, 0) != 0) {
                    valid = MTAssetSetError(error,
                        MTAssetStagingSessionErrorCleanup,
                        @"Unable to remove a staged object.",
                        MTAssetPOSIXError(errno));
                    break;
                }
            }
        }
        if (valid && fsync(objectsDescriptor) != 0) {
            valid = MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"Unable to synchronize staged-object cleanup.",
                MTAssetPOSIXError(errno));
        }
        close(objectsDescriptor);
        if (valid && unlinkat(sessionDescriptor, MTAssetObjectsName,
                              AT_REMOVEDIR) != 0) {
            valid = MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"Unable to remove the empty asset object directory.",
                MTAssetPOSIXError(errno));
        }
    }
    if (valid && fsync(sessionDescriptor) != 0) {
        valid = MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to synchronize asset-session cleanup.",
            MTAssetPOSIXError(errno));
    }
    close(sessionDescriptor);
    if (valid && unlinkat(rootDescriptor, sessionName, AT_REMOVEDIR) != 0) {
        valid = MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to remove the empty asset session.",
            MTAssetPOSIXError(errno));
    }
    if (valid && fsync(rootDescriptor) != 0) {
        valid = MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to synchronize the asset-staging root.",
            MTAssetPOSIXError(errno));
    }
    return valid;
}

BOOL MTOpenAssetSessionDescriptors(
    MTAssetStagingConfiguration *configuration,
    NSString *sessionIdentifier,
    uint64_t rootDevice,
    uint64_t rootInode,
    uint64_t sessionDevice,
    uint64_t sessionInode,
    int *rootDescriptor,
    int *sessionDescriptor,
    int *objectsDescriptor,
    NSError **error) {
    int root = -1;
    struct stat rootStatus = {0};
    if (!MTOpenAssetSessionsRoot(configuration, NO, &root, &rootStatus, error)) {
        return NO;
    }
    if (root < 0 || (uint64_t)rootStatus.st_dev != rootDevice ||
        (uint64_t)rootStatus.st_ino != rootInode) {
        if (root >= 0) close(root);
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"The asset-staging root changed during the transaction.", nil);
    }
    const char *sessionName = sessionIdentifier.fileSystemRepresentation;
    struct stat sessionPathStatus = {0};
    if (fstatat(root, sessionName, &sessionPathStatus,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(sessionPathStatus.st_mode) ||
        (uint64_t)sessionPathStatus.st_dev != sessionDevice ||
        (uint64_t)sessionPathStatus.st_ino != sessionInode) {
        int savedError = errno;
        close(root);
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"The asset session changed during the transaction.",
            savedError == 0 ? nil : MTAssetPOSIXError(savedError));
    }
    int session = openat(root, sessionName,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat openedSession = {0};
    if (session < 0 || fstat(session, &openedSession) != 0 ||
        !MTAssetStatIdentityMatches(&sessionPathStatus, &openedSession) ||
        !MTAssetValidatePrivateDirectory(session, NULL, error)) {
        int savedError = errno;
        if (session >= 0) close(session);
        close(root);
        if (error == NULL || *error == nil) {
            MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
                @"Unable to reopen the asset session safely.",
                MTAssetPOSIXError(savedError));
        }
        return NO;
    }
    int objects = openat(session, MTAssetObjectsName,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (objects < 0 ||
        !MTAssetValidatePrivateDirectory(objects, NULL, error)) {
        int savedError = errno;
        if (objects >= 0) close(objects);
        close(session);
        close(root);
        if (error == NULL || *error == nil) {
            MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
                @"Unable to reopen the asset object directory safely.",
                MTAssetPOSIXError(savedError));
        }
        return NO;
    }
    *rootDescriptor = root;
    *sessionDescriptor = session;
    *objectsDescriptor = objects;
    return YES;
}

BOOL MTAssetWriteAll(int descriptor,
                     const void *bytes,
                     size_t length,
                     NSError **error) {
    const unsigned char *cursor = bytes;
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(descriptor, cursor + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorStorage,
                @"Unable to write an asset-staging object.",
                MTAssetPOSIXError(count == 0 ? EIO : errno));
        }
        written += (size_t)count;
    }
    return YES;
}

BOOL MTAssetHasAvailableSpace(int descriptor,
                              uint64_t requiredBytes,
                              NSError **error) {
    struct statfs storage = {0};
    if (fstatfs(descriptor, &storage) != 0) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorStorage,
            @"Unable to inspect available asset-staging space.",
            MTAssetPOSIXError(errno));
    }
    uint64_t blocks = (uint64_t)storage.f_bavail;
    uint64_t blockSize = (uint64_t)storage.f_bsize;
    uint64_t available = blockSize != 0 && blocks > UINT64_MAX / blockSize
        ? UINT64_MAX : blocks * blockSize;
    if (requiredBytes > available) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorLimitExceeded,
            @"Insufficient private storage is available for this asset.", nil);
    }
    return YES;
}

BOOL MTAssetSessionPathsAreStable(
    MTAssetStagingConfiguration *configuration,
    NSString *sessionIdentifier,
    uint64_t rootDevice,
    uint64_t rootInode,
    uint64_t sessionDevice,
    uint64_t sessionInode,
    int rootDescriptor,
    int sessionDescriptor,
    int objectsDescriptor,
    NSError **error) {
    struct stat rootPath = {0};
    struct stat openedRoot = {0};
    struct stat sessionPath = {0};
    struct stat openedSession = {0};
    struct stat objectsPath = {0};
    struct stat openedObjects = {0};
    BOOL stable =
        lstat(configuration.sessionsRootURL.path.fileSystemRepresentation,
              &rootPath) == 0 &&
        fstat(rootDescriptor, &openedRoot) == 0 &&
        MTAssetStatIdentityMatches(&rootPath, &openedRoot) &&
        (uint64_t)openedRoot.st_dev == rootDevice &&
        (uint64_t)openedRoot.st_ino == rootInode &&
        fstatat(rootDescriptor, sessionIdentifier.fileSystemRepresentation,
                &sessionPath, AT_SYMLINK_NOFOLLOW) == 0 &&
        fstat(sessionDescriptor, &openedSession) == 0 &&
        MTAssetStatIdentityMatches(&sessionPath, &openedSession) &&
        (uint64_t)openedSession.st_dev == sessionDevice &&
        (uint64_t)openedSession.st_ino == sessionInode &&
        fstatat(sessionDescriptor, MTAssetObjectsName, &objectsPath,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        fstat(objectsDescriptor, &openedObjects) == 0 &&
        MTAssetStatIdentityMatches(&objectsPath, &openedObjects);
    if (!stable) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"The asset-staging directory chain changed before commit.", nil);
    }
    return YES;
}

BOOL MTAssetVerifyOwnedFile(
    int directoryDescriptor,
    const char *name,
    uint64_t expectedBytes,
    NSString *expectedDigest,
    MTImportCancellationToken *cancellationToken,
    struct stat *verifiedStatus,
    NSError **error) {
    if (cancellationToken.isCancelled) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCancelled,
            @"Asset staging was cancelled before destination verification.",
            nil);
    }
    int descriptor = openat(directoryDescriptor, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"Unable to reopen the staged destination safely.",
            MTAssetPOSIXError(errno));
    }
    struct stat before = {0};
    if (fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_nlink != 1 || before.st_uid != geteuid() ||
        (before.st_mode & 0777) != 0600 || before.st_size < 0 ||
        (uint64_t)before.st_size != expectedBytes) {
        close(descriptor);
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"The staged destination failed its type, owner, mode, or size check.",
            nil);
    }
    uint64_t digestedBytes = 0;
    NSError *digestError = nil;
    NSString *digest = MTSHA256HexDigestForFileDescriptor(
        descriptor, expectedBytes, &digestedBytes, &digestError);
    struct stat after = {0};
    BOOL stable = fstat(descriptor, &after) == 0 &&
        MTAssetFileStatIsStable(&before, &after);
    close(descriptor);
    if (cancellationToken.isCancelled) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCancelled,
            @"Asset staging was cancelled during destination verification.",
            nil);
    }
    if (digest == nil || digestedBytes != expectedBytes || !stable ||
        ![digest isEqualToString:expectedDigest]) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"The independently read destination does not match its inventory digest.",
            digestError);
    }
    if (verifiedStatus != NULL) *verifiedStatus = after;
    return YES;
}

BOOL MTAssetVerifyKnownFileIdentity(
    int directoryDescriptor,
    const char *name,
    uint64_t expectedBytes,
    const struct stat *verifiedBaseline,
    MTImportCancellationToken *cancellationToken,
    NSError **error) {
    if (cancellationToken.isCancelled) {
        return MTAssetSetError(error, MTAssetStagingSessionErrorCancelled,
            @"Asset staging was cancelled before deduplication.", nil);
    }
    int descriptor = openat(directoryDescriptor, name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"A known staged object could not be reopened safely.",
            MTAssetPOSIXError(errno));
    }
    struct stat current = {0};
    BOOL valid = fstat(descriptor, &current) == 0 &&
        MTAssetFileStatIsStable(verifiedBaseline, &current) &&
        S_ISREG(current.st_mode) && current.st_nlink == 1 &&
        current.st_uid == geteuid() && (current.st_mode & 0777) == 0600 &&
        current.st_size >= 0 && (uint64_t)current.st_size == expectedBytes;
    close(descriptor);
    if (!valid) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorVerification,
            @"A known staged object changed after its destination hash was verified.",
            nil);
    }
    return YES;
}
