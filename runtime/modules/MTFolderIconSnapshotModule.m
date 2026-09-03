#import "MTFolderIconSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTIconOverlaySnapshotModule.h"
#import "MTStaticIconVisualProofContract.h"
#import "MTSpringBoardDecorationSnapshotResolver.h"
#import "MTRuntimeABIReport.h"

#include <math.h>
#include <stdatomic.h>

NSString *const MTFolderIconSnapshotModuleID = @"folder-icons.snapshot";

MTFolderIconSnapshotObservation MTRuntimeFolderIconSnapshotObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTFolderIconSnapshotModuleStateDormant),
    .baseResourceHits = ATOMIC_VAR_INIT(0),
    .lightResourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .backgroundResolutions = ATOMIC_VAR_INIT(0),
    .backgroundReplacements = ATOMIC_VAR_INIT(0),
    .overlayActivations = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTFolderIconSnapshotObservation) == 64,
    "Folder ModuleRuntime observation ABI changed");

@interface MTFolderIconImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) UIImage *background;
@property(nonatomic, strong, nullable) UIImage *lightBackground;
@end

@implementation MTFolderIconImageSet
@end

@interface MTFolderThemedBackgroundImageView : UIImageView
@property(nonatomic, copy) NSString *generationIdentifier;
@end

@implementation MTFolderThemedBackgroundImageView
@end

@interface MTFolderOverlayState : NSObject {
@public
    CGFloat _gridAlpha;
    CGFloat _floatyFraction;
    __strong UIImageView *_overlayView;
}
@end

@implementation MTFolderOverlayState
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _gridAlpha = 1.0;
    return self;
}
@end

@interface MTFolderIconSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong)
    MTSpringBoardDecorationSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(atomic, strong, nullable) MTFolderIconImageSet *currentImageSet;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)loadInitialImageSet;
- (nullable UIView *)resolveNativeBackgroundForFolderView:(UIView *)folderView
                                         nativeBackground:(UIView *)nativeBackground;
- (BOOL)synchronizeOverlayForFolderView:(UIView *)folderView
                     installedBackground:(nullable UIView *)installedBackground;
@end

static char MTFolderOverlayStateAssociationKey;

static CGFloat MTFolderNormalizedOverlayAlpha(CGFloat alpha) {
    if (!isfinite(alpha)) return 1.0;
    return fmin(1.0, fmax(0.0, alpha));
}

