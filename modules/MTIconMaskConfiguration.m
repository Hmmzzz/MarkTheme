#import "MTIconMaskConfiguration.h"

#import <CoreFoundation/CoreFoundation.h>

NSString *const MTIconMaskConfigurationErrorDomain =
    @"com.hmmzzz.marktheme64e.icon-mask-configuration";

@implementation MTIconMaskConfiguration

+ (instancetype)enabledConfiguration {
    return [[self alloc] initWithDictionary:@{ @"enabled" : @YES }
                                      error:NULL];
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                               error:(NSError **)error {
    BOOL exactKeys = [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == 1;
    id enabled = exactKeys ? dictionary[@"enabled"] : nil;
    BOOL validBoolean = [enabled isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID();
    if (!exactKeys || !validBoolean || ![enabled boolValue]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTIconMaskConfigurationErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Icon mask configuration must be exactly enabled."
            }];
        }
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _enabled = YES;
    _canonicalDictionary = @{ @"enabled" : @YES };
    return self;
}

@end
