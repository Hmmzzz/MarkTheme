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

// Process-local provider used by the shared icon cache. Repeated lookups during
// one day reuse the immutable content and avoid rebuilding date formatters.
@interface MTCalendarIconContentProvider : NSObject

- (nullable MTCalendarIconContent *)currentContent;

@end

NS_ASSUME_NONNULL_END
