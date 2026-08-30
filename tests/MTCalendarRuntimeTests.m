#import "MTCalendarRuntimeTests.h"

#import "MTCalendarIconConfiguration.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "modules/MTCalendarIconContent.h"
#import "modules/MTCalendarIconSnapshotResolver.h"

static NSUInteger MTCalendarRuntimeAssertionCount;

static void MTCalendarRuntimeAssert(BOOL condition, NSString *message) {
    MTCalendarRuntimeAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSDate *MTCalendarRuntimeDate(NSString *text) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter dateFromString:text];
}

@interface MTCalendarRuntimeGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTGenerationDescriptor *descriptor;
@end

@implementation MTCalendarRuntimeGeneration
@end

static MTCalendarRuntimeGeneration *MTCalendarRuntimeGenerationWithModules(
    NSArray<NSString *> *moduleIDs,
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *configurations,
    unichar digestCharacter) {
    NSString *digest = [@"" stringByPaddingToLength:64
                                        withString:[NSString stringWithCharacters:
                                            &digestCharacter length:1]
                                   startingAtIndex:0];
    NSString *revisionIdentifier = [@"r1-" stringByAppendingString:digest];
    NSError *error = nil;
    MTGenerationDescriptor *descriptor = [[MTGenerationDescriptor alloc]
        initWithThemeID:@"calendar.runtime-test"
        libraryRevisionIdentifier:revisionIdentifier
        manifestDigest:digest
        indexSHA256:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        indexByteCount:80
        indexFormatVersion:MTGenerationIndexFormatVersion
        resourceCount:0
        assets:@[]
        moduleIDs:moduleIDs
        moduleConfigurations:configurations
        error:&error];
    MTCalendarRuntimeAssert(descriptor != nil && error == nil,
        @"Calendar Runtime fixtures require one canonical Generation descriptor");
    MTCalendarRuntimeGeneration *generation =
        [[MTCalendarRuntimeGeneration alloc] init];
    generation.generationIdentifier = descriptor.generationIdentifier;
    generation.descriptor = descriptor;
    return generation;
}

