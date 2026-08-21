#import "MTRuntimeStoreController.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/clonefile.h>
#import <sys/file.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

#import "MTBootstrapPaths.h"
#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTImportSession.h"
#import "MTRuntimeState.h"
#if defined(MT_RUNTIME_STORE_FAULT_TESTING)
#import "MTRuntimeStoreTesting.h"
#endif

NSString *const MTRuntimeStoreErrorDomain =
    @"com.hmmzzz.marktheme.runtime-store";

static NSString *const MTRuntimeStoreGenerationsName = @"generations";
static NSString *const MTRuntimeStoreStateName = @"state";
static NSString *const MTRuntimeStorePublishName = @".publish";
static NSString *const MTRuntimeStoreLockName = @"control.lock";
static NSString *const MTRuntimeStoreStateFilename = @"active.json";
static NSString *const MTRuntimeStorePendingStateFilename = @".active.pending";
static const uint64_t MTRuntimeStoreDefaultFreeSpaceReserveBytes =
    64ULL * 1024ULL * 1024ULL;

static BOOL MTRuntimeStoreSetError(NSError **error,
                                   MTRuntimeStoreErrorCode code,
                                   NSString *description,
                                   NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTRuntimeStoreErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *MTRuntimeStorePOSIXError(int value) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:value userInfo:nil];
}

static BOOL MTRuntimeStoreGenerationIdentifierIsCanonical(NSString *value) {
    static NSString *const prefix = @"g1-";
    return [value isKindOfClass:NSString.class] && [value hasPrefix:prefix] &&
        MTStringIsLowercaseSHA256Digest(
            [value substringFromIndex:prefix.length]);
}

static BOOL MTRuntimeStoreEnsureDirectory(NSURL *directoryURL,
                                          NSError **error) {
    struct stat existingStatus = {0};
    if (lstat(directoryURL.fileSystemRepresentation, &existingStatus) == 0) {
        if (!S_ISDIR(existingStatus.st_mode)) {
            return MTRuntimeStoreSetError(error,
                MTRuntimeStoreErrorStorage,
                @"A Runtime store directory path is occupied by an unsafe node.",
                MTRuntimeStorePOSIXError(ENOTDIR));
        }
    } else if (errno != ENOENT) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to inspect a Runtime store directory.",
            MTRuntimeStorePOSIXError(errno));
    }
    NSError *creationError = nil;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:directoryURL
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions : @0755}
            error:&creationError]) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to create a Runtime store directory.", creationError);
    }

    int descriptor = open(directoryURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to open a Runtime store directory safely.",
            MTRuntimeStorePOSIXError(errno));
    }
    struct stat status = {0};
    BOOL repaired = fstat(descriptor, &status) == 0 &&
        S_ISDIR(status.st_mode);
    if (repaired &&
        (status.st_uid != geteuid() || status.st_gid != getegid())) {
        repaired = fchown(descriptor, geteuid(), getegid()) == 0;
    }
    if (repaired) repaired = fchmod(descriptor, 0755) == 0;
    if (repaired) repaired = fstat(descriptor, &status) == 0;
    int savedError = repaired ? 0 : errno;
    int closeResult = close(descriptor);
    int closeError = closeResult == 0 ? 0 : errno;
    if (!repaired || closeResult != 0 || !S_ISDIR(status.st_mode) ||
        status.st_uid != geteuid() || status.st_gid != getegid() ||
        (status.st_mode & 0777) != 0755) {
        if (savedError == 0) savedError = closeError;
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to repair Runtime store directory ownership or permissions.",
            savedError == 0 ? nil : MTRuntimeStorePOSIXError(savedError));
    }
    return YES;
}

static BOOL MTRuntimeStorePrepareDirectories(NSURL *runtimeRootURL,
                                             NSError **error) {
    NSURL *generationsURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreGenerationsName
                         isDirectory:YES];
    NSURL *stateURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreStateName
                         isDirectory:YES];
    return MTRuntimeStoreEnsureDirectory(runtimeRootURL, error) &&
        MTRuntimeStoreEnsureDirectory(generationsURL, error) &&
        MTRuntimeStoreEnsureDirectory(stateURL, error);
}