static MTFolderOverlayState *MTFolderOverlayStateForFolderView(
    UIView *folderView,
    BOOL create) {
    if (folderView == nil) return nil;
    MTFolderOverlayState *state = objc_getAssociatedObject(
        folderView, &MTFolderOverlayStateAssociationKey);
    if (state == nil && create) {
        state = [[MTFolderOverlayState alloc] init];
        objc_setAssociatedObject(
            folderView, &MTFolderOverlayStateAssociationKey, state,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static CGFloat MTFolderEffectiveOverlayAlpha(MTFolderOverlayState *state) {
    if (state == nil) return 1.0;
    return state->_gridAlpha * (1.0 - state->_floatyFraction);
}

static BOOL MTFolderApplyEffectiveOverlayAlpha(
    MTFolderOverlayState *state) {
    UIImageView *overlayView = state->_overlayView;
    if (![overlayView isKindOfClass:UIImageView.class]) return NO;
    overlayView.alpha = MTFolderEffectiveOverlayAlpha(state);
    return YES;
}

static BOOL MTFolderSetAssociatedOverlayGridAlpha(UIView *folderView,
                                                   CGFloat alpha) {
    MTFolderOverlayState *state = MTFolderOverlayStateForFolderView(
        folderView, YES);
    if (state == nil) return NO;
    state->_gridAlpha = MTFolderNormalizedOverlayAlpha(alpha);
    return MTFolderApplyEffectiveOverlayAlpha(state);
}

static BOOL MTFolderSetAssociatedFloatyFraction(UIView *folderView,
                                                 CGFloat fraction) {
    MTFolderOverlayState *state = MTFolderOverlayStateForFolderView(
        folderView, YES);
    if (state == nil) return NO;
    state->_floatyFraction = MTFolderNormalizedOverlayAlpha(fraction);
    return MTFolderApplyEffectiveOverlayAlpha(state);
}

static BOOL MTFolderRemoveAssociatedOverlay(UIView *folderView) {
    MTFolderOverlayState *state = MTFolderOverlayStateForFolderView(
        folderView, NO);
    UIImageView *overlayView = state->_overlayView;
    BOOL removed = [overlayView isKindOfClass:UIImageView.class];
    [overlayView removeFromSuperview];
    state->_overlayView = nil;
    return removed;
}

static BOOL MTFolderPointSizeIsSupported(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) &&
        size.width >= 1.0 && size.height >= 1.0 &&
        size.width <= 400.0 && size.height <= 400.0;
}

typedef struct MTFolderInstalledBackgroundGeometry {
    CGSize pointSize;
    CGRect bounds;
    CGPoint center;
    CGAffineTransform transform;
    UIViewAutoresizing autoresizingMask;
} MTFolderInstalledBackgroundGeometry;

static BOOL MTFolderResolveInstalledBackgroundGeometry(
    UIView *folderView,
    UIView *backgroundView,
    MTFolderInstalledBackgroundGeometry *geometry) {
    if (folderView == nil || backgroundView == nil || geometry == NULL) {
        return NO;
    }

    CGSize pointSize = backgroundView.bounds.size;
    if (backgroundView == folderView &&
        MTFolderPointSizeIsSupported(pointSize)) {
        geometry->pointSize = pointSize;
        geometry->bounds = folderView.bounds;
        geometry->center = CGPointMake(
            CGRectGetMidX(folderView.bounds),
            CGRectGetMidY(folderView.bounds));
        geometry->transform = CGAffineTransformIdentity;
        geometry->autoresizingMask =
            UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        return YES;
    }
    if (backgroundView.superview == folderView &&
        MTFolderPointSizeIsSupported(pointSize)) {
        geometry->pointSize = pointSize;
        geometry->bounds = backgroundView.bounds;
        geometry->center = backgroundView.center;
        geometry->transform = backgroundView.transform;
        geometry->autoresizingMask = backgroundView.autoresizingMask;
        return YES;
    }

    CGRect frame = [backgroundView isDescendantOfView:folderView]
        ? [backgroundView convertRect:backgroundView.bounds
                               toView:folderView]
        : backgroundView.frame;
    if (!MTFolderPointSizeIsSupported(frame.size)) return NO;
    if (!MTFolderPointSizeIsSupported(pointSize)) pointSize = frame.size;
    geometry->pointSize = pointSize;
    geometry->bounds = (CGRect){CGPointZero, frame.size};
    geometry->center = CGPointMake(
        CGRectGetMidX(frame), CGRectGetMidY(frame));
    geometry->transform = CGAffineTransformIdentity;
    geometry->autoresizingMask = UIViewAutoresizingNone;
    return YES;
}

static CGFloat MTFolderDisplayScale(UIView *folderView,
                                    UIView *backgroundView) {
    CGFloat scale = folderView.traitCollection.displayScale;
    if (!isfinite(scale) || scale < 1.0) {
        scale = folderView.layer.contentsScale;
    }
    if ((!isfinite(scale) || scale < 1.0) && backgroundView != nil) {
        scale = backgroundView.traitCollection.displayScale;
    }
    if ((!isfinite(scale) || scale < 1.0) && backgroundView != nil) {
        scale = backgroundView.layer.contentsScale;
    }
    if (!isfinite(scale) || scale < 1.0) {
        scale = folderView.contentScaleFactor;
    }
    NSInteger roundedScale = isfinite(scale)
        ? (NSInteger)llround(scale) : 0;
    return roundedScale >= 1 && roundedScale <= 3 &&
        fabs(scale - (CGFloat)roundedScale) <= 0.001
            ? (CGFloat)roundedScale : 0.0;
}

static UIImage *MTFolderResolveOverlayArtwork(
    UIView *folderView,
    UIView *backgroundView,
    const MTFolderInstalledBackgroundGeometry *geometry,
    CGFloat displayScale) {
    if (folderView == nil || backgroundView == nil || geometry == NULL ||
        displayScale <= 0) return nil;

    // Background views in SpringBoard may use a large internal coordinate
    // space plus a transform. Prefer the installed image's logical size, then
    // the transformed on-screen extent, before falling back to either view's
    // raw bounds. Every candidate is only a target rendering contract: the
    // authored overlay itself remains unrestricted and is scale-to-filled into
    // the exact installed background geometry by the caller.
    CGSize candidates[5] = {0};
    NSUInteger candidateCount = 0;
    if ([backgroundView isKindOfClass:UIImageView.class]) {
        UIImage *backgroundImage = ((UIImageView *)backgroundView).image;
        if (backgroundImage != nil) {
            candidates[candidateCount++] = backgroundImage.size;
        }
    }
    CGRect displayedFrame = [backgroundView convertRect:backgroundView.bounds
                                                  toView:folderView];
    candidates[candidateCount++] = CGSizeMake(
        fabs(displayedFrame.size.width), fabs(displayedFrame.size.height));
    candidates[candidateCount++] = folderView.bounds.size;
    candidates[candidateCount++] = geometry->pointSize;
    candidates[candidateCount++] =
        MTStaticIconVisualProofExpectedPointSize;

    for (NSUInteger index = 0; index < candidateCount; index++) {
        CGSize pointSize = candidates[index];
        if (!MTFolderPointSizeIsSupported(pointSize) ||
            fabs(pointSize.width - pointSize.height) > 0.001) {
            continue;
        }
        UIImage *artwork = MTIconOverlaySnapshotResolveArtwork(
            pointSize, displayScale);
        if (artwork != nil) return artwork;
    }
    return nil;
}

@implementation MTFolderIconSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _resolver = [[MTSpringBoardDecorationSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return kernel.currentSnapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    if (_resolver == nil || _imageLoader == nil) return nil;
    return self;
}

- (nullable UIImage *)decodeResolution:
    (MTSpringBoardDecorationSnapshotResolution *)resolution {
    if (resolution == nil) return nil;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:180
             targetPixelHeight:180
                         error:NULL];
    UIImage *image = decoded == nil ? nil : [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:MTStaticIconVisualProofExpectedScale
        orientation:UIImageOrientationUp];
    if (!MTStaticIconVisualProofImageContractIsSupported(
            image.size, image.scale)) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderIconSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return image;
}

- (void)publishImageSet:(nullable MTFolderIconImageSet *)imageSet {
    self.currentImageSet = imageSet;
    atomic_store_explicit(
        &MTRuntimeFolderIconSnapshotObservation.state,
        imageSet == nil ? MTFolderIconSnapshotModuleStateConfigured
                        : MTFolderIconSnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTFolderIconSnapshotModuleID,
        imageSet == nil ? MTFolderIconSnapshotModuleStateConfigured
                        : MTFolderIconSnapshotModuleStateReady,
        imageSet == nil ? @"Configured" : @"Ready");
}

- (void)loadInitialImageSet {
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    if (!snapshot.isReady) {
        [self publishImageSet:nil];
        return;
    }

    NSError *baseError = nil;
    MTSpringBoardDecorationSnapshotResolution *base = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindFolderBackground
                     error:&baseError];
    if (base == nil || baseError != nil) {
        [self publishImageSet:nil];
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.baseResourceHits,
        1, memory_order_relaxed);
    UIImage *background = [self decodeResolution:base];
    if (background == nil) {
        [self publishImageSet:nil];
        return;
    }

    NSError *lightError = nil;
    MTSpringBoardDecorationSnapshotResolution *light = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindFolderBackgroundLight
                     error:&lightError];
    UIImage *lightBackground = nil;
    if (light != nil && lightError == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderIconSnapshotObservation.lightResourceHits,
            1, memory_order_relaxed);
        if ([light.resource.contentSHA256
                isEqualToString:base.resource.contentSHA256]) {
            lightBackground = background;
        } else {
            lightBackground = [self decodeResolution:light];
        }
    }

    MTFolderIconImageSet *imageSet = [[MTFolderIconImageSet alloc] init];
    imageSet.generationIdentifier = base.generationIdentifier;
    imageSet.background = background;
    imageSet.lightBackground = lightBackground;
    [self publishImageSet:imageSet];
}

