#import "MTImportSession.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

NSString *const MTImportSessionErrorDomain =
    @"com.hmmzzz.marktheme.import-session";

static NSString *const MTImportSessionDirectoryPrefix = @"session-";
static const char *MTImportSessionPayloadName = "source.payload";
static const char *MTImportSessionPartialName = ".source.payload.partial";

@interface MTImportCancellationToken ()
@property(atomic, assign, readwrite, getter=isCancelled) BOOL cancelled;
@end

@implementation MTImportCancellationToken

- (void)cancel {
    self.cancelled = YES;
}

@end

@implementation MTImportSessionConfiguration

+ (instancetype)defaultConfiguration {
    NSString *temporaryDirectory = NSTemporaryDirectory();
    NSAssert(temporaryDirectory.length > 0,
             @"The application temporary directory must be available.");
    NSURL *rootURL = [[NSURL fileURLWithPath:temporaryDirectory isDirectory:YES]
        URLByAppendingPathComponent:@"com.hmmzzz.marktheme.import-sessions"
                         isDirectory:YES];
    return [[self alloc] initWithSessionsRootURL:rootURL
                                         limits:MTImportLimits.defaultLimits];
}

- (instancetype)initWithSessionsRootURL:(NSURL *)sessionsRootURL
                                  limits:(MTImportLimits *)limits {
    NSParameterAssert(sessionsRootURL.isFileURL);
    NSParameterAssert(sessionsRootURL.path.length > 0);
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _sessionsRootURL = [sessionsRootURL copy];
    _limits = limits;
    return self;
}

@end

static NSError *MTImportPOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

static BOOL MTImportSetError(NSError **error,
                             MTImportSessionErrorCode code,
                             NSString *description,
                             NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTImportSessionErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTImportSessionIdentifierIsCanonical(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier hasPrefix:MTImportSessionDirectoryPrefix]) {
        return NO;
    }
    NSString *suffix = [identifier
        substringFromIndex:MTImportSessionDirectoryPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:suffix];
    return uuid != nil &&
        [uuid.UUIDString.lowercaseString isEqualToString:suffix];
}

static BOOL MTImportStatIsStable(const struct stat *before,
                                 const struct stat *after) {
    return before->st_dev == after->st_dev &&
        before->st_ino == after->st_ino &&
        before->st_mode == after->st_mode &&
        before->st_size == after->st_size &&
        before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
        before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec &&
        before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
        before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec;
}

static BOOL MTOpenImportSessionsRoot(
    MTImportSessionConfiguration *configuration,
    BOOL createIfMissing,
    int *rootDescriptor,
    struct stat *rootStatus,
    NSError **error) {
    NSString *path = configuration.sessionsRootURL.path.stringByStandardizingPath;
    if (path.length == 0 || ![path isEqualToString:configuration.sessionsRootURL.path]) {
        return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
            @"The import-session root is not a canonical local path.", nil);
    }

    struct stat pathStatus = {0};
    if (lstat(path.fileSystemRepresentation, &pathStatus) != 0) {
        int savedError = errno;
        if (savedError == ENOENT && !createIfMissing) {
            if (rootDescriptor != NULL) *rootDescriptor = -1;
            return YES;
        }
        int creationResult = savedError == ENOENT
            ? mkdir(path.fileSystemRepresentation, 0700) : -1;
        if (savedError != ENOENT ||
            (creationResult != 0 && errno != EEXIST)) {
            int finalError = savedError == ENOENT ? errno : savedError;
            return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
                @"Unable to create the import-session root.",
                MTImportPOSIXError(finalError));
        }
    }

    int descriptor = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
            @"Unable to open the import-session root without following links.",
            MTImportPOSIXError(errno));
    }
    struct stat openedStatus = {0};
    if (fstat(descriptor, &openedStatus) != 0 ||
        !S_ISDIR(openedStatus.st_mode) || openedStatus.st_uid != geteuid()) {
        int savedError = errno;
        close(descriptor);
        return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
            @"The import-session root has an unsafe type or owner.",
            savedError == 0 ? nil : MTImportPOSIXError(savedError));
    }
    if (fchmod(descriptor, 0700) != 0) {
        int savedError = errno;
        close(descriptor);
        return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
            @"Unable to protect the import-session root.",
            MTImportPOSIXError(savedError));
    }
    if (rootDescriptor != NULL) *rootDescriptor = descriptor;
    if (rootStatus != NULL) *rootStatus = openedStatus;
    return YES;
}

