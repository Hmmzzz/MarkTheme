#import "MTIconBundlesImporter.h"

#import <string.h>

#import "MTBadgeConfiguration.h"
#import "MTBadgesModule.h"
#import "MTDiagnostic.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTDialerModule.h"
#import "MTFolderIconContract.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconMaskContract.h"
#import "MTIconShadowConfiguration.h"
#import "MTIconShadowsModule.h"
#import "MTLegacyThemeResourcesImporter.h"
#import "MTResourceKey.h"
#import "MTSourceInventory.h"
#import "MTThemeComponentPath.h"
#import "MTThemeManifest.h"
#import "MTThemeInfoMetadataMapper.h"
#import "MTStatusBarModule.h"
#import "MTStaticIconConfiguration.h"
#import "MTUIResourcesImporter.h"
#import "MTUIResourcesModule.h"

NSString *const MTIconBundlesImporterErrorDomain =
    @"com.hmmzzz.marktheme.iconbundles-importer";

@interface MTIconBundlesImportResult ()
- (instancetype)initWithManifest:(MTThemeManifest *)manifest
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
              recognizedFileCount:(NSUInteger)recognizedFileCount
                 ignoredFileCount:(NSUInteger)ignoredFileCount
                rejectedFileCount:(NSUInteger)rejectedFileCount;
@end

@implementation MTIconBundlesImportResult

- (instancetype)initWithManifest:(MTThemeManifest *)manifest
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
              recognizedFileCount:(NSUInteger)recognizedFileCount
                 ignoredFileCount:(NSUInteger)ignoredFileCount
                rejectedFileCount:(NSUInteger)rejectedFileCount {
    self = [super init];
    if (self == nil) return nil;
    _manifest = manifest;
    _diagnostics = [diagnostics copy];
    _recognizedFileCount = recognizedFileCount;
    _ignoredFileCount = ignoredFileCount;
    _rejectedFileCount = rejectedFileCount;
    return self;
}

@end

@interface MTIconBundlesFilenameMapping : NSObject
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *trait;
@property(nonatomic, copy) NSString *sourceFormat;
@property(nonatomic, assign) NSUInteger scale;
@property(nonatomic, assign) NSUInteger matchRank;
@end

@implementation MTIconBundlesFilenameMapping
@end

static BOOL MTIconBundlesBundleIDIsValid(NSString *bundleID) {
    return MTStaticIconBundleIdentifierIsValid(bundleID);
}

static NSDictionary<NSString *, id> *MTIconBundlesSuffix(
    NSString *suffix,
    NSUInteger scale,
    NSString *trait,
    NSString *format,
    NSUInteger rank) {
    return @{
        @"suffix" : suffix,
        @"scale" : @(scale),
        @"trait" : trait,
        @"format" : format,
        @"rank" : @(rank),
    };
}

static NSArray<NSDictionary<NSString *, id> *> *MTIconBundlesSuffixes(void) {
    static NSArray<NSDictionary<NSString *, id> *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            MTIconBundlesSuffix(@"-large", 0, @"any", @"iconbundles.large", 0),
            MTIconBundlesSuffix(@"~iphone@3x", 3, @"iphone",
                                @"iconbundles.device-scale", 10),
            MTIconBundlesSuffix(@"~iphone@2x", 2, @"iphone",
                                @"iconbundles.device-scale", 11),
            MTIconBundlesSuffix(@"~ipad@3x", 3, @"ipad",
                                @"iconbundles.device-scale", 12),
            MTIconBundlesSuffix(@"~ipad@2x", 2, @"ipad",
                                @"iconbundles.device-scale", 13),
            MTIconBundlesSuffix(@"@3x~iphone", 3, @"iphone",
                                @"iconbundles.scale-device", 20),
            MTIconBundlesSuffix(@"@2x~iphone", 2, @"iphone",
                                @"iconbundles.scale-device", 21),
            MTIconBundlesSuffix(@"@3x~ipad", 3, @"ipad",
                                @"iconbundles.scale-device", 22),
            MTIconBundlesSuffix(@"@2x~ipad", 2, @"ipad",
                                @"iconbundles.scale-device", 23),
            MTIconBundlesSuffix(@"@3x", 3, @"any",
                                @"iconbundles.scale", 30),
            MTIconBundlesSuffix(@"@2x", 2, @"any",
                                @"iconbundles.scale", 31),
            MTIconBundlesSuffix(@"~iphone", 0, @"iphone",
                                @"iconbundles.device", 40),
            MTIconBundlesSuffix(@"~ipad", 0, @"ipad",
                                @"iconbundles.device", 41),
            MTIconBundlesSuffix(@"", 0, @"any",
                                @"iconbundles.plain", 50),
        ];
    });
    return suffixes;
}

