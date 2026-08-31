#import "MTIconServiceRuntimeTests.h"

#import "MTIconServiceABI.h"
#import "MTIconServiceImageResolver.h"
#import "MTIconServiceProvenCanary.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

static NSUInteger MTIconServiceAssertionCount;

static void MTIconServiceAssert(BOOL condition, NSString *message) {
    MTIconServiceAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTTestIconServiceDescriptor : NSObject
@property(nonatomic, copy) NSArray<NSString *> *moduleIDs;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@end
@implementation MTTestIconServiceDescriptor
@end

@interface MTTestIconServiceGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) id descriptor;
@property(nonatomic, assign) NSUInteger lookupCount;
@property(nonatomic, copy) NSDictionary<NSString *, id> *resources;
@property(nonatomic, strong) NSMutableArray<NSString *> *requestedKeys;
// Runs on the first resource lookup, letting a test interleave a Generation
// swap in the exact window between capturing the snapshot and storing a
// composite decision.
@property(nonatomic, copy, nullable) void (^duringFirstLookup)(void);
@end

@implementation MTTestIconServiceGeneration

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _requestedKeys = [NSMutableArray array];
    return self;
}

- (id)resourceForCanonicalResourceKey:(NSString *)key error:(NSError **)error {
    self.lookupCount++;
    [self.requestedKeys addObject:key];
    if (error != NULL) *error = nil;
    void (^interleaved)(void) = self.duringFirstLookup;
    if (interleaved != nil) {
        self.duringFirstLookup = nil;
        interleaved();
    }
    return self.resources[key];
}

@end

static CGImageRef MTIconServiceTestCreateStockImage(uint32_t dimension) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) return NULL;
    CGContextRef context = CGBitmapContextCreate(
        NULL, dimension, dimension, 8, (size_t)dimension * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return NULL;
    CGContextSetRGBFillColor(context, 0.2, 0.4, 0.6, 1);
    CGContextFillRect(context, CGRectMake(0, 0, dimension, dimension));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

// An unthemed application must resolve to the stock appearance exactly once.
// Repeating the identical request may not re-enter the Generation resolver,
// and advancing the source fingerprint must invalidate that decision.
static void MTIconServiceRunStockCacheTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[];
    descriptor.moduleConfigurations = @{};

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    generation.descriptor = descriptor;

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Icon service stock cache fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    MTIconServiceAssert(resolver != nil,
        @"The icon service resolver must construct for a ready snapshot");

    NSString *fingerprint = [@"mtfs1-" stringByPaddingToLength:70
        withString:@"0" startingAtIndex:0];
    MTIconServiceAssert([resolver updateSourceFingerprint:fingerprint],
        @"A canonical source fingerprint must be accepted");

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef first = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(first == NULL && error == nil,
        @"An unthemed application must be a clean stock miss");
    NSUInteger lookupsAfterFirst = generation.lookupCount;
    MTIconServiceAssert(lookupsAfterFirst > 0,
        @"The first stock miss must consult the Generation resolver");

    error = nil;
    CGImageRef second = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(second == NULL && error == nil,
        @"A cached stock decision must still return the stock appearance");
    MTIconServiceAssert(generation.lookupCount == lookupsAfterFirst,
        @"A repeated unthemed request must not re-enter the Generation resolver");

    // A different stock digest is a different request and must be resolved.
    error = nil;
    CGImageRef changed = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-b" stockCGImage:stock error:&error];
    MTIconServiceAssert(changed == NULL && error == nil,
        @"A new stock digest must still resolve to the stock appearance");
    MTIconServiceAssert(generation.lookupCount > lookupsAfterFirst,
        @"A distinct stock digest must not reuse another request's decision");

    // Advancing the fingerprint must purge proven stock decisions so a newly
    // applied theme is never masked by a cached miss.
    NSString *nextFingerprint = [@"mtfs1-" stringByPaddingToLength:70
        withString:@"1" startingAtIndex:0];
    MTIconServiceAssert([resolver updateSourceFingerprint:nextFingerprint],
        @"A second canonical source fingerprint must be accepted");
    NSUInteger lookupsBeforePurgedRequest = generation.lookupCount;
    error = nil;
    CGImageRef afterPurge = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(afterPurge == NULL && error == nil,
        @"A purged stock decision must resolve cleanly again");
    MTIconServiceAssert(
        generation.lookupCount > lookupsBeforePurgedRequest,
        @"A new source fingerprint must invalidate cached stock decisions");

    CGImageRelease(stock);
}

// An application with no static icon of its own must still be evaluated for
// the global mask and overlay. The stock decision may only be cached once
// those decorations have themselves been resolved and found absent, so a
// themed mask or overlay can never be short-circuited by a cached miss.
static void MTIconServiceRunDecorationWithoutStaticIconTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[ @"icons.mask", @"icons.overlay" ];
    descriptor.moduleConfigurations = @{
        @"icons.mask" : @{ @"enabled" : @YES },
    };

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    generation.descriptor = descriptor;
    generation.resources = @{};

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Decoration fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    NSString *fingerprint = [@"mtfs1-" stringByPaddingToLength:70
        withString:@"2" startingAtIndex:0];
    MTIconServiceAssert(resolver != nil &&
        [resolver updateSourceFingerprint:fingerprint],
        @"The decoration resolver fixture must initialise");

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef result = [resolver
        copyReplacementForBundleIdentifier:@"com.example.nostatic"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(result == NULL && error == nil,
        @"An absent mask and overlay must still resolve to the stock appearance");

    // The decision may only be cached after the global mask and overlay were
    // actually probed. If either were skipped, an authored decoration would
    // silently stop applying to applications that ship no themed icon.
    BOOL probedMask = NO;
    BOOL probedOverlay = NO;
    for (NSString *requested in generation.requestedKeys) {
        if ([requested containsString:@"icons.mask"]) probedMask = YES;
        if ([requested containsString:@"icons.overlay"]) probedOverlay = YES;
    }
    MTIconServiceAssert(probedMask,
        @"An enabled icon mask must be resolved even without a themed static icon");
    MTIconServiceAssert(probedOverlay,
        @"An enabled icon overlay must be resolved even without a themed static icon");

    CGImageRelease(stock);
}

