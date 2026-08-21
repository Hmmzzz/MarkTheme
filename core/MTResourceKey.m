#import "MTResourceKey.h"

#import "MTIdentifier.h"

NSString *const MTResourceKeyErrorDomain = @"com.hmmzzz.marktheme64e.resource-key";

static NSString *_Nullable MTNormalizeSubject(NSString *subject,
                                              NSError **error) {
    if (![subject isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [subject precomposedStringWithCanonicalMapping];
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length == 0 || utf8.length > 255) return nil;

    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character == 0 || character == '/' || character == '\\' ||
            character < 0x20 || character == 0x7f) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:MTResourceKeyErrorDomain
                                             code:2
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Resource subject contains an unsafe character."
                }];
            }
            return nil;
        }
    }
    return normalized;
}

static NSString *MTLengthPrefixedComponent(NSString *component) {
    NSUInteger byteLength =
        [component lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"%lu:%@",
                                      (unsigned long)byteLength,
                                      component];
}

@implementation MTResourceKey

- (instancetype)initWithModuleID:(NSString *)moduleID
                          surface:(NSString *)surface
                          subject:(NSString *)subject
                          variant:(NSString *)variant
                            scale:(NSUInteger)scale
                            trait:(NSString *)trait
                            error:(NSError **)error {
    NSError *identifierError = nil;
    NSString *normalizedModule = MTNormalizeIdentifier(moduleID, &identifierError);
    NSString *normalizedSurface = MTNormalizeIdentifier(surface, &identifierError);
    NSString *normalizedVariant = MTNormalizeIdentifier(variant, &identifierError);
    NSString *normalizedTrait = MTNormalizeIdentifier(trait, &identifierError);
    NSString *normalizedSubject = MTNormalizeSubject(subject, error);
    if (normalizedModule == nil || normalizedSurface == nil ||
        normalizedVariant == nil || normalizedTrait == nil ||
        normalizedSubject == nil || scale > 3) {
        if (error != NULL && *error == nil) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
                @"Resource key components are invalid."
                forKey:NSLocalizedDescriptionKey];
            if (identifierError != nil) {
                userInfo[NSUnderlyingErrorKey] = identifierError;
            }
            *error = [NSError errorWithDomain:MTResourceKeyErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return nil;
    }

    self = [super init];
    if (self == nil) return nil;
    _moduleID = [normalizedModule copy];
    _surface = [normalizedSurface copy];
    _subject = [normalizedSubject copy];
    _variant = [normalizedVariant copy];
    _scale = scale;
    _trait = [normalizedTrait copy];
    _canonicalString = [[NSString stringWithFormat:@"mtk1|%@|%@|%@|%@|%lu|%@",
        MTLengthPrefixedComponent(_moduleID),
        MTLengthPrefixedComponent(_surface),
        MTLengthPrefixedComponent(_subject),
        MTLengthPrefixedComponent(_variant),
        (unsigned long)_scale,
        MTLengthPrefixedComponent(_trait)] copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (NSUInteger)hash {
    return self.canonicalString.hash;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:MTResourceKey.class]) return NO;
    return [self.canonicalString
        isEqualToString:((MTResourceKey *)object).canonicalString];
}

- (NSString *)description {
    return self.canonicalString;
}

@end
