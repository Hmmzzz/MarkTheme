#import "MTRuntimeStressFixture.h"

#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationWriter.h"
#import "MTDigest.h"
#import "MTImportLimits.h"
#import "MTResourceKey.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTSafeImageDecoder.h"
#import "MTSyntheticCorpus.h"
#import "MTStaticIconCompiler.h"
#import "MTThemeImport.h"
#import "MTThemeLibraryStore.h"

NSString *const MTRuntimeStressFixtureErrorDomain =
    @"com.hmmzzz.marktheme.tests.runtime-stress-fixture";

static const NSUInteger MTRuntimeStressFixtureIconCount = 500;
static const uint32_t MTRuntimeStressFixturePixelDimension = 180;
static NSString *const MTRuntimeSnapshotFixtureSubject =
    @"com.hmmzzz.marktheme";

typedef NS_ENUM(NSInteger, MTRuntimeStressFixtureErrorCode) {
    MTRuntimeStressFixtureErrorInvalidRequest = 1,
    MTRuntimeStressFixtureErrorFilesystem = 2,
    MTRuntimeStressFixtureErrorPipeline = 3,
    MTRuntimeStressFixtureErrorInvariant = 4,
};

@interface MTCompiledGeneration (MTRuntimeFallbackFixture)
- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
    (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest;
@end

static BOOL MTRuntimeStressFixtureSetError(
    NSError **error,
    MTRuntimeStressFixtureErrorCode code,
    NSString *description,
    NSError *_Nullable underlyingError) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey : description,
        } mutableCopy];
        if (underlyingError != nil) {
            userInfo[NSUnderlyingErrorKey] = underlyingError;
        }
        *error = [NSError errorWithDomain:MTRuntimeStressFixtureErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSURL *_Nullable MTRuntimeStressFixtureTemporaryRoot(
    NSError **error) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"marktheme-runtime-stress.XXXXXX"];
    NSMutableData *buffer = [[template dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    if (mkdtemp(path) == NULL) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"Unable to create the Runtime stress fixture workspace.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:errno userInfo:nil]);
        return nil;
    }
    return [NSURL fileURLWithPath:
        [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:path length:strlen(path)]
                     isDirectory:YES];
}

