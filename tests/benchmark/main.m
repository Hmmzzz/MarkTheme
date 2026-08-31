#import <Foundation/Foundation.h>

#import <fcntl.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>

#import "MTGenerationBenchmark.h"
#import "MTImportLimits.h"
#import "MTSafeImageDecoder.h"
#import "MTSafeImageInspector.h"
#import "MTSyntheticCorpus.h"
#import "MTThemeImport.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

static NSString *const MTBenchmarkErrorDomain =
    @"com.hmmzzz.marktheme.tests.benchmark";
static const useconds_t MTBenchmarkFootprintIntervalMicroseconds = 10000;

typedef NS_ENUM(NSInteger, MTBenchmarkErrorCode) {
    MTBenchmarkErrorInvalidArguments = 1,
    MTBenchmarkErrorFilesystem = 2,
    MTBenchmarkErrorOperation = 3,
    MTBenchmarkErrorInvariant = 4,
};

static BOOL MTBenchmarkSetError(NSError **error,
                                MTBenchmarkErrorCode code,
                                NSString *description,
                                NSError *_Nullable underlyingError) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey : description,
        } mutableCopy];
        if (underlyingError != nil) userInfo[NSUnderlyingErrorKey] = underlyingError;
        *error = [NSError errorWithDomain:MTBenchmarkErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static uint64_t MTBenchmarkNowNanoseconds(clockid_t clockID) {
    struct timespec value = {0};
    if (clock_gettime(clockID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * NSEC_PER_SEC + (uint64_t)value.tv_nsec;
}

static uint64_t MTBenchmarkElapsedMicroseconds(uint64_t start,
                                               uint64_t end) {
    return end >= start ? (end - start) / NSEC_PER_USEC : 0;
}

static uint64_t MTBenchmarkPhysicalFootprint(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO,
        (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? info.phys_footprint : 0;
}

@interface MTBenchmarkFootprintSampler : NSObject
@property(atomic, assign, getter=isRunning) BOOL running;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_semaphore_t completion;
@property(nonatomic, assign) uint64_t baselineFootprint;
@property(nonatomic, assign) uint64_t peakFootprint;
- (void)start;
- (void)stop;
@end

@implementation MTBenchmarkFootprintSampler

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _queue = dispatch_queue_create(
        "com.hmmzzz.marktheme.tests.benchmark-footprint",
        DISPATCH_QUEUE_SERIAL);
    _completion = dispatch_semaphore_create(0);
    return self;
}

- (void)start {
    self.baselineFootprint = MTBenchmarkPhysicalFootprint();
    self.peakFootprint = self.baselineFootprint;
    self.running = YES;
    dispatch_async(self.queue, ^{
        while (self.isRunning) {
            uint64_t footprint = MTBenchmarkPhysicalFootprint();
            if (footprint > self.peakFootprint) {
                self.peakFootprint = footprint;
            }
            usleep(MTBenchmarkFootprintIntervalMicroseconds);
        }
        uint64_t finalFootprint = MTBenchmarkPhysicalFootprint();
        if (finalFootprint > self.peakFootprint) {
            self.peakFootprint = finalFootprint;
        }
        dispatch_semaphore_signal(self.completion);
    });
}

- (void)stop {
    self.running = NO;
    dispatch_semaphore_wait(self.completion, DISPATCH_TIME_FOREVER);
}

@end

typedef BOOL (^MTBenchmarkOperation)(NSError **error);

static NSDictionary<NSString *, NSNumber *> *_Nullable
MTBenchmarkMeasureOperation(MTBenchmarkOperation operation,
                            NSError **error) {
    MTBenchmarkFootprintSampler *sampler =
        [[MTBenchmarkFootprintSampler alloc] init];
    [sampler start];
    uint64_t wallStart = MTBenchmarkNowNanoseconds(CLOCK_MONOTONIC_RAW);
    uint64_t cpuStart = MTBenchmarkNowNanoseconds(CLOCK_PROCESS_CPUTIME_ID);
    NSError *operationError = nil;
    BOOL success = operation(&operationError);
    uint64_t cpuEnd = MTBenchmarkNowNanoseconds(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t wallEnd = MTBenchmarkNowNanoseconds(CLOCK_MONOTONIC_RAW);
    [sampler stop];
    if (!success) {
        MTBenchmarkSetError(error, MTBenchmarkErrorOperation,
            @"A measured benchmark operation failed.", operationError);
        return nil;
    }
    uint64_t delta = sampler.peakFootprint >= sampler.baselineFootprint
        ? sampler.peakFootprint - sampler.baselineFootprint
        : 0;
    return @{
        @"wallMicroseconds" :
            @(MTBenchmarkElapsedMicroseconds(wallStart, wallEnd)),
        @"cpuMicroseconds" :
            @(MTBenchmarkElapsedMicroseconds(cpuStart, cpuEnd)),
        @"baselineFootprintBytes" : @(sampler.baselineFootprint),
        @"peakFootprintBytes" : @(sampler.peakFootprint),
        @"peakFootprintDeltaBytes" : @(delta),
    };
}

static MTGenerationBenchmarkMeasure MTBenchmarkGenerationMeasure(void) {
    return ^NSDictionary<NSString *, NSNumber *> *_Nullable(
        MTGenerationBenchmarkOperation operation,
        NSError **error) {
        return MTBenchmarkMeasureOperation(operation, error);
    };
}

static NSString *MTBenchmarkStageName(MTThemeImportStage stage) {
    switch (stage) {
        case MTThemeImportStageAcquiring: return @"acquiring";
        case MTThemeImportStageAuditing: return @"auditing";
        case MTThemeImportStageParsing: return @"parsing";
        case MTThemeImportStageStaging: return @"staging";
        case MTThemeImportStageValidating: return @"validating";
        case MTThemeImportStageCommitting: return @"committing";
    }
    return @"unknown";
}

@interface MTBenchmarkProgressCapture : NSObject
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *starts;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *ends;
- (void)recordStage:(MTThemeImportStage)stage
          completed:(NSUInteger)completed
              total:(NSUInteger)total;
- (NSDictionary<NSString *, NSNumber *> *)wallDurations;
- (NSDictionary<NSString *, NSNumber *> *)cpuDurations;
@end

@implementation MTBenchmarkProgressCapture

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _starts = [NSMutableDictionary dictionary];
    _ends = [NSMutableDictionary dictionary];
    return self;
}

- (void)recordStage:(MTThemeImportStage)stage
          completed:(NSUInteger)completed
              total:(NSUInteger)total {
    NSString *name = MTBenchmarkStageName(stage);
    NSDictionary *point = @{
        @"wall" : @(MTBenchmarkNowNanoseconds(CLOCK_MONOTONIC_RAW)),
        @"cpu" : @(MTBenchmarkNowNanoseconds(CLOCK_PROCESS_CPUTIME_ID)),
    };
    if (self.starts[name] == nil) self.starts[name] = point;
    if (total > 0 && completed >= total) self.ends[name] = point;
}

- (NSDictionary<NSString *, NSNumber *> *)durationsForClock:
    (NSString *)clockKey {
    NSMutableDictionary<NSString *, NSNumber *> *durations =
        [NSMutableDictionary dictionary];
    for (NSString *name in self.starts) {
        NSDictionary *start = self.starts[name];
        NSDictionary *end = self.ends[name];
        if (end == nil) continue;
        durations[name] = @(MTBenchmarkElapsedMicroseconds(
            [start[clockKey] unsignedLongLongValue],
            [end[clockKey] unsignedLongLongValue]));
    }
    return [durations copy];
}

- (NSDictionary<NSString *, NSNumber *> *)wallDurations {
    return [self durationsForClock:@"wall"];
}

- (NSDictionary<NSString *, NSNumber *> *)cpuDurations {
    return [self durationsForClock:@"cpu"];
}

@end

static NSDictionary<NSString *, NSNumber *> *MTBenchmarkStatistics(
    NSArray<NSNumber *> *values) {
    NSArray<NSNumber *> *sorted = [values sortedArrayUsingComparator:
        ^NSComparisonResult(NSNumber *left, NSNumber *right) {
            return [left compare:right];
        }];
    if (sorted.count == 0) return @{};
    NSUInteger rank50 = (50 * sorted.count + 99) / 100;
    NSUInteger rank95 = (95 * sorted.count + 99) / 100;
    return @{
        @"sampleCount" : @(sorted.count),
        @"minimum" : sorted.firstObject,
        @"p50" : sorted[rank50 - 1],
        @"p95" : sorted[rank95 - 1],
        @"maximum" : sorted.lastObject,
    };
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *
MTBenchmarkOperationSummary(NSArray<NSDictionary *> *samples,
                            NSArray<NSString *> *operationNames) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *operationName in operationNames) {
        for (NSString *metricName in @[
            @"wallMicroseconds", @"cpuMicroseconds",
            @"peakFootprintDeltaBytes"
        ]) {
            NSMutableArray<NSNumber *> *values = [NSMutableArray array];
            for (NSDictionary *sample in samples) {
                NSNumber *value = sample[operationName][metricName];
                if (value != nil) [values addObject:value];
            }
            summary[[NSString stringWithFormat:@"%@.%@",
                operationName, metricName]] = MTBenchmarkStatistics(values);
        }
    }
    return [summary copy];
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *
MTBenchmarkStageSummary(NSArray<NSDictionary *> *samples) {
    NSMutableSet<NSString *> *stageNames = [NSMutableSet set];
    for (NSDictionary *sample in samples) {
        [stageNames addObjectsFromArray:
            [sample[@"prepareStageWallMicroseconds"] allKeys]];
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *stageName in stageNames) {
        for (NSString *clockKey in @[
            @"prepareStageWallMicroseconds",
            @"prepareStageCPUMicroseconds"
        ]) {
            NSMutableArray<NSNumber *> *values = [NSMutableArray array];
            for (NSDictionary *sample in samples) {
                NSNumber *value = sample[clockKey][stageName];
                if (value != nil) [values addObject:value];
            }
            summary[[NSString stringWithFormat:@"%@.%@",
                clockKey, stageName]] = MTBenchmarkStatistics(values);
        }
    }
    return [summary copy];
}

static NSURL *_Nullable MTBenchmarkCreateTemporaryRoot(NSError **error) {
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"marktheme-benchmark.XXXXXX"];
    NSMutableData *buffer = [[template dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    [buffer increaseLengthBy:1];
    char *path = buffer.mutableBytes;
    if (mkdtemp(path) == NULL || chmod(path, 0700) != 0) {
        MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to create the private benchmark root.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }
    return [NSURL fileURLWithFileSystemRepresentation:path
                                          isDirectory:YES
                                        relativeToURL:nil];
}

static BOOL MTBenchmarkCreateDirectory(NSURL *url, NSError **error) {
    NSError *operationError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url
                                withIntermediateDirectories:NO
                                                 attributes:@{
            NSFilePosixPermissions : @0700,
        } error:&operationError] || chmod(url.fileSystemRepresentation, 0700) != 0) {
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to create a benchmark case directory.",
            operationError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno userInfo:nil]);
    }
    return YES;
}

