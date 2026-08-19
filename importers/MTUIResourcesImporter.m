#import "MTUIResourcesImporter.h"

#import <string.h>

#import "MTDiagnostic.h"
#import "MTResourceKey.h"
#import "MTSourceInventory.h"
#import "MTThemeComponentPath.h"
#import "MTThemeManifest.h"
#import "MTUIResourcesModule.h"

NSString *const MTUIResourcesImporterErrorDomain =
    @"com.hmmzzz.marktheme.ui-resources-importer";

@interface MTUIResourcesImportResult ()
- (instancetype)initWithResources:(NSArray<MTThemeResource *> *)resources
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics
              recognizedFileCount:(NSUInteger)recognizedFileCount
                 rejectedFileCount:(NSUInteger)rejectedFileCount;
@end

@implementation MTUIResourcesImportResult

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

@interface MTUIResourceFilenameMapping : NSObject
@property(nonatomic, copy) NSString *resourceName;
@property(nonatomic, copy) NSString *trait;
@property(nonatomic, copy) NSString *sourceFormat;
@property(nonatomic, assign) NSUInteger scale;
@property(nonatomic, assign) NSUInteger matchRank;
@end

@implementation MTUIResourceFilenameMapping
@end

@interface MTUIResourceBundleMapping : NSObject
@property(nonatomic, copy) NSString *surface;
@property(nonatomic, copy) NSString *formatFamily;
@property(nonatomic, copy) NSString *diagnosticFamily;
@property(nonatomic, assign) NSUInteger rank;
@end

@implementation MTUIResourceBundleMapping
@end

static MTUIResourceBundleMapping *MTUIResourceBundle(
    NSString *surface,
    NSString *formatFamily,
    NSString *diagnosticFamily,
    NSUInteger rank) {
    MTUIResourceBundleMapping *mapping =
        [[MTUIResourceBundleMapping alloc] init];
    mapping.surface = surface;
    mapping.formatFamily = formatFamily;
    mapping.diagnosticFamily = diagnosticFamily;
    mapping.rank = rank;
    return mapping;
}

static NSDictionary<NSString *, MTUIResourceBundleMapping *> *
    MTUIResourceBundles(void) {
    static NSDictionary<NSString *, MTUIResourceBundleMapping *> *bundles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundles = @{
            @"com.apple.Preferences" : MTUIResourceBundle(
                @"preferences.icon", @"settings", @"settings", 0),
            @"com.apple.preferences-framework" : MTUIResourceBundle(
                @"preferences.icon", @"settings", @"settings", 100),
            @"com.apple.preferences-ui-framework" : MTUIResourceBundle(
                @"preferences.icon", @"settings", @"settings", 200),
            @"com.apple.SharingUIService" : MTUIResourceBundle(
                @"share.activity", @"share", @"share", 0),
        };
    });
    return bundles;
}

BOOL MTUIResourceBundleIsSupported(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:NSString.class]) return NO;
    for (NSString *candidate in MTUIResourceBundles()) {
        if ([candidate caseInsensitiveCompare:bundleIdentifier] ==
                NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, id> *MTUIResourceSuffix(
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

static NSArray<NSDictionary<NSString *, id> *> *MTUIResourceSuffixes(void) {
    static NSArray<NSDictionary<NSString *, id> *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            MTUIResourceSuffix(@"~iphone@3x", 3, @"iphone",
                @"device-scale", 0),
            MTUIResourceSuffix(@"@3x~iphone", 3, @"iphone",
                @"scale-device", 1),
            MTUIResourceSuffix(@"~iphone@2x", 2, @"iphone",
                @"device-scale", 2),
            MTUIResourceSuffix(@"@2x~iphone", 2, @"iphone",
                @"scale-device", 3),
            MTUIResourceSuffix(@"~ipad@3x", 3, @"ipad",
                @"device-scale", 4),
            MTUIResourceSuffix(@"@3x~ipad", 3, @"ipad",
                @"scale-device", 5),
            MTUIResourceSuffix(@"~ipad@2x", 2, @"ipad",
                @"device-scale", 6),
            MTUIResourceSuffix(@"@2x~ipad", 2, @"ipad",
                @"scale-device", 7),
            MTUIResourceSuffix(@"@3x", 3, @"any",
                @"scale", 10),
            MTUIResourceSuffix(@"@2x", 2, @"any",
                @"scale", 11),
            MTUIResourceSuffix(@"~iphone", 0, @"iphone",
                @"device", 20),
            MTUIResourceSuffix(@"~ipad", 0, @"ipad",
                @"device", 21),
            MTUIResourceSuffix(@"-large", 0, @"any",
                @"large", 30),
            MTUIResourceSuffix(@"", 0, @"any",
                @"plain", 40),
        ];
    });
    return suffixes;
}

