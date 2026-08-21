#import "MTModuleDescriptor.h"

#import "MTIdentifier.h"

NSString *MTRefreshRequirementName(MTRefreshRequirement requirement) {
    switch (requirement) {
        case MTRefreshRequirementLive:
            return @"live";
        case MTRefreshRequirementTargeted:
            return @"targeted";
        case MTRefreshRequirementRespring:
            return @"respring";
        case MTRefreshRequirementUnsupported:
            return @"unsupported";
    }
    return @"invalid";
}

static NSArray<NSString *> *_Nullable MTNormalizeIdentifierList(
    NSArray<NSString *> *values,
    NSError **error) {
    if (![values isKindOfClass:NSArray.class]) return nil;
    NSMutableOrderedSet<NSString *> *normalized = [NSMutableOrderedSet orderedSet];
    for (id value in values) {
        if (![value isKindOfClass:NSString.class]) return nil;
        NSString *identifier = MTNormalizeIdentifier(value, error);
        if (identifier == nil || [normalized containsObject:identifier]) return nil;
        [normalized addObject:identifier];
    }
    return [normalized.array sortedArrayUsingSelector:@selector(compare:)];
}

@implementation MTModuleDescriptor

- (instancetype)initWithModuleID:(NSString *)moduleID
                        apiVersion:(NSUInteger)apiVersion
                     resourceKinds:(NSArray<NSString *> *)resourceKinds
                      dependencies:(NSArray<NSString *> *)dependencies
                   processAdapters:(NSArray<NSString *> *)processAdapters
                refreshRequirement:(MTRefreshRequirement)refreshRequirement
                             error:(NSError **)error {
    NSString *normalizedModuleID = MTNormalizeIdentifier(moduleID, error);
    NSArray<NSString *> *normalizedKinds =
        MTNormalizeIdentifierList(resourceKinds, error);
    NSArray<NSString *> *normalizedDependencies =
        MTNormalizeIdentifierList(dependencies, error);
    NSArray<NSString *> *normalizedAdapters =
        MTNormalizeIdentifierList(processAdapters, error);
    if (normalizedModuleID == nil || apiVersion == 0 ||
        normalizedKinds == nil || normalizedKinds.count == 0 ||
        normalizedDependencies == nil || normalizedAdapters == nil ||
        refreshRequirement > MTRefreshRequirementUnsupported ||
        [normalizedDependencies containsObject:normalizedModuleID]) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:@"com.hmmzzz.marktheme64e.module-descriptor"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Module descriptor is invalid."
            }];
        }
        return nil;
    }

    self = [super init];
    if (self == nil) return nil;
    _moduleID = [normalizedModuleID copy];
    _apiVersion = apiVersion;
    _resourceKinds = [normalizedKinds copy];
    _dependencies = [normalizedDependencies copy];
    _processAdapters = [normalizedAdapters copy];
    _refreshRequirement = refreshRequirement;
    return self;
}

@end
