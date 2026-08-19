#import "MTCalendarIconContent.h"

#import <os/lock.h>

@interface MTCalendarIconContent ()
- (instancetype)initWithDayText:(NSString *)dayText
                       dateText:(NSString *)dateText
                cacheIdentifier:(NSString *)cacheIdentifier
                  validFromDate:(NSDate *)validFromDate
                 expirationDate:(NSDate *)expirationDate;
@end

@implementation MTCalendarIconContent

- (instancetype)initWithDayText:(NSString *)dayText
                       dateText:(NSString *)dateText
                cacheIdentifier:(NSString *)cacheIdentifier
                  validFromDate:(NSDate *)validFromDate
                 expirationDate:(NSDate *)expirationDate {
    self = [super init];
    if (self == nil) return nil;
    _dayText = [dayText copy];
    _dateText = [dateText copy];
    _cacheIdentifier = [cacheIdentifier copy];
    _validFromDate = validFromDate;
    _expirationDate = expirationDate;
    return self;
}

+ (instancetype)contentForDate:(NSDate *)date
                       calendar:(NSCalendar *)calendar
                         locale:(NSLocale *)locale
                       timeZone:(NSTimeZone *)timeZone {
    if (date == nil || calendar == nil || locale == nil || timeZone == nil) {
        return nil;
    }

    NSCalendar *resolvedCalendar = [calendar copy];
    resolvedCalendar.locale = locale;
    resolvedCalendar.timeZone = timeZone;
    NSDate *validFromDate = [resolvedCalendar startOfDayForDate:date];
    NSDate *expirationDate = [resolvedCalendar
        dateByAddingUnit:NSCalendarUnitDay
                   value:1
                  toDate:validFromDate
                 options:0];
    NSDateComponents *components = [resolvedCalendar
        components:NSCalendarUnitEra | NSCalendarUnitYear |
                   NSCalendarUnitMonth | NSCalendarUnitDay
          fromDate:date];
    if (validFromDate == nil || expirationDate == nil) return nil;

    NSDateFormatter *dayFormatter = [[NSDateFormatter alloc] init];
    dayFormatter.calendar = resolvedCalendar;
    dayFormatter.locale = locale;
    dayFormatter.timeZone = timeZone;
    dayFormatter.dateFormat = [NSDateFormatter
        dateFormatFromTemplate:@"EEE" options:0 locale:locale];

    NSString *dayText = [[dayFormatter stringFromDate:date]
        uppercaseStringWithLocale:locale];
    NSNumberFormatter *dateFormatter = [[NSNumberFormatter alloc] init];
    dateFormatter.locale = locale;
    dateFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    dateFormatter.usesGroupingSeparator = NO;
    dateFormatter.minimumFractionDigits = 0;
    dateFormatter.maximumFractionDigits = 0;
    NSString *dateText = [dateFormatter stringFromNumber:@(components.day)];
    if (dayText.length == 0 || dateText.length == 0) return nil;

    NSString *cacheIdentifier = [NSString stringWithFormat:
        @"%@|%@|%@|%ld|%ld|%ld|%ld|%@|%@",
        resolvedCalendar.calendarIdentifier,
        locale.localeIdentifier,
        timeZone.name,
        (long)components.era,
        (long)components.year,
        (long)components.month,
        (long)components.day,
        dayText,
        dateText];
    return [[self alloc] initWithDayText:dayText
                               dateText:dateText
                        cacheIdentifier:cacheIdentifier
                          validFromDate:validFromDate
                         expirationDate:expirationDate];
}

@end

@interface MTCalendarIconContentProvider () {
    os_unfair_lock _lock;
    MTCalendarIconContent *_cachedContent;
    NSString *_cachedEnvironmentIdentifier;
}
@end

@implementation MTCalendarIconContentProvider

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (MTCalendarIconContent *)currentContent {
    NSDate *date = [NSDate date];
    NSCalendar *calendar = [NSCalendar autoupdatingCurrentCalendar];
    NSLocale *locale = [NSLocale autoupdatingCurrentLocale];
    NSTimeZone *timeZone = [NSTimeZone localTimeZone];
    NSString *environmentIdentifier = [NSString stringWithFormat:@"%@|%@|%@",
        calendar.calendarIdentifier, locale.localeIdentifier, timeZone.name];

    os_unfair_lock_lock(&_lock);
    MTCalendarIconContent *cachedContent = _cachedContent;
    BOOL current = [environmentIdentifier
            isEqualToString:_cachedEnvironmentIdentifier] &&
        [cachedContent.validFromDate compare:date] != NSOrderedDescending &&
        [date compare:cachedContent.expirationDate] == NSOrderedAscending;
    os_unfair_lock_unlock(&_lock);
    if (current) return cachedContent;

    MTCalendarIconContent *content = [MTCalendarIconContent
        contentForDate:date
              calendar:calendar
                locale:locale
              timeZone:timeZone];
    if (content == nil) return nil;

    os_unfair_lock_lock(&_lock);
    _cachedContent = content;
    _cachedEnvironmentIdentifier = [environmentIdentifier copy];
    os_unfair_lock_unlock(&_lock);
    return content;
}

@end
