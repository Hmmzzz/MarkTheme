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
                    @"iconservices.application-icon-source",
                    @"springboard.application-icon-native-invalidation",
                    @"springboard.icon-morph-carrier",
                    @"spotlight.application-icon-native-invalidation",
                    @"preferences.application-icon-native-invalidation",
                    @"share-sheet.application-icon-native-invalidation",
               ]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
