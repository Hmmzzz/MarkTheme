#import "MTIconShadowConfiguration.h"

#import "MTIdentifier.h"

NSString *const MTIconShadowConfigurationErrorDomain =
    @"com.hmmzzz.marktheme.icon-shadow-configuration";

@implementation MTIconShadowConfiguration

+ (instancetype)configurationWithDefaultVariant:(NSString *)defaultVariant {
    return [[self alloc] initWithDictionary:@{
        @"defaultVariant" : defaultVariant ?: @"",
    } error:NULL];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                               error:(NSError **)error {
    BOOL exactKeys = [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == 1;
    NSString *variant = exactKeys &&
        [dictionary[@"defaultVariant"] isKindOfClass:NSString.class]
        ? MTNormalizeIdentifier(dictionary[@"defaultVariant"], NULL) : nil;
    if (!exactKeys || variant == nil) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTIconShadowConfigurationErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Icon Shadow configuration requires one default style variant."
            }];
        }
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _defaultVariant = [variant copy];
    _canonicalDictionary = @{ @"defaultVariant" : _defaultVariant };
    return self;
}

@end