static BOOL MTUIResourceNameIsSafe(NSString *name) {
    NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding
                      allowLossyConversion:NO];
    if (utf8.length == 0 || utf8.length > 192) return NO;
    for (NSUInteger index = 0; index < name.length; index++) {
        unichar character = [name characterAtIndex:index];
        if (character == 0 || character == '/' || character == '\\' ||
            character < 0x20 || character == 0x7f) {
            return NO;
        }
    }
    return YES;
}

static MTUIResourceFilenameMapping *_Nullable MTUIResourceParseFilename(
    NSString *filename,
    MTUIResourceBundleMapping *bundle) {
    if (![filename hasSuffix:@".png"] || filename.length <= 4) return nil;
    NSString *stem = [filename substringToIndex:filename.length - 4];
    for (NSDictionary<NSString *, id> *rule in MTUIResourceSuffixes()) {
        NSString *suffix = rule[@"suffix"];
        if (suffix.length > 0 && ![stem hasSuffix:suffix]) continue;
        NSString *resourceName = suffix.length == 0
            ? stem
            : [stem substringToIndex:stem.length - suffix.length];
        if (!MTUIResourceNameIsSafe(resourceName)) continue;
        MTUIResourceFilenameMapping *mapping =
            [[MTUIResourceFilenameMapping alloc] init];
        mapping.resourceName =
            [resourceName precomposedStringWithCanonicalMapping];
        mapping.scale = [rule[@"scale"] unsignedIntegerValue];
        mapping.trait = rule[@"trait"];
        mapping.sourceFormat = [NSString stringWithFormat:@"snowboard.%@.%@",
            bundle.formatFamily, rule[@"format"]];
        mapping.matchRank = bundle.rank +
            [rule[@"rank"] unsignedIntegerValue];
        return mapping;
    }
    return nil;
}

static BOOL MTUIResourceFileHasPNGSignature(MTSourceFile *file) {
    static const unsigned char signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a
    };
    return file.prefixData.length >= sizeof(signature) &&
        memcmp(file.prefixData.bytes, signature, sizeof(signature)) == 0;
}

