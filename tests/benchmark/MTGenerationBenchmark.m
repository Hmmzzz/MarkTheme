#import "MTGenerationBenchmark.h"

#import "MTDigest.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTGenerationWriter.h"
#import "MTResourceKey.h"
#import "MTStaticIconCompiler.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeLibraryStoreInternal.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"

NSString *const MTGenerationBenchmarkErrorDomain =
    @"com.hmmzzz.marktheme.tests.generation-benchmark";
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
        subject:@"com.hmmzzz.marktheme.generation-benchmark-miss"
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

static MTThemeLibraryRevision *_Nullable
MTGenerationBenchmarkMixRevision(MTThemeLibraryRevision *sourceRevision,
                                 NSArray<MTThemeResource *> *resources,
                                 NSUInteger layerIndex,
                                 NSError **error) {
    NSString *themeIdentifier = [NSString stringWithFormat:
        @"theme.generation-benchmark.mix%lu", (unsigned long)layerIndex];
    NSString *firstSubject = resources.firstObject.resourceKey.subject;
    MTStaticIconConfiguration *configuration = firstSubject.length == 0 ? nil :
        [MTStaticIconConfiguration
            configurationWithFuzzyBundleIdentifiers:@[firstSubject]
            bundleAliases:@{
                [NSString stringWithFormat:@"benchmark.layer%lu.request",
                    (unsigned long)layerIndex] : firstSubject,
            }];
    NSString *fingerprint = MTSHA256HexDigestForData(
        [themeIdentifier dataUsingEncoding:NSUTF8StringEncoding]);
    MTThemeManifest *manifest = configuration == nil ? nil :
        [[MTThemeManifest alloc]
            initWithThemeID:themeIdentifier
            displayName:[NSString stringWithFormat:@"Mix Layer %lu",
                (unsigned long)(layerIndex + 1)]
            author:@"MarkTheme Benchmark"
            themeVersion:@"1"
            importerID:@"marktheme.benchmark"
            importerVersion:1
            sourceFingerprint:fingerprint
            capabilities:@[@"icons.static"]
            moduleConfigurations:@{
                @"icons.static" : configuration.canonicalDictionary,
            }
            resources:resources
            error:error];
    NSString *manifestDigest = [manifest contentDigestWithError:error];
    if (manifestDigest == nil) return nil;

    NSMutableSet<NSString *> *digests = [NSMutableSet set];
    for (MTThemeResource *resource in resources) {
        [digests addObject:resource.contentSHA256];
    }
    NSMutableDictionary<NSString *, NSURL *> *assetURLs =
        [NSMutableDictionary dictionaryWithCapacity:digests.count];
    NSMutableDictionary<NSString *, NSNumber *> *assetByteCounts =
        [NSMutableDictionary dictionaryWithCapacity:digests.count];
    uint64_t assetByteCount = 0;
    for (NSString *digest in digests) {
        NSURL *assetURL = sourceRevision.assetURLsByContentSHA256[digest];
        NSNumber *bytes = sourceRevision
            .assetByteCountsByContentSHA256[digest];
        if (assetURL == nil || bytes == nil ||
            UINT64_MAX - assetByteCount < bytes.unsignedLongLongValue) {
            MTGenerationBenchmarkSetError(error,
                MTGenerationBenchmarkErrorFixture,
                @"Three-layer mix fixture lost one source asset identity.", nil);
            return nil;
        }
        assetURLs[digest] = assetURL;
        assetByteCounts[digest] = bytes;
        assetByteCount += bytes.unsignedLongLongValue;
    }
    return [[MTThemeLibraryRevision alloc]
        initWithRevisionIdentifier:
            [@"r1-" stringByAppendingString:manifestDigest]
        manifestDigest:manifestDigest
        manifest:manifest
        assetURLsByContentSHA256:assetURLs
        assetByteCountsByContentSHA256:assetByteCounts
        resourcesDirectoryURL:nil
        assetByteCount:assetByteCount];
}

