#import "MTIconMaskModule.h"

#import "MTIconMaskContract.h"
#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTIconMaskModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTIconMaskModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[@"icon.mask", @"icon.pattern"]
                dependencies:@[]
             processAdapters:@[
                    @"iconservices.application-icon-source",
                    @"springboard.icon-morph-carrier",
                    @"springboard.notification-icon-source",
               ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
