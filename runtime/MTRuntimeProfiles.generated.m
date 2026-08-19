// Generated from RuntimeProfiles.json. Do not edit by hand.
#import "MTRuntimeProfiles.generated.h"

#import <dispatch/dispatch.h>

#import "MTRuntimeProfile.h"

NSString *const MTRuntimeProfileManifestDigest = @"3ab3958f53abcc7b9b80c5015890dfe9353800ebccd74cbaf695ab356a14d4db";

NSArray<MTRuntimeProfile *> *MTRuntimeGeneratedProfiles(void) {
    static NSArray<MTRuntimeProfile *> *profiles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        profiles = @[
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"mobilephone.dialer"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.mobilephone"
   executableName:@"MobilePhone"
       adapterIDs:@[ @"mobilephone.dialer-buttons" ]
        moduleIDs:@[ @"dialer.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"photos.share-sheet.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.mobileslideshow"
   executableName:@"MobileSlideShow"
       adapterIDs:@[ @"share-sheet.activity-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"icon-mask.snapshot", @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"preferences.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.Preferences"
   executableName:@"Preferences"
       adapterIDs:@[ @"preferences.icon-image-cache" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"share-sheet.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.SharingUIService"
   executableName:@"SharingUIService"
       adapterIDs:@[ @"share-sheet.activity-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"icon-mask.snapshot", @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"sharingd.share-sheet.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.sharingd"
   executableName:@"sharingd"
       adapterIDs:@[ @"share-sheet.activity-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"icon-mask.snapshot", @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"spotlight.application-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.Spotlight"
   executableName:@"Spotlight"
       adapterIDs:@[ @"spotlight.icon-image-cache", @"springboard.clock-image-set", @"spotlight.search-ui-app-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"calendar-icons.composite", @"clock-icons.snapshot", @"icon-mask.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"springboard.icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.springboard"
   executableName:@"SpringBoard"
       adapterIDs:@[ @"springboard.icon-image-cache", @"springboard.clock-image-set", @"springboard.folder-image", @"springboard.badge-background", @"springboard.icon-shadow", @"springboard.statusbar-signal-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"calendar-icons.composite", @"clock-icons.snapshot", @"icon-mask.snapshot", @"folder-icons.snapshot", @"badges.snapshot", @"icon-shadow.snapshot", @"statusbar.snapshot" ]]
        ];
    });
    return profiles;
}
