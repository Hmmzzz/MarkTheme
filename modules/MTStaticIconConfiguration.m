#import "MTStaticIconConfiguration.h"

NSUInteger const MTStaticIconMaximumFuzzyBundleIdentifierCount = 256;
NSUInteger const MTStaticIconMaximumBundleAliasCount = 256;
NSUInteger const MTStaticIconMaximumMatchingLayerCount = 3;

NSString *const MTStaticIconSourceVariantPrimary = @"primary";
NSString *const MTStaticIconSourceVariantLarge = @"source-large";
NSString *const MTStaticIconSourceVariantDeviceScale =
    @"source-device-scale";
NSString *const MTStaticIconSourceVariantScaleDevice =
    @"source-scale-device";
NSString *const MTStaticIconSourceVariantScale = @"source-scale";
NSString *const MTStaticIconSourceVariantDevice = @"source-device";
NSString *const MTStaticIconSourceVariantPlain = @"source-plain";
NSString *const MTStaticIconSourceVariantBundleIcon = @"source-bundle-icon";

NSArray<NSString *> *MTStaticIconSourceVariants(void) {
    static NSArray<NSString *> *variants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        variants = @[
            MTStaticIconSourceVariantLarge,
            MTStaticIconSourceVariantDeviceScale,
            MTStaticIconSourceVariantScaleDevice,
            MTStaticIconSourceVariantScale,
            MTStaticIconSourceVariantDevice,
            MTStaticIconSourceVariantPlain,
            MTStaticIconSourceVariantBundleIcon,
            MTStaticIconSourceVariantPrimary,
        ];
    });
    return variants;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *
MTStaticIconSourceVariantsByMatchingLayer(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *layers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *built = [NSMutableArray
            arrayWithCapacity:MTStaticIconMaximumMatchingLayerCount];
        for (NSUInteger layerIndex = 0;
             layerIndex < MTStaticIconMaximumMatchingLayerCount;
             layerIndex++) {
            NSMutableDictionary *variants = [NSMutableDictionary dictionary];
            for (NSString *sourceVariant in MTStaticIconSourceVariants()) {
                variants[sourceVariant] = [NSString stringWithFormat:
                    @"mix%lu-%@", (unsigned long)layerIndex, sourceVariant];
            }
            [built addObject:[variants copy]];
        }
        layers = [built copy];
    });
    return layers;
}

BOOL MTStaticIconSourceVariantIsSupported(NSString *variant) {
    if (![variant isKindOfClass:NSString.class]) return NO;
    static NSSet<NSString *> *supported;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet *built = [NSMutableSet setWithArray:
            MTStaticIconSourceVariants()];
        for (NSDictionary<NSString *, NSString *> *layer in
                MTStaticIconSourceVariantsByMatchingLayer()) {
            [built addObjectsFromArray:layer.allValues];
        }
        supported = [built copy];
    });
    return [supported containsObject:variant];
}

NSString *MTStaticIconSourceVariantForMatchingLayer(
    NSString *sourceVariant,
    NSUInteger layerIndex) {
    if (![MTStaticIconSourceVariants() containsObject:sourceVariant] ||
        layerIndex >= MTStaticIconMaximumMatchingLayerCount) {
        return nil;
    }
    return MTStaticIconSourceVariantsByMatchingLayer()[layerIndex][
        sourceVariant];
}

static NSString *const MTStaticIconConfigurationErrorDomain =
    @"com.hmmzzz.marktheme.static-icon-configuration";

BOOL MTStaticIconBundleIdentifierIsValid(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:NSString.class]) return NO;
    NSUInteger bytes = [bundleIdentifier
        lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes == 0 || bytes > 255 || [bundleIdentifier hasPrefix:@"."] ||
        [bundleIdentifier hasSuffix:@"."]) {
        return NO;
    }
    BOOL previousDot = NO;
    for (NSUInteger index = 0; index < bundleIdentifier.length; index++) {
        unichar character = [bundleIdentifier characterAtIndex:index];
        BOOL alphanumeric =
            (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9');
        if (alphanumeric || character == '-' || character == '_') {
            previousDot = NO;
            continue;
        }
        if (character != '.' || previousDot) return NO;
        previousDot = YES;
    }
    return YES;
}

static BOOL MTStaticIconSetConfigurationError(NSError **error,
                                               NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTStaticIconConfigurationErrorDomain
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey : description,
        }];
    }
    return NO;
}