static BOOL MTRuntimeStressFixtureDestinationIsAvailable(
    NSURL *destinationRootURL,
    NSError **error) {
    if (![destinationRootURL isKindOfClass:NSURL.class] ||
        !destinationRootURL.isFileURL ||
        !destinationRootURL.path.isAbsolutePath ||
        destinationRootURL.lastPathComponent.length == 0) {
        return MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvalidRequest,
            @"The Runtime stress fixture destination must be an absolute file URL.",
            nil);
    }
    struct stat status = {0};
    if (lstat(destinationRootURL.fileSystemRepresentation, &status) == 0) {
        return MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvalidRequest,
            @"The Runtime stress fixture destination already exists.", nil);
    }
    if (errno != ENOENT) {
        return MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"Unable to inspect the Runtime stress fixture destination.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:errno userInfo:nil]);
    }
    NSError *operationError = nil;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:destinationRootURL.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions : @0700}
            error:&operationError]) {
        return MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"Unable to create the Runtime stress fixture parent directory.",
            operationError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable
MTRuntimeFixtureBuild(NSURL *workspaceURL,
                      NSURL *destinationRootURL,
                      NSUInteger iconCount,
                      NSString *_Nullable snapshotSubject,
                      uint32_t snapshotSeed,
                      BOOL deduplicateAssets,
                      NSError **error) {
    NSError *operationError = nil;
    MTSyntheticCorpus *corpus = MTSyntheticCorpusCreate(
        workspaceURL, iconCount,
        MTRuntimeStressFixturePixelDimension, &operationError);
    if (corpus == nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorPipeline,
            @"Unable to generate the deterministic Runtime stress corpus.",
            operationError);
        return nil;
    }

    if (snapshotSubject != nil) {
        NSURL *iconsURL = [corpus.directoryURL
            URLByAppendingPathComponent:@"IconBundles" isDirectory:YES];
        NSURL *sourceURL = [iconsURL URLByAppendingPathComponent:
            @"com.example.benchmark0000-large.png"];
        NSURL *targetURL = [iconsURL URLByAppendingPathComponent:
            [snapshotSubject stringByAppendingString:@"@3x.png"]];
        if (![NSFileManager.defaultManager moveItemAtURL:sourceURL
                                                   toURL:targetURL
                                                   error:&operationError]) {
            MTRuntimeStressFixtureSetError(error,
                MTRuntimeStressFixtureErrorFilesystem,
                @"Unable to specialize the Runtime snapshot fixture subject.",
                operationError);
            return nil;
        }
        NSData *snapshotPNG = MTSyntheticPNGData(
            MTRuntimeStressFixturePixelDimension, snapshotSeed,
            &operationError);
        if (snapshotPNG == nil ||
            ![snapshotPNG writeToURL:targetURL
                             options:NSDataWritingAtomic
                               error:&operationError]) {
            MTRuntimeStressFixtureSetError(error,
                MTRuntimeStressFixtureErrorFilesystem,
                @"Unable to specialize the Runtime snapshot fixture pixels.",
                operationError);
            return nil;
        }
    }

    if (deduplicateAssets) {
        NSURL *iconsURL = [corpus.directoryURL
            URLByAppendingPathComponent:@"IconBundles" isDirectory:YES];
        NSArray<NSURL *> *iconURLs = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:iconsURL
            includingPropertiesForKeys:nil
            options:0
            error:&operationError];
        NSData *sharedPNG = iconURLs == nil ? nil : MTSyntheticPNGData(
            MTRuntimeStressFixturePixelDimension, snapshotSeed,
            &operationError);
        NSUInteger pngCount = 0;
        for (NSURL *iconURL in iconURLs ?: @[]) {
            if (![iconURL.pathExtension.lowercaseString
                    isEqualToString:@"png"]) {
                continue;
            }
            pngCount++;
            if (![sharedPNG writeToURL:iconURL
                               options:NSDataWritingAtomic
                                 error:&operationError]) {
                break;
            }
        }
        if (sharedPNG == nil || operationError != nil ||
            pngCount != iconCount) {
            MTRuntimeStressFixtureSetError(error,
                MTRuntimeStressFixtureErrorFilesystem,
                @"Unable to deduplicate the Runtime performance fixture assets.",
                operationError);
            return nil;
        }
    }

    MTImportLimits *limits = MTImportLimits.defaultLimits;
    MTThemeImportConfiguration *configuration =
        [[MTThemeImportConfiguration alloc]
            initWithLimits:limits
            importSessionsRootURL:[workspaceURL
                URLByAppendingPathComponent:@"import" isDirectory:YES]
            assetSessionsRootURL:[workspaceURL
                URLByAppendingPathComponent:@"assets" isDirectory:YES]
            libraryRootURL:[workspaceURL
                URLByAppendingPathComponent:@"library" isDirectory:YES]
            libraryFreeSpaceReserveBytes:0
            imageDecoder:MTSafeImageDecoder.defaultDecoder
            maximumPreviewCount:1
            previewMaximumDimension:64];
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
        initWithConfiguration:configuration];
    MTPreparedThemeImport *prepared = [pipeline
        prepareDirectoryThemeAtURL:corpus.directoryURL
        sourceName:@"SyntheticBenchmark.theme"
        cancellationToken:nil
        progressHandler:nil
        error:&operationError];
    if (prepared == nil ||
        prepared.recognizedFileCount != iconCount ||
        prepared.uniqueAssetCount != (deduplicateAssets ? 1 : iconCount)) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"The Runtime stress import did not preserve its resource and asset counts.",
            operationError);
        return nil;
    }

    MTThemeLibraryRevision *revision = [pipeline
        commitPreparedImport:prepared
        cancellationToken:nil
        progressHandler:nil
        error:&operationError];
    MTCompiledGeneration *compiled = revision == nil ? nil :
        [MTStaticIconCompiler.defaultCompiler
            compileLibraryRevision:revision
            cancellationToken:nil
            error:&operationError];
    if (compiled == nil ||
        compiled.index.recordCount != iconCount ||
        compiled.descriptor.assetCount !=
            (deduplicateAssets ? 1 : iconCount)) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"The Runtime stress Library revision did not compile into the expected Generation.",
            operationError);
        return nil;
    }

    NSURL *canonicalDestinationRootURL = [NSURL fileURLWithPath:
        destinationRootURL.path.stringByStandardizingPath isDirectory:YES];
    MTGenerationWriterConfiguration *writerConfiguration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:canonicalDestinationRootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:25000];
    MTGenerationWriteResult *writeResult = [[[MTGenerationWriter alloc]
        initWithConfiguration:writerConfiguration]
        writeCompiledGeneration:compiled
        cancellationToken:nil
        error:&operationError];
    MTGenerationReaderConfiguration *readerConfiguration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:canonicalDestinationRootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    MTGeneration *generation = writeResult == nil ? nil :
        [[[MTGenerationReader alloc] initWithConfiguration:readerConfiguration]
            readGenerationWithIdentifier:writeResult.generationIdentifier
            cancellationToken:nil
            error:&operationError];
    if (generation == nil || writeResult.reusedExistingGeneration ||
        ![generation.generationIdentifier
            isEqualToString:compiled.descriptor.generationIdentifier] ||
        generation.index.recordCount != iconCount ||
        generation.descriptor.assetCount !=
            (deduplicateAssets ? 1 : iconCount)) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"The Runtime stress Generation failed fresh Reader validation.",
            operationError);
        return nil;
    }

    NSString *snapshotAssetSHA256 = nil;
    if (snapshotSubject != nil) {
        MTResourceKey *expectedKey = [[MTResourceKey alloc]
            initWithModuleID:@"icons.static"
                     surface:@"springboard.home"
                     subject:snapshotSubject
                     variant:@"primary"
                       scale:3
                       trait:@"any"
                       error:&operationError];
        MTGenerationResource *resource = expectedKey == nil ? nil :
            [generation resourceForCanonicalResourceKey:
                expectedKey.canonicalString error:&operationError];
        if (resource == nil) {
            MTRuntimeStressFixtureSetError(error,
                MTRuntimeStressFixtureErrorInvariant,
                @"The Runtime snapshot fixture lacks its exact target key.",
                operationError);
            return nil;
        }
        snapshotAssetSHA256 = resource.contentSHA256;
    }

    return @{
        @"assetByteCount" : @(generation.descriptor.assetByteCount),
        @"assetCount" : @(generation.descriptor.assetCount),
        @"generationIdentifier" : generation.generationIdentifier,
        @"pixelDimension" : @(MTRuntimeStressFixturePixelDimension),
        @"resourceCount" : @(generation.index.recordCount),
        @"snapshotAssetSHA256" : snapshotAssetSHA256 ?: NSNull.null,
        @"subject" : snapshotSubject ?: NSNull.null,
    };
}