static MTDiagnostic *MTUIResourceDiagnostic(
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

@implementation MTUIResourcesImporter

- (MTUIResourcesImportResult *)importSourceInventory:
    (MTSourceInventory *)inventory
                                                     error:(NSError **)error {
    if (![inventory isKindOfClass:MTSourceInventory.class]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTUIResourcesImporterErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"UI resource import requires an audited source inventory."
            }];
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
        NSString *logicalPath = component.relativePath;
        if (![logicalPath hasPrefix:@"Bundles/"]) continue;
        NSString *remainder = [logicalPath
            substringFromIndex:@"Bundles/".length];
        NSRange separator = [remainder rangeOfString:@"/"];
        if (separator.location == NSNotFound) continue;
        NSString *bundleIdentifier = [remainder
            substringToIndex:separator.location];
        MTUIResourceBundleMapping *bundle =
            MTUIResourceBundles()[bundleIdentifier];
        if (bundle == nil) continue;
        NSString *filename = [remainder
            substringFromIndex:NSMaxRange(separator)];
        if ([filename containsString:@"/"]) {
            rejected++;
            BOOL settings = [bundle.diagnosticFamily
                isEqualToString:@"settings"];
            [diagnostics addObject:MTUIResourceDiagnostic(
                MTDiagnosticSeverityWarning,
                settings
                    ? @"import.ui-resources.nested-settings-file"
                    : @"import.ui-resources.nested-share-file",
                settings
                    ? @"Settings UI image is nested below the supported bundle level."
                    : @"Share activity image is nested below the supported bundle level.",
                nil, file.relativePath)];
            continue;
        }
        MTUIResourceFilenameMapping *mapping = MTUIResourceParseFilename(
            filename, bundle);
        if (mapping == nil) {
            rejected++;
            BOOL settings = [bundle.diagnosticFamily
                isEqualToString:@"settings"];
            [diagnostics addObject:MTUIResourceDiagnostic(
                MTDiagnosticSeverityWarning,
                settings
                    ? @"import.ui-resources.unknown-settings-name"
                    : @"import.ui-resources.unknown-share-name",
                settings
                    ? @"Settings UI filename is outside the supported PNG forms."
                    : @"Share activity filename is outside the supported PNG forms.",
                nil, file.relativePath)];
            continue;
        }
        if (!MTUIResourceFileHasPNGSignature(file)) {
            rejected++;
            BOOL settings = [bundle.diagnosticFamily
                isEqualToString:@"settings"];
            [diagnostics addObject:MTUIResourceDiagnostic(
                MTDiagnosticSeverityError,
                settings
                    ? @"import.ui-resources.invalid-settings-png"
                    : @"import.ui-resources.invalid-share-png",
                settings
                    ? @"Settings UI image has a PNG name but no PNG signature."
                    : @"Share activity image has a PNG name but no PNG signature.",
                nil, file.relativePath)];
            continue;
        }

        NSError *resourceError = nil;
        MTResourceKey *key = [[MTResourceKey alloc]
            initWithModuleID:MTUIResourcesModuleID
                     surface:bundle.surface
                     subject:mapping.resourceName
                     variant:@"primary"
                       scale:mapping.scale
                       trait:mapping.trait
                       error:&resourceError];
        MTThemeResource *resource = key == nil ? nil : [[MTThemeResource alloc]
            initWithResourceKey:key
               relativeAssetPath:file.relativePath
                   contentSHA256:file.contentSHA256
                    sourceFormat:mapping.sourceFormat
                       matchRank:mapping.matchRank
                           error:&resourceError];
        if (resource == nil) {
            rejected++;
            BOOL settings = [bundle.diagnosticFamily
                isEqualToString:@"settings"];
            [diagnostics addObject:MTUIResourceDiagnostic(
                MTDiagnosticSeverityError,
                settings
                    ? @"import.ui-resources.invalid-settings-resource"
                    : @"import.ui-resources.invalid-share-resource",
                resourceError.localizedDescription ?:
                    (settings
                        ? @"Settings UI resource is invalid."
                        : @"Share activity resource is invalid."),
                key, file.relativePath)];
            continue;
        }
        NSString *priorityIdentity = [NSString stringWithFormat:@"%@\x1f%lu",
            key.canonicalString, (unsigned long)mapping.matchRank];
        if ([priorityIdentities containsObject:priorityIdentity]) {
            BOOL settings = [bundle.diagnosticFamily
                isEqualToString:@"settings"];
            [diagnostics addObject:MTUIResourceDiagnostic(
                MTDiagnosticSeverityWarning,
                settings
                    ? @"import.ui-resources.duplicate-settings-priority"
                    : @"import.ui-resources.duplicate-share-priority",
                settings
                    ? @"Multiple Settings images have the same semantic priority."
                    : @"Multiple Share activity images have the same semantic priority.",
                key, file.relativePath)];
        }
        [priorityIdentities addObject:priorityIdentity];
        [resources addObject:resource];
        recognized++;
    }

    return [[MTUIResourcesImportResult alloc]
        initWithResources:resources
               diagnostics:diagnostics
      recognizedFileCount:recognized
         rejectedFileCount:rejected];
}

@end
