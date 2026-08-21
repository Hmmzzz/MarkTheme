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
