#import "MTDirectorySnapshotFilesystem.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTImportSession.h"
#import "MTSourceInventory.h"

NSString *const MTDirectorySnapshotSessionErrorDomain =
    @"com.hmmzzz.marktheme64e.directory-snapshot-session";

static NSString *const MTDirectorySnapshotSessionPrefix =
    @"directory-session-";
const char *MTDirectorySnapshotPartialName = ".snapshot.partial";
const char *MTDirectorySnapshotPublishedName = "snapshot";

NSError *MTDirectorySnapshotPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:value
                           userInfo:nil];
}
NSError *MTDirectorySnapshotError(
    MTDirectorySnapshotSessionErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTDirectorySnapshotSessionErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL MTDirectorySnapshotSetError(
    NSError **error,
    MTDirectorySnapshotSessionErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    if (error != NULL) {
        *error = MTDirectorySnapshotError(code, description, underlying);
    }
    return NO;
}

BOOL MTDirectorySnapshotIdentifierIsCanonical(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier hasPrefix:MTDirectorySnapshotSessionPrefix]) {
        return NO;
    }
    NSString *suffix = [identifier
        substringFromIndex:MTDirectorySnapshotSessionPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

static BOOL MTDirectorySnapshotComponentIsSafe(NSString *component) {
    if (![component isKindOfClass:NSString.class] || component.length == 0 ||
        [component isEqualToString:@"."] ||
        [component isEqualToString:@".."] ||
        [component containsString:@"/"] ||
        [component containsString:@"\\"]) {
        return NO;
    }
    for (NSUInteger index = 0; index < component.length; index++) {
        unichar character = [component characterAtIndex:index];
        if (character == 0 || character < 0x20 || character == 0x7f) {
            return NO;
        }
    }
    return YES;
}

static BOOL MTDirectorySnapshotStatusesMatch(const struct stat *left,
                                              const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static BOOL MTDirectorySnapshotValidatePrivateDirectory(
    int descriptor,
    struct stat *_Nullable status,
    NSError **error) {
    struct stat value = {0};
    if (fstat(descriptor, &value) != 0 || !S_ISDIR(value.st_mode) ||
        value.st_uid != geteuid() || fchmod(descriptor, 0700) != 0 ||
        fstat(descriptor, &value) != 0 || (value.st_mode & 0777) != 0700) {
        int savedError = errno;
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorStorage,
            @"A directory-snapshot path has an unsafe owner or mode.",
            savedError == 0 ? nil :
                MTDirectorySnapshotPOSIXError(savedError));
    }
    if (status != NULL) *status = value;
    return YES;
}

BOOL MTOpenDirectorySnapshotRoot(
    MTDirectorySnapshotConfiguration *configuration,
    BOOL createIfMissing,
    int *rootDescriptor,
    struct stat *_Nullable rootStatus,
    NSError **error) {
    NSString *path = configuration.sessionsRootURL.path;
    NSString *standardized = path.stringByStandardizingPath;
    if (path.length == 0 || ![path isEqualToString:standardized]) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorStorage,
            @"The directory-snapshot root is not a canonical local path.", nil);
    }

    struct stat pathStatus = {0};
    if (lstat(path.fileSystemRepresentation, &pathStatus) != 0) {
        int savedError = errno;
        if (savedError == ENOENT && !createIfMissing) {
            if (rootDescriptor != NULL) *rootDescriptor = -1;
            return YES;
        }
        NSError *createError = nil;
        if (savedError != ENOENT ||
            ![NSFileManager.defaultManager
                createDirectoryAtURL:configuration.sessionsRootURL
                withIntermediateDirectories:YES
                attributes:@{ NSFilePosixPermissions : @0700 }
                error:&createError]) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to create the private directory-snapshot root.",
                createError ?: MTDirectorySnapshotPOSIXError(savedError));
        }
    }

    int descriptor = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorStorage,
            @"Unable to open the directory-snapshot root safely.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    struct stat opened = {0};
    if (!MTDirectorySnapshotValidatePrivateDirectory(
            descriptor, &opened, error)) {
        close(descriptor);
        return NO;
    }
    if (rootDescriptor != NULL) *rootDescriptor = descriptor;
    if (rootStatus != NULL) *rootStatus = opened;
    return YES;
}

