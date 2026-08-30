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
                    @"iconservices.application-icon-source",
                    @"springboard.application-icon-native-invalidation",
                    @"springboard.icon-morph-carrier",
                    @"springboard.notification-icon-source",
                    @"spotlight.application-icon-native-invalidation",
                    @"preferences.application-icon-native-invalidation",
                    @"share-sheet.application-icon-native-invalidation",
               ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
