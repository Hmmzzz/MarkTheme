#import "MTThemeComponentCatalog.h"

#import "MTBadgeConfiguration.h"
#import "MTIconShadowConfiguration.h"
#import "MTBadgesModule.h"
#import "MTIconShadowsModule.h"
#import "MTIdentifier.h"
#import "MTResourceKey.h"
#import "MTThemeComponentPath.h"
#import "MTThemeManifest.h"

NSString *const MTThemeComponentCatalogErrorDomain =
    @"com.hmmzzz.marktheme64e.theme-component-catalog";
NSUInteger const MTThemeComponentSelectionSchemaVersion = 1;

static void MTThemeComponentSetError(NSError **error,
                                     NSInteger code,
                                     NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTThemeComponentCatalogErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

static NSString *MTThemeComponentDisplayName(NSString *_Nullable name,
                                             NSString *fallback) {
    if (name.length == 0) return fallback;
    NSString *displayName = [name precomposedStringWithCanonicalMapping];
    if ([displayName.lowercaseString hasSuffix:@".theme"] &&
        displayName.length > 6) {
        displayName = [displayName substringToIndex:displayName.length - 6];
    }
    return displayName.length > 0 ? displayName : fallback;
}

@interface MTThemeComponentDescriptor ()
@property(nonatomic, copy, readwrite) NSString *componentIdentifier;
@property(nonatomic, copy, readwrite) NSString *displayName;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *moduleIDs;
@property(nonatomic, assign, readwrite) NSUInteger resourceCount;
@property(nonatomic, assign, readwrite, getter=isRequired) BOOL required;
- (instancetype)initWithIdentifier:(NSString *)identifier
                         displayName:(NSString *)displayName
                           moduleIDs:(NSArray<NSString *> *)moduleIDs
                       resourceCount:(NSUInteger)resourceCount
                            required:(BOOL)required;
@end

@implementation MTThemeComponentDescriptor
- (instancetype)initWithIdentifier:(NSString *)identifier
                         displayName:(NSString *)displayName
                           moduleIDs:(NSArray<NSString *> *)moduleIDs
                       resourceCount:(NSUInteger)resourceCount
                            required:(BOOL)required {
    self = [super init];
    if (self == nil) return nil;
    _componentIdentifier = [identifier copy];
    _displayName = [displayName copy];
    _moduleIDs = [moduleIDs copy];
    _resourceCount = resourceCount;
    _required = required;
    return self;
}
@end

@interface MTThemeVariantOption ()
@property(nonatomic, copy, readwrite) NSString *variantIdentifier;
@property(nonatomic, copy, readwrite) NSString *displayName;
@property(nonatomic, copy, readwrite) NSString *componentIdentifier;
@property(nonatomic, assign, readwrite) NSUInteger resourceCount;
- (instancetype)initWithIdentifier:(NSString *)identifier
                         displayName:(NSString *)displayName
                 componentIdentifier:(NSString *)componentIdentifier
                       resourceCount:(NSUInteger)resourceCount;
@end

@implementation MTThemeVariantOption
- (instancetype)initWithIdentifier:(NSString *)identifier
                         displayName:(NSString *)displayName
                 componentIdentifier:(NSString *)componentIdentifier
                       resourceCount:(NSUInteger)resourceCount {
    self = [super init];
    if (self == nil) return nil;
    _variantIdentifier = [identifier copy];
    _displayName = [displayName copy];
    _componentIdentifier = [componentIdentifier copy];
    _resourceCount = resourceCount;
    return self;
}
@end

@interface MTThemeVariantGroup ()
@property(nonatomic, copy, readwrite) NSString *groupIdentifier;
@property(nonatomic, copy, readwrite) NSArray<MTThemeVariantOption *> *options;
@property(nonatomic, copy, readwrite) NSString *defaultVariantIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeVariantOption *> *optionIndex;
- (instancetype)initWithIdentifier:(NSString *)identifier
                            options:(NSArray<MTThemeVariantOption *> *)options
           defaultVariantIdentifier:(NSString *)defaultVariantIdentifier;
@end

@implementation MTThemeVariantGroup
- (instancetype)initWithIdentifier:(NSString *)identifier
                            options:(NSArray<MTThemeVariantOption *> *)options
           defaultVariantIdentifier:(NSString *)defaultVariantIdentifier {
    self = [super init];
    if (self == nil) return nil;
    NSMutableDictionary *index = [NSMutableDictionary
        dictionaryWithCapacity:options.count];
    for (MTThemeVariantOption *option in options) {
        index[option.variantIdentifier] = option;
    }
    _groupIdentifier = [identifier copy];
    _options = [options copy];
    _defaultVariantIdentifier = [defaultVariantIdentifier copy];
    _optionIndex = [index copy];
    return self;
}

- (MTThemeVariantOption *)optionWithIdentifier:(NSString *)variantIdentifier {
    return self.optionIndex[variantIdentifier];
}
@end

@interface MTThemeComponentAccumulator : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, strong) NSMutableSet<NSString *> *moduleIDs;
@property(nonatomic, assign) NSUInteger resourceCount;
@end