- (nullable UIView *)resolveNativeBackgroundForFolderView:(UIView *)folderView
                                         nativeBackground:(UIView *)nativeBackground {
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.backgroundResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return nativeBackground;

    MTFolderIconImageSet *imageSet = self.currentImageSet;
    if (imageSet == nil) return nativeBackground;
    BOOL prefersLight = folderView.traitCollection.userInterfaceStyle ==
        UIUserInterfaceStyleLight;
    UIImage *image = prefersLight && imageSet.lightBackground != nil
        ? imageSet.lightBackground : imageSet.background;
    if (image == nil) return nativeBackground;

    if ([nativeBackground
            isKindOfClass:MTFolderThemedBackgroundImageView.class]) {
        MTFolderThemedBackgroundImageView *existing =
            (MTFolderThemedBackgroundImageView *)nativeBackground;
        if ([existing.generationIdentifier
                isEqualToString:imageSet.generationIdentifier]) {
            existing.image = image;
            return existing;
        }
    }

    CGRect nativeBounds = nativeBackground.bounds;
    CGPoint nativeCenter = nativeBackground.center;
    CGAffineTransform nativeTransform = nativeBackground.transform;
    if (!MTFolderPointSizeIsSupported(nativeBounds.size)) {
        CGRect fallbackFrame = nativeBackground.frame;
        if (!MTFolderPointSizeIsSupported(fallbackFrame.size)) {
            fallbackFrame = folderView.bounds;
        }
        nativeBounds = (CGRect){CGPointZero, fallbackFrame.size};
        nativeCenter = CGPointMake(
            CGRectGetMidX(fallbackFrame), CGRectGetMidY(fallbackFrame));
        nativeTransform = CGAffineTransformIdentity;
    }

    MTFolderThemedBackgroundImageView *replacement =
        [[MTFolderThemedBackgroundImageView alloc] initWithFrame:CGRectZero];
    replacement.generationIdentifier = imageSet.generationIdentifier;
    replacement.image = image;
    replacement.autoresizingMask = nativeBackground.autoresizingMask;
    replacement.alpha = nativeBackground.alpha;
    replacement.hidden = nativeBackground.hidden;
    replacement.bounds = nativeBounds;
    replacement.center = nativeCenter;
    replacement.transform = nativeTransform;
    replacement.backgroundColor = UIColor.clearColor;
    replacement.contentMode = UIViewContentModeScaleAspectFill;
    replacement.clipsToBounds = YES;
    replacement.userInteractionEnabled = NO;
    replacement.isAccessibilityElement = NO;
    replacement.accessibilityElementsHidden = YES;
    replacement.layer.cornerCurve = kCACornerCurveContinuous;
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.backgroundReplacements,
        1, memory_order_relaxed);
    return replacement;
}