static MTIconBundlesFilenameMapping *_Nullable MTIconBundlesParseFilename(
    NSString *filename) {
    NSString *normalized = [[filename
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        precomposedStringWithCanonicalMapping];
    if (![normalized.lowercaseString hasSuffix:@".png"] ||
        normalized.length <= 4) return nil;
    NSString *stem = [normalized substringToIndex:normalized.length - 4];
    while ([stem.lowercaseString hasSuffix:@".png"] && stem.length > 4) {
        stem = [stem substringToIndex:stem.length - 4];
    }
    for (NSDictionary<NSString *, id> *rule in MTIconBundlesSuffixes()) {
        NSString *suffix = rule[@"suffix"];
        if (suffix.length > 0 &&
            ![stem.lowercaseString hasSuffix:suffix.lowercaseString]) {
            continue;
        }
        NSString *bundleID = suffix.length == 0
            ? stem
            : [stem substringToIndex:stem.length - suffix.length];
        while ([bundleID containsString:@".."]) {
            bundleID = [bundleID stringByReplacingOccurrencesOfString:@".."
                                                       withString:@"."];
        }
        if (!MTIconBundlesBundleIDIsValid(bundleID)) continue;
        MTIconBundlesFilenameMapping *mapping =
            [[MTIconBundlesFilenameMapping alloc] init];
        mapping.bundleID = [bundleID precomposedStringWithCanonicalMapping];
        mapping.scale = [rule[@"scale"] unsignedIntegerValue];
        mapping.trait = rule[@"trait"];
        mapping.sourceFormat = rule[@"format"];
        mapping.matchRank = [rule[@"rank"] unsignedIntegerValue];
        return mapping;
    }
    return nil;
}

static BOOL MTIconBundlesFileHasPNGSignature(MTSourceFile *file) {
    static const unsigned char signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a
    };
    return file.prefixData.length >= sizeof(signature) &&
        memcmp(file.prefixData.bytes, signature, sizeof(signature)) == 0;
}

static MTDiagnostic *MTIconBundlesDiagnostic(
    MTDiagnosticSeverity severity,
    NSString *code,
    NSString *summary,
    MTResourceKey *_Nullable resourceKey,
    NSString *path) {
    return [[MTDiagnostic alloc] initWithSeverity:severity
                                             code:code
                                          summary:summary
                                      resourceKey:resourceKey
                                          details:@{ @"path" : path }
                                            error:NULL];
}

static NSArray<MTThemeResource *> *MTIconBundlesResolveResourceConflicts(
    NSArray<MTThemeResource *> *resources,
    NSMutableArray<MTDiagnostic *> *diagnostics) {
    NSMutableDictionary<NSString *, MTThemeResource *> *selected =
        [NSMutableDictionary dictionary];
    for (MTThemeResource *candidate in resources) {
        NSString *identity = candidate.resourceKey.canonicalString;
        MTThemeResource *current = selected[identity];
        if (current == nil) {
            selected[identity] = candidate;
            continue;
        }
        BOOL candidateIsComponent = [candidate.relativeAssetPath
            hasPrefix:@"Components/"];
        BOOL currentIsComponent = [current.relativeAssetPath
            hasPrefix:@"Components/"];
        BOOL candidateWins = candidateIsComponent != currentIsComponent
            ? !candidateIsComponent
            : candidate.matchRank < current.matchRank ||
            (candidate.matchRank == current.matchRank &&
             [candidate.relativeAssetPath
                 compare:current.relativeAssetPath] == NSOrderedAscending);
        MTThemeResource *loser = candidateWins ? current : candidate;
        if (candidateWins) selected[identity] = candidate;
        [diagnostics addObject:MTIconBundlesDiagnostic(
            MTDiagnosticSeverityWarning,
            @"import.resource.shadowed",
            @"A lower-precedence file mapped to an existing semantic resource and was skipped.",
            loser.resourceKey, loser.relativeAssetPath)];
    }
    return [selected.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(MTThemeResource *left, MTThemeResource *right) {
            return [left.resourceKey.canonicalString
                compare:right.resourceKey.canonicalString];
        }];
}

