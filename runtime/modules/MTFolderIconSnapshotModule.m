#import "MTFolderIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStaticIconVisualProofContract.h"
#import "MTSpringBoardDecorationSnapshotResolver.h"

NSString *const MTFolderIconSnapshotModuleID = @"folder-icons.snapshot";

MTFolderIconSnapshotObservation MTRuntimeFolderIconSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTFolderIconSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .baseResourceHits = ATOMIC_VAR_INIT(0),
    .lightResourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .viewResolutions = ATOMIC_VAR_INIT(0),
    .replacementViewsCreated = ATOMIC_VAR_INIT(0),
    .originalViewsRestored = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTFolderIconSnapshotObservation) == 72,
    "The Folder ModuleRuntime observation layout must remain fixed.");

@interface MTFolderIconImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) UIImage *background;
@property(nonatomic, strong, nullable) UIImage *lightBackground;
@end

@implementation MTFolderIconImageSet
@end

@interface MTFolderIconSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong)
    MTSpringBoardDecorationSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(atomic, strong, nullable) MTFolderIconImageSet *currentImageSet;
@property(atomic, assign) uint64_t requestedEpoch;
@property(atomic, copy, nullable) dispatch_block_t readyHandler;
@property(nonatomic, strong) NSMapTable<UIView *, id> *originalViews;
@property(nonatomic, strong)
    NSMapTable<UIView *, UIImageView *> *replacementViews;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)reload;
- (nullable UIView *)resolveFolderView:(UIView *)folderView
                    originalBackground:(nullable UIView *)originalBackground
                            didReplace:(BOOL *)didReplace;
@end

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
    _originalViews = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    _replacementViews = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (_resolver == nil || _imageLoader == nil || _originalViews == nil ||
        _replacementViews == nil) {
        return nil;
    }
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

- (void)publishImageSet:(nullable MTFolderIconImageSet *)imageSet
                   epoch:(uint64_t)epoch
    generationIdentifier:(nullable NSString *)generationIdentifier {
    if (self.requestedEpoch != epoch) return;
    NSString *active = self.kernel.currentSnapshot
        .state.activeGenerationIdentifier;
    if (generationIdentifier != nil &&
        ![active isEqualToString:generationIdentifier]) {
        return;
    }
    self.currentImageSet = imageSet;
    atomic_store_explicit(
        &MTRuntimeFolderIconSnapshotObservation.state,
        imageSet == nil ? MTFolderIconSnapshotModuleStateConfigured
                        : MTFolderIconSnapshotModuleStateReady,
        memory_order_release);
    dispatch_block_t handler = self.readyHandler;
    if (handler != nil) dispatch_async(dispatch_get_main_queue(), handler);
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.reloads,
        1, memory_order_relaxed);
    uint64_t epoch = 0;
    @synchronized (self) {
        epoch = self.requestedEpoch + 1;
        self.requestedEpoch = epoch;
    }
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    if (!snapshot.isReady) {
        [self publishImageSet:nil epoch:epoch generationIdentifier:nil];
        return;
    }

    NSError *baseError = nil;
    MTSpringBoardDecorationSnapshotResolution *base = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindFolderBackground
                     error:&baseError];
    if (base == nil || baseError != nil) {
        [self publishImageSet:nil epoch:epoch generationIdentifier:nil];
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.baseResourceHits,
        1, memory_order_relaxed);
    UIImage *background = [self decodeResolution:base];
    if (background == nil) {
        [self publishImageSet:nil epoch:epoch generationIdentifier:nil];
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
    [self publishImageSet:imageSet
                    epoch:epoch
     generationIdentifier:base.generationIdentifier];
}

- (nullable UIView *)resolveFolderView:(UIView *)folderView
                    originalBackground:(nullable UIView *)originalBackground
                            didReplace:(BOOL *)didReplace {
    if (didReplace != NULL) *didReplace = NO;
    atomic_fetch_add_explicit(
        &MTRuntimeFolderIconSnapshotObservation.viewResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return originalBackground;

    UIImageView *replacement = [self.replacementViews objectForKey:folderView];
    if (originalBackground != replacement) {
        [self.originalViews setObject:originalBackground ?: NSNull.null
                               forKey:folderView];
    }

    MTFolderIconImageSet *imageSet = self.currentImageSet;
    if (imageSet == nil) {
        if (replacement != nil && originalBackground == replacement) {
            id stored = [self.originalViews objectForKey:folderView];
            UIView *restored = stored == NSNull.null ? nil : stored;
            [self.replacementViews removeObjectForKey:folderView];
            [self.originalViews removeObjectForKey:folderView];
            if (didReplace != NULL) *didReplace = YES;
            atomic_fetch_add_explicit(
                &MTRuntimeFolderIconSnapshotObservation.originalViewsRestored,
                1, memory_order_relaxed);
            return restored;
        }
        [self.replacementViews removeObjectForKey:folderView];
        [self.originalViews removeObjectForKey:folderView];
        return originalBackground;
    }

    BOOL prefersLight = folderView.traitCollection.userInterfaceStyle ==
        UIUserInterfaceStyleLight;
    UIImage *image = prefersLight && imageSet.lightBackground != nil
        ? imageSet.lightBackground : imageSet.background;
    if (replacement == nil) {
        CGRect frame = originalBackground == nil
            ? folderView.bounds : originalBackground.frame;
        replacement = [[UIImageView alloc] initWithFrame:frame];
        replacement.autoresizingMask = originalBackground == nil
            ? UIViewAutoresizingFlexibleWidth |
              UIViewAutoresizingFlexibleHeight
            : originalBackground.autoresizingMask;
        replacement.backgroundColor = UIColor.clearColor;
        replacement.contentMode = UIViewContentModeScaleAspectFill;
        replacement.clipsToBounds = YES;
        replacement.userInteractionEnabled = NO;
        [self.replacementViews setObject:replacement forKey:folderView];
        atomic_fetch_add_explicit(
            &MTRuntimeFolderIconSnapshotObservation.replacementViewsCreated,
            1, memory_order_relaxed);
    }
    replacement.image = image;
    if (originalBackground == replacement) return originalBackground;
    if (didReplace != NULL) *didReplace = YES;
    return replacement;
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

void MTFolderIconSnapshotReload(void) {
    [MTFolderIconSnapshotInstance reload];
}

void MTFolderIconSnapshotSetReadyHandler(dispatch_block_t handler) {
    MTFolderIconSnapshotInstance.readyHandler = handler;
}

id MTFolderIconSnapshotResolveBackgroundView(id folderImageView,
                                             id originalBackgroundView,
                                             BOOL *didReplace) {
    if (didReplace != NULL) *didReplace = NO;
    if (![folderImageView isKindOfClass:UIView.class] ||
        (originalBackgroundView != nil &&
         ![originalBackgroundView isKindOfClass:UIView.class])) {
        return originalBackgroundView;
    }
    return [MTFolderIconSnapshotInstance
        resolveFolderView:folderImageView
        originalBackground:originalBackgroundView
        didReplace:didReplace];
}
