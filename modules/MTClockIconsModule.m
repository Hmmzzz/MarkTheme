#import "MTClockIconsModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTClockIconsModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTClockIconsModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[
                   @"icon.clock.background", @"icon.clock.hand",
               ]
                dependencies:@[@"icons.static"]
             processAdapters:@[@"springboard.clock-image-set"]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
