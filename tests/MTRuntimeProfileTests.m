#import "MTRuntimeProfileTests.h"

#import "MTRuntimeProfile.h"
#import "MTRuntimeProfiles.generated.h"

static NSUInteger MTRuntimeProfileAssertionCount = 0;

static void MTRuntimeProfileAssert(BOOL condition, NSString *message) {
    MTRuntimeProfileAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static MTRuntimeProcessIdentity *MTRuntimeTestIdentity(
    NSString *bundleIdentifier,
    NSString *executableName) {
    return [[MTRuntimeProcessIdentity alloc]
        initWithBundleIdentifier:bundleIdentifier
                  executableName:executableName];
}

NSUInteger MTRunRuntimeProfileTests(void) {
    MTRuntimeProfileAssertionCount = 0;
    NSArray<MTRuntimeProfile *> *profiles = MTRuntimeGeneratedProfiles();
    MTRuntimeProfileAssert(profiles.count == 8,
        @"The system UI image must compile exactly eight process profiles");
    MTRuntimeProfile *profile = nil;
    MTRuntimeProfile *preferencesProfile = nil;
    MTRuntimeProfile *shareSheetProfile = nil;
    MTRuntimeProfile *loadedShareSheetProfile = nil;
    MTRuntimeProfile *photosShareSheetProfile = nil;
    MTRuntimeProfile *sharingdProfile = nil;
    MTRuntimeProfile *dialerProfile = nil;
    MTRuntimeProfile *spotlightProfile = nil;
    for (MTRuntimeProfile *candidate in profiles) {
        if ([candidate.profileID isEqualToString:@"springboard.icons"]) {
            profile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"preferences.ui-icons"]) {
            preferencesProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"share-sheet.ui-icons"]) {
            shareSheetProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"share-sheet.loaded-host.ui-icons"]) {
            loadedShareSheetProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"photos.share-sheet.ui-icons"]) {
            photosShareSheetProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"sharingd.share-sheet.ui-icons"]) {
            sharingdProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"mobilephone.dialer"]) {
            dialerProfile = candidate;
        } else if ([candidate.profileID
                isEqualToString:@"spotlight.application-icons"]) {
            spotlightProfile = candidate;
        }
    }
    MTRuntimeProfileAssert(
        [profile.imageID isEqualToString:@"runtime.system-ui"] &&
        [profile.profileID isEqualToString:@"springboard.icons"] &&
        profile.mode == MTRuntimeProfileModeProcessAdapters,
        @"The first Runtime profile must be the ProcessAdapter SpringBoard slice");
    MTRuntimeProfileAssert(
        [profile.bundleIdentifier isEqualToString:@"com.apple.springboard"] &&
        [profile.executableName isEqualToString:@"SpringBoard"] &&
        ![profile respondsToSelector:NSSelectorFromString(@"osBuild")],
        @"The profile must select a process without binding it to an OS build");
    MTRuntimeProfileAssert([profile.adapterIDs isEqualToArray:@[
            @"springboard.icon-image-cache",
            @"springboard.notification-icon",
            @"springboard.clock-image-set",
            @"springboard.folder-image",
            @"springboard.badge-background",
            @"springboard.icon-shadow",
            @"springboard.statusbar-signal-image"]] &&
        [profile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot", @"calendar-icons.composite",
            @"clock-icons.snapshot", @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"folder-icons.snapshot", @"badges.snapshot",
            @"icon-shadow.snapshot", @"statusbar.snapshot"]],
        @"SpringBoard must select its seven ProcessAdapters and nine in-image modules");
    MTRuntimeProfileAssert(
        [preferencesProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        preferencesProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [preferencesProfile.bundleIdentifier
            isEqualToString:@"com.apple.Preferences"] &&
        [preferencesProfile.executableName isEqualToString:@"Preferences"] &&
        [preferencesProfile.adapterIDs isEqualToArray:@[
            @"preferences.icon-image-cache",
            @"preferences.application-icon-image"]] &&
        [preferencesProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"ui-resources.snapshot"]],
        @"Preferences must select its UI resources plus application icon source and mask composition");
    MTRuntimeProfileAssert(
        [shareSheetProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        shareSheetProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [shareSheetProfile.bundleIdentifier
            isEqualToString:@"com.apple.SharingUIService"] &&
        [shareSheetProfile.executableName
            isEqualToString:@"SharingUIService"] &&
        [shareSheetProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [shareSheetProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"ui-resources.snapshot"]],
        @"SharingUIService must select one Share adapter and reuse the icon source, mask, and UI snapshot modules");
    MTRuntimeProfileAssert(
        [loadedShareSheetProfile.imageID
            isEqualToString:@"runtime.system-ui"] &&
        loadedShareSheetProfile.mode ==
            MTRuntimeProfileModeProcessAdapters &&
        [loadedShareSheetProfile.bundleIdentifier
            isEqualToString:@"com.apple.ShareSheet"] &&
        [loadedShareSheetProfile.executableName
            isEqualToString:@"ShareSheet"] &&
        [loadedShareSheetProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [loadedShareSheetProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"ui-resources.snapshot"]],
        @"A loaded iOS 16 ShareSheet framework must select the same narrow Share composition");
    MTRuntimeProfileAssert(
        [photosShareSheetProfile.imageID
            isEqualToString:@"runtime.system-ui"] &&
        photosShareSheetProfile.mode ==
            MTRuntimeProfileModeProcessAdapters &&
        [photosShareSheetProfile.bundleIdentifier
            isEqualToString:@"com.apple.mobileslideshow"] &&
        [photosShareSheetProfile.executableName
            isEqualToString:@"MobileSlideShow"] &&
        [photosShareSheetProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [photosShareSheetProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"ui-resources.snapshot"]],
        @"Photos must select the same narrow Share composition in its proven in-process host");
    MTRuntimeProfileAssert(
        [sharingdProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        sharingdProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [sharingdProfile.bundleIdentifier isEqualToString:@"com.apple.sharingd"] &&
        [sharingdProfile.executableName isEqualToString:@"sharingd"] &&
        [sharingdProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [sharingdProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"icon-overlay.snapshot",
            @"ui-resources.snapshot"]],
        @"sharingd must select the same Share composition in the process that produces remote share-sheet activity icons");
    MTRuntimeProfileAssert(
        [dialerProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        dialerProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [dialerProfile.bundleIdentifier
            isEqualToString:@"com.apple.mobilephone"] &&
        [dialerProfile.executableName isEqualToString:@"MobilePhone"] &&
        [dialerProfile.adapterIDs isEqualToArray:@[
            @"mobilephone.dialer-buttons"]] &&
        [dialerProfile.moduleIDs isEqualToArray:@[
            @"dialer.snapshot"]],
        @"MobilePhone must select only the exact Dialer adapter and snapshot module");
    MTRuntimeProfileAssert(
        [spotlightProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        spotlightProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [spotlightProfile.bundleIdentifier
            isEqualToString:@"com.apple.Spotlight"] &&
        [spotlightProfile.executableName isEqualToString:@"Spotlight"] &&
        [spotlightProfile.adapterIDs isEqualToArray:@[
            @"spotlight.icon-image-cache",
            @"springboard.clock-image-set",
            @"spotlight.search-ui-app-image"]] &&
        [spotlightProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot", @"calendar-icons.composite",
            @"clock-icons.snapshot", @"icon-mask.snapshot",
            @"icon-overlay.snapshot"]],
        @"Spotlight must reuse the shared icon/cache/Clock modules and add only its exact SearchUI producer");

    NSError *error = nil;
    MTRuntimeProcessIdentity *exact = MTRuntimeTestIdentity(
        @"com.apple.springboard", @"SpringBoard");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exact, @"runtime.system-ui", &error) == profile &&
        error == nil &&
        ![exact respondsToSelector:NSSelectorFromString(@"osBuild")],
        @"Process identity must deterministically select one build-independent profile");
    error = nil;
    MTRuntimeProcessIdentity *exactPreferences = MTRuntimeTestIdentity(
        @"com.apple.Preferences", @"Preferences");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactPreferences,
                                @"runtime.system-ui", &error) ==
            preferencesProfile && error == nil,
        @"Exact Preferences identity must select only its UI profile");
    error = nil;
    MTRuntimeProcessIdentity *exactShareSheet = MTRuntimeTestIdentity(
        @"com.apple.SharingUIService", @"SharingUIService");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactShareSheet,
                                @"runtime.system-ui", &error) ==
            shareSheetProfile && error == nil,
        @"Exact SharingUIService identity must select only its Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactLoadedShareSheet = MTRuntimeTestIdentity(
        @"com.apple.ShareSheet", @"ShareSheet");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactLoadedShareSheet,
                                @"runtime.system-ui", &error) ==
            loadedShareSheetProfile && error == nil,
        @"The generated ShareSheet framework identity must select its loaded-host profile");
    error = nil;
    MTRuntimeProcessIdentity *exactPhotos = MTRuntimeTestIdentity(
        @"com.apple.mobileslideshow", @"MobileSlideShow");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactPhotos,
                                @"runtime.system-ui", &error) ==
            photosShareSheetProfile && error == nil,
        @"Exact Photos identity must select only its in-process Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactSharingd = MTRuntimeTestIdentity(
        @"com.apple.sharingd", @"sharingd");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactSharingd,
                                @"runtime.system-ui", &error) ==
            sharingdProfile && error == nil,
        @"Exact sharingd identity must select only its Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactDialer = MTRuntimeTestIdentity(
        @"com.apple.mobilephone", @"MobilePhone");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactDialer,
                                @"runtime.system-ui", &error) ==
            dialerProfile && error == nil,
        @"Exact MobilePhone identity must select only its Dialer profile");
    error = nil;
    MTRuntimeProcessIdentity *exactSpotlight = MTRuntimeTestIdentity(
        @"com.apple.Spotlight", @"Spotlight");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactSpotlight,
                                @"runtime.system-ui", &error) ==
            spotlightProfile && error == nil,
        @"Exact Spotlight identity must select only its app-icon profile");
    for (MTRuntimeProcessIdentity *unsupported in @[
        MTRuntimeTestIdentity(@"com.apple.Preferences", @"SpringBoard"),
        MTRuntimeTestIdentity(@"com.apple.springboard", @"Preferences"),
        MTRuntimeTestIdentity(@"com.apple.SharingUIService", @"Preferences"),
        MTRuntimeTestIdentity(@"com.apple.Preferences", @"SharingUIService"),
        MTRuntimeTestIdentity(@"com.apple.ShareSheet", @"SharingUIService"),
        MTRuntimeTestIdentity(@"com.apple.SharingUIService", @"ShareSheet"),
        MTRuntimeTestIdentity(@"com.apple.mobileslideshow", @"SharingUIService"),
        MTRuntimeTestIdentity(@"com.apple.SharingUIService", @"MobileSlideShow"),
        MTRuntimeTestIdentity(@"com.apple.mobilephone", @"SpringBoard"),
        MTRuntimeTestIdentity(@"com.apple.Spotlight", @"SpringBoard"),
    ]) {
        error = nil;
        MTRuntimeProfileAssert(
            MTRuntimeResolveProfile(unsupported,
                                    @"runtime.system-ui", &error) == nil &&
            error == nil,
            @"A non-exact process identity must remain a normal no-op");
    }
    error = nil;
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exact, @"runtime.other", &error) == nil &&
        error == nil,
        @"An image may resolve only profiles assigned to that image");
    NSCharacterSet *nonHex =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
            invertedSet];
    MTRuntimeProfileAssert(MTRuntimeProfileManifestDigest.length == 64 &&
        [MTRuntimeProfileManifestDigest rangeOfCharacterFromSet:nonHex].location ==
            NSNotFound,
        @"Generated profile composition must carry a canonical manifest digest");
    return MTRuntimeProfileAssertionCount;
}
