// Generated from RuntimeProfiles.json. Do not edit by hand.
#import "MTRuntimeProfiles.generated.h"

#import <dispatch/dispatch.h>

#import "MTRuntimeProfile.h"

NSString *const MTRuntimeProfileManifestDigest = @"858e6ce54e9c0f03cab9ca6bcaa5ec3a0ee7005a42a81c45fc8f03988f57c157";

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
       adapterIDs:@[ @"share-sheet.activity-glyph", @"share-sheet.application-icon-native-invalidation" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"preferences.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.Preferences"
   executableName:@"Preferences"
       adapterIDs:@[ @"preferences.ui-resource-image", @"preferences.application-icon-native-invalidation" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"share-sheet.loaded-host.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.ShareSheet"
   executableName:@"ShareSheet"
       adapterIDs:@[ @"share-sheet.activity-glyph", @"share-sheet.application-icon-native-invalidation" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"share-sheet.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.SharingUIService"
   executableName:@"SharingUIService"
       adapterIDs:@[ @"share-sheet.activity-glyph", @"share-sheet.application-icon-native-invalidation" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"sharingd.share-sheet.ui-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.sharingd"
   executableName:@"sharingd"
       adapterIDs:@[ @"share-sheet.activity-glyph", @"share-sheet.application-icon-native-invalidation" ]
        moduleIDs:@[ @"ui-resources.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"spotlight.application-icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.Spotlight"
   executableName:@"Spotlight"
       adapterIDs:@[ @"spotlight.application-icon-native-invalidation", @"springboard.clock-image-set", @"spotlight.calendar-icon-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"calendar-icons.composite", @"clock-icons.snapshot", @"icon-mask.snapshot", @"icon-overlay.snapshot" ]],
[[MTRuntimeProfile alloc]
    initWithImageID:@"runtime.system-ui"
        profileID:@"springboard.icons"
             mode:MTRuntimeProfileModeProcessAdapters
 bundleIdentifier:@"com.apple.springboard"
   executableName:@"SpringBoard"
       adapterIDs:@[ @"springboard.application-icon-native-invalidation", @"springboard.icon-morph-carrier", @"springboard.calendar-application-icon", @"springboard.clock-image-set", @"springboard.folder-image", @"springboard.badge-background", @"springboard.icon-shadow", @"springboard.statusbar-signal-image" ]
        moduleIDs:@[ @"static-icons.snapshot", @"calendar-icons.composite", @"clock-icons.snapshot", @"icon-mask.snapshot", @"icon-overlay.snapshot", @"folder-icons.snapshot", @"badges.snapshot", @"icon-shadow.snapshot", @"statusbar.snapshot" ]]
        ];
    });
    return profiles;
}
