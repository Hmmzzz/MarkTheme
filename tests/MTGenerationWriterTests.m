#import "MTGenerationWriterTests.h"

#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTStaticIconCompiler.h"

static NSUInteger MTGenerationWriterAssertionCount = 0;

static void MTGenerationWriterAssert(BOOL condition, NSString *message) {
    MTGenerationWriterAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTCompiledGeneration (MTGenerationWriterTests)
- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
    (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest;
@end

@interface MTGenerationWriterThresholdToken : MTImportCancellationToken {
    NSUInteger _readCount;
    NSUInteger _threshold;
}
@property(nonatomic, assign, readonly) NSUInteger readCount;
- (instancetype)initWithThreshold:(NSUInteger)threshold;
@end

@implementation MTGenerationWriterThresholdToken
- (instancetype)initWithThreshold:(NSUInteger)threshold {
    self = [super init];
    if (self == nil) return nil;
    _threshold = threshold;
    return self;
}
- (BOOL)isCancelled {
    _readCount++;
    return _readCount >= _threshold;
}
- (NSUInteger)readCount {
    return _readCount;
}
@end

@interface MTGenerationSourceMutationToken : MTImportCancellationToken {
    NSString *_sourcePath;
    NSString *_generationsPath;
}
@property(nonatomic, assign, readonly) BOOL mutationSucceeded;
- (instancetype)initWithSourcePath:(NSString *)sourcePath
                   generationsPath:(NSString *)generationsPath;
@end

@implementation MTGenerationSourceMutationToken
- (instancetype)initWithSourcePath:(NSString *)sourcePath
                   generationsPath:(NSString *)generationsPath {
    self = [super init];
    if (self == nil) return nil;
    _sourcePath = [sourcePath copy];
    _generationsPath = [generationsPath copy];
    return self;
}
- (BOOL)isCancelled {
    if (_mutationSucceeded) return NO;
    for (NSString *name in [NSFileManager.defaultManager
             contentsOfDirectoryAtPath:_generationsPath error:NULL]) {
        if (![name hasPrefix:@".transaction-"]) continue;
        NSString *assetsPath = [[_generationsPath
            stringByAppendingPathComponent:name]
            stringByAppendingPathComponent:@"assets"];
        if ([NSFileManager.defaultManager
                contentsOfDirectoryAtPath:assetsPath error:NULL].count == 0) {
            continue;
        }
        int descriptor = open(_sourcePath.fileSystemRepresentation,
                              O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        uint8_t byte = 0x6c;
        _mutationSucceeded = descriptor >= 0 &&
            pwrite(descriptor, &byte, 1, 16) == 1;
        if (descriptor >= 0) close(descriptor);
        if (_mutationSucceeded) return NO;
    }
    return NO;
}
@end

@interface MTGenerationDestinationMutationToken : MTImportCancellationToken {
    NSString *_generationsPath;
}
@property(nonatomic, assign, readonly) BOOL mutationSucceeded;
- (instancetype)initWithGenerationsPath:(NSString *)generationsPath;
@end

@implementation MTGenerationDestinationMutationToken
- (instancetype)initWithGenerationsPath:(NSString *)generationsPath {
    self = [super init];
    if (self == nil) return nil;
    _generationsPath = [generationsPath copy];
    return self;
}
- (BOOL)isCancelled {
    if (_mutationSucceeded) return NO;
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:_generationsPath error:NULL];
    for (NSString *name in names) {
        if (![name hasPrefix:@".transaction-"]) continue;
        NSString *assetsPath = [[_generationsPath
            stringByAppendingPathComponent:name]
            stringByAppendingPathComponent:@"assets"];
        NSArray<NSString *> *assets = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:assetsPath error:NULL];
        for (NSString *assetName in assets) {
            NSString *assetPath = [assetsPath
                stringByAppendingPathComponent:assetName];
            struct stat status = {0};
            if (lstat(assetPath.fileSystemRepresentation, &status) != 0 ||
                !S_ISREG(status.st_mode) || status.st_size <= 16) {
                continue;
            }
            int descriptor = open(assetPath.fileSystemRepresentation,
                                  O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
            uint8_t byte = 0xa5;
            _mutationSucceeded = descriptor >= 0 &&
                pwrite(descriptor, &byte, 1, 16) == 1;
            if (descriptor >= 0) close(descriptor);
            if (_mutationSucceeded) return NO;
        }
    }
    return NO;
}
@end

static NSString *MTGenerationWriterTemporaryDirectory(NSString *label) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"marktheme-generation-writer-%@.XXXXXX", label]];
    NSMutableData *buffer = [[template
        dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    MTGenerationWriterAssert(mkdtemp(path) != NULL,
        @"Generation writer test root must be created");
    return [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:path length:strlen(path)];
}

static BOOL MTGenerationWriterCreateDirectory(NSString *path) {
    NSError *error = nil;
    return [NSFileManager.defaultManager
        createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error] &&
        chmod(path.fileSystemRepresentation, 0700) == 0;
}

static BOOL MTGenerationWriterWritePrivateData(NSData *data,
                                               NSString *path) {
    NSError *error = nil;
    return [data writeToFile:path options:0 error:&error] &&
        chmod(path.fileSystemRepresentation, 0600) == 0;
}

static MTCompiledGeneration *MTGenerationWriterCloneCompilerResult(
    MTCompiledGeneration *compiledGeneration,
    NSString *sourceDirectory,
    NSError **error) {
    if (!MTGenerationWriterCreateDirectory(sourceDirectory)) return nil;
    NSMutableDictionary<NSString *, NSURL *> *urls =
        [NSMutableDictionary dictionary];
    for (MTGenerationAssetDescriptor *asset in
             compiledGeneration.descriptor.assets) {
        NSURL *sourceURL =
            compiledGeneration.sourceAssetURLsByContentSHA256[
                asset.contentSHA256];
        NSData *data = [NSData dataWithContentsOfURL:sourceURL
                                             options:0 error:error];
        NSString *path = [sourceDirectory
            stringByAppendingPathComponent:asset.contentSHA256];
        if (data == nil ||
            !MTGenerationWriterWritePrivateData(data, path)) {
            return nil;
        }
        urls[asset.contentSHA256] = [NSURL fileURLWithPath:path];
    }
    return [[MTCompiledGeneration alloc]
        initWithDescriptor:compiledGeneration.descriptor
                     index:compiledGeneration.index
   sourceAssetURLsByDigest:urls];
}

static MTGenerationWriter *MTGenerationWriterForPath(
    NSString *path,
    NSUInteger maximumAssetCount,
    uint64_t maximumByteCount,
    uint64_t reserveBytes) {
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:path isDirectory:YES]
            maximumAssetCount:maximumAssetCount
            maximumGenerationByteCount:maximumByteCount
            minimumFreeSpaceReserveBytes:reserveBytes
            maximumRecoveryNodeCount:MAX((NSUInteger)32,
                                         maximumAssetCount + 3)];
    return [[MTGenerationWriter alloc]
        initWithConfiguration:configuration];
}

