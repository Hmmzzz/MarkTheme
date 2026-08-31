#import "MTIconOverlayModule.h"

#import "MTIconOverlayContract.h"
#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTIconOverlayModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTIconOverlayModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[@"icon.overlay"]
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
