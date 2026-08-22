#import "MTLegacyThemeResourcesImporter.h"

#import <string.h>

#import "MTBadgesModule.h"
#import "MTDiagnostic.h"
#import "MTDialerModule.h"
#import "MTFolderIconContract.h"
#import "MTIconShadowContract.h"
#import "MTIconShadowsModule.h"
#import "MTResourceKey.h"
#import "MTSourceInventory.h"
#import "MTStatusBarContract.h"
#import "MTStatusBarModule.h"
#import "MTThemeComponentPath.h"
#import "MTThemeManifest.h"

NSString *const MTLegacyThemeResourcesImporterErrorDomain =
    @"com.hmmzzz.marktheme64e.legacy-theme-resources-importer";

@interface MTLegacyThemeResourcesImportResult ()
- (instancetype)initWithResources:(NSArray<MTThemeResource *> *)resources
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
              recognizedFileCount:(NSUInteger)recognizedFileCount
                 rejectedFileCount:(NSUInteger)rejectedFileCount;
@end

@implementation MTLegacyThemeResourcesImportResult

- (instancetype)initWithResources:(NSArray<MTThemeResource *> *)resources
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
              recognizedFileCount:(NSUInteger)recognizedFileCount
                 rejectedFileCount:(NSUInteger)rejectedFileCount {
    self = [super init];
    if (self == nil) return nil;
    _resources = [resources copy];
    _diagnostics = [diagnostics copy];
    _recognizedFileCount = recognizedFileCount;
    _rejectedFileCount = rejectedFileCount;
    return self;
}

@end

@interface MTLegacyFilenameMapping : NSObject
@property(nonatomic, copy) NSString *subject;
@property(nonatomic, copy) NSString *trait;
@property(nonatomic, copy) NSString *formatSuffix;
@property(nonatomic, assign) NSUInteger scale;
@property(nonatomic, assign) NSUInteger matchRank;
@end

@implementation MTLegacyFilenameMapping
@end

static NSDictionary<NSString *, id> *MTLegacySuffix(
    NSString *suffix,
    NSUInteger scale,
    NSString *trait,
    NSString *formatSuffix,
    NSUInteger rank) {
    return @{
        @"suffix" : suffix,
        @"scale" : @(scale),
        @"trait" : trait,
        @"format" : formatSuffix,
        @"rank" : @(rank),
    };
}

static NSArray<NSDictionary<NSString *, id> *> *MTLegacySuffixes(void) {
    static NSArray<NSDictionary<NSString *, id> *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            MTLegacySuffix(@"~iphone@3x", 3, @"iphone",
                           @"device-scale", 0),
            MTLegacySuffix(@"@3x~iphone", 3, @"iphone",
                           @"scale-device", 1),
            MTLegacySuffix(@"~iphone@2x", 2, @"iphone",
                           @"device-scale", 2),
            MTLegacySuffix(@"@2x~iphone", 2, @"iphone",
                           @"scale-device", 3),
            MTLegacySuffix(@"~ipad@3x", 3, @"ipad",
                           @"device-scale", 4),
            MTLegacySuffix(@"@3x~ipad", 3, @"ipad",
                           @"scale-device", 5),
            MTLegacySuffix(@"~ipad@2x", 2, @"ipad",
                           @"device-scale", 6),
            MTLegacySuffix(@"@2x~ipad", 2, @"ipad",
                           @"scale-device", 7),
            MTLegacySuffix(@"@3x", 3, @"any", @"scale", 10),
            MTLegacySuffix(@"@2x", 2, @"any", @"scale", 11),
            MTLegacySuffix(@"~iphone", 0, @"iphone", @"device", 20),
            MTLegacySuffix(@"~ipad", 0, @"ipad", @"device", 21),
            MTLegacySuffix(@"", 0, @"any", @"plain", 30),
        ];
    });
    return suffixes;
}