static BOOL MTGenerationWriterPathHasMode(NSString *path, mode_t mode) {
    struct stat status = {0};
    return lstat(path.fileSystemRepresentation, &status) == 0 &&
        (status.st_mode & 0777) == mode;
}

static NSArray<NSString *> *MTGenerationWriterDirectoryNames(NSString *path) {
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:path error:NULL];
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

static NSUInteger MTGenerationWriterTransactionCount(NSString *path) {
    NSUInteger count = 0;
    for (NSString *name in MTGenerationWriterDirectoryNames(path)) {
        if ([name hasPrefix:@".transaction-"]) count++;
    }
    return count;
}

static NSString *MTGenerationWriterTransactionName(void) {
    return [@".transaction-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
}

static BOOL MTGenerationWriterTreesHaveEqualBytes(
    NSString *firstPath,
    NSString *secondPath,
    NSArray<NSString *> *assetDigests) {
    NSArray<NSString *> *relativeFiles = @[
        @"index.mtg", @"generation.json"
    ];
    for (NSString *relativePath in relativeFiles) {
        NSData *first = [NSData dataWithContentsOfFile:
            [firstPath stringByAppendingPathComponent:relativePath]];
        NSData *second = [NSData dataWithContentsOfFile:
            [secondPath stringByAppendingPathComponent:relativePath]];
        if (first == nil || ![first isEqualToData:second]) return NO;
    }
    for (NSString *digest in assetDigests) {
        NSString *relativePath = [@"assets"
            stringByAppendingPathComponent:digest];
        NSData *first = [NSData dataWithContentsOfFile:
            [firstPath stringByAppendingPathComponent:relativePath]];
        NSData *second = [NSData dataWithContentsOfFile:
            [secondPath stringByAppendingPathComponent:relativePath]];
        if (first == nil || ![first isEqualToData:second]) return NO;
    }
    return YES;
}

NSUInteger MTRunGenerationWriterTests(
    MTCompiledGeneration *compiledGeneration) {
    MTGenerationWriterAssertionCount = 0;
    MTGenerationWriterAssert(
        [compiledGeneration isKindOfClass:MTCompiledGeneration.class] &&
        compiledGeneration.descriptor.assetCount > 0,
        @"Generation writer tests require a real non-empty compiler result");
    NSString *root = MTGenerationWriterTemporaryDirectory(@"contracts");
    NSString *sourceDirectory = [root
        stringByAppendingPathComponent:@"sources"];
    NSError *error = nil;
    MTCompiledGeneration *fixture =
        MTGenerationWriterCloneCompilerResult(
            compiledGeneration, sourceDirectory, &error);
    MTGenerationWriterAssert(fixture != nil && error == nil,
        @"Generation writer fixture must clone Library-owned sources");
    NSUInteger assetCount = fixture.descriptor.assetCount;
    uint64_t maximumBytes = 1024ULL * 1024ULL * 1024ULL;

    NSString *storeA = [root stringByAppendingPathComponent:@"store-a"];
    MTGenerationWriter *writerA = MTGenerationWriterForPath(
        storeA, 20000, maximumBytes, 0);
    error = nil;
    MTGenerationWriteResult *first = [writerA
        writeCompiledGeneration:fixture cancellationToken:nil error:&error];
    NSString *identifier = fixture.descriptor.generationIdentifier;
    NSString *generationsA = [storeA
        stringByAppendingPathComponent:@"generations"];
    NSString *finalA = [generationsA
        stringByAppendingPathComponent:identifier];
    NSString *assetsA = [finalA stringByAppendingPathComponent:@"assets"];
    MTGenerationWriterAssert(first != nil && error == nil &&
        !first.reusedExistingGeneration &&
        [first.generationIdentifier isEqualToString:identifier] &&
        first.clonedAssetCount + first.streamedAssetCount == assetCount &&
        [first.generationURL.path isEqualToString:finalA],
        @"Writer must publish one new Generation and report its copy paths");
    MTGenerationWriterAssert(
        MTGenerationWriterPathHasMode(storeA, 0700) &&
        MTGenerationWriterPathHasMode(generationsA, 0700) &&
        MTGenerationWriterPathHasMode(finalA, 0700) &&
        MTGenerationWriterPathHasMode(assetsA, 0700) &&
        MTGenerationWriterPathHasMode(
            [finalA stringByAppendingPathComponent:@"index.mtg"], 0600) &&
        MTGenerationWriterPathHasMode(
            [finalA stringByAppendingPathComponent:@"generation.json"], 0600),
        @"Published Generation directories and metadata must stay private");
    NSArray<NSString *> *sortedDigests = [fixture.descriptor.assets
        valueForKey:@"contentSHA256"];
    sortedDigests = [sortedDigests
        sortedArrayUsingSelector:@selector(compare:)];
    MTGenerationWriterAssert(
        [MTGenerationWriterDirectoryNames(finalA) isEqualToArray:@[
            @"assets", @"generation.json", @"index.mtg"
        ]] &&
        [MTGenerationWriterDirectoryNames(assetsA)
            isEqualToArray:sortedDigests] &&
        [[NSData dataWithContentsOfFile:
            [finalA stringByAppendingPathComponent:@"index.mtg"]]
            isEqualToData:fixture.index.encodedData] &&
        [[NSData dataWithContentsOfFile:
            [finalA stringByAppendingPathComponent:@"generation.json"]]
            isEqualToData:fixture.descriptor.canonicalData],
        @"Published Generation tree must contain only exact compiler bytes");

    error = nil;
    MTGenerationWriteResult *reused = [writerA
        writeCompiledGeneration:fixture cancellationToken:nil error:&error];
    MTGenerationWriterAssert(reused != nil && error == nil &&
        reused.reusedExistingGeneration && reused.clonedAssetCount == 0 &&
        reused.streamedAssetCount == 0 &&
        [MTGenerationWriterDirectoryNames(generationsA)
            isEqualToArray:@[identifier]],
        @"Identical writes must fully validate and reuse one immutable tree");

    NSString *storeB = [root stringByAppendingPathComponent:@"store-b"];
    MTGenerationWriter *writerB = MTGenerationWriterForPath(
        storeB, 20000, maximumBytes, 0);
    error = nil;
    MTGenerationWriteResult *secondRoot = [writerB
        writeCompiledGeneration:fixture cancellationToken:nil error:&error];
    NSString *finalB = [[[storeB stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:identifier] copy];
    MTGenerationWriterAssert(secondRoot != nil && error == nil &&
        MTGenerationWriterTreesHaveEqualBytes(
            finalA, finalB, sortedDigests),
        @"Different App-owned roots must publish byte-identical trees");

    error = nil;
    MTGenerationDescriptor *alternateDescriptor =
        [[MTGenerationDescriptor alloc]
            initWithThemeID:@"theme.generation-writer-alternate"
            libraryRevisionIdentifier:
                fixture.descriptor.libraryRevisionIdentifier
            manifestDigest:fixture.descriptor.manifestDigest
            indexSHA256:fixture.descriptor.indexSHA256
            indexByteCount:fixture.descriptor.indexByteCount
            indexFormatVersion:fixture.descriptor.indexFormatVersion
            resourceCount:fixture.descriptor.resourceCount
            assets:fixture.descriptor.assets
            moduleIDs:fixture.descriptor.moduleIDs
            error:&error];
    MTCompiledGeneration *alternateFixture = alternateDescriptor == nil ? nil :
        [[MTCompiledGeneration alloc]
            initWithDescriptor:alternateDescriptor
            index:fixture.index
            sourceAssetURLsByDigest:
                fixture.sourceAssetURLsByContentSHA256];
    NSString *alternateIdentifier =
        alternateDescriptor.generationIdentifier ?: @"invalid-generation";
    MTGenerationWriteResult *alternateResult = alternateFixture == nil ? nil :
        [writerA writeCompiledGeneration:alternateFixture
                       cancellationToken:nil error:&error];
    NSString *alternateFinal = [generationsA stringByAppendingPathComponent:
        alternateIdentifier];
    MTGenerationWriterAssert(alternateDescriptor != nil &&
        alternateFixture != nil && alternateResult != nil && error == nil &&
        ![alternateIdentifier isEqualToString:identifier] &&
        access(finalA.fileSystemRepresentation, F_OK) == 0 &&
        access(alternateFinal.fileSystemRepresentation, F_OK) == 0 &&
        MTGenerationWriterDirectoryNames(generationsA).count == 2,
        @"Publishing a second Generation must preserve the previous immutable tree");

    int heldLock = open([[storeA stringByAppendingPathComponent:
        @"transaction.lock"] fileSystemRepresentation],
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    MTGenerationWriterAssert(heldLock >= 0 &&
        flock(heldLock, LOCK_EX | LOCK_NB) == 0,
        @"Writer contention fixture must hold the store lock");
    error = nil;
    MTGenerationWriterAssert([writerA
        writeCompiledGeneration:fixture cancellationToken:nil error:&error] == nil &&
        [error.domain isEqualToString:MTGenerationWriterErrorDomain] &&
        error.code == MTGenerationWriterErrorBusy,
        @"A contended Generation store must fail quickly without mutation");
    MTGenerationWriterAssert(flock(heldLock, LOCK_UN) == 0 &&
        close(heldLock) == 0,
        @"Writer contention fixture must release its lock");

    NSString *storeCancelled = [root
        stringByAppendingPathComponent:@"store-pre-cancel"];
    MTGenerationWriter *cancelledWriter = MTGenerationWriterForPath(
        storeCancelled, 20000, maximumBytes, 0);
    MTImportCancellationToken *preCancelled =
        [[MTImportCancellationToken alloc] init];
    [preCancelled cancel];
    error = nil;
    MTGenerationWriterAssert([cancelledWriter
        writeCompiledGeneration:fixture cancellationToken:preCancelled
        error:&error] == nil &&
        error.code == MTGenerationWriterErrorCancelled &&
        access(storeCancelled.fileSystemRepresentation, F_OK) != 0,
        @"Pre-cancellation must not create the Generation store");

    NSString *storeMidCancel = [root
        stringByAppendingPathComponent:@"store-mid-cancel"];
    MTGenerationWriter *midCancelWriter = MTGenerationWriterForPath(
        storeMidCancel, 20000, maximumBytes, 0);
    MTGenerationWriterThresholdToken *midCancel =
        [[MTGenerationWriterThresholdToken alloc] initWithThreshold:5];
    error = nil;
    MTGenerationWriterAssert([midCancelWriter
        writeCompiledGeneration:fixture cancellationToken:midCancel
        error:&error] == nil &&
        error.code == MTGenerationWriterErrorCancelled &&
        midCancel.readCount >= 5 &&
        MTGenerationWriterTransactionCount([storeMidCancel
            stringByAppendingPathComponent:@"generations"]) == 0 &&
        ![NSFileManager.defaultManager fileExistsAtPath:[[storeMidCancel
            stringByAppendingPathComponent:@"generations"]
            stringByAppendingPathComponent:identifier]],
        @"Mid-write cancellation must remove its unpublished transaction");

    NSString *storeNoSpace = [root
        stringByAppendingPathComponent:@"store-no-space"];
    MTGenerationWriter *noSpaceWriter = MTGenerationWriterForPath(
        storeNoSpace, 20000, maximumBytes, UINT64_MAX);
    error = nil;
    MTGenerationWriterAssert([noSpaceWriter
        writeCompiledGeneration:fixture cancellationToken:nil error:&error] == nil &&
        error.code == MTGenerationWriterErrorInsufficientSpace &&
        MTGenerationWriterDirectoryNames([storeNoSpace
            stringByAppendingPathComponent:@"generations"]).count == 0,
        @"Space admission must reject before a Generation transaction is created");

    NSString *storeLimit = [root
        stringByAppendingPathComponent:@"store-limit"];
    MTGenerationWriter *limitedWriter = MTGenerationWriterForPath(
        storeLimit, MAX((NSUInteger)1, assetCount - 1), maximumBytes, 0);
    error = nil;
    MTGenerationWriterAssert([limitedWriter
        writeCompiledGeneration:fixture cancellationToken:nil error:&error] == nil &&
        error.code == MTGenerationWriterErrorLimitExceeded &&
        access(storeLimit.fileSystemRepresentation, F_OK) != 0,
        @"Writer limits must reject compiler output before opening the store");

    NSString *mutatedSources = [root
        stringByAppendingPathComponent:@"mutated-sources"];
    error = nil;
    MTCompiledGeneration *mutatedFixture =
        MTGenerationWriterCloneCompilerResult(
            compiledGeneration, mutatedSources, &error);
    NSString *mutatedDigest = sortedDigests.firstObject;
    NSString *mutatedSourcePath = [mutatedSources
        stringByAppendingPathComponent:mutatedDigest];
    int sourceMutation = open(mutatedSourcePath.fileSystemRepresentation,
                              O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    uint8_t mutationByte = 0x5a;
    MTGenerationWriterAssert(sourceMutation >= 0 &&
        pwrite(sourceMutation, &mutationByte, 1, 16) == 1 &&
        close(sourceMutation) == 0,
        @"Source corruption fixture must preserve the declared file size");
    NSString *storeSourceMutation = [root
        stringByAppendingPathComponent:@"store-source-mutation"];
    error = nil;
    MTGenerationWriterAssert([MTGenerationWriterForPath(
        storeSourceMutation, 20000, maximumBytes, 0)
        writeCompiledGeneration:mutatedFixture cancellationToken:nil
        error:&error] == nil &&
        error.code == MTGenerationWriterErrorVerification &&
        MTGenerationWriterTransactionCount([storeSourceMutation
            stringByAppendingPathComponent:@"generations"]) == 0,
        @"Writer must rehash and reject a same-size Library source mutation");

    NSString *midMutationSources = [root
        stringByAppendingPathComponent:@"mid-mutation-sources"];
    error = nil;
    MTCompiledGeneration *midMutationFixture =
        MTGenerationWriterCloneCompilerResult(
            compiledGeneration, midMutationSources, &error);
    NSString *storeMidMutation = [root
        stringByAppendingPathComponent:@"store-mid-source-mutation"];
    NSString *midMutationGenerations = [storeMidMutation
        stringByAppendingPathComponent:@"generations"];
    MTGenerationSourceMutationToken *sourceMutationToken =
        [[MTGenerationSourceMutationToken alloc]
            initWithSourcePath:[midMutationSources
                stringByAppendingPathComponent:mutatedDigest]
            generationsPath:midMutationGenerations];
    error = nil;
    MTGenerationWriterAssert([MTGenerationWriterForPath(
        storeMidMutation, 20000, maximumBytes, 0)
        writeCompiledGeneration:midMutationFixture
        cancellationToken:sourceMutationToken error:&error] == nil &&
        sourceMutationToken.mutationSucceeded &&
        error.code == MTGenerationWriterErrorVerification &&
        MTGenerationWriterTransactionCount(midMutationGenerations) == 0,
        @"A Library source mutation during copy must fail stability checks and roll back");

    NSString *storeDestinationMutation = [root
        stringByAppendingPathComponent:@"store-destination-mutation"];
    NSString *destinationGenerations = [storeDestinationMutation
        stringByAppendingPathComponent:@"generations"];
    MTGenerationDestinationMutationToken *destinationMutation =
        [[MTGenerationDestinationMutationToken alloc]
            initWithGenerationsPath:destinationGenerations];
    error = nil;
    MTGenerationWriterAssert([MTGenerationWriterForPath(
        storeDestinationMutation, 20000, maximumBytes, 0)
        writeCompiledGeneration:fixture
        cancellationToken:destinationMutation error:&error] == nil &&
        destinationMutation.mutationSucceeded &&
        error.code == MTGenerationWriterErrorVerification &&
        MTGenerationWriterTransactionCount(destinationGenerations) == 0,
        @"Destination tampering must fail independent rehash and roll back");

    NSString *storeRecovery = [root
        stringByAppendingPathComponent:@"store-recovery"];
    MTGenerationWriter *recoveryWriter = MTGenerationWriterForPath(
        storeRecovery, 20000, maximumBytes, 0);
    error = nil;
    MTGenerationWriterAssert([recoveryWriter
        recoverAbandonedTransactionsWithError:&error] && error == nil,
        @"An empty Generation store must initialize and recover");
    NSString *recoveryGenerations = [storeRecovery
        stringByAppendingPathComponent:@"generations"];
    NSString *abandonedName = MTGenerationWriterTransactionName();
    NSString *abandonedPath = [recoveryGenerations
        stringByAppendingPathComponent:abandonedName];
    NSString *abandonedAssets = [abandonedPath
        stringByAppendingPathComponent:@"assets"];
    MTGenerationWriterAssert(
        MTGenerationWriterCreateDirectory(abandonedAssets) &&
        MTGenerationWriterWritePrivateData(
            [NSData dataWithContentsOfFile:[sourceDirectory
                stringByAppendingPathComponent:mutatedDigest]],
            [abandonedAssets stringByAppendingPathComponent:mutatedDigest]) &&
        MTGenerationWriterWritePrivateData(
            fixture.index.encodedData,
            [abandonedPath stringByAppendingPathComponent:@"index.mtg"]),
        @"Canonical abandoned Generation transaction must be constructed");
    error = nil;
    MTGenerationWriterAssert([recoveryWriter
        recoverAbandonedTransactionsWithError:&error] && error == nil &&
        access(abandonedPath.fileSystemRepresentation, F_OK) != 0,
        @"Startup recovery must remove a bounded canonical partial transaction");

    NSString *guardedName = MTGenerationWriterTransactionName();
    NSString *guardedPath = [recoveryGenerations
        stringByAppendingPathComponent:guardedName];
    NSString *guardedUnknown = [guardedPath
        stringByAppendingPathComponent:@"unexpected"];
    MTGenerationWriterAssert(MTGenerationWriterCreateDirectory(guardedPath) &&
        MTGenerationWriterWritePrivateData(
            [@"keep" dataUsingEncoding:NSUTF8StringEncoding], guardedUnknown),
        @"Guarded recovery transaction must contain its unknown node");
    error = nil;
    MTGenerationWriterAssert(![recoveryWriter
        recoverAbandonedTransactionsWithError:&error] &&
        error.code == MTGenerationWriterErrorRecovery &&
        access(guardedUnknown.fileSystemRepresentation, F_OK) == 0,
        @"Recovery must refuse and preserve an unknown transaction node");
    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:guardedPath error:&error],
        @"Test owner must explicitly remove its guarded transaction");

    NSString *symlinkName = MTGenerationWriterTransactionName();
    NSString *symlinkPath = [recoveryGenerations
        stringByAppendingPathComponent:symlinkName];
    NSString *symlinkAssets = [symlinkPath
        stringByAppendingPathComponent:@"assets"];
    NSString *symlinkAsset = [symlinkAssets
        stringByAppendingPathComponent:mutatedDigest];
    NSString *symlinkTarget = [sourceDirectory
        stringByAppendingPathComponent:mutatedDigest];
    MTGenerationWriterAssert(MTGenerationWriterCreateDirectory(symlinkAssets) &&
        symlink(symlinkTarget.fileSystemRepresentation,
                                     symlinkAsset.fileSystemRepresentation) == 0,
        @"Recovery symlink fixture must be created");
    error = nil;
    MTGenerationWriterAssert(![recoveryWriter
        recoverAbandonedTransactionsWithError:&error] &&
        error.code == MTGenerationWriterErrorRecovery &&
        lstat(symlinkAsset.fileSystemRepresentation, &(struct stat){0}) == 0,
        @"Recovery must not follow or delete a transaction asset symlink");
    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:symlinkPath error:&error],
        @"Test owner must explicitly remove its symlink transaction");

    NSString *malformedPath = [recoveryGenerations
        stringByAppendingPathComponent:@".transaction-not-a-uuid"];
    MTGenerationWriterAssert(MTGenerationWriterCreateDirectory(malformedPath),
        @"Malformed transaction-name fixture must be created");
    error = nil;
    MTGenerationWriterAssert(![recoveryWriter
        recoverAbandonedTransactionsWithError:&error] &&
        error.code == MTGenerationWriterErrorRecovery &&
        access(malformedPath.fileSystemRepresentation, F_OK) == 0,
        @"Recovery must reject a malformed transaction name without deletion");
    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:malformedPath error:&error],
        @"Test owner must remove the malformed transaction fixture");

    NSString *unknownFinalPath = [recoveryGenerations
        stringByAppendingPathComponent:@"unknown"];
    MTGenerationWriterAssert(MTGenerationWriterWritePrivateData(
        [@"keep" dataUsingEncoding:NSUTF8StringEncoding], unknownFinalPath),
        @"Unknown first-level Generation node fixture must be created");
    error = nil;
    MTGenerationWriterAssert(![recoveryWriter
        recoverAbandonedTransactionsWithError:&error] &&
        error.code == MTGenerationWriterErrorRecovery &&
        access(unknownFinalPath.fileSystemRepresentation, F_OK) == 0,
        @"Recovery must reject and preserve an unknown first-level node");
    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:unknownFinalPath error:&error],
        @"Test owner must remove the unknown first-level fixture");

    NSString *unknownRootPath = [storeRecovery
        stringByAppendingPathComponent:@"unexpected-root-node"];
    MTGenerationWriterAssert(MTGenerationWriterWritePrivateData(
        [@"keep" dataUsingEncoding:NSUTF8StringEncoding], unknownRootPath),
        @"Unknown Generation root node fixture must be created");
    error = nil;
    MTGenerationWriterAssert(![recoveryWriter
        recoverAbandonedTransactionsWithError:&error] &&
        error.code == MTGenerationWriterErrorRecovery &&
        access(unknownRootPath.fileSystemRepresentation, F_OK) == 0,
        @"Recovery must reject and preserve an unknown compiler-root node");
    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:unknownRootPath error:&error],
        @"Test owner must remove the unknown compiler-root fixture");

    error = nil;
    MTGenerationWriterAssert([writerB
        recoverAbandonedTransactionsWithError:&error] && error == nil &&
        access(finalB.fileSystemRepresentation, F_OK) == 0,
        @"Recovery must preserve canonical published Generation directories");
    NSString *extraFinalNode = [finalB
        stringByAppendingPathComponent:@"unexpected"];
    MTGenerationWriterAssert(MTGenerationWriterWritePrivateData(
        [@"extra" dataUsingEncoding:NSUTF8StringEncoding], extraFinalNode),
        @"Existing-tree corruption fixture must add one private extra node");
    error = nil;
    MTGenerationWriterAssert([writerB
        writeCompiledGeneration:fixture cancellationToken:nil error:&error] == nil &&
        error.code == MTGenerationWriterErrorVerification &&
        access(extraFinalNode.fileSystemRepresentation, F_OK) == 0,
        @"Idempotence must reject rather than repair an in-place final mutation");

    NSString *publishedAsset = [assetsA
        stringByAppendingPathComponent:sortedDigests.firstObject];
    int publishedMutation = open(publishedAsset.fileSystemRepresentation,
                                 O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    mutationByte = 0xc3;
    MTGenerationWriterAssert(publishedMutation >= 0 &&
        pwrite(publishedMutation, &mutationByte, 1, 16) == 1 &&
        close(publishedMutation) == 0,
        @"Published corruption fixture must preserve asset size and metadata");
    error = nil;
    MTGenerationWriterAssert([writerA
        writeCompiledGeneration:fixture cancellationToken:nil error:&error] == nil &&
        error.code == MTGenerationWriterErrorVerification &&
        MTGenerationWriterTransactionCount(generationsA) == 0 &&
        access(alternateFinal.fileSystemRepresentation, F_OK) == 0,
        @"Writer must never overwrite a corrupted same-ID final or damage another Generation");

    NSDictionary<NSString *, NSURL *> *missingSources =
        fixture.sourceAssetURLsByContentSHA256.count > 0 ? @{} : nil;
    MTCompiledGeneration *missingSourceFixture = [[MTCompiledGeneration alloc]
        initWithDescriptor:fixture.descriptor index:fixture.index
        sourceAssetURLsByDigest:missingSources];
    NSString *storeMissingSource = [root
        stringByAppendingPathComponent:@"store-missing-source"];
    error = nil;
    MTGenerationWriterAssert([MTGenerationWriterForPath(
        storeMissingSource, 20000, maximumBytes, 0)
        writeCompiledGeneration:missingSourceFixture cancellationToken:nil
        error:&error] == nil &&
        error.code == MTGenerationWriterErrorVerification &&
        access(storeMissingSource.fileSystemRepresentation, F_OK) != 0,
        @"Writer must reject a compiler result without its exact source map");

    MTGenerationWriterAssert([NSFileManager.defaultManager
        removeItemAtPath:root error:&error],
        @"Generation writer test root must be removable by its owner");
    return MTGenerationWriterAssertionCount;
}