BOOL MTCreateDirectorySnapshotSession(
    int rootDescriptor,
    NSString **sessionIdentifier,
    int *sessionDescriptor,
    int *partialDescriptor,
    struct stat *sessionStatus,
    NSError **error) {
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSString *identifier = [MTDirectorySnapshotSessionPrefix
            stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        const char *name = identifier.fileSystemRepresentation;
        if (mkdirat(rootDescriptor, name, 0700) != 0) {
            if (errno == EEXIST) continue;
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to create a private directory-snapshot session.",
                MTDirectorySnapshotPOSIXError(errno));
        }
        int session = openat(rootDescriptor, name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat createdStatus = {0};
        BOOL success = session >= 0 &&
            MTDirectorySnapshotValidatePrivateDirectory(
                session, &createdStatus, error);
        if (!success && session < 0 && (error == NULL || *error == nil)) {
            MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to open the new directory-snapshot session.",
                MTDirectorySnapshotPOSIXError(errno));
        }
        if (success && mkdirat(session,
                MTDirectorySnapshotPartialName, 0700) != 0) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to create the unpublished snapshot tree.",
                MTDirectorySnapshotPOSIXError(errno));
        }
        int partial = success ? openat(session,
            MTDirectorySnapshotPartialName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
        if (success && (partial < 0 ||
            !MTDirectorySnapshotValidatePrivateDirectory(
                partial, NULL, error))) {
            if (partial < 0 && (error == NULL || *error == nil)) {
                MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorStorage,
                    @"Unable to open the unpublished snapshot tree.",
                    MTDirectorySnapshotPOSIXError(errno));
            }
            success = NO;
        }
        if (success && (fsync(partial) != 0 || fsync(session) != 0 ||
                            fsync(rootDescriptor) != 0)) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to synchronize the new snapshot session.",
                MTDirectorySnapshotPOSIXError(errno));
        }
        if (!success) {
            if (partial >= 0) close(partial);
            if (session >= 0) {
                unlinkat(session, MTDirectorySnapshotPartialName,
                         AT_REMOVEDIR);
                close(session);
            }
            unlinkat(rootDescriptor, name, AT_REMOVEDIR);
            return NO;
        }
        *sessionIdentifier = identifier;
        *sessionDescriptor = session;
        *partialDescriptor = partial;
        *sessionStatus = createdStatus;
        return YES;
    }
    return MTDirectorySnapshotSetError(error,
        MTDirectorySnapshotSessionErrorStorage,
        @"Unable to allocate a unique directory-snapshot identifier.", nil);
}

static BOOL MTDirectorySnapshotRegisterInventoryPath(
    NSString *path,
    BOOL isDirectory,
    NSMutableDictionary<NSString *, NSString *> *pathsByFoldedKey,
    NSMutableDictionary<NSString *, NSNumber *> *directoryByFoldedKey,
    MTImportLimits *limits,
    NSUInteger *nodeCount,
    NSError **error) {
    NSString *folded = [path
        stringByFoldingWithOptions:NSCaseInsensitiveSearch
                            locale:[NSLocale
                                localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSString *existing = pathsByFoldedKey[folded];
    if (existing != nil && ![existing isEqualToString:path]) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"Two snapshot paths collide after normalization or case folding.",
            nil);
    }
    NSNumber *existingDirectory = directoryByFoldedKey[folded];
    if (existingDirectory != nil && existingDirectory.boolValue != isDirectory) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"A snapshot path cannot be both a file and a directory.", nil);
    }
    if (existing == nil) {
        if (*nodeCount >= limits.maximumArchiveEntries) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorLimitExceeded,
                @"The directory snapshot exceeds its total node budget.", nil);
        }
        (*nodeCount)++;
        pathsByFoldedKey[folded] = path;
        directoryByFoldedKey[folded] = @(isDirectory);
    }
    return YES;
}

