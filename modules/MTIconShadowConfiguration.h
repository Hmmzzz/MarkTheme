#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconShadowConfigurationErrorDomain;

// The authored shadow style is independent from scale/device resource traits.
@interface MTIconShadowConfiguration : NSObject

@property(nonatomic, copy, readonly) NSString *defaultVariant;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, id> *canonicalDictionary;

+ (nullable instancetype)configurationWithDefaultVariant:
    (NSString *)defaultVariant;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