static BOOL MTCreateImportSessionDirectory(int rootDescriptor,
                                           NSString **sessionIdentifier,
                                           int *sessionDescriptor,
                                           NSError **error) {
    for (NSUInteger attempt = 0; attempt < 8; attempt++) {
        NSString *identifier = [MTImportSessionDirectoryPrefix
            stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        const char *name = identifier.fileSystemRepresentation;
        if (mkdirat(rootDescriptor, name, 0700) != 0) {
            if (errno == EEXIST) continue;
            return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
                @"Unable to create a private import session.",
                MTImportPOSIXError(errno));
        }
        int descriptor = openat(rootDescriptor, name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            int savedError = errno;
            unlinkat(rootDescriptor, name, AT_REMOVEDIR);
            return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
                @"Unable to open the new import session safely.",
                MTImportPOSIXError(savedError));
        }
        struct stat status = {0};
        if (fstat(descriptor, &status) != 0 || !S_ISDIR(status.st_mode) ||
            status.st_uid != geteuid() || fchmod(descriptor, 0700) != 0) {
            int savedError = errno;
            close(descriptor);
            unlinkat(rootDescriptor, name, AT_REMOVEDIR);
            return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
                @"The new import session has an unsafe type or owner.",
                savedError == 0 ? nil : MTImportPOSIXError(savedError));
        }
        *sessionIdentifier = identifier;
        *sessionDescriptor = descriptor;
        return YES;
    }
    return MTImportSetError(error, MTImportSessionErrorTemporaryStorage,
        @"Unable to allocate a unique import-session identifier.", nil);
}

static BOOL MTWriteAll(int descriptor,
                       const unsigned char *bytes,
                       size_t length,
                       NSError **error) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) {
            return MTImportSetError(error, MTImportSessionErrorIO,
                @"Unable to write the private import copy.",
                MTImportPOSIXError(result == 0 ? EIO : errno));
        }
        written += (size_t)result;
    }
    return YES;
}

