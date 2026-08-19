#import "MTCalendarIconRenderer.h"

#import <UIKit/UIKit.h>

#import "MTCalendarIconConfiguration.h"
#import "MTCalendarIconContent.h"

MTCalendarIconRendererObservation MTRuntimeCalendarIconRendererObservation = {
    .schemaVersion = 1,
    .renderAttempts = ATOMIC_VAR_INIT(0),
    .renderSuccesses = ATOMIC_VAR_INIT(0),
    .renderFailures = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTCalendarIconRendererObservation) == 32,
    "The M5-A Calendar renderer observation layout must remain fixed.");

static UIColor *MTCalendarIconColor(MTCalendarIconTextStyle *style) {
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:style.textColorRGB];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    return [UIColor
        colorWithRed:((rgb >> 16) & 0xff) / 255.0
               green:((rgb >> 8) & 0xff) / 255.0
                blue:(rgb & 0xff) / 255.0
               alpha:style.alphaPermille / 1000.0];
}

static NSDictionary<NSAttributedStringKey, id> *
MTCalendarIconAttributes(MTCalendarIconTextStyle *style) {
    CGFloat fontSize = style.fontSizeMilliPoints / 1000.0;
    UIFont *font = [UIFont fontWithName:style.fontName size:fontSize];
    UIColor *color = MTCalendarIconColor(style);
    if (font == nil || color == nil) return nil;
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByClipping;
    return @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : color,
        NSParagraphStyleAttributeName : paragraph,
    };
}

static void MTCalendarIconDrawText(
    NSString *text,
    MTCalendarIconTextStyle *style,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    CGSize canvasSize,
    CGFloat legacyBaseY) {
    // SnowBoard's legacy Calendar contract stores a displacement from the
    // label's built-in 60-point baseline, not an absolute top coordinate.
    // Scale both values together so the same metadata remains proportional
    // when SpringBoard asks for a non-60-point representation.
    CGFloat legacyOffset = style.yOffsetMilliPoints / 1000.0;
    CGFloat y = (legacyBaseY + legacyOffset) *
        (canvasSize.width / 60.0);
    CGRect rect = CGRectMake(0, y, canvasSize.width,
                             MAX(canvasSize.height - y, 1));
    [text drawInRect:rect
      withAttributes:attributes];
}

UIImage *MTCalendarIconRenderBackground(
    UIImage *background,
    MTCalendarIconConfiguration *configuration,
    MTCalendarIconContent *content) {
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarIconRendererObservation.renderAttempts,
        1, memory_order_relaxed);
    NSDictionary *dayAttributes =
        MTCalendarIconAttributes(configuration.dayStyle);
    NSDictionary *dateAttributes =
        MTCalendarIconAttributes(configuration.dateStyle);
    if (background.CGImage == nil || background.scale <= 0 ||
        dayAttributes == nil || dateAttributes == nil ||
        content.dayText.length == 0 || content.dateText.length == 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarIconRendererObservation.renderFailures,
            1, memory_order_relaxed);
        return nil;
    }

    UIGraphicsImageRendererFormat *format =
        [[UIGraphicsImageRendererFormat alloc] init];
    format.opaque = NO;
    format.scale = background.scale;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:background.size format:format];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *rendererContext) {
            (void)rendererContext;
            CGRect bounds = (CGRect){ .origin = CGPointZero,
                                      .size = background.size };
            [background drawInRect:bounds];
            MTCalendarIconDrawText(content.dayText,
                configuration.dayStyle, dayAttributes, background.size, 8.0);
            MTCalendarIconDrawText(content.dateText,
                configuration.dateStyle, dateAttributes, background.size, 14.0);
        }];
    if (image.CGImage == nil ||
        !CGSizeEqualToSize(image.size, background.size) ||
        image.scale != background.scale) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarIconRendererObservation.renderFailures,
            1, memory_order_relaxed);
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarIconRendererObservation.renderSuccesses,
        1, memory_order_relaxed);
    return image;
}
