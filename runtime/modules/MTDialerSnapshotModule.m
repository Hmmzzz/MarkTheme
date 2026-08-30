#import "MTDialerSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <os/lock.h>

#import "MTDialerContract.h"
#import "MTDialerSnapshotResolver.h"
#import "MTGenerationReader.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

NSString *const MTDialerSnapshotModuleID = @"dialer.snapshot";

static const NSUInteger MTDialerMaximumReadyImageCount = 32;
static const NSUInteger MTDialerMaximumReadyImageCost = 16 * 1024 * 1024;
static const NSUInteger MTDialerMaximumSetDecisionCount = 8;

MTDialerSnapshotObservation MTRuntimeDialerSnapshotObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTDialerSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .imageRequests = ATOMIC_VAR_INIT(0),
    .contractRejects = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
    .completeSetChecks = ATOMIC_VAR_INIT(0),
    .completeSetPasses = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTDialerSnapshotObservation) == 88,
    "The Dialer native-source Module observation layout must remain fixed.");

@interface MTDialerSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTDialerSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong) MTRuntimeObjectCache<UIImage *> *images;
@property(nonatomic, strong) MTRuntimeObjectCache<NSNumber *> *setDecisions;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (BOOL)prepare;
- (void)reload;
- (nullable UIImage *)resolveSubject:(NSString *)subject
                       originalImage:(UIImage *)originalImage;
- (BOOL)hasCompleteNumberSet;
@end

@implementation MTDialerSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    __weak MTRuntimeKernel *weakKernel = kernel;
    _resolver = [[MTDialerSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return weakKernel.currentSnapshot;
        }];
    _imageLoader = [[MTRuntimePublishedImageLoader alloc]
        initWithMaximumEncodedByteCount:8ULL * 1024ULL * 1024ULL
        maximumDecodedByteCount:4ULL * 1024ULL * 1024ULL];
    _images = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTDialerMaximumReadyImageCount
        maximumCost:MTDialerMaximumReadyImageCost];
    _setDecisions = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTDialerMaximumSetDecisionCount
        maximumCost:MTDialerMaximumSetDecisionCount];
    if (_resolver == nil || _imageLoader == nil || _images == nil ||
        _setDecisions == nil) {
        return nil;
    }
    return self;
}

static MTDialerSnapshotContext *MTDialerContextForImage(UIImage *image) {
    CGFloat scale = image.scale;
    if (!isfinite(scale)) return nil;
    NSInteger roundedScale = (NSInteger)llround(scale);
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(scale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }
    return [MTDialerSnapshotContext
        contextWithScale:(NSUInteger)roundedScale deviceTrait:@"iphone"];
}

static NSString *MTDialerImageCacheKey(
    MTDialerSnapshotResolution *resolution,
    MTDialerSnapshotContext *context) {
    return [NSString stringWithFormat:@"%@/%@/%@/%lu",
        resolution.generationIdentifier,
        resolution.canonicalResourceKey,
        resolution.resource.contentSHA256,
        (unsigned long)context.scale];
}

- (nullable UIImage *)decodeResolution:
        (MTDialerSnapshotResolution *)resolution
                                  context:(MTDialerSnapshotContext *)context
                             residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    uint32_t targetDimension = (uint32_t)llround(
        MTDialerButtonPointDimension * (CGFloat)context.scale);
    MTRuntimePublishedImageResizePolicy policy = context.scale == 3
        ? MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
        : MTRuntimePublishedImageResizePolicyExactOrDownsample;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:targetDimension
             targetPixelHeight:targetDimension
                  resizePolicy:policy
                         error:NULL];
    if (decoded == nil ||
        decoded.residentCost > MTDialerMaximumReadyImageCost) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *image = [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)context.scale
        orientation:UIImageOrientationUp];
    if (image == nil ||
        fabs(image.size.width - MTDialerButtonPointDimension) > 0.001 ||
        fabs(image.size.height - MTDialerButtonPointDimension) > 0.001) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (nullable UIImage *)imageForSubject:(NSString *)subject
                               context:(MTDialerSnapshotContext *)context
                    generationIdentifier:(NSString *)generationIdentifier {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.imageRequests,
        1, memory_order_relaxed);
    if (!MTDialerResourceSubjectIsSupported(subject) || context == nil ||
        generationIdentifier.length == 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.contractRejects,
            1, memory_order_relaxed);
        return nil;
    }
    MTDialerSnapshotResolution *resolution = [self.resolver
        resolutionForSubject:subject context:context error:NULL];
    if (resolution == nil ||
        ![resolution.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.resourceHits,
        1, memory_order_relaxed);
    NSString *cacheKey = MTDialerImageCacheKey(resolution, context);
    UIImage *cached = [self.images objectForKey:cacheKey];
    if (cached != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return cached;
    }
    NSUInteger residentCost = 0;
    UIImage *decoded = [self decodeResolution:resolution
                                      context:context
                                 residentCost:&residentCost];
    if (decoded == nil) return nil;
    MTRuntimeSnapshot *current = self.kernel.currentSnapshot;
    if (!current.isReady ||
        ![current.state.activeGenerationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }
    if (![self.images setObject:decoded forKey:cacheKey
                           cost:MAX((NSUInteger)1, residentCost)]) {
        return nil;
    }
    return decoded;
}

- (nullable UIImage *)resolveSubject:(NSString *)subject
                       originalImage:(UIImage *)originalImage {
    if (atomic_load_explicit(
            &MTRuntimeDialerSnapshotObservation.state,
            memory_order_acquire) < MTDialerSnapshotModuleStateConfigured ||
        ![originalImage isKindOfClass:UIImage.class]) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.contractRejects,
            1, memory_order_relaxed);
        return nil;
    }
    MTDialerSnapshotContext *context = MTDialerContextForImage(originalImage);
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (context == nil || !snapshot.isReady ||
        generationIdentifier.length == 0 || snapshot.generation == nil ||
        ![snapshot.generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.contractRejects,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *replacement = [self imageForSubject:subject
                                         context:context
                            generationIdentifier:generationIdentifier];
    if (replacement != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.replacementResults,
            1, memory_order_relaxed);
    }
    return replacement;
}