static int MTRuntimeStoreAcquireLock(NSURL *runtimeRootURL,
                                     NSError **error) {
    NSURL *lockURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreLockName isDirectory:NO];
    int descriptor = open(lockURL.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0 ||
        fchown(descriptor, geteuid(), getegid()) != 0 ||
        fchmod(descriptor, 0600) != 0) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to open the Runtime control lock.",
            MTRuntimeStorePOSIXError(savedError));
        return -1;
    }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        int savedError = errno;
        close(descriptor);
        MTRuntimeStoreSetError(error,
            savedError == EWOULDBLOCK ? MTRuntimeStoreErrorBusy
                                     : MTRuntimeStoreErrorStorage,
            savedError == EWOULDBLOCK
                ? @"Another Runtime store operation is already running."
                : @"Unable to acquire the Runtime control lock.",
            MTRuntimeStorePOSIXError(savedError));
        return -1;
    }
    return descriptor;
}

static BOOL MTRuntimeStoreRemoveIfPresent(NSURL *url, NSError **error) {
    struct stat status = {0};
    if (lstat(url.fileSystemRepresentation, &status) != 0) {
        if (errno == ENOENT) return YES;
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to inspect Runtime staging data.",
            MTRuntimeStorePOSIXError(errno));
    }
    NSError *removeError = nil;
    if ([NSFileManager.defaultManager removeItemAtURL:url error:&removeError]) {
        return YES;
    }
    return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
        @"Unable to remove abandoned Runtime staging data.", removeError);
}

static BOOL MTRuntimeStoreRecoverFixedStaging(NSURL *runtimeRootURL,
                                              NSError **error) {
    NSURL *publishURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStorePublishName
                         isDirectory:YES];
    NSURL *pendingStateURL = [[runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreStateName isDirectory:YES]
        URLByAppendingPathComponent:MTRuntimeStorePendingStateFilename
                         isDirectory:NO];
    return MTRuntimeStoreRemoveIfPresent(publishURL, error) &&
        MTRuntimeStoreRemoveIfPresent(pendingStateURL, error);
}

static BOOL MTRuntimeStoreSynchronizeDirectory(NSURL *directoryURL,
                                               NSError **error) {
    int descriptor = open(directoryURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to open a Runtime directory for synchronization.",
            MTRuntimeStorePOSIXError(errno));
    }
    int syncResult = fsync(descriptor);
    int savedError = errno;
    int closeResult = close(descriptor);
    if (syncResult != 0 || closeResult != 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to synchronize a Runtime directory.",
            MTRuntimeStorePOSIXError(savedError));
    }
    return YES;
}

static BOOL MTRuntimeStoreCheckAvailableSpace(
    NSURL *directoryURL,
    uint64_t requiredBytes,
    uint64_t reserveBytes,
    NSError **error) {
    int descriptor = open(directoryURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to open Runtime storage for capacity inspection.",
            MTRuntimeStorePOSIXError(errno));
    }
    struct statfs storage = {0};
    int result = fstatfs(descriptor, &storage);
    int savedError = errno;
    close(descriptor);
    if (result != 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to inspect available Runtime storage.",
            MTRuntimeStorePOSIXError(savedError));
    }
    uint64_t blocks = (uint64_t)storage.f_bavail;
    uint64_t blockSize = (uint64_t)storage.f_bsize;
    uint64_t available = blockSize != 0 && blocks > UINT64_MAX / blockSize
        ? UINT64_MAX : blocks * blockSize;
    if (reserveBytes > available || requiredBytes > available - reserveBytes) {
        return MTRuntimeStoreSetError(error,
            MTRuntimeStoreErrorInsufficientSpace,
            @"Insufficient storage is available for the complete Runtime Generation and reserve.",
            nil);
    }
    return YES;
}

static BOOL MTRuntimeStoreGenerationByteCount(
    MTGeneration *generation,
    uint64_t *byteCount,
    NSError **error) {
    uint64_t total = generation.descriptor.assetByteCount;
    uint64_t indexBytes = generation.descriptor.indexByteCount;
    uint64_t descriptorBytes = generation.descriptor.canonicalData.length;
    if (indexBytes > UINT64_MAX - total ||
        descriptorBytes > UINT64_MAX - total - indexBytes) {
        return MTRuntimeStoreSetError(error,
            MTRuntimeStoreErrorInvalidRequest,
            @"Runtime Generation byte count is invalid.", nil);
    }
    *byteCount = total + indexBytes + descriptorBytes;
    return YES;
}