static BOOL MTBenchmarkRemoveTemporaryNode(NSURL *url, NSError **error) {
    if (![url.lastPathComponent hasPrefix:@"marktheme-benchmark"] &&
        ![url.lastPathComponent hasPrefix:@"run-"]) {
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Refusing to remove an unexpected benchmark path.", nil);
    }
    NSError *operationError = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path] &&
        ![NSFileManager.defaultManager removeItemAtURL:url error:&operationError]) {
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to remove a private benchmark path.", operationError);
    }
    return YES;
}

static NSDictionary *_Nullable MTBenchmarkPixelCase(uint32_t dimension,
                                                     NSUInteger repetitions,
                                                     NSURL *benchmarkRoot,
                                                     NSError **error) {
    NSError *operationError = nil;
    NSData *png = MTSyntheticPNGData(dimension, 0x4d54u + dimension,
                                     &operationError);
    NSURL *fileURL = [benchmarkRoot URLByAppendingPathComponent:
        [NSString stringWithFormat:@"pixel-%u.png", dimension]];
    if (png == nil ||
        ![png writeToURL:fileURL options:NSDataWritingAtomic
                    error:&operationError] ||
        chmod(fileURL.fileSystemRepresentation, 0600) != 0) {
        MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to create a standalone pixel benchmark fixture.",
            operationError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno userInfo:nil]);
        return nil;
    }

    fprintf(stderr, "pixel benchmark: %u px, %lu repetitions\n",
            dimension, (unsigned long)repetitions);
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    MTSafeImageDecoder *decoder = MTSafeImageDecoder.defaultDecoder;
    for (NSUInteger repetition = 0; repetition < repetitions; repetition++) {
        NSError *iterationError = nil;
        @autoreleasepool {
            __block MTSafeImageDecodeResult *decodeResult = nil;
            NSDictionary *measurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    decodeResult = [decoder
                        decodeOwnedPNGFileAtURL:fileURL
                        thumbnailMaximumDimension:160
                        cancellationToken:nil error:measureError];
                    return decodeResult != nil;
                }, &operationError);
            if (measurement == nil ||
                decodeResult.inspection.pixelWidth != dimension ||
                decodeResult.inspection.pixelHeight != dimension) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Standalone pixel decode did not preserve its dimensions.",
                    operationError);
            } else {
                [samples addObject:@{
                    @"repetition" : @(repetition + 1),
                    @"decode" : measurement,
                    @"fullResolutionDecodedBytes" :
                        @(decodeResult.fullResolutionDecodedByteCount),
                    @"thumbnailBytes" :
                        @(decodeResult.thumbnailPixelData.length),
                }];
            }
        }
        if (iterationError != nil) {
            if (error != NULL) *error = iterationError;
            return nil;
        }
    }
    unlink(fileURL.fileSystemRepresentation);
    return @{
        @"kind" : @"pixel-decode",
        @"pixelDimension" : @(dimension),
        @"encodedByteCount" : @(png.length),
        @"repetitions" : @(repetitions),
        @"samples" : samples,
        @"summary" : MTBenchmarkOperationSummary(samples, @[@"decode"]),
    };
}

