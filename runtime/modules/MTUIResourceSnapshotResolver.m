#import "MTUIResourceSnapshotResolver.h"

#import "MTGenerationReader.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"
#import "MTStaticIconConfiguration.h"

static NSArray<NSString *> *MTUIResourceCandidateNames(NSString *surface,
                                                       NSString *resourceName) {
    if (![surface isEqualToString:@"preferences.icon"]) {
        return @[resourceName];
    }
    // Preferences 21D61 selects these GraphicIcon types and PK cache keys in
    // opposite branches of the same system feature flag. They are verified
    // pairs, not names inferred from localized labels or suffix spelling.
    // See docs/ISSUE_7_PREFERENCES_GRAPHIC_ICONS.md for the binary evidence.
    static NSDictionary<NSString *, NSString *> *graphicIconNames;
    static NSDictionary<NSString *, NSString *> *legacyNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        graphicIconNames = @{
            @"airplane-mode" : @"AirplaneMode",
            @"wifi" : @"WiFi",
            @"ethernet" : @"Ethernet",
            @"bluetooth" : @"Bluetooth",
            @"cellular-settings" : @"CellularData",
            @"personal-hotspot" : @"PersonalHotspot",
            @"vpn" : @"VPN",
            @"notifications" : @"NotificationCenter",
            @"sound" : @"Sounds",
            @"focus" : @"DND",
            @"screen-time" : @"ScreenTime",
            @"gear" : @"General",
            @"control-center" : @"ControlCenter",
            @"home-screen" : @"HomeScreen",
            @"accessibility" : @"Accessibility",
            @"wallpaper" : @"Wallpaper",
            @"pencil" : @"Pencil",
            @"face-id" : @"FaceID",
            @"emergency-sos" : @"SOS",
            @"exposure-notifications" : @"ExposureNotification",
            @"touch-id" : @"TouchID",
            @"battery" : @"BatteryUsage",
            @"passcode" : @"Passcode",
            @"privacy" : @"Privacy",
            @"passwords" : @"KeychainSync",
            @"tv-provider" : @"VideoSubscriber",
            @"developer-tools" : @"DeveloperSettings",
            @"carrier-settings" : @"CarrierSettings",
            @"internal-settings" : @"_internal_icon",
            @"app-clips" : @"AppClips",
        };
        legacyNames = @{
            @"CarrierSettings" : @"Carrier",
            @"Wallet" : @"Passbook",
            @"Notes" : @"mobileNotes",
        };
    });
    NSMutableArray<NSString *> *names =
        [NSMutableArray arrayWithObject:resourceName];
    NSString *preferencesName = resourceName;
    NSString *graphicPrefix = @"com.apple.graphic-icon.";
    if ([resourceName hasPrefix:graphicPrefix]) {
        NSString *cacheName = graphicIconNames[
            [resourceName substringFromIndex:graphicPrefix.length]];
        if (cacheName != nil) {
            [names addObject:cacheName];
            preferencesName = cacheName;
        }
    }
    // Keep authored keys intact. Every exact-name scale/device variant wins
    // over a PK fallback, which in turn wins over a historical Settings name.
    NSString *legacyName = legacyNames[preferencesName];
    if (legacyName != nil) [names addObject:legacyName];
    return names;
}

@interface MTUIResourceSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTUIResourceSnapshotResolution

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _canonicalResourceKey = [canonicalResourceKey copy];
    _generation = generation;
    _resource = resource;
    return self;
}

@end

@interface MTUIResourceSnapshotResolver ()
@property(nonatomic, copy) MTUIResourceSnapshotProvider snapshotProvider;
@end

@implementation MTUIResourceSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTUIResourceSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (NSArray<NSDictionary<NSString *, id> *> *)sourceCandidatesForScale:
    (NSUInteger)scale deviceTrait:(NSString *)deviceTrait {
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    void (^append)(NSString *, NSUInteger, NSString *) =
        ^(NSString *variant, NSUInteger candidateScale, NSString *trait) {
            [candidates addObject:@{
                @"variant" : variant,
                @"scale" : @(candidateScale),
                @"trait" : trait,
            }];
        };
    append(MTStaticIconSourceVariantLarge, 0, @"any");
    NSMutableArray<NSNumber *> *scales = [NSMutableArray array];
    if (scale >= 1 && scale <= 3) [scales addObject:@(scale)];
    for (NSUInteger candidate = scale + 1; candidate <= 3; candidate++) {
        [scales addObject:@(candidate)];
    }
    if (scale > 1) {
        for (NSUInteger candidate = scale - 1; candidate >= 1; candidate--) {
            [scales addObject:@(candidate)];
            if (candidate == 1) break;
        }
    }
    if (scales.count == 0) [scales addObjectsFromArray:@[@3, @2, @1]];
    BOOL firstScale = YES;
    for (NSNumber *scaleNumber in scales) {
        NSUInteger candidateScale = scaleNumber.unsignedIntegerValue;
        append(MTStaticIconSourceVariantDeviceScale,
               candidateScale, deviceTrait);
        append(MTStaticIconSourceVariantScaleDevice,
               candidateScale, deviceTrait);
        append(MTStaticIconSourceVariantScale,
               candidateScale, @"any");
        if (firstScale) {
            append(MTStaticIconSourceVariantDevice, 0, deviceTrait);
            firstScale = NO;
        }
    }
    append(MTStaticIconSourceVariantPlain, 0, @"any");
    if (scale <= 3) {
        append(MTStaticIconSourceVariantPrimary, scale, deviceTrait);
        append(MTStaticIconSourceVariantPrimary, scale, @"any");
    }
    append(MTStaticIconSourceVariantPrimary, 0, deviceTrait);
    append(MTStaticIconSourceVariantPrimary, 0, @"any");
    return candidates;
}