NSDictionary<NSString *, id> *
MTGenerationBenchmarkMeasureThreeLayerMixCompilation(
    MTThemeLibraryRevision *revision,
    MTGenerationBenchmarkMeasure measure,
    NSError **error) {
    if (![revision isKindOfClass:MTThemeLibraryRevision.class] ||
        measure == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvalidRequest,
            @"Three-layer mix benchmark parameters are invalid.", nil);
        return nil;
    }
    NSMutableDictionary<NSString *, NSMutableArray<MTThemeResource *> *> *
        resourcesBySubject = [NSMutableDictionary dictionary];
    for (MTThemeResource *resource in revision.manifest.resources) {
        MTResourceKey *key = resource.resourceKey;
        if (![key.moduleID isEqualToString:@"icons.static"] ||
            ![key.surface isEqualToString:@"springboard.home"]) {
            continue;
        }
        NSMutableArray<MTThemeResource *> *subjectResources =
            resourcesBySubject[key.subject];
        if (subjectResources == nil) {
            subjectResources = [NSMutableArray array];
            resourcesBySubject[key.subject] = subjectResources;
        }
        [subjectResources addObject:resource];
    }
    NSArray<NSString *> *subjects = [resourcesBySubject.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    if (subjects.count < 3) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorFixture,
            @"Three-layer mix benchmark requires at least three App subjects.",
            nil);
        return nil;
    }

    NSMutableArray<NSMutableArray<MTThemeResource *> *> *layerResources =
        [NSMutableArray arrayWithCapacity:3];
    for (NSUInteger layerIndex = 0; layerIndex < 3; layerIndex++) {
        [layerResources addObject:[NSMutableArray array]];
    }
    NSUInteger overlappingSubjectCount = 0;
    for (NSUInteger subjectIndex = 0; subjectIndex < subjects.count;
         subjectIndex++) {
        NSArray<MTThemeResource *> *resources =
            resourcesBySubject[subjects[subjectIndex]];
        BOOL overlapping = subjectIndex % 10 == 0;
        if (overlapping) overlappingSubjectCount++;
        for (NSUInteger layerIndex = 0; layerIndex < 3; layerIndex++) {
            if (overlapping || subjectIndex % 3 == layerIndex) {
                [layerResources[layerIndex] addObjectsFromArray:resources];
            }
        }
    }

    NSError *fixtureError = nil;
    NSMutableDictionary<NSString *, MTThemeLibraryRevision *> *revisions =
        [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableDictionary<NSString *, NSString *> *revisionIdentifiers =
        [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableDictionary<NSString *, MTThemeComponentSelection *> *selections =
        [NSMutableDictionary dictionaryWithCapacity:3];
    NSMutableArray<NSString *> *themeIdentifiers =
        [NSMutableArray arrayWithCapacity:3];
    for (NSUInteger layerIndex = 0; layerIndex < 3; layerIndex++) {
        MTThemeLibraryRevision *layerRevision =
            MTGenerationBenchmarkMixRevision(
                revision, layerResources[layerIndex], layerIndex,
                &fixtureError);
        MTThemeComponentCatalog *catalog = layerRevision == nil ? nil :
            [MTThemeComponentCatalog catalogForManifest:layerRevision.manifest
                                                   error:&fixtureError];
        if (layerRevision == nil || catalog == nil) {
            MTGenerationBenchmarkSetError(error,
                MTGenerationBenchmarkErrorFixture,
                @"Unable to construct a three-layer mix benchmark source.",
                fixtureError);
            return nil;
        }
        NSString *themeIdentifier = layerRevision.manifest.themeID;
        revisions[themeIdentifier] = layerRevision;
        revisionIdentifiers[themeIdentifier] =
            layerRevision.revisionIdentifier;
        selections[themeIdentifier] = catalog.defaultSelection;
        [themeIdentifiers addObject:themeIdentifier];
    }
    MTThemeMixSelection *mix = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:themeIdentifiers[0]
        sourceThemeIdentifiersByFeature:@{}
        appIconFallbackThemeIdentifiers:@[
            themeIdentifiers[1], themeIdentifiers[2],
        ]
        disabledFeatureIdentifiers:@[]
        revisionIdentifiersByThemeIdentifier:revisionIdentifiers
        componentSelectionsByThemeIdentifier:selections
        error:&fixtureError];
    if (mix == nil) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorFixture,
            @"Unable to construct the three-layer mix benchmark selection.",
            fixtureError);
        return nil;
    }

    __block MTCompiledGeneration *compiled = nil;
    NSDictionary<NSString *, NSNumber *> *compileMeasurement = measure(
        ^BOOL(NSError **measureError) {
            compiled = [MTStaticIconCompiler.defaultCompiler
                compileLibraryRevisionsByThemeIdentifier:revisions
                mixSelection:mix cancellationToken:nil error:measureError];
            return compiled != nil;
        }, &fixtureError);
    if (compileMeasurement == nil || compiled == nil ||
        compiled.index.recordCount != revision.manifest.resources.count) {
        MTGenerationBenchmarkSetError(error,
            MTGenerationBenchmarkErrorInvariant,
            @"Three-layer mix compilation changed the complete source coverage.",
            fixtureError);
        return nil;
    }
    return @{
        @"generationThreeLayerMixCompile" : compileMeasurement,
        @"generationThreeLayerMixResourceCount" :
            @(compiled.index.recordCount),
        @"generationThreeLayerMixSourceSubjectCount" : @(subjects.count),
        @"generationThreeLayerMixOverlappingSubjectCount" :
            @(overlappingSubjectCount),
    };
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