static NSDictionary *_Nullable MTBenchmarkZeroGenerationCase(
    NSUInteger repetitions,
    NSURL *benchmarkRoot,
    NSError **error) {
    fprintf(stderr, "generation benchmark: 0 records, %lu repetitions\n",
            (unsigned long)repetitions);
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    NSString *expectedGenerationIdentifier = nil;
    for (NSUInteger repetition = 0; repetition < repetitions; repetition++) {
        NSURL *runRoot = [benchmarkRoot URLByAppendingPathComponent:
            [NSString stringWithFormat:@"run-generation-zero-%02lu",
                (unsigned long)repetition]
            isDirectory:YES];
        NSError *operationError = nil;
        if (!MTBenchmarkCreateDirectory(runRoot, &operationError)) {
            if (error != NULL) *error = operationError;
            return nil;
        }
        NSDictionary<NSString *, id> *generation =
            MTGenerationBenchmarkMeasureZeroRecordBaseline(
                runRoot, MTBenchmarkGenerationMeasure(), &operationError);
        NSString *identifier = generation[@"generationIdentifier"];
        if (generation == nil || identifier.length == 0 ||
            (expectedGenerationIdentifier != nil &&
             ![identifier isEqualToString:expectedGenerationIdentifier])) {
            MTBenchmarkSetError(error, MTBenchmarkErrorInvariant,
                @"Zero-record Generation baseline changed identity.",
                operationError);
            return nil;
        }
        expectedGenerationIdentifier = identifier;
        NSMutableDictionary *sample = [generation mutableCopy];
        sample[@"repetition"] = @(repetition + 1);
        [samples addObject:[sample copy]];
        if (!MTBenchmarkRemoveTemporaryNode(runRoot, &operationError)) {
            if (error != NULL) *error = operationError;
            return nil;
        }
    }
    return @{
        @"kind" : @"generation-zero-record-baseline",
        @"generationIdentifier" : expectedGenerationIdentifier,
        @"resourceCount" : @0,
        @"repetitions" : @(repetitions),
        @"cacheState" :
            @"new reader instance; host filesystem cache uncontrolled",
        @"samples" : samples,
        @"summary" : MTBenchmarkOperationSummary(samples, @[
            @"generationFormatBuild", @"generationWrite",
            @"generationFreshReaderFullValidate",
            @"generationResourceLookup100k",
        ]),
    };
}

