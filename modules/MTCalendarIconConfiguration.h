#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTCalendarIconConfigurationErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTCalendarIconConfigurationSchemaVersion;

@interface MTCalendarIconTextStyle : NSObject

@property(nonatomic, copy, readonly) NSString *fontName;
@property(nonatomic, assign, readonly) NSUInteger fontSizeMilliPoints;
@property(nonatomic, copy, readonly) NSString *textColorRGB;
@property(nonatomic, assign, readonly) NSUInteger alphaPermille;
@property(nonatomic, assign, readonly) NSInteger yOffsetMilliPoints;

- (nullable instancetype)initWithFontName:(NSString *)fontName
                      fontSizeMilliPoints:(NSUInteger)fontSizeMilliPoints
                             textColorRGB:(NSString *)textColorRGB
                            alphaPermille:(NSUInteger)alphaPermille
                       yOffsetMilliPoints:(NSInteger)yOffsetMilliPoints
                                    error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;
- (NSDictionary<NSString *, id> *)canonicalDictionary;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTCalendarIconConfiguration : NSObject

@property(nonatomic, assign, readonly) NSUInteger schemaVersion;
@property(nonatomic, strong, readonly) MTCalendarIconTextStyle *dayStyle;
@property(nonatomic, strong, readonly) MTCalendarIconTextStyle *dateStyle;

- (nullable instancetype)initWithDayStyle:(MTCalendarIconTextStyle *)dayStyle
                                dateStyle:(MTCalendarIconTextStyle *)dateStyle
                                    error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;
- (NSDictionary<NSString *, id> *)canonicalDictionary;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
