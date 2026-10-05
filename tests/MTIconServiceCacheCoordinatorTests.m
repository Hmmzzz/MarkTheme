#import "MTIconServiceCacheCoordinatorTests.h"

#import "MTIconServiceCacheCoordinator.h"
#import "MTGenerationIndexCodec.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTRuntimeKernel.h"

static NSUInteger MTCacheCoordinatorAssertions;
static void MTCacheCheck(BOOL condition, NSString *message) {
    MTCacheCoordinatorAssertions++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// The Generation reader independently verifies published bytes. These small
// descriptor fixtures isolate fingerprint dependencies; the binary index and
// immutable Runtime snapshot used here are real production values.
@interface MTCacheTestDescriptor : NSObject
@property(nonatomic, copy) NSArray<NSString *> *moduleIDs;
@property(nonatomic, copy) NSDictionary *moduleConfigurations;
@property(nonatomic, copy) NSDictionary *contractVersions;
@property(nonatomic, assign) NSUInteger schemaVersion;
@property(nonatomic, assign) NSUInteger indexFormatVersion;
@end
@implementation MTCacheTestDescriptor
@end

@interface MTCacheTestGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTCacheTestDescriptor *descriptor;
@property(nonatomic, strong) MTGenerationIndex *index;
@end
@implementation MTCacheTestGeneration
@end

static MTGenerationIndexRecord *MTCacheRecord(NSString *module, NSString *surface,
    NSString *subject, NSString *variant, NSUInteger scale, NSString *trait,
    NSUInteger digest, NSUInteger bytes) {
    MTResourceKey *key = [[MTResourceKey alloc] initWithModuleID:module surface:surface
        subject:subject variant:variant scale:scale trait:trait error:NULL];
    MTGenerationIndexRecord *record = [[MTGenerationIndexRecord alloc]
        initWithCanonicalResourceKey:key.canonicalString
        contentSHA256:[NSString stringWithFormat:@"%064llx", (unsigned long long)digest]
        assetByteCount:bytes error:NULL];
    MTCacheCheck(record != nil, @"Fingerprint resource fixture must be canonical");
    return record;
}

static MTRuntimeSnapshot *MTCacheSnapshot(NSArray *modules, NSDictionary *configurations,
    NSArray<MTGenerationIndexRecord *> *records, NSUInteger identity, uint64_t sequence) {
    MTCacheTestDescriptor *descriptor = [[MTCacheTestDescriptor alloc] init];
    descriptor.moduleIDs = modules;
    descriptor.moduleConfigurations = configurations;
    descriptor.contractVersions = @{ @"resourceKey" : @1, @"moduleRegistry" : @1 };
    descriptor.schemaVersion = 1;
    descriptor.indexFormatVersion = MTGenerationIndexFormatVersion;
    MTCacheTestGeneration *generation = [[MTCacheTestGeneration alloc] init];
    generation.generationIdentifier = [NSString stringWithFormat:@"g1-%064llx", (unsigned long long)identity];
    generation.descriptor = descriptor;
    NSData *encoded = [MTGenerationIndex encodedDataWithRecords:records error:NULL];
    generation.index = [[MTGenerationIndex alloc] initWithEncodedData:encoded error:NULL];
    MTCacheCheck(generation.index != nil, @"Fingerprint fixture must use a validated Generation index");
    MTRuntimeState *state = [[MTRuntimeState alloc] initWithSequence:sequence runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier previousGenerationIdentifier:nil error:NULL];
    MTCacheCheck(state != nil, @"Fingerprint fixture must use a valid Runtime state");
    return [[MTRuntimeSnapshot alloc] initWithState:state generation:(id)generation];
}

static NSString *MTCacheFingerprint(MTRuntimeSnapshot *snapshot) {
    NSError *error = nil;
    NSString *value = MTIconServicePixelDependencyFingerprint(snapshot, &error);
    MTCacheCheck(value.length > 0 && error == nil, @"Valid pixel dependencies must produce a fingerprint");
    return value;
}

static void MTCacheRunFingerprintTests(void) {
    MTGenerationIndexRecord *icon = MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"primary", 2, @"iphone", 1, 64);
    MTGenerationIndexRecord *badge = MTCacheRecord(@"badges", @"springboard.badge", @"global", @"default", 0, @"any", 2, 32);
    NSDictionary *staticConfig = @{ @"bundleAliases" : @{ @"com.example.two" : @"com.example.one" }, @"fuzzyBundleIdentifiers" : @[] };
    NSArray *modules = @[@"icons.static", @"badges"];
    NSDictionary *configs = @{ @"icons.static" : staticConfig, @"badges" : @{ @"style" : @1 } };
    MTRuntimeSnapshot *original = MTCacheSnapshot(modules, configs, @[icon, badge], 1, 1);
    NSString *fingerprint = MTCacheFingerprint(original);
    MTCacheCheck([fingerprint isEqualToString:MTCacheFingerprint(MTCacheSnapshot(modules, configs, @[badge, icon], 2, 9))],
        @"Generation identity, sequence, and index input order cannot invalidate equal pixels");
    MTGenerationIndexRecord *differentBadge = MTCacheRecord(@"badges", @"springboard.badge", @"global", @"default", 0, @"any", 3, 33);
    MTCacheCheck([fingerprint isEqualToString:MTCacheFingerprint(MTCacheSnapshot(modules,
        @{ @"icons.static" : staticConfig, @"badges" : @{ @"style" : @2 } }, @[icon, differentBadge], 3, 10))],
        @"Badge-only resource and configuration edits must retain App icon caches");
    for (NSString *unrelated in @[@"ui.statusbar", @"ui.dialer", @"folders", @"icons.shadow"]) {
        MTGenerationIndexRecord *record = MTCacheRecord(unrelated, @"unrelated.surface", @"global", @"default", 0, @"any", 40, 40);
        MTCacheCheck([fingerprint isEqualToString:MTCacheFingerprint(MTCacheSnapshot(
            [modules arrayByAddingObject:unrelated], configs, @[icon, badge, record], 4, 11))],
            @"Adding a display-only module must retain persistent App icon caches");
    }
    NSArray *changedIcons = @[
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"primary", 2, @"iphone", 9, 64),
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"primary", 2, @"iphone", 1, 65),
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.two", @"primary", 2, @"iphone", 1, 64),
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"source-large", 2, @"iphone", 1, 64),
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"primary", 3, @"iphone", 1, 64),
        MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.one", @"primary", 2, @"any", 1, 64),
        MTCacheRecord(@"icons.static", @"another.surface", @"com.example.one", @"primary", 2, @"iphone", 1, 64),
    ];
    for (MTGenerationIndexRecord *changed in changedIcons) {
        MTCacheCheck(![fingerprint isEqualToString:MTCacheFingerprint(MTCacheSnapshot(modules, configs, @[changed, badge], 5, 12))],
            @"Every key component, content digest, and admitted asset length participates in pixel identity");
    }
    MTCacheCheck(![fingerprint isEqualToString:MTCacheFingerprint(MTCacheSnapshot(modules,
        @{ @"icons.static" : @{ @"bundleAliases" : @{ @"com.example.two" : @"com.example.three" }, @"fuzzyBundleIdentifiers" : @[] } }, @[icon, badge], 6, 13))],
        @"Source matching configuration must invalidate even when asset bytes are unchanged");
    NSDictionary *secondLayer = @{ @"bundleAliases" : @{}, @"fuzzyBundleIdentifiers" : @[@"com.example"] };
    NSString *firstLayerWins = MTCacheFingerprint(MTCacheSnapshot(modules,
        @{ @"icons.static" : @{ @"matchingLayers" : @[staticConfig, secondLayer] } }, @[icon, badge], 61, 61));
    NSString *secondLayerWins = MTCacheFingerprint(MTCacheSnapshot(modules,
        @{ @"icons.static" : @{ @"matchingLayers" : @[secondLayer, staticConfig] } }, @[icon, badge], 62, 62));
    MTCacheCheck(![firstLayerWins isEqualToString:secondLayerWins],
        @"Reordering matching layers changes which source wins and must invalidate");
    // StaticIconSnapshotResolver queries the index directly even when a
    // producer omitted icons.static from descriptor.moduleIDs. Conservative
    // identity must therefore retain these bytes and their matching hints.
    NSString *unlistedStatic = MTCacheFingerprint(MTCacheSnapshot(@[@"badges"], configs, @[icon, badge], 63, 63));
    MTCacheCheck(![unlistedStatic isEqualToString:MTCacheFingerprint(MTCacheSnapshot(@[@"badges"], configs,
        @[changedIcons.firstObject, badge], 64, 64))],
        @"Indexed static pixels remain dependencies when the static module ID is absent");
    MTCacheCheck(![unlistedStatic isEqualToString:MTCacheFingerprint(MTCacheSnapshot(@[@"badges"], @{},
        @[icon, badge], 65, 65))],
        @"Unlisted static matching configuration remains a resolver dependency");
    for (NSString *dependency in @[@"icons.mask", @"icons.overlay", @"icons.calendar", @"icons.clock"]) {
        NSArray *expandedModules = [modules arrayByAddingObject:dependency];
        NSString *enabled = MTCacheFingerprint(MTCacheSnapshot(expandedModules, configs, @[icon, badge], 7, 14));
        MTCacheCheck(![enabled isEqualToString:fingerprint],
            @"Decoration and dynamic category module presence must participate in pixel identity");
        MTGenerationIndexRecord *artwork = MTCacheRecord(dependency, @"springboard.icon", @"global", @"default", 0, @"any", 21, 64);
        NSString *withArtwork = MTCacheFingerprint(MTCacheSnapshot(expandedModules, configs, @[icon, badge, artwork], 8, 15));
        MTCacheCheck(![enabled isEqualToString:withArtwork], @"Decoration and dynamic resources must affect the conservative fingerprint");
        NSMutableDictionary *changedConfigs = [configs mutableCopy];
        changedConfigs[dependency] = @{ @"mode" : @2 };
        MTCacheCheck(![withArtwork isEqualToString:MTCacheFingerprint(MTCacheSnapshot(expandedModules, changedConfigs, @[icon, badge, artwork], 9, 16))],
            @"Decoration configuration cannot be omitted from pixel identity");
    }
    MTCacheTestGeneration *generation = (id)original.generation;
    generation.descriptor.contractVersions = @{ @"resourceKey" : @2, @"moduleRegistry" : @1 };
    MTCacheCheck(![fingerprint isEqualToString:MTCacheFingerprint(original)], @"Contract changes must invalidate pixel identity");
    generation.index = nil;
    MTCacheCheck(MTIconServicePixelDependencyFingerprint(original, NULL) == nil,
        @"An unavailable admitted index must request conservative full invalidation");
    NSString *stock = MTCacheFingerprint(MTRuntimeSnapshot.stockSnapshot);
    MTCacheCheck(![stock isEqualToString:fingerprint], @"Disabling a themed source must invalidate to stock");
    MTRuntimeState *disabled = [[MTRuntimeState alloc] initWithSequence:99 runtimeEnabled:NO
        activeGenerationIdentifier:nil previousGenerationIdentifier:nil error:NULL];
    MTCacheCheck([stock isEqualToString:MTCacheFingerprint([[MTRuntimeSnapshot alloc] initWithState:disabled generation:nil])],
        @"Repeated stock states share pixels independently of sequence");
}

