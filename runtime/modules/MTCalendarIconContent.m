#import "MTCalendarIconContent.h"

#import <os/lock.h>

@interface MTCalendarIconContent ()
- (instancetype)initWithDayText:(NSString *)dayText
                       dateText:(NSString *)dateText
                cacheIdentifier:(NSString *)cacheIdentifier
                  validFromDate:(NSDate *)validFromDate
                 expirationDate:(NSDate *)expirationDate;
@end

@interface MTCalendarIconContentProvider () {
    os_unfair_lock _lock;
    NSString *_cachedInputIdentifier;
    MTCalendarIconContent *_cachedContent;
}
@end

@implementation MTCalendarIconContentProvider

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (MTCalendarIconContent *)
    contentForDateComponents:(NSDateComponents *)dateComponents
                    calendar:(NSCalendar *)calendar {
    if (![dateComponents isKindOfClass:NSDateComponents.class] ||
        ![calendar isKindOfClass:NSCalendar.class]) {
        return nil;
    }
    NSDate *date = [calendar dateFromComponents:dateComponents];
    NSLocale *locale = calendar.locale ?: NSLocale.autoupdatingCurrentLocale;
    NSTimeZone *timeZone = calendar.timeZone ?: NSTimeZone.localTimeZone;
    if (date == nil || locale == nil || timeZone == nil) return nil;
    NSString *inputIdentifier = [NSString stringWithFormat:
        @"%@|%@|%@|%.6f", calendar.calendarIdentifier,
        locale.localeIdentifier, timeZone.name,
        date.timeIntervalSinceReferenceDate];

    os_unfair_lock_lock(&_lock);
    MTCalendarIconContent *cached =
        [inputIdentifier isEqualToString:_cachedInputIdentifier]
            ? _cachedContent : nil;
    os_unfair_lock_unlock(&_lock);
    if (cached != nil) return cached;

    MTCalendarIconContent *content = [MTCalendarIconContent
        contentForDate:date
              calendar:calendar
                locale:locale
              timeZone:timeZone];
    if (content == nil) return nil;
    os_unfair_lock_lock(&_lock);
    _cachedInputIdentifier = [inputIdentifier copy];
    _cachedContent = content;
    os_unfair_lock_unlock(&_lock);
    return content;
}

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
