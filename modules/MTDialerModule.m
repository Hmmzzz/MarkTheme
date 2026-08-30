#import "MTDialerModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTDialerModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTDialerModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[ @"ui.phone.dialer-image" ]
                dependencies:@[]
             processAdapters:@[ @"mobilephone.dialer-buttons" ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