static BOOL MTRuntimeStoreWriteData(NSURL *destinationURL,
                                    NSData *data,
                                    NSError **error) {
    int descriptor = open(destinationURL.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (descriptor < 0 ||
        fchown(descriptor, geteuid(), getegid()) != 0 ||
        fchmod(descriptor, 0644) != 0) {
        int savedError = errno;
        if (descriptor >= 0) {
            close(descriptor);
            unlink(destinationURL.fileSystemRepresentation);
        }
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to create a Runtime store file.",
            MTRuntimeStorePOSIXError(savedError));
    }
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = write(descriptor,
            (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (NSUInteger)count;
    }
    int syncResult = offset == data.length ? fsync(descriptor) : -1;
    int savedError = errno;
    int closeResult = close(descriptor);
    if (offset != data.length || syncResult != 0 || closeResult != 0) {
        unlink(destinationURL.fileSystemRepresentation);
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to write a complete Runtime store file.",
            MTRuntimeStorePOSIXError(savedError));
    }
    return YES;
}

static BOOL MTRuntimeStoreCopyAsset(NSURL *sourceURL,
                                    NSURL *destinationURL,
                                    uint64_t expectedBytes,
                                    MTImportCancellationToken *token,
                                    NSError **error) {
    if (token.isCancelled) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorCancelled,
            @"Runtime publication was cancelled.", nil);
    }
    if (clonefile(sourceURL.fileSystemRepresentation,
                  destinationURL.fileSystemRepresentation,
                  CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0) {
        struct stat status = {0};
        int descriptor = open(destinationURL.fileSystemRepresentation,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        BOOL valid = descriptor >= 0 &&
            fchown(descriptor, geteuid(), getegid()) == 0 &&
            fchmod(descriptor, 0644) == 0 &&
            fstat(descriptor, &status) == 0 && S_ISREG(status.st_mode) &&
            status.st_uid == geteuid() && status.st_gid == getegid() &&
            (status.st_mode & 0777) == 0644 && status.st_nlink == 1 &&
            status.st_size >= 0 &&
            (uint64_t)status.st_size == expectedBytes;
        if (valid) valid = fsync(descriptor) == 0;
        int closeResult = descriptor >= 0 ? close(descriptor) : -1;
        valid = valid && closeResult == 0;
        if (valid) return YES;
        unlink(destinationURL.fileSystemRepresentation);
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"A cloned Runtime asset has invalid metadata.", nil);
    }

    int sourceDescriptor = open(sourceURL.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (sourceDescriptor < 0) {
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to open a Generation asset for Runtime publication.",
            MTRuntimeStorePOSIXError(errno));
    }
    struct stat sourceStatus = {0};
    BOOL sourceValid = fstat(sourceDescriptor, &sourceStatus) == 0 &&
        S_ISREG(sourceStatus.st_mode) && sourceStatus.st_nlink == 1 &&
        sourceStatus.st_size >= 0 &&
        (uint64_t)sourceStatus.st_size == expectedBytes;
    int destinationDescriptor = sourceValid
        ? open(destinationURL.fileSystemRepresentation,
               O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644)
        : -1;
    BOOL destinationValid = destinationDescriptor >= 0 &&
        fchown(destinationDescriptor, geteuid(), getegid()) == 0 &&
        fchmod(destinationDescriptor, 0644) == 0;
    if (!sourceValid || !destinationValid) {
        int savedError = errno;
        if (destinationDescriptor >= 0) {
            close(destinationDescriptor);
            unlink(destinationURL.fileSystemRepresentation);
        }
        close(sourceDescriptor);
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to prepare a Runtime asset copy.",
            savedError == 0 ? nil : MTRuntimeStorePOSIXError(savedError));
    }

    unsigned char buffer[64 * 1024];
    uint64_t copiedBytes = 0;
    BOOL success = YES;
    while (copiedBytes < expectedBytes) {
        if (token.isCancelled) {
            success = NO;
            break;
        }
        size_t requested = (size_t)MIN(
            (uint64_t)sizeof(buffer), expectedBytes - copiedBytes);
        ssize_t count = read(sourceDescriptor, buffer, requested);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            success = NO;
            break;
        }
        ssize_t written = 0;
        while (written < count) {
            ssize_t amount = write(destinationDescriptor, buffer + written,
                                   (size_t)(count - written));
            if (amount < 0 && errno == EINTR) continue;
            if (amount <= 0) {
                success = NO;
                break;
            }
            written += amount;
        }
        if (!success) break;
        copiedBytes += (uint64_t)count;
    }
    if (success) success = fsync(destinationDescriptor) == 0;
    int savedError = errno;
    if (close(destinationDescriptor) != 0) success = NO;
    if (close(sourceDescriptor) != 0) success = NO;
    if (!success || copiedBytes != expectedBytes) {
        unlink(destinationURL.fileSystemRepresentation);
        return MTRuntimeStoreSetError(error,
            token.isCancelled ? MTRuntimeStoreErrorCancelled
                              : MTRuntimeStoreErrorStorage,
            token.isCancelled
                ? @"Runtime publication was cancelled."
                : @"Unable to copy a complete Runtime asset.",
            token.isCancelled ? nil : MTRuntimeStorePOSIXError(savedError));
    }
    return YES;
}