@interface MTCacheCoordinatorHarness : NSObject
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSMutableArray *completions;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *acknowledgements;
@property(nonatomic, strong) MTIconServiceCacheCoordinator *coordinator;
@property(nonatomic, assign) NSUInteger activeOperations;
@property(nonatomic, assign) NSUInteger maximumActiveOperations;
- (BOOL)waitForStarts:(NSUInteger)starts acknowledgements:(NSUInteger)acknowledgements;
- (void)completeOperationAtIndex:(NSUInteger)index verified:(BOOL)verified;
- (NSArray<NSDictionary *> *)acknowledgementSnapshot;
@end

@implementation MTCacheCoordinatorHarness
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _condition = [[NSCondition alloc] init];
    _completions = [NSMutableArray array];
    _acknowledgements = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    _coordinator = [[MTIconServiceCacheCoordinator alloc] initWithInvalidation:^(void (^completion)(BOOL)) {
        typeof(self) owner = weakSelf;
        [owner.condition lock];
        [owner.completions addObject:[completion copy]];
        owner.activeOperations++;
        owner.maximumActiveOperations = MAX(owner.maximumActiveOperations, owner.activeOperations);
        [owner.condition broadcast];
        [owner.condition unlock];
    } acknowledgement:^(uint64_t sequence, BOOL verified, BOOL skipped) {
        typeof(self) owner = weakSelf;
        [owner.condition lock];
        [owner.acknowledgements addObject:@{ @"sequence" : @(sequence), @"verified" : @(verified), @"skipped" : @(skipped) }];
        [owner.condition broadcast];
        [owner.condition unlock];
    }];
    return self;
}
- (BOOL)waitForStarts:(NSUInteger)starts acknowledgements:(NSUInteger)acknowledgements {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    [self.condition lock];
    while (self.completions.count < starts || self.acknowledgements.count < acknowledgements) {
        if (![self.condition waitUntilDate:deadline]) break;
    }
    BOOL ready = self.completions.count >= starts && self.acknowledgements.count >= acknowledgements;
    [self.condition unlock];
    return ready;
}
- (void)completeOperationAtIndex:(NSUInteger)index verified:(BOOL)verified {
    [self.condition lock];
    void (^completion)(BOOL) = self.completions[index];
    if (self.activeOperations > 0) self.activeOperations--;
    [self.condition unlock];
    completion(verified);
}
- (NSArray<NSDictionary *> *)acknowledgementSnapshot {
    [self.condition lock];
    NSArray *result = [self.acknowledgements copy];
    [self.condition unlock];
    return result;
}
@end

