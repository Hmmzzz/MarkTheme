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
                    @"preferences.application-icon-image",
                    @"springboard.icon-image-cache",
                    @"spotlight.icon-image-cache",
                    @"spotlight.search-ui-app-image",
                    @"share-sheet.activity-image",
               ]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
