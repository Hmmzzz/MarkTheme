#import "MTUIResourceCompatibilityTests.h"

#import "MTDiagnostic.h"
#import "MTDigest.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTSourceInventory.h"
#import "MTStaticIconConfiguration.h"
#import "MTSyntheticCorpus.h"
#import "MTThemeManifest.h"
#import "MTUIResourcesImporter.h"
#import "modules/MTUIResourceSnapshotResolver.h"

static NSUInteger MTUIResourceCompatibilityAssertions;

static void MTUIResourceCompatibilityAssert(BOOL condition,
                                            NSString *message) {
    MTUIResourceCompatibilityAssertions++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// The resolver only reads Generation identity and canonical-key lookup. Keep
// imported resources as opaque payloads so tests exercise the real importer
// keys without coupling naming compatibility to Generation file encoding.
@interface MTUICompatibilityGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeResource *> *resources;
@end

@implementation MTUICompatibilityGeneration

- (id)resourceForCanonicalResourceKey:(NSString *)key
                                 error:(NSError **)error {
    if (error != NULL) *error = nil;
    return self.resources[key];
}

@end

static MTUIResourcesImportResult *MTUICompatibilityImport(
    NSArray<NSString *> *paths) {
    NSError *error = nil;
    NSData *png = MTSyntheticPNGData(87, 7, &error);
    MTUIResourceCompatibilityAssert(png.length >= 16 && error == nil,
        @"UI compatibility fixtures must generate their own PNG bytes");
    NSString *digest = MTSHA256HexDigestForData(png);
    NSMutableArray<MTSourceFile *> *files = [NSMutableArray array];
    for (NSString *path in paths) {
        [files addObject:[[MTSourceFile alloc]
            initWithRelativePath:path
            byteCount:png.length
            contentSHA256:digest
            prefixData:[png subdataWithRange:NSMakeRange(0, 16)]]];
    }
    MTSourceInventory *inventory = [MTSourceInventory
        inventoryWithFiles:files error:&error];
    MTUIResourceCompatibilityAssert(inventory != nil && error == nil,
        @"UI compatibility fixtures must form a valid audited inventory");
    MTUIResourcesImportResult *result = [[[MTUIResourcesImporter alloc] init]
        importSourceInventory:inventory error:&error];
    MTUIResourceCompatibilityAssert(result != nil && error == nil,
        @"UI compatibility fixtures must import without a fatal error");
    return result;
}

static MTThemeResource *MTUICompatibilityResourceAtPath(
    MTUIResourcesImportResult *result,
    NSString *path) {
    for (MTThemeResource *resource in result.resources) {
        if ([resource.relativeAssetPath isEqualToString:path]) return resource;
    }
    return nil;
}

static MTUIResourceSnapshotResolver *MTUICompatibilityResolver(
    NSArray<MTThemeResource *> *resources) {
    NSMutableDictionary<NSString *, MTThemeResource *> *byKey =
        [NSMutableDictionary dictionary];
    for (MTThemeResource *resource in resources) {
        byKey[resource.resourceKey.canonicalString] = resource;
    }
    MTUICompatibilityGeneration *generation =
        [[MTUICompatibilityGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    generation.resources = byKey;
    NSError *error = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&error];
    MTUIResourceCompatibilityAssert(state != nil && error == nil,
        @"UI compatibility fixtures must have a ready Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];
    return [[MTUIResourceSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
}

static void MTUICompatibilityTestMalformedNames(void) {
    NSArray<NSString *> *malformed = @[
        @"Bundles/com.apple.Preferences/WiFi@3x.png.png",
        @"Bundles/com.apple.preferences-framework/Bluetooth@2x.PNG.png",
        @"Bundles/com.apple.SharingUIService/UIAirDropActivity@3x.png.png",
        @"Bundles/com.apple.SharingUIService/UIMessageActivity@2x.PnG.png",
    ];
    NSString *generalPath =
        @"Bundles/com.apple.preferences-ui-framework/General@3x~iphone.png";
    NSString *airDropPath =
        @"Bundles/com.apple.SharingUIService/UIAirDropActivity@3x.png";
    NSMutableArray<NSString *> *paths = [malformed mutableCopy];
    [paths addObjectsFromArray:@[generalPath, airDropPath]];
    MTUIResourcesImportResult *result = MTUICompatibilityImport(paths);
    MTUIResourceCompatibilityAssert(result.recognizedFileCount == 2 &&
        result.rejectedFileCount == malformed.count &&
        result.resources.count == 2,
        @"Double PNG extensions must be rejected instead of reported as usable UI resources");

    NSMutableSet<NSString *> *diagnosedPaths = [NSMutableSet set];
    NSCountedSet<NSString *> *codes = [NSCountedSet set];
    for (MTDiagnostic *diagnostic in result.diagnostics) {
        [codes addObject:diagnostic.code];
        [diagnosedPaths addObject:diagnostic.details[@"path"]];
    }
    MTUIResourceCompatibilityAssert(result.diagnostics.count == 4 &&
        [codes countForObject:
            @"import.ui-resources.malformed-settings-filename"] == 2 &&
        [codes countForObject:
            @"import.ui-resources.malformed-share-filename"] == 2 &&
        [diagnosedPaths isEqualToSet:[NSSet setWithArray:malformed]],
        @"Malformed Settings and Share names must retain family-specific diagnostics and source paths");

    MTThemeResource *general = MTUICompatibilityResourceAtPath(result,
                                                               generalPath);
    MTUIResourceCompatibilityAssert(
        [general.resourceKey.subject isEqualToString:@"General"] &&
        [general.resourceKey.trait isEqualToString:@"iphone"] &&
        general.resourceKey.scale == 3 &&
        [general.resourceKey.variant
            isEqualToString:MTStaticIconSourceVariantScaleDevice],
        @"Valid SnowBoard @3x~iphone names must retain their subject, scale and device variant");
    MTUIResourceSnapshotResolver *resolver =
        MTUICompatibilityResolver(result.resources);
    NSError *error = nil;
    MTUIResourceSnapshotResolution *resolution = [resolver
        resolutionForPreferencesIconName:@"General" scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)general &&
        error == nil,
        @"A normal Settings image must remain reachable after malformed-name filtering");
    MTThemeResource *airDrop = MTUICompatibilityResourceAtPath(result,
                                                               airDropPath);
    resolution = [resolver resolutionForShareActivityName:@"UIAirDropActivity"
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)airDrop &&
        [airDrop.resourceKey.subject isEqualToString:@"UIAirDropActivity"] &&
        error == nil,
        @"AirDrop must retain the confirmed UIAirDropActivity identity through import and resolution");
}

static void MTUICompatibilityTestSettingsAliases(void) {
    NSArray<NSArray<NSString *> *> *aliases = @[
        @[@"CarrierSettings", @"Carrier"],
        @[@"Wallet", @"Passbook"],
        @[@"Notes", @"mobileNotes"],
    ];
    for (NSArray<NSString *> *pair in aliases) {
        NSString *currentName = pair[0];
        NSString *legacyName = pair[1];
        NSString *legacyPath = [NSString stringWithFormat:
            @"Bundles/com.apple.preferences/%@@3x~iphone.png", legacyName];
        NSString *exactScalePath = [NSString stringWithFormat:
            @"Bundles/com.apple.Preferences/%@@2x.png", currentName];
        NSString *exactPlainPath = [NSString stringWithFormat:
            @"Bundles/com.apple.Preferences/%@.png", currentName];
        MTUIResourcesImportResult *result = MTUICompatibilityImport(
            @[legacyPath, exactScalePath, exactPlainPath]);
        MTThemeResource *legacy = MTUICompatibilityResourceAtPath(result,
                                                                  legacyPath);
        MTThemeResource *exactScale = MTUICompatibilityResourceAtPath(result,
            exactScalePath);
        MTThemeResource *exactPlain = MTUICompatibilityResourceAtPath(result,
            exactPlainPath);
        MTUIResourceCompatibilityAssert(result.recognizedFileCount == 3 &&
            result.rejectedFileCount == 0 &&
            [legacy.resourceKey.subject isEqualToString:legacyName] &&
            [exactScale.resourceKey.subject isEqualToString:currentName] &&
            [exactPlain.resourceKey.subject isEqualToString:currentName],
            @"Legacy aliases must preserve authored import subjects and coexist with current names");

        MTUIResourceSnapshotResolver *resolver =
            MTUICompatibilityResolver(result.resources);
        NSError *error = nil;
        NSArray<MTUIResourceSnapshotResolution *> *resolutions = [resolver
            resolutionsForPreferencesIconName:currentName scale:3
            deviceTrait:@"iphone" error:&error];
        MTUIResourceCompatibilityAssert(resolutions.count == 3 &&
            resolutions[0].resource == (id)exactScale &&
            resolutions[1].resource == (id)exactPlain &&
            resolutions[2].resource == (id)legacy && error == nil,
            @"All exact-name candidates, including cross-scale and plain, must precede a legacy exact-scale device image");

        resolver = MTUICompatibilityResolver(@[legacy]);
        MTUIResourceSnapshotResolution *resolution = [resolver
            resolutionForPreferencesIconName:currentName scale:3 error:&error];
        MTUIResourceCompatibilityAssert(resolution.resource == (id)legacy &&
            [resolution.canonicalResourceKey
                isEqualToString:legacy.resourceKey.canonicalString] &&
            error == nil,
            @"Current Settings keys must resolve a supported legacy-only resource without rewriting its key");

        resolver = MTUICompatibilityResolver(@[exactScale, exactPlain]);
        resolution = [resolver resolutionForPreferencesIconName:legacyName
            scale:3 error:&error];
        MTUIResourceCompatibilityAssert(resolution == nil && error == nil,
            @"Settings aliases must not become reverse or bidirectional mappings");
    }
}

static void MTUICompatibilityTestGraphicIconPairs(void) {
    // Fixed by the paired GraphicIcon/PK branches in Preferences 21D61,
    // independently of the source theme's filenames and visible labels.
    NSArray<NSArray<NSString *> *> *pairs = @[
        @[@"com.apple.graphic-icon.airplane-mode", @"AirplaneMode"],
        @[@"com.apple.graphic-icon.wifi", @"WiFi"],
        @[@"com.apple.graphic-icon.ethernet", @"Ethernet"],
        @[@"com.apple.graphic-icon.bluetooth", @"Bluetooth"],
        @[@"com.apple.graphic-icon.cellular-settings", @"CellularData"],
        @[@"com.apple.graphic-icon.personal-hotspot", @"PersonalHotspot"],
        @[@"com.apple.graphic-icon.vpn", @"VPN"],
        @[@"com.apple.graphic-icon.notifications", @"NotificationCenter"],
        @[@"com.apple.graphic-icon.sound", @"Sounds"],
        @[@"com.apple.graphic-icon.focus", @"DND"],
        @[@"com.apple.graphic-icon.screen-time", @"ScreenTime"],
        @[@"com.apple.graphic-icon.gear", @"General"],
        @[@"com.apple.graphic-icon.control-center", @"ControlCenter"],
        @[@"com.apple.graphic-icon.home-screen", @"HomeScreen"],
        @[@"com.apple.graphic-icon.accessibility", @"Accessibility"],
        @[@"com.apple.graphic-icon.wallpaper", @"Wallpaper"],
        @[@"com.apple.graphic-icon.pencil", @"Pencil"],
        @[@"com.apple.graphic-icon.face-id", @"FaceID"],
        @[@"com.apple.graphic-icon.emergency-sos", @"SOS"],
        @[@"com.apple.graphic-icon.exposure-notifications", @"ExposureNotification"],
        @[@"com.apple.graphic-icon.touch-id", @"TouchID"],
        @[@"com.apple.graphic-icon.battery", @"BatteryUsage"],
        @[@"com.apple.graphic-icon.passcode", @"Passcode"],
        @[@"com.apple.graphic-icon.privacy", @"Privacy"],
        @[@"com.apple.graphic-icon.passwords", @"KeychainSync"],
        @[@"com.apple.graphic-icon.tv-provider", @"VideoSubscriber"],
        @[@"com.apple.graphic-icon.developer-tools", @"DeveloperSettings"],
        @[@"com.apple.graphic-icon.carrier-settings", @"CarrierSettings"],
        @[@"com.apple.graphic-icon.internal-settings", @"_internal_icon"],
        @[@"com.apple.graphic-icon.app-clips", @"AppClips"],
    ];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSArray<NSString *> *pair in pairs) {
        [paths addObject:[NSString stringWithFormat:
            @"Bundles/com.apple.Preferences/%@@3x.png", pair[1]]];
    }
    MTUIResourcesImportResult *result = MTUICompatibilityImport(paths);
    MTUIResourceCompatibilityAssert(result.recognizedFileCount == 30 &&
        result.rejectedFileCount == 0 && result.resources.count == 30,
        @"The 21D61 GraphicIcon bridge must reuse thirty ordinary imported PK-name resources");
    MTUIResourceSnapshotResolver *resolver =
        MTUICompatibilityResolver(result.resources);
    for (NSUInteger index = 0; index < pairs.count; index++) {
        NSArray<NSString *> *pair = pairs[index];
        MTThemeResource *resource = MTUICompatibilityResourceAtPath(result,
                                                                   paths[index]);
        MTUIResourceCompatibilityAssert(resource != nil &&
            [resource.resourceKey.subject isEqualToString:pair[1]],
            @"GraphicIcon compatibility must leave every authored PK subject unchanged");
        NSError *error = nil;
        MTUIResourceSnapshotResolution *resolution = [resolver
            resolutionForPreferencesIconName:pair[0] scale:3 error:&error];
        MTUIResourceCompatibilityAssert(resolution.resource == (id)resource &&
            [resolution.canonicalResourceKey
                isEqualToString:resource.resourceKey.canonicalString] &&
            error == nil,
            [NSString stringWithFormat:
                @"The confirmed GraphicIcon type %@ must resolve its PK resource %@",
                pair[0], pair[1]]);
    }
    for (NSString *unverifiedName in @[
            @"wifi", @"Wi-Fi", @"com.example.graphic-icon.wifi",
            @"com.apple.Graphic-Icon.wifi", @"com.apple.graphic-icon.WiFi"]) {
        NSError *error = nil;
        MTUIResourceCompatibilityAssert([resolver
            resolutionForPreferencesIconName:unverifiedName scale:3
            error:&error] == nil && error == nil,
            @"GraphicIcon fallback must require an exact verified type and namespace");
    }
}

static void MTUICompatibilityTestGraphicIconPrecedence(void) {
    NSString *type = @"com.apple.graphic-icon.carrier-settings";
    NSString *fullPath = [NSString stringWithFormat:
        @"Bundles/com.apple.Preferences/%@.png", type];
    NSString *iPadPath = [NSString stringWithFormat:
        @"Bundles/com.apple.Preferences/%@@3x~ipad.png", type];
    NSString *cacheScalePath =
        @"Bundles/com.apple.Preferences/CarrierSettings@2x.png";
    NSString *cachePlainPath =
        @"Bundles/com.apple.Preferences/CarrierSettings.png";
    NSString *legacyPath =
        @"Bundles/com.apple.Preferences/Carrier@3x~iphone.png";
    MTUIResourcesImportResult *result = MTUICompatibilityImport(
        @[fullPath, iPadPath, cacheScalePath, cachePlainPath, legacyPath]);
    MTThemeResource *full = MTUICompatibilityResourceAtPath(result, fullPath);
    MTThemeResource *iPad = MTUICompatibilityResourceAtPath(result, iPadPath);
    MTThemeResource *cacheScale = MTUICompatibilityResourceAtPath(result,
        cacheScalePath);
    MTThemeResource *cachePlain = MTUICompatibilityResourceAtPath(result,
        cachePlainPath);
    MTThemeResource *legacy = MTUICompatibilityResourceAtPath(result,
        legacyPath);
    MTUIResourceCompatibilityAssert(result.recognizedFileCount == 5 &&
        result.rejectedFileCount == 0 &&
        [full.resourceKey.subject isEqualToString:type],
        @"Full GraphicIcon identities must be accepted without altering ordinary PK or legacy subjects");
    MTUIResourceSnapshotResolver *resolver =
        MTUICompatibilityResolver(result.resources);
    NSError *error = nil;
    NSArray<MTUIResourceSnapshotResolution *> *resolutions = [resolver
        resolutionsForPreferencesIconName:type scale:3
        deviceTrait:@"iphone" error:&error];
    MTUIResourceCompatibilityAssert(resolutions.count == 4 &&
        resolutions[0].resource == (id)full &&
        resolutions[1].resource == (id)cacheScale &&
        resolutions[2].resource == (id)cachePlain &&
        resolutions[3].resource == (id)legacy && error == nil,
        @"Full-type plain artwork must precede every PK variant, and lower-scale PK artwork must precede exact-scale legacy artwork");
    resolutions = [resolver resolutionsForPreferencesIconName:type scale:3
        deviceTrait:@"ipad" error:&error];
    MTUIResourceCompatibilityAssert(resolutions.count == 4 &&
        resolutions[0].resource == (id)iPad &&
        resolutions[1].resource == (id)full &&
        resolutions[2].resource == (id)cacheScale &&
        resolutions[3].resource == (id)cachePlain && error == nil,
        @"GraphicIcon and PK fallback must preserve device variants and exclude iPhone-only legacy artwork on iPad");

    resolver = MTUICompatibilityResolver(@[cacheScale, cachePlain, legacy]);
    MTUIResourceSnapshotResolution *resolution = [resolver
        resolutionForPreferencesIconName:type scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)cacheScale &&
        error == nil,
        @"A missing full-type resource must prefer an available PK scale fallback over a legacy match");
    resolver = MTUICompatibilityResolver(@[legacy]);
    resolution = [resolver resolutionForPreferencesIconName:type
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)legacy &&
        error == nil,
        @"A verified GraphicIcon-to-PK bridge may continue to that PK key's documented legacy name");
    resolver = MTUICompatibilityResolver(@[full]);
    resolution = [resolver
        resolutionForPreferencesIconName:@"CarrierSettings"
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution == nil && error == nil,
        @"GraphicIcon aliases must not reverse-map PK requests to unrelated full-type assets");
}