static NSArray<NSString *> *_Nullable MTStaticIconNormalizeIdentifiers(
    NSArray<NSString *> *identifiers,
    NSError **error) {
    if (![identifiers isKindOfClass:NSArray.class]) {
        MTStaticIconSetConfigurationError(error,
            @"Fuzzy Bundle ID configuration is not an array.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *byFoldedIdentifier =
        [NSMutableDictionary dictionary];
    for (id candidate in identifiers) {
        if (!MTStaticIconBundleIdentifierIsValid(candidate)) {
            MTStaticIconSetConfigurationError(error,
                @"Fuzzy Bundle ID configuration contains an invalid identifier.");
            return nil;
        }
        NSString *identifier = [candidate
            precomposedStringWithCanonicalMapping];
        NSString *folded = identifier.lowercaseString;
        NSString *existing = byFoldedIdentifier[folded];
        if (existing == nil &&
            byFoldedIdentifier.count >=
                MTStaticIconMaximumFuzzyBundleIdentifierCount) {
            MTStaticIconSetConfigurationError(error,
                @"Fuzzy Bundle ID configuration exceeds its collection limit.");
            return nil;
        }
        if (existing == nil || [identifier compare:existing
            options:NSLiteralSearch] == NSOrderedAscending) {
            byFoldedIdentifier[folded] = identifier;
        }
    }
    return [byFoldedIdentifier.allValues
        sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary<NSString *, NSString *> *_Nullable
MTStaticIconNormalizeAliases(NSDictionary<NSString *, NSString *> *aliases,
                             NSError **error) {
    if (![aliases isKindOfClass:NSDictionary.class]) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon aliases are not a dictionary.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *normalized =
        [NSMutableDictionary dictionaryWithCapacity:aliases.count];
    NSMutableDictionary<NSString *, NSString *> *aliasByFoldedKey =
        [NSMutableDictionary dictionaryWithCapacity:aliases.count];
    NSMutableArray<NSString *> *sortedAliases =
        [NSMutableArray arrayWithCapacity:aliases.count];
    for (id rawAlias in aliases) {
        id rawTarget = aliases[rawAlias];
        if (!MTStaticIconBundleIdentifierIsValid(rawAlias) ||
            !MTStaticIconBundleIdentifierIsValid(rawTarget)) {
            MTStaticIconSetConfigurationError(error,
                @"Static icon aliases contain an invalid Bundle ID.");
            return nil;
        }
        [sortedAliases addObject:rawAlias];
    }
    [sortedAliases sortUsingSelector:@selector(compare:)];
    for (NSString *rawAlias in sortedAliases) {
        NSString *rawTarget = aliases[rawAlias];
        NSString *alias = [rawAlias precomposedStringWithCanonicalMapping];
        NSString *target = [rawTarget precomposedStringWithCanonicalMapping];
        NSString *foldedAlias = alias.lowercaseString;
        if (aliasByFoldedKey[foldedAlias] != nil) {
            MTStaticIconSetConfigurationError(error,
                @"Static icon aliases contain a case-insensitive duplicate key.");
            return nil;
        }
        if (normalized.count >= MTStaticIconMaximumBundleAliasCount) {
            MTStaticIconSetConfigurationError(error,
                @"Static icon aliases exceed their collection limit.");
            return nil;
        }
        aliasByFoldedKey[foldedAlias] = alias;
        normalized[alias] = target;
    }
    return [normalized copy];
}

static BOOL MTStaticIconIdentifierContainsIdentifier(NSString *container,
                                                      NSString *candidate) {
    NSString *foldedContainer = container.lowercaseString;
    NSString *foldedCandidate = candidate.lowercaseString;
    NSRange searchRange = NSMakeRange(0, foldedContainer.length);
    while (searchRange.length >= foldedCandidate.length) {
        NSRange match = [foldedContainer rangeOfString:foldedCandidate
                                              options:NSLiteralSearch
                                                range:searchRange];
        if (match.location == NSNotFound) return NO;
        BOOL leftBoundary = match.location == 0 ||
            [foldedContainer characterAtIndex:match.location - 1] == '.';
        NSUInteger end = NSMaxRange(match);
        BOOL rightBoundary = end == foldedContainer.length ||
            [foldedContainer characterAtIndex:end] == '.';
        if (leftBoundary && rightBoundary) return YES;
        NSUInteger next = match.location + 1;
        searchRange = NSMakeRange(next, foldedContainer.length - next);
    }
    return NO;
}

static BOOL MTStaticIconDictionaryHasExactKeys(
    NSDictionary<NSString *, id> *dictionary,
    NSArray<NSString *> *keys) {
    return [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

static NSDictionary<NSString *, id> *_Nullable
MTStaticIconNormalizeMatchingLayer(NSDictionary<NSString *, id> *dictionary,
                                   NSError **error) {
    if (!MTStaticIconDictionaryHasExactKeys(dictionary, @[
            @"bundleAliases", @"fuzzyBundleIdentifiers",
        ])) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon matching layer has an unsupported shape.");
        return nil;
    }
    NSArray<NSString *> *identifiers = MTStaticIconNormalizeIdentifiers(
        dictionary[@"fuzzyBundleIdentifiers"], error);
    NSDictionary<NSString *, NSString *> *aliases =
        MTStaticIconNormalizeAliases(dictionary[@"bundleAliases"], error);
    if (identifiers == nil || aliases == nil) return nil;
    return @{
        @"bundleAliases" : aliases,
        @"fuzzyBundleIdentifiers" : identifiers,
    };
}

static NSArray<NSString *> *MTStaticIconLookupOrderedIdentifiers(
    NSArray<NSString *> *identifiers) {
    return [identifiers sortedArrayUsingComparator:^NSComparisonResult(
        NSString *left, NSString *right) {
        if (left.length != right.length) {
            return left.length > right.length
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left compare:right options:NSLiteralSearch];
    }];
}

@interface MTStaticIconConfiguration ()
@property(nonatomic, copy, readwrite)
    NSArray<NSDictionary<NSString *, NSString *> *> *
        aliasTargetsByFoldedKeyByMatchingLayer;
@property(nonatomic, copy, readwrite)
    NSArray<NSArray<NSString *> *> *lookupOrderedIdentifiersByMatchingLayer;
@end

@implementation MTStaticIconConfiguration

+ (instancetype)configurationWithFuzzyBundleIdentifiers:
                    (NSArray<NSString *> *)fuzzyBundleIdentifiers
                                            bundleAliases:
                    (NSDictionary<NSString *, NSString *> *)bundleAliases {
    NSError *error = nil;
    NSArray<NSString *> *normalizedIdentifiers =
        MTStaticIconNormalizeIdentifiers(fuzzyBundleIdentifiers, &error);
    NSDictionary<NSString *, NSString *> *normalizedAliases =
        MTStaticIconNormalizeAliases(bundleAliases, &error);
    if (normalizedIdentifiers == nil || normalizedAliases == nil ||
        (normalizedIdentifiers.count == 0 && normalizedAliases.count == 0)) {
        return nil;
    }
    return [[self alloc] initWithDictionary:@{
        @"bundleAliases" : normalizedAliases,
        @"fuzzyBundleIdentifiers" : normalizedIdentifiers,
    } error:NULL];
}

+ (instancetype)configurationWithOrderedMatchingLayers:
        (NSArray<NSDictionary<NSString *,id> *> *)orderedMatchingLayers {
    if (![orderedMatchingLayers isKindOfClass:NSArray.class] ||
        orderedMatchingLayers.count == 0 ||
        orderedMatchingLayers.count > MTStaticIconMaximumMatchingLayerCount) {
        return nil;
    }
    return [[self alloc] initWithDictionary:@{
        @"matchingLayers" : orderedMatchingLayers,
    } error:NULL];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                              error:(NSError **)error {
    BOOL flatShape = MTStaticIconDictionaryHasExactKeys(dictionary, @[
        @"bundleAliases", @"fuzzyBundleIdentifiers",
    ]);
    BOOL layeredShape = MTStaticIconDictionaryHasExactKeys(dictionary, @[
        @"matchingLayers",
    ]);
    if (!flatShape && !layeredShape) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon configuration has an unsupported shape.");
        return nil;
    }
    NSArray *rawLayers = flatShape ? @[dictionary] : dictionary[@"matchingLayers"];
    if (![rawLayers isKindOfClass:NSArray.class] || rawLayers.count == 0 ||
        rawLayers.count > MTStaticIconMaximumMatchingLayerCount) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon matching layers exceed their collection limit.");
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *layers =
        [NSMutableArray arrayWithCapacity:rawLayers.count];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *foldedAliases =
        [NSMutableArray arrayWithCapacity:rawLayers.count];
    NSMutableArray<NSArray<NSString *> *> *lookupIdentifiers =
        [NSMutableArray arrayWithCapacity:rawLayers.count];
    NSMutableArray<NSString *> *flattenedIdentifiers = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *flattenedAliases =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seenAliases = [NSMutableSet set];
    NSUInteger totalIdentifierCount = 0;
    NSUInteger totalAliasCount = 0;
    for (id rawLayer in rawLayers) {
        NSDictionary<NSString *, id> *layer =
            MTStaticIconNormalizeMatchingLayer(rawLayer, error);
        if (layer == nil) return nil;
        NSArray<NSString *> *identifiers = layer[@"fuzzyBundleIdentifiers"];
        NSDictionary<NSString *, NSString *> *aliases = layer[@"bundleAliases"];
        if (totalIdentifierCount >
                MTStaticIconMaximumFuzzyBundleIdentifierCount -
                    identifiers.count ||
            totalAliasCount > MTStaticIconMaximumBundleAliasCount -
                    aliases.count) {
            MTStaticIconSetConfigurationError(error,
                @"Static icon matching layers exceed their aggregate limit.");
            return nil;
        }
        totalIdentifierCount += identifiers.count;
        totalAliasCount += aliases.count;
        [layers addObject:layer];
        [lookupIdentifiers addObject:
            MTStaticIconLookupOrderedIdentifiers(identifiers)];

        NSMutableDictionary<NSString *, NSString *> *aliasesByFoldedKey =
            [NSMutableDictionary dictionaryWithCapacity:aliases.count];
        for (NSString *alias in aliases) {
            NSString *folded = alias.lowercaseString;
            aliasesByFoldedKey[folded] = aliases[alias];
            if (![seenAliases containsObject:folded]) {
                flattenedAliases[alias] = aliases[alias];
                [seenAliases addObject:folded];
            }
        }
        [foldedAliases addObject:[aliasesByFoldedKey copy]];
        for (NSString *identifier in identifiers) {
            NSString *folded = identifier.lowercaseString;
            if ([seenIdentifiers containsObject:folded]) continue;
            [flattenedIdentifiers addObject:identifier];
            [seenIdentifiers addObject:folded];
        }
    }
    if (flatShape && flattenedIdentifiers.count == 0 &&
        flattenedAliases.count == 0) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon configuration is empty.");
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _usesOrderedMatchingLayers = layeredShape;
    _orderedMatchingLayers = [layers copy];
    _aliasTargetsByFoldedKeyByMatchingLayer = [foldedAliases copy];
    _lookupOrderedIdentifiersByMatchingLayer = [lookupIdentifiers copy];
    _fuzzyBundleIdentifiers = [flattenedIdentifiers copy];
    _bundleAliases = [flattenedAliases copy];
    _canonicalDictionary = layeredShape
        ? @{ @"matchingLayers" : _orderedMatchingLayers }
        : _orderedMatchingLayers.firstObject;
    return self;
}

- (NSString *)themedBundleIdentifierForRequestedIdentifier:
    (NSString *)requestedIdentifier {
    return [self
        themedBundleIdentifierCandidatesForRequestedIdentifier:
            requestedIdentifier].firstObject;
}

- (NSArray<NSString *> *)
    themedBundleIdentifierCandidatesForRequestedIdentifier:
        (NSString *)requestedIdentifier {
    if (!MTStaticIconBundleIdentifierIsValid(requestedIdentifier)) return @[];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger layerIndex = 0;
         layerIndex < self.orderedMatchingLayers.count; layerIndex++) {
        for (NSString *candidate in [self
                themedBundleIdentifierCandidatesForRequestedIdentifier:
                    requestedIdentifier
                matchingLayerAtIndex:layerIndex]) {
            if ([seen containsObject:candidate]) continue;
            [matches addObject:candidate];
            [seen addObject:candidate];
        }
    }
    return [matches copy];
}

- (NSArray<NSString *> *)
    themedBundleIdentifierCandidatesForRequestedIdentifier:
        (NSString *)requestedIdentifier
                                      matchingLayerAtIndex:
        (NSUInteger)layerIndex {
    if (!MTStaticIconBundleIdentifierIsValid(requestedIdentifier) ||
        layerIndex >= self.orderedMatchingLayers.count) {
        return @[];
    }
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *explicitTarget =
        self.aliasTargetsByFoldedKeyByMatchingLayer[layerIndex][
            requestedIdentifier.lowercaseString];
    if (explicitTarget.length > 0) {
        [matches addObject:explicitTarget];
        [seen addObject:explicitTarget];
    }
    for (NSString *candidate in
            self.lookupOrderedIdentifiersByMatchingLayer[layerIndex]) {
        if ([candidate caseInsensitiveCompare:requestedIdentifier] ==
                NSOrderedSame ||
            MTStaticIconIdentifierContainsIdentifier(requestedIdentifier,
                                                       candidate)) {
            if ([seen containsObject:candidate]) continue;
            [matches addObject:candidate];
            [seen addObject:candidate];
        }
    }
    return [matches copy];
}

@end
