#import "MTThemeComponentSelectionStore.h"

#import "MTIdentifier.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeCapabilityReport.h"
#import "MTThemeMixSelection.h"

NSString *const MTThemeComponentSelectionStoreErrorDomain =
    @"com.hmmzzz.marktheme.theme-component-selection-store";

static NSString *const MTDesiredSelectionsDefaultsKey =
    @"ThemeComponentSelections.v1";
static NSString *const MTAppliedSelectionsDefaultsKey =
    @"AppliedThemeComponentSelections.v1";
static NSString *const MTDesiredMixSelectionsDefaultsKey =
    @"ThemeMixSelections.v1";
static NSString *const MTAppliedMixSelectionsDefaultsKey =
    @"AppliedThemeMixSelections.v1";
static const NSUInteger MTAppliedSelectionMaximumCount = 64;

static BOOL MTThemeSelectionStoreSetError(NSError **error,
                                          NSInteger code,
                                          NSString *description) {
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:MTThemeComponentSelectionStoreErrorDomain
                       code:code
                   userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
}

static BOOL MTThemeSelectionStoreMixUsesSupportedFeatures(
    MTThemeMixSelection *selection) {
    NSSet<NSString *> *supported = [NSSet setWithArray:
        MTThemeMixableFeatureIdentifiers()];
    NSSet<NSString *> *sources = [NSSet setWithArray:
        selection.sourceThemeIdentifiersByFeature.allKeys];
    NSSet<NSString *> *disabled = [NSSet setWithArray:
        selection.disabledFeatureIdentifiers];
    return [sources isSubsetOfSet:supported] &&
        [disabled isSubsetOfSet:supported];
}

@interface MTThemeComponentSelectionStore ()
@property(nonatomic, strong, readwrite) NSUserDefaults *userDefaults;
@end

@implementation MTThemeComponentSelectionStore