static void MTUICompatibilityTestGraphicIconLimits(void) {
    NSString *keychainPath =
        @"Bundles/com.apple.Preferences/KeychainSync@2x.png";
    NSString *passcodePath =
        @"Bundles/com.apple.Preferences/Passcode@3x.png";
    NSString *standbyPath =
        @"Bundles/com.apple.Preferences/com.apple.graphic-icon.standby@2x.png";
    NSString *guessedStandbyPath =
        @"Bundles/com.apple.Preferences/Standby@3x.png";
    NSString *shareWiFiPath =
        @"Bundles/com.apple.SharingUIService/WiFi@3x.png";
    MTUIResourcesImportResult *result = MTUICompatibilityImport(
        @[keychainPath, passcodePath, standbyPath, guessedStandbyPath,
          shareWiFiPath]);
    MTThemeResource *keychain = MTUICompatibilityResourceAtPath(result,
        keychainPath);
    MTThemeResource *passcode = MTUICompatibilityResourceAtPath(result,
        passcodePath);
    MTThemeResource *standby = MTUICompatibilityResourceAtPath(result,
        standbyPath);
    MTThemeResource *guessedStandby = MTUICompatibilityResourceAtPath(result,
        guessedStandbyPath);
    MTUIResourceSnapshotResolver *resolver =
        MTUICompatibilityResolver(result.resources);
    NSError *error = nil;
    MTUIResourceSnapshotResolution *resolution = [resolver
        resolutionForPreferencesIconName:@"com.apple.graphic-icon.passwords"
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)keychain &&
        error == nil,
        @"The passwords GraphicIcon must map to the verified KeychainSync resource, never Passcode");
    resolution = [resolver
        resolutionForPreferencesIconName:@"com.apple.graphic-icon.passcode"
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)passcode &&
        error == nil,
        @"The distinct passcode GraphicIcon must continue to use Passcode");
    resolution = [resolver
        resolutionForPreferencesIconName:@"com.apple.graphic-icon.standby"
        scale:3 error:&error];
    MTUIResourceCompatibilityAssert(resolution.resource == (id)standby &&
        error == nil,
        @"An unmapped GraphicIcon type may use an explicitly authored full-type resource");
    MTUIResourceCompatibilityAssert([resolver
        resolutionForShareActivityName:@"com.apple.graphic-icon.wifi"
        scale:3 error:&error] == nil && error == nil,
        @"GraphicIcon-to-PK compatibility must never apply to the Share surface");

    resolver = MTUICompatibilityResolver(@[passcode, guessedStandby]);
    for (NSString *name in @[@"com.apple.graphic-icon.passwords",
                             @"com.apple.graphic-icon.standby"]) {
        MTUIResourceCompatibilityAssert([resolver
            resolutionForPreferencesIconName:name scale:3 error:&error] == nil &&
            error == nil,
            @"Nearby names must not substitute for missing passwords or an unknown full GraphicIcon type");
    }
}