BOOL MTDirectorySnapshotValidateInventory(
    MTSourceInventory *inventory,
    MTImportLimits *limits,
    NSError **error) {
    if (![inventory isKindOfClass:MTSourceInventory.class] ||
        inventory.files.count == 0 ||
        inventory.files.count > limits.maximumRegularFiles ||
        inventory.totalBytes > limits.maximumExpandedBytes) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"The audited directory exceeds the snapshot file or byte policy.",
            nil);
    }
    NSMutableDictionary<NSString *, NSString *> *paths =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *directoryKinds =
        [NSMutableDictionary dictionary];
    NSUInteger nodeCount = 0;
    uint64_t totalBytes = 0;
    for (MTSourceFile *file in inventory.files) {
        NSString *path = file.relativePath;
        if (![path isKindOfClass:NSString.class] || path.length == 0 ||
            ![path isEqualToString:
                path.precomposedStringWithCanonicalMapping] ||
            [path hasPrefix:@"/"] || [path hasSuffix:@"/"] ||
            [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
                limits.maximumPathUTF8Bytes ||
            file.byteCount > limits.maximumSingleFileBytes ||
            file.byteCount > UINT64_MAX - totalBytes) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorLimitExceeded,
                @"The audited directory contains an invalid snapshot path or size.",
                nil);
        }
        NSArray<NSString *> *components =
            [path componentsSeparatedByString:@"/"];
        if (components.count == 0 ||
            components.count > limits.maximumPathDepth) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorLimitExceeded,
                @"A snapshot path exceeds the configured depth limit.", nil);
        }
        NSMutableArray<NSString *> *prefix = [NSMutableArray array];
        for (NSUInteger index = 0; index < components.count; index++) {
            NSString *component = components[index];
            if (!MTDirectorySnapshotComponentIsSafe(component)) {
                return MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorLimitExceeded,
                    @"The audited directory contains an unsafe path component.",
                    nil);
            }
            [prefix addObject:component];
            NSString *prefixPath = [prefix componentsJoinedByString:@"/"];
            BOOL isDirectory = index + 1 < components.count;
            if (!MTDirectorySnapshotRegisterInventoryPath(prefixPath,
                    isDirectory, paths, directoryKinds, limits, &nodeCount,
                    error)) {
                return NO;
            }
        }
        totalBytes += file.byteCount;
    }
    if (totalBytes != inventory.totalBytes) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"The audited directory byte total is inconsistent.", nil);
    }
    return YES;
}

BOOL MTDirectorySnapshotHasSpace(
    int descriptor,
    uint64_t bytes,
    uint64_t reserve,
    NSError **error) {
    if (bytes > UINT64_MAX - reserve) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"The directory snapshot space requirement overflows its policy.",
            nil);
    }
    struct statfs filesystem = {0};
    if (fstatfs(descriptor, &filesystem) != 0) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorStorage,
            @"Unable to inspect free space for the directory snapshot.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    uint64_t blocks = filesystem.f_bavail < 0
        ? 0 : (uint64_t)filesystem.f_bavail;
    uint64_t blockSize = filesystem.f_bsize < 0
        ? 0 : (uint64_t)filesystem.f_bsize;
    uint64_t available = blockSize != 0 &&
        blocks > UINT64_MAX / blockSize
            ? UINT64_MAX : blocks * blockSize;
    if (bytes + reserve > available) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorLimitExceeded,
            @"The private volume lacks space for a complete directory snapshot.",
            nil);
    }
    return YES;
}