@implementation MTThemeComponentAccumulator
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _moduleIDs = [NSMutableSet set];
    return self;
}
@end

@interface MTThemeVariantAccumulator : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *componentIdentifier;
@property(nonatomic, assign) NSUInteger resourceCount;
@end

@implementation MTThemeVariantAccumulator
@end

@interface MTThemeComponentCatalog ()
@property(nonatomic, copy, readwrite) NSString *themeIdentifier;
@property(nonatomic, copy, readwrite) NSString *manifestDigest;
@property(nonatomic, copy, readwrite)
    NSArray<MTThemeComponentDescriptor *> *components;
@property(nonatomic, copy, readwrite)
    NSArray<MTThemeVariantGroup *> *variantGroups;
@property(nonatomic, strong, readwrite)
    MTThemeComponentSelection *defaultSelection;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeComponentDescriptor *> *componentIndex;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeVariantGroup *> *variantGroupIndex;
- (instancetype)initPrivate;
@end

@interface MTThemeComponentSelection ()
@property(nonatomic, copy, readwrite) NSString *manifestDigest;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *enabledComponentIDs;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSString *> *selectedVariantsByGroup;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, id> *canonicalDictionary;
- (instancetype)initWithManifestDigest:(NSString *)manifestDigest
                   enabledComponentIDs:(NSArray<NSString *> *)enabledComponentIDs
               selectedVariantsByGroup:
                   (NSDictionary<NSString *, NSString *> *)selectedVariants;
@end

static NSSet<NSString *> *MTThemeExclusiveVariantModuleIDs(void) {
    static NSSet<NSString *> *moduleIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        moduleIDs = [NSSet setWithObjects:
            MTBadgesModuleID, MTIconShadowsModuleID, nil];
    });
    return moduleIDs;
}

static MTThemeComponentPath *_Nullable MTThemeComponentPathForResource(
    MTThemeResource *resource) {
    return [MTThemeComponentPath
        pathWithLogicalRelativePath:resource.relativeAssetPath];
}

@implementation MTThemeComponentCatalog

