#import "MTGenerationWriter.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationFilesystem.h"
#import "MTGenerationWriterValidation.h"
#import "MTImportSession.h"
#import "MTStaticIconCompiler.h"

NSString *const MTGenerationWriterErrorDomain =
    @"com.hmmzzz.marktheme.generation-writer";

static NSString *const MTGenerationIndexFilename = @"index.mtg";
static NSString *const MTGenerationDescriptorFilename = @"generation.json";
static NSString *const MTGenerationAssetsDirectoryName = @"assets";

@implementation MTGenerationWriterConfiguration

+ (instancetype)defaultConfiguration {
    NSString *applicationSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSAssert(applicationSupport.length > 0,
             @"Application Support must be available for Generation output.");
    NSURL *rootURL = [[[NSURL fileURLWithPath:applicationSupport
                                  isDirectory:YES]
        URLByAppendingPathComponent:@"MarkTheme" isDirectory:YES]
        URLByAppendingPathComponent:@"Compiler" isDirectory:YES];
    return [[self alloc]
        initWithRootURL:rootURL
        maximumAssetCount:20000
        maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
        minimumFreeSpaceReserveBytes:64ULL * 1024ULL * 1024ULL
        maximumRecoveryNodeCount:25000];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
    minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes
        maximumRecoveryNodeCount:(NSUInteger)maximumRecoveryNodeCount {
    NSParameterAssert(rootURL.isFileURL);
    NSParameterAssert(rootURL.path.length > 0);
    NSParameterAssert(maximumAssetCount > 0);
    NSParameterAssert(maximumAssetCount <= NSUIntegerMax - 3);
    NSParameterAssert(maximumGenerationByteCount > 0);
    NSParameterAssert(maximumRecoveryNodeCount >= maximumAssetCount + 3);
    self = [super init];
    if (self == nil) return nil;
    _rootURL = [rootURL copy];
    _maximumAssetCount = maximumAssetCount;
    _maximumGenerationByteCount = maximumGenerationByteCount;
    _minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes;
    _maximumRecoveryNodeCount = maximumRecoveryNodeCount;
    return self;
}

@end

@interface MTGenerationWriteResult ()

@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, copy, readwrite) NSURL *generationURL;
@property(nonatomic, assign, readwrite) BOOL reusedExistingGeneration;
@property(nonatomic, assign, readwrite) NSUInteger clonedAssetCount;
@property(nonatomic, assign, readwrite) NSUInteger streamedAssetCount;

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                generationURL:(NSURL *)generationURL
                    reusedExistingGeneration:(BOOL)reused
                             clonedAssetCount:(NSUInteger)clonedAssetCount
                           streamedAssetCount:(NSUInteger)streamedAssetCount;

@end

@implementation MTGenerationWriteResult

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                generationURL:(NSURL *)generationURL
                    reusedExistingGeneration:(BOOL)reused
                             clonedAssetCount:(NSUInteger)clonedAssetCount
                           streamedAssetCount:(NSUInteger)streamedAssetCount {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _generationURL = [generationURL copy];
    _reusedExistingGeneration = reused;
    _clonedAssetCount = clonedAssetCount;
    _streamedAssetCount = streamedAssetCount;
    return self;
}

@end

static NSURL *MTGenerationWriterFinalURL(
    MTGenerationWriterConfiguration *configuration,
    NSString *generationIdentifier) {
    return [[configuration.rootURL
        URLByAppendingPathComponent:@"generations" isDirectory:YES]
        URLByAppendingPathComponent:generationIdentifier isDirectory:YES];
}

@interface MTGenerationWriter ()
@property(nonatomic, strong, readwrite)
    MTGenerationWriterConfiguration *configuration;
@end

@implementation MTGenerationWriter

+ (instancetype)defaultWriter {
    return [[self alloc] initWithConfiguration:
        MTGenerationWriterConfiguration.defaultConfiguration];
}

- (instancetype)initWithConfiguration:
    (MTGenerationWriterConfiguration *)configuration {
    NSParameterAssert(configuration != nil);
    self = [super init];
    if (self == nil) return nil;
    _configuration = configuration;
    return self;
}

- (BOOL)recoverAbandonedTransactionsWithError:(NSError **)error {
    MTGenerationStoreDirectories directories;
    if (!MTOpenGenerationStoreDirectories(
            self.configuration, YES, &directories, error)) {
        return NO;
    }
    int lockDescriptor = MTGenerationAcquireTransactionLock(
        directories.rootDescriptor, error);
    if (lockDescriptor < 0) {
        MTGenerationStoreDirectoriesClose(&directories);
        return NO;
    }
    BOOL success = MTGenerationRecoverAbandonedTransactions(
        directories.rootDescriptor, directories.generationsDescriptor,
        self.configuration, error) &&
        MTGenerationStoreDirectoriesAreStable(
            self.configuration, &directories, error);
    close(lockDescriptor);
    MTGenerationStoreDirectoriesClose(&directories);
    return success;
}