static MTGenerationReader *MTRuntimeStoreReader(NSURL *runtimeRootURL) {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:runtimeRootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePublished];
    return [[MTGenerationReader alloc] initWithConfiguration:configuration];
}

static BOOL MTRuntimeStorePublishedNodeIsValid(NSURL *url,
                                               BOOL directory,
                                               mode_t permissions) {
    struct stat status = {0};
    return lstat(url.fileSystemRepresentation, &status) == 0 &&
        (directory ? S_ISDIR(status.st_mode) : S_ISREG(status.st_mode)) &&
        status.st_uid == geteuid() && status.st_gid == getegid() &&
        (status.st_mode & 0777) == permissions &&
        (directory || status.st_nlink == 1);
}

static BOOL MTRuntimeStorePublishedGenerationMetadataIsValid(
    NSURL *runtimeRootURL,
    MTGeneration *generation) {
    NSURL *generationsURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreGenerationsName
                         isDirectory:YES];
    NSURL *generationURL = [generationsURL
        URLByAppendingPathComponent:generation.generationIdentifier
                         isDirectory:YES];
    NSURL *assetsURL = [generationURL
        URLByAppendingPathComponent:@"assets" isDirectory:YES];
    if (!MTRuntimeStorePublishedNodeIsValid(runtimeRootURL, YES, 0755) ||
        !MTRuntimeStorePublishedNodeIsValid(generationsURL, YES, 0755) ||
        !MTRuntimeStorePublishedNodeIsValid(generationURL, YES, 0755) ||
        !MTRuntimeStorePublishedNodeIsValid(assetsURL, YES, 0755) ||
        !MTRuntimeStorePublishedNodeIsValid([generationURL
            URLByAppendingPathComponent:@"index.mtg" isDirectory:NO],
            NO, 0644) ||
        !MTRuntimeStorePublishedNodeIsValid([generationURL
            URLByAppendingPathComponent:@"generation.json" isDirectory:NO],
            NO, 0644)) {
        return NO;
    }
    for (MTGenerationAssetDescriptor *asset in generation.descriptor.assets) {
        if (!MTRuntimeStorePublishedNodeIsValid([assetsURL
                URLByAppendingPathComponent:asset.contentSHA256
                             isDirectory:NO], NO, 0644)) {
            return NO;
        }
    }
    return YES;
}

