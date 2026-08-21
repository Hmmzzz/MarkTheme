#import "MTLayerResolver.h"

#import "MTDiagnostic.h"
#import "MTIdentifier.h"
#import "MTResourceKey.h"

static BOOL MTRelativeAssetPathIsSafe(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 ||
        [path hasPrefix:@"/"] || [path hasSuffix:@"/"] ||
        [path containsString:@"\\"] ||
        [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) {
        return NO;
    }
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSString *component in components) {
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."]) {
            return NO;
        }
        for (NSUInteger index = 0; index < component.length; index++) {
            unichar character = [component characterAtIndex:index];
            if (character == 0 || character < 0x20 || character == 0x7f) {
                return NO;
            }
        }
    }
    return YES;
}

@implementation MTResourceCandidate

- (instancetype)initWithResourceKey:(MTResourceKey *)resourceKey
                              themeID:(NSString *)themeID
                     relativeAssetPath:(NSString *)relativeAssetPath
                        layerPriority:(NSInteger)layerPriority
                            matchRank:(NSUInteger)matchRank
                      explicitOverride:(BOOL)explicitOverride
                                error:(NSError **)error {
    NSString *normalizedThemeID = MTNormalizeIdentifier(themeID, error);
    if (![resourceKey isKindOfClass:MTResourceKey.class] ||
        normalizedThemeID == nil || !MTRelativeAssetPathIsSafe(relativeAssetPath)) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:@"com.hmmzzz.marktheme64e.layer-resolver"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Resource candidate is invalid."
            }];
        }
        return nil;
    }

    self = [super init];
    if (self == nil) return nil;
    _resourceKey = resourceKey;
    _themeID = [normalizedThemeID copy];
    _relativeAssetPath = [[relativeAssetPath precomposedStringWithCanonicalMapping] copy];
    _layerPriority = layerPriority;
    _matchRank = matchRank;
    _explicitOverride = explicitOverride;
    return self;
}

@end

@interface MTResolutionResult ()
- (instancetype)initWithWinner:(nullable MTResourceCandidate *)winner
                       shadowed:(NSArray<MTResourceCandidate *> *)shadowed
                        conflict:(BOOL)conflict
                      diagnostic:(nullable MTDiagnostic *)diagnostic;
@end

@implementation MTResolutionResult

- (instancetype)initWithWinner:(MTResourceCandidate *)winner
                       shadowed:(NSArray<MTResourceCandidate *> *)shadowed
                        conflict:(BOOL)conflict
                      diagnostic:(MTDiagnostic *)diagnostic {
    self = [super init];
    if (self == nil) return nil;
    _winner = winner;
    _shadowed = [shadowed copy];
    _conflict = conflict;
    _diagnostic = diagnostic;
    return self;
}

@end

static NSComparisonResult MTCompareCandidates(MTResourceCandidate *left,
                                               MTResourceCandidate *right) {
    if (left.isExplicitOverride != right.isExplicitOverride) {
        return left.isExplicitOverride ? NSOrderedAscending : NSOrderedDescending;
    }
    if (left.layerPriority != right.layerPriority) {
        return left.layerPriority > right.layerPriority
            ? NSOrderedAscending : NSOrderedDescending;
    }
    if (left.matchRank != right.matchRank) {
        return left.matchRank < right.matchRank
            ? NSOrderedAscending : NSOrderedDescending;
    }
    NSComparisonResult themeOrder = [left.themeID compare:right.themeID
                                                    options:NSLiteralSearch];
    if (themeOrder != NSOrderedSame) return themeOrder;
    return [left.relativeAssetPath compare:right.relativeAssetPath
                                    options:NSLiteralSearch];
}

static BOOL MTResolutionPriorityIsEqual(MTResourceCandidate *left,
                                        MTResourceCandidate *right) {
    return left.isExplicitOverride == right.isExplicitOverride &&
           left.layerPriority == right.layerPriority &&
           left.matchRank == right.matchRank;
}

@implementation MTLayerResolver

+ (MTResolutionResult *)resolveCandidates:(NSArray<MTResourceCandidate *> *)candidates
                           forResourceKey:(MTResourceKey *)resourceKey {
    NSArray<MTResourceCandidate *> *sorted = [candidates
        sortedArrayUsingComparator:^NSComparisonResult(MTResourceCandidate *left,
                                                       MTResourceCandidate *right) {
            return MTCompareCandidates(left, right);
        }];

    for (MTResourceCandidate *candidate in sorted) {
        if (![candidate.resourceKey isEqual:resourceKey]) {
            MTDiagnostic *diagnostic = [[MTDiagnostic alloc]
                initWithSeverity:MTDiagnosticSeverityError
                            code:@"resolution.mixed-resource-keys"
                         summary:@"Candidates belong to different resource keys."
                     resourceKey:resourceKey
                         details:@{}
                           error:NULL];
            return [[MTResolutionResult alloc] initWithWinner:nil
                                                     shadowed:sorted
                                                      conflict:YES
                                                    diagnostic:diagnostic];
        }
    }

    if (sorted.count == 0) {
        return [[MTResolutionResult alloc] initWithWinner:nil
                                                 shadowed:@[]
                                                  conflict:NO
                                                diagnostic:nil];
    }

    MTResourceCandidate *first = sorted.firstObject;
    if (sorted.count > 1 &&
        MTResolutionPriorityIsEqual(first, sorted[1])) {
        MTDiagnostic *diagnostic = [[MTDiagnostic alloc]
            initWithSeverity:MTDiagnosticSeverityError
                        code:@"resolution.conflict"
                     summary:@"Multiple candidates have the same winning priority."
                 resourceKey:resourceKey
                     details:@{
                @"themeA" : first.themeID,
                @"themeB" : sorted[1].themeID,
            }
                       error:NULL];
        return [[MTResolutionResult alloc] initWithWinner:nil
                                                 shadowed:sorted
                                                  conflict:YES
                                                diagnostic:diagnostic];
    }

    NSArray<MTResourceCandidate *> *shadowed = sorted.count > 1
        ? [sorted subarrayWithRange:NSMakeRange(1, sorted.count - 1)]
        : @[];
    return [[MTResolutionResult alloc] initWithWinner:first
                                             shadowed:shadowed
                                              conflict:NO
                                            diagnostic:nil];
}

@end
