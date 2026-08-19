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
    NSString *executableName,
    NSString *osBuild) {
    return [[MTRuntimeProcessIdentity alloc]
        initWithBundleIdentifier:bundleIdentifier
                  executableName:executableName
                         osBuild:osBuild];
}

NSUInteger MTRunRuntimeProfileTests(void) {
    MTRuntimeProfileAssertionCount = 0;
    NSArray<MTRuntimeProfile *> *profiles = MTRuntimeGeneratedProfiles();
    MTRuntimeProfileAssert(profiles.count == 7,
        @"The system UI image must compile exactly seven process profiles");
    MTRuntimeProfile *profile = nil;
    MTRuntimeProfile *preferencesProfile = nil;
    MTRuntimeProfile *shareSheetProfile = nil;
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
        [profile.osBuild isEqualToString:@"21D61"],
        @"The profile must require the exact maintained process and OS build");
    MTRuntimeProfileAssert([profile.adapterIDs isEqualToArray:@[
            @"springboard.icon-image-cache", @"springboard.clock-image-set",
            @"springboard.folder-image",
            @"springboard.badge-background",
            @"springboard.icon-shadow",
            @"springboard.statusbar-signal-image"]] &&
        [profile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot", @"calendar-icons.composite",
            @"clock-icons.snapshot", @"icon-mask.snapshot",
            @"folder-icons.snapshot", @"badges.snapshot",
            @"icon-shadow.snapshot", @"statusbar.snapshot"]],
        @"SpringBoard must select its six ProcessAdapters and eight in-image modules");
    MTRuntimeProfileAssert(
        [preferencesProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        preferencesProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [preferencesProfile.bundleIdentifier
            isEqualToString:@"com.apple.Preferences"] &&
        [preferencesProfile.executableName isEqualToString:@"Preferences"] &&
        [preferencesProfile.osBuild isEqualToString:@"21D61"] &&
        [preferencesProfile.adapterIDs isEqualToArray:@[
            @"preferences.icon-image-cache"]] &&
        [preferencesProfile.moduleIDs isEqualToArray:@[
            @"ui-resources.snapshot"]],
        @"Preferences must select only its UI resource adapter and module");
    MTRuntimeProfileAssert(
        [shareSheetProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        shareSheetProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [shareSheetProfile.bundleIdentifier
            isEqualToString:@"com.apple.SharingUIService"] &&
        [shareSheetProfile.executableName
            isEqualToString:@"SharingUIService"] &&
        [shareSheetProfile.osBuild isEqualToString:@"21D61"] &&
        [shareSheetProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [shareSheetProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"ui-resources.snapshot"]],
        @"SharingUIService must select one Share adapter and reuse the icon source, mask, and UI snapshot modules");
    MTRuntimeProfileAssert(
        [photosShareSheetProfile.imageID
            isEqualToString:@"runtime.system-ui"] &&
        photosShareSheetProfile.mode ==
            MTRuntimeProfileModeProcessAdapters &&
        [photosShareSheetProfile.bundleIdentifier
            isEqualToString:@"com.apple.mobileslideshow"] &&
        [photosShareSheetProfile.executableName
            isEqualToString:@"MobileSlideShow"] &&
        [photosShareSheetProfile.osBuild isEqualToString:@"21D61"] &&
        [photosShareSheetProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [photosShareSheetProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"ui-resources.snapshot"]],
        @"Photos must select the same narrow Share composition in its proven in-process host");
    MTRuntimeProfileAssert(
        [sharingdProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        sharingdProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [sharingdProfile.bundleIdentifier isEqualToString:@"com.apple.sharingd"] &&
        [sharingdProfile.executableName isEqualToString:@"sharingd"] &&
        [sharingdProfile.osBuild isEqualToString:@"21D61"] &&
        [sharingdProfile.adapterIDs isEqualToArray:@[
            @"share-sheet.activity-image"]] &&
        [sharingdProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot",
            @"icon-mask.snapshot",
            @"ui-resources.snapshot"]],
        @"sharingd must select the same Share composition in the process that produces remote share-sheet activity icons");
    MTRuntimeProfileAssert(
        [dialerProfile.imageID isEqualToString:@"runtime.system-ui"] &&
        dialerProfile.mode == MTRuntimeProfileModeProcessAdapters &&
        [dialerProfile.bundleIdentifier
            isEqualToString:@"com.apple.mobilephone"] &&
        [dialerProfile.executableName isEqualToString:@"MobilePhone"] &&
        [dialerProfile.osBuild isEqualToString:@"21D61"] &&
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
        [spotlightProfile.osBuild isEqualToString:@"21D61"] &&
        [spotlightProfile.adapterIDs isEqualToArray:@[
            @"spotlight.icon-image-cache",
            @"springboard.clock-image-set",
            @"spotlight.search-ui-app-image"]] &&
        [spotlightProfile.moduleIDs isEqualToArray:@[
            @"static-icons.snapshot", @"calendar-icons.composite",
            @"clock-icons.snapshot", @"icon-mask.snapshot"]],
        @"Spotlight must reuse the shared icon/cache/Clock modules and add only its exact SearchUI producer");

    NSError *error = nil;
    MTRuntimeProcessIdentity *exact = MTRuntimeTestIdentity(
        @"com.apple.springboard", @"SpringBoard", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exact, @"runtime.system-ui", &error) == profile &&
        error == nil,
        @"Exact process identity must deterministically select one profile");
    error = nil;
    MTRuntimeProcessIdentity *exactPreferences = MTRuntimeTestIdentity(
        @"com.apple.Preferences", @"Preferences", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactPreferences,
                                @"runtime.system-ui", &error) ==
            preferencesProfile && error == nil,
        @"Exact Preferences identity must select only its UI profile");
    error = nil;
    MTRuntimeProcessIdentity *exactShareSheet = MTRuntimeTestIdentity(
        @"com.apple.SharingUIService", @"SharingUIService", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactShareSheet,
                                @"runtime.system-ui", &error) ==
            shareSheetProfile && error == nil,
        @"Exact SharingUIService identity must select only its Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactPhotos = MTRuntimeTestIdentity(
        @"com.apple.mobileslideshow", @"MobileSlideShow", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactPhotos,
                                @"runtime.system-ui", &error) ==
            photosShareSheetProfile && error == nil,
        @"Exact Photos identity must select only its in-process Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactSharingd = MTRuntimeTestIdentity(
        @"com.apple.sharingd", @"sharingd", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactSharingd,
                                @"runtime.system-ui", &error) ==
            sharingdProfile && error == nil,
        @"Exact sharingd identity must select only its Share profile");
    error = nil;
    MTRuntimeProcessIdentity *exactDialer = MTRuntimeTestIdentity(
        @"com.apple.mobilephone", @"MobilePhone", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactDialer,
                                @"runtime.system-ui", &error) ==
            dialerProfile && error == nil,
        @"Exact MobilePhone identity must select only its Dialer profile");
    error = nil;
    MTRuntimeProcessIdentity *exactSpotlight = MTRuntimeTestIdentity(
        @"com.apple.Spotlight", @"Spotlight", @"21D61");
    MTRuntimeProfileAssert(
        MTRuntimeResolveProfile(exactSpotlight,
                                @"runtime.system-ui", &error) ==
            spotlightProfile && error == nil,
        @"Exact Spotlight identity must select only its app-icon profile");
    for (MTRuntimeProcessIdentity *unsupported in @[
        MTRuntimeTestIdentity(@"com.apple.Preferences", @"SpringBoard", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.springboard", @"Preferences", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.SharingUIService", @"Preferences", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.Preferences", @"SharingUIService", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.mobileslideshow", @"SharingUIService", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.SharingUIService", @"MobileSlideShow", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.mobileslideshow", @"MobileSlideShow", @"21D62"),
        MTRuntimeTestIdentity(@"com.apple.mobilephone", @"SpringBoard", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.mobilephone", @"MobilePhone", @"21D62"),
        MTRuntimeTestIdentity(@"com.apple.Spotlight", @"SpringBoard", @"21D61"),
        MTRuntimeTestIdentity(@"com.apple.Spotlight", @"Spotlight", @"21D62"),
        MTRuntimeTestIdentity(@"com.apple.springboard", @"SpringBoard", @"21D62"),
    ]) {
        error = nil;
        MTRuntimeProfileAssert(
            MTRuntimeResolveProfile(unsupported,
                                    @"runtime.system-ui", &error) == nil &&
            error == nil,
            @"A non-exact process or OS build must remain a normal no-op");
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