static MTGeneration *MTRuntimeStoreReadGeneration(
    NSURL *runtimeRootURL,
    NSString *generationIdentifier,
    NSError **error) {
    NSError *readerError = nil;
    MTGeneration *generation = [MTRuntimeStoreReader(runtimeRootURL)
        readGenerationWithIdentifier:generationIdentifier
        cancellationToken:nil
        error:&readerError];
    if (generation != nil &&
        MTRuntimeStorePublishedGenerationMetadataIsValid(
            runtimeRootURL, generation)) {
        return generation;
    }
    if (generation != nil) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorVerification,
            @"The Runtime Generation is not root-owned published data.", nil);
        return nil;
    }
    MTRuntimeStoreErrorCode code =
        [readerError.domain isEqualToString:MTGenerationReaderErrorDomain] &&
        readerError.code == MTGenerationReaderErrorNotFound
            ? MTRuntimeStoreErrorNotFound
            : MTRuntimeStoreErrorVerification;
    MTRuntimeStoreSetError(error, code,
        code == MTRuntimeStoreErrorNotFound
            ? @"The requested Runtime Generation does not exist."
            : @"The requested Runtime Generation failed validation.",
        readerError);
    return nil;
}

static MTRuntimeState *MTRuntimeStoreReadState(NSURL *runtimeRootURL,
                                               NSError **error) {
    NSURL *stateURL = [[runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreStateName isDirectory:YES]
        URLByAppendingPathComponent:MTRuntimeStoreStateFilename
                         isDirectory:NO];
    struct stat stateStatus = {0};
    int stateResult = lstat(stateURL.fileSystemRepresentation, &stateStatus);
    int stateErrorValue = stateResult == 0 ? 0 : errno;
    if (stateResult == 0 &&
        !MTRuntimeStorePublishedNodeIsValid(stateURL, NO, 0644)) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorVerification,
            @"Runtime activation state is not root-owned published data.", nil);
        return nil;
    }
    if (stateErrorValue != 0 && stateErrorValue != ENOENT) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to inspect Runtime activation state.",
            MTRuntimeStorePOSIXError(stateErrorValue));
        return nil;
    }
    NSError *stateError = nil;
    MTRuntimeState *state = [MTRuntimeState
        stateByReadingRuntimeRootURL:runtimeRootURL
        ownershipProfile:MTRuntimeStateOwnershipProfilePublished
        error:&stateError];
    if (state != nil) return state;
    MTRuntimeStoreSetError(error, MTRuntimeStoreErrorVerification,
        @"Runtime activation state failed validation.", stateError);
    return nil;
}

static BOOL MTRuntimeStoreWriteState(NSURL *runtimeRootURL,
                                     MTRuntimeState *state,
                                     NSError **error) {
    NSURL *stateDirectoryURL = [runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreStateName isDirectory:YES];
    NSURL *pendingURL = [stateDirectoryURL
        URLByAppendingPathComponent:MTRuntimeStorePendingStateFilename
                         isDirectory:NO];
    NSURL *activeURL = [stateDirectoryURL
        URLByAppendingPathComponent:MTRuntimeStoreStateFilename
                         isDirectory:NO];
    if (!MTRuntimeStoreRemoveIfPresent(pendingURL, error) ||
        !MTRuntimeStoreWriteData(pendingURL, state.canonicalData, error)) {
        return NO;
    }
#if defined(MT_RUNTIME_STORE_FAULT_TESTING)
    MTRuntimeStoreTestingReachCheckpoint(
        MTRuntimeStoreTestingCheckpointBeforeStateRename);
#endif
    if (rename(pendingURL.fileSystemRepresentation,
               activeURL.fileSystemRepresentation) != 0) {
        int savedError = errno;
        unlink(pendingURL.fileSystemRepresentation);
        return MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to atomically replace Runtime activation state.",
            MTRuntimeStorePOSIXError(savedError));
    }
#if defined(MT_RUNTIME_STORE_FAULT_TESTING)
    MTRuntimeStoreTestingReachCheckpoint(
        MTRuntimeStoreTestingCheckpointAfterStateRename);
#endif
    return MTRuntimeStoreSynchronizeDirectory(stateDirectoryURL, error);
}

@interface MTRuntimePublishResult ()

@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, copy, readwrite) NSURL *generationURL;
@property(nonatomic, assign, readwrite) BOOL reusedExistingGeneration;

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                generationURL:(NSURL *)generationURL
                    reusedExistingGeneration:(BOOL)reused;

@end

@implementation MTRuntimePublishResult

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                generationURL:(NSURL *)generationURL
                    reusedExistingGeneration:(BOOL)reused {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _generationURL = [generationURL copy];
    _reusedExistingGeneration = reused;
    return self;
}

@end

