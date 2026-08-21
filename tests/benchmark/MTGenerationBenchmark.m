#import "MTGenerationBenchmark.h"

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationWriter.h"
#import "MTResourceKey.h"
#import "MTStaticIconCompiler.h"
#import "MTThemeLibraryStore.h"

NSString *const MTGenerationBenchmarkErrorDomain =
    @"com.hmmzzz.marktheme64e.tests.generation-benchmark";
NSUInteger const MTGenerationBenchmarkLookupCount = 100000;

typedef NS_ENUM(NSInteger, MTGenerationBenchmarkErrorCode) {
    MTGenerationBenchmarkErrorInvalidRequest = 1,
    MTGenerationBenchmarkErrorFixture = 2,
    MTGenerationBenchmarkErrorInvariant = 3,
};

static BOOL MTGenerationBenchmarkSetError(
    NSError **error,
    MTGenerationBenchmarkErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTGenerationBenchmarkErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

@interface MTCompiledGeneration (MTGenerationBenchmarkFixture)

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
    (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest;

@end

static MTGenerationWriter *MTGenerationBenchmarkWriter(NSURL *rootURL) {
    MTGenerationWriterConfiguration *configuration =
        [[MTGenerationWriterConfiguration alloc]
            initWithRootURL:rootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            minimumFreeSpaceReserveBytes:0
            maximumRecoveryNodeCount:25000];
    return [[MTGenerationWriter alloc] initWithConfiguration:configuration];
}

static MTGenerationReader *MTGenerationBenchmarkReader(NSURL *rootURL) {
    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:rootURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    return [[MTGenerationReader alloc] initWithConfiguration:configuration];
}

static MTCompiledGeneration *_Nullable
MTGenerationBenchmarkCreateZeroRecordFixture(NSError **error) {
    NSError *operationError = nil;
    NSData *indexData = [MTGenerationIndex encodedDataWithRecords:@[]
                                                            error:&operationError];
    MTGenerationIndex *index = indexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:indexData
                                                 error:&operationError];
    NSString *emptyDigest = MTSHA256HexDigestForData(NSData.data);
    MTGenerationDescriptor *descriptor = index == nil ? nil :
        [[MTGenerationDescriptor alloc]
            initWithThemeID:@"theme.generation-benchmark.empty"
            libraryRevisionIdentifier:
                [@"r1-" stringByAppendingString:emptyDigest]
            manifestDigest:emptyDigest
            indexSHA256:MTSHA256HexDigestForData(indexData)
            indexByteCount:indexData.length
            indexFormatVersion:MTGenerationIndexFormatVersion
            resourceCount:0
            assets:@[]
            moduleIDs:@[]
            error:&operationError];
    MTCompiledGeneration *compiled = descriptor == nil ? nil :
        [[MTCompiledGeneration alloc]
            initWithDescriptor:descriptor
            index:index
            sourceAssetURLsByDigest:@{}];
    if (compiled == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorFixture,
            @"Unable to construct the zero-record Generation baseline.",
            operationError);
    }
    return compiled;
}

static NSArray<NSString *> *_Nullable MTGenerationBenchmarkLookupKeys(
    MTGeneration *generation,
    NSError **error) {
    NSMutableArray<NSString *> *keys = [NSMutableArray
        arrayWithCapacity:generation.index.recordCount];
    for (NSUInteger index = 0; index < generation.index.recordCount; index++) {
        MTGenerationIndexRecord *record = [generation.index
            recordAtIndex:index];
        if (record == nil) {
            MTGenerationBenchmarkSetError(error,
                MTGenerationBenchmarkErrorInvariant,
                @"A validated Generation did not expose an indexed record.",
                nil);
            return nil;
        }
        [keys addObject:record.canonicalResourceKey];
    }
    return [keys copy];
}

