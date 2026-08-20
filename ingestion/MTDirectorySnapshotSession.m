#import "MTDirectorySnapshotSession.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDirectorySnapshotFilesystem.h"
#import "MTImportSession.h"
#import "MTSourceInventory.h"

@implementation MTDirectorySnapshotConfiguration

+ (instancetype)defaultConfiguration {
    MTImportSessionConfiguration *fileConfiguration =
        MTImportSessionConfiguration.defaultConfiguration;
    return [[self alloc]
        initWithSessionsRootURL:fileConfiguration.sessionsRootURL
                         limits:fileConfiguration.limits
           minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL];
}

- (instancetype)initWithSessionsRootURL:(NSURL *)sessionsRootURL
                                  limits:(MTImportLimits *)limits
            minimumFreeSpaceReserveBytes:
                (uint64_t)minimumFreeSpaceReserveBytes {
    NSParameterAssert(sessionsRootURL.isFileURL);
    NSParameterAssert(sessionsRootURL.path.length > 0);
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _sessionsRootURL = [sessionsRootURL copy];
    _limits = limits;
    _minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes;
    return self;
}

@end

@interface MTDirectorySnapshotSession ()
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(nonatomic, copy, readwrite) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readwrite) NSURL *snapshotDirectoryURL;
@property(nonatomic, strong, readwrite) MTSourceInventory *sourceInventory;
@property(nonatomic, strong, readwrite) id<MTAuditedSource> auditedSource;
@property(nonatomic, strong) MTDirectorySnapshotConfiguration *configuration;
@property(nonatomic, assign) uint64_t rootDevice;
@property(nonatomic, assign) uint64_t rootInode;
@property(nonatomic, assign) uint64_t sessionDevice;
@property(nonatomic, assign) uint64_t sessionInode;
@property(nonatomic, assign) BOOL discarded;
- (instancetype)initWithIdentifier:(NSString *)identifier
                       configuration:
                           (MTDirectorySnapshotConfiguration *)configuration
                          rootStatus:(const struct stat *)rootStatus
                       sessionStatus:(const struct stat *)sessionStatus
                     sourceInventory:(MTSourceInventory *)sourceInventory
                       auditedSource:(id<MTAuditedSource>)auditedSource;
@end

@implementation MTDirectorySnapshotSession