@interface MTRuntimeStoreController ()
@property(nonatomic, copy, readwrite) NSURL *runtimeRootURL;
@property(nonatomic, assign, readwrite)
    uint64_t minimumFreeSpaceReserveBytes;
@end

@implementation MTRuntimeStoreController

+ (instancetype)defaultControllerWithError:(NSError **)error {
    NSError *pathError = nil;
    NSURL *runtimeRootURL = MTDefaultRuntimeStoreURL(&pathError);
    if (runtimeRootURL == nil) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to resolve the Runtime store location.", pathError);
        return nil;
    }
    return [[self alloc] initWithRuntimeRootURL:runtimeRootURL];
}

- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL {
    return [self initWithRuntimeRootURL:runtimeRootURL
          minimumFreeSpaceReserveBytes:
              MTRuntimeStoreDefaultFreeSpaceReserveBytes];
}

- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL
          minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes {
    NSParameterAssert(runtimeRootURL.isFileURL);
    NSParameterAssert(runtimeRootURL.path.length > 0);
    self = [super init];
    if (self == nil) return nil;
    _runtimeRootURL = [runtimeRootURL copy];
    _minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes;
    return self;
}

- (MTRuntimePublishResult *)publishGeneration:(MTGeneration *)generation
                             cancellationToken:
                                 (MTImportCancellationToken *)cancellationToken
                                      error:(NSError **)error {
    if (![generation isKindOfClass:MTGeneration.class] ||
        generation.generationIdentifier.length == 0 ||
        generation.descriptor == nil || generation.index == nil ||
        ![generation.generationIdentifier
            isEqualToString:generation.descriptor.generationIdentifier]) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorInvalidRequest,
            @"Runtime publication requires a validated Generation.", nil);
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorCancelled,
            @"Runtime publication was cancelled.", nil);
        return nil;
    }
    if (!MTRuntimeStorePrepareDirectories(self.runtimeRootURL, error)) {
        return nil;
    }
    int lockDescriptor = MTRuntimeStoreAcquireLock(self.runtimeRootURL, error);
    if (lockDescriptor < 0) return nil;

    MTRuntimePublishResult *result = nil;
    NSString *identifier = generation.generationIdentifier;
    NSURL *generationsURL = [self.runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStoreGenerationsName
                         isDirectory:YES];
    NSURL *finalURL = [generationsURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    struct stat finalStatus = {0};
    if (!MTRuntimeStoreRecoverFixedStaging(self.runtimeRootURL, error)) {
        close(lockDescriptor);
        return nil;
    }
    if (lstat(finalURL.fileSystemRepresentation, &finalStatus) == 0) {
        MTGeneration *existing = MTRuntimeStoreReadGeneration(
            self.runtimeRootURL, identifier, error);
        if (existing != nil) {
            result = [[MTRuntimePublishResult alloc]
                initWithGenerationIdentifier:identifier
                generationURL:finalURL
                reusedExistingGeneration:YES];
        }
        close(lockDescriptor);
        return result;
    }
    if (errno != ENOENT) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to inspect the Runtime Generation destination.",
            MTRuntimeStorePOSIXError(errno));
        close(lockDescriptor);
        return nil;
    }

    uint64_t requiredBytes = 0;
    if (!MTRuntimeStoreGenerationByteCount(
            generation, &requiredBytes, error) ||
        !MTRuntimeStoreCheckAvailableSpace(
            generationsURL, requiredBytes,
            self.minimumFreeSpaceReserveBytes, error)) {
        close(lockDescriptor);
        return nil;
    }

    NSURL *publishURL = [self.runtimeRootURL
        URLByAppendingPathComponent:MTRuntimeStorePublishName isDirectory:YES];
    NSURL *publishGenerationsURL = [publishURL
        URLByAppendingPathComponent:MTRuntimeStoreGenerationsName
                         isDirectory:YES];
    NSURL *stagingGenerationURL = [publishGenerationsURL
        URLByAppendingPathComponent:identifier isDirectory:YES];
    NSURL *stagingAssetsURL = [stagingGenerationURL
        URLByAppendingPathComponent:@"assets" isDirectory:YES];
    BOOL success = MTRuntimeStoreEnsureDirectory(publishURL, error) &&
        MTRuntimeStoreEnsureDirectory(publishGenerationsURL, error) &&
        MTRuntimeStoreEnsureDirectory(stagingGenerationURL, error) &&
        MTRuntimeStoreEnsureDirectory(stagingAssetsURL, error);
    NSURL *sourceAssetsURL = [generation.generationURL
        URLByAppendingPathComponent:@"assets" isDirectory:YES];
    for (MTGenerationAssetDescriptor *asset in generation.descriptor.assets) {
        if (!success) break;
        NSURL *sourceURL = [sourceAssetsURL
            URLByAppendingPathComponent:asset.contentSHA256 isDirectory:NO];
        NSURL *destinationURL = [stagingAssetsURL
            URLByAppendingPathComponent:asset.contentSHA256 isDirectory:NO];
        success = MTRuntimeStoreCopyAsset(
            sourceURL, destinationURL, asset.byteCount,
            cancellationToken, error);
    }
    NSURL *indexURL = [stagingGenerationURL
        URLByAppendingPathComponent:@"index.mtg" isDirectory:NO];
    NSURL *descriptorURL = [stagingGenerationURL
        URLByAppendingPathComponent:@"generation.json" isDirectory:NO];
    if (success) {
        success = MTRuntimeStoreWriteData(
            indexURL, generation.index.encodedData, error) &&
            MTRuntimeStoreWriteData(
                descriptorURL, generation.descriptor.canonicalData, error);
    }
    if (success) {
        success = MTRuntimeStoreSynchronizeDirectory(stagingAssetsURL, error) &&
            MTRuntimeStoreSynchronizeDirectory(stagingGenerationURL, error);
    }
    if (success && cancellationToken.isCancelled) {
        success = MTRuntimeStoreSetError(error,
            MTRuntimeStoreErrorCancelled,
            @"Runtime publication was cancelled.", nil);
    }
    if (success) {
        NSError *readerError = nil;
        MTGeneration *validated = [MTRuntimeStoreReader(publishURL)
            readGenerationWithIdentifier:identifier
            cancellationToken:cancellationToken
            error:&readerError];
        if (validated == nil) {
            success = MTRuntimeStoreSetError(error,
                cancellationToken.isCancelled
                    ? MTRuntimeStoreErrorCancelled
                    : MTRuntimeStoreErrorVerification,
                @"Published Runtime staging data failed independent validation.",
                readerError);
        }
    }
    if (success && renamex_np(stagingGenerationURL.fileSystemRepresentation,
                              finalURL.fileSystemRepresentation,
                              RENAME_EXCL) != 0) {
        success = MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Unable to atomically publish the Runtime Generation.",
            MTRuntimeStorePOSIXError(errno));
    }
    if (success) {
        success = MTRuntimeStoreSynchronizeDirectory(generationsURL, error);
    }
    NSError *cleanupError = nil;
    BOOL cleaned = MTRuntimeStoreRemoveIfPresent(publishURL, &cleanupError);
    if (success && !cleaned) {
        success = MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
            @"Runtime Generation was published but staging cleanup failed.",
            cleanupError);
    }
    if (success) {
        result = [[MTRuntimePublishResult alloc]
            initWithGenerationIdentifier:identifier
            generationURL:finalURL
            reusedExistingGeneration:NO];
    }
    close(lockDescriptor);
    return result;
}

