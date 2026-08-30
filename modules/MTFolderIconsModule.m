#import "MTFolderIconsModule.h"

#import "MTFolderIconContract.h"
#import "MTModuleDescriptor.h"
#import "MTVersionContracts.h"

MTModuleDescriptor *MTFolderIconsModuleDescriptor(void) {
    static MTModuleDescriptor *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descriptor = [[MTModuleDescriptor alloc]
            initWithModuleID:MTFolderIconsModuleID
                  apiVersion:MTModuleAPIVersion
               resourceKinds:@[
                   @"folder.background", @"folder.background.light",
               ]
                dependencies:@[]
             processAdapters:@[@"springboard-home.folder-icon-source"]
          refreshRequirement:MTRefreshRequirementRespring
                       error:NULL];
    });
    return descriptor;
}