// A Generation swap that lands after this request captured its snapshot must
// not leave a decision keyed by the new fingerprint but composed from the old
// snapshot. Such an entry would otherwise be served until the following swap.
static void MTIconServiceRunGenerationSwapRaceTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[];
    descriptor.moduleConfigurations = @{};

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    generation.descriptor = descriptor;
    generation.resources = @{};

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Generation swap fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    NSString *first = [@"mtfs1-" stringByPaddingToLength:70
        withString:@"3" startingAtIndex:0];
    NSString *second = [@"mtfs1-" stringByPaddingToLength:70
        withString:@"4" startingAtIndex:0];

    // The swap must land in the exact window between capturing the snapshot
    // and reading the fingerprint. The snapshot provider is the only hook
    // inside that window, so the swap is driven from there.
    __block MTIconServiceImageResolver *raceResolver = nil;
    __block BOOL swapPending = NO;
    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            if (swapPending) {
                swapPending = NO;
                (void)[raceResolver updateSourceFingerprint:second];
            }
            return snapshot;
        }];
    raceResolver = resolver;
    MTIconServiceAssert(resolver != nil &&
        [resolver updateSourceFingerprint:first],
        @"The Generation swap fixture must initialise");
    swapPending = YES;

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef raced = [resolver
        copyReplacementForBundleIdentifier:@"com.example.raced"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(raced == NULL && error == nil,
        @"A raced request must still return its own correct result");

    // The next request runs entirely under the new generation. If the raced
    // request had published its decision, this lookup would be served from
    // that stale entry and never consult the Generation again.
    NSUInteger lookupsBefore = generation.lookupCount;
    error = nil;
    CGImageRef afterSwap = [resolver
        copyReplacementForBundleIdentifier:@"com.example.raced"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(afterSwap == NULL && error == nil,
        @"The post-swap request must resolve cleanly");
    MTIconServiceAssert(generation.lookupCount > lookupsBefore,
        @"A decision raced by a Generation swap must not be published");

    CGImageRelease(stock);
}

NSUInteger MTRunIconServiceRuntimeTests(void) {
    MTIconServiceAssertionCount = 0;
    MTIconServiceAssert(
        MTIconServiceConfiguredRuntimeMode() ==
            MTIconServiceRuntimeModeDisabled &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeDisabled)
            isEqualToString:@"disabled"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeObserve)
            isEqualToString:@"service-observe"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeSource)
            isEqualToString:@"service-source"],
        @"Host tests must use the fail-closed IconServices default while preserving stable rollout names");

    MTIconServiceImageGeometry proven = {
        .pixelSize = CGSizeMake(128, 128),
        .minimumSize = CGSizeMake(61, 61),
        .iconSize = CGSizeMake(64, 64),
        .scale = 2,
        .placeholder = NO,
        .largest = NO,
    };
    MTIconServiceAssert(MTIconServiceImageGeometryIsSupported(proven),
        @"The exact 21D61 IFCacheImage proof geometry must be accepted");
    MTIconServiceImageGeometry nonSquare = proven;
    nonSquare.pixelSize.height = 127;
    MTIconServiceImageGeometry placeholder = proven;
    placeholder.placeholder = YES;
    MTIconServiceImageGeometry mismatchedScale = proven;
    mismatchedScale.iconSize = CGSizeMake(63, 63);
    MTIconServiceAssert(
        !MTIconServiceImageGeometryIsSupported(nonSquare) &&
        !MTIconServiceImageGeometryIsSupported(placeholder) &&
        !MTIconServiceImageGeometryIsSupported(mismatchedScale),
        @"Unsupported IFImage geometry must fail closed before private construction");

    NSUUID *proofIconDigest = [[NSUUID alloc]
        initWithUUIDString:@"B68AA0B6-EFEA-3DCD-AF68-A034411947FD"];
    NSUUID *proofDescriptorDigest = [[NSUUID alloc]
        initWithUUIDString:@"0A08A069-61D7-3C2F-8274-AC0C2BA0651D"];
    MTIconServiceAssert(
        !MTIconServiceProvenCanaryIsEnabled() &&
        MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2) &&
        !MTIconServiceProvenCanaryAllowsRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2),
        @"The exact device-proof canary must match deterministically but remain disabled by default");
    MTIconServiceAssert(
        !MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.Preferences", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(60, 60), 2) &&
        !MTIconServiceProvenCanaryMatchesRequest(
            @"com.apple.MobileSafari", proofIconDigest,
            proofDescriptorDigest, CGSizeMake(61.25, 61.25), 2),
        @"The device-proof canary must reject every unproven bundle or descriptor geometry");

    MTIconServiceRunStockCacheTests();
    MTIconServiceRunDecorationWithoutStaticIconTests();
    MTIconServiceRunGenerationSwapRaceTests();

    return MTIconServiceAssertionCount;
}