static BOOL MTDirectorySnapshotWriteAll(int descriptor,
                                        const void *bytes,
                                        NSUInteger length,
                                        NSError **error) {
    const unsigned char *cursor = bytes;
    NSUInteger written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, cursor + written,
                               length - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorIO,
                @"Unable to write an App-owned snapshot file.",
                MTDirectorySnapshotPOSIXError(result == 0 ? EIO : errno));
        }
        written += (NSUInteger)result;
    }
    return YES;
}

static int MTOpenDirectorySnapshotParent(
    int treeDescriptor,
    NSArray<NSString *> *components,
    NSError **error) {
    int parent = openat(treeDescriptor, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (parent < 0) {
        MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorStorage,
            @"Unable to open the private snapshot tree.",
            MTDirectorySnapshotPOSIXError(errno));
        return -1;
    }
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        const char *name = components[index].fileSystemRepresentation;
        struct stat pathStatus = {0};
        BOOL created = NO;
        if (fstatat(parent, name, &pathStatus, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) {
                int savedError = errno;
                close(parent);
                MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorStorage,
                    @"Unable to inspect a private snapshot directory.",
                    MTDirectorySnapshotPOSIXError(savedError));
                return -1;
            }
            if (mkdirat(parent, name, 0700) != 0) {
                int savedError = errno;
                close(parent);
                MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorStorage,
                    @"Unable to create a private snapshot directory.",
                    MTDirectorySnapshotPOSIXError(savedError));
                return -1;
            }
            created = YES;
            if (fsync(parent) != 0) {
                int savedError = errno;
                close(parent);
                MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorStorage,
                    @"Unable to synchronize a private snapshot directory.",
                    MTDirectorySnapshotPOSIXError(savedError));
                return -1;
            }
            if (fstatat(parent, name, &pathStatus,
                        AT_SYMLINK_NOFOLLOW) != 0) {
                int savedError = errno;
                close(parent);
                MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorStorage,
                    @"Unable to verify a new private snapshot directory.",
                    MTDirectorySnapshotPOSIXError(savedError));
                return -1;
            }
        }
        if (!S_ISDIR(pathStatus.st_mode) ||
            pathStatus.st_uid != geteuid()) {
            close(parent);
            MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"A private snapshot path is not an owned directory.", nil);
            return -1;
        }
        int child = openat(parent, name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat opened = {0};
        if (child < 0 || fstat(child, &opened) != 0 ||
            !MTDirectorySnapshotStatusesMatch(&pathStatus, &opened) ||
            !S_ISDIR(opened.st_mode) || opened.st_uid != geteuid() ||
            (opened.st_mode & 0777) != 0700) {
            int savedError = errno;
            if (child >= 0) close(child);
            close(parent);
            MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                created
                    ? @"A new snapshot directory failed verification."
                    : @"A snapshot directory changed while being opened.",
                savedError == 0 ? nil :
                    MTDirectorySnapshotPOSIXError(savedError));
            return -1;
        }
        close(parent);
        parent = child;
    }
    return parent;
}