static BOOL MTCopyCoordinatedImportSource(
    NSURL *sourceURL,
    int sessionDescriptor,
    uint64_t maximumBytes,
    MTImportCancellationToken *_Nullable cancellationToken,
    uint64_t *copiedBytes,
    NSError **error) {
    if (cancellationToken.isCancelled) {
        return MTImportSetError(error, MTImportSessionErrorCancelled,
            @"The import was cancelled before the source was read.", nil);
    }

    int sourceDescriptor = open(sourceURL.path.fileSystemRepresentation,
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (sourceDescriptor < 0) {
        return MTImportSetError(error, MTImportSessionErrorInvalidSource,
            @"The selected item is not a safely readable regular file.",
            MTImportPOSIXError(errno));
    }
    struct stat sourceBefore = {0};
    if (fstat(sourceDescriptor, &sourceBefore) != 0 ||
        !S_ISREG(sourceBefore.st_mode) || sourceBefore.st_size <= 0) {
        int savedError = errno;
        close(sourceDescriptor);
        return MTImportSetError(error, MTImportSessionErrorInvalidSource,
            @"The selected item is not a non-empty regular file.",
            savedError == 0 ? nil : MTImportPOSIXError(savedError));
    }
    if ((uint64_t)sourceBefore.st_size > maximumBytes) {
        close(sourceDescriptor);
        return MTImportSetError(error, MTImportSessionErrorLimitExceeded,
            @"The selected file exceeds the configured import limit.", nil);
    }

    int destinationDescriptor = openat(sessionDescriptor,
        MTImportSessionPartialName,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (destinationDescriptor < 0) {
        int savedError = errno;
        close(sourceDescriptor);
        return MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to create the private import copy.",
            MTImportPOSIXError(savedError));
    }
    BOOL success = fchmod(destinationDescriptor, 0600) == 0;
    if (!success) {
        MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to protect the private import copy.",
            MTImportPOSIXError(errno));
    }

    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    while (success) {
        if (cancellationToken.isCancelled) {
            success = MTImportSetError(error, MTImportSessionErrorCancelled,
                @"The import was cancelled while the source was being copied.", nil);
            break;
        }
        ssize_t count = read(sourceDescriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            success = MTImportSetError(error, MTImportSessionErrorIO,
                @"Unable to read the selected file.", MTImportPOSIXError(errno));
            break;
        }
        if (count == 0) break;
        if ((uint64_t)count > maximumBytes - total) {
            success = MTImportSetError(error, MTImportSessionErrorLimitExceeded,
                @"The selected file grew beyond the configured import limit.", nil);
            break;
        }
        success = MTWriteAll(destinationDescriptor, buffer, (size_t)count, error);
        if (success) total += (uint64_t)count;
    }

    struct stat sourceAfter = {0};
    struct stat destinationStatus = {0};
    if (success && fstat(sourceDescriptor, &sourceAfter) != 0) {
        success = MTImportSetError(error, MTImportSessionErrorSourceChanged,
            @"Unable to verify the selected file after copying.",
            MTImportPOSIXError(errno));
    }
    if (success &&
        (!MTImportStatIsStable(&sourceBefore, &sourceAfter) ||
         total != (uint64_t)sourceBefore.st_size)) {
        success = MTImportSetError(error, MTImportSessionErrorSourceChanged,
            @"The selected file changed while it was being copied.", nil);
    }
    if (success && cancellationToken.isCancelled) {
        success = MTImportSetError(error, MTImportSessionErrorCancelled,
            @"The import was cancelled before its private copy was published.", nil);
    }
    if (success && fsync(destinationDescriptor) != 0) {
        success = MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to synchronize the private import copy.",
            MTImportPOSIXError(errno));
    }
    if (success && fstat(destinationDescriptor, &destinationStatus) != 0) {
        success = MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to inspect the private import copy.",
            MTImportPOSIXError(errno));
    }
    if (success &&
        (!S_ISREG(destinationStatus.st_mode) || destinationStatus.st_nlink != 1 ||
         destinationStatus.st_uid != geteuid() ||
         (destinationStatus.st_mode & 0777) != 0600 ||
         (uint64_t)destinationStatus.st_size != total)) {
        success = MTImportSetError(error, MTImportSessionErrorIO,
            @"The private import copy failed final verification.", nil);
    }

    close(destinationDescriptor);
    close(sourceDescriptor);
    if (success && renameat(sessionDescriptor, MTImportSessionPartialName,
                            sessionDescriptor, MTImportSessionPayloadName) != 0) {
        success = MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to publish the private import copy atomically.",
            MTImportPOSIXError(errno));
    }
    if (success && fsync(sessionDescriptor) != 0) {
        success = MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to synchronize the private import session.",
            MTImportPOSIXError(errno));
    }
    if (!success) {
        unlinkat(sessionDescriptor, MTImportSessionPartialName, 0);
        unlinkat(sessionDescriptor, MTImportSessionPayloadName, 0);
        return NO;
    }
    if (copiedBytes != NULL) *copiedBytes = total;
    return YES;
}