NSUInteger MTRunCalendarRuntimeTests(void) {
    MTCalendarRuntimeAssertionCount = 0;
    NSCalendar *gregorian = [[NSCalendar alloc]
        initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSLocale *english = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    NSTimeZone *shanghai = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    NSDate *utcDate = MTCalendarRuntimeDate(@"2026-08-12 16:30:00");
    MTCalendarIconContent *englishContent = [MTCalendarIconContent
        contentForDate:utcDate
              calendar:gregorian
                locale:english
              timeZone:shanghai];
    MTCalendarRuntimeAssert(
        [englishContent.dayText isEqualToString:@"THU"] &&
        [englishContent.dateText isEqualToString:@"13"] &&
        [englishContent.validFromDate
            isEqualToDate:MTCalendarRuntimeDate(@"2026-08-12 16:00:00")] &&
        [englishContent.expirationDate
            isEqualToDate:MTCalendarRuntimeDate(@"2026-08-13 16:00:00")],
        @"Calendar content must use the selected local day, not host UTC");

    MTCalendarIconContent *sameDay = [MTCalendarIconContent
        contentForDate:MTCalendarRuntimeDate(@"2026-08-13 01:00:00")
              calendar:gregorian
                locale:english
              timeZone:shanghai];
    MTCalendarRuntimeAssert(
        [sameDay.cacheIdentifier
            isEqualToString:englishContent.cacheIdentifier],
        @"Two instants in one local calendar day must share a cache identity");

    MTCalendarIconContent *nextDay = [MTCalendarIconContent
        contentForDate:MTCalendarRuntimeDate(@"2026-08-13 16:00:00")
              calendar:gregorian
                locale:english
              timeZone:shanghai];
    MTCalendarRuntimeAssert(
        [nextDay.dateText isEqualToString:@"14"] &&
        ![nextDay.cacheIdentifier
            isEqualToString:englishContent.cacheIdentifier],
        @"Calendar cache identity must roll at local midnight");

    MTCalendarIconContent *utcContent = [MTCalendarIconContent
        contentForDate:utcDate
              calendar:gregorian
                locale:english
              timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    MTCalendarRuntimeAssert(
        [utcContent.dateText isEqualToString:@"12"] &&
        ![utcContent.cacheIdentifier
            isEqualToString:englishContent.cacheIdentifier],
        @"A time-zone change must invalidate Calendar content");

    NSLocale *chinese = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    MTCalendarIconContent *chineseContent = [MTCalendarIconContent
        contentForDate:utcDate
              calendar:gregorian
                locale:chinese
              timeZone:shanghai];
    MTCalendarRuntimeAssert(
        chineseContent.dayText.length > 0 &&
        [chineseContent.dateText isEqualToString:@"13"] &&
        [chineseContent.cacheIdentifier containsString:@"zh_CN"] &&
        ![chineseContent.cacheIdentifier
            isEqualToString:englishContent.cacheIdentifier],
        [NSString stringWithFormat:
            @"A locale change must regenerate localized weekday text (%@ / %@)",
            englishContent.cacheIdentifier,
            chineseContent.cacheIdentifier]);

    MTCalendarRuntimeAssert(
        [MTCalendarIconContent contentForDate:nil
                                    calendar:gregorian
                                      locale:english
                                    timeZone:shanghai] == nil,
        @"Calendar content must reject an incomplete environment");

    NSCalendar *nativeCalendar = [gregorian copy];
    nativeCalendar.locale = english;
    nativeCalendar.timeZone = shanghai;
    NSDateComponents *nativeComponents = [nativeCalendar
        components:NSCalendarUnitEra | NSCalendarUnitYear |
                   NSCalendarUnitMonth | NSCalendarUnitDay
          fromDate:utcDate];
    MTCalendarIconContentProvider *nativeProvider =
        [[MTCalendarIconContentProvider alloc] init];
    MTCalendarIconContent *nativeContent = [nativeProvider
        contentForDateComponents:nativeComponents
                       calendar:nativeCalendar];
    MTCalendarRuntimeAssert(
        [nativeContent.dateText isEqualToString:@"13"] &&
        [nativeProvider contentForDateComponents:nativeComponents
                                         calendar:nativeCalendar] ==
            nativeContent,
        @"Calendar source content must follow and cache Apple's native date input");
    NSDateComponents *nativeNextComponents = [nativeComponents copy];
    nativeNextComponents.day += 1;
    MTCalendarIconContent *nativeNextContent = [nativeProvider
        contentForDateComponents:nativeNextComponents
                       calendar:nativeCalendar];
    MTCalendarRuntimeAssert(
        [nativeNextContent.dateText isEqualToString:@"14"] &&
        nativeNextContent != nativeContent,
        @"Calendar source content cache must roll with Apple's requested day");

    NSDictionary *configuration = @{
        @"schemaVersion" : @1,
        @"day" : @{
            @"alphaPermille" : @1000,
            @"fontName" : @"HelveticaNeue-Bold",
            @"fontSizeMilliPoints" : @6000,
            @"textColorRGB" : @"ffffff",
            @"yOffsetMilliPoints" : @7000,
        },
        @"date" : @{
            @"alphaPermille" : @800,
            @"fontName" : @"HelveticaNeue-Regular",
            @"fontSizeMilliPoints" : @20000,
            @"textColorRGB" : @"444242",
            @"yOffsetMilliPoints" : @14000,
        },
    };
    MTCalendarRuntimeGeneration *calendarGeneration =
        MTCalendarRuntimeGenerationWithModules(
            @[@"icons.static", @"icons.calendar"],
            @{@"icons.calendar" : configuration}, 'b');
    MTCalendarIconSnapshotResolver *resolver =
        [[MTCalendarIconSnapshotResolver alloc] init];
    NSError *error = nil;
    MTCalendarIconConfiguration *resolved = [resolver
        configurationForBundleIdentifier:MTCalendarIconTargetBundleIdentifier
                               generation:(id)calendarGeneration
                                    error:&error];
    MTCalendarRuntimeAssert(
        resolved != nil && error == nil &&
        resolved.dayStyle.fontSizeMilliPoints == 6000 &&
        [resolved.dateStyle.fontName isEqualToString:@"HelveticaNeue"] &&
        resolved.dateStyle.alphaPermille == 800,
        @"Calendar Runtime resolver must expose the typed v2 Generation configuration");
    MTCalendarRuntimeAssert(
        [resolver configurationForBundleIdentifier:
                MTCalendarIconTargetBundleIdentifier
                                       generation:(id)calendarGeneration
                                            error:&error] == resolved,
        @"Calendar Runtime resolver must reuse one immutable configuration per Generation");
    MTCalendarRuntimeAssert(
        [resolver configurationForBundleIdentifier:@"com.example.other"
                                       generation:(id)calendarGeneration
                                            error:&error] == nil && error == nil,
        @"Calendar Runtime resolver must be a clean no-op for other subjects");

    MTCalendarRuntimeGeneration *staticGeneration =
        MTCalendarRuntimeGenerationWithModules(@[@"icons.static"], @{}, 'c');
    error = nil;
    MTCalendarRuntimeAssert(
        [resolver configurationForBundleIdentifier:
                MTCalendarIconTargetBundleIdentifier
                                       generation:(id)staticGeneration
                                            error:&error] == nil && error == nil,
        @"A Generation without icons.calendar must retain static-icon semantics");

    MTCalendarRuntimeGeneration *malformedGeneration =
        MTCalendarRuntimeGenerationWithModules(
            @[@"icons.static", @"icons.calendar"],
            @{@"icons.calendar" : @{@"malformed" : @YES}}, 'd');
    error = nil;
    MTCalendarRuntimeAssert(
        [resolver configurationForBundleIdentifier:
                MTCalendarIconTargetBundleIdentifier
                                       generation:(id)malformedGeneration
                                            error:&error] == nil &&
        [error.domain isEqualToString:
            MTCalendarIconSnapshotResolverErrorDomain],
        @"An enabled malformed Calendar capability must fail closed to stock");
    return MTCalendarRuntimeAssertionCount;
}
