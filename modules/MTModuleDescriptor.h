#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTRefreshRequirement) {
    MTRefreshRequirementLive = 0,
    MTRefreshRequirementTargeted = 1,
    MTRefreshRequirementRespring = 2,
    MTRefreshRequirementUnsupported = 3,
};

FOUNDATION_EXPORT NSString *MTRefreshRequirementName(
    MTRefreshRequirement requirement);

@interface MTModuleDescriptor : NSObject

@property(nonatomic, copy, readonly) NSString *moduleID;
@property(nonatomic, assign, readonly) NSUInteger apiVersion;
@property(nonatomic, copy, readonly) NSArray<NSString *> *resourceKinds;
@property(nonatomic, copy, readonly) NSArray<NSString *> *dependencies;
@property(nonatomic, copy, readonly) NSArray<NSString *> *processAdapters;
@property(nonatomic, assign, readonly) MTRefreshRequirement refreshRequirement;

- (nullable instancetype)initWithModuleID:(NSString *)moduleID
                                apiVersion:(NSUInteger)apiVersion
                             resourceKinds:(NSArray<NSString *> *)resourceKinds
                              dependencies:(NSArray<NSString *> *)dependencies
                           processAdapters:(NSArray<NSString *> *)processAdapters
                        refreshRequirement:(MTRefreshRequirement)refreshRequirement
                                     error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
