#import "MTClockIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>

#include <math.h>

#import "MTClockIconsModule.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTResourceKey.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStaticIconVisualProofContract.h"

NSString *const MTClockIconSnapshotModuleID = @"clock-icons.snapshot";

@interface MTClockIconImageSet ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                      hourHand:(nullable UIImage *)hourHand
                                    minuteHand:(nullable UIImage *)minuteHand
                                    secondHand:(nullable UIImage *)secondHand
                                 hourMinuteDot:(nullable UIImage *)hourMinuteDot
                                     secondDot:(nullable UIImage *)secondDot;
@end

@implementation MTClockIconImageSet

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                                      hourHand:(UIImage *)hourHand
                                    minuteHand:(UIImage *)minuteHand
                                    secondHand:(UIImage *)secondHand
                                 hourMinuteDot:(UIImage *)hourMinuteDot
                                     secondDot:(UIImage *)secondDot {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _hourHand = hourHand;
    _minuteHand = minuteHand;
    _secondHand = secondHand;
    _hourMinuteDot = hourMinuteDot;
    _secondDot = secondDot;
    return self;
}

@end

@interface MTClockIconSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(atomic, strong, nullable) MTClockIconImageSet *currentImageSet;
@property(atomic, assign) uint64_t requestedEpoch;
- (void)reload;
@end

@implementation MTClockIconSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    return _imageLoader == nil ? nil : self;
}

- (MTGenerationResource *)resourceForVariant:(NSString *)variant
                                  generation:(MTGeneration *)generation {
    NSError *keyError = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:MTClockIconsModuleID
                 surface:@"springboard.home"
                 subject:MTClockIconTargetBundleIdentifier
                 variant:variant
                   scale:0
                   trait:@"any"
                   error:&keyError];
    return key == nil ? nil : [generation
        resourceForCanonicalResourceKey:key.canonicalString error:NULL];
}

- (UIImage *)loadFullCanvasForVariant:(NSString *)variant
                            generation:(MTGeneration *)generation {
    MTGenerationResource *resource = [self resourceForVariant:variant
                                                   generation:generation];
    if (resource == nil) return nil;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:generation
                      resource:resource
              targetPixelWidth:180
             targetPixelHeight:180
                         error:NULL];
    UIImage *image = decoded == nil ? nil : [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:MTStaticIconVisualProofExpectedScale
        orientation:UIImageOrientationUp];
    return MTStaticIconVisualProofImageContractIsSupported(
        image.size, image.scale) ? image : nil;
}

static UIImage *MTClockCropHandCanvas(UIImage *canvas,
                                      CGRect pixelRect) {
    CGImageRef source = canvas.CGImage;
    if (source == NULL || CGImageGetWidth(source) != 180 ||
        CGImageGetHeight(source) != 180) {
        return nil;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(source, pixelRect);
    UIImage *image = cropped == NULL ? nil : [[UIImage alloc]
        initWithCGImage:cropped scale:3.0 orientation:UIImageOrientationUp];
    if (cropped != NULL) CGImageRelease(cropped);
    return image;
}

static UIImage *MTClockTransparentImage(size_t pixelWidth,
                                        size_t pixelHeight) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        NULL, pixelWidth, pixelHeight, 8, pixelWidth * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return nil;
    CGImageRef imageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    UIImage *image = imageRef == NULL ? nil : [[UIImage alloc]
        initWithCGImage:imageRef scale:3.0 orientation:UIImageOrientationUp];
    if (imageRef != NULL) CGImageRelease(imageRef);
    return image;
}

- (void)reload {
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    uint64_t epoch = 0;
    @synchronized (self) {
        epoch = self.requestedEpoch + 1;
        self.requestedEpoch = epoch;
    }
    if (!snapshot.isReady || ![snapshot.generation.descriptor.moduleIDs
            containsObject:MTClockIconsModuleID]) {
        self.currentImageSet = nil;
        return;
    }
    MTGeneration *generation = snapshot.generation;
    NSString *generationIdentifier = generation.generationIdentifier;
    UIImage *hourCanvas = [self loadFullCanvasForVariant:@"hour-hand"
                                              generation:generation];
    UIImage *minuteCanvas = [self loadFullCanvasForVariant:@"minute-hand"
                                                generation:generation];
    UIImage *secondCanvas = [self loadFullCanvasForVariant:@"second-hand"
                                                generation:generation];
    UIImage *hour = MTClockCropHandCanvas(
        hourCanvas, CGRectMake(76, 39, 28, 65));
    UIImage *minute = MTClockCropHandCanvas(
        minuteCanvas, CGRectMake(76, 9, 28, 95));
    UIImage *second = MTClockCropHandCanvas(
        secondCanvas, CGRectMake(87, 16, 6, 85));
    // Legacy hand canvases already contain their center artwork. Suppress
    // SpringBoard's additional stationary dots so it is not drawn twice.
    UIImage *hourMinuteDot = MTClockTransparentImage(28, 28);
    UIImage *secondDot = MTClockTransparentImage(6, 6);
    MTClockIconImageSet *set =
        hour == nil && minute == nil && second == nil ? nil :
        [[MTClockIconImageSet alloc]
            initWithGenerationIdentifier:generationIdentifier
            hourHand:hour minuteHand:minute secondHand:second
            hourMinuteDot:hourMinuteDot secondDot:secondDot];
    if (self.requestedEpoch != epoch ||
        ![self.kernel.currentSnapshot.state.activeGenerationIdentifier
            isEqualToString:generationIdentifier]) {
        return;
    }
    self.currentImageSet = set;
}