- (MTRuntimeState *)currentStateWithError:(NSError **)error {
    return MTRuntimeStoreReadState(self.runtimeRootURL, error);
}

- (MTRuntimeState *)activateGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                 error:(NSError **)error {
    if (!MTRuntimeStoreGenerationIdentifierIsCanonical(
            generationIdentifier)) {
        MTRuntimeStoreSetError(error, MTRuntimeStoreErrorInvalidRequest,
            @"Activation requires a Generation identifier.", nil);
        return nil;
    }
    if (!MTRuntimeStorePrepareDirectories(self.runtimeRootURL, error)) {
        return nil;
    }
    int lockDescriptor = MTRuntimeStoreAcquireLock(self.runtimeRootURL, error);
    if (lockDescriptor < 0) return nil;
    MTRuntimeState *result = nil;
    if (MTRuntimeStoreRecoverFixedStaging(self.runtimeRootURL, error) &&
        MTRuntimeStoreReadGeneration(self.runtimeRootURL,
                                     generationIdentifier, error) != nil) {
        MTRuntimeState *current = MTRuntimeStoreReadState(
            self.runtimeRootURL, error);
        if (current != nil && current.isRuntimeEnabled &&
            [current.activeGenerationIdentifier
                isEqualToString:generationIdentifier]) {
            result = current;
        } else if (current != nil && current.sequence != UINT64_MAX) {
            NSString *previous = [current.activeGenerationIdentifier
                isEqualToString:generationIdentifier]
                    ? current.previousGenerationIdentifier
                    : current.activeGenerationIdentifier;
            MTRuntimeState *next = [[MTRuntimeState alloc]
                initWithSequence:current.sequence + 1
                runtimeEnabled:YES
                activeGenerationIdentifier:generationIdentifier
                previousGenerationIdentifier:previous
                error:error];
            if (next != nil &&
                MTRuntimeStoreWriteState(self.runtimeRootURL, next, error)) {
                result = next;
            }
        } else if (current != nil) {
            MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
                @"Runtime state sequence is exhausted.", nil);
        }
    }
    close(lockDescriptor);
    return result;
}