static NSDictionary<NSString *, id> *_Nullable
MTRuntimeFixtureWrite(NSURL *destinationRootURL,
                      NSUInteger iconCount,
                      NSString *_Nullable snapshotSubject,
                      BOOL deduplicateAssets,
                      NSError **error) {
    if (!MTRuntimeStressFixtureDestinationIsAvailable(
            destinationRootURL, error)) {
        return nil;
    }
    NSURL *workspaceURL = MTRuntimeStressFixtureTemporaryRoot(error);
    if (workspaceURL == nil) return nil;

    NSDictionary<NSString *, id> *result = MTRuntimeFixtureBuild(
        workspaceURL, destinationRootURL, iconCount, snapshotSubject,
        snapshotSubject == nil ? 0 : 1, deduplicateAssets, error);
    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:workspaceURL
                                                  error:&cleanupError] &&
        result != nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"The Runtime fixture was written but its workspace could not be removed.",
            cleanupError);
        result = nil;
    }
    if (result == nil) {
        [NSFileManager.defaultManager removeItemAtURL:destinationRootURL
                                                error:NULL];
    }
    return result;
}

NSDictionary<NSString *, id> *MTRuntimeStressFixtureWrite(
    NSURL *destinationRootURL,
    NSError **error) {
    return MTRuntimeFixtureWrite(destinationRootURL,
        MTRuntimeStressFixtureIconCount, nil, NO, error);
}