static NSDictionary *_Nullable MTBenchmarkImportCase(
    MTSyntheticCorpus *corpus,
    NSString *container,
    NSUInteger repetitions,
    NSURL *benchmarkRoot,
    NSError **error) {
    BOOL directory = [container isEqualToString:@"directory"];
    NSURL *sourceURL = directory ? corpus.directoryURL : corpus.archiveURL;
    fprintf(stderr, "import benchmark: %s, %lu icons, %lu repetitions\n",
            container.UTF8String, (unsigned long)corpus.iconCount,
            (unsigned long)repetitions);
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    NSString *expectedManifestDigest = nil;
    NSString *expectedSourceFingerprint = nil;
    NSString *expectedGenerationIdentifier = nil;
    for (NSUInteger repetition = 0; repetition < repetitions; repetition++) {
        NSError *iterationError = nil;
        @autoreleasepool {
            do {
            NSURL *runRoot = [benchmarkRoot URLByAppendingPathComponent:
                [NSString stringWithFormat:@"run-%@-%04lu-%02lu",
                    container, (unsigned long)corpus.iconCount,
                    (unsigned long)repetition]
                isDirectory:YES];
            NSError *operationError = nil;
            if (!MTBenchmarkCreateDirectory(runRoot, &operationError)) {
                iterationError = operationError;
                break;
            }
            NSURL *importRoot = [runRoot
                URLByAppendingPathComponent:@"import" isDirectory:YES];
            NSURL *assetRoot = [runRoot
                URLByAppendingPathComponent:@"assets" isDirectory:YES];
            NSURL *libraryRoot = [runRoot
                URLByAppendingPathComponent:@"library" isDirectory:YES];
            MTImportLimits *limits = MTImportLimits.defaultLimits;
            MTThemeImportConfiguration *configuration =
                [[MTThemeImportConfiguration alloc]
                    initWithLimits:limits
                    importSessionsRootURL:importRoot
                    assetSessionsRootURL:assetRoot
                    libraryRootURL:libraryRoot
                    libraryFreeSpaceReserveBytes:0
                    imageDecoder:MTSafeImageDecoder.defaultDecoder
                    maximumPreviewCount:1
                    previewMaximumDimension:64];
            MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc]
                initWithConfiguration:configuration];
            MTBenchmarkProgressCapture *progress =
                [[MTBenchmarkProgressCapture alloc] init];
            __block MTPreparedThemeImport *prepared = nil;
            NSDictionary *prepareMeasurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    MTThemeImportProgressHandler handler =
                        ^(MTThemeImportStage stage, NSUInteger completed,
                          NSUInteger total) {
                            [progress recordStage:stage completed:completed
                                           total:total];
                        };
                    prepared = directory
                        ? [pipeline prepareDirectoryThemeAtURL:sourceURL
                            sourceName:@"SyntheticBenchmark.theme"
                            cancellationToken:nil progressHandler:handler
                            error:measureError]
                        : [pipeline prepareZIPThemeAtURL:sourceURL
                            sourceName:@"SyntheticBenchmark.theme.zip"
                            cancellationToken:nil progressHandler:handler
                            error:measureError];
                    return prepared != nil;
                }, &operationError);
            if (prepareMeasurement == nil || prepared == nil ||
                prepared.recognizedFileCount != corpus.iconCount ||
                prepared.uniqueAssetCount != corpus.iconCount ||
                prepared.sourceFileCount != corpus.iconCount + 1) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Synthetic import preparation violated its count contract.",
                    operationError);
                break;
            }
            NSString *manifestDigest = [prepared.manifest
                contentDigestWithError:&operationError];
            if (manifestDigest == nil ||
                (expectedManifestDigest != nil &&
                 ![manifestDigest isEqualToString:expectedManifestDigest]) ||
                (expectedSourceFingerprint != nil &&
                 ![prepared.manifest.sourceFingerprint
                    isEqualToString:expectedSourceFingerprint])) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Repeated synthetic imports produced different canonical identities.",
                    operationError);
                break;
            }
            expectedManifestDigest = manifestDigest;
            expectedSourceFingerprint = prepared.manifest.sourceFingerprint;

            __block MTThemeLibraryRevision *committedRevision = nil;
            NSDictionary *commitMeasurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    committedRevision = [pipeline
                        commitPreparedImport:prepared cancellationToken:nil
                        progressHandler:nil error:measureError];
                    return committedRevision != nil;
                }, &operationError);
            if (commitMeasurement == nil ||
                committedRevision.assetCount != corpus.iconCount) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Synthetic formal Library commit violated its asset contract.",
                    operationError);
                break;
            }

            MTThemeLibraryConfiguration *libraryConfiguration =
                [[MTThemeLibraryConfiguration alloc]
                    initWithRootURL:libraryRoot limits:limits
                    minimumFreeSpaceReserveBytes:0];
            MTThemeLibraryStore *library = [[MTThemeLibraryStore alloc]
                initWithConfiguration:libraryConfiguration];
            __block NSArray<MTThemeLibraryThemeSummary *> *catalog = nil;
            NSDictionary *catalogMeasurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    catalog = [library
                        loadThemeCatalogWithCancellationToken:nil
                        error:measureError];
                    return catalog != nil;
                }, &operationError);
            __block MTThemeLibraryRevision *loadedRevision = nil;
            NSDictionary *readMeasurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    loadedRevision = [library
                        loadCurrentRevisionForThemeID:
                            prepared.manifest.themeID
                        error:measureError];
                    return loadedRevision != nil;
                }, &operationError);
            if (catalogMeasurement == nil ||
                readMeasurement == nil || catalog.count != 1 ||
                loadedRevision.assetCount != corpus.iconCount) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Synthetic Library readback violated its catalog or revision contract.",
                    operationError);
                break;
            }

            operationError = nil;
            NSDictionary<NSString *, id> *generation =
                MTGenerationBenchmarkMeasureRevision(
                    loadedRevision, runRoot, MTBenchmarkGenerationMeasure(),
                    &operationError);
            NSString *generationIdentifier =
                generation[@"generationIdentifier"];
            if (generation == nil || generationIdentifier.length == 0 ||
                [generation[@"generationResourceCount"]
                    unsignedIntegerValue] != corpus.iconCount ||
                [generation[@"generationAssetCount"]
                    unsignedIntegerValue] != corpus.iconCount ||
                (expectedGenerationIdentifier != nil &&
                 ![generationIdentifier
                    isEqualToString:expectedGenerationIdentifier])) {
                MTBenchmarkSetError(&iterationError,
                    MTBenchmarkErrorInvariant,
                    @"Synthetic Generation benchmark violated its identity or count contract.",
                    operationError);
                break;
            }
            expectedGenerationIdentifier = generationIdentifier;

            NSMutableDictionary *sample = [@{
                @"repetition" : @(repetition + 1),
                @"prepare" : prepareMeasurement,
                @"prepareStageWallMicroseconds" : progress.wallDurations,
                @"prepareStageCPUMicroseconds" : progress.cpuDurations,
                @"commit" : commitMeasurement,
                @"catalog" : catalogMeasurement,
                @"fullRevisionRead" : readMeasurement,
                @"sourceFileCount" : @(prepared.sourceFileCount),
                @"recognizedFileCount" : @(prepared.recognizedFileCount),
                @"uniqueAssetCount" : @(prepared.uniqueAssetCount),
                @"assetByteCount" : @(prepared.assetByteCount),
                @"revisionAssetByteCount" :
                    @(loadedRevision.assetByteCount),
            } mutableCopy];
            [sample addEntriesFromDictionary:generation];
            [samples addObject:[sample copy]];
            if (!MTBenchmarkRemoveTemporaryNode(runRoot, &operationError)) {
                iterationError = operationError;
                break;
            }
            } while (NO);
        }
        if (iterationError != nil) {
            if (error != NULL) *error = iterationError;
            return nil;
        }
    }
    return @{
        @"kind" : @"theme-import",
        @"container" : container,
        @"iconCount" : @(corpus.iconCount),
        @"pixelDimension" : @(corpus.pixelDimension),
        @"directoryPayloadByteCount" :
            @(corpus.directoryPayloadByteCount),
        @"archiveByteCount" : @(corpus.archiveByteCount),
        @"manifestDigest" : expectedManifestDigest,
        @"sourceFingerprint" : expectedSourceFingerprint,
        @"generationIdentifier" : expectedGenerationIdentifier,
        @"generationCacheState" :
            @"new reader instance; host filesystem cache uncontrolled",
        @"repetitions" : @(repetitions),
        @"samples" : samples,
        @"summary" : MTBenchmarkOperationSummary(samples, @[
            @"prepare", @"commit", @"catalog", @"history",
            @"fullRevisionRead", @"generationCompile", @"generationWrite",
            @"generationFreshReaderFullValidate",
            @"generationResourceLookup100k"
        ]),
        @"prepareStageSummary" : MTBenchmarkStageSummary(samples),
    };
}

