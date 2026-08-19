#import "MTCalendarIconsModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

NSString *const MTCalendarIconsModuleID = @"icons.calendar";

MTModuleDescriptor *MTCalendarIconsModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTCalendarIconsModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[@"icon.calendar.composite"]
                dependencies:@[@"icons.static"]
             processAdapters:@[
                    @"springboard.icon-image-cache",
                    @"spotlight.icon-image-cache",
                    @"spotlight.search-ui-app-image",
               ]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
