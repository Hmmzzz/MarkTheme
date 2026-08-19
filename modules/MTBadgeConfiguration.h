#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTBadgeConfigurationErrorDomain;

// The importer records a deterministic authored default. It is not the
// system appearance: light/dark remains a separate resource trait axis.
@interface MTBadgeConfiguration : NSObject

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