static NSDictionary *MTBenchmarkEnvironment(NSString *profile,
                                            NSUInteger repetitions) {
    struct utsname systemInfo = {0};
    NSString *architecture = @"unknown";
    if (uname(&systemInfo) == 0) {
        architecture = [NSString stringWithUTF8String:systemInfo.machine]
            ?: @"unknown";
    }
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    NSDictionary<NSString *, NSString *> *environment =
        processInfo.environment;
    NSString *sourceRevision =
        environment[@"MARKTHEME_BENCHMARK_SOURCE_REVISION"] ?: @"unknown";
    NSString *treeState =
        environment[@"MARKTHEME_BENCHMARK_TREE_STATE"] ?: @"unknown";
    NSString *interpretation = repetitions < 20
        ? @"exploratory; not a release threshold"
        : @"distribution sample; still host-only";
    return @{
        @"evidenceClass" : @"HostBenchmark",
        @"hostTestingCoordinatorBypass" : @YES,
        @"buildConfiguration" : @"optimized-host",
        @"profile" : profile,
        @"repetitionsPerCase" : @(repetitions),
        @"interpretation" : interpretation,
        @"sourceRevision" : sourceRevision,
        @"sourceTreeState" : treeState,
        @"architecture" : architecture,
        @"operatingSystem" : processInfo.operatingSystemVersionString,
        @"activeProcessorCount" : @(processInfo.activeProcessorCount),
        @"physicalMemoryBytes" : @(processInfo.physicalMemory),
        @"wallClock" : @"CLOCK_MONOTONIC_RAW",
        @"cpuClock" : @"CLOCK_PROCESS_CPUTIME_ID",
        @"footprintMetric" : @"TASK_VM_INFO.phys_footprint",
        @"footprintSampleIntervalMicroseconds" :
            @(MTBenchmarkFootprintIntervalMicroseconds),
    };
}

