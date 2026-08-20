#import "MTAssetStagingSession.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "MTAuditedSource.h"
#import "MTBootstrapPaths.h"
#import "MTAssetStagingFilesystem.h"
#import "MTAssetStagingSessionInternal.h"
#import "MTDigest.h"
#import "MTImportSession.h"
#import "MTSourceInventory.h"

NSString *const MTAssetStagingSessionErrorDomain =
    @"com.hmmzzz.marktheme.asset-staging-session";

static NSError *MTAssetStageErrorForSourceError(NSError *sourceError) {
    if ([sourceError.domain
            isEqualToString:MTAssetStagingSessionErrorDomain]) {
        return sourceError;
    }
    if ([sourceError.domain isEqualToString:MTAuditedSourceErrorDomain] &&
        sourceError.code == MTAuditedSourceErrorCancelled) {
        return MTAssetError(MTAssetStagingSessionErrorCancelled,
            @"The audited source stream was cancelled.", sourceError);
    }
    return MTAssetError(MTAssetStagingSessionErrorSourceRejected,
        @"The audited source rejected asset materialization.", sourceError);
}

@implementation MTAssetStagingConfiguration

+ (instancetype)defaultConfiguration {
    NSURL *managerDataRoot = MTDefaultManagerDataRootURL();
    NSAssert(managerDataRoot != nil,
             @"Manager data storage must be available for asset staging.");
    NSURL *rootURL = [managerDataRoot
        URLByAppendingPathComponent:
            @"com.hmmzzz.marktheme.asset-staging-sessions"
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

@interface MTStagedAsset ()
@property(nonatomic, copy) NSData *verifiedStatusData;
- (instancetype)initWithContentSHA256:(NSString *)contentSHA256
                            byteCount:(uint64_t)byteCount
                         ownedFileURL:(NSURL *)ownedFileURL
                       verifiedStatus:(const struct stat *)verifiedStatus;
- (void)copyVerifiedStatus:(struct stat *)status;
@end

@implementation MTStagedAsset

- (instancetype)initWithContentSHA256:(NSString *)contentSHA256
                            byteCount:(uint64_t)byteCount
                         ownedFileURL:(NSURL *)ownedFileURL
                       verifiedStatus:(const struct stat *)verifiedStatus {
    self = [super init];
    if (self == nil) return nil;
    _contentSHA256 = [contentSHA256 copy];
    _byteCount = byteCount;
    _ownedFileURL = [ownedFileURL copy];
    _verifiedStatusData = [NSData dataWithBytes:verifiedStatus
                                         length:sizeof(*verifiedStatus)];
    return self;
}

- (void)copyVerifiedStatus:(struct stat *)status {
    [self.verifiedStatusData getBytes:status length:sizeof(*status)];
}

@end

@interface MTAssetStagingSession ()
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(nonatomic, copy, readwrite) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readwrite) NSURL *objectsDirectoryURL;
@property(nonatomic, strong) MTAssetStagingConfiguration *configuration;
@property(nonatomic, assign) uint64_t rootDevice;
@property(nonatomic, assign) uint64_t rootInode;
@property(nonatomic, assign) uint64_t sessionDevice;
@property(nonatomic, assign) uint64_t sessionInode;
@property(nonatomic, strong) NSMutableDictionary<NSString *, MTStagedAsset *>
    *assetsByDigest;
@property(nonatomic, assign) NSUInteger objectCount;
@property(nonatomic, assign) uint64_t objectBytes;
@property(nonatomic, assign) BOOL invalidated;
@property(nonatomic, assign) BOOL discarded;
- (instancetype)initWithIdentifier:(NSString *)identifier
                       configuration:(MTAssetStagingConfiguration *)configuration
                          rootStatus:(const struct stat *)rootStatus
                       sessionStatus:(const struct stat *)sessionStatus;
- (nullable MTStagedAsset *)failStageWithError:(NSError *)stageError
                                   outputError:(NSError **)outputError;
@end

@implementation MTAssetStagingSession

- (instancetype)initWithIdentifier:(NSString *)identifier
                       configuration:(MTAssetStagingConfiguration *)configuration
                          rootStatus:(const struct stat *)rootStatus
                       sessionStatus:(const struct stat *)sessionStatus {
    self = [super init];
    if (self == nil) return nil;
    _sessionIdentifier = [identifier copy];
    _configuration = configuration;
    _sessionDirectoryURL = [configuration.sessionsRootURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    _objectsDirectoryURL = [_sessionDirectoryURL
        URLByAppendingPathComponent:@"objects" isDirectory:YES];
    _rootDevice = (uint64_t)rootStatus->st_dev;
    _rootInode = (uint64_t)rootStatus->st_ino;
    _sessionDevice = (uint64_t)sessionStatus->st_dev;
    _sessionInode = (uint64_t)sessionStatus->st_ino;
    _assetsByDigest = [NSMutableDictionary dictionary];
    return self;
}

+ (instancetype)sessionWithConfiguration:
                    (MTAssetStagingConfiguration *)configuration
                                   error:(NSError **)error {
    if (![configuration
            isKindOfClass:MTAssetStagingConfiguration.class]) {
        MTAssetSetError(error, MTAssetStagingSessionErrorInvalidRequest,
            @"A valid asset-staging configuration is required.", nil);
        return nil;
    }
    int rootDescriptor = -1;
    struct stat rootStatus = {0};
    if (!MTOpenAssetSessionsRoot(configuration, YES, &rootDescriptor,
                                 &rootStatus, error)) {
        return nil;
    }
    NSString *identifier = nil;
    struct stat sessionStatus = {0};
    if (!MTCreateAssetSessionDirectory(rootDescriptor, &identifier,
                                       &sessionStatus, error)) {
        close(rootDescriptor);
        return nil;
    }
    close(rootDescriptor);
    return [[self alloc] initWithIdentifier:identifier
                              configuration:configuration
                                 rootStatus:&rootStatus
                              sessionStatus:&sessionStatus];
}

- (NSUInteger)stagedObjectCount {
    @synchronized (self) {
        return self.objectCount;
    }
}

- (uint64_t)stagedByteCount {
    @synchronized (self) {
        return self.objectBytes;
    }
}

- (BOOL)isActive {
    @synchronized (self) {
        return !self.invalidated && !self.discarded;
    }
}

- (MTStagedAsset *)failStageWithError:(NSError *)stageError
                           outputError:(NSError **)outputError {
    self.invalidated = YES;
    NSError *cleanupError = nil;
    BOOL cleaned = [self discard:&cleanupError];
    if (outputError != NULL) {
        if (cleaned) {
            *outputError = stageError;
        } else {
            *outputError = MTAssetError(
                MTAssetStagingSessionErrorCleanup,
                @"Asset staging failed and its session could not be fully cleaned.",
                cleanupError);
        }
    }
    return nil;
}

- (MTStagedAsset *)stageAssetAtRelativePath:(NSString *)relativePath
                                  fromSource:(id<MTAuditedSource>)source
                            maximumByteCount:(uint64_t)maximumByteCount
                           cancellationToken:
                               (MTImportCancellationToken *)cancellationToken
                                       error:(NSError **)error {
    @synchronized (self) {
        if (self.invalidated || self.discarded) {
            MTAssetSetError(error, MTAssetStagingSessionErrorInactive,
                @"The asset-staging session is no longer active.", nil);
            return nil;
        }
        if (![relativePath isKindOfClass:NSString.class] ||
            relativePath.length == 0 || source == nil ||
            ![(id)source conformsToProtocol:@protocol(MTAuditedSource)] ||
            maximumByteCount == 0) {
            return [self failStageWithError:MTAssetError(
                MTAssetStagingSessionErrorInvalidRequest,
                @"Asset staging requires an audited path, source, and byte limit.",
                nil) outputError:error];
        }
        MTSourceFile *expected =
            [source.inventory fileAtRelativePath:relativePath];
        if (expected == nil) {
            return [self failStageWithError:MTAssetError(
                MTAssetStagingSessionErrorNotInventoried,
                @"The requested asset was not admitted by the source audit.",
                nil) outputError:error];
        }
        uint64_t stageLimit = MIN(maximumByteCount,
            self.configuration.limits.maximumSingleFileBytes);
        if (expected.byteCount == 0 || expected.byteCount > stageLimit) {
            NSError *stageError = MTAssetError(
                MTAssetStagingSessionErrorLimitExceeded,
                @"The inventoried asset exceeds its staging byte limit.", nil);
            return [self failStageWithError:stageError outputError:error];
        }

        MTStagedAsset *knownAsset =
            self.assetsByDigest[expected.contentSHA256];
        if (knownAsset == nil &&
            (self.objectCount >=
                 self.configuration.limits.maximumRegularFiles ||
             expected.byteCount >
                 self.configuration.limits.maximumExpandedBytes -
                     self.objectBytes)) {
            NSError *stageError = MTAssetError(
                MTAssetStagingSessionErrorLimitExceeded,
                @"The asset-staging session exceeded its object or byte budget.",
                nil);
            return [self failStageWithError:stageError outputError:error];
        }

        int rootDescriptor = -1;
        int sessionDescriptor = -1;
        int objectsDescriptor = -1;
        NSError *stageError = nil;
        BOOL success = MTOpenAssetSessionDescriptors(self.configuration,
            self.sessionIdentifier, self.rootDevice, self.rootInode,
            self.sessionDevice, self.sessionInode, &rootDescriptor,
            &sessionDescriptor, &objectsDescriptor, &stageError);
        if (success && knownAsset == nil) {
            success = MTAssetHasAvailableSpace(objectsDescriptor,
                                               expected.byteCount,
                                               &stageError);
        }

        if (success && knownAsset != nil) {
            struct stat verifiedBaseline = {0};
            [knownAsset copyVerifiedStatus:&verifiedBaseline];
            if (knownAsset.byteCount != expected.byteCount) {
                success = MTAssetSetError(&stageError,
                    MTAssetStagingSessionErrorVerification,
                    @"A known content digest has a different inventoried size.",
                    nil);
            }
            if (success) {
                success = MTAssetVerifyKnownFileIdentity(objectsDescriptor,
                    expected.contentSHA256.fileSystemRepresentation,
                    expected.byteCount, &verifiedBaseline,
                    cancellationToken, &stageError);
            }
            if (success) {
                NSError *sourceError = nil;
                success = [source
                    streamFileAtRelativePath:expected.relativePath
                            maximumByteCount:stageLimit
                           cancellationToken:cancellationToken
                                byteConsumer:^BOOL(
                                    __unused const void *bytes,
                                    __unused NSUInteger length,
                                    NSError **consumerError) {
                    if (cancellationToken.isCancelled) {
                        return MTAssetSetError(consumerError,
                            MTAssetStagingSessionErrorCancelled,
                            @"Asset deduplication was cancelled while revalidating the source.",
                            nil);
                    }
                    return YES;
                }
                                       error:&sourceError];
                if (!success) {
                    stageError = MTAssetStageErrorForSourceError(sourceError);
                }
            }
            if (success) {
                success = MTAssetVerifyKnownFileIdentity(objectsDescriptor,
                    expected.contentSHA256.fileSystemRepresentation,
                    expected.byteCount, &verifiedBaseline,
                    cancellationToken, &stageError);
            }
            if (success) {
                success = MTAssetSessionPathsAreStable(self.configuration,
                    self.sessionIdentifier, self.rootDevice, self.rootInode,
                    self.sessionDevice, self.sessionInode, rootDescriptor,
                    sessionDescriptor, objectsDescriptor, &stageError);
            }
            close(objectsDescriptor);
            close(sessionDescriptor);
            close(rootDescriptor);
            if (!success) {
                return [self failStageWithError:stageError outputError:error];
            }
            return knownAsset;
        }

        NSString *partialName = MTAssetCreatePartialName();
        int partialDescriptor = -1;
        if (success) {
            partialDescriptor = openat(objectsDescriptor,
                partialName.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
            if (partialDescriptor < 0 || fchmod(partialDescriptor, 0600) != 0) {
                int savedError = errno;
                if (partialDescriptor >= 0) close(partialDescriptor);
                partialDescriptor = -1;
                success = MTAssetSetError(&stageError,
                    MTAssetStagingSessionErrorStorage,
                    @"Unable to create a private asset partial file.",
                    MTAssetPOSIXError(savedError));
            }
        }

        __block uint64_t writtenBytes = 0;
        if (success) {
            NSError *sourceError = nil;
            success = [source
                streamFileAtRelativePath:expected.relativePath
                        maximumByteCount:stageLimit
                       cancellationToken:cancellationToken
                            byteConsumer:^BOOL(const void *bytes,
                                               NSUInteger length,
                                               NSError **consumerError) {
                if (cancellationToken.isCancelled) {
                    return MTAssetSetError(consumerError,
                        MTAssetStagingSessionErrorCancelled,
                        @"Asset staging was cancelled while writing data.",
                        nil);
                }
                if ((uint64_t)length > expected.byteCount - writtenBytes) {
                    return MTAssetSetError(consumerError,
                        MTAssetStagingSessionErrorVerification,
                        @"The source streamed more bytes than its inventory.",
                        nil);
                }
                if (!MTAssetWriteAll(partialDescriptor, bytes, length,
                                     consumerError)) {
                    return NO;
                }
                writtenBytes += (uint64_t)length;
                return YES;
            }
                                   error:&sourceError];
            if (!success) {
                stageError = MTAssetStageErrorForSourceError(sourceError);
            }
        }

        struct stat partialStatus = {0};
        if (success && (partialDescriptor < 0 ||
            writtenBytes != expected.byteCount ||
            fsync(partialDescriptor) != 0 ||
            fstat(partialDescriptor, &partialStatus) != 0 ||
            !S_ISREG(partialStatus.st_mode) ||
            partialStatus.st_nlink != 1 ||
            partialStatus.st_uid != geteuid() ||
            (partialStatus.st_mode & 0777) != 0600 ||
            partialStatus.st_size < 0 ||
            (uint64_t)partialStatus.st_size != expected.byteCount)) {
            success = MTAssetSetError(&stageError,
                MTAssetStagingSessionErrorVerification,
                @"The streamed asset failed its initial destination check.",
                nil);
        }
        if (partialDescriptor >= 0) close(partialDescriptor);

        struct stat verifiedPartial = {0};
        struct stat verifiedFinal = {0};
        if (success) {
            success = MTAssetVerifyOwnedFile(objectsDescriptor,
                partialName.fileSystemRepresentation, expected.byteCount,
                expected.contentSHA256, cancellationToken, &verifiedPartial,
                &stageError);
        }

        if (success && cancellationToken.isCancelled) {
            success = MTAssetSetError(&stageError,
                MTAssetStagingSessionErrorCancelled,
                @"Asset staging was cancelled before publication.", nil);
        }
        if (success) {
            int result = renameatx_np(objectsDescriptor,
                partialName.fileSystemRepresentation, objectsDescriptor,
                expected.contentSHA256.fileSystemRepresentation, RENAME_EXCL);
            if (result == 0) {
                int finalDescriptor = openat(objectsDescriptor,
                    expected.contentSHA256.fileSystemRepresentation,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
                struct stat finalStatus = {0};
                if (finalDescriptor < 0 ||
                    fstat(finalDescriptor, &finalStatus) != 0 ||
                    !MTAssetStatIdentityMatches(&verifiedPartial, &finalStatus) ||
                    !S_ISREG(finalStatus.st_mode) || finalStatus.st_nlink != 1 ||
                    finalStatus.st_uid != geteuid() ||
                    (finalStatus.st_mode & 0777) != 0600 ||
                    (uint64_t)finalStatus.st_size != expected.byteCount) {
                    success = MTAssetSetError(&stageError,
                        MTAssetStagingSessionErrorVerification,
                        @"The published asset identity differs from its verified partial.",
                        nil);
                }
                if (success) verifiedFinal = finalStatus;
                if (finalDescriptor >= 0) close(finalDescriptor);
            } else if (errno == EEXIST) {
                success = MTAssetVerifyOwnedFile(objectsDescriptor,
                    expected.contentSHA256.fileSystemRepresentation,
                    expected.byteCount, expected.contentSHA256,
                    cancellationToken, &verifiedFinal, &stageError);
                if (success && unlinkat(objectsDescriptor,
                    partialName.fileSystemRepresentation, 0) != 0) {
                    success = MTAssetSetError(&stageError,
                        MTAssetStagingSessionErrorStorage,
                        @"Unable to remove a verified duplicate partial.",
                        MTAssetPOSIXError(errno));
                }
            } else {
                success = MTAssetSetError(&stageError,
                    MTAssetStagingSessionErrorStorage,
                    @"Unable to publish an asset without overwrite.",
                    MTAssetPOSIXError(errno));
            }
        }
        if (success && fsync(objectsDescriptor) != 0) {
            success = MTAssetSetError(&stageError,
                MTAssetStagingSessionErrorStorage,
                @"Unable to synchronize the published asset object.",
                MTAssetPOSIXError(errno));
        }
        if (success) {
            success = MTAssetSessionPathsAreStable(self.configuration,
                self.sessionIdentifier, self.rootDevice, self.rootInode,
                self.sessionDevice, self.sessionInode, rootDescriptor,
                sessionDescriptor, objectsDescriptor, &stageError);
        }
        if (success && cancellationToken.isCancelled) {
            success = MTAssetSetError(&stageError,
                MTAssetStagingSessionErrorCancelled,
                @"Asset staging was cancelled before commit.", nil);
        }

        if (objectsDescriptor >= 0) close(objectsDescriptor);
        if (sessionDescriptor >= 0) close(sessionDescriptor);
        if (rootDescriptor >= 0) close(rootDescriptor);
        if (!success) {
            return [self failStageWithError:stageError outputError:error];
        }

        NSURL *ownedURL = [self.objectsDirectoryURL
            URLByAppendingPathComponent:expected.contentSHA256
                             isDirectory:NO];
        MTStagedAsset *asset = [[MTStagedAsset alloc]
            initWithContentSHA256:expected.contentSHA256
                        byteCount:expected.byteCount
                     ownedFileURL:ownedURL
                   verifiedStatus:&verifiedFinal];
        self.assetsByDigest[asset.contentSHA256] = asset;
        self.objectCount++;
        self.objectBytes += asset.byteCount;
        return asset;
    }
}

+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTAssetStagingConfiguration *)configuration
                                             error:(NSError **)error {
    if (![configuration
            isKindOfClass:MTAssetStagingConfiguration.class]) {
        return MTAssetSetError(error,
            MTAssetStagingSessionErrorInvalidRequest,
            @"A valid asset-staging configuration is required.", nil);
    }
    int rootDescriptor = -1;
    if (!MTOpenAssetSessionsRoot(configuration, NO, &rootDescriptor,
                                 NULL, error)) {
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
        return MTAssetSetError(error, MTAssetStagingSessionErrorCleanup,
            @"Unable to enumerate abandoned asset sessions.",
            MTAssetPOSIXError(savedError));
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    BOOL success = YES;
    while (YES) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                success = MTAssetSetError(error,
                    MTAssetStagingSessionErrorCleanup,
                    @"Asset-staging root enumeration failed.",
                    MTAssetPOSIXError(errno));
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
        if (MTAssetSessionIdentifierIsCanonical(identifier)) {
            [identifiers addObject:identifier];
        }
    }
    closedir(directory);
    if (success) {
        for (NSString *identifier in identifiers) {
            if (!MTDiscardAssetSessionAtRootDescriptor(rootDescriptor,
                    identifier, 0, 0, error)) {
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
        self.invalidated = YES;
        int rootDescriptor = -1;
        struct stat rootStatus = {0};
        if (!MTOpenAssetSessionsRoot(self.configuration, NO, &rootDescriptor,
                                     &rootStatus, error)) {
            return NO;
        }
        if (rootDescriptor < 0) {
            self.discarded = YES;
            [self.assetsByDigest removeAllObjects];
            self.objectCount = 0;
            self.objectBytes = 0;
            return YES;
        }
        if ((uint64_t)rootStatus.st_dev != self.rootDevice ||
            (uint64_t)rootStatus.st_ino != self.rootInode) {
            close(rootDescriptor);
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorCleanup,
                @"The asset-staging root changed before cleanup.", nil);
        }
        BOOL success = MTDiscardAssetSessionAtRootDescriptor(rootDescriptor,
            self.sessionIdentifier, self.sessionDevice, self.sessionInode,
            error);
        close(rootDescriptor);
        if (success) {
            self.discarded = YES;
            [self.assetsByDigest removeAllObjects];
            self.objectCount = 0;
            self.objectBytes = 0;
        }
        return success;
    }
}

- (BOOL)performLockedLibraryAdoptionForRequiredDigests:
            (NSSet<NSString *> *)requiredDigests
    consumer:(MTAssetStagingLibraryAdoptionBlock)consumer
       error:(NSError **)error {
    @synchronized (self) {
        if (self.invalidated || self.discarded) {
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorInactive,
                @"The asset-staging session is no longer active.", nil);
        }
        if (![requiredDigests isKindOfClass:NSSet.class] ||
            requiredDigests.count == 0 || consumer == nil) {
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorInvalidRequest,
                @"Library adoption requires a non-empty digest set and consumer.",
                nil);
        }
        for (id value in requiredDigests) {
            if (![value isKindOfClass:NSString.class] ||
                !MTStringIsLowercaseSHA256Digest(value)) {
                return MTAssetSetError(error,
                    MTAssetStagingSessionErrorInvalidRequest,
                    @"Library adoption received a malformed content digest.",
                    nil);
            }
        }
        NSSet<NSString *> *availableDigests =
            [NSSet setWithArray:self.assetsByDigest.allKeys];
        if (![availableDigests isEqualToSet:requiredDigests]) {
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorNotInventoried,
                @"The staged asset set does not exactly match the manifest.",
                nil);
        }

        int rootDescriptor = -1;
        int sessionDescriptor = -1;
        int objectsDescriptor = -1;
        NSError *operationError = nil;
        BOOL success = MTOpenAssetSessionDescriptors(self.configuration,
            self.sessionIdentifier, self.rootDevice, self.rootInode,
            self.sessionDevice, self.sessionInode, &rootDescriptor,
            &sessionDescriptor, &objectsDescriptor, &operationError);
        NSArray<NSString *> *sortedDigests = [requiredDigests.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        if (success) {
            for (NSString *digest in sortedDigests) {
                MTStagedAsset *asset = self.assetsByDigest[digest];
                struct stat baseline = {0};
                [asset copyVerifiedStatus:&baseline];
                if (!MTAssetVerifyKnownFileIdentity(objectsDescriptor,
                        digest.fileSystemRepresentation, asset.byteCount,
                        &baseline, nil, &operationError)) {
                    success = NO;
                    break;
                }
            }
        }
        if (success) {
            success = consumer(objectsDescriptor,
                               [self.assetsByDigest copy], &operationError);
        }
        if (success) {
            for (NSString *digest in sortedDigests) {
                MTStagedAsset *asset = self.assetsByDigest[digest];
                struct stat baseline = {0};
                [asset copyVerifiedStatus:&baseline];
                if (!MTAssetVerifyKnownFileIdentity(objectsDescriptor,
                        digest.fileSystemRepresentation, asset.byteCount,
                        &baseline, nil, &operationError)) {
                    success = NO;
                    break;
                }
            }
        }
        if (success) {
            success = MTAssetSessionPathsAreStable(self.configuration,
                self.sessionIdentifier, self.rootDevice, self.rootInode,
                self.sessionDevice, self.sessionInode, rootDescriptor,
                sessionDescriptor, objectsDescriptor, &operationError);
        }
        if (objectsDescriptor >= 0) close(objectsDescriptor);
        if (sessionDescriptor >= 0) close(sessionDescriptor);
        if (rootDescriptor >= 0) close(rootDescriptor);
        if (!success) {
            if (error != NULL) *error = operationError;
            return NO;
        }

        // Publication has already crossed current.json's atomic rename. A
        // cleanup failure may leak only an app-owned provisional session, so
        // it must not turn a committed revision into a reported failure.
        self.invalidated = YES;
        [self discard:NULL];
        return YES;
    }
}

- (void)dealloc {
    [self discard:NULL];
}

- (BOOL)removeStagedAssetWithContentSHA256:(NSString *)contentSHA256
                                     error:(NSError **)error {
    @synchronized (self) {
        if (self.invalidated || self.discarded ||
            !MTStringIsLowercaseSHA256Digest(contentSHA256)) {
            return MTAssetSetError(error,
                self.invalidated || self.discarded
                    ? MTAssetStagingSessionErrorInactive
                    : MTAssetStagingSessionErrorInvalidRequest,
                @"Removing a staged asset requires an active session and canonical digest.",
                nil);
        }
        MTStagedAsset *asset = self.assetsByDigest[contentSHA256];
        if (asset == nil) {
            return MTAssetSetError(error,
                MTAssetStagingSessionErrorNotInventoried,
                @"The staged asset selected for removal does not exist.", nil);
        }
        int rootDescriptor = -1;
        int sessionDescriptor = -1;
        int objectsDescriptor = -1;
        NSError *operationError = nil;
        BOOL success = MTOpenAssetSessionDescriptors(self.configuration,
            self.sessionIdentifier, self.rootDevice, self.rootInode,
            self.sessionDevice, self.sessionInode, &rootDescriptor,
            &sessionDescriptor, &objectsDescriptor, &operationError);
        struct stat baseline = {0};
        if (success) {
            [asset copyVerifiedStatus:&baseline];
            success = MTAssetVerifyKnownFileIdentity(objectsDescriptor,
                contentSHA256.fileSystemRepresentation, asset.byteCount,
                &baseline, nil, &operationError);
        }
        if (success && unlinkat(objectsDescriptor,
                contentSHA256.fileSystemRepresentation, 0) != 0) {
            success = MTAssetSetError(&operationError,
                MTAssetStagingSessionErrorStorage,
                @"Unable to remove a rejected staged asset.",
                MTAssetPOSIXError(errno));
        }
        if (success && fsync(objectsDescriptor) != 0) {
            success = MTAssetSetError(&operationError,
                MTAssetStagingSessionErrorStorage,
                @"Unable to synchronize rejected-asset removal.",
                MTAssetPOSIXError(errno));
        }
        if (success) {
            success = MTAssetSessionPathsAreStable(self.configuration,
                self.sessionIdentifier, self.rootDevice, self.rootInode,
                self.sessionDevice, self.sessionInode, rootDescriptor,
                sessionDescriptor, objectsDescriptor, &operationError);
        }
        if (objectsDescriptor >= 0) close(objectsDescriptor);
        if (sessionDescriptor >= 0) close(sessionDescriptor);
        if (rootDescriptor >= 0) close(rootDescriptor);
        if (!success) {
            if (error != NULL) *error = operationError;
            return NO;
        }
        [self.assetsByDigest removeObjectForKey:contentSHA256];
        self.objectCount--;
        self.objectBytes -= asset.byteCount;
        return YES;
    }
}

@end
