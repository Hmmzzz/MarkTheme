#import "MTModuleRegistry.h"

#import "MTIdentifier.h"
#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

NSString *const MTModuleRegistryErrorDomain = @"com.hmmzzz.marktheme.module-registry";

static BOOL MTRegistrySetError(NSError **error,
                               NSInteger code,
                               NSString *description,
                               NSString *_Nullable moduleID) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
            description forKey:NSLocalizedDescriptionKey];
        if (moduleID != nil) userInfo[@"moduleID"] = moduleID;
        *error = [NSError errorWithDomain:MTModuleRegistryErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTRegistryVisitModule(
    NSString *moduleID,
    NSDictionary<NSString *, MTModuleDescriptor *> *byID,
    NSMutableSet<NSString *> *visiting,
    NSMutableSet<NSString *> *visited,
    NSError **error) {
    if ([visited containsObject:moduleID]) return YES;
    if ([visiting containsObject:moduleID]) {
        return MTRegistrySetError(error, 4,
            @"Module dependency graph contains a cycle.", moduleID);
    }
    [visiting addObject:moduleID];
    MTModuleDescriptor *descriptor = byID[moduleID];
    for (NSString *dependency in descriptor.dependencies) {
        if (!MTRegistryVisitModule(dependency, byID, visiting, visited, error)) {
            return NO;
        }
    }
    [visiting removeObject:moduleID];
    [visited addObject:moduleID];
    return YES;
}

@interface MTModuleRegistry ()
@property(nonatomic, copy) NSDictionary<NSString *, MTModuleDescriptor *> *byID;
@end

@implementation MTModuleRegistry

- (instancetype)initWithDescriptors:(NSArray<MTModuleDescriptor *> *)descriptors
                                error:(NSError **)error {
    if (![descriptors isKindOfClass:NSArray.class] || descriptors.count == 0) {
        MTRegistrySetError(error, 1, @"Module registry cannot be empty.", nil);
        return nil;
    }

    NSMutableDictionary<NSString *, MTModuleDescriptor *> *byID =
        [NSMutableDictionary dictionary];
    for (id object in descriptors) {
        if (![object isKindOfClass:MTModuleDescriptor.class]) {
            MTRegistrySetError(error, 1,
                @"Module registry contains an invalid descriptor.", nil);
            return nil;
        }
        MTModuleDescriptor *descriptor = object;
        if (descriptor.apiVersion != MTModuleAPIVersion) {
            MTRegistrySetError(error, 2,
                @"Module API version is incompatible.", descriptor.moduleID);
            return nil;
        }
        if (byID[descriptor.moduleID] != nil) {
            MTRegistrySetError(error, 2,
                @"Module ID is registered more than once.", descriptor.moduleID);
            return nil;
        }
        byID[descriptor.moduleID] = descriptor;
    }

    for (MTModuleDescriptor *descriptor in byID.allValues) {
        for (NSString *dependency in descriptor.dependencies) {
            if (byID[dependency] == nil) {
                MTRegistrySetError(error, 3,
                    @"Module dependency is not registered.", dependency);
                return nil;
            }
        }
    }

    NSMutableSet<NSString *> *visiting = [NSMutableSet set];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSString *moduleID in byID) {
        if (!MTRegistryVisitModule(moduleID, byID, visiting, visited, error)) {
            return nil;
        }
    }

    self = [super init];
    if (self == nil) return nil;
    _byID = [byID copy];
    _descriptors = [[byID.allValues
        sortedArrayUsingComparator:^NSComparisonResult(MTModuleDescriptor *left,
                                                       MTModuleDescriptor *right) {
            return [left.moduleID compare:right.moduleID options:NSLiteralSearch];
        }] copy];
    return self;
}

- (MTModuleDescriptor *)descriptorForModuleID:(NSString *)moduleID {
    NSString *normalized = MTNormalizeIdentifier(moduleID, NULL);
    return normalized != nil ? self.byID[normalized] : nil;
}

@end