static BOOL MTBenchmarkProfileConfiguration(
    NSString *profile,
    NSArray<NSNumber *> **pixelDimensions,
    NSArray<NSNumber *> **iconCounts) {
    if ([profile isEqualToString:@"smoke"]) {
        *pixelDimensions = @[@180];
        *iconCounts = @[@10];
        return YES;
    }
    if ([profile isEqualToString:@"standard"]) {
        *pixelDimensions = @[@180, @512, @1024];
        *iconCounts = @[@50, @500];
        return YES;
    }
    if ([profile isEqualToString:@"full"]) {
        *pixelDimensions = @[@180, @512, @1024, @4096];
        *iconCounts = @[@50, @500, @2000];
        return YES;
    }
    return NO;
}

static NSDictionary *_Nullable MTBenchmarkRun(NSString *profile,
                                               NSUInteger repetitions,
                                               NSError **error) {
    NSArray<NSNumber *> *pixelDimensions = nil;
    NSArray<NSNumber *> *iconCounts = nil;
    if (!MTBenchmarkProfileConfiguration(profile, &pixelDimensions,
                                         &iconCounts)) {
        MTBenchmarkSetError(error, MTBenchmarkErrorInvalidArguments,
            @"Unknown benchmark profile.", nil);
        return nil;
    }

    NSError *runError = nil;
    NSURL *benchmarkRoot = MTBenchmarkCreateTemporaryRoot(&runError);
    if (benchmarkRoot == nil) {
        if (error != NULL) *error = runError;
        return nil;
    }

    NSMutableArray<NSDictionary *> *cases = [NSMutableArray array];
    NSDictionary *result = nil;
    do {
        BOOL failed = NO;
        for (NSNumber *dimensionValue in pixelDimensions) {
            NSDictionary *pixelCase = MTBenchmarkPixelCase(
                dimensionValue.unsignedIntValue, repetitions,
                benchmarkRoot, &runError);
            if (pixelCase == nil) {
                failed = YES;
                break;
            }
            [cases addObject:pixelCase];
        }
        if (failed) break;

        NSDictionary *zeroGenerationCase = MTBenchmarkZeroGenerationCase(
            repetitions, benchmarkRoot, &runError);
        if (zeroGenerationCase == nil) break;
        [cases addObject:zeroGenerationCase];

        for (NSNumber *countValue in iconCounts) {
            NSUInteger iconCount = countValue.unsignedIntegerValue;
            NSURL *corpusRoot = [benchmarkRoot
                URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"corpus-%04lu",
                        (unsigned long)iconCount]
                isDirectory:YES];
            if (!MTBenchmarkCreateDirectory(corpusRoot, &runError)) {
                failed = YES;
                break;
            }
            __block MTSyntheticCorpus *corpus = nil;
            NSDictionary *fixtureMeasurement = MTBenchmarkMeasureOperation(
                ^BOOL(NSError **measureError) {
                    corpus = MTSyntheticCorpusCreate(
                        corpusRoot, iconCount, 180, measureError);
                    return corpus != nil;
                }, &runError);
            if (fixtureMeasurement == nil || corpus == nil) {
                failed = YES;
                break;
            }

            NSDictionary *directoryCase = MTBenchmarkImportCase(
                corpus, @"directory", repetitions, benchmarkRoot, &runError);
            NSDictionary *archiveCase = directoryCase == nil ? nil
                : MTBenchmarkImportCase(
                    corpus, @"zip", repetitions, benchmarkRoot, &runError);
            if (directoryCase == nil || archiveCase == nil) {
                failed = YES;
                break;
            }
            if (![directoryCase[@"manifestDigest"]
                    isEqualToString:archiveCase[@"manifestDigest"]] ||
                ![directoryCase[@"sourceFingerprint"]
                    isEqualToString:archiveCase[@"sourceFingerprint"]] ||
                ![directoryCase[@"generationIdentifier"]
                    isEqualToString:archiveCase[@"generationIdentifier"]]) {
                MTBenchmarkSetError(&runError, MTBenchmarkErrorInvariant,
                    @"Directory and ZIP imports produced different canonical identities.",
                    nil);
                failed = YES;
                break;
            }
            NSMutableDictionary *directoryOutput =
                [directoryCase mutableCopy];
            NSMutableDictionary *archiveOutput = [archiveCase mutableCopy];
            directoryOutput[@"sharedFixtureGeneration"] =
                fixtureMeasurement;
            archiveOutput[@"sharedFixtureGeneration"] =
                fixtureMeasurement;
            [cases addObject:[directoryOutput copy]];
            [cases addObject:[archiveOutput copy]];
        }
        if (failed) break;

        result = @{
            @"schemaVersion" : @2,
            @"environment" :
                MTBenchmarkEnvironment(profile, repetitions),
            @"cases" : cases,
        };
    } while (NO);

    NSError *cleanupError = nil;
    if (!MTBenchmarkRemoveTemporaryNode(benchmarkRoot, &cleanupError) &&
        runError == nil) {
        runError = cleanupError;
        result = nil;
    }
    if (result == nil && error != NULL) {
        *error = runError ?: [NSError
            errorWithDomain:MTBenchmarkErrorDomain
                       code:MTBenchmarkErrorOperation
                   userInfo:@{
            NSLocalizedDescriptionKey : @"Benchmark execution failed.",
        }];
    }
    return result;
}

