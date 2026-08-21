#import "MTCalendarIconConfiguration.h"

#import <CoreFoundation/CoreFoundation.h>

NSString *const MTCalendarIconConfigurationErrorDomain =
    @"com.hmmzzz.marktheme64e.calendar-icon-configuration";
NSUInteger const MTCalendarIconConfigurationSchemaVersion = 1;

static BOOL MTCalendarConfigurationSetError(NSError **error,
                                            NSInteger code,
                                            NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTCalendarIconConfigurationErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey : description
        }];
    }
    return NO;
}

static BOOL MTCalendarDictionaryHasExactKeys(NSDictionary *dictionary,
                                             NSArray<NSString *> *keys) {
    return [dictionary isKindOfClass:NSDictionary.class] &&
        dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL MTCalendarReadInteger(id value,
                                  NSInteger minimum,
                                  NSInteger maximum,
                                  NSInteger *output) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    const char *type = number.objCType;
    if (type == NULL || type[0] == 'f' || type[0] == 'd') return NO;
    NSString *text = number.stringValue;
    if (text.length == 0) return NO;
    NSUInteger index = 0;
    BOOL negative = [text characterAtIndex:0] == '-';
    if (negative) index++;
    if (index >= text.length) return NO;
    uint64_t magnitude = 0;
    for (; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
        uint64_t digit = (uint64_t)(character - '0');
        if (magnitude > (UINT64_MAX - digit) / 10) return NO;
        magnitude = magnitude * 10 + digit;
    }
    if ((!negative && magnitude > (uint64_t)NSIntegerMax) ||
        (negative && magnitude > (uint64_t)NSIntegerMax + 1ULL)) {
        return NO;
    }
    NSInteger parsed = negative
        ? (magnitude == (uint64_t)NSIntegerMax + 1ULL
            ? NSIntegerMin : -(NSInteger)magnitude)
        : (NSInteger)magnitude;
    if (parsed < minimum || parsed > maximum) return NO;
    *output = (NSInteger)parsed;
    return YES;
}

static NSString *_Nullable MTCalendarNormalizeFontName(NSString *fontName) {
    if (![fontName isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [[fontName
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        precomposedStringWithCanonicalMapping];
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding
                            allowLossyConversion:NO];
    if (utf8.length == 0 || utf8.length > 128) return nil;
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character == 0 || character < 0x20 || character == 0x7f) return nil;
    }
    // Legacy iOS themes commonly use this CoreText-style alias, while UIKit
    // on iOS 17 exposes the regular face by its canonical PostScript name.
    // Normalize at the data boundary so Runtime rendering stays exact and
    // deterministic instead of silently substituting a system font.
    if ([normalized isEqualToString:@"HelveticaNeue-Regular"]) {
        return @"HelveticaNeue";
    }
    return normalized;
}

static BOOL MTCalendarColorIsCanonical(NSString *color) {
    if (![color isKindOfClass:NSString.class] || color.length != 6) return NO;
    for (NSUInteger index = 0; index < color.length; index++) {
        unichar character = [color characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return NO;
        }
    }
    return YES;
}

@implementation MTCalendarIconTextStyle