@end

static os_unfair_lock MTClockIconSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTClockIconSnapshotModule *MTClockIconSnapshotInstance;

BOOL MTClockIconSnapshotConfigure(MTRuntimeKernel *kernel, NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTClockIconSnapshotLock);
    if (MTClockIconSnapshotInstance == nil) {
        MTClockIconSnapshotInstance = [[MTClockIconSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTClockIconSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTClockIconSnapshotLock);
    if (!configured && error != NULL) {
        *error = [NSError errorWithDomain:@"com.hmmzzz.marktheme.clock-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey : @"Clock snapshot module could not initialize."
        }];
    }
    return configured;
}

void MTClockIconSnapshotReload(void) {
    [MTClockIconSnapshotInstance reload];
}

MTClockIconImageSet *MTClockIconSnapshotCurrentImageSet(void) {
    return MTClockIconSnapshotInstance.currentImageSet;
}

static BOOL MTClockNativeComponentContract(UIImage *image) {
    if (![image isKindOfClass:UIImage.class] || image.CGImage == NULL ||
        !isfinite(image.scale) || image.scale < 1 || image.scale > 3 ||
        floor(image.scale) != image.scale) {
        return NO;
    }
    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    return width >= 1 && height >= 1 && width <= 512 && height <= 512 &&
        fabs(image.size.width * image.scale - (CGFloat)width) < 0.01 &&
        fabs(image.size.height * image.scale - (CGFloat)height) < 0.01;
}

static UIImage *MTClockImageMatchingNativeComponent(UIImage *source,
                                                     id nativeComponent) {
    if (![source isKindOfClass:UIImage.class] || source.CGImage == NULL ||
        ![nativeComponent isKindOfClass:UIImage.class]) {
        return nil;
    }
    UIImage *nativeImage = nativeComponent;
    if (!MTClockNativeComponentContract(nativeImage)) return nil;
    size_t pixelWidth = CGImageGetWidth(nativeImage.CGImage);
    size_t pixelHeight = CGImageGetHeight(nativeImage.CGImage);
    if (CGImageGetWidth(source.CGImage) == pixelWidth &&
        CGImageGetHeight(source.CGImage) == pixelHeight &&
        source.scale == nativeImage.scale) {
        return source;
    }
    CGSize pointSize = CGSizeMake(
        (CGFloat)pixelWidth / nativeImage.scale,
        (CGFloat)pixelHeight / nativeImage.scale);
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = nativeImage.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:pointSize format:format];
    UIImage *result = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
            (void)context;
            [source drawInRect:(CGRect){CGPointZero, pointSize}];
        }];
    return MTClockNativeComponentContract(result) &&
        CGImageGetWidth(result.CGImage) == pixelWidth &&
        CGImageGetHeight(result.CGImage) == pixelHeight
        ? result : nil;
}

MTClockIconImageSet *MTClockIconSnapshotImageSetMatchingNativeComponents(
    id hourHand,
    id minuteHand,
    id secondHand,
    id hourMinuteDot,
    id secondDot) {
    MTClockIconImageSet *source =
        MTClockIconSnapshotInstance.currentImageSet;
    if (source == nil) return nil;
    UIImage *hour = source.hourHand == nil ? nil :
        MTClockImageMatchingNativeComponent(source.hourHand, hourHand);
    UIImage *minute = source.minuteHand == nil ? nil :
        MTClockImageMatchingNativeComponent(source.minuteHand, minuteHand);
    UIImage *second = source.secondHand == nil ? nil :
        MTClockImageMatchingNativeComponent(source.secondHand, secondHand);
    if (hour == nil && minute == nil && second == nil) return nil;
    UIImage *hourDot = source.hourMinuteDot == nil ? nil :
        MTClockImageMatchingNativeComponent(
            source.hourMinuteDot, hourMinuteDot);
    UIImage *secondsDot = source.secondDot == nil ? nil :
        MTClockImageMatchingNativeComponent(source.secondDot, secondDot);
    return [[MTClockIconImageSet alloc]
        initWithGenerationIdentifier:source.generationIdentifier
        hourHand:hour
        minuteHand:minute
        secondHand:second
        hourMinuteDot:hourDot
        secondDot:secondsDot];
}