- (BOOL)hasCompleteNumberSet {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.completeSetChecks,
        1, memory_order_relaxed);
    if (atomic_load_explicit(
            &MTRuntimeDialerSnapshotObservation.state,
            memory_order_acquire) < MTDialerSnapshotModuleStateConfigured) {
        return NO;
    }
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generationIdentifier.length == 0 ||
        snapshot.generation == nil ||
        ![snapshot.generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return NO;
    }
    NSString *decisionKey = [generationIdentifier
        stringByAppendingString:@"/dialer-number-set"];
    NSNumber *cached = [self.setDecisions objectForKey:decisionKey];
    if (cached != nil) {
        if (cached.boolValue) {
            atomic_fetch_add_explicit(
                &MTRuntimeDialerSnapshotObservation.completeSetPasses,
                1, memory_order_relaxed);
        }
        return cached.boolValue;
    }

    // The exact supported iPhone16,1 surface is 3x. The resolver's existing
    // scale order still accepts 2x/1x/universal authored fallbacks, and this
    // successful pass pre-decodes only 12 x 75pt canvases (about 2.4 MiB).
    MTDialerSnapshotContext *context = [MTDialerSnapshotContext
        contextWithScale:3 deviceTrait:@"iphone"];
    BOOL complete = context != nil;
    for (NSString *subject in MTDialerNumberButtonSubjects()) {
        if (!complete || [self imageForSubject:subject
                                      context:context
                         generationIdentifier:generationIdentifier] == nil) {
            complete = NO;
            break;
        }
    }
    MTRuntimeSnapshot *current = self.kernel.currentSnapshot;
    complete = complete && current.isReady &&
        [current.state.activeGenerationIdentifier
            isEqualToString:generationIdentifier];
    (void)[self.setDecisions setObject:@(complete)
                                forKey:decisionKey cost:1];
    if (complete) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.completeSetPasses,
            1, memory_order_relaxed);
    }
    return complete;
}

- (BOOL)prepare {
    atomic_store_explicit(
        &MTRuntimeDialerSnapshotObservation.state,
        MTDialerSnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTDialerSnapshotModuleID, MTDialerSnapshotModuleStateReady,
        @"Ready");
    return YES;
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.reloads,
        1, memory_order_relaxed);
    [self.images removeAllObjects];
    [self.setDecisions removeAllObjects];
    atomic_store_explicit(
        &MTRuntimeDialerSnapshotObservation.state,
        MTDialerSnapshotModuleStateConfigured,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTDialerSnapshotModuleID,
        MTDialerSnapshotModuleStateConfigured, @"Configured");
}

@end

static os_unfair_lock MTDialerSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTDialerSnapshotModule *MTDialerSnapshotInstance;

BOOL MTDialerSnapshotConfigure(MTRuntimeKernel *kernel,
                               NSError **error) {
    if (error != NULL) *error = nil;
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTDialerSnapshotLock);
    if (MTDialerSnapshotInstance == nil) {
        MTDialerSnapshotInstance = [[MTDialerSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTDialerSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTDialerSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeDialerSnapshotObservation.state,
            MTDialerSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTDialerSnapshotModuleID,
            MTDialerSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.dialer-snapshot"
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Dialer source-image module could not initialize."
        }];
    }
    return configured;
}

BOOL MTDialerSnapshotPrepare(void) {
    return [MTDialerSnapshotInstance prepare];
}

void MTDialerSnapshotReload(void) {
    [MTDialerSnapshotInstance reload];
}

id MTDialerSnapshotResolveImage(NSString *subject, id originalResult) {
    if (![originalResult isKindOfClass:UIImage.class]) return nil;
    return [MTDialerSnapshotInstance resolveSubject:subject
                                      originalImage:originalResult];
}

BOOL MTDialerSnapshotHasCompleteNumberSet(void) {
    return [MTDialerSnapshotInstance hasCompleteNumberSet];
}