static BOOL MTValidateOwnedSessionFile(int sessionDescriptor,
                                       const char *name,
                                       NSError **error) {
    struct stat status = {0};
    if (fstatat(sessionDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to inspect a file in an abandoned import session.",
            MTImportPOSIXError(errno));
    }
    if (!S_ISREG(status.st_mode) || status.st_nlink != 1 ||
        status.st_uid != geteuid() || (status.st_mode & 0077) != 0) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"An abandoned import session contains an unsafe node.", nil);
    }
    return YES;
}

static BOOL MTDiscardSessionAtRootDescriptor(int rootDescriptor,
                                             NSString *sessionIdentifier,
                                             NSError **error) {
    if (!MTImportSessionIdentifierIsCanonical(sessionIdentifier)) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Refusing to clean a path that is not an owned import session.", nil);
    }
    const char *name = sessionIdentifier.fileSystemRepresentation;
    struct stat pathStatus = {0};
    if (fstatat(rootDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return YES;
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to inspect the import session before cleanup.",
            MTImportPOSIXError(errno));
    }
    if (!S_ISDIR(pathStatus.st_mode) || pathStatus.st_uid != geteuid()) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"The import session to clean has an unsafe type or owner.", nil);
    }

    int sessionDescriptor = openat(rootDescriptor, name,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (sessionDescriptor < 0) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to open the import session for cleanup.",
            MTImportPOSIXError(errno));
    }
    struct stat openedStatus = {0};
    if (fstat(sessionDescriptor, &openedStatus) != 0 ||
        openedStatus.st_dev != pathStatus.st_dev ||
        openedStatus.st_ino != pathStatus.st_ino ||
        !S_ISDIR(openedStatus.st_mode) || openedStatus.st_uid != geteuid()) {
        close(sessionDescriptor);
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"The import session changed before cleanup.", nil);
    }

    int enumerationDescriptor = dup(sessionDescriptor);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        close(sessionDescriptor);
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to enumerate the import session for cleanup.",
            MTImportPOSIXError(savedError));
    }

    BOOL hasPayload = NO;
    BOOL hasPartial = NO;
    BOOL valid = YES;
    while (valid) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                valid = MTImportSetError(error, MTImportSessionErrorCleanup,
                    @"Import-session cleanup enumeration failed.",
                    MTImportPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (strcmp(entry->d_name, MTImportSessionPayloadName) == 0) {
            hasPayload = YES;
        } else if (strcmp(entry->d_name, MTImportSessionPartialName) == 0) {
            hasPartial = YES;
        } else {
            valid = MTImportSetError(error, MTImportSessionErrorCleanup,
                @"Refusing to recursively delete an unexpected session entry.", nil);
            break;
        }
        valid = MTValidateOwnedSessionFile(sessionDescriptor, entry->d_name, error);
    }
    closedir(directory);

    if (valid && hasPayload &&
        unlinkat(sessionDescriptor, MTImportSessionPayloadName, 0) != 0) {
        valid = MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to remove the private import copy.", MTImportPOSIXError(errno));
    }
    if (valid && hasPartial &&
        unlinkat(sessionDescriptor, MTImportSessionPartialName, 0) != 0) {
        valid = MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to remove an incomplete private import copy.",
            MTImportPOSIXError(errno));
    }
    close(sessionDescriptor);
    if (valid && unlinkat(rootDescriptor, name, AT_REMOVEDIR) != 0) {
        valid = MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to remove the empty import-session directory.",
            MTImportPOSIXError(errno));
    }
    return valid;
}

@interface MTImportSession ()
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(nonatomic, copy, readwrite) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readwrite) NSURL *payloadURL;
@property(nonatomic, assign, readwrite) uint64_t byteCount;
@property(nonatomic, strong) MTImportSessionConfiguration *configuration;
@property(nonatomic, assign) uint64_t rootDevice;
@property(nonatomic, assign) uint64_t rootInode;
@property(nonatomic, assign) BOOL discarded;
- (instancetype)initWithIdentifier:(NSString *)identifier
                      configuration:(MTImportSessionConfiguration *)configuration
                         rootStatus:(const struct stat *)rootStatus
                          byteCount:(uint64_t)byteCount;
