#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Immutable text and lifetime for one local calendar day. The cache identity
// changes with the calendar, locale, time zone, day, or rendered strings.
@interface MTCalendarIconContent : NSObject

@property(nonatomic, copy, readonly) NSString *dayText;
@property(nonatomic, copy, readonly) NSString *dateText;
@property(nonatomic, copy, readonly) NSString *cacheIdentifier;
@property(nonatomic, strong, readonly) NSDate *validFromDate;
@property(nonatomic, strong, readonly) NSDate *expirationDate;

+ (nullable instancetype)contentForDate:(nullable NSDate *)date
                               calendar:(nullable NSCalendar *)calendar
                                 locale:(nullable NSLocale *)locale
                               timeZone:(nullable NSTimeZone *)timeZone;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// One-entry process-local cache keyed only by CalendarUIKit's native semantic
// inputs. It avoids rebuilding date formatters on repeated source requests and
// never substitutes the process's current date/calendar for Apple's request.
@interface MTCalendarIconContentProvider : NSObject

- (nullable MTCalendarIconContent *)
    contentForDateComponents:(nullable NSDateComponents *)dateComponents
                    calendar:(nullable NSCalendar *)calendar;

@end

NS_ASSUME_NONNULL_END