- (NSArray<MTUIResourceSnapshotResolution *> *)
    resolutionsForSurface:(NSString *)surface
              resourceName:(NSString *)resourceName
                     scale:(NSUInteger)scale
               deviceTrait:(NSString *)deviceTrait
                     error:(NSError **)error {
    if (error != NULL) *error = nil;
    NSError *validationError = nil;
    MTResourceKey *validationKey = [[MTResourceKey alloc]
        initWithModuleID:@"ui.resources"
                 surface:surface
                 subject:resourceName
                 variant:MTStaticIconSourceVariantPrimary
                   scale:scale
                   trait:@"any"
                   error:&validationError];
    if (validationKey == nil) {
        if (error != NULL) *error = validationError;
        return nil;
    }
    if (!([deviceTrait isEqualToString:@"iphone"] ||
          [deviceTrait isEqualToString:@"ipad"])) {
        return nil;
    }
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    NSMutableArray<MTUIResourceSnapshotResolution *> *resolutions =
        [NSMutableArray array];
    NSMutableSet<NSString *> *visitedKeys = [NSMutableSet set];
    NSArray<NSDictionary<NSString *, id> *> *sourceCandidates =
        [self sourceCandidatesForScale:scale deviceTrait:deviceTrait];
    for (NSString *candidateName in
            MTUIResourceCandidateNames(surface, resourceName)) {
        for (NSDictionary<NSString *, id> *candidate in sourceCandidates) {
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:@"ui.resources"
                         surface:surface
                         subject:candidateName
                         variant:candidate[@"variant"]
                           scale:[candidate[@"scale"] unsignedIntegerValue]
                           trait:candidate[@"trait"]
                           error:&keyError];
            if (key == nil) {
                if (error != NULL) *error = keyError;
                return nil;
            }
            if ([visitedKeys containsObject:key.canonicalString]) continue;
            [visitedKeys addObject:key.canonicalString];
            NSError *lookupError = nil;
            MTGenerationResource *resource = [generation
                resourceForCanonicalResourceKey:key.canonicalString
                error:&lookupError];
            if (lookupError != nil) {
                if (error != NULL) *error = lookupError;
                return nil;
            }
            if (resource != nil) {
                [resolutions addObject:[[MTUIResourceSnapshotResolution alloc]
                    initWithGenerationIdentifier:generation.generationIdentifier
                    canonicalResourceKey:key.canonicalString
                    generation:generation
                    resource:resource]];
            }
        }
    }
    return resolutions.count == 0 ? nil : [resolutions copy];
}

- (MTUIResourceSnapshotResolution *)
    resolutionForPreferencesIconName:(NSString *)resourceName
                               scale:(NSUInteger)scale
                               error:(NSError **)error {
    return [self resolutionsForPreferencesIconName:resourceName
                                             scale:scale
                                       deviceTrait:@"iphone"
                                             error:error].firstObject;
}

- (MTUIResourceSnapshotResolution *)
    resolutionForShareActivityName:(NSString *)activityName
                              scale:(NSUInteger)scale
                              error:(NSError **)error {
    return [self resolutionsForShareActivityName:activityName
                                           scale:scale
                                     deviceTrait:@"iphone"
                                           error:error].firstObject;
}

- (NSArray<MTUIResourceSnapshotResolution *> *)
    resolutionsForPreferencesIconName:(NSString *)resourceName
                                 scale:(NSUInteger)scale
                           deviceTrait:(NSString *)deviceTrait
                                 error:(NSError **)error {
    return [self resolutionsForSurface:@"preferences.icon"
                          resourceName:resourceName
                                 scale:scale
                           deviceTrait:deviceTrait
                                 error:error];
}

- (NSArray<MTUIResourceSnapshotResolution *> *)
    resolutionsForShareActivityName:(NSString *)activityName
                               scale:(NSUInteger)scale
                         deviceTrait:(NSString *)deviceTrait
                               error:(NSError **)error {
    return [self resolutionsForSurface:@"share.activity"
                          resourceName:activityName
                                 scale:scale
                           deviceTrait:deviceTrait
                                 error:error];
}

@end