- (MTRuntimeState *)rollbackWithError:(NSError **)error {
    if (!MTRuntimeStorePrepareDirectories(self.runtimeRootURL, error)) {
        return nil;
    }
    int lockDescriptor = MTRuntimeStoreAcquireLock(self.runtimeRootURL, error);
    if (lockDescriptor < 0) return nil;
    MTRuntimeState *result = nil;
    if (MTRuntimeStoreRecoverFixedStaging(self.runtimeRootURL, error)) {
        MTRuntimeState *current = MTRuntimeStoreReadState(
            self.runtimeRootURL, error);
        if (current != nil && current.previousGenerationIdentifier == nil) {
            MTRuntimeStoreSetError(error, MTRuntimeStoreErrorNotFound,
                @"No previous Runtime Generation is available.", nil);
        } else if (current != nil && current.sequence == UINT64_MAX) {
            MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
                @"Runtime state sequence is exhausted.", nil);
        } else if (current != nil &&
            MTRuntimeStoreReadGeneration(
                self.runtimeRootURL,
                current.previousGenerationIdentifier, error) != nil) {
            MTRuntimeState *next = [[MTRuntimeState alloc]
                initWithSequence:current.sequence + 1
                runtimeEnabled:YES
                activeGenerationIdentifier:current.previousGenerationIdentifier
                previousGenerationIdentifier:current.activeGenerationIdentifier
                error:error];
            if (next != nil &&
                MTRuntimeStoreWriteState(self.runtimeRootURL, next, error)) {
                result = next;
            }
        }
    }
    close(lockDescriptor);
    return result;
}

- (MTRuntimeState *)disableWithError:(NSError **)error {
    if (!MTRuntimeStorePrepareDirectories(self.runtimeRootURL, error)) {
        return nil;
    }
    int lockDescriptor = MTRuntimeStoreAcquireLock(self.runtimeRootURL, error);
    if (lockDescriptor < 0) return nil;
    MTRuntimeState *result = nil;
    if (MTRuntimeStoreRecoverFixedStaging(self.runtimeRootURL, error)) {
        MTRuntimeState *current = MTRuntimeStoreReadState(
            self.runtimeRootURL, error);
        if (current != nil && !current.isRuntimeEnabled) {
            result = current;
        } else if (current != nil && current.sequence != UINT64_MAX) {
            MTRuntimeState *next = [[MTRuntimeState alloc]
                initWithSequence:current.sequence + 1
                runtimeEnabled:NO
                activeGenerationIdentifier:current.activeGenerationIdentifier
                previousGenerationIdentifier:current.previousGenerationIdentifier
                error:error];
            if (next != nil &&
                MTRuntimeStoreWriteState(self.runtimeRootURL, next, error)) {
                result = next;
            }
        } else if (current != nil) {
            MTRuntimeStoreSetError(error, MTRuntimeStoreErrorStorage,
                @"Runtime state sequence is exhausted.", nil);
        }
    }
    close(lockDescriptor);
    return result;
}

@end