NSDictionary<NSString *, id> *MTRuntimeSnapshotFixtureWrite(
    NSURL *destinationRootURL,
    NSError **error) {
    return MTRuntimeFixtureWrite(destinationRootURL, 1,
        MTRuntimeSnapshotFixtureSubject, NO, error);
}

NSDictionary<NSString *, id> *MTRuntimePerformanceFixtureWrite(
    NSURL *destinationRootURL,
    NSError **error) {
    return MTRuntimeFixtureWrite(destinationRootURL,
        MTRuntimeStressFixtureIconCount,
        MTRuntimeSnapshotFixtureSubject, YES, error);
}

NSDictionary<NSString *, id> *MTRuntimeSnapshotSwapFixtureWrite(
    NSURL *destinationRootURL,
    NSError **error) {
    if (!MTRuntimeStressFixtureDestinationIsAvailable(
            destinationRootURL, error)) {
        return nil;
    }
    NSURL *workspaceURL = MTRuntimeStressFixtureTemporaryRoot(error);
    if (workspaceURL == nil) return nil;

    NSError *operationError = nil;
    NSURL *workspaceA = [workspaceURL
        URLByAppendingPathComponent:@"a" isDirectory:YES];
    NSURL *workspaceB = [workspaceURL
        URLByAppendingPathComponent:@"b" isDirectory:YES];
    BOOL createdWorkspaces = [NSFileManager.defaultManager
        createDirectoryAtURL:workspaceA
        withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700}
        error:&operationError] &&
        [NSFileManager.defaultManager
            createDirectoryAtURL:workspaceB
            withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions : @0700}
            error:&operationError];
    NSDictionary<NSString *, id> *generationA = createdWorkspaces ?
        MTRuntimeFixtureBuild(workspaceA, destinationRootURL, 1,
            MTRuntimeSnapshotFixtureSubject, 101, NO,
            &operationError) : nil;
    NSDictionary<NSString *, id> *generationB = generationA == nil ? nil :
        MTRuntimeFixtureBuild(workspaceB, destinationRootURL, 1,
            MTRuntimeSnapshotFixtureSubject, 202, NO,
            &operationError);
    NSString *identifierA = generationA[@"generationIdentifier"];
    NSString *identifierB = generationB[@"generationIdentifier"];
    NSString *assetA = generationA[@"snapshotAssetSHA256"];
    NSString *assetB = generationB[@"snapshotAssetSHA256"];
    NSDictionary<NSString *, id> *result = nil;
    if (generationB != nil && identifierA.length > 0 &&
        identifierB.length > 0 && assetA.length > 0 && assetB.length > 0 &&
        ![identifierA isEqualToString:identifierB] &&
        ![assetA isEqualToString:assetB]) {
        result = @{
            @"generationA" : identifierA,
            @"generationB" : identifierB,
            @"assetA" : assetA,
            @"assetB" : assetB,
            @"subject" : MTRuntimeSnapshotFixtureSubject,
        };
    } else {
        NSString *detail = [NSString stringWithFormat:
            @"The Runtime swap fixture did not produce two distinct Generations "
             "(A=%@, B=%@, assetA=%@, assetB=%@).",
            identifierA ?: @"missing", identifierB ?: @"missing",
            assetA ?: @"missing", assetB ?: @"missing"];
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            detail,
            operationError);
    }

    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:workspaceURL
                                                  error:&cleanupError] &&
        result != nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"The Runtime swap fixture was written but its workspace could not be removed.",
            cleanupError);
        result = nil;
    }
    if (result == nil) {
        [NSFileManager.defaultManager removeItemAtURL:destinationRootURL
                                                error:NULL];
    }
    return result;
}

static MTGenerationWriter *MTRuntimeFallbackWriter(
    NSURL *destinationRootURL) {
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:destinationRootURL
            maximumAssetCount:8
            maximumGenerationByteCount:8ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:32];
    return [[MTGenerationWriter alloc] initWithConfiguration:configuration];
}

static MTGenerationReader *MTRuntimeFallbackReader(
    NSURL *destinationRootURL) {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:destinationRootURL
            maximumAssetCount:8
            maximumGenerationByteCount:8ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    return [[MTGenerationReader alloc] initWithConfiguration:configuration];
}