BOOL MTDirectorySnapshotCopyInventory(
    id<MTAuditedSource> source,
    int partialDescriptor,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    for (MTSourceFile *file in source.inventory.files) {
        if (cancellationToken.isCancelled) {
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCancelled,
                @"The directory snapshot was cancelled between files.", nil);
        }
        NSArray<NSString *> *components =
            [file.relativePath componentsSeparatedByString:@"/"];
        int parent = MTOpenDirectorySnapshotParent(
            partialDescriptor, components, error);
        if (parent < 0) return NO;
        NSString *filename = components.lastObject;
        int destination = openat(parent, filename.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (destination < 0) {
            int savedError = errno;
            close(parent);
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorStorage,
                @"Unable to create a private snapshot file.",
                MTDirectorySnapshotPOSIXError(savedError));
        }
        __block uint64_t copied = 0;
        __block NSError *consumerError = nil;
        BOOL streamed = [source
            streamFileAtRelativePath:file.relativePath
                    maximumByteCount:file.byteCount
                   cancellationToken:cancellationToken
                        byteConsumer:^BOOL(const void *bytes,
                                           NSUInteger length,
                                           NSError **streamError) {
            if ((uint64_t)length > file.byteCount - copied) {
                consumerError = MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorSourceRejected,
                    @"An audited source emitted more bytes than its inventory.",
                    nil);
                if (streamError != NULL) *streamError = consumerError;
                return NO;
            }
            NSError *writeError = nil;
            if (!MTDirectorySnapshotWriteAll(destination, bytes, length,
                                              &writeError)) {
                consumerError = writeError;
                if (streamError != NULL) *streamError = writeError;
                return NO;
            }
            copied += (uint64_t)length;
            return YES;
        }
                               error:&consumerError];
        BOOL success = streamed && copied == file.byteCount;
        if (success && cancellationToken.isCancelled) {
            consumerError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorCancelled,
                @"The directory snapshot was cancelled before file publication.",
                nil);
            success = NO;
        }
        if (success && (fchmod(destination, 0600) != 0 ||
                        fsync(destination) != 0)) {
            consumerError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorIO,
                @"Unable to protect or synchronize a snapshot file.",
                MTDirectorySnapshotPOSIXError(errno));
            success = NO;
        }
        struct stat status = {0};
        if (success && (fstat(destination, &status) != 0 ||
            !S_ISREG(status.st_mode) || status.st_nlink != 1 ||
            status.st_uid != geteuid() ||
            (status.st_mode & 0777) != 0600 || status.st_size < 0 ||
            (uint64_t)status.st_size != file.byteCount)) {
            consumerError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorDestinationVerification,
                @"A snapshot file failed final metadata verification.", nil);
            success = NO;
        }
        close(destination);
        if (success && fsync(parent) != 0) {
            consumerError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorIO,
                @"Unable to synchronize a snapshot file entry.",
                MTDirectorySnapshotPOSIXError(errno));
            success = NO;
        }
        close(parent);
        if (!success) {
            if (consumerError != nil &&
                [consumerError.domain isEqualToString:
                    MTAuditedSourceErrorDomain] &&
                consumerError.code == MTAuditedSourceErrorCancelled) {
                consumerError = MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorCancelled,
                    @"The audited directory stream was cancelled.",
                    consumerError);
            } else if (consumerError == nil) {
                consumerError = MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorSourceRejected,
                    @"The audited directory stream did not match its inventory.",
                    nil);
            } else if (![consumerError.domain isEqualToString:
                           MTDirectorySnapshotSessionErrorDomain]) {
                consumerError = MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorSourceRejected,
                    @"The audited directory rejected snapshot materialization.",
                    consumerError);
            }
            if (error != NULL) *error = consumerError;
            return NO;
        }
    }
    if (fsync(partialDescriptor) != 0) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorIO,
            @"Unable to synchronize the complete unpublished snapshot.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    return YES;
}

typedef struct {
    NSUInteger nodeCount;
    NSUInteger fileCount;
    uint64_t byteCount;
} MTDirectorySnapshotCleanupBudget;