static void MTBenchmarkPrintUsage(const char *programName) {
    fprintf(stderr,
        "Usage: %s [--profile smoke|standard|full] "
        "[--repetitions 1..100] [--output PATH]\n",
        programName);
}

static BOOL MTBenchmarkParseUnsigned(NSString *value,
                                     NSUInteger *result) {
    if (value.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    unsigned long long parsed = 0;
    if (![scanner scanUnsignedLongLong:&parsed] ||
        !scanner.isAtEnd || parsed == 0 || parsed > 100) {
        return NO;
    }
    *result = (NSUInteger)parsed;
    return YES;
}

static void MTBenchmarkPrintError(NSError *error) {
    fprintf(stderr, "FAIL: %s\n",
            error.localizedDescription.UTF8String ?: "unknown error");
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    NSUInteger depth = 0;
    while (underlying != nil && depth < 8) {
        fprintf(stderr, "  caused by: %s (%s:%ld)\n",
            underlying.localizedDescription.UTF8String ?: "unknown error",
            underlying.domain.UTF8String ?: "unknown",
            (long)underlying.code);
        underlying = underlying.userInfo[NSUnderlyingErrorKey];
        depth++;
    }
}

static BOOL MTBenchmarkWriteOutput(NSData *data,
                                   NSString *outputPath,
                                   NSError **error) {
    NSURL *requestedURL = [NSURL fileURLWithPath:outputPath].standardizedURL;
    NSURL *parentURL =
        requestedURL.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
    NSURL *finalURL = [parentURL
        URLByAppendingPathComponent:requestedURL.lastPathComponent];
    if (finalURL.lastPathComponent.length == 0 ||
        ![NSFileManager.defaultManager
            fileExistsAtPath:parentURL.path]) {
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"The benchmark output parent directory does not exist.", nil);
    }
    NSString *partialName = [NSString stringWithFormat:@".%@.%@.partial",
        finalURL.lastPathComponent, NSUUID.UUID.UUIDString];
    NSURL *partialURL = [parentURL URLByAppendingPathComponent:partialName];
    NSError *operationError = nil;
    if (![data writeToURL:partialURL
                  options:NSDataWritingWithoutOverwriting
                    error:&operationError] ||
        chmod(partialURL.fileSystemRepresentation, 0600) != 0) {
        unlink(partialURL.fileSystemRepresentation);
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to write the private benchmark output staging file.",
            operationError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno userInfo:nil]);
    }
    int descriptor = open(partialURL.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0 || fsync(descriptor) != 0) {
        int savedError = errno;
        if (descriptor >= 0) close(descriptor);
        unlink(partialURL.fileSystemRepresentation);
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to synchronize the benchmark output staging file.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError userInfo:nil]);
    }
    close(descriptor);
    if (renameatx_np(AT_FDCWD, partialURL.fileSystemRepresentation,
                     AT_FDCWD, finalURL.fileSystemRepresentation,
                     RENAME_EXCL) != 0) {
        int savedError = errno;
        unlink(partialURL.fileSystemRepresentation);
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"Unable to publish the benchmark output without replacement.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError userInfo:nil]);
    }
    int parentDescriptor = open(parentURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parentDescriptor < 0) {
        int savedError = errno;
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            [NSString stringWithFormat:
                @"The benchmark output was published but its directory could not be opened: %@",
                parentURL.path],
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError userInfo:nil]);
    }
    if (fsync(parentDescriptor) != 0) {
        int savedError = errno;
        close(parentDescriptor);
        return MTBenchmarkSetError(error, MTBenchmarkErrorFilesystem,
            @"The benchmark output was published but its directory could not be synchronized.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError userInfo:nil]);
    }
    close(parentDescriptor);
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *profile = @"smoke";
        NSString *outputPath = nil;
        NSUInteger repetitions = 0;
        BOOL repetitionsWereProvided = NO;
        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--help"]) {
                MTBenchmarkPrintUsage(argv[0]);
                return 0;
            }
            if ([argument isEqualToString:@"--profile"] &&
                index + 1 < argc) {
                profile = [NSString stringWithUTF8String:argv[++index]];
                continue;
            }
            if ([argument isEqualToString:@"--repetitions"] &&
                index + 1 < argc) {
                NSString *value =
                    [NSString stringWithUTF8String:argv[++index]];
                if (!MTBenchmarkParseUnsigned(value, &repetitions)) {
                    fprintf(stderr,
                        "FAIL: --repetitions must be an integer from 1 to 100.\n");
                    MTBenchmarkPrintUsage(argv[0]);
                    return 64;
                }
                repetitionsWereProvided = YES;
                continue;
            }
            if ([argument isEqualToString:@"--output"] &&
                index + 1 < argc) {
                outputPath =
                    [NSString stringWithUTF8String:argv[++index]];
                continue;
            }
            fprintf(stderr, "FAIL: unknown or incomplete argument: %s\n",
                    argument.UTF8String);
            MTBenchmarkPrintUsage(argv[0]);
            return 64;
        }

        NSArray<NSNumber *> *unusedPixels = nil;
        NSArray<NSNumber *> *unusedCounts = nil;
        if (!MTBenchmarkProfileConfiguration(
                profile, &unusedPixels, &unusedCounts)) {
            fprintf(stderr,
                "FAIL: --profile must be smoke, standard, or full.\n");
            MTBenchmarkPrintUsage(argv[0]);
            return 64;
        }
        if (!repetitionsWereProvided) {
            repetitions = [profile isEqualToString:@"smoke"] ? 1 : 3;
        }
        if (outputPath != nil && outputPath.length == 0) {
            fprintf(stderr, "FAIL: --output cannot be empty.\n");
            return 64;
        }
        if (outputPath != nil) {
            struct stat outputStatus = {0};
            const char *outputFile =
                [NSURL fileURLWithPath:outputPath]
                    .standardizedURL.fileSystemRepresentation;
            if (lstat(outputFile, &outputStatus) == 0) {
                fprintf(stderr,
                    "FAIL: benchmark output already exists: %s\n",
                    outputFile);
                return 73;
            }
            if (errno != ENOENT) {
                fprintf(stderr,
                    "FAIL: benchmark output cannot be inspected: %s\n",
                    outputFile);
                return 73;
            }
        }

        NSError *error = nil;
        NSDictionary *benchmark =
            MTBenchmarkRun(profile, repetitions, &error);
        if (benchmark == nil) {
            MTBenchmarkPrintError(error);
            return 1;
        }
        NSData *json = [NSJSONSerialization
            dataWithJSONObject:benchmark
                       options:(NSJSONWritingPrettyPrinted |
                                NSJSONWritingSortedKeys)
                         error:&error];
        if (json == nil) {
            MTBenchmarkPrintError(error);
            return 1;
        }
        NSMutableData *output = [json mutableCopy];
        const uint8_t newline = '\n';
        [output appendBytes:&newline length:1];
        if (outputPath == nil) {
            if (fwrite(output.bytes, 1, output.length, stdout) !=
                output.length) {
                fprintf(stderr, "FAIL: unable to write benchmark JSON.\n");
                return 1;
            }
        } else {
            if (!MTBenchmarkWriteOutput(output, outputPath, &error)) {
                MTBenchmarkPrintError(error);
                return 1;
            }
            fprintf(stderr, "wrote benchmark: %s\n",
                    [NSURL fileURLWithPath:outputPath]
                        .standardizedURL.path.UTF8String);
        }
        return 0;
    }
}