- (instancetype)initWithIdentifier:(NSString *)identifier
                       configuration:
                           (MTDirectorySnapshotConfiguration *)configuration
                          rootStatus:(const struct stat *)rootStatus
                       sessionStatus:(const struct stat *)sessionStatus
                     sourceInventory:(MTSourceInventory *)sourceInventory
                       auditedSource:(id<MTAuditedSource>)auditedSource {
    self = [super init];
    if (self == nil) return nil;
    _sessionIdentifier = [identifier copy];
    _configuration = configuration;
    _sessionDirectoryURL = [configuration.sessionsRootURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    _snapshotDirectoryURL = [_sessionDirectoryURL
        URLByAppendingPathComponent:@"snapshot" isDirectory:YES];
    _sourceInventory = sourceInventory;
    _auditedSource = auditedSource;
    _rootDevice = (uint64_t)rootStatus->st_dev;
    _rootInode = (uint64_t)rootStatus->st_ino;
    _sessionDevice = (uint64_t)sessionStatus->st_dev;
    _sessionInode = (uint64_t)sessionStatus->st_ino;
    return self;
}

- (NSUInteger)fileCount {
    return self.sourceInventory.files.count;
}

- (uint64_t)byteCount {
    return self.sourceInventory.totalBytes;
}

- (BOOL)isActive {
    @synchronized (self) {
        return !self.discarded;
    }
}

+ (instancetype)
    sessionBySnapshottingDirectoryAtURL:(NSURL *)sourceURL
                           configuration:
                               (MTDirectorySnapshotConfiguration *)configuration
                       cancellationToken:
                           (MTImportCancellationToken *)cancellationToken
                                auditor:(MTDirectorySnapshotAuditor)auditor
                                  error:(NSError **)error {
    if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL ||
        sourceURL.path.length == 0 ||
        ![configuration isKindOfClass:
            MTDirectorySnapshotConfiguration.class] || auditor == nil) {
        MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorInvalidRequest,
            @"A local directory URL, policy and synchronous auditor are required.",
            nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCancelled,
            @"The directory snapshot was cancelled before acquisition.", nil);
        return nil;
    }

    int root = -1;
    int session = -1;
    int partial = -1;
    struct stat rootStatus = {0};
    struct stat sessionStatus = {0};
    NSString *identifier = nil;
    if (!MTOpenDirectorySnapshotRoot(configuration, YES, &root,
                                     &rootStatus, error)) {
        return nil;
    }
    if (!MTCreateDirectorySnapshotSession(root, &identifier, &session,
            &partial, &sessionStatus, error)) {
        close(root);
        return nil;
    }

    __block id<MTAuditedSource> source = nil;
    __block NSError *operationError = nil;
    __block BOOL accessorInvoked = NO;
    __block BOOL copied = NO;
    void (^accessor)(NSURL *) = ^(NSURL *coordinatedURL) {
        accessorInvoked = YES;
        NSError *auditError = nil;
        source = auditor(coordinatedURL, &auditError);
        if (source == nil || ![(id)source
                conformsToProtocol:@protocol(MTAuditedSource)]) {
            operationError = MTDirectorySnapshotError(
                cancellationToken.isCancelled
                    ? MTDirectorySnapshotSessionErrorCancelled
                    : MTDirectorySnapshotSessionErrorSourceAudit,
                cancellationToken.isCancelled
                    ? @"The directory audit was cancelled."
                    : @"The selected directory did not pass source audit.",
                auditError);
            return;
        }
        if (!MTDirectorySnapshotValidateInventory(
                source.inventory, configuration.limits, &operationError) ||
            !MTDirectorySnapshotHasSpace(partial,
                source.inventory.totalBytes,
                configuration.minimumFreeSpaceReserveBytes,
                &operationError) ||
            !MTDirectorySnapshotCopyInventory(source, partial,
                cancellationToken, &operationError)) {
            return;
        }
        if (cancellationToken.isCancelled) {
            operationError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorCancelled,
                @"The directory snapshot was cancelled before publication.", nil);
            return;
        }
        if (renameatx_np(session, MTDirectorySnapshotPartialName,
                session, MTDirectorySnapshotPublishedName,
                RENAME_EXCL) != 0 || fsync(session) != 0 || fsync(root) != 0) {
            operationError = MTDirectorySnapshotError(
                MTDirectorySnapshotSessionErrorIO,
                @"Unable to publish the complete private directory snapshot.",
                MTDirectorySnapshotPOSIXError(errno));
            return;
        }
        copied = YES;
    };

    NSError *coordinationError = nil;
    BOOL coordinateSourceRead = YES;
#if MT_HOST_TESTING
    coordinateSourceRead = NO;
#endif
    if (!coordinateSourceRead) {
        accessor(sourceURL);
    } else {
        BOOL securityScopeAccessed =
            [sourceURL startAccessingSecurityScopedResource];
        if (!securityScopeAccessed) {
            // Installed themes under the active bootstrap and picker-created
            // copies are normal directories, not File Provider documents.
            accessor(sourceURL);
        } else {
            NSFileCoordinator *coordinator =
                [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            @try {
                [coordinator coordinateReadingItemAtURL:sourceURL
                    options:NSFileCoordinatorReadingWithoutChanges
                    error:&coordinationError
                    byAccessor:^(NSURL *coordinatedURL) {
                        accessor(coordinatedURL);
                    }];
            } @catch (__unused NSException *exception) {
                coordinationError = MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorCoordination,
                    @"Directory coordination raised an exception.", nil);
            } @finally {
                [sourceURL stopAccessingSecurityScopedResource];
            }
        }
    }
    if (!accessorInvoked && coordinationError == nil) {
        coordinationError = MTDirectorySnapshotError(
            MTDirectorySnapshotSessionErrorCoordination,
            @"Directory coordination did not provide a source accessor.", nil);
    }
    if (operationError == nil && coordinationError != nil) {
        operationError = MTDirectorySnapshotError(
            MTDirectorySnapshotSessionErrorCoordination,
            @"Unable to coordinate a read of the selected directory.",
            coordinationError);
    }

    close(partial);
    partial = -1;
    close(session);
    session = -1;

    id<MTAuditedSource> destination = nil;
    if (copied && operationError == nil) {
        NSURL *snapshotURL = [[configuration.sessionsRootURL
            URLByAppendingPathComponent:identifier isDirectory:YES]
            URLByAppendingPathComponent:@"snapshot" isDirectory:YES];
        NSError *destinationError = nil;
        destination = auditor(snapshotURL, &destinationError);
        if (destination == nil || ![(id)destination
                conformsToProtocol:@protocol(MTAuditedSource)] ||
            destination.inventory.files.count != source.inventory.files.count ||
            destination.inventory.totalBytes != source.inventory.totalBytes ||
            ![destination.inventory.sourceFingerprint
                isEqualToString:source.inventory.sourceFingerprint]) {
            operationError = MTDirectorySnapshotError(
                cancellationToken.isCancelled
                    ? MTDirectorySnapshotSessionErrorCancelled
                    : MTDirectorySnapshotSessionErrorDestinationVerification,
                cancellationToken.isCancelled
                    ? @"The directory snapshot was cancelled during destination audit."
                    : @"The App-owned snapshot does not match its source inventory.",
                destinationError);
        }
    }

    if (operationError != nil || !copied || destination == nil) {
        NSError *cleanupError = nil;
        BOOL cleaned = MTDiscardDirectorySnapshotAtRootDescriptor(root,
            identifier, (uint64_t)sessionStatus.st_dev,
            (uint64_t)sessionStatus.st_ino, configuration, &cleanupError);
        close(root);
        if (error != NULL) {
            *error = cleaned
                ? (operationError ?: MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorSourceRejected,
                    @"The directory snapshot did not complete.", nil))
                : MTDirectorySnapshotError(
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"Directory snapshot failed and its private session could not be cleaned safely.",
                    cleanupError ?: operationError);
        }
        return nil;
    }

    close(root);
    return [[self alloc] initWithIdentifier:identifier
        configuration:configuration rootStatus:&rootStatus
        sessionStatus:&sessionStatus sourceInventory:source.inventory
        auditedSource:destination];
}

