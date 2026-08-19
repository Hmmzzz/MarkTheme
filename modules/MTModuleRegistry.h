#import <Foundation/Foundation.h>

@class MTModuleDescriptor;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTModuleRegistryErrorDomain;

@interface MTModuleRegistry : NSObject

@property(nonatomic, copy, readonly) NSArray<MTModuleDescriptor *> *descriptors;

- (nullable instancetype)initWithDescriptors:(NSArray<MTModuleDescriptor *> *)descriptors
                                        error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (nullable MTModuleDescriptor *)descriptorForModuleID:(NSString *)moduleID;

@end

NS_ASSUME_NONNULL_END
