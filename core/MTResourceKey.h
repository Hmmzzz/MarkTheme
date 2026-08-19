#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTResourceKeyErrorDomain;

@interface MTResourceKey : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *moduleID;
@property(nonatomic, copy, readonly) NSString *surface;
@property(nonatomic, copy, readonly) NSString *subject;
@property(nonatomic, copy, readonly) NSString *variant;
@property(nonatomic, assign, readonly) NSUInteger scale;
@property(nonatomic, copy, readonly) NSString *trait;
@property(nonatomic, copy, readonly) NSString *canonicalString;

- (nullable instancetype)initWithModuleID:(NSString *)moduleID
                                  surface:(NSString *)surface
                                  subject:(NSString *)subject
                                  variant:(NSString *)variant
                                    scale:(NSUInteger)scale
                                    trait:(NSString *)trait
                                    error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