static MTLegacyFilenameMapping *_Nullable MTLegacyParseFilename(
    NSString *filename) {
    if (![filename.lowercaseString hasSuffix:@".png"] ||
        filename.length <= 4) {
        return nil;
    }
    NSString *stem = [filename substringToIndex:filename.length - 4];
    if ([stem.lowercaseString hasSuffix:@".png"]) return nil;
    for (NSDictionary<NSString *, id> *rule in MTLegacySuffixes()) {
        NSString *suffix = rule[@"suffix"];
        if (suffix.length > 0 && ![stem hasSuffix:suffix]) continue;
        NSString *subject = suffix.length == 0
            ? stem : [stem substringToIndex:stem.length - suffix.length];
        if (subject.length == 0 ||
            [subject lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 192) {
            continue;
        }
        MTLegacyFilenameMapping *mapping =
            [[MTLegacyFilenameMapping alloc] init];
        mapping.subject = [subject precomposedStringWithCanonicalMapping];
        mapping.trait = rule[@"trait"];
        mapping.formatSuffix = rule[@"format"];
        mapping.scale = [rule[@"scale"] unsignedIntegerValue];
        mapping.matchRank = [rule[@"rank"] unsignedIntegerValue];
        return mapping;
    }
    return nil;
}

// SnowBoard's established SBBadgeBG name remains appearance-neutral. MarkTheme64e
// additionally accepts explicit Light/Dark stems so one authored style can
// carry separate artwork without turning those files into separate styles.
// Component names containing words such as "Dark" are deliberately not
// interpreted here: a component is a user-selectable style, not a system
// appearance declaration.
static NSString *_Nullable MTLegacyBadgeAppearanceForSubject(
    NSString *subject) {
    NSDictionary<NSString *, NSString *> *subjects = @{
        @"SBBadgeBG" : MTBadgeAppearanceAny,
        @"SBBadgeBGLight" : MTBadgeAppearanceLight,
        @"SBBadgeBG-light" : MTBadgeAppearanceLight,
        @"SBBadgeBG_light" : MTBadgeAppearanceLight,
        @"SBBadgeBGDark" : MTBadgeAppearanceDark,
        @"SBBadgeBG-dark" : MTBadgeAppearanceDark,
        @"SBBadgeBG_dark" : MTBadgeAppearanceDark,
    };
    return subjects[subject];
}

static BOOL MTLegacyFileHasPNGSignature(MTSourceFile *file) {
    static const unsigned char signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a
    };
    return file.prefixData.length >= sizeof(signature) &&
        memcmp(file.prefixData.bytes, signature, sizeof(signature)) == 0;
}

static MTDiagnostic *MTLegacyDiagnostic(
    MTDiagnosticSeverity severity,
    NSString *code,
    NSString *summary,
    MTResourceKey *_Nullable key,
    NSString *path) {
    return [[MTDiagnostic alloc] initWithSeverity:severity
                                             code:code
                                          summary:summary
                                      resourceKey:key
                                          details:@{ @"path" : path }
                                            error:NULL];
}

typedef NS_ENUM(NSUInteger, MTLegacyResourceFamily) {
    MTLegacyResourceFamilyNone = 0,
    MTLegacyResourceFamilyBadge,
    MTLegacyResourceFamilyDialer,
    MTLegacyResourceFamilyStatusBar,
    MTLegacyResourceFamilyIconShadow,
    MTLegacyResourceFamilyFolderIcon,
};

static MTLegacyResourceFamily MTLegacyClassifyPath(
    NSString *relativePath,
    NSString **filename) {
    NSArray<NSDictionary<NSString *, id> *> *rules = @[
        @{ @"prefix" : @"Bundles/com.apple.springboard/",
           @"family" : @(MTLegacyResourceFamilyBadge) },
        @{ @"prefix" : @"Bundles/com.apple.TelephonyUI/",
           @"family" : @(MTLegacyResourceFamilyDialer) },
        @{ @"prefix" : @"Bundles/com.apple.UI/",
           @"family" : @(MTLegacyResourceFamilyStatusBar) },
        @{ @"prefix" : @"Bundles/com.apple.UIKit/",
           @"family" : @(MTLegacyResourceFamilyStatusBar) },
        @{ @"prefix" : @"UIImages/",
           @"family" : @(MTLegacyResourceFamilyStatusBar) },
        @{ @"prefix" : @"AnemoneEffects/",
           @"family" : @(MTLegacyResourceFamilyIconShadow) },
    ];
    for (NSDictionary<NSString *, id> *rule in rules) {
        NSString *prefix = rule[@"prefix"];
        if (![relativePath.lowercaseString hasPrefix:prefix.lowercaseString] ||
            relativePath.length <= prefix.length) {
            continue;
        }
        NSString *remainder = [relativePath substringFromIndex:prefix.length];
        if ([remainder containsString:@"/"]) return MTLegacyResourceFamilyNone;
        if (filename != NULL) *filename = remainder;
        return [rule[@"family"] unsignedIntegerValue];
    }
    return MTLegacyResourceFamilyNone;
}