+ (instancetype)catalogForManifest:(MTThemeManifest *)manifest
                               error:(NSError **)error {
    if (![manifest isKindOfClass:MTThemeManifest.class]) {
        MTThemeComponentSetError(error, 1,
            @"A component catalog requires one canonical Theme Manifest.");
        return nil;
    }
    NSError *digestError = nil;
    NSString *manifestDigest = [manifest contentDigestWithError:&digestError];
    if (manifestDigest == nil) {
        if (error != NULL) *error = digestError;
        return nil;
    }

    NSSet<NSString *> *exclusiveModules =
        MTThemeExclusiveVariantModuleIDs();
    NSMutableDictionary<NSString *, MTThemeComponentAccumulator *> *components =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *,
        MTThemeVariantAccumulator *> *> *variantsByModule =
            [NSMutableDictionary dictionary];

    for (MTThemeResource *resource in manifest.resources) {
        MTThemeComponentPath *path = MTThemeComponentPathForResource(resource);
        if (path == nil) {
            MTThemeComponentSetError(error, 2,
                @"A Theme resource has no canonical component path.");
            return nil;
        }
        NSString *componentID = path.componentIdentifier;
        NSString *displayName = MTThemeComponentDisplayName(
            path.componentName, manifest.displayName);
        NSString *moduleID = resource.resourceKey.moduleID;
        if ([exclusiveModules containsObject:moduleID]) {
            NSMutableDictionary<NSString *, MTThemeVariantAccumulator *> *byID =
                variantsByModule[moduleID];
            if (byID == nil) {
                byID = [NSMutableDictionary dictionary];
                variantsByModule[moduleID] = byID;
            }
            NSString *variantID = resource.resourceKey.variant;
            MTThemeVariantAccumulator *variant = byID[variantID];
            if (variant == nil) {
                variant = [[MTThemeVariantAccumulator alloc] init];
                variant.identifier = variantID;
                variant.displayName = displayName;
                variant.componentIdentifier = componentID;
                byID[variantID] = variant;
            } else if ([displayName compare:variant.displayName
                                    options:NSLiteralSearch] ==
                       NSOrderedAscending) {
                variant.displayName = displayName;
                variant.componentIdentifier = componentID;
            }
            variant.resourceCount += 1;
            continue;
        }

        MTThemeComponentAccumulator *component = components[componentID];
        if (component == nil) {
            component = [[MTThemeComponentAccumulator alloc] init];
            component.identifier = componentID;
            component.displayName = displayName;
            components[componentID] = component;
        }
        [component.moduleIDs addObject:moduleID];
        component.resourceCount += 1;
    }

    MTThemeComponentAccumulator *primary = components[@"primary"];
    if (primary == nil) {
        primary = [[MTThemeComponentAccumulator alloc] init];
        primary.identifier = @"primary";
        primary.displayName = manifest.displayName;
        components[@"primary"] = primary;
    }
    NSSet<NSString *> *resourceModuleIDs = [NSSet setWithArray:
        [manifest.resources valueForKeyPath:@"resourceKey.moduleID"]];
    for (NSString *moduleID in manifest.capabilities) {
        if (![resourceModuleIDs containsObject:moduleID] &&
            ![exclusiveModules containsObject:moduleID]) {
            [primary.moduleIDs addObject:moduleID];
        }
    }

    NSMutableArray<MTThemeComponentDescriptor *> *componentDescriptors =
        [NSMutableArray arrayWithCapacity:components.count];
    NSArray<MTThemeComponentAccumulator *> *sortedComponents =
        [components.allValues sortedArrayUsingComparator:
            ^NSComparisonResult(MTThemeComponentAccumulator *left,
                                MTThemeComponentAccumulator *right) {
        BOOL leftPrimary = [left.identifier isEqualToString:@"primary"];
        BOOL rightPrimary = [right.identifier isEqualToString:@"primary"];
        if (leftPrimary != rightPrimary) {
            return leftPrimary ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.identifier compare:right.identifier
                                  options:NSLiteralSearch];
    }];
    for (MTThemeComponentAccumulator *component in sortedComponents) {
        NSArray<NSString *> *moduleIDs = [component.moduleIDs.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        [componentDescriptors addObject:[[MTThemeComponentDescriptor alloc]
            initWithIdentifier:component.identifier
            displayName:component.displayName
            moduleIDs:moduleIDs
            resourceCount:component.resourceCount
            required:[component.identifier isEqualToString:@"primary"]]];
    }

    NSMutableArray<MTThemeVariantGroup *> *variantGroups =
        [NSMutableArray arrayWithCapacity:variantsByModule.count];
    NSArray<NSString *> *sortedGroupIDs = [variantsByModule.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *groupID in sortedGroupIDs) {
        NSDictionary<NSString *, MTThemeVariantAccumulator *> *byID =
            variantsByModule[groupID];
        NSArray<NSString *> *sortedVariantIDs = [byID.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray<MTThemeVariantOption *> *options =
            [NSMutableArray arrayWithCapacity:sortedVariantIDs.count];
        for (NSString *variantID in sortedVariantIDs) {
            MTThemeVariantAccumulator *variant = byID[variantID];
            [options addObject:[[MTThemeVariantOption alloc]
                initWithIdentifier:variant.identifier
                displayName:variant.displayName
                componentIdentifier:variant.componentIdentifier
                resourceCount:variant.resourceCount]];
        }
        NSString *defaultVariant = sortedVariantIDs.firstObject;
        if ([groupID isEqualToString:MTBadgesModuleID]) {
            MTBadgeConfiguration *badge = [[MTBadgeConfiguration alloc]
                initWithDictionary:
                    manifest.moduleConfigurations[MTBadgesModuleID]
                error:NULL];
            if ([byID objectForKey:badge.defaultVariant] != nil) {
                defaultVariant = badge.defaultVariant;
            }
        } else if ([groupID isEqualToString:MTIconShadowsModuleID]) {
            MTIconShadowConfiguration *shadow =
                [[MTIconShadowConfiguration alloc]
                    initWithDictionary:
                        manifest.moduleConfigurations[MTIconShadowsModuleID]
                    error:NULL];
            if ([byID objectForKey:shadow.defaultVariant] != nil) {
                defaultVariant = shadow.defaultVariant;
            }
        }
        if (defaultVariant.length == 0) continue;
        [variantGroups addObject:[[MTThemeVariantGroup alloc]
            initWithIdentifier:groupID
            options:options
            defaultVariantIdentifier:defaultVariant]];
    }

    MTThemeComponentCatalog *catalog = [[self alloc] initPrivate];
    catalog.themeIdentifier = manifest.themeID;
    catalog.manifestDigest = manifestDigest;
    catalog.components = componentDescriptors;
    catalog.variantGroups = variantGroups;
    NSMutableDictionary *componentIndex = [NSMutableDictionary dictionary];
    for (MTThemeComponentDescriptor *component in componentDescriptors) {
        componentIndex[component.componentIdentifier] = component;
    }
    NSMutableDictionary *groupIndex = [NSMutableDictionary dictionary];
    for (MTThemeVariantGroup *group in variantGroups) {
        groupIndex[group.groupIdentifier] = group;
    }
    catalog.componentIndex = componentIndex;
    catalog.variantGroupIndex = groupIndex;

    NSMutableArray<NSString *> *enabled = [NSMutableArray array];
    for (MTThemeComponentDescriptor *component in componentDescriptors) {
        [enabled addObject:component.componentIdentifier];
    }
    NSMutableDictionary<NSString *, NSString *> *selected =
        [NSMutableDictionary dictionary];
    for (MTThemeVariantGroup *group in variantGroups) {
        selected[group.groupIdentifier] = group.defaultVariantIdentifier;
    }
    catalog.defaultSelection = [[MTThemeComponentSelection alloc]
        initWithManifestDigest:manifestDigest
        enabledComponentIDs:enabled
        selectedVariantsByGroup:selected];
    return catalog;
}

- (instancetype)initPrivate {
    return [super init];
}

- (MTThemeComponentDescriptor *)componentWithIdentifier:
        (NSString *)componentIdentifier {
    return self.componentIndex[componentIdentifier];
}

- (MTThemeVariantGroup *)variantGroupWithIdentifier:
        (NSString *)groupIdentifier {
    return self.variantGroupIndex[groupIdentifier];
}

- (MTThemeVariantGroup *)variantGroupForModuleIdentifier:
        (NSString *)moduleIdentifier {
    return self.variantGroupIndex[moduleIdentifier];
}

- (NSString *)componentIdentifierForResource:(MTThemeResource *)resource {
    return MTThemeComponentPathForResource(resource).componentIdentifier;
}

@end

static BOOL MTThemeSelectionDictionaryHasExactKeys(
    NSDictionary *dictionary,
    NSArray<NSString *> *keys) {
    return [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

static NSArray<NSString *> *_Nullable MTThemeSelectionEnabledComponents(
    id value,
    MTThemeComponentCatalog *catalog,
    BOOL requireAllRequired) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id candidate in value) {
        if (![candidate isKindOfClass:NSString.class] ||
            [catalog componentWithIdentifier:candidate] == nil ||
            [seen containsObject:candidate]) {
            return nil;
        }
        [seen addObject:candidate];
    }
    if (requireAllRequired) {
        for (MTThemeComponentDescriptor *component in catalog.components) {
            if (component.isRequired &&
                ![seen containsObject:component.componentIdentifier]) {
                return nil;
            }
        }
    }
    return [seen.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary<NSString *, NSString *> *_Nullable
MTThemeSelectionSelectedVariants(id value,
                                 MTThemeComponentCatalog *catalog,
                                 BOOL requireEveryGroup) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dictionary = value;
    NSMutableDictionary<NSString *, NSString *> *selected =
        [NSMutableDictionary dictionary];
    for (id rawGroupID in dictionary) {
        id rawVariantID = dictionary[rawGroupID];
        if (![rawGroupID isKindOfClass:NSString.class] ||
            ![rawVariantID isKindOfClass:NSString.class]) {
            return nil;
        }
        MTThemeVariantGroup *group = [catalog
            variantGroupWithIdentifier:rawGroupID];
        if (group == nil || [group optionWithIdentifier:rawVariantID] == nil) {
            return nil;
        }
        selected[rawGroupID] = rawVariantID;
    }
    if (requireEveryGroup && selected.count != catalog.variantGroups.count) {
        return nil;
    }
    return [selected copy];
}

@implementation MTThemeComponentSelection

- (instancetype)initWithManifestDigest:(NSString *)manifestDigest
                   enabledComponentIDs:(NSArray<NSString *> *)enabledComponentIDs
               selectedVariantsByGroup:
                   (NSDictionary<NSString *,NSString *> *)selectedVariants {
    self = [super init];
    if (self == nil) return nil;
    _manifestDigest = [manifestDigest copy];
    _enabledComponentIDs = [[enabledComponentIDs
        sortedArrayUsingSelector:@selector(compare:)] copy];
    _selectedVariantsByGroup = [selectedVariants copy];
    _canonicalDictionary = @{
        @"enabledComponents" : _enabledComponentIDs,
        @"manifestDigest" : _manifestDigest,
        @"schemaVersion" : @(MTThemeComponentSelectionSchemaVersion),
        @"selectedVariants" : _selectedVariantsByGroup,
    };
    return self;
}

+ (instancetype)selectionForCatalog:(MTThemeComponentCatalog *)catalog
                 canonicalDictionary:(NSDictionary<NSString *,id> *)dictionary
                               error:(NSError **)error {
    if (![catalog isKindOfClass:MTThemeComponentCatalog.class] ||
        !MTThemeSelectionDictionaryHasExactKeys(dictionary, @[
            @"enabledComponents", @"manifestDigest", @"schemaVersion",
            @"selectedVariants",
        ]) ||
        ![dictionary[@"schemaVersion"]
            isEqual:@(MTThemeComponentSelectionSchemaVersion)] ||
        ![dictionary[@"manifestDigest"]
            isEqualToString:catalog.manifestDigest]) {
        MTThemeComponentSetError(error, 3,
            @"Theme component selection identity is invalid.");
        return nil;
    }
    NSArray<NSString *> *enabled = MTThemeSelectionEnabledComponents(
        dictionary[@"enabledComponents"], catalog, YES);
    NSDictionary<NSString *, NSString *> *selected =
        MTThemeSelectionSelectedVariants(
            dictionary[@"selectedVariants"], catalog, YES);
    if (enabled == nil || selected == nil) {
        MTThemeComponentSetError(error, 4,
            @"Theme component selection contains an unknown or incomplete choice.");
        return nil;
    }
    return [[self alloc]
        initWithManifestDigest:catalog.manifestDigest
        enabledComponentIDs:enabled
        selectedVariantsByGroup:selected];
}

+ (instancetype)selectionByNormalizingDictionary:
        (NSDictionary<NSString *,id> *)dictionary
                                         catalog:
                                             (MTThemeComponentCatalog *)catalog {
    MTThemeComponentSelection *strict = [self selectionForCatalog:catalog
        canonicalDictionary:dictionary error:NULL];
    if (strict != nil) return strict;

    NSMutableSet<NSString *> *enabled = [NSMutableSet set];
    id rawEnabled = [dictionary isKindOfClass:NSDictionary.class]
        ? dictionary[@"enabledComponents"] : nil;
    if ([rawEnabled isKindOfClass:NSArray.class]) {
        for (id candidate in rawEnabled) {
            if ([candidate isKindOfClass:NSString.class] &&
                [catalog componentWithIdentifier:candidate] != nil) {
                [enabled addObject:candidate];
            }
        }
    } else {
        [enabled addObjectsFromArray:
            catalog.defaultSelection.enabledComponentIDs];
    }
    for (MTThemeComponentDescriptor *component in catalog.components) {
        if (component.isRequired) {
            [enabled addObject:component.componentIdentifier];
        }
    }

    NSMutableDictionary<NSString *, NSString *> *selected =
        [catalog.defaultSelection.selectedVariantsByGroup mutableCopy];
    id rawSelected = [dictionary isKindOfClass:NSDictionary.class]
        ? dictionary[@"selectedVariants"] : nil;
    if ([rawSelected isKindOfClass:NSDictionary.class]) {
        for (id rawGroupID in (NSDictionary *)rawSelected) {
            id rawVariantID = rawSelected[rawGroupID];
            MTThemeVariantGroup *group =
                [rawGroupID isKindOfClass:NSString.class]
                ? [catalog variantGroupWithIdentifier:rawGroupID] : nil;
            if ([rawVariantID isKindOfClass:NSString.class] &&
                [group optionWithIdentifier:rawVariantID] != nil) {
                selected[rawGroupID] = rawVariantID;
            }
        }
    }
    return [[self alloc]
        initWithManifestDigest:catalog.manifestDigest
        enabledComponentIDs:enabled.allObjects
        selectedVariantsByGroup:selected];
}

- (BOOL)isComponentEnabled:(NSString *)componentIdentifier {
    return [self.enabledComponentIDs containsObject:componentIdentifier];
}

- (NSString *)selectedVariantForGroup:(NSString *)groupIdentifier {
    return self.selectedVariantsByGroup[groupIdentifier];
}

- (instancetype)selectionBySettingComponentIdentifier:
        (NSString *)componentIdentifier
                                                enabled:(BOOL)enabled
                                                catalog:
                                                    (MTThemeComponentCatalog *)catalog
                                                  error:(NSError **)error {
    MTThemeComponentDescriptor *component = [catalog
        componentWithIdentifier:componentIdentifier];
    if (component == nil ||
        ![self.manifestDigest isEqualToString:catalog.manifestDigest] ||
        (component.isRequired && !enabled)) {
        MTThemeComponentSetError(error, 5,
            @"The requested component state is not selectable.");
        return nil;
    }
    NSMutableSet<NSString *> *components =
        [NSMutableSet setWithArray:self.enabledComponentIDs];
    if (enabled) {
        [components addObject:componentIdentifier];
    } else {
        [components removeObject:componentIdentifier];
    }
    NSDictionary *dictionary = @{
        @"enabledComponents" : components.allObjects,
        @"manifestDigest" : catalog.manifestDigest,
        @"schemaVersion" : @(MTThemeComponentSelectionSchemaVersion),
        @"selectedVariants" : self.selectedVariantsByGroup,
    };
    return [MTThemeComponentSelection selectionForCatalog:catalog
        canonicalDictionary:dictionary error:error];
}

- (instancetype)selectionBySelectingVariantIdentifier:
        (NSString *)variantIdentifier
                                           forGroupIdentifier:
                                               (NSString *)groupIdentifier
                                                        catalog:
                                                            (MTThemeComponentCatalog *)catalog
                                                          error:(NSError **)error {
    MTThemeVariantGroup *group = [catalog
        variantGroupWithIdentifier:groupIdentifier];
    if (![self.manifestDigest isEqualToString:catalog.manifestDigest] ||
        [group optionWithIdentifier:variantIdentifier] == nil) {
        MTThemeComponentSetError(error, 6,
            @"The requested authored variant is unavailable.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *selected =
        [self.selectedVariantsByGroup mutableCopy];
    selected[groupIdentifier] = variantIdentifier;
    NSDictionary *dictionary = @{
        @"enabledComponents" : self.enabledComponentIDs,
        @"manifestDigest" : catalog.manifestDigest,
        @"schemaVersion" : @(MTThemeComponentSelectionSchemaVersion),
        @"selectedVariants" : selected,
    };
    return [MTThemeComponentSelection selectionForCatalog:catalog
        canonicalDictionary:dictionary error:error];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    return [object isKindOfClass:MTThemeComponentSelection.class] &&
        [self.canonicalDictionary isEqual:
            ((MTThemeComponentSelection *)object).canonicalDictionary];
}

- (NSUInteger)hash {
    return self.canonicalDictionary.hash;
}

@end