static NSDictionary<NSString *, NSString *> *MTClockResourceVariantsByPath(void) {
    static NSDictionary<NSString *, NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @{
            @"Bundles/com.apple.springboard/ClockIconBackgroundSquare.png" :
                @"background",
            @"Bundles/com.apple.springboard/ClockIconHourHand.png" :
                @"hour-hand",
            @"Bundles/com.apple.springboard/ClockIconMinuteHand.png" :
                @"minute-hand",
            @"Bundles/com.apple.springboard/ClockIconSecondHand.png" :
                @"second-hand",
        };
    });
    return paths;
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *
MTIconBundlesGlobalResourcesByFilename(void) {
    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *files;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        files = @{
            @"icon_mask.png" : @{
                @"module" : MTIconMaskModuleID,
                @"surface" : MTIconMaskSurface,
                @"subject" : MTIconMaskGlobalSubject,
                @"variant" : MTIconMaskVariantMask,
                @"format" : @"iconbundles.global-mask",
            },
            @"icon_pattern.png" : @{
                @"module" : MTIconMaskModuleID,
                @"surface" : MTIconMaskSurface,
                @"subject" : MTIconMaskGlobalSubject,
                @"variant" : MTIconMaskVariantPattern,
                @"format" : @"iconbundles.global-pattern",
            },
            @"icon_folder.png" : @{
                @"module" : MTFolderIconsModuleID,
                @"surface" : MTFolderIconSurface,
                @"subject" : MTFolderIconGlobalSubject,
                @"variant" : MTFolderIconVariantBackground,
                @"format" : @"iconbundles.folder-background",
            },
            @"icon_folder_light.png" : @{
                @"module" : MTFolderIconsModuleID,
                @"surface" : MTFolderIconSurface,
                @"subject" : MTFolderIconGlobalSubject,
                @"variant" : MTFolderIconVariantBackgroundLight,
                @"format" : @"iconbundles.folder-background-light",
            },
        };
    });
    return files;
}

@implementation MTIconBundlesImporter