+ (instancetype)defaultStore {
    return [[self alloc] initWithUserDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults {
    NSParameterAssert(userDefaults != nil);
    self = [super init];
    if (self == nil) return nil;
    _userDefaults = userDefaults;
    return self;
}

- (NSDictionary<NSString *, id> *)dictionaryForKey:(NSString *)key {
    id value = [self.userDefaults objectForKey:key];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

- (MTThemeComponentSelection *)selectionForCatalog:
        (MTThemeComponentCatalog *)catalog {
    NSDictionary *selections = [self dictionaryForKey:
        MTDesiredSelectionsDefaultsKey];
    id stored = selections[catalog.themeIdentifier];
    return [MTThemeComponentSelection selectionByNormalizingDictionary:
        [stored isKindOfClass:NSDictionary.class] ? stored : nil
        catalog:catalog];
}

- (BOOL)saveSelection:(MTThemeComponentSelection *)selection
           forCatalog:(MTThemeComponentCatalog *)catalog
                error:(NSError **)error {
    if (![selection isKindOfClass:MTThemeComponentSelection.class] ||
        ![catalog isKindOfClass:MTThemeComponentCatalog.class] ||
        ![selection.manifestDigest isEqualToString:catalog.manifestDigest] ||
        [MTThemeComponentSelection selectionForCatalog:catalog
            canonicalDictionary:selection.canonicalDictionary
            error:NULL] == nil) {
        return MTThemeSelectionStoreSetError(error, 1,
            @"Only a valid selection for the current Theme revision can be saved.");
    }
    NSMutableDictionary *selections = [[self dictionaryForKey:
        MTDesiredSelectionsDefaultsKey] mutableCopy];
    selections[catalog.themeIdentifier] = selection.canonicalDictionary;
    [self.userDefaults setObject:selections forKey:MTDesiredSelectionsDefaultsKey];
    return YES;
}

- (BOOL)recordAppliedSelection:(MTThemeComponentSelection *)selection
               themeIdentifier:(NSString *)themeIdentifier
             revisionIdentifier:(NSString *)revisionIdentifier
           generationIdentifier:(NSString *)generationIdentifier
                          error:(NSError **)error {
    if (![selection isKindOfClass:MTThemeComponentSelection.class] ||
        themeIdentifier.length == 0 || revisionIdentifier.length == 0 ||
        generationIdentifier.length == 0) {
        return MTThemeSelectionStoreSetError(error, 2,
            @"Applied component selection identity is incomplete.");
    }
    NSMutableDictionary<NSString *, NSDictionary *> *applied =
        [[self dictionaryForKey:MTAppliedSelectionsDefaultsKey] mutableCopy];
    applied[generationIdentifier] = @{
        @"recordedAt" : @([NSDate date].timeIntervalSince1970),
        @"revisionIdentifier" : revisionIdentifier,
        @"selection" : selection.canonicalDictionary,
        @"themeIdentifier" : themeIdentifier,
    };
    if (applied.count > MTAppliedSelectionMaximumCount) {
        NSArray<NSString *> *ordered = [applied.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                            NSString *right) {
            NSNumber *leftDate = applied[left][@"recordedAt"];
            NSNumber *rightDate = applied[right][@"recordedAt"];
            NSComparisonResult result = [leftDate compare:rightDate];
            return result != NSOrderedSame
                ? result : [left compare:right options:NSLiteralSearch];
        }];
        NSUInteger removeCount = applied.count - MTAppliedSelectionMaximumCount;
        for (NSUInteger index = 0; index < removeCount; index++) {
            [applied removeObjectForKey:ordered[index]];
        }
    }
    [self.userDefaults setObject:applied forKey:MTAppliedSelectionsDefaultsKey];
    return YES;
}

- (MTThemeComponentSelection *)appliedSelectionForGenerationIdentifier:
        (NSString *)generationIdentifier
                                                        themeIdentifier:
                                                            (NSString *)themeIdentifier
                                                     revisionIdentifier:
                                                         (NSString *)revisionIdentifier
                                                                catalog:
                                                                    (MTThemeComponentCatalog *)catalog {
    NSDictionary *applied = [self dictionaryForKey:
        MTAppliedSelectionsDefaultsKey];
    id value = applied[generationIdentifier];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *entry = value;
    if (![entry[@"themeIdentifier"] isEqualToString:themeIdentifier] ||
        ![entry[@"revisionIdentifier"] isEqualToString:revisionIdentifier] ||
        ![entry[@"selection"] isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    return [MTThemeComponentSelection selectionForCatalog:catalog
        canonicalDictionary:entry[@"selection"] error:NULL];
}

- (MTThemeMixSelection *)mixSelectionForBaseThemeIdentifier:
        (NSString *)baseThemeIdentifier
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *,NSString *> *)revisionIdentifiersByThemeIdentifier
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *,MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *,NSSet<NSString *> *> *)
            availableFeatureIdentifiersByThemeIdentifier {
    if (baseThemeIdentifier.length == 0 ||
        revisionIdentifiersByThemeIdentifier[baseThemeIdentifier] == nil ||
        componentSelectionsByThemeIdentifier[baseThemeIdentifier] == nil) {
        return nil;
    }
    NSDictionary *storedByBase = [self dictionaryForKey:
        MTDesiredMixSelectionsDefaultsKey];
    id rawValue = storedByBase[baseThemeIdentifier];
    NSDictionary *value = [rawValue isKindOfClass:NSDictionary.class]
        ? rawValue : @{};
    id rawSources = value[@"sourceThemes"];
    NSMutableDictionary<NSString *, NSString *> *sources =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *rememberedSources =
        [NSMutableDictionary dictionary];
    if ([rawSources isKindOfClass:NSDictionary.class]) {
        for (id rawFeature in (NSDictionary *)rawSources) {
            id rawTheme = rawSources[rawFeature];
            NSString *feature = [rawFeature isKindOfClass:NSString.class]
                ? MTNormalizeIdentifier(rawFeature, NULL) : nil;
            NSString *theme = [rawTheme isKindOfClass:NSString.class]
                ? MTNormalizeIdentifier(rawTheme, NULL) : nil;
            if (feature == nil || theme == nil ||
                ![feature isEqualToString:rawFeature] ||
                ![theme isEqualToString:rawTheme] ||
                !MTThemeFeatureSupportsMixing(feature) ||
                [theme isEqualToString:baseThemeIdentifier]) {
                continue;
            }
            rememberedSources[feature] = theme;
            if (revisionIdentifiersByThemeIdentifier[theme] != nil &&
                componentSelectionsByThemeIdentifier[theme] != nil) {
                sources[feature] = theme;
            }
        }
    }
    id rawDisabled = value[@"disabledFeatures"];
    NSMutableArray<NSString *> *disabled = [NSMutableArray array];
    if ([rawDisabled isKindOfClass:NSArray.class]) {
        for (id rawFeature in (NSArray *)rawDisabled) {
            if ([rawFeature isKindOfClass:NSString.class] &&
                MTThemeFeatureSupportsMixing(rawFeature) &&
                ![disabled containsObject:rawFeature]) {
                [disabled addObject:rawFeature];
            }
        }
    }
    BOOL repairedUnavailableSource = NO;
    for (NSString *featureIdentifier in rememberedSources) {
        NSString *sourceThemeIdentifier = sources[featureIdentifier];
        NSSet<NSString *> *knownAvailableFeatures =
            sourceThemeIdentifier == nil ? nil :
                availableFeatureIdentifiersByThemeIdentifier[
                    sourceThemeIdentifier];
        // A partial map is used for targeted component edits. An omitted,
        // still-present source is unchanged and was validated by the previous
        // immutable snapshot; a missing Library source remains unavailable.
        BOOL sourceAvailable = sourceThemeIdentifier != nil &&
            (knownAvailableFeatures == nil ||
             [knownAvailableFeatures containsObject:featureIdentifier]);
        if (!sourceAvailable &&
            ![disabled containsObject:featureIdentifier]) {
            [disabled addObject:featureIdentifier];
            repairedUnavailableSource = YES;
        }
    }
    MTThemeMixSelection *selection = [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:baseThemeIdentifier
        sourceThemeIdentifiersByFeature:sources
        disabledFeatureIdentifiers:disabled
        revisionIdentifiersByThemeIdentifier:revisionIdentifiersByThemeIdentifier
        componentSelectionsByThemeIdentifier:componentSelectionsByThemeIdentifier
        error:NULL];
    if (selection != nil) {
        if (repairedUnavailableSource) {
            // Missing Library themes cannot be embedded in the immutable
            // selection, but their preference is retained so reinstalling the
            // same theme restores the source without silently re-enabling it.
            NSMutableDictionary *repaired = [storedByBase mutableCopy];
            repaired[baseThemeIdentifier] = @{
                @"disabledFeatures" : disabled,
                @"sourceThemes" : rememberedSources,
            };
            [self.userDefaults setObject:repaired
                                  forKey:MTDesiredMixSelectionsDefaultsKey];
        }
        return selection;
    }
    return [MTThemeMixSelection
        selectionWithBaseThemeIdentifier:baseThemeIdentifier
        sourceThemeIdentifiersByFeature:@{}
        disabledFeatureIdentifiers:@[]
        revisionIdentifiersByThemeIdentifier:revisionIdentifiersByThemeIdentifier
        componentSelectionsByThemeIdentifier:componentSelectionsByThemeIdentifier
        error:NULL];
}

- (BOOL)saveMixSelection:(MTThemeMixSelection *)selection
                   error:(NSError **)error {
    MTThemeMixSelection *validated =
        [selection isKindOfClass:MTThemeMixSelection.class]
        ? [MTThemeMixSelection selectionWithCanonicalDictionary:
            selection.canonicalDictionary error:NULL]
        : nil;
    if (validated == nil ||
        !MTThemeSelectionStoreMixUsesSupportedFeatures(validated)) {
        return MTThemeSelectionStoreSetError(error, 3,
            @"Only a valid current theme mix selection can be saved.");
    }
    NSMutableDictionary *stored = [[self dictionaryForKey:
        MTDesiredMixSelectionsDefaultsKey] mutableCopy];
    stored[validated.baseThemeIdentifier] = @{
        @"disabledFeatures" : validated.disabledFeatureIdentifiers,
        @"sourceThemes" : validated.sourceThemeIdentifiersByFeature,
    };
    [self.userDefaults setObject:stored forKey:MTDesiredMixSelectionsDefaultsKey];
    return YES;
}

static void MTThemeSelectionStorePruneAppliedEntries(
    NSMutableDictionary<NSString *, NSDictionary *> *applied) {
    if (applied.count <= MTAppliedSelectionMaximumCount) return;
    NSArray<NSString *> *ordered = [applied.allKeys
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                        NSString *right) {
        NSNumber *leftDate = applied[left][@"recordedAt"];
        NSNumber *rightDate = applied[right][@"recordedAt"];
        NSComparisonResult result = [leftDate compare:rightDate];
        return result != NSOrderedSame
            ? result : [left compare:right options:NSLiteralSearch];
    }];
    NSUInteger removeCount = applied.count - MTAppliedSelectionMaximumCount;
    for (NSUInteger index = 0; index < removeCount; index++) {
        [applied removeObjectForKey:ordered[index]];
    }
}

- (BOOL)recordAppliedMixSelection:(MTThemeMixSelection *)selection
              generationIdentifier:(NSString *)generationIdentifier
                             error:(NSError **)error {
    if (![selection isKindOfClass:MTThemeMixSelection.class] ||
        generationIdentifier.length == 0 ||
        [MTThemeMixSelection selectionWithCanonicalDictionary:
            selection.canonicalDictionary error:NULL] == nil ||
        !MTThemeSelectionStoreMixUsesSupportedFeatures(selection)) {
        return MTThemeSelectionStoreSetError(error, 4,
            @"Applied theme mix selection identity is incomplete.");
    }
    NSMutableDictionary<NSString *, NSDictionary *> *applied =
        [[self dictionaryForKey:MTAppliedMixSelectionsDefaultsKey] mutableCopy];
    applied[generationIdentifier] = @{
        @"baseRevisionIdentifier" :
            selection.revisionIdentifiersByThemeIdentifier[
                selection.baseThemeIdentifier],
        @"baseThemeIdentifier" : selection.baseThemeIdentifier,
        @"recordedAt" : @([NSDate date].timeIntervalSince1970),
        @"selection" : selection.canonicalDictionary,
    };
    MTThemeSelectionStorePruneAppliedEntries(applied);
    [self.userDefaults setObject:applied
                          forKey:MTAppliedMixSelectionsDefaultsKey];
    return YES;
}

- (MTThemeMixSelection *)appliedMixSelectionForGenerationIdentifier:
        (NSString *)generationIdentifier
                                                 baseThemeIdentifier:
                                                     (NSString *)baseThemeIdentifier
                                              baseRevisionIdentifier:
                                                  (NSString *)baseRevisionIdentifier {
    NSDictionary *applied = [self dictionaryForKey:
        MTAppliedMixSelectionsDefaultsKey];
    id rawValue = applied[generationIdentifier];
    if (![rawValue isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *value = rawValue;
    if (![value[@"baseThemeIdentifier"] isEqualToString:baseThemeIdentifier] ||
        ![value[@"baseRevisionIdentifier"]
            isEqualToString:baseRevisionIdentifier] ||
        ![value[@"selection"] isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    MTThemeMixSelection *selection = [MTThemeMixSelection
        selectionWithCanonicalDictionary:value[@"selection"] error:NULL];
    NSString *recordedRevision =
        selection.revisionIdentifiersByThemeIdentifier[baseThemeIdentifier];
    return [selection.baseThemeIdentifier isEqualToString:baseThemeIdentifier] &&
        [recordedRevision isEqualToString:baseRevisionIdentifier]
        ? selection : nil;
}

@end
