#import "MTStaticIconConfiguration.h"

NSUInteger const MTStaticIconMaximumFuzzyBundleIdentifierCount = 256;
NSUInteger const MTStaticIconMaximumBundleAliasCount = 256;

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

BOOL MTStaticIconSourceVariantIsSupported(NSString *variant) {
    return [variant isKindOfClass:NSString.class] &&
        [MTStaticIconSourceVariants() containsObject:variant];
}

static NSString *const MTStaticIconConfigurationErrorDomain =
    @"com.hmmzzz.marktheme64e.static-icon-configuration";

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

- (instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                              error:(NSError **)error {
    NSSet<NSString *> *expected = [NSSet setWithArray:@[
        @"bundleAliases", @"fuzzyBundleIdentifiers",
    ]];
    if (![dictionary isKindOfClass:NSDictionary.class] ||
        dictionary.count != expected.count ||
        ![[NSSet setWithArray:dictionary.allKeys] isEqualToSet:expected]) {
        MTStaticIconSetConfigurationError(error,
            @"Static icon configuration has an unsupported shape.");
        return nil;
    }
    NSArray<NSString *> *identifiers = MTStaticIconNormalizeIdentifiers(
        dictionary[@"fuzzyBundleIdentifiers"], error);
    NSDictionary<NSString *, NSString *> *aliases =
        MTStaticIconNormalizeAliases(dictionary[@"bundleAliases"], error);
    if (identifiers == nil || aliases == nil ||
        (identifiers.count == 0 && aliases.count == 0)) {
        if (error != NULL && *error == nil) {
            MTStaticIconSetConfigurationError(error,
                @"Static icon configuration is empty.");
        }
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _fuzzyBundleIdentifiers = [identifiers copy];
    _bundleAliases = [aliases copy];
    _canonicalDictionary = @{
        @"bundleAliases" : _bundleAliases,
        @"fuzzyBundleIdentifiers" : _fuzzyBundleIdentifiers,
    };
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
    NSString *explicitTarget = self.bundleAliases[requestedIdentifier];
    if (explicitTarget == nil) {
        for (NSString *alias in [self.bundleAliases.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            if ([alias caseInsensitiveCompare:requestedIdentifier] ==
                    NSOrderedSame) {
                explicitTarget = self.bundleAliases[alias];
                break;
            }
        }
    }
    if (explicitTarget.length > 0) {
        [matches addObject:explicitTarget];
        [seen addObject:explicitTarget];
    }

    NSMutableArray<NSString *> *fuzzyMatches = [NSMutableArray array];
    for (NSString *candidate in self.fuzzyBundleIdentifiers) {
        if ([candidate caseInsensitiveCompare:requestedIdentifier] ==
                NSOrderedSame ||
            MTStaticIconIdentifierContainsIdentifier(requestedIdentifier,
                                                       candidate)) {
            [fuzzyMatches addObject:candidate];
            continue;
        }
    }
    [fuzzyMatches sortUsingComparator:^NSComparisonResult(NSString *left,
                                                           NSString *right) {
        BOOL leftEqual = [left caseInsensitiveCompare:requestedIdentifier] ==
            NSOrderedSame;
        BOOL rightEqual = [right caseInsensitiveCompare:requestedIdentifier] ==
            NSOrderedSame;
        if (leftEqual != rightEqual) {
            return leftEqual ? NSOrderedAscending : NSOrderedDescending;
        }
        if (left.length != right.length) {
            return left.length > right.length
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left compare:right options:NSLiteralSearch];
    }];
    for (NSString *candidate in fuzzyMatches) {
        if ([seen containsObject:candidate]) continue;
        [matches addObject:candidate];
        [seen addObject:candidate];
    }
    return [matches copy];
}

@end