static NSString *MTLegacyModuleID(MTLegacyResourceFamily family) {
    switch (family) {
        case MTLegacyResourceFamilyBadge: return MTBadgesModuleID;
        case MTLegacyResourceFamilyDialer: return MTDialerModuleID;
        case MTLegacyResourceFamilyStatusBar: return MTStatusBarModuleID;
        case MTLegacyResourceFamilyIconShadow: return MTIconShadowsModuleID;
        case MTLegacyResourceFamilyFolderIcon: return MTFolderIconsModuleID;
        case MTLegacyResourceFamilyNone: return @"";
    }
    return @"";
}

static NSString *MTLegacySurface(MTLegacyResourceFamily family) {
    switch (family) {
        case MTLegacyResourceFamilyBadge: return MTBadgeSurface;
        case MTLegacyResourceFamilyDialer: return MTDialerSurface;
        case MTLegacyResourceFamilyStatusBar: return MTStatusBarSurface;
        case MTLegacyResourceFamilyIconShadow: return MTIconShadowSurface;
        case MTLegacyResourceFamilyFolderIcon: return MTFolderIconSurface;
        case MTLegacyResourceFamilyNone: return @"";
    }
    return @"";
}

static NSString *MTLegacyFamilyName(MTLegacyResourceFamily family) {
    switch (family) {
        case MTLegacyResourceFamilyBadge: return @"badge";
        case MTLegacyResourceFamilyDialer: return @"dialer";
        case MTLegacyResourceFamilyStatusBar: return @"statusbar";
        case MTLegacyResourceFamilyIconShadow: return @"icon-shadow";
        case MTLegacyResourceFamilyFolderIcon: return @"folder-icon";
        case MTLegacyResourceFamilyNone: return @"resource";
    }
    return @"resource";
}

@implementation MTLegacyThemeResourcesImporter