- (instancetype)initWithFontName:(NSString *)fontName
              fontSizeMilliPoints:(NSUInteger)fontSizeMilliPoints
                     textColorRGB:(NSString *)textColorRGB
                    alphaPermille:(NSUInteger)alphaPermille
               yOffsetMilliPoints:(NSInteger)yOffsetMilliPoints
                            error:(NSError **)error {
    NSString *normalizedFontName = MTCalendarNormalizeFontName(fontName);
    if (normalizedFontName == nil ||
        fontSizeMilliPoints < 1000 || fontSizeMilliPoints > 200000 ||
        !MTCalendarColorIsCanonical(textColorRGB) || alphaPermille > 1000 ||
        yOffsetMilliPoints < -200000 || yOffsetMilliPoints > 200000) {
        MTCalendarConfigurationSetError(error, 1,
            @"Calendar text style is invalid.");
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _fontName = [normalizedFontName copy];
    _fontSizeMilliPoints = fontSizeMilliPoints;
    _textColorRGB = [textColorRGB copy];
    _alphaPermille = alphaPermille;
    _yOffsetMilliPoints = yOffsetMilliPoints;
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *,id> *)dictionary
                               error:(NSError **)error {
    if (!MTCalendarDictionaryHasExactKeys(dictionary, @[
            @"alphaPermille", @"fontName", @"fontSizeMilliPoints",
            @"textColorRGB", @"yOffsetMilliPoints",
        ])) {
        MTCalendarConfigurationSetError(error, 2,
            @"Calendar text-style dictionary is malformed.");
        return nil;
    }
    NSInteger fontSize = 0;
    NSInteger alpha = 0;
    NSInteger offset = 0;
    if (!MTCalendarReadInteger(dictionary[@"fontSizeMilliPoints"], 1000,
                               200000, &fontSize) ||
        !MTCalendarReadInteger(dictionary[@"alphaPermille"], 0, 1000,
                               &alpha) ||
        !MTCalendarReadInteger(dictionary[@"yOffsetMilliPoints"], -200000,
                               200000, &offset)) {
        MTCalendarConfigurationSetError(error, 2,
            @"Calendar text-style numeric field is malformed.");
        return nil;
    }
    return [self initWithFontName:dictionary[@"fontName"]
              fontSizeMilliPoints:(NSUInteger)fontSize
                     textColorRGB:dictionary[@"textColorRGB"]
                    alphaPermille:(NSUInteger)alpha
               yOffsetMilliPoints:offset
                            error:error];
}

- (NSDictionary<NSString *,id> *)canonicalDictionary {
    return @{
        @"alphaPermille" : @(self.alphaPermille),
        @"fontName" : self.fontName,
        @"fontSizeMilliPoints" : @(self.fontSizeMilliPoints),
        @"textColorRGB" : self.textColorRGB,
        @"yOffsetMilliPoints" : @(self.yOffsetMilliPoints),
    };
}

@end

@implementation MTCalendarIconConfiguration

- (instancetype)initWithDayStyle:(MTCalendarIconTextStyle *)dayStyle
                        dateStyle:(MTCalendarIconTextStyle *)dateStyle
                            error:(NSError **)error {
    if (![dayStyle isKindOfClass:MTCalendarIconTextStyle.class] ||
        ![dateStyle isKindOfClass:MTCalendarIconTextStyle.class]) {
        MTCalendarConfigurationSetError(error, 3,
            @"Calendar configuration requires day and date styles.");
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _schemaVersion = MTCalendarIconConfigurationSchemaVersion;
    _dayStyle = dayStyle;
    _dateStyle = dateStyle;
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary<NSString *,id> *)dictionary
                               error:(NSError **)error {
    if (!MTCalendarDictionaryHasExactKeys(dictionary,
            @[@"date", @"day", @"schemaVersion"]) ||
        ![dictionary[@"schemaVersion"] isEqual:
            @(MTCalendarIconConfigurationSchemaVersion)] ||
        ![dictionary[@"day"] isKindOfClass:NSDictionary.class] ||
        ![dictionary[@"date"] isKindOfClass:NSDictionary.class]) {
        MTCalendarConfigurationSetError(error, 4,
            @"Calendar configuration dictionary is malformed or unsupported.");
        return nil;
    }
    MTCalendarIconTextStyle *day = [[MTCalendarIconTextStyle alloc]
        initWithDictionary:dictionary[@"day"] error:error];
    MTCalendarIconTextStyle *date = day == nil ? nil :
        [[MTCalendarIconTextStyle alloc]
            initWithDictionary:dictionary[@"date"] error:error];
    return date == nil ? nil : [self initWithDayStyle:day
                                            dateStyle:date
                                                error:error];
}

- (NSDictionary<NSString *,id> *)canonicalDictionary {
    return @{
        @"date" : self.dateStyle.canonicalDictionary,
        @"day" : self.dayStyle.canonicalDictionary,
        @"schemaVersion" : @(self.schemaVersion),
    };
}

@end