static void MTUICompatibilityTestNarrowFallback(void) {
    NSArray<NSString *> *paths = @[
        @"Bundles/com.apple.Preferences/FindMyiPhone@3x.png",
        @"Bundles/com.apple.Preferences/PearlID-D22@3x.png",
        @"Bundles/com.apple.Preferences/Newsstand@3x.png",
        @"Bundles/com.apple.Preferences/WiFi@3x.png",
        @"Bundles/com.apple.Preferences/Passbook@3x.png",
        @"Bundles/com.apple.SharingUIService/Carrier@3x.png",
        @"Bundles/com.apple.SharingUIService/Passbook@3x.png",
        @"Bundles/com.apple.SharingUIService/mobileNotes@3x.png",
        @"Bundles/com.apple.SharingUIService/UIAirDropActivity@3x.png",
    ];
    MTUIResourcesImportResult *result = MTUICompatibilityImport(paths);
    MTUIResourceSnapshotResolver *resolver =
        MTUICompatibilityResolver(result.resources);
    for (NSString *name in @[@"Location", @"iCloud", @"FaceID", @"News",
                             @"wifi", @"com.apple.graphic-icon.standby"]) {
        NSError *error = nil;
        MTUIResourceCompatibilityAssert([resolver
            resolutionForPreferencesIconName:name scale:3 error:&error] == nil &&
            error == nil,
            @"Unverified aliases, case changes and unsupported GraphicIcon identities must remain clean Settings misses");
    }
    for (NSString *name in @[@"CarrierSettings", @"Wallet", @"Notes",
                             @"AirDrop"]) {
        NSError *error = nil;
        MTUIResourceCompatibilityAssert([resolver
            resolutionForShareActivityName:name scale:3 error:&error] == nil &&
            error == nil,
            @"Settings aliases and a display-label AirDrop guess must never change Share activity lookup");
    }
    NSError *error = nil;
    MTUIResourceSnapshotResolution *resolution = [resolver
        resolutionForShareActivityName:@"Passbook" scale:3 error:&error];
    MTUIResourceCompatibilityAssert([resolution.canonicalResourceKey
        isEqualToString:MTUICompatibilityResourceAtPath(result,
            @"Bundles/com.apple.SharingUIService/Passbook@3x.png")
                .resourceKey.canonicalString] && error == nil,
        @"Exact Share lookup must remain independent of a Settings resource with the same subject");
    resolver = [[MTUIResourceSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return MTRuntimeSnapshot.stockSnapshot;
        }];
    MTUIResourceCompatibilityAssert([resolver
        resolutionForPreferencesIconName:@"Wallet" scale:3 error:&error] == nil &&
        error == nil,
        @"Legacy fallback must preserve the stock behavior of a disabled Runtime snapshot");
}

NSUInteger MTRunUIResourceCompatibilityTests(void) {
    MTUIResourceCompatibilityAssertions = 0;
    MTUICompatibilityTestMalformedNames();
    MTUICompatibilityTestSettingsAliases();
    MTUICompatibilityTestGraphicIconPairs();
    MTUICompatibilityTestGraphicIconPrecedence();
    MTUICompatibilityTestGraphicIconLimits();
    MTUICompatibilityTestNarrowFallback();
    return MTUIResourceCompatibilityAssertions;
}