static MTGenerationDescriptor *_Nullable MTRuntimeFallbackDescriptor(
    NSString *themeID,
    NSString *manifestSeed,
    MTGenerationIndex *index,
    NSArray<MTGenerationAssetDescriptor *> *assets,
    NSArray<NSString *> *moduleIDs,
    NSError **error) {
    NSData *manifestSeedData = [manifestSeed
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString *manifestDigest = MTSHA256HexDigestForData(manifestSeedData);
    if (manifestDigest == nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"Unable to derive the fallback fixture manifest identity.", nil);
        return nil;
    }
    return [[MTGenerationDescriptor alloc]
        initWithThemeID:themeID
        libraryRevisionIdentifier:
            [@"r1-" stringByAppendingString:manifestDigest]
        manifestDigest:manifestDigest
        indexSHA256:MTSHA256HexDigestForData(index.encodedData)
        indexByteCount:index.encodedData.length
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:index.recordCount
        assets:assets
        moduleIDs:moduleIDs
        error:error];
}

static NSDictionary<NSString *, id> *_Nullable
MTRuntimeFallbackFixtureBuild(NSURL *workspaceURL,
                              NSURL *destinationRootURL,
                              NSError **error) {
    NSError *operationError = nil;
    NSData *rejectedBytes = [
        @"MarkTheme verified bytes; intentionally not an image.\n"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString *assetDigest = MTSHA256HexDigestForData(rejectedBytes);
    NSURL *sourceDirectoryURL = [workspaceURL
        URLByAppendingPathComponent:@"fallback-assets" isDirectory:YES];
    NSURL *sourceAssetURL = assetDigest == nil ? nil :
        [sourceDirectoryURL URLByAppendingPathComponent:assetDigest];
    BOOL sourceReady = sourceAssetURL != nil &&
        [NSFileManager.defaultManager
            createDirectoryAtURL:sourceDirectoryURL
            withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions : @0700}
            error:&operationError] &&
        [rejectedBytes writeToURL:sourceAssetURL
                         options:NSDataWritingWithoutOverwriting
                           error:&operationError] &&
        chmod(sourceAssetURL.fileSystemRepresentation, 0600) == 0;
    if (!sourceReady) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"Unable to write the byte-valid fallback fixture asset.",
            operationError);
        return nil;
    }

    MTResourceKey *resourceKey = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
        surface:@"springboard.home"
        subject:MTRuntimeSnapshotFixtureSubject
        variant:@"primary"
        scale:3
        trait:@"any"
        error:&operationError];
    MTGenerationIndexRecord *record = resourceKey == nil ? nil :
        [[MTGenerationIndexRecord alloc]
            initWithCanonicalResourceKey:resourceKey.canonicalString
            contentSHA256:assetDigest
            assetByteCount:rejectedBytes.length
            error:&operationError];
    NSData *corruptIndexData = record == nil ? nil :
        [MTGenerationIndex encodedDataWithRecords:@[record]
                                            error:&operationError];
    MTGenerationIndex *corruptIndex = corruptIndexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:corruptIndexData
                                                 error:&operationError];
    MTGenerationAssetDescriptor *asset = assetDigest == nil ? nil :
        [[MTGenerationAssetDescriptor alloc]
            initWithContentSHA256:assetDigest
            byteCount:rejectedBytes.length
            error:&operationError];
    MTGenerationDescriptor *corruptDescriptor =
        corruptIndex == nil || asset == nil ? nil :
        MTRuntimeFallbackDescriptor(
            @"theme.runtime-fallback-corrupt",
            @"runtime-fallback-corrupt-v1", corruptIndex, @[asset],
            @[@"icons.static"], &operationError);
    MTCompiledGeneration *corruptCompiled = corruptDescriptor == nil ? nil :
        [[MTCompiledGeneration alloc]
            initWithDescriptor:corruptDescriptor
            index:corruptIndex
            sourceAssetURLsByDigest:@{assetDigest : sourceAssetURL}];
    MTGenerationWriter *writer = MTRuntimeFallbackWriter(destinationRootURL);
    MTGenerationWriteResult *corruptWrite = corruptCompiled == nil ? nil :
        [writer writeCompiledGeneration:corruptCompiled
                      cancellationToken:nil
                               error:&operationError];
    MTGenerationReader *reader = MTRuntimeFallbackReader(destinationRootURL);
    MTGeneration *corruptGeneration = corruptWrite == nil ? nil :
        [reader readGenerationWithIdentifier:
            corruptWrite.generationIdentifier
                            cancellationToken:nil
                                     error:&operationError];
    MTGenerationResource *corruptResource = corruptGeneration == nil ? nil :
        [corruptGeneration resourceForCanonicalResourceKey:
            resourceKey.canonicalString error:&operationError];
    NSError *decodeError = nil;
    MTRuntimeDecodedImage *decoded = corruptResource == nil ? nil :
        [MTRuntimePublishedImageLoader.staticIconLoader
            loadImageForGeneration:corruptGeneration
            resource:corruptResource
            targetPixelWidth:MTRuntimeStressFixturePixelDimension
            targetPixelHeight:MTRuntimeStressFixturePixelDimension
            error:&decodeError];
    if (corruptGeneration == nil || corruptResource == nil ||
        corruptWrite.reusedExistingGeneration || decoded != nil ||
        decodeError == nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"The fallback fixture did not preserve verified bytes through an ImageIO rejection.",
            operationError ?: decodeError);
        return nil;
    }

    NSData *offIndexData = [MTGenerationIndex
        encodedDataWithRecords:@[] error:&operationError];
    MTGenerationIndex *offIndex = offIndexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:offIndexData
                                                 error:&operationError];
    MTGenerationDescriptor *offDescriptor = offIndex == nil ? nil :
        MTRuntimeFallbackDescriptor(
            @"theme.runtime-fallback-module-off",
            @"runtime-fallback-module-off-v1", offIndex, @[], @[],
            &operationError);
    MTCompiledGeneration *offCompiled = offDescriptor == nil ? nil :
        [[MTCompiledGeneration alloc]
            initWithDescriptor:offDescriptor
            index:offIndex
            sourceAssetURLsByDigest:@{}];
    MTGenerationWriteResult *offWrite = offCompiled == nil ? nil :
        [writer writeCompiledGeneration:offCompiled
                      cancellationToken:nil
                               error:&operationError];
    MTGeneration *offGeneration = offWrite == nil ? nil :
        [reader readGenerationWithIdentifier:offWrite.generationIdentifier
                            cancellationToken:nil
                                     error:&operationError];
    if (offGeneration == nil || offWrite.reusedExistingGeneration ||
        offGeneration.index.recordCount != 0 ||
        offGeneration.descriptor.moduleIDs.count != 0 ||
        [offGeneration resourceForCanonicalResourceKey:
            resourceKey.canonicalString error:&operationError] != nil ||
        operationError != nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorInvariant,
            @"The module-off fallback Generation is not canonically empty.",
            operationError);
        return nil;
    }

    return @{
        @"corruptAsset" : assetDigest,
        @"corruptAssetByteCount" : @(rejectedBytes.length),
        @"corruptGeneration" : corruptGeneration.generationIdentifier,
        @"moduleOffGeneration" : offGeneration.generationIdentifier,
        @"subject" : MTRuntimeSnapshotFixtureSubject,
    };
}

NSDictionary<NSString *, id> *MTRuntimeFallbackFixtureWrite(
    NSURL *destinationRootURL,
    NSError **error) {
    if (!MTRuntimeStressFixtureDestinationIsAvailable(
            destinationRootURL, error)) {
        return nil;
    }
    NSURL *workspaceURL = MTRuntimeStressFixtureTemporaryRoot(error);
    if (workspaceURL == nil) return nil;

    NSDictionary<NSString *, id> *result = MTRuntimeFallbackFixtureBuild(
        workspaceURL, destinationRootURL, error);
    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:workspaceURL
                                                  error:&cleanupError] &&
        result != nil) {
        MTRuntimeStressFixtureSetError(error,
            MTRuntimeStressFixtureErrorFilesystem,
            @"The fallback fixture was written but its workspace could not be removed.",
            cleanupError);
        result = nil;
    }
    if (result == nil) {
        [NSFileManager.defaultManager removeItemAtURL:destinationRootURL
                                                error:NULL];
    }
    return result;
}
