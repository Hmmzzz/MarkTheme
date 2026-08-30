#import "MTStatusBarModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTStatusBarModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTStatusBarModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[ @"ui.statusbar-image" ]
                dependencies:@[]
             processAdapters:@[ @"springboard.statusbar-signal-image" ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