- (BOOL)synchronizeOverlayForFolderView:(UIView *)folderView
                     installedBackground:(nullable UIView *)installedBackground {
    if (![NSThread isMainThread]) return NO;
    if (!MTIconOverlaySnapshotIsEnabled()) {
        (void)MTFolderRemoveAssociatedOverlay(folderView);
        return NO;
    }
    MTFolderOverlayState *state = MTFolderOverlayStateForFolderView(
        folderView, YES);
    if (state == nil) return NO;
    UIImageView *overlayView = state->_overlayView;

    // A stock folder need not expose a separate backgroundView and may never
    // call setBackgroundView: after Runtime installation. Its own bounds remain
    // the geometry fallback. The overlay is permanently retained by this
    // compact folder canvas so native motion applies without a detached view.
    UIView *geometryCarrier = installedBackground ?: folderView;
    UIView *overlayContainer = folderView;
    MTFolderInstalledBackgroundGeometry geometry = {0};
    BOOL hasGeometry = MTFolderResolveInstalledBackgroundGeometry(
        folderView, geometryCarrier, &geometry);
    CGFloat displayScale = MTFolderDisplayScale(
        folderView, geometryCarrier);
    UIImage *overlayImage =
        hasGeometry && displayScale > 0
            ? MTFolderResolveOverlayArtwork(
                folderView, geometryCarrier, &geometry, displayScale)
            : nil;
    if (overlayImage == nil) {
        (void)MTFolderRemoveAssociatedOverlay(folderView);
        return NO;
    }
    if (overlayView == nil) {
        overlayView = [[UIImageView alloc] initWithFrame:CGRectZero];
        overlayView.backgroundColor = UIColor.clearColor;
        overlayView.contentMode = UIViewContentModeScaleToFill;
        overlayView.userInteractionEnabled = NO;
        overlayView.isAccessibilityElement = NO;
        overlayView.accessibilityElementsHidden = YES;
        state->_overlayView = overlayView;
    }
    overlayView.autoresizingMask = geometry.autoresizingMask;
    overlayView.bounds = geometry.bounds;
    overlayView.center = geometry.center;
    overlayView.transform = geometry.transform;
    overlayView.hidden = NO;
    overlayView.layer.zPosition = 1000.0;
    UIImage *current = overlayView.image;
    BOOL sameRaster = current != nil &&
        current.CGImage == overlayImage.CGImage &&
        current.scale == overlayImage.scale &&
        current.imageOrientation == overlayImage.imageOrientation;
    if (!sameRaster) overlayView.image = overlayImage;
    if (overlayView.superview != overlayContainer) {
        [overlayContainer addSubview:overlayView];
    }
    if (overlayContainer.subviews.lastObject != overlayView) {
        [overlayContainer bringSubviewToFront:overlayView];
    }
    (void)MTFolderApplyEffectiveOverlayAlpha(state);
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.overlayActivations,
        1, memory_order_relaxed);
    return YES;
}

