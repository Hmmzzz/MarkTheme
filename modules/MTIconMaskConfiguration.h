#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconMaskConfigurationErrorDomain;

@interface MTIconMaskConfiguration : NSObject

@property(nonatomic, assign, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *canonicalDictionary;

+ (instancetype)enabledConfiguration;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
