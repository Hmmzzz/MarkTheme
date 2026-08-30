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
                    @"calendar-ui-kit.dynamic-icon-source",
                    @"springboard.calendar-appearance",
                    @"spotlight.calendar-appearance",
               ]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
