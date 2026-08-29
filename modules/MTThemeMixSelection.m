#import "MTThemeMixSelection.h"

#import "MTDigest.h"
#import "MTIdentifier.h"
#import "MTThemeComponentCatalog.h"

NSString *const MTThemeMixSelectionErrorDomain =
    @"com.hmmzzz.marktheme.theme-mix-selection";
NSUInteger const MTThemeMixSelectionSchemaVersion = 1;

static void MTThemeMixSetError(NSError **error,
                               NSInteger code,
                               NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTThemeMixSelectionErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

static BOOL MTThemeMixDictionaryHasExactKeys(NSDictionary *dictionary,
                                             NSArray<NSString *> *keys) {
    return [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL MTThemeMixRevisionIdentifierIsValid(NSString *identifier) {
    return [identifier isKindOfClass:NSString.class] &&
        [identifier hasPrefix:@"r1-"] && identifier.length == 67 &&
        MTStringIsLowercaseSHA256Digest([identifier substringFromIndex:3]);
}

static NSDictionary<NSString *, NSString *> *_Nullable
MTThemeMixNormalizeSourceThemes(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary<NSString *, NSString *> *result =
        [NSMutableDictionary dictionary];
    for (id rawFeature in (NSDictionary *)value) {
        id rawTheme = ((NSDictionary *)value)[rawFeature];
        NSString *feature = [rawFeature isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawFeature, NULL) : nil;
        NSString *theme = [rawTheme isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawTheme, NULL) : nil;
        if (feature == nil || theme == nil ||
            ![feature isEqualToString:rawFeature] ||
            ![theme isEqualToString:rawTheme]) {
            return nil;
        }
        result[feature] = theme;
    }
    return [result copy];
}

static NSArray<NSString *> *_Nullable MTThemeMixNormalizeDisabledFeatures(
    id value) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id rawFeature in (NSArray *)value) {
        NSString *feature = [rawFeature isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawFeature, NULL) : nil;
        if (feature == nil || ![feature isEqualToString:rawFeature] ||
            [seen containsObject:feature]) {
            return nil;
        }
        [seen addObject:feature];
    }
    return [seen.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL MTThemeMixComponentDictionaryIsValid(
    NSDictionary<NSString *, id> *dictionary,
    NSString *revisionIdentifier) {
    if (!MTThemeMixDictionaryHasExactKeys(dictionary, @[
            @"enabledComponents", @"manifestDigest", @"schemaVersion",
            @"selectedVariants",
        ]) ||
        ![dictionary[@"schemaVersion"]
            isEqual:@(MTThemeComponentSelectionSchemaVersion)] ||
        ![dictionary[@"manifestDigest"] isKindOfClass:NSString.class] ||
        ![dictionary[@"enabledComponents"] isKindOfClass:NSArray.class] ||
        ![dictionary[@"selectedVariants"] isKindOfClass:NSDictionary.class] ||
        ![[revisionIdentifier substringFromIndex:3]
            isEqualToString:dictionary[@"manifestDigest"]]) {
        return NO;
    }
    NSMutableSet<NSString *> *components = [NSMutableSet set];
    for (id rawComponent in dictionary[@"enabledComponents"]) {
        NSString *component = [rawComponent isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawComponent, NULL) : nil;
        if (component == nil || ![component isEqualToString:rawComponent] ||
            [components containsObject:component]) {
            return NO;
        }
        [components addObject:component];
    }
    for (id rawGroup in dictionary[@"selectedVariants"]) {
        id rawVariant = dictionary[@"selectedVariants"][rawGroup];
        NSString *group = [rawGroup isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawGroup, NULL) : nil;
        NSString *variant = [rawVariant isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawVariant, NULL) : nil;
        if (group == nil || variant == nil ||
            ![group isEqualToString:rawGroup] ||
            ![variant isEqualToString:rawVariant]) {
            return NO;
        }
    }
    return YES;
}

@interface MTThemeMixSelection ()
@property(nonatomic, copy, readwrite) NSString *baseThemeIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSString *> *sourceThemeIdentifiersByFeature;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *disabledFeatureIdentifiers;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *referencedThemeIdentifiers;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *effectiveThemeIdentifiers;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, id> *effectiveCanonicalDictionary;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSString *> *revisionIdentifiersByThemeIdentifier;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        componentSelectionDictionariesByThemeIdentifier;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, id> *canonicalDictionary;
- (instancetype)initPrivateWithBaseThemeIdentifier:(NSString *)baseThemeIdentifier
    sourceThemeIdentifiersByFeature:
        (NSDictionary<NSString *, NSString *> *)sourceThemes
    disabledFeatureIdentifiers:(NSArray<NSString *> *)disabledFeatures
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSString *> *)revisions
    componentSelectionDictionariesByThemeIdentifier:
        (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)components;
@end

@implementation MTThemeMixSelection

- (instancetype)initPrivateWithBaseThemeIdentifier:(NSString *)baseThemeIdentifier
    sourceThemeIdentifiersByFeature:
        (NSDictionary<NSString *,NSString *> *)sourceThemes
    disabledFeatureIdentifiers:(NSArray<NSString *> *)disabledFeatures
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *,NSString *> *)revisions
    componentSelectionDictionariesByThemeIdentifier:
        (NSDictionary<NSString *,NSDictionary<NSString *,id> *> *)components {
    self = [super init];
    if (self == nil) return nil;
    _baseThemeIdentifier = [baseThemeIdentifier copy];
    _sourceThemeIdentifiersByFeature = [sourceThemes copy];
    _disabledFeatureIdentifiers = [disabledFeatures copy];
    _revisionIdentifiersByThemeIdentifier = [revisions copy];
    _componentSelectionDictionariesByThemeIdentifier = [components copy];
    _referencedThemeIdentifiers = [[revisions.allKeys
        sortedArrayUsingSelector:@selector(compare:)] copy];
    NSMutableSet<NSString *> *effective = [NSMutableSet
        setWithObject:_baseThemeIdentifier];
    NSMutableDictionary<NSString *, NSString *> *effectiveSources =
        [NSMutableDictionary dictionary];
    NSSet<NSString *> *disabledSet = [NSSet setWithArray:
        _disabledFeatureIdentifiers];
    for (NSString *featureIdentifier in _sourceThemeIdentifiersByFeature) {
        if (![disabledSet containsObject:featureIdentifier]) {
            NSString *source =
                _sourceThemeIdentifiersByFeature[featureIdentifier];
            [effective addObject:source];
            effectiveSources[featureIdentifier] = source;
        }
    }
    _effectiveThemeIdentifiers = [[effective.allObjects
        sortedArrayUsingSelector:@selector(compare:)] copy];
    NSMutableDictionary<NSString *, NSString *> *effectiveRevisions =
        [NSMutableDictionary dictionaryWithCapacity:effective.count];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
        effectiveComponents =
            [NSMutableDictionary dictionaryWithCapacity:effective.count];
    for (NSString *themeIdentifier in _effectiveThemeIdentifiers) {
        effectiveRevisions[themeIdentifier] =
            _revisionIdentifiersByThemeIdentifier[themeIdentifier];
        effectiveComponents[themeIdentifier] =
            _componentSelectionDictionariesByThemeIdentifier[themeIdentifier];
    }
    _effectiveCanonicalDictionary = @{
        @"baseThemeIdentifier" : _baseThemeIdentifier,
        @"componentSelections" : [effectiveComponents copy],
        @"disabledFeatures" : _disabledFeatureIdentifiers,
        @"revisions" : [effectiveRevisions copy],
        @"schemaVersion" : @(MTThemeMixSelectionSchemaVersion),
        @"sourceThemes" : [effectiveSources copy],
    };
    _canonicalDictionary = @{
        @"baseThemeIdentifier" : _baseThemeIdentifier,
        @"componentSelections" : _componentSelectionDictionariesByThemeIdentifier,
        @"disabledFeatures" : _disabledFeatureIdentifiers,
        @"revisions" : _revisionIdentifiersByThemeIdentifier,
        @"schemaVersion" : @(MTThemeMixSelectionSchemaVersion),
        @"sourceThemes" : _sourceThemeIdentifiersByFeature,
    };
    return self;
}

+ (instancetype)selectionWithBaseThemeIdentifier:(NSString *)baseThemeIdentifier
    sourceThemeIdentifiersByFeature:
        (NSDictionary<NSString *,NSString *> *)sourceThemeIdentifiersByFeature
    disabledFeatureIdentifiers:(NSArray<NSString *> *)disabledFeatureIdentifiers
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *,NSString *> *)revisionIdentifiersByThemeIdentifier
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *,MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    error:(NSError **)error {
    NSString *base = MTNormalizeIdentifier(baseThemeIdentifier, NULL);
    NSDictionary<NSString *, NSString *> *sources =
        MTThemeMixNormalizeSourceThemes(sourceThemeIdentifiersByFeature);
    NSArray<NSString *> *disabled =
        MTThemeMixNormalizeDisabledFeatures(disabledFeatureIdentifiers);
    if (base == nil || ![base isEqualToString:baseThemeIdentifier] ||
        sources == nil || disabled == nil) {
        MTThemeMixSetError(error, 1,
            @"Theme mix base, source, or feature identifiers are invalid.");
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *normalizedSources =
        [sources mutableCopy];
    NSArray<NSString *> *sourceFeatures = normalizedSources.allKeys;
    for (NSString *feature in sourceFeatures) {
        if ([normalizedSources[feature] isEqualToString:base]) {
            [normalizedSources removeObjectForKey:feature];
        }
    }
    NSMutableSet<NSString *> *referenced = [NSMutableSet setWithObject:base];
    [referenced addObjectsFromArray:normalizedSources.allValues];
    NSMutableDictionary<NSString *, NSString *> *revisions =
        [NSMutableDictionary dictionaryWithCapacity:referenced.count];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *components =
        [NSMutableDictionary dictionaryWithCapacity:referenced.count];
    for (NSString *themeIdentifier in referenced) {
        NSString *revision = revisionIdentifiersByThemeIdentifier[themeIdentifier];
        MTThemeComponentSelection *selection =
            componentSelectionsByThemeIdentifier[themeIdentifier];
        if (!MTThemeMixRevisionIdentifierIsValid(revision) ||
            ![selection isKindOfClass:MTThemeComponentSelection.class] ||
            ![[revision substringFromIndex:3]
                isEqualToString:selection.manifestDigest]) {
            MTThemeMixSetError(error, 2,
                @"A referenced mix source has no matching current revision and component selection.");
            return nil;
        }
        revisions[themeIdentifier] = revision;
        components[themeIdentifier] = selection.canonicalDictionary;
    }
    NSDictionary *canonical = @{
        @"baseThemeIdentifier" : base,
        @"componentSelections" : components,
        @"disabledFeatures" : disabled,
        @"revisions" : revisions,
        @"schemaVersion" : @(MTThemeMixSelectionSchemaVersion),
        @"sourceThemes" : normalizedSources,
    };
    return [self selectionWithCanonicalDictionary:canonical error:error];
}

+ (instancetype)selectionWithCanonicalDictionary:
        (NSDictionary<NSString *,id> *)canonicalDictionary
                                                  error:(NSError **)error {
    if (![canonicalDictionary isKindOfClass:NSDictionary.class]) {
        MTThemeMixSetError(error, 3,
            @"Theme mix selection has an unsupported or malformed shape.");
        return nil;
    }
    NSArray<NSString *> *rootKeys = @[
        @"baseThemeIdentifier", @"componentSelections", @"disabledFeatures",
        @"revisions", @"schemaVersion", @"sourceThemes",
    ];
    NSString *rawBase = canonicalDictionary[@"baseThemeIdentifier"];
    NSString *base = [rawBase isKindOfClass:NSString.class]
        ? MTNormalizeIdentifier(rawBase, NULL) : nil;
    NSDictionary<NSString *, NSString *> *sources =
        MTThemeMixNormalizeSourceThemes(canonicalDictionary[@"sourceThemes"]);
    NSArray<NSString *> *disabled = MTThemeMixNormalizeDisabledFeatures(
        canonicalDictionary[@"disabledFeatures"]);
    NSDictionary *rawRevisions = canonicalDictionary[@"revisions"];
    NSDictionary *rawComponents = canonicalDictionary[@"componentSelections"];
    if (!MTThemeMixDictionaryHasExactKeys(canonicalDictionary, rootKeys) ||
        ![canonicalDictionary[@"schemaVersion"]
            isEqual:@(MTThemeMixSelectionSchemaVersion)] ||
        base == nil || ![base isEqualToString:rawBase] || sources == nil ||
        disabled == nil || ![rawRevisions isKindOfClass:NSDictionary.class] ||
        ![rawComponents isKindOfClass:NSDictionary.class]) {
        MTThemeMixSetError(error, 3,
            @"Theme mix selection has an unsupported or malformed shape.");
        return nil;
    }
    for (NSString *source in sources.allValues) {
        if ([source isEqualToString:base]) {
            MTThemeMixSetError(error, 4,
                @"Base-theme feature sources must use the canonical implicit form.");
            return nil;
        }
    }

    NSMutableSet<NSString *> *referenced = [NSMutableSet setWithObject:base];
    [referenced addObjectsFromArray:sources.allValues];
    NSSet<NSString *> *revisionKeys = [NSSet setWithArray:rawRevisions.allKeys];
    NSSet<NSString *> *componentKeys = [NSSet setWithArray:rawComponents.allKeys];
    if (![revisionKeys isEqualToSet:referenced] ||
        ![componentKeys isEqualToSet:referenced]) {
        MTThemeMixSetError(error, 5,
            @"Theme mix source identities are incomplete or contain unused themes.");
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *revisions =
        [NSMutableDictionary dictionaryWithCapacity:referenced.count];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *components =
        [NSMutableDictionary dictionaryWithCapacity:referenced.count];
    for (id rawTheme in rawRevisions) {
        NSString *theme = [rawTheme isKindOfClass:NSString.class]
            ? MTNormalizeIdentifier(rawTheme, NULL) : nil;
        NSString *revision = rawRevisions[rawTheme];
        NSDictionary *component = rawComponents[rawTheme];
        if (theme == nil || ![theme isEqualToString:rawTheme] ||
            !MTThemeMixRevisionIdentifierIsValid(revision) ||
            ![component isKindOfClass:NSDictionary.class] ||
            !MTThemeMixComponentDictionaryIsValid(component, revision)) {
            MTThemeMixSetError(error, 6,
                @"Theme mix revision or component-selection identity is invalid.");
            return nil;
        }
        revisions[theme] = revision;
        components[theme] = [component copy];
    }
    return [[self alloc] initPrivateWithBaseThemeIdentifier:base
        sourceThemeIdentifiersByFeature:sources
        disabledFeatureIdentifiers:disabled
        revisionIdentifiersByThemeIdentifier:revisions
        componentSelectionDictionariesByThemeIdentifier:components];
}

- (BOOL)isFeatureEnabled:(NSString *)featureIdentifier {
    return ![self.disabledFeatureIdentifiers containsObject:featureIdentifier];
}

- (NSString *)sourceThemeIdentifierForFeatureIdentifier:
        (NSString *)featureIdentifier {
    return self.sourceThemeIdentifiersByFeature[featureIdentifier] ?:
        self.baseThemeIdentifier;
}

- (BOOL)isRuntimeEquivalentToSelection:(MTThemeMixSelection *)selection {
    return self == selection ||
        ([selection isKindOfClass:MTThemeMixSelection.class] &&
         [self.effectiveCanonicalDictionary isEqual:
             selection.effectiveCanonicalDictionary]);
}

- (instancetype)selectionBySettingFeatureIdentifier:
        (NSString *)featureIdentifier
                                                   enabled:(BOOL)enabled
                                                     error:(NSError **)error {
    NSString *feature = MTNormalizeIdentifier(featureIdentifier, NULL);
    if (feature == nil || ![feature isEqualToString:featureIdentifier]) {
        MTThemeMixSetError(error, 7, @"Theme feature identifier is invalid.");
        return nil;
    }
    NSMutableSet<NSString *> *disabled =
        [NSMutableSet setWithArray:self.disabledFeatureIdentifiers];
    if (enabled) {
        [disabled removeObject:feature];
    } else {
        [disabled addObject:feature];
    }
    NSDictionary *canonical = @{
        @"baseThemeIdentifier" : self.baseThemeIdentifier,
        @"componentSelections" :
            self.componentSelectionDictionariesByThemeIdentifier,
        @"disabledFeatures" : disabled.allObjects,
        @"revisions" : self.revisionIdentifiersByThemeIdentifier,
        @"schemaVersion" : @(MTThemeMixSelectionSchemaVersion),
        @"sourceThemes" : self.sourceThemeIdentifiersByFeature,
    };
    return [MTThemeMixSelection selectionWithCanonicalDictionary:canonical
                                                           error:error];
}

- (instancetype)selectionBySettingSourceThemeIdentifier:
        (NSString *)sourceThemeIdentifier
                                         forFeatureIdentifier:
                                             (NSString *)featureIdentifier
                         revisionIdentifiersByThemeIdentifier:
                             (NSDictionary<NSString *,NSString *> *)
                                 revisionIdentifiersByThemeIdentifier
                       componentSelectionsByThemeIdentifier:
                           (NSDictionary<NSString *,MTThemeComponentSelection *> *)
                               componentSelectionsByThemeIdentifier
                                                       error:(NSError **)error {
    NSString *feature = MTNormalizeIdentifier(featureIdentifier, NULL);
    NSString *source = MTNormalizeIdentifier(sourceThemeIdentifier, NULL);
    if (feature == nil || source == nil ||
        ![feature isEqualToString:featureIdentifier] ||
        ![source isEqualToString:sourceThemeIdentifier]) {
        MTThemeMixSetError(error, 8,
            @"Theme feature source identifiers are invalid.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *sources =
        [self.sourceThemeIdentifiersByFeature mutableCopy];
    if ([source isEqualToString:self.baseThemeIdentifier]) {
        [sources removeObjectForKey:feature];
    } else {
        sources[feature] = source;
    }
    return [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:self.baseThemeIdentifier
        sourceThemeIdentifiersByFeature:sources
        disabledFeatureIdentifiers:self.disabledFeatureIdentifiers
        revisionIdentifiersByThemeIdentifier:revisionIdentifiersByThemeIdentifier
        componentSelectionsByThemeIdentifier:componentSelectionsByThemeIdentifier
        error:error];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    return [object isKindOfClass:MTThemeMixSelection.class] &&
        [self.canonicalDictionary isEqual:
            ((MTThemeMixSelection *)object).canonicalDictionary];
}

- (NSUInteger)hash {
    return self.canonicalDictionary.hash;
}

@end