static BOOL MTDirectorySnapshotRemoveTree(
    int directoryDescriptor,
    NSUInteger depth,
    NSUInteger pathUTF8Bytes,
    MTDirectorySnapshotConfiguration *configuration,
    MTDirectorySnapshotCleanupBudget *budget,
    NSError **error) {
    int enumerationDescriptor = openat(directoryDescriptor, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to enumerate a directory-snapshot tree for cleanup.",
            MTDirectorySnapshotPOSIXError(savedError));
    }
    BOOL success = YES;
    while (success) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"Directory-snapshot cleanup enumeration failed.",
                    MTDirectorySnapshotPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        NSString *component = [[NSString alloc]
            initWithBytes:entry->d_name
                   length:strlen(entry->d_name)
                 encoding:NSUTF8StringEncoding];
        NSUInteger componentBytes = [component
            lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger separatorBytes = pathUTF8Bytes == 0 ? 0 : 1;
        BOOL pathOverflows = componentBytes >
            NSUIntegerMax - separatorBytes ||
            pathUTF8Bytes >
                NSUIntegerMax - separatorBytes - componentBytes;
        NSUInteger nextPathBytes = pathOverflows
            ? NSUIntegerMax
            : pathUTF8Bytes + separatorBytes + componentBytes;
        if (!MTDirectorySnapshotComponentIsSafe(component) ||
            ![component isEqualToString:
                component.precomposedStringWithCanonicalMapping] ||
            depth + 1 > configuration.limits.maximumPathDepth ||
            pathOverflows || nextPathBytes >
                configuration.limits.maximumPathUTF8Bytes ||
            budget->nodeCount >=
                configuration.limits.maximumArchiveEntries) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"An abandoned snapshot tree exceeds its safe cleanup shape.",
                nil);
            break;
        }
        budget->nodeCount++;
        struct stat pathStatus = {0};
        if (fstatat(directoryDescriptor, entry->d_name, &pathStatus,
                    AT_SYMLINK_NOFOLLOW) != 0) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"Unable to inspect an abandoned snapshot node.",
                MTDirectorySnapshotPOSIXError(errno));
            break;
        }
        if (S_ISDIR(pathStatus.st_mode)) {
            if (pathStatus.st_uid != geteuid() ||
                (pathStatus.st_mode & 0777) != 0700) {
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"An abandoned snapshot contains an unsafe directory.",
                    nil);
                break;
            }
            int child = openat(directoryDescriptor, entry->d_name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            struct stat opened = {0};
            if (child < 0 || fstat(child, &opened) != 0 ||
                !MTDirectorySnapshotStatusesMatch(&pathStatus, &opened)) {
                int savedError = errno;
                if (child >= 0) close(child);
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"An abandoned snapshot directory changed before cleanup.",
                    savedError == 0 ? nil :
                        MTDirectorySnapshotPOSIXError(savedError));
                break;
            }
            success = MTDirectorySnapshotRemoveTree(child, depth + 1,
                nextPathBytes, configuration, budget, error);
            close(child);
            if (success && unlinkat(directoryDescriptor, entry->d_name,
                                    AT_REMOVEDIR) != 0) {
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"Unable to remove an empty snapshot directory.",
                    MTDirectorySnapshotPOSIXError(errno));
            }
            continue;
        }
        if (!S_ISREG(pathStatus.st_mode) || pathStatus.st_nlink != 1 ||
            pathStatus.st_uid != geteuid() ||
            (pathStatus.st_mode & 0777) != 0600 ||
            pathStatus.st_size < 0 ||
            budget->fileCount >= configuration.limits.maximumRegularFiles ||
            (uint64_t)pathStatus.st_size >
                configuration.limits.maximumSingleFileBytes ||
            (uint64_t)pathStatus.st_size >
                configuration.limits.maximumExpandedBytes -
                    budget->byteCount) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"An abandoned snapshot contains an unsafe file node.", nil);
            break;
        }
        budget->fileCount++;
        budget->byteCount += (uint64_t)pathStatus.st_size;
        if (unlinkat(directoryDescriptor, entry->d_name, 0) != 0) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"Unable to remove an abandoned snapshot file.",
                MTDirectorySnapshotPOSIXError(errno));
        }
    }
    closedir(directory);
    return success;
}

