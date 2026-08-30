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
