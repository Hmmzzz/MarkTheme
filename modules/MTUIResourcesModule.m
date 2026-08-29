#import "MTUIResourcesModule.h"

#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

NSString *const MTUIResourcesModuleID = @"ui.resources";

MTModuleDescriptor *MTUIResourcesModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTUIResourcesModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[
                    @"ui.preferences.icon",
                    @"ui.share.activity",
               ]
                dependencies:@[]
             processAdapters:@[
                    @"preferences.ui-resource-image",
                    @"share-sheet.activity-glyph",
               ]
          refreshRequirement:MTRefreshRequirementTargeted
                       error:NULL];
    });
    return descriptor;
}