- (MTGenerationWriteResult *)writeCompiledGeneration:
    (MTCompiledGeneration *)compiledGeneration
                                          cancellationToken:
    (MTImportCancellationToken *)cancellationToken
                                                   error:(NSError **)error {
    MTGenerationValidatedInput *input = MTGenerationWriterValidateInput(
        compiledGeneration, self.configuration, error);
    if (input == nil) return nil;
    if (MTGenerationWriterCancelled(cancellationToken,
            @"Generation writing was cancelled before opening the store.",
            error)) {
        return nil;
    }

    MTGenerationStoreDirectories directories;
    if (!MTOpenGenerationStoreDirectories(
            self.configuration, YES, &directories, error)) {
        return nil;
    }
    int lockDescriptor = MTGenerationAcquireTransactionLock(
        directories.rootDescriptor, error);
    if (lockDescriptor < 0) {
        MTGenerationStoreDirectoriesClose(&directories);
        return nil;
    }
    MTGenerationWriteResult *result = nil;
    NSString *transactionName = nil;
    int transactionDescriptor = -1;
    int assetsDescriptor = -1;
    BOOL published = NO;
    BOOL success = MTGenerationRecoverAbandonedTransactions(
        directories.rootDescriptor, directories.generationsDescriptor,
        self.configuration, error);
    if (success && MTGenerationWriterCancelled(cancellationToken,
            @"Generation writing was cancelled after store recovery.", error)) {
        success = NO;
    }

    NSString *identifier = input.descriptor.generationIdentifier;
    struct stat existingStatus = {0};
    int existingResult = success ? fstatat(
        directories.generationsDescriptor,
        identifier.fileSystemRepresentation, &existingStatus,
        AT_SYMLINK_NOFOLLOW) : -1;
    int existingError = errno;
    if (success && existingResult == 0) {
        success = MTGenerationWriterVerifyFinal(
            directories.generationsDescriptor, input, cancellationToken,
            error);
        if (success) {
            result = [[MTGenerationWriteResult alloc]
                initWithGenerationIdentifier:identifier
                generationURL:MTGenerationWriterFinalURL(
                    self.configuration, identifier)
                reusedExistingGeneration:YES
                clonedAssetCount:0
                streamedAssetCount:0];
        }
    } else if (success && existingError != ENOENT) {
        success = MTGenerationWriterSetError(error,
            MTGenerationWriterErrorStorage,
            @"Unable to inspect the Generation publication destination.",
            MTGenerationPOSIXError(existingError));
    }

    NSUInteger clonedAssetCount = 0;
    NSUInteger streamedAssetCount = 0;
    if (success && result == nil) {
        success = MTGenerationCheckAvailableSpace(
            directories.generationsDescriptor, input.totalByteCount,
            self.configuration.minimumFreeSpaceReserveBytes, error);
    }
    if (success && result == nil) {
        transactionName = MTGenerationCreateTransactionName();
        success = MTGenerationCreateTransactionDirectories(
            directories.generationsDescriptor, transactionName,
            &transactionDescriptor, &assetsDescriptor, error);
    }
    if (success && result == nil) {
        for (NSString *digest in input.sortedAssetDigests) {
            if (MTGenerationWriterCancelled(cancellationToken,
                    @"Generation writing was cancelled before an asset copy.",
                    error)) {
                success = NO;
                break;
            }
            MTGenerationAssetDescriptor *asset =
                input.assetsByDigest[digest];
            BOOL cloned = NO;
            if (!MTGenerationCopyVerifiedAssetURL(
                    input.sourceURLs[digest], assetsDescriptor, digest,
                    asset.byteCount, cancellationToken, &cloned, error)) {
                success = NO;
                break;
            }
            if (cloned) {
                clonedAssetCount++;
            } else {
                streamedAssetCount++;
            }
        }
    }
    if (success && result == nil) {
        success = MTGenerationSynchronizeDirectory(assetsDescriptor, error) &&
            MTGenerationWriteDataExclusivelyAt(
                transactionDescriptor, MTGenerationIndexFilename,
                input.indexData, error);
    }
    if (success && result == nil) {
        NSData *writtenIndex = MTGenerationReadPrivateFileAt(
            transactionDescriptor, MTGenerationIndexFilename,
            input.indexData.length, error);
        success = [writtenIndex isEqualToData:input.indexData];
        if (!success && writtenIndex != nil &&
            (error == NULL || *error == nil)) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The written Generation index failed its independent readback.",
                nil);
        }
    }
    // generation.json is deliberately the final transaction file.
    if (success && result == nil) {
        success = MTGenerationWriteDataExclusivelyAt(
            transactionDescriptor, MTGenerationDescriptorFilename,
            input.descriptorData, error);
    }
    if (success && result == nil) {
        NSData *writtenDescriptor = MTGenerationReadPrivateFileAt(
            transactionDescriptor, MTGenerationDescriptorFilename,
            input.descriptorData.length, error);
        success = [writtenDescriptor isEqualToData:input.descriptorData];
        if (!success && writtenDescriptor != nil &&
            (error == NULL || *error == nil)) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The written Generation completion marker failed readback.",
                nil);
        }
    }
    if (success && result == nil) {
        success = MTGenerationSynchronizeDirectory(
            transactionDescriptor, error) &&
            MTGenerationWriterVerifyTree(
                transactionDescriptor, input, cancellationToken, error);
    }
    struct stat transactionStatus = {0};
    if (success && result == nil) {
        struct stat transactionPathStatus = {0};
        success = fstat(transactionDescriptor, &transactionStatus) == 0 &&
            S_ISDIR(transactionStatus.st_mode) &&
            transactionStatus.st_uid == geteuid() &&
            (transactionStatus.st_mode & 0777) == 0700 &&
            fstatat(directories.generationsDescriptor,
                    transactionName.fileSystemRepresentation,
                    &transactionPathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
            transactionPathStatus.st_dev == transactionStatus.st_dev &&
            transactionPathStatus.st_ino == transactionStatus.st_ino;
        if (!success) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The complete Generation transaction lost its identity.",
                MTGenerationPOSIXError(errno));
        }
    }
    if (assetsDescriptor >= 0) {
        close(assetsDescriptor);
        assetsDescriptor = -1;
    }
    if (transactionDescriptor >= 0) {
        close(transactionDescriptor);
        transactionDescriptor = -1;
    }
    if (success && result == nil &&
        MTGenerationWriterCancelled(cancellationToken,
            @"Generation writing was cancelled before its atomic rename.",
            error)) {
        success = NO;
    }
    if (success && result == nil) {
        struct stat transactionPathStatus = {0};
        success = fstatat(directories.generationsDescriptor,
            transactionName.fileSystemRepresentation, &transactionPathStatus,
            AT_SYMLINK_NOFOLLOW) == 0 &&
            transactionPathStatus.st_dev == transactionStatus.st_dev &&
            transactionPathStatus.st_ino == transactionStatus.st_ino &&
            S_ISDIR(transactionPathStatus.st_mode) &&
            transactionPathStatus.st_uid == geteuid() &&
            (transactionPathStatus.st_mode & 0777) == 0700;
        if (!success) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The Generation transaction changed before atomic rename.",
                nil);
        }
    }
    if (success && result == nil) {
        int renameResult = renameatx_np(
            directories.generationsDescriptor,
            transactionName.fileSystemRepresentation,
            directories.generationsDescriptor,
            identifier.fileSystemRepresentation, RENAME_EXCL);
        if (renameResult == 0) {
            published = YES;
        } else if (errno == EEXIST) {
            success = MTGenerationDiscardTransaction(
                directories.generationsDescriptor, transactionName,
                self.configuration, error) &&
                MTGenerationWriterVerifyFinal(
                    directories.generationsDescriptor, input,
                    cancellationToken, error);
            if (success) {
                result = [[MTGenerationWriteResult alloc]
                    initWithGenerationIdentifier:identifier
                    generationURL:MTGenerationWriterFinalURL(
                        self.configuration, identifier)
                    reusedExistingGeneration:YES
                    clonedAssetCount:0
                    streamedAssetCount:0];
            }
        } else {
            success = MTGenerationWriterSetError(error,
                MTGenerationWriterErrorStorage,
                @"Unable to atomically publish the immutable Generation.",
                MTGenerationPOSIXError(errno));
        }
    }
    if (success && published) {
        struct stat publishedStatus = {0};
        success = fstatat(directories.generationsDescriptor,
            identifier.fileSystemRepresentation, &publishedStatus,
            AT_SYMLINK_NOFOLLOW) == 0 &&
            publishedStatus.st_dev == transactionStatus.st_dev &&
            publishedStatus.st_ino == transactionStatus.st_ino &&
            S_ISDIR(publishedStatus.st_mode) &&
            publishedStatus.st_uid == geteuid() &&
            (publishedStatus.st_mode & 0777) == 0700 &&
            MTGenerationSynchronizeDirectory(
                directories.generationsDescriptor, error);
        if (!success && (error == NULL || *error == nil)) {
            MTGenerationWriterSetError(error,
                MTGenerationWriterErrorVerification,
                @"The published Generation changed identity after rename.",
                nil);
        }
        if (success) {
            result = [[MTGenerationWriteResult alloc]
                initWithGenerationIdentifier:identifier
                generationURL:MTGenerationWriterFinalURL(
                    self.configuration, identifier)
                reusedExistingGeneration:NO
                clonedAssetCount:clonedAssetCount
                streamedAssetCount:streamedAssetCount];
        }
    }
    if (success) {
        success = MTGenerationStoreDirectoriesAreStable(
            self.configuration, &directories, error);
        if (!success) result = nil;
    }
    if (!success && !published && transactionName != nil) {
        NSError *cleanupError = nil;
        if (!MTGenerationDiscardTransaction(
                directories.generationsDescriptor, transactionName,
                self.configuration, &cleanupError) &&
            (error == NULL || *error == nil)) {
            if (error != NULL) *error = cleanupError;
        }
    }
    close(lockDescriptor);
    MTGenerationStoreDirectoriesClose(&directories);
    return success ? result : nil;
}

@end
