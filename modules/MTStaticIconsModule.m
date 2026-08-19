#import "MTStaticIconsModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTStaticIconsModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:@"icons.static"
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[@"icon.primary", @"icon.alternate"]
                dependencies:@[]
             processAdapters:@[
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
