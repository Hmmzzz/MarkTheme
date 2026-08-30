#import "MTIconShadowsModule.h"

#import "MTIconShadowContract.h"
#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTIconShadowsModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTIconShadowsModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[ @"icon.shadow" ]
                dependencies:@[]
             processAdapters:@[ @"springboard-home.icon-shadow-carrier" ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