static NSDictionary<NSString *, NSNumber *> *_Nullable
MTGenerationBenchmarkMeasureLookups(
    MTGeneration *generation,
    MTGenerationBenchmarkMeasure measure,
    NSError **error) {
    NSError *operationError = nil;
    NSArray<NSString *> *keys = MTGenerationBenchmarkLookupKeys(
        generation, &operationError);
    MTResourceKey *missingKey = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
        surface:@"springboard.home"
        subject:@"com.hmmzzz.marktheme64e.generation-benchmark-miss"
        variant:@"primary"
        scale:3
        trait:@"any"
        error:&operationError];
    if (keys == nil || missingKey == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorFixture,
            @"Unable to construct deterministic Generation lookup keys.",
            operationError);
        return nil;
    }

    __block uint64_t accumulator = 0;
    __block NSUInteger hitCount = 0;
    __block NSUInteger missCount = 0;
    NSDictionary<NSString *, NSNumber *> *measurement = measure(
        ^BOOL(NSError **measureError) {
            uint32_t randomState = 0x4d544731u;
            NSError *workloadError = nil;
            BOOL success = YES;
            for (NSUInteger lookupIndex = 0;
                 lookupIndex < MTGenerationBenchmarkLookupCount;
                 lookupIndex++) {
                @autoreleasepool {
                    BOOL expectsMiss = keys.count == 0 ||
                        lookupIndex % 16 == 15;
                    NSString *key = missingKey.canonicalString;
                    if (!expectsMiss) {
                        NSUInteger pattern = lookupIndex % 16;
                        NSUInteger recordIndex = 0;
                        if (pattern == 0) {
                            recordIndex = 0;
                        } else if (pattern == 1) {
                            recordIndex = keys.count - 1;
                        } else if (pattern == 2) {
                            recordIndex = keys.count / 2;
                        } else {
                            randomState = randomState * 1664525u + 1013904223u;
                            recordIndex = (NSUInteger)randomState % keys.count;
                        }
                        key = keys[recordIndex];
                    }
                    NSError *lookupError = nil;
                    MTGenerationResource *resource = [generation
                        resourceForCanonicalResourceKey:key error:&lookupError];
                    if (expectsMiss) {
                        if (resource != nil || lookupError != nil) {
                            success = MTGenerationBenchmarkSetError(
                                &workloadError,
                                MTGenerationBenchmarkErrorInvariant,
                                @"A valid benchmark lookup miss changed semantics.",
                                lookupError);
                        } else {
                            missCount++;
                        }
                    } else {
                        if (resource == nil || lookupError != nil ||
                            resource.assetByteCount == 0) {
                            success = MTGenerationBenchmarkSetError(
                                &workloadError,
                                MTGenerationBenchmarkErrorInvariant,
                                @"A benchmark lookup hit failed validation.",
                                lookupError);
                        } else {
                            accumulator += resource.assetByteCount + lookupIndex;
                            hitCount++;
                        }
                    }
                }
                if (!success) break;
            }
            if (!success && measureError != NULL) {
                *measureError = workloadError;
            }
            return success;
        }, &operationError);
    if (measurement == nil ||
        hitCount + missCount != MTGenerationBenchmarkLookupCount ||
        (keys.count > 0 && (hitCount == 0 || accumulator == 0)) ||
        (keys.count == 0 && hitCount != 0)) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvariant,
            @"The deterministic Generation lookup workload was incomplete.",
            operationError);
        return nil;
    }
    return @{
        @"wallMicroseconds" : measurement[@"wallMicroseconds"],
        @"cpuMicroseconds" : measurement[@"cpuMicroseconds"],
        @"baselineFootprintBytes" : measurement[@"baselineFootprintBytes"],
        @"peakFootprintBytes" : measurement[@"peakFootprintBytes"],
        @"peakFootprintDeltaBytes" :
            measurement[@"peakFootprintDeltaBytes"],
        @"lookupCount" : @(MTGenerationBenchmarkLookupCount),
        @"hitCount" : @(hitCount),
        @"missCount" : @(missCount),
        @"accumulator" : @(accumulator),
    };
}