@interface MTCacheTestSnapshotLoader : NSObject <MTRuntimeSnapshotLoading>
@property(atomic, strong) MTRuntimeSnapshot *snapshot;
@end
@implementation MTCacheTestSnapshotLoader
- (MTRuntimeSnapshot *)loadSnapshotWithError:(NSError **)error {
    if (error != NULL) *error = nil;
    return self.snapshot;
}
@end

static void MTCacheRunKernelInterleavingTests(void) {
    MTGenerationIndexRecord *iconA = MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.app", @"primary", 2, @"iphone", 100, 64);
    MTGenerationIndexRecord *iconB = MTCacheRecord(@"icons.static", @"springboard.home", @"com.example.app", @"primary", 2, @"iphone", 101, 64);
    MTRuntimeSnapshot *snapshotA = MTCacheSnapshot(@[@"icons.static"], @{}, @[iconA], 100, 100);
    MTRuntimeSnapshot *snapshotB = MTCacheSnapshot(@[@"icons.static"], @{}, @[iconB], 101, 101);
    MTRuntimeSnapshot *snapshotReturningA = MTCacheSnapshot(@[@"icons.static"], @{}, @[iconA], 100, 102);
    MTCacheTestSnapshotLoader *loader = [[MTCacheTestSnapshotLoader alloc] init];
    loader.snapshot = snapshotA;
    MTCacheCoordinatorHarness *harness = [[MTCacheCoordinatorHarness alloc] init];
    dispatch_semaphore_t accepted = dispatch_semaphore_create(0);
    MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc] initWithLoader:loader notificationName:nil
        reloadHandler:^(MTRuntimeReloadDisposition disposition, MTRuntimeSnapshot *snapshot, __unused NSError *error) {
            if (disposition != MTRuntimeReloadDispositionRetainedAfterFailure) {
                [harness.coordinator acceptFingerprint:MTIconServicePixelDependencyFingerprint(snapshot, NULL)
                    sequence:snapshot.state.sequence];
            }
            dispatch_semaphore_signal(accepted);
        }];
    MTCacheCheck([kernel startSynchronouslyWithError:NULL], @"Interleaving fixture must publish its initial immutable snapshot");
    MTCacheCheck(dispatch_semaphore_wait(accepted, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
        @"Initial Kernel callback must enqueue pixel dependencies");
    MTCacheCheck([harness waitForStarts:1 acknowledgements:0], @"Initial A native operation starts");
    loader.snapshot = snapshotB;
    [kernel requestReload];
    MTCacheCheck(dispatch_semaphore_wait(accepted, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 &&
        kernel.currentSnapshot == snapshotB, @"Kernel may publish B while the A native clear is outstanding");
    loader.snapshot = snapshotReturningA;
    [kernel requestReload];
    MTCacheCheck(dispatch_semaphore_wait(accepted, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 &&
        kernel.currentSnapshot == snapshotReturningA, @"Kernel may publish returning A before either native clear completes");
    [harness completeOperationAtIndex:0 verified:YES];
    MTCacheCheck([harness waitForStarts:2 acknowledgements:1] &&
        [harness.acknowledgementSnapshot[0][@"sequence"] isEqual:@100],
        @"An old clear acknowledges only its captured sequence while the pending B clear starts");
    [harness completeOperationAtIndex:1 verified:NO];
    MTCacheCheck([harness waitForStarts:3 acknowledgements:2],
        @"With current A already published, failure of pending B still forces the final A clear");
    [harness completeOperationAtIndex:2 verified:YES];
    MTCacheCheck([harness waitForStarts:3 acknowledgements:3] &&
        [harness.acknowledgementSnapshot[2][@"sequence"] isEqual:@102] &&
        ![harness.acknowledgementSnapshot[2][@"skipped"] boolValue],
        @"The latest Kernel state receives a distinct, verified cache barrier after intervening failure");
    [kernel stop];
}

static void MTCacheRunTransactionTests(void) {
    MTCacheCoordinatorHarness *harness = [[MTCacheCoordinatorHarness alloc] init];
    [harness.coordinator acceptFingerprint:@"A" sequence:2];
    [harness.coordinator acceptFingerprint:@"A" sequence:1];
    [harness.coordinator acceptFingerprint:@"A" sequence:1];
    [harness.coordinator acceptFingerprint:@"B" sequence:3];
    MTCacheCheck([harness waitForStarts:1 acknowledgements:0], @"First dependency requires a native clear, including after process start");
    MTCacheCheck(harness.acknowledgementSnapshot.count == 0, @"No sequence may be acknowledged before its native completion");
    [harness completeOperationAtIndex:0 verified:YES];
    MTCacheCheck([harness waitForStarts:2 acknowledgements:2], @"Adjacent equal states must share one clear before the next different state starts");
    NSArray *acks = harness.acknowledgementSnapshot;
    MTCacheCheck([acks[0][@"sequence"] isEqual:@1] && [acks[1][@"sequence"] isEqual:@2],
        @"Coalesced acknowledgements are unique and ordered by sequence");
    MTCacheCheck(harness.maximumActiveOperations == 1, @"Native whole-store operations must never overlap");
    [harness completeOperationAtIndex:1 verified:YES];
    MTCacheCheck([harness waitForStarts:2 acknowledgements:3], @"A different fingerprint receives its own completion");
    [harness.coordinator acceptFingerprint:@"B" sequence:4];
    MTCacheCheck([harness waitForStarts:2 acknowledgements:4], @"An already-completed equal dependency acknowledges without another native clear");
    MTCacheCheck([harness.acknowledgementSnapshot[3][@"skipped"] boolValue], @"Equal completed pixels must take the skip path");
    // An erroneous callback repeated after a newer request is complete cannot
    // poison the latest completed dependency or issue a duplicate ack.
    [harness completeOperationAtIndex:0 verified:NO];
    [harness.coordinator acceptFingerprint:@"B" sequence:5];
    MTCacheCheck([harness waitForStarts:2 acknowledgements:5], @"Duplicate old callback cannot change the newest completed dependency");
    MTCacheCheck(harness.acknowledgementSnapshot.count == 5 &&
        [harness.acknowledgementSnapshot[4][@"sequence"] isEqual:@5] &&
        [harness.acknowledgementSnapshot[4][@"skipped"] boolValue],
        @"Duplicate completion must neither acknowledge twice nor invalidate a later successful state");

    MTCacheCoordinatorHarness *failure = [[MTCacheCoordinatorHarness alloc] init];
    [failure.coordinator acceptFingerprint:@"A" sequence:10];
    MTCacheCheck([failure waitForStarts:1 acknowledgements:0], @"Failure fixture A starts");
    [failure completeOperationAtIndex:0 verified:YES];
    MTCacheCheck([failure waitForStarts:1 acknowledgements:1], @"Failure fixture A completes");
    [failure.coordinator acceptFingerprint:@"B" sequence:11];
    MTCacheCheck([failure waitForStarts:2 acknowledgements:1], @"Changed pixels start the B operation");
    [failure completeOperationAtIndex:1 verified:NO];
    MTCacheCheck([failure waitForStarts:2 acknowledgements:2], @"Failed native clears deliver a failure outcome");
    MTCacheCheck(![failure.acknowledgementSnapshot[1][@"verified"] boolValue], @"Failure must not be acknowledged as a completed pixel state");
    [failure.coordinator acceptFingerprint:@"A" sequence:12];
    MTCacheCheck([failure waitForStarts:3 acknowledgements:2], @"A successful A followed by failed B must clear again on returning to A");
    [failure completeOperationAtIndex:2 verified:YES];
    MTCacheCheck([failure waitForStarts:3 acknowledgements:3] &&
        ![failure.acknowledgementSnapshot[2][@"skipped"] boolValue], @"Rollback after failure must be a newly verified clear");

    MTCacheCoordinatorHarness *interleaved = [[MTCacheCoordinatorHarness alloc] init];
    // Kernel publishes each immutable snapshot before accepting its request.
    // The latest source may therefore be A again while the original A clear
    // is still running. It must not absorb the intervening B transition.
    [interleaved.coordinator acceptFingerprint:@"A" sequence:20];
    [interleaved.coordinator acceptFingerprint:@"B" sequence:21];
    [interleaved.coordinator acceptFingerprint:@"A" sequence:22];
    [interleaved.coordinator acceptFingerprint:@"A" sequence:23];
    MTCacheCheck([interleaved waitForStarts:1 acknowledgements:0], @"Interleaved A/B/A begins with one operation");
    [interleaved completeOperationAtIndex:0 verified:YES];
    MTCacheCheck([interleaved waitForStarts:2 acknowledgements:1], @"Current A cannot bypass the pending B transaction");
    [interleaved completeOperationAtIndex:1 verified:YES];
    MTCacheCheck([interleaved waitForStarts:3 acknowledgements:2], @"A/B/A requires a final A clear after B completes");
    [interleaved completeOperationAtIndex:2 verified:YES];
    MTCacheCheck([interleaved waitForStarts:3 acknowledgements:4], @"Only adjacent final A requests share the final operation");
    acks = interleaved.acknowledgementSnapshot;
    MTCacheCheck([acks valueForKey:@"sequence"] != nil &&
        [[acks valueForKey:@"sequence"] isEqualToArray:@[@20, @21, @22, @23]] &&
        interleaved.maximumActiveOperations == 1,
        @"Cross-Generation transitions must remain serial and acknowledge only their own completed requests");
}

NSUInteger MTRunIconServiceCacheCoordinatorTests(void) {
    MTCacheCoordinatorAssertions = 0;
    MTCacheRunFingerprintTests();
    MTCacheRunTransactionTests();
    MTCacheRunKernelInterleavingTests();
    return MTCacheCoordinatorAssertions;
}