- (MTIconBundlesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                            sourceName:(NSString *)sourceName
                                                 error:(NSError **)error {
    return [self importSourceInventory:inventory
                            sourceName:sourceName
                        importMetadata:nil
                                 error:error];
}

- (MTIconBundlesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                            sourceName:(NSString *)sourceName
                                        importMetadata:
                                           (MTThemeImportMetadata *)importMetadata
                                                 error:(NSError **)error {
    if (![inventory isKindOfClass:MTSourceInventory.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTIconBundlesImporterErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"IconBundles scan is invalid."
            }];
        }
        return nil;
    }
    if (importMetadata != nil &&
        ![importMetadata isKindOfClass:MTThemeImportMetadata.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTIconBundlesImporterErrorDomain
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"IconBundles import metadata is invalid."
            }];
        }
        return nil;
    }
    NSMutableArray<MTThemeResource *> *resources = [NSMutableArray array];
    NSMutableArray<MTDiagnostic *> *diagnostics = importMetadata == nil
        ? [NSMutableArray array]
        : [importMetadata.diagnostics mutableCopy];
    NSMutableSet<NSString *> *priorityIdentities = [NSMutableSet set];
    NSUInteger recognized = 0;
    NSUInteger rejected = 0;
    NSUInteger folderResourceCount = 0;
    NSDictionary *iconMaskDictionary =
        importMetadata.moduleConfigurations[MTIconMaskModuleID];
    MTIconMaskConfiguration *iconMaskConfiguration =
        iconMaskDictionary == nil ? nil :
            [[MTIconMaskConfiguration alloc]
                initWithDictionary:iconMaskDictionary error:NULL];
    NSDictionary *staticIconDictionary =
        importMetadata.moduleConfigurations[@"icons.static"];
    MTStaticIconConfiguration *staticIconConfiguration =
        staticIconDictionary == nil ? nil :
            [[MTStaticIconConfiguration alloc]
                initWithDictionary:staticIconDictionary error:NULL];

    for (MTSourceFile *file in inventory.files) {
        MTThemeComponentPath *component = [MTThemeComponentPath
            pathWithLogicalRelativePath:file.relativePath];
        NSString *logicalPath = component.relativePath;
        if (![logicalPath hasPrefix:@"IconBundles/"]) continue;
        NSString *remainder = [logicalPath
            substringFromIndex:@"IconBundles/".length];
        if ([remainder containsString:@"/"]) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.iconbundles.nested-file",
                @"IconBundles file is nested below the supported directory level.",
                nil, file.relativePath)];
            continue;
        }
        NSString *normalizedFilename = [[remainder
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
            precomposedStringWithCanonicalMapping];
        NSDictionary<NSString *, NSString *> *globalMapping =
            MTIconBundlesGlobalResourcesByFilename()[
                normalizedFilename.lowercaseString];
        if (globalMapping != nil) {
            NSString *moduleID = globalMapping[@"module"];
            if ([moduleID isEqualToString:MTIconMaskModuleID] &&
                iconMaskConfiguration == nil) {
                rejected++;
                [diagnostics addObject:MTIconBundlesDiagnostic(
                    MTDiagnosticSeverityWarning,
                    @"import.icon-mask.not-enabled",
                    @"Global icon mask resource requires IB-MaskIcons=true.",
                    nil, file.relativePath)];
                continue;
            }
            if (!MTIconBundlesFileHasPNGSignature(file)) {
                rejected++;
                [diagnostics addObject:MTIconBundlesDiagnostic(
                    MTDiagnosticSeverityError,
                    @"import.iconbundles.invalid-png",
                    @"Global IconBundles resource has no PNG signature.",
                    nil, file.relativePath)];
                continue;
            }
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:moduleID
                         surface:globalMapping[@"surface"]
                         subject:globalMapping[@"subject"]
                         variant:globalMapping[@"variant"]
                           scale:0
                           trait:@"any"
                           error:&keyError];
            MTThemeResource *resource = key == nil ? nil :
                [[MTThemeResource alloc]
                    initWithResourceKey:key
                       relativeAssetPath:file.relativePath
                           contentSHA256:file.contentSHA256
                            sourceFormat:globalMapping[@"format"]
                               matchRank:0
                                   error:&keyError];
            if (resource == nil) {
                rejected++;
                [diagnostics addObject:MTIconBundlesDiagnostic(
                    MTDiagnosticSeverityError,
                    @"import.iconbundles.invalid-resource",
                    keyError.localizedDescription ?:
                        @"Global IconBundles resource is invalid.",
                    key, file.relativePath)];
                continue;
            }
            [resources addObject:resource];
            recognized++;
            if (![moduleID isEqualToString:MTIconMaskModuleID]) {
                folderResourceCount++;
            }
            continue;
        }
        MTIconBundlesFilenameMapping *mapping =
            MTIconBundlesParseFilename(remainder);
        if (mapping == nil) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.iconbundles.unknown-name",
                @"Icon filename is outside the confirmed IconBundles subset.",
                nil, file.relativePath)];
            continue;
        }
        if (!MTIconBundlesFileHasPNGSignature(file)) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityError,
                @"import.iconbundles.invalid-png",
                @"Icon has a .png name but does not contain a PNG signature.",
                nil, file.relativePath)];
            continue;
        }

        NSError *keyError = nil;
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:@"icons.static"
                     surface:@"springboard.home"
                     subject:mapping.bundleID
                     variant:@"primary"
                       scale:mapping.scale
                       trait:mapping.trait
                       error:&keyError];
        MTThemeResource *resource = key == nil ? nil : [[MTThemeResource alloc]
            initWithResourceKey:key
               relativeAssetPath:file.relativePath
                   contentSHA256:file.contentSHA256
                    sourceFormat:mapping.sourceFormat
                       matchRank:mapping.matchRank
                           error:&keyError];
        if (resource == nil) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityError,
                @"import.iconbundles.invalid-resource",
                keyError.localizedDescription ?: @"Icon resource is invalid.",
                key, file.relativePath)];
            continue;
        }
        NSString *priorityIdentity = [NSString stringWithFormat:@"%@\x1f%lu",
            key.canonicalString, (unsigned long)mapping.matchRank];
        if ([priorityIdentities containsObject:priorityIdentity]) {
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.iconbundles.duplicate-priority",
                @"Multiple icons map to the same semantic key and precedence.",
                key, file.relativePath)];
        }
        [priorityIdentities addObject:priorityIdentity];
        [resources addObject:resource];
        recognized++;
    }

    MTUIResourcesImportResult *uiResources =
        [[[MTUIResourcesImporter alloc] init]
            importSourceInventory:inventory error:error];
    if (uiResources == nil) return nil;
    [resources addObjectsFromArray:uiResources.resources];
    [diagnostics addObjectsFromArray:uiResources.diagnostics];
    recognized += uiResources.recognizedFileCount;
    rejected += uiResources.rejectedFileCount;

    MTLegacyThemeResourcesImportResult *legacyResources =
        [[[MTLegacyThemeResourcesImporter alloc] init]
            importSourceInventory:inventory error:error];
    if (legacyResources == nil) return nil;
    [resources addObjectsFromArray:legacyResources.resources];
    [diagnostics addObjectsFromArray:legacyResources.diagnostics];
    recognized += legacyResources.recognizedFileCount;
    rejected += legacyResources.rejectedFileCount;

    NSUInteger clockResourceCount = 0;
    MTThemeResource *clockBackgroundResource = nil;
    NSDictionary<NSString *, NSString *> *clockVariants =
        MTClockResourceVariantsByPath();
    for (MTSourceFile *file in inventory.files) {
        MTThemeComponentPath *component = [MTThemeComponentPath
            pathWithLogicalRelativePath:file.relativePath];
        NSString *variant = clockVariants[component.relativePath];
        if (variant == nil) continue;
        if (!MTIconBundlesFileHasPNGSignature(file)) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityError,
                @"import.clock.invalid-png",
                @"Clock component has a .png name but no PNG signature.",
                nil, file.relativePath)];
            continue;
        }
        NSError *keyError = nil;
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:MTClockIconsModuleID
                     surface:@"springboard.home"
                     subject:MTClockIconTargetBundleIdentifier
                     variant:variant
                       scale:0
                       trait:@"any"
                       error:&keyError];
        MTThemeResource *resource = key == nil ? nil : [[MTThemeResource alloc]
            initWithResourceKey:key
               relativeAssetPath:file.relativePath
                   contentSHA256:file.contentSHA256
                    sourceFormat:@"snowboard.clock-component"
                       matchRank:0
                           error:&keyError];
        if (resource == nil) {
            rejected++;
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityError,
                @"import.clock.invalid-resource",
                keyError.localizedDescription ?: @"Clock resource is invalid.",
                key, file.relativePath)];
            continue;
        }
        [resources addObject:resource];
        if ([variant isEqualToString:@"background"]) {
            clockBackgroundResource = resource;
        }
        clockResourceCount++;
        recognized++;
    }

    // The live Clock still asks the ordinary icon cache for its face. Publish
    // the legacy background under the canonical static subject as well,
    // unless the theme supplied an explicit IconBundles icon.
    BOOL hasExplicitClockStaticIcon = NO;
    for (MTThemeResource *resource in resources) {
        if ([resource.resourceKey.moduleID isEqualToString:@"icons.static"] &&
            [resource.resourceKey.subject
                isEqualToString:MTClockIconTargetBundleIdentifier]) {
            hasExplicitClockStaticIcon = YES;
            break;
        }
    }
    if (clockBackgroundResource != nil && !hasExplicitClockStaticIcon) {
        NSError *aliasError = nil;
        MTResourceKey *aliasKey = [[MTResourceKey alloc]
            initWithModuleID:@"icons.static"
                     surface:@"springboard.home"
                     subject:MTClockIconTargetBundleIdentifier
                     variant:@"primary"
                       scale:0
                       trait:@"any"
                       error:&aliasError];
        MTThemeResource *alias = aliasKey == nil ? nil : [[MTThemeResource alloc]
            initWithResourceKey:aliasKey
               relativeAssetPath:clockBackgroundResource.relativeAssetPath
                   contentSHA256:clockBackgroundResource.contentSHA256
                    sourceFormat:@"snowboard.clock-background"
                       matchRank:0
                           error:&aliasError];
        if (alias == nil) {
            if (error != NULL) *error = aliasError;
            return nil;
        }
        [resources addObject:alias];
    }

    [resources setArray:MTIconBundlesResolveResourceConflicts(
        resources, diagnostics)];

    BOOL hasStaticResources = NO;
    for (MTThemeResource *resource in resources) {
        if ([resource.resourceKey.moduleID isEqualToString:@"icons.static"]) {
            hasStaticResources = YES;
            break;
        }
    }
    if (resources.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTIconBundlesImporterErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"No supported icon or UI resources were found."
            }];
        }
        return nil;
    }
    MTThemeDisplayMetadata *displayMetadata = importMetadata.displayMetadata;
    NSString *displayName = displayMetadata.displayName;
    if (displayName == nil) {
        displayName = [sourceName precomposedStringWithCanonicalMapping];
        if ([displayName hasSuffix:@".theme"] && displayName.length > 6) {
            displayName = [displayName substringToIndex:displayName.length - 6];
        }
        if (displayName.length == 0) displayName = @"Imported Icon Theme";
    }
    NSString *themeID = [NSString stringWithFormat:@"theme.iconbundles.%@",
        [inventory.sourceFingerprint substringToIndex:24]];
    NSMutableDictionary *moduleConfigurations = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *capabilities = [NSMutableArray array];
    if (hasStaticResources) {
        [capabilities addObject:@"icons.static"];
        if (staticIconConfiguration != nil) {
            moduleConfigurations[@"icons.static"] =
                staticIconConfiguration.canonicalDictionary;
        }
    }
    if (clockResourceCount > 0) {
        [capabilities addObject:MTClockIconsModuleID];
    }
    if (uiResources.resources.count > 0) {
        [capabilities addObject:MTUIResourcesModuleID];
    }
    NSSet<NSString *> *legacyModuleIDs = [NSSet setWithArray:
        [legacyResources.resources valueForKeyPath:@"resourceKey.moduleID"]];
    for (NSString *moduleID in @[
        MTBadgesModuleID,
        MTDialerModuleID,
        MTIconShadowsModuleID,
        MTStatusBarModuleID,
    ]) {
        if ([legacyModuleIDs containsObject:moduleID]) {
            [capabilities addObject:moduleID];
        }
    }
    if ([legacyModuleIDs containsObject:MTBadgesModuleID]) {
        NSMutableSet<NSString *> *badgeVariants = [NSMutableSet set];
        for (MTThemeResource *resource in legacyResources.resources) {
            if ([resource.resourceKey.moduleID
                    isEqualToString:MTBadgesModuleID]) {
                [badgeVariants addObject:resource.resourceKey.variant];
            }
        }
        NSString *defaultVariant = [[badgeVariants.allObjects
            sortedArrayUsingSelector:@selector(compare:)] firstObject];
        MTBadgeConfiguration *badgeConfiguration = defaultVariant == nil
            ? nil : [MTBadgeConfiguration
                configurationWithDefaultVariant:defaultVariant];
        if (badgeConfiguration == nil) {
            if (error != NULL) {
                *error = [NSError
                    errorWithDomain:MTIconBundlesImporterErrorDomain
                               code:2
                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Badge resources have no deterministic default style."
                }];
            }
            return nil;
        }
        moduleConfigurations[MTBadgesModuleID] =
            badgeConfiguration.canonicalDictionary;
    }
    if ([legacyModuleIDs containsObject:MTIconShadowsModuleID]) {
        NSMutableSet<NSString *> *shadowVariants = [NSMutableSet set];
        for (MTThemeResource *resource in legacyResources.resources) {
            if ([resource.resourceKey.moduleID
                    isEqualToString:MTIconShadowsModuleID]) {
                [shadowVariants addObject:resource.resourceKey.variant];
            }
        }
        NSString *defaultVariant = [[shadowVariants.allObjects
            sortedArrayUsingSelector:@selector(compare:)] firstObject];
        MTIconShadowConfiguration *shadowConfiguration =
            defaultVariant == nil ? nil : [MTIconShadowConfiguration
                configurationWithDefaultVariant:defaultVariant];
        if (shadowConfiguration == nil) {
            if (error != NULL) {
                *error = [NSError
                    errorWithDomain:MTIconBundlesImporterErrorDomain
                               code:2
                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Icon Shadow resources have no deterministic default style."
                }];
            }
            return nil;
        }
        moduleConfigurations[MTIconShadowsModuleID] =
            shadowConfiguration.canonicalDictionary;
    }
    if (iconMaskConfiguration != nil) {
        [capabilities addObject:MTIconMaskModuleID];
        moduleConfigurations[MTIconMaskModuleID] =
            iconMaskConfiguration.canonicalDictionary;
    }
    if (folderResourceCount > 0) {
        [capabilities addObject:MTFolderIconsModuleID];
    }
    NSDictionary *calendarConfiguration =
        importMetadata.moduleConfigurations[MTCalendarIconsModuleID];
    if (calendarConfiguration != nil) {
        BOOL hasCalendarBackground = NO;
        for (MTThemeResource *resource in resources) {
            if ([resource.resourceKey.moduleID isEqualToString:@"icons.static"] &&
                [resource.resourceKey.subject
                    isEqualToString:@"com.apple.mobilecal"] &&
                [resource.resourceKey.surface
                    isEqualToString:@"springboard.home"] &&
                [resource.resourceKey.variant isEqualToString:@"primary"]) {
                hasCalendarBackground = YES;
                break;
            }
        }
        if (hasCalendarBackground) {
            moduleConfigurations[MTCalendarIconsModuleID] =
                calendarConfiguration;
            [capabilities addObject:MTCalendarIconsModuleID];
        } else {
            [diagnostics addObject:MTIconBundlesDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.calendar.background-missing",
                @"Calendar settings were ignored because no Calendar icon background was imported.",
                nil, @"Info.plist")];
        }
    }
    NSUInteger importerVersion = staticIconConfiguration != nil
        ? 10
        : (legacyResources.resources.count > 0
        ? 9
        : (iconMaskConfiguration != nil || folderResourceCount > 0)
        ? 7
        : (uiResources.resources.count > 0
        ? 6
        : (clockResourceCount > 0
            ? 4 : (importMetadata == nil ? 1 : 3))));
    NSError *manifestError = nil;
    MTThemeManifest *manifest = [[MTThemeManifest alloc]
        initWithThemeID:themeID
             displayName:displayName
                  author:displayMetadata.author ?: @""
            themeVersion:displayMetadata.themeVersion ?: @""
              importerID:@"import.iconbundles"
         importerVersion:importerVersion
       sourceFingerprint:inventory.sourceFingerprint
            capabilities:capabilities
    moduleConfigurations:moduleConfigurations
               resources:resources
                   error:&manifestError];
    if (manifest == nil) {
        if (error != NULL) *error = manifestError;
        return nil;
    }
    NSUInteger ignored = inventory.files.count - recognized - rejected;
    return [[MTIconBundlesImportResult alloc]
        initWithManifest:manifest
             diagnostics:diagnostics
    recognizedFileCount:recognized
       ignoredFileCount:ignored
      rejectedFileCount:rejected];
}

@end