@end

@implementation MTImportSession

- (instancetype)initWithIdentifier:(NSString *)identifier
                      configuration:(MTImportSessionConfiguration *)configuration
                         rootStatus:(const struct stat *)rootStatus
                          byteCount:(uint64_t)byteCount {
    self = [super init];
    if (self == nil) return nil;
    _sessionIdentifier = [identifier copy];
    _configuration = configuration;
    _sessionDirectoryURL = [configuration.sessionsRootURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    _payloadURL = [_sessionDirectoryURL
        URLByAppendingPathComponent:@"source.payload" isDirectory:NO];
    _byteCount = byteCount;
    _rootDevice = (uint64_t)rootStatus->st_dev;
    _rootInode = (uint64_t)rootStatus->st_ino;
    return self;
}

+ (instancetype)sessionByImportingFileAtURL:(NSURL *)sourceURL
                               configuration:(MTImportSessionConfiguration *)configuration
                           cancellationToken:(MTImportCancellationToken *)cancellationToken
                                       error:(NSError **)error {
    if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL ||
        sourceURL.path.length == 0 ||
        ![configuration isKindOfClass:MTImportSessionConfiguration.class]) {
        MTImportSetError(error, MTImportSessionErrorInvalidSource,
            @"Import requires a local file URL and a valid configuration.", nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTImportSetError(error, MTImportSessionErrorCancelled,
            @"The import was cancelled before a session was created.", nil);
        return nil;
    }

    int rootDescriptor = -1;
    struct stat rootStatus = {0};
    if (!MTOpenImportSessionsRoot(configuration, YES, &rootDescriptor,
                                  &rootStatus, error)) {
        return nil;
    }
    NSString *sessionIdentifier = nil;
    int sessionDescriptor = -1;
    if (!MTCreateImportSessionDirectory(rootDescriptor, &sessionIdentifier,
                                        &sessionDescriptor, error)) {
        close(rootDescriptor);
        return nil;
    }

    __block NSError *copyError = nil;
    __block uint64_t copiedBytes = 0;
    __block BOOL accessorInvoked = NO;
    NSError *coordinationError = nil;
    BOOL coordinateSourceRead = YES;
#if MT_HOST_TESTING
    coordinateSourceRead = NO;
#endif
    if (!coordinateSourceRead) {
    // The command-line contract runner has no application/file-provider
    // coordination context on current macOS. It exercises the exact accessor
    // and descriptor path against private fixtures; production always takes
    // the security-scoped NSFileCoordinator branch below.
        accessorInvoked = YES;
        MTCopyCoordinatedImportSource(sourceURL, sessionDescriptor,
            configuration.limits.maximumSourceBytes,
            cancellationToken, &copiedBytes, &copyError);
    } else {
        BOOL securityScopeAccessed =
            [sourceURL startAccessingSecurityScopedResource];
        NSFileCoordinator *coordinator =
            [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        @try {
            [coordinator coordinateReadingItemAtURL:sourceURL
                                            options:NSFileCoordinatorReadingWithoutChanges
                                         error:&coordinationError
                                     byAccessor:^(NSURL *coordinatedURL) {
                accessorInvoked = YES;
                MTCopyCoordinatedImportSource(coordinatedURL, sessionDescriptor,
                    configuration.limits.maximumSourceBytes,
                    cancellationToken, &copiedBytes, &copyError);
            }];
        } @catch (__unused NSException *exception) {
            coordinationError = [NSError errorWithDomain:MTImportSessionErrorDomain
                code:MTImportSessionErrorCoordination
            userInfo:@{NSLocalizedDescriptionKey :
                @"File coordination raised an exception."}];
        } @finally {
            if (securityScopeAccessed) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
        }
    }

    if (!accessorInvoked && coordinationError == nil) {
        coordinationError = [NSError errorWithDomain:MTImportSessionErrorDomain
            code:MTImportSessionErrorCoordination
        userInfo:@{NSLocalizedDescriptionKey :
            @"File coordination completed without providing the source."}];
    }

    close(sessionDescriptor);
    if (coordinationError != nil || copyError != nil) {
        MTDiscardSessionAtRootDescriptor(rootDescriptor, sessionIdentifier, NULL);
        close(rootDescriptor);
        if (error != NULL) {
            *error = copyError ?: [NSError errorWithDomain:MTImportSessionErrorDomain
                code:MTImportSessionErrorCoordination
            userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Unable to coordinate a read of the selected file.",
                NSUnderlyingErrorKey : coordinationError,
            }];
        }
        return nil;
    }
    if (fsync(rootDescriptor) != 0) {
        NSError *syncError = MTImportPOSIXError(errno);
        MTDiscardSessionAtRootDescriptor(rootDescriptor, sessionIdentifier, NULL);
        close(rootDescriptor);
        MTImportSetError(error, MTImportSessionErrorIO,
            @"Unable to synchronize the import-session root.", syncError);
        return nil;
    }

    close(rootDescriptor);
    return [[self alloc] initWithIdentifier:sessionIdentifier
                              configuration:configuration
                                 rootStatus:&rootStatus
                                  byteCount:copiedBytes];
}

+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTImportSessionConfiguration *)configuration
                                             error:(NSError **)error {
    if (![configuration isKindOfClass:MTImportSessionConfiguration.class]) {
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"A valid import-session configuration is required.", nil);
    }
    int rootDescriptor = -1;
    if (!MTOpenImportSessionsRoot(configuration, NO, &rootDescriptor, NULL, error)) {
        return NO;
    }
    if (rootDescriptor < 0) return YES;

    int enumerationDescriptor = dup(rootDescriptor);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        close(rootDescriptor);
        return MTImportSetError(error, MTImportSessionErrorCleanup,
            @"Unable to enumerate abandoned import sessions.",
            MTImportPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *ownedIdentifiers = [NSMutableArray array];
    BOOL success = YES;
    while (YES) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTImportSetError(error, MTImportSessionErrorCleanup,
                    @"Import-session root enumeration failed.",
                    MTImportPOSIXError(errno));
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        NSString *identifier = [[NSString alloc]
            initWithBytes:entry->d_name
                   length:strlen(entry->d_name)
                 encoding:NSUTF8StringEncoding];
        if (MTImportSessionIdentifierIsCanonical(identifier)) {
            [ownedIdentifiers addObject:identifier];
        }
    }
    closedir(directory);
    if (success) {
        for (NSString *identifier in ownedIdentifiers) {
            if (!MTDiscardSessionAtRootDescriptor(rootDescriptor,
                                                  identifier, error)) {
                success = NO;
                break;
            }
        }
    }
    close(rootDescriptor);
    return success;
}

- (BOOL)discard:(NSError **)error {
    @synchronized (self) {
        if (self.discarded) return YES;
        int rootDescriptor = -1;
        struct stat rootStatus = {0};
        if (!MTOpenImportSessionsRoot(self.configuration, NO, &rootDescriptor,
                                      &rootStatus, error)) {
            return NO;
        }
        if (rootDescriptor < 0) {
            self.discarded = YES;
            return YES;
        }
        if ((uint64_t)rootStatus.st_dev != self.rootDevice ||
            (uint64_t)rootStatus.st_ino != self.rootInode) {
            close(rootDescriptor);
            return MTImportSetError(error, MTImportSessionErrorCleanup,
                @"The import-session root changed before cleanup.", nil);
        }
        BOOL success = MTDiscardSessionAtRootDescriptor(rootDescriptor,
            self.sessionIdentifier, error);
        close(rootDescriptor);
        if (success) self.discarded = YES;
        return success;
    }
}

- (void)dealloc {
    [self discard:NULL];
}

@end