@end

static os_unfair_lock MTFolderIconSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTFolderIconSnapshotModule *MTFolderIconSnapshotInstance;

BOOL MTFolderIconSnapshotConfigure(MTRuntimeKernel *kernel,
                                   NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTFolderIconSnapshotLock);
    if (MTFolderIconSnapshotInstance == nil) {
        MTFolderIconSnapshotInstance = [[MTFolderIconSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTFolderIconSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTFolderIconSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeFolderIconSnapshotObservation.state,
            MTFolderIconSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTFolderIconSnapshotModuleID,
            MTFolderIconSnapshotModuleStateConfigured, @"Configured");
        [MTFolderIconSnapshotInstance loadInitialImageSet];
    } else if (error != NULL) {
        *error = [NSError errorWithDomain:
            @"com.hmmzzz.marktheme.folder-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"Folder snapshot module could not initialize."
        }];
    }
    return configured;
}

BOOL MTFolderIconSnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTFolderIconSnapshotLock);
    BOOL prepared = MTFolderIconSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTFolderIconSnapshotLock);
    return prepared;
}

id MTFolderIconSnapshotResolveNativeBackground(
    id folderImageView,
    id nativeBackgroundView) {
    if (![folderImageView isKindOfClass:UIView.class] ||
        ![nativeBackgroundView isKindOfClass:UIView.class]) {
        return nativeBackgroundView;
    }
    return [MTFolderIconSnapshotInstance
        resolveNativeBackgroundForFolderView:folderImageView
        nativeBackground:nativeBackgroundView];
}

BOOL MTFolderIconSnapshotSynchronizeOverlay(
    id folderImageView,
    id installedBackgroundView) {
    if (![folderImageView isKindOfClass:UIView.class] ||
        (installedBackgroundView != nil &&
         ![installedBackgroundView isKindOfClass:UIView.class])) {
        return NO;
    }
    return [MTFolderIconSnapshotInstance
        synchronizeOverlayForFolderView:folderImageView
        installedBackground:installedBackgroundView];
}

BOOL MTFolderIconSnapshotSetOverlayAlpha(id folderImageView,
                                         CGFloat alpha) {
    if (![NSThread isMainThread] ||
        ![folderImageView isKindOfClass:UIView.class]) {
        return NO;
    }
    return MTFolderSetAssociatedOverlayGridAlpha(folderImageView, alpha);
}

BOOL MTFolderIconSnapshotSetFloatyCrossfadeFraction(
    id folderImageView,
    CGFloat fraction) {
    if (![NSThread isMainThread] ||
        ![folderImageView isKindOfClass:UIView.class]) {
        return NO;
    }
    return MTFolderSetAssociatedFloatyFraction(
        folderImageView, fraction);
}
