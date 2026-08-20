#import "MTGenerationReaderTests.h"

#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationWriter.h"
#import "MTImportSession.h"
#import "MTResourceKey.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTSafeImageInspector.h"
#import "MTStaticIconCompiler.h"

static NSUInteger MTGenerationReaderAssertionCount = 0;

static void MTGenerationReaderAssert(BOOL condition, NSString *message) {
    MTGenerationReaderAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static void MTGenerationReaderRequire(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTGenerationReaderThresholdToken : MTImportCancellationToken {
    NSUInteger _readCount;
    NSUInteger _threshold;
}
@property(nonatomic, assign, readonly) NSUInteger readCount;
- (instancetype)initWithThreshold:(NSUInteger)threshold;
@end

@implementation MTGenerationReaderThresholdToken
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

@interface MTGenerationReaderMutationToken : MTImportCancellationToken {
    NSUInteger _readCount;
    NSUInteger _trigger;
    NSString *_path;
}
@property(nonatomic, assign, readonly) BOOL mutationSucceeded;
- (instancetype)initWithPath:(NSString *)path
                      trigger:(NSUInteger)trigger;
@end

@implementation MTGenerationReaderMutationToken
- (instancetype)initWithPath:(NSString *)path
                      trigger:(NSUInteger)trigger {
    self = [super init];
    if (self == nil) return nil;
    _path = [path copy];
    _trigger = trigger;
    return self;
}
- (BOOL)isCancelled {
    _readCount++;
    if (!_mutationSucceeded && _readCount == _trigger) {
        int descriptor = open(_path.fileSystemRepresentation,
                              O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        uint8_t byte = 0x5a;
        _mutationSucceeded = descriptor >= 0 &&
            pwrite(descriptor, &byte, 1, 16) == 1;
        if (descriptor >= 0) close(descriptor);
    }
    return NO;
}
@end

static NSString *MTGenerationReaderTemporaryDirectory(void) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            @"marktheme-generation-reader.XXXXXX"];
    NSMutableData *buffer = [[template
        dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    MTGenerationReaderRequire(mkdtemp(path) != NULL,
        @"Generation reader test root must be created");
    return [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:path length:strlen(path)];
}

static BOOL MTGenerationReaderCreateDirectory(NSString *path) {
    NSError *error = nil;
    return [NSFileManager.defaultManager
        createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:&error] &&
        chmod(path.fileSystemRepresentation, 0700) == 0;
}

static BOOL MTGenerationReaderWriteData(NSData *data, NSString *path) {
    NSError *error = nil;
    return [data writeToFile:path options:0 error:&error] &&
        chmod(path.fileSystemRepresentation, 0600) == 0;
}

static MTGenerationWriter *MTGenerationReaderWriter(NSString *path) {
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:path isDirectory:YES]
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:25000];
    return [[MTGenerationWriter alloc]
        initWithConfiguration:configuration];
}

static MTGenerationReader *MTGenerationReaderForPath(
    NSString *path,
    NSUInteger maximumAssetCount,
    uint64_t maximumGenerationByteCount) {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:[NSURL fileURLWithPath:path isDirectory:YES]
            maximumAssetCount:maximumAssetCount
            maximumGenerationByteCount:maximumGenerationByteCount
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    return [[MTGenerationReader alloc] initWithConfiguration:configuration];
}

static NSString *MTGenerationReaderPublish(
    NSString *testRoot,
    NSString *label,
    MTCompiledGeneration *compiledGeneration) {
    NSString *store = [testRoot stringByAppendingPathComponent:label];
    NSError *error = nil;
    MTGenerationWriteResult *result = [MTGenerationReaderWriter(store)
        writeCompiledGeneration:compiledGeneration
        cancellationToken:nil
        error:&error];
    MTGenerationReaderRequire(result != nil && error == nil,
        [NSString stringWithFormat:
            @"Generation reader fixture %@ must publish (%@)", label,
            error.localizedDescription ?: @"no error"]);
    return store;
}

static NSString *MTGenerationReaderFinalPath(
    NSString *store,
    NSString *generationIdentifier) {
    return [[store stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:generationIdentifier];
}

static MTGeneration *MTGenerationReaderRead(
    NSString *store,
    NSString *generationIdentifier,
    MTImportCancellationToken *token,
    NSError **error) {
    return [MTGenerationReaderForPath(
        store, 20000, 1024ULL * 1024ULL * 1024ULL)
        readGenerationWithIdentifier:generationIdentifier
        cancellationToken:token
        error:error];
}

static BOOL MTGenerationReaderFails(
    NSString *store,
    NSString *identifier,
    MTGenerationReaderErrorCode expectedCode) {
    NSError *error = nil;
    MTGeneration *generation = MTGenerationReaderRead(
        store, identifier, nil, &error);
    return generation == nil &&
        [error.domain isEqualToString:MTGenerationReaderErrorDomain] &&
        error.code == expectedCode;
}

static NSString *MTGenerationReaderFirstAssetPath(
    NSString *store,
    MTCompiledGeneration *compiledGeneration) {
    NSString *digest = [compiledGeneration.descriptor.assets.firstObject
        contentSHA256];
    return [[MTGenerationReaderFinalPath(
        store, compiledGeneration.descriptor.generationIdentifier)
        stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:digest];
}

NSUInteger MTRunGenerationReaderTests(
    MTCompiledGeneration *compiledGeneration) {
    MTGenerationReaderAssertionCount = 0;
    MTGenerationReaderAssert(
        [compiledGeneration isKindOfClass:MTCompiledGeneration.class] &&
        compiledGeneration.descriptor.assetCount > 1,
        @"Generation reader tests require a real multi-asset compiler result");
    NSString *root = MTGenerationReaderTemporaryDirectory();
    NSString *identifier = compiledGeneration.descriptor.generationIdentifier;
    NSError *error = nil;

    NSString *validStore = MTGenerationReaderPublish(
        root, @"valid", compiledGeneration);
    MTGeneration *generation = MTGenerationReaderRead(
        validStore, identifier, nil, &error);
    NSString *validFinal = MTGenerationReaderFinalPath(validStore, identifier);
    MTGenerationReaderAssert(generation != nil && error == nil &&
        [generation.generationIdentifier isEqualToString:identifier] &&
        [generation.generationURL.path isEqualToString:validFinal] &&
        [generation.descriptor.canonicalData
            isEqualToData:compiledGeneration.descriptor.canonicalData] &&
        [generation.index.encodedData
            isEqualToData:compiledGeneration.index.encodedData],
        @"Reader must independently reconstruct the exact immutable Generation");

    BOOL allLookupsMatch = YES;
    for (NSUInteger index = 0;
         index < compiledGeneration.index.recordCount; index++) {
        MTGenerationIndexRecord *record = [compiledGeneration.index
            recordAtIndex:index];
        error = nil;
        MTGenerationResource *resource = [generation
            resourceForCanonicalResourceKey:record.canonicalResourceKey
            error:&error];
        NSString *expectedPath = [[validFinal
            stringByAppendingPathComponent:@"assets"]
            stringByAppendingPathComponent:record.contentSHA256];
        allLookupsMatch = allLookupsMatch && resource != nil && error == nil &&
            [resource.canonicalResourceKey
                isEqualToString:record.canonicalResourceKey] &&
            [resource.contentSHA256 isEqualToString:record.contentSHA256] &&
            resource.assetByteCount == record.assetByteCount &&
            [resource.assetURL.path isEqualToString:expectedPath];
    }
    MTGenerationReaderAssert(allLookupsMatch,
        @"Reader lookup must preserve every fixed-index resource reference");

    MTGenerationIndexRecord *firstRecord =
        [compiledGeneration.index recordAtIndex:0];
    error = nil;
    MTGenerationResource *firstResource = [generation
        resourceForCanonicalResourceKey:firstRecord.canonicalResourceKey
        error:&error];
    NSData *expectedAssetData = [NSData dataWithContentsOfURL:
        compiledGeneration.sourceAssetURLsByContentSHA256[
            firstRecord.contentSHA256]];
    NSData *verifiedAssetData = [generation
        verifiedAssetDataForResource:firstResource
        maximumByteCount:32ULL * 1024ULL * 1024ULL
        error:&error];
    MTGenerationReaderAssert(firstResource != nil &&
        verifiedAssetData != nil &&
        [verifiedAssetData isEqualToData:expectedAssetData] && error == nil,
        @"A validated Generation must reopen exact asset bytes relative to its retained directory");

    NSURL *expectedAssetURL =
        compiledGeneration.sourceAssetURLsByContentSHA256[
            firstRecord.contentSHA256];
    MTSafeImageInspection *expectedInspection =
        [MTSafeImageInspector.defaultInspector
            inspectOwnedPNGFileAtURL:expectedAssetURL
            cancellationToken:nil
            error:&error];
    MTRuntimePublishedImageLoader *runtimeImageLoader =
        MTRuntimePublishedImageLoader.staticIconLoader;
    MTRuntimeDecodedImage *runtimeImage = [runtimeImageLoader
        loadImageForGeneration:generation
        resource:firstResource
        targetPixelWidth:expectedInspection.pixelWidth
        targetPixelHeight:expectedInspection.pixelHeight
        error:&error];
    MTGenerationReaderAssert(runtimeImage != nil && error == nil &&
        runtimeImage.image != NULL &&
        runtimeImage.pixelWidth == expectedInspection.pixelWidth &&
        runtimeImage.pixelHeight == expectedInspection.pixelHeight &&
        runtimeImage.decodedByteCost > 0 &&
        runtimeImage.residentCost ==
            expectedAssetData.length + runtimeImage.decodedByteCost,
        @"Background Runtime loader must immediately decode exact verified PNG dimensions");
    error = nil;
    MTRuntimeDecodedImage *preservedImage = [runtimeImageLoader
        loadImagePreservingSourceDimensionsForGeneration:generation
        resource:firstResource
        error:&error];
    MTGenerationReaderAssert(preservedImage != nil && error == nil &&
        preservedImage.pixelWidth == expectedInspection.pixelWidth &&
        preservedImage.pixelHeight == expectedInspection.pixelHeight &&
        preservedImage.decodedByteCost > 0,
        @"Runtime loader must preserve an authored non-normalized canvas when explicitly requested");
    error = nil;
    MTRuntimeDecodedImage *downsampledImage = [runtimeImageLoader
        loadImageForGeneration:generation
        resource:firstResource
        targetPixelWidth:expectedInspection.pixelWidth / 2
        targetPixelHeight:expectedInspection.pixelHeight / 2
        error:&error];
    MTGenerationReaderAssert(
        expectedInspection.pixelWidth % 2 == 0 &&
        expectedInspection.pixelHeight % 2 == 0 &&
        downsampledImage != nil && error == nil &&
        downsampledImage.pixelWidth == expectedInspection.pixelWidth / 2 &&
        downsampledImage.pixelHeight == expectedInspection.pixelHeight / 2 &&
        downsampledImage.decodedByteCost > 0 &&
        downsampledImage.decodedByteCost < runtimeImage.decodedByteCost,
        @"Background Runtime loader must downsample a larger same-aspect PNG directly to the requested cache dimensions");
    uint32_t legacyTargetWidth =
        (uint32_t)(expectedInspection.pixelWidth / 2 * 3);
    uint32_t legacyTargetHeight =
        (uint32_t)(expectedInspection.pixelHeight / 2 * 3);
    error = nil;
    MTGenerationReaderAssert([runtimeImageLoader
        loadImageForGeneration:generation resource:firstResource
        targetPixelWidth:legacyTargetWidth
        targetPixelHeight:legacyTargetHeight error:&error] == nil &&
        error.code == MTRuntimePublishedImageLoaderErrorUnsupportedImage,
        @"The default Runtime decode policy must continue rejecting upscaling");
    error = nil;
    MTRuntimeDecodedImage *snowBoardUpscaledImage = [runtimeImageLoader
        loadImageForGeneration:generation
        resource:firstResource
        targetPixelWidth:legacyTargetWidth
        targetPixelHeight:legacyTargetHeight
        resizePolicy:
            MTRuntimePublishedImageResizePolicyBoundedScaleToFill
        error:&error];
    MTGenerationReaderAssert(
        snowBoardUpscaledImage != nil && error == nil &&
        snowBoardUpscaledImage.pixelWidth == legacyTargetWidth &&
        snowBoardUpscaledImage.pixelHeight == legacyTargetHeight,
        @"The SnowBoard-compatible policy must render a smaller authored icon into the caller-bounded target canvas");
    error = nil;
    MTRuntimeDecodedImage *snowBoardReshapedImage = [runtimeImageLoader
        loadImageForGeneration:generation
        resource:firstResource
        targetPixelWidth:legacyTargetWidth
        targetPixelHeight:legacyTargetHeight - 1
        resizePolicy:
            MTRuntimePublishedImageResizePolicyBoundedScaleToFill
        error:&error];
    MTGenerationReaderAssert(
        snowBoardReshapedImage != nil && error == nil &&
        snowBoardReshapedImage.pixelWidth == legacyTargetWidth &&
        snowBoardReshapedImage.pixelHeight == legacyTargetHeight - 1,
        @"The bounded compatibility renderer must normalize legacy non-matching source geometry to an exact system carrier");
    error = nil;
    MTRuntimeDecodedImage *legacyUpscaledImage = [runtimeImageLoader
        loadImageForGeneration:generation
        resource:firstResource
        targetPixelWidth:legacyTargetWidth
        targetPixelHeight:legacyTargetHeight
        resizePolicy:
            MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
        error:&error];
    MTGenerationReaderAssert(
        expectedInspection.pixelWidth % 2 == 0 &&
        expectedInspection.pixelHeight % 2 == 0 &&
        legacyUpscaledImage != nil && error == nil &&
        legacyUpscaledImage.pixelWidth == legacyTargetWidth &&
        legacyUpscaledImage.pixelHeight == legacyTargetHeight &&
        legacyUpscaledImage.decodedByteCost > runtimeImage.decodedByteCost,
        @"The explicit legacy Clock policy must deterministically resize one 2x canvas to 3x");
    error = nil;
    MTGenerationReaderAssert([runtimeImageLoader
        loadImageForGeneration:generation resource:firstResource
        targetPixelWidth:legacyTargetWidth + 1
        targetPixelHeight:legacyTargetHeight + 1
        resizePolicy:
            MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
        error:&error] == nil &&
        error.code == MTRuntimePublishedImageLoaderErrorUnsupportedImage,
        @"The legacy Clock policy must reject every ratio except exact 2x-to-3x");
    error = nil;
    MTGenerationReaderAssert([runtimeImageLoader
        loadImageForGeneration:generation resource:firstResource
        targetPixelWidth:expectedInspection.pixelWidth + 1
        targetPixelHeight:expectedInspection.pixelHeight error:&error] == nil &&
        error.code == MTRuntimePublishedImageLoaderErrorUnsupportedImage,
        @"Runtime loader must reject an asset outside the requested image contract");
    MTRuntimePublishedImageLoader *tightRuntimeImageLoader =
        [[MTRuntimePublishedImageLoader alloc]
            initWithMaximumEncodedByteCount:firstResource.assetByteCount - 1
            maximumDecodedByteCount:4ULL * 1024ULL * 1024ULL];
    error = nil;
    MTGenerationReaderAssert([tightRuntimeImageLoader
        loadImageForGeneration:generation resource:firstResource
        targetPixelWidth:expectedInspection.pixelWidth
        targetPixelHeight:expectedInspection.pixelHeight error:&error] == nil &&
        error.code == MTRuntimePublishedImageLoaderErrorLimitExceeded,
        @"Runtime loader must enforce its independent encoded-asset ceiling");
    error = nil;
    MTGenerationReaderAssert([generation
        verifiedAssetDataForResource:firstResource
        maximumByteCount:firstResource.assetByteCount - 1
        error:&error] == nil &&
        error.code == MTGenerationReaderErrorLimitExceeded,
        @"A Runtime asset read must enforce its narrower caller budget");

    NSString *retainedStore = MTGenerationReaderPublish(
        root, @"retained-descriptor", compiledGeneration);
    error = nil;
    MTGeneration *retainedGeneration = MTGenerationReaderRead(
        retainedStore, identifier, nil, &error);
    MTGenerationResource *retainedResource = [retainedGeneration
        resourceForCanonicalResourceKey:firstRecord.canonicalResourceKey
        error:&error];
    NSString *retainedFinal = MTGenerationReaderFinalPath(
        retainedStore, identifier);
    NSString *detachedFinal =
        [retainedFinal stringByAppendingString:@".detached"];
    MTGenerationReaderRequire(retainedGeneration != nil &&
        retainedResource != nil && error == nil &&
        rename(retainedFinal.fileSystemRepresentation,
               detachedFinal.fileSystemRepresentation) == 0,
        @"Retained Generation descriptor fixture must rename only its disposable path");
    error = nil;
    MTGenerationReaderAssert([[retainedGeneration
        verifiedAssetDataForResource:retainedResource
        maximumByteCount:32ULL * 1024ULL * 1024ULL
        error:&error] isEqualToData:expectedAssetData] && error == nil,
        @"Retained Generation access must not depend on a stale absolute asset path");

    NSString *postReadMutationStore = MTGenerationReaderPublish(
        root, @"post-read-mutation", compiledGeneration);
    error = nil;
    MTGeneration *postReadMutationGeneration = MTGenerationReaderRead(
        postReadMutationStore, identifier, nil, &error);
    MTGenerationResource *postReadMutationResource =
        [postReadMutationGeneration
            resourceForCanonicalResourceKey:firstRecord.canonicalResourceKey
            error:&error];
    NSString *postReadMutationAsset = [[MTGenerationReaderFinalPath(
        postReadMutationStore, identifier)
        stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:firstRecord.contentSHA256];
    int postReadMutationDescriptor = open(
        postReadMutationAsset.fileSystemRepresentation,
        O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    const uint8_t postReadMutationByte = 0xff;
    MTGenerationReaderRequire(postReadMutationGeneration != nil &&
        postReadMutationResource != nil && error == nil &&
        postReadMutationDescriptor >= 0 &&
        pwrite(postReadMutationDescriptor, &postReadMutationByte, 1, 0) == 1 &&
        close(postReadMutationDescriptor) == 0,
        @"Post-read mutation fixture must alter only its disposable asset");
    error = nil;
    MTGenerationReaderAssert([postReadMutationGeneration
        verifiedAssetDataForResource:postReadMutationResource
        maximumByteCount:32ULL * 1024ULL * 1024ULL
        error:&error] == nil &&
        error.code == MTGenerationReaderErrorVerification,
        @"Retained Generation access must reject post-validation asset mutation");

    MTResourceKey *missingKey = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
        surface:@"springboard.home"
        subject:@"com.hmmzzz.marktheme.reader-miss"
        variant:@"primary"
        scale:3
        trait:@"any"
        error:&error];
    error = nil;
    MTGenerationReaderAssert(missingKey != nil &&
        [generation resourceForCanonicalResourceKey:
            missingKey.canonicalString error:&error] == nil && error == nil,
        @"A canonical Reader lookup miss must remain a non-error miss");
    error = nil;
    MTGenerationReaderAssert([generation
        resourceForCanonicalResourceKey:@"not-canonical" error:&error] == nil &&
        [error.domain isEqualToString:MTGenerationIndexErrorDomain],
        @"Reader lookup must reject alternate resource-key encodings");

    int heldLock = open([[validStore stringByAppendingPathComponent:
        @"transaction.lock"] fileSystemRepresentation],
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    MTGenerationReaderAssert(heldLock >= 0 &&
        flock(heldLock, LOCK_EX | LOCK_NB) == 0,
        @"Reader lock-independence fixture must hold the writer lock");
    error = nil;
    MTGeneration *whileWriterLocked = MTGenerationReaderRead(
        validStore, identifier, nil, &error);
    MTGenerationReaderAssert(whileWriterLocked != nil && error == nil,
        @"Published Generation reads must not use writer-lock IPC");
    MTGenerationReaderRequire(flock(heldLock, LOCK_UN) == 0 &&
        close(heldLock) == 0,
        @"Reader lock-independence fixture must release its lock");

    NSString *unrelatedTransaction = [[validStore
        stringByAppendingPathComponent:@"generations"]
        stringByAppendingPathComponent:[@".transaction-"
            stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]];
    MTGenerationReaderRequire(
        MTGenerationReaderCreateDirectory(unrelatedTransaction),
        @"Reader sibling transaction fixture must be created");
    error = nil;
    MTGenerationReaderAssert(MTGenerationReaderRead(
        validStore, identifier, nil, &error) != nil && error == nil &&
        access(unrelatedTransaction.fileSystemRepresentation, F_OK) == 0,
        @"Reader must ignore and never mutate an unrelated writer transaction");

    NSString *missingStore = [root stringByAppendingPathComponent:@"missing"];
    MTGenerationReaderAssert(MTGenerationReaderFails(
        missingStore, identifier, MTGenerationReaderErrorNotFound) &&
        access(missingStore.fileSystemRepresentation, F_OK) != 0,
        @"Reader must report a missing store without creating it");
    NSString *missingIdentifier = [@"g1-" stringByAppendingString:
        [@"0" stringByPaddingToLength:64 withString:@"0"
                         startingAtIndex:0]];
    MTGenerationReaderAssert(MTGenerationReaderFails(
        validStore, missingIdentifier, MTGenerationReaderErrorNotFound),
        @"Reader must distinguish a canonical missing Generation");
    error = nil;
    MTGenerationReaderAssert([MTGenerationReaderForPath(
        missingStore, 20000, UINT64_MAX)
        readGenerationWithIdentifier:@"../invalid"
        cancellationToken:nil error:&error] == nil &&
        error.code == MTGenerationReaderErrorInvalidRequest &&
        access(missingStore.fileSystemRepresentation, F_OK) != 0,
        @"Reader must reject an invalid identifier before filesystem access");

    MTImportCancellationToken *preCancelled =
        [[MTImportCancellationToken alloc] init];
    [preCancelled cancel];
    error = nil;
    MTGenerationReaderAssert(MTGenerationReaderRead(
        validStore, identifier, preCancelled, &error) == nil &&
        error.code == MTGenerationReaderErrorCancelled,
        @"Reader must honor pre-cancellation without modifying the store");

    error = nil;
    MTGenerationReader *countLimited = MTGenerationReaderForPath(
        validStore, compiledGeneration.descriptor.assetCount - 1,
        UINT64_MAX);
    MTGenerationReaderAssert([countLimited
        readGenerationWithIdentifier:identifier cancellationToken:nil
        error:&error] == nil &&
        error.code == MTGenerationReaderErrorLimitExceeded,
        @"Reader must enforce its independent asset-count admission limit");
    uint64_t logicalBytes = compiledGeneration.descriptor.assetByteCount +
        compiledGeneration.descriptor.canonicalData.length +
        compiledGeneration.index.encodedData.length;
    error = nil;
    MTGenerationReader *byteLimited = MTGenerationReaderForPath(
        validStore, 20000, logicalBytes - 1);
    MTGenerationReaderAssert([byteLimited
        readGenerationWithIdentifier:identifier cancellationToken:nil
        error:&error] == nil &&
        error.code == MTGenerationReaderErrorLimitExceeded,
        @"Reader must enforce its independent logical-byte admission limit");

    MTGenerationReaderThresholdToken *midCancel =
        [[MTGenerationReaderThresholdToken alloc] initWithThreshold:21];
    error = nil;
    MTGenerationReaderAssert(MTGenerationReaderRead(
        validStore, identifier, midCancel, &error) == nil &&
        error.code == MTGenerationReaderErrorCancelled &&
        midCancel.readCount >= 21,
        @"Reader must observe deterministic cancellation during content validation");

    NSString *extraStore = MTGenerationReaderPublish(
        root, @"extra-final", compiledGeneration);
    NSString *extraFinal = MTGenerationReaderFinalPath(extraStore, identifier);
    MTGenerationReaderRequire(MTGenerationReaderWriteData(
        [@"extra" dataUsingEncoding:NSUTF8StringEncoding],
        [extraFinal stringByAppendingPathComponent:@"unexpected"]),
        @"Reader extra-final-node fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        extraStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject an extra final-tree node");

    NSString *missingMarkerStore = MTGenerationReaderPublish(
        root, @"missing-marker", compiledGeneration);
    NSString *missingMarker = [MTGenerationReaderFinalPath(
        missingMarkerStore, identifier)
        stringByAppendingPathComponent:@"generation.json"];
    MTGenerationReaderRequire(unlink(missingMarker.fileSystemRepresentation) == 0,
        @"Reader missing-marker fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        missingMarkerStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a final tree without its completion marker");

    NSString *malformedMarkerStore = MTGenerationReaderPublish(
        root, @"malformed-marker", compiledGeneration);
    NSString *malformedMarker = [MTGenerationReaderFinalPath(
        malformedMarkerStore, identifier)
        stringByAppendingPathComponent:@"generation.json"];
    MTGenerationReaderRequire(MTGenerationReaderWriteData(
        [@"{}" dataUsingEncoding:NSUTF8StringEncoding], malformedMarker),
        @"Reader malformed-marker fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        malformedMarkerStore, identifier,
        MTGenerationReaderErrorVerification),
        @"Reader must reject a malformed completion marker");

    error = nil;
    MTGenerationDescriptor *alternateDescriptor =
        [[MTGenerationDescriptor alloc]
            initWithThemeID:@"theme.generation-reader-alternate"
            libraryRevisionIdentifier:
                compiledGeneration.descriptor.libraryRevisionIdentifier
            manifestDigest:compiledGeneration.descriptor.manifestDigest
            indexSHA256:compiledGeneration.descriptor.indexSHA256
            indexByteCount:compiledGeneration.descriptor.indexByteCount
            indexFormatVersion:compiledGeneration.descriptor.indexFormatVersion
            resourceCount:compiledGeneration.descriptor.resourceCount
            assets:compiledGeneration.descriptor.assets
            moduleIDs:compiledGeneration.descriptor.moduleIDs
            error:&error];
    NSString *identityStore = MTGenerationReaderPublish(
        root, @"identity-mismatch", compiledGeneration);
    NSString *identityMarker = [MTGenerationReaderFinalPath(
        identityStore, identifier)
        stringByAppendingPathComponent:@"generation.json"];
    MTGenerationReaderRequire(alternateDescriptor != nil && error == nil &&
        MTGenerationReaderWriteData(
            alternateDescriptor.canonicalData, identityMarker),
        @"Reader identity-mismatch marker fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        identityStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must bind a canonical marker to its final directory name");

    NSString *indexStore = MTGenerationReaderPublish(
        root, @"index-corruption", compiledGeneration);
    NSString *indexPath = [MTGenerationReaderFinalPath(indexStore, identifier)
        stringByAppendingPathComponent:@"index.mtg"];
    int indexDescriptor = open(indexPath.fileSystemRepresentation,
                               O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    uint8_t indexByte = 0xff;
    MTGenerationReaderRequire(indexDescriptor >= 0 &&
        pwrite(indexDescriptor, &indexByte, 1, 0) == 1 &&
        close(indexDescriptor) == 0,
        @"Reader index-corruption fixture must preserve file size");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        indexStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject same-size fixed-index corruption");

    NSString *missingAssetStore = MTGenerationReaderPublish(
        root, @"missing-asset", compiledGeneration);
    NSString *missingAsset = MTGenerationReaderFirstAssetPath(
        missingAssetStore, compiledGeneration);
    MTGenerationReaderRequire(unlink(missingAsset.fileSystemRepresentation) == 0,
        @"Reader missing-asset fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        missingAssetStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a missing descriptor asset");

    NSString *extraAssetStore = MTGenerationReaderPublish(
        root, @"extra-asset", compiledGeneration);
    NSString *extraAssetPath = [[MTGenerationReaderFinalPath(
        extraAssetStore, identifier) stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:
            [@"0" stringByPaddingToLength:64 withString:@"0"
                             startingAtIndex:0]];
    MTGenerationReaderRequire(MTGenerationReaderWriteData(
        [@"x" dataUsingEncoding:NSUTF8StringEncoding], extraAssetPath),
        @"Reader extra-asset fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        extraAssetStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject an extra asset even when its name is canonical");

    NSString *symlinkAssetsStore = MTGenerationReaderPublish(
        root, @"symlink-assets", compiledGeneration);
    NSString *symlinkAssetsPath = [MTGenerationReaderFinalPath(
        symlinkAssetsStore, identifier) stringByAppendingPathComponent:@"assets"];
    NSString *realAssetsPath = [root stringByAppendingPathComponent:
        @"reader-real-assets"];
    MTGenerationReaderRequire(rename(
        symlinkAssetsPath.fileSystemRepresentation,
        realAssetsPath.fileSystemRepresentation) == 0 &&
        symlink(realAssetsPath.fileSystemRepresentation,
                symlinkAssetsPath.fileSystemRepresentation) == 0,
        @"Reader symlink-assets fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        symlinkAssetsStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a symlink in place of the assets directory");

    NSString *symlinkAssetStore = MTGenerationReaderPublish(
        root, @"symlink-asset", compiledGeneration);
    NSString *symlinkAsset = MTGenerationReaderFirstAssetPath(
        symlinkAssetStore, compiledGeneration);
    NSString *symlinkTarget = [root stringByAppendingPathComponent:
        @"reader-symlink-target"];
    MTGenerationReaderRequire(MTGenerationReaderWriteData(
        [NSData dataWithContentsOfFile:symlinkAsset], symlinkTarget) &&
        unlink(symlinkAsset.fileSystemRepresentation) == 0 &&
        symlink(symlinkTarget.fileSystemRepresentation,
                symlinkAsset.fileSystemRepresentation) == 0,
        @"Reader symlink-asset fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        symlinkAssetStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must never follow a Generation asset symlink");

    NSString *hardlinkStore = MTGenerationReaderPublish(
        root, @"hardlink-asset", compiledGeneration);
    NSString *hardlinkAsset = MTGenerationReaderFirstAssetPath(
        hardlinkStore, compiledGeneration);
    NSString *hardlinkAlias = [root stringByAppendingPathComponent:
        @"reader-hardlink-alias"];
    MTGenerationReaderRequire(link(hardlinkAsset.fileSystemRepresentation,
                                   hardlinkAlias.fileSystemRepresentation) == 0,
        @"Reader hardlink-asset fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        hardlinkStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a Generation asset with multiple links");

    NSString *hardlinkMarkerStore = MTGenerationReaderPublish(
        root, @"hardlink-marker", compiledGeneration);
    NSString *hardlinkMarker = [MTGenerationReaderFinalPath(
        hardlinkMarkerStore, identifier)
        stringByAppendingPathComponent:@"generation.json"];
    NSString *hardlinkMarkerAlias = [root stringByAppendingPathComponent:
        @"reader-marker-hardlink-alias"];
    MTGenerationReaderRequire(link(
        hardlinkMarker.fileSystemRepresentation,
        hardlinkMarkerAlias.fileSystemRepresentation) == 0,
        @"Reader hardlink-marker fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        hardlinkMarkerStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a completion marker with multiple links");

    NSString *modeStore = MTGenerationReaderPublish(
        root, @"unsafe-mode", compiledGeneration);
    NSString *modeAsset = MTGenerationReaderFirstAssetPath(
        modeStore, compiledGeneration);
    MTGenerationReaderRequire(chmod(modeAsset.fileSystemRepresentation,
                                    0664) == 0,
        @"Reader unsafe-mode fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        modeStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a Generation asset with a widened mode");

    NSString *contentStore = MTGenerationReaderPublish(
        root, @"content-corruption", compiledGeneration);
    NSString *contentAsset = MTGenerationReaderFirstAssetPath(
        contentStore, compiledGeneration);
    int contentDescriptor = open(contentAsset.fileSystemRepresentation,
                                 O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    uint8_t contentByte = 0xa7;
    MTGenerationReaderRequire(contentDescriptor >= 0 &&
        pwrite(contentDescriptor, &contentByte, 1, 16) == 1 &&
        close(contentDescriptor) == 0,
        @"Reader content-corruption fixture must preserve asset size");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        contentStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must full-hash and reject same-size asset corruption");

    NSString *mutationStore = MTGenerationReaderPublish(
        root, @"mid-read-mutation", compiledGeneration);
    NSString *mutationAsset = MTGenerationReaderFirstAssetPath(
        mutationStore, compiledGeneration);
    MTGenerationReaderMutationToken *mutationToken =
        [[MTGenerationReaderMutationToken alloc]
            initWithPath:mutationAsset trigger:21];
    error = nil;
    MTGenerationReaderAssert(MTGenerationReaderRead(
        mutationStore, identifier, mutationToken, &error) == nil &&
        mutationToken.mutationSucceeded &&
        error.code == MTGenerationReaderErrorVerification,
        @"Reader must reject asset mutation during its full-hash pass");

    NSString *lateMutationStore = MTGenerationReaderPublish(
        root, @"late-mutation", compiledGeneration);
    NSString *lateMutationAsset = MTGenerationReaderFirstAssetPath(
        lateMutationStore, compiledGeneration);
    MTGenerationReaderMutationToken *lateMutationToken =
        [[MTGenerationReaderMutationToken alloc]
            initWithPath:lateMutationAsset trigger:23];
    error = nil;
    MTGenerationReaderAssert(MTGenerationReaderRead(
        lateMutationStore, identifier, lateMutationToken, &error) == nil &&
        lateMutationToken.mutationSucceeded &&
        error.code == MTGenerationReaderErrorVerification,
        @"Reader must recheck early assets after the complete hash pass");

    NSString *finalModeStore = MTGenerationReaderPublish(
        root, @"final-mode", compiledGeneration);
    NSString *finalModePath = MTGenerationReaderFinalPath(
        finalModeStore, identifier);
    MTGenerationReaderRequire(chmod(finalModePath.fileSystemRepresentation,
                                    0775) == 0,
        @"Reader final-mode fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        finalModeStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject an unsafe final-directory mode");

    NSString *rootModeStore = MTGenerationReaderPublish(
        root, @"root-mode", compiledGeneration);
    MTGenerationReaderRequire(chmod(rootModeStore.fileSystemRepresentation,
                                    0775) == 0,
        @"Reader root-mode fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        rootModeStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject an unsafe store-root mode");

    NSString *symlinkRootTarget = MTGenerationReaderPublish(
        root, @"symlink-root-target", compiledGeneration);
    NSString *symlinkRoot = [root stringByAppendingPathComponent:
        @"symlink-root"];
    MTGenerationReaderRequire(symlink(
        symlinkRootTarget.fileSystemRepresentation,
        symlinkRoot.fileSystemRepresentation) == 0,
        @"Reader symlink-root fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        symlinkRoot, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a symlink in place of the compiler root");

    NSString *symlinkFinalStore = MTGenerationReaderPublish(
        root, @"symlink-final", compiledGeneration);
    NSString *symlinkFinal = MTGenerationReaderFinalPath(
        symlinkFinalStore, identifier);
    NSString *realFinal = [root stringByAppendingPathComponent:
        @"reader-real-final"];
    MTGenerationReaderRequire(rename(symlinkFinal.fileSystemRepresentation,
                                     realFinal.fileSystemRepresentation) == 0 &&
        symlink(realFinal.fileSystemRepresentation,
                symlinkFinal.fileSystemRepresentation) == 0,
        @"Reader symlink-final fixture must be created");
    MTGenerationReaderAssert(MTGenerationReaderFails(
        symlinkFinalStore, identifier, MTGenerationReaderErrorVerification),
        @"Reader must reject a symlink in place of a published final");

    MTGenerationReaderRequire([NSFileManager.defaultManager
        removeItemAtPath:root error:&error],
        @"Generation reader test root must be removable by its owner");
    return MTGenerationReaderAssertionCount;
}