- (MTLegacyThemeResourcesImportResult *)
    importSourceInventory:(MTSourceInventory *)inventory
                    error:(NSError **)error {
    if (![inventory isKindOfClass:MTSourceInventory.class]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTLegacyThemeResourcesImporterErrorDomain
                           code:1
                       userInfo:@{ NSLocalizedDescriptionKey :
                            @"Legacy theme resources require an audited inventory." }];
        }
        return nil;
    }

    NSMutableArray<MTThemeResource *> *resources = [NSMutableArray array];
    NSMutableArray<MTDiagnostic *> *diagnostics = [NSMutableArray array];
    NSMutableSet<NSString *> *priorityIdentities = [NSMutableSet set];
    NSUInteger recognized = 0;
    NSUInteger rejected = 0;
    for (MTSourceFile *file in inventory.files) {
        MTThemeComponentPath *component = [MTThemeComponentPath
            pathWithLogicalRelativePath:file.relativePath];
        if (component == nil) continue;
        NSString *filename = nil;
        MTLegacyResourceFamily family = MTLegacyClassifyPath(
            component.relativePath, &filename);
        if (family == MTLegacyResourceFamilyNone) continue;
        MTLegacyFilenameMapping *mapping = MTLegacyParseFilename(filename);
        if (mapping == nil) {
            rejected += 1;
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.legacy-resource.unknown-name",
                @"A known SnowBoard component contains an unsupported PNG name.",
                nil, file.relativePath)];
            continue;
        }
        if (family == MTLegacyResourceFamilyIconShadow &&
            !MTIconShadowSubjectIsSupported(mapping.subject)) {
            rejected += 1;
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.icon-shadow.unsupported-subject",
                @"An AnemoneEffects PNG is not a supported icon shadow canvas.",
                nil, file.relativePath)];
            continue;
        }
        if (family == MTLegacyResourceFamilyStatusBar &&
            !MTStatusBarResourceSubjectIsSupported(mapping.subject)) {
            rejected += 1;
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.statusbar.unsupported-subject",
                @"A status-bar PNG is not a supported Wi-Fi or cellular level.",
                nil, file.relativePath)];
            continue;
        }
        NSString *badgeAppearance = family == MTLegacyResourceFamilyBadge
            ? MTLegacyBadgeAppearanceForSubject(mapping.subject) : nil;
        if (family == MTLegacyResourceFamilyBadge && badgeAppearance == nil) {
            if ([mapping.subject hasPrefix:@"FolderIconBG"]) {
                family = MTLegacyResourceFamilyFolderIcon;
            } else {
                continue;
            }
        }
        if (!MTLegacyFileHasPNGSignature(file)) {
            rejected += 1;
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityError,
                @"import.legacy-resource.invalid-png",
                @"A known SnowBoard component has no PNG signature.",
                nil, file.relativePath)];
            continue;
        }

        NSString *subject = mapping.subject;
        if (family == MTLegacyResourceFamilyBadge) {
            subject = MTBadgeGlobalSubject;
        } else if (family == MTLegacyResourceFamilyFolderIcon) {
            subject = MTFolderIconGlobalSubject;
        }
        NSString *variant = @"primary";
        if (family == MTLegacyResourceFamilyBadge ||
            family == MTLegacyResourceFamilyIconShadow) {
            variant = component.componentIdentifier;
        } else if (family == MTLegacyResourceFamilyFolderIcon) {
            variant = [mapping.subject.lowercaseString containsString:@"light"]
                ? MTFolderIconVariantBackgroundLight : MTFolderIconVariantBackground;
        }
        NSString *trait = mapping.trait;
        if (family == MTLegacyResourceFamilyBadge) {
            trait = MTBadgeResourceTrait(mapping.trait, badgeAppearance);
        }
        if (family == MTLegacyResourceFamilyIconShadow &&
            [trait isEqualToString:@"any"]) {
            if ([mapping.subject hasPrefix:@"iPhone"]) trait = @"iphone";
            if ([mapping.subject hasPrefix:@"iPad"]) trait = @"ipad";
        }
        NSError *resourceError = nil;
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:MTLegacyModuleID(family)
                     surface:MTLegacySurface(family)
                     subject:subject
                     variant:variant
                       scale:mapping.scale
                       trait:trait
                       error:&resourceError];
        NSString *sourceFormat = [NSString stringWithFormat:@"snowboard.%@.%@",
            MTLegacyFamilyName(family), mapping.formatSuffix];
        if (family == MTLegacyResourceFamilyBadge &&
            ![badgeAppearance isEqualToString:MTBadgeAppearanceAny]) {
            sourceFormat = [sourceFormat stringByAppendingFormat:@".%@",
                badgeAppearance];
        }
        MTThemeResource *resource = key == nil ? nil : [[MTThemeResource alloc]
            initWithResourceKey:key
               relativeAssetPath:file.relativePath
                   contentSHA256:file.contentSHA256
                    sourceFormat:sourceFormat
                       matchRank:mapping.matchRank
                           error:&resourceError];
        if (resource == nil) {
            rejected += 1;
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityError,
                @"import.legacy-resource.invalid-resource",
                resourceError.localizedDescription ?:
                    @"A known SnowBoard component could not form a canonical resource.",
                key, file.relativePath)];
            continue;
        }
        NSString *priorityIdentity = [NSString stringWithFormat:@"%@\x1f%lu",
            key.canonicalString, (unsigned long)mapping.matchRank];
        if ([priorityIdentities containsObject:priorityIdentity]) {
            [diagnostics addObject:MTLegacyDiagnostic(
                MTDiagnosticSeverityWarning,
                @"import.legacy-resource.duplicate-priority",
                @"Multiple component images have the same semantic priority.",
                key, file.relativePath)];
        }
        [priorityIdentities addObject:priorityIdentity];
        [resources addObject:resource];
        recognized += 1;
    }
    return [[MTLegacyThemeResourcesImportResult alloc]
        initWithResources:resources
        diagnostics:diagnostics
        recognizedFileCount:recognized
        rejectedFileCount:rejected];
}

@end
