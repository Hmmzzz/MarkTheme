#import "MTBadgesModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTBadgesModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTBadgesModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[ @"badge.background" ]
                dependencies:@[]
             processAdapters:@[ @"springboard.badge-background" ]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