BOOL MTDiscardDirectorySnapshotAtRootDescriptor(
    int rootDescriptor,
    NSString *sessionIdentifier,
    uint64_t expectedDevice,
    uint64_t expectedInode,
    MTDirectorySnapshotConfiguration *configuration,
    NSError **error) {
    if (!MTDirectorySnapshotIdentifierIsCanonical(sessionIdentifier)) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Refusing to clean a non-canonical directory snapshot.", nil);
    }
    const char *sessionName = sessionIdentifier.fileSystemRepresentation;
    struct stat pathStatus = {0};
    if (fstatat(rootDescriptor, sessionName, &pathStatus,
                AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return YES;
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to inspect a directory-snapshot session before cleanup.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    if (!S_ISDIR(pathStatus.st_mode) || pathStatus.st_uid != geteuid() ||
        (pathStatus.st_mode & 0777) != 0700 ||
        (expectedDevice != 0 &&
         ((uint64_t)pathStatus.st_dev != expectedDevice ||
          (uint64_t)pathStatus.st_ino != expectedInode))) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"The directory-snapshot session has an unsafe identity.", nil);
    }
    int session = openat(rootDescriptor, sessionName,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {0};
    if (session < 0 || fstat(session, &opened) != 0 ||
        !MTDirectorySnapshotStatusesMatch(&pathStatus, &opened)) {
        int savedError = errno;
        if (session >= 0) close(session);
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"The directory-snapshot session changed before cleanup.",
            savedError == 0 ? nil :
                MTDirectorySnapshotPOSIXError(savedError));
    }

    int enumerationDescriptor = openat(session, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        close(session);
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to enumerate a directory-snapshot session.",
            MTDirectorySnapshotPOSIXError(savedError));
    }
    NSString *treeName = nil;
    BOOL success = YES;
    while (success) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"Directory-snapshot session enumeration failed.",
                    MTDirectorySnapshotPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        BOOL known = strcmp(entry->d_name,
                            MTDirectorySnapshotPartialName) == 0 ||
            strcmp(entry->d_name, MTDirectorySnapshotPublishedName) == 0;
        if (!known || treeName != nil) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"A directory-snapshot session contains an unknown root node.",
                nil);
            break;
        }
        treeName = [NSString stringWithUTF8String:entry->d_name];
    }
    closedir(directory);

    if (success && treeName != nil) {
        struct stat treeStatus = {0};
        if (fstatat(session, treeName.fileSystemRepresentation, &treeStatus,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(treeStatus.st_mode) ||
            treeStatus.st_uid != geteuid() ||
            (treeStatus.st_mode & 0777) != 0700) {
            success = MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"The snapshot tree root is unsafe for cleanup.", nil);
        } else {
            int tree = openat(session, treeName.fileSystemRepresentation,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            struct stat treeOpened = {0};
            if (tree < 0 || fstat(tree, &treeOpened) != 0 ||
                !MTDirectorySnapshotStatusesMatch(&treeStatus, &treeOpened)) {
                int savedError = errno;
                if (tree >= 0) close(tree);
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"The snapshot tree root changed before cleanup.",
                    savedError == 0 ? nil :
                        MTDirectorySnapshotPOSIXError(savedError));
            } else {
                MTDirectorySnapshotCleanupBudget budget = {0};
                success = MTDirectorySnapshotRemoveTree(tree, 0, 0,
                    configuration, &budget, error);
                close(tree);
                if (success && unlinkat(session,
                        treeName.fileSystemRepresentation,
                        AT_REMOVEDIR) != 0) {
                    success = MTDirectorySnapshotSetError(error,
                        MTDirectorySnapshotSessionErrorCleanup,
                        @"Unable to remove the empty snapshot tree root.",
                        MTDirectorySnapshotPOSIXError(errno));
                }
            }
        }
    }
    if (success && fsync(session) != 0) {
        success = MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to synchronize directory-snapshot cleanup.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    close(session);
    if (success && unlinkat(rootDescriptor, sessionName,
                            AT_REMOVEDIR) != 0) {
        success = MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to remove the empty directory-snapshot session.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    if (success && fsync(rootDescriptor) != 0) {
        success = MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to synchronize the directory-snapshot root cleanup.",
            MTDirectorySnapshotPOSIXError(errno));
    }
    return success;
}