+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTDirectorySnapshotConfiguration *)configuration
                                             error:(NSError **)error {
    if (![configuration isKindOfClass:
            MTDirectorySnapshotConfiguration.class]) {
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"A valid directory-snapshot configuration is required.", nil);
    }
    int root = -1;
    if (!MTOpenDirectorySnapshotRoot(configuration, NO, &root, NULL,
                                     error)) {
        return NO;
    }
    if (root < 0) return YES;
    int enumerationDescriptor = openat(root, ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = enumerationDescriptor < 0
        ? NULL : fdopendir(enumerationDescriptor);
    if (directory == NULL) {
        int savedError = errno;
        if (enumerationDescriptor >= 0) close(enumerationDescriptor);
        close(root);
        return MTDirectorySnapshotSetError(error,
            MTDirectorySnapshotSessionErrorCleanup,
            @"Unable to enumerate abandoned directory snapshots.",
            MTDirectorySnapshotPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    BOOL success = YES;
    while (success) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTDirectorySnapshotSetError(error,
                    MTDirectorySnapshotSessionErrorCleanup,
                    @"Directory-snapshot root enumeration failed.",
                    MTDirectorySnapshotPOSIXError(errno));
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
        if (MTDirectorySnapshotIdentifierIsCanonical(identifier)) {
            [identifiers addObject:identifier];
        }
    }
    closedir(directory);
    if (success) {
        [identifiers sortUsingSelector:@selector(compare:)];
        for (NSString *identifier in identifiers) {
            if (!MTDiscardDirectorySnapshotAtRootDescriptor(root,
                    identifier, 0, 0, configuration, error)) {
                success = NO;
                break;
            }
        }
    }
    close(root);
    return success;
}

- (BOOL)discard:(NSError **)error {
    @synchronized (self) {
        if (self.discarded) return YES;
        int root = -1;
        struct stat rootStatus = {0};
        if (!MTOpenDirectorySnapshotRoot(self.configuration, NO, &root,
                                         &rootStatus, error)) {
            return NO;
        }
        if (root < 0) {
            self.discarded = YES;
            return YES;
        }
        if ((uint64_t)rootStatus.st_dev != self.rootDevice ||
            (uint64_t)rootStatus.st_ino != self.rootInode) {
            close(root);
            return MTDirectorySnapshotSetError(error,
                MTDirectorySnapshotSessionErrorCleanup,
                @"The directory-snapshot root changed before cleanup.", nil);
        }
        BOOL success = MTDiscardDirectorySnapshotAtRootDescriptor(root,
            self.sessionIdentifier, self.sessionDevice, self.sessionInode,
            self.configuration, error);
        close(root);
        if (success) self.discarded = YES;
        return success;
    }
}

- (void)dealloc {
    [self discard:NULL];
}

@end