static NSDictionary<NSString *, id> *_Nullable
MTGenerationBenchmarkMeasureCompiledGeneration(
    MTCompiledGeneration *compiled,
    NSDictionary<NSString *, NSNumber *> *_Nullable buildMeasurement,
    NSString *_Nullable buildMeasurementName,
    NSURL *runRootURL,
    MTGenerationBenchmarkMeasure measure,
    NSError **error) {
    NSURL *compilerRoot = [runRootURL
        URLByAppendingPathComponent:@"compiler" isDirectory:YES];
    MTGenerationWriter *writer = MTGenerationBenchmarkWriter(compilerRoot);
    NSError *operationError = nil;
    __block MTGenerationWriteResult *writeResult = nil;
    NSDictionary *writeMeasurement = measure(
        ^BOOL(NSError **measureError) {
            writeResult = [writer
                writeCompiledGeneration:compiled
                cancellationToken:nil
                error:measureError];
            return writeResult != nil;
        }, &operationError);
    if (writeMeasurement == nil || writeResult == nil ||
        writeResult.reusedExistingGeneration) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvariant,
            @"Generation benchmark publication did not create one new final.",
            operationError);
        return nil;
    }

    MTGenerationReader *reader = MTGenerationBenchmarkReader(compilerRoot);
    __block MTGeneration *generation = nil;
    NSDictionary *readerMeasurement = measure(
        ^BOOL(NSError **measureError) {
            generation = [reader
                readGenerationWithIdentifier:writeResult.generationIdentifier
                cancellationToken:nil
                error:measureError];
            return generation != nil;
        }, &operationError);
    if (readerMeasurement == nil || generation == nil ||
        ![generation.generationIdentifier
            isEqualToString:compiled.descriptor.generationIdentifier] ||
        generation.index.recordCount != compiled.index.recordCount ||
        generation.descriptor.assetCount != compiled.descriptor.assetCount) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvariant,
            @"Fresh Generation reader validation changed the compiled identity.",
            operationError);
        return nil;
    }

    NSDictionary *lookupMeasurement = MTGenerationBenchmarkMeasureLookups(
        generation, measure, &operationError);
    if (lookupMeasurement == nil) {
        if (error != NULL) *error = operationError;
        return nil;
    }

    NSMutableDictionary<NSString *, id> *result = [@{
        @"generationWrite" : writeMeasurement,
        @"generationFreshReaderFullValidate" : readerMeasurement,
        @"generationResourceLookup100k" : lookupMeasurement,
        @"generationIdentifier" : generation.generationIdentifier,
        @"generationResourceCount" : @(generation.index.recordCount),
        @"generationAssetCount" : @(generation.descriptor.assetCount),
        @"generationAssetByteCount" :
            @(generation.descriptor.assetByteCount),
        @"generationIndexByteCount" :
            @(generation.descriptor.indexByteCount),
        @"generationWriterClonedAssetCount" :
            @(writeResult.clonedAssetCount),
        @"generationWriterStreamedAssetCount" :
            @(writeResult.streamedAssetCount),
    } mutableCopy];
    if (buildMeasurement != nil && buildMeasurementName.length > 0) {
        result[buildMeasurementName] = buildMeasurement;
    }
    return [result copy];
}

NSDictionary<NSString *, id> *MTGenerationBenchmarkMeasureRevision(
    MTThemeLibraryRevision *revision,
    NSURL *runRootURL,
    MTGenerationBenchmarkMeasure measure,
    NSError **error) {
    if (![revision isKindOfClass:MTThemeLibraryRevision.class] ||
        !runRootURL.isFileURL || runRootURL.path.length == 0 ||
        measure == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvalidRequest,
            @"Generation revision benchmark parameters are invalid.", nil);
        return nil;
    }
    NSError *operationError = nil;
    __block MTCompiledGeneration *compiled = nil;
    NSDictionary *compileMeasurement = measure(
        ^BOOL(NSError **measureError) {
            compiled = [MTStaticIconCompiler.defaultCompiler
                compileLibraryRevision:revision
                cancellationToken:nil
                error:measureError];
            return compiled != nil;
        }, &operationError);
    if (compileMeasurement == nil || compiled == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvariant,
            @"Generation benchmark pure compilation failed.", operationError);
        return nil;
    }
    return MTGenerationBenchmarkMeasureCompiledGeneration(
        compiled, compileMeasurement, @"generationCompile", runRootURL,
        measure, error);
}

NSDictionary<NSString *, id> *MTGenerationBenchmarkMeasureZeroRecordBaseline(
    NSURL *runRootURL,
    MTGenerationBenchmarkMeasure measure,
    NSError **error) {
    if (!runRootURL.isFileURL || runRootURL.path.length == 0 ||
        measure == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvalidRequest,
            @"Zero-record Generation benchmark parameters are invalid.", nil);
        return nil;
    }
    NSError *operationError = nil;
    __block MTCompiledGeneration *compiled = nil;
    NSDictionary *formatMeasurement = measure(
        ^BOOL(NSError **measureError) {
            compiled = MTGenerationBenchmarkCreateZeroRecordFixture(
                measureError);
            return compiled != nil;
        }, &operationError);
    if (formatMeasurement == nil || compiled == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorFixture,
            @"Zero-record Generation format construction failed.",
            operationError);
        return nil;
    }
    return MTGenerationBenchmarkMeasureCompiledGeneration(
        compiled, formatMeasurement, @"generationFormatBuild", runRootURL,
        measure, error);
}
