#import "MTNotificationIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#include <math.h>
#include <stdint.h>

#import "MTApplicationIconSourceState.h"
#import "MTDigest.h"
#import "MTIconServiceImageResolver.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshot.h"

NSString *const MTNotificationIconSnapshotModuleErrorDomain =
    @"com.hmmzzz.marktheme.notification-icon-snapshot";

static const NSUInteger MTNotificationMaximumDigestCount = 128;
static const NSUInteger MTNotificationMaximumDigestCost = 32 * 1024 * 1024;
static const NSUInteger MTNotificationMaximumScopeCount = 512;

// The entry retains its CGImage, not merely its address. That makes a pointer
// key safe: the allocator cannot reuse the address for a different image while
// the cached digest remains reachable.
@interface MTNotificationIconDigestEntry : NSObject
@property(nonatomic, assign, readonly) CGImageRef image;
@property(nonatomic, copy, readonly) NSString *digest;
- (instancetype)initWithImage:(CGImageRef)image digest:(NSString *)digest;
@end

@implementation MTNotificationIconDigestEntry

- (instancetype)initWithImage:(CGImageRef)image digest:(NSString *)digest {
    if (image == NULL || digest.length != 64) return nil;
    self = [super init];
    if (self == nil) return nil;
    _image = CGImageRetain(image);
    _digest = [digest copy];
    return self;
}

- (void)dealloc {
    if (_image != NULL) CGImageRelease(_image);
}

@end

@interface MTNotificationIconSnapshotModule : NSObject
@property(nonatomic, strong) MTRuntimeSnapshot *snapshot;
@property(nonatomic, strong) MTIconServiceImageResolver *resolver;
@property(nonatomic, strong)
    NSCache<NSString *, NSNumber *> *affectedBundleCache;
@property(nonatomic, strong)
    NSCache<NSValue *, MTNotificationIconDigestEntry *> *digestCache;
- (instancetype)initWithSnapshot:(MTRuntimeSnapshot *)snapshot;
- (UIImage *_Nullable)resolveBundleIdentifier:(NSString *)bundleIdentifier
                                originalImage:(UIImage *)originalImage;
- (BOOL)snapshotAffectsBundleIdentifier:(NSString *)bundleIdentifier;
- (NSString *_Nullable)stockDigestForImage:(CGImageRef)image;
@end

@implementation MTNotificationIconSnapshotModule

- (instancetype)initWithSnapshot:(MTRuntimeSnapshot *)snapshot {
    if (![snapshot isKindOfClass:MTRuntimeSnapshot.class]) return nil;
    self = [super init];
    if (self == nil) return nil;
    _snapshot = snapshot;
    MTRuntimeSnapshot *capturedSnapshot = snapshot;
    _resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return capturedSnapshot;
        }
        dynamicCategoryPolicy:
            MTIconServiceDynamicCategoryPolicyPreserveStockSource];
    _affectedBundleCache = [[NSCache alloc] init];
    _affectedBundleCache.countLimit = MTNotificationMaximumScopeCount;
    _digestCache = [[NSCache alloc] init];
    _digestCache.countLimit = MTNotificationMaximumDigestCount;
    _digestCache.totalCostLimit = MTNotificationMaximumDigestCost;
    return _resolver == nil || _affectedBundleCache == nil ||
        _digestCache == nil ? nil : self;
}

- (BOOL)snapshotAffectsBundleIdentifier:(NSString *)bundleIdentifier {
    NSNumber *cached = [self.affectedBundleCache
        objectForKey:bundleIdentifier];
    if (cached != nil) return cached.boolValue;
    BOOL affected = MTApplicationIconSnapshotAffectsBundleIdentifier(
        self.snapshot, bundleIdentifier);
    [self.affectedBundleCache setObject:@(affected)
                                forKey:bundleIdentifier];
    return affected;
}

- (NSString *)stockDigestForImage:(CGImageRef)image {
    if (image == NULL) return nil;
    NSValue *key = [NSValue valueWithPointer:(const void *)image];
    MTNotificationIconDigestEntry *cached =
        [self.digestCache objectForKey:key];
    if (cached != nil && cached.image == image) return cached.digest;

    CGDataProviderRef provider = CGImageGetDataProvider(image);
    CFDataRef pixelData = provider == NULL ? NULL :
        CGDataProviderCopyData(provider);
    if (pixelData == NULL) return nil;
    NSString *digest = MTSHA256HexDigestForData(
        (__bridge NSData *)pixelData);
    CFIndex byteCount = CFDataGetLength(pixelData);
    CFRelease(pixelData);
    if (digest.length != 64 || byteCount <= 0) return nil;
    MTNotificationIconDigestEntry *entry =
        [[MTNotificationIconDigestEntry alloc]
            initWithImage:image digest:digest];
    if (entry != nil &&
        (uint64_t)byteCount <= MTNotificationMaximumDigestCost) {
        [self.digestCache setObject:entry forKey:key
                              cost:(NSUInteger)byteCount];
    }
    return digest;
}

- (UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                       originalImage:(UIImage *)originalImage {
    if (![self snapshotAffectsBundleIdentifier:bundleIdentifier]) return nil;
    CGImageRef originalCGImage = originalImage.CGImage;
    CGSize pointSize = originalImage.size;
    CGFloat scale = originalImage.scale;
    if (originalCGImage == NULL ||
        !isfinite(pointSize.width) || !isfinite(pointSize.height) ||
        pointSize.width <= 0 || pointSize.width != pointSize.height ||
        !isfinite(scale) || scale < 1 || scale > 3 ||
        floor(scale) != scale) {
        return nil;
    }
    size_t width = CGImageGetWidth(originalCGImage);
    size_t height = CGImageGetHeight(originalCGImage);
    if (width == 0 || width != height || width > 1200 ||
        width > UINT32_MAX ||
        fabs(pointSize.width * scale - (CGFloat)width) > 0.001 ||
        fabs(pointSize.height * scale - (CGFloat)height) > 0.001) {
        return nil;
    }
    NSString *stockDigest = [self stockDigestForImage:originalCGImage];
    if (stockDigest.length != 64) return nil;

    CGImageRef replacementCGImage = [self.resolver
        copyReplacementForBundleIdentifier:bundleIdentifier
        pointSize:pointSize
        scale:scale
        pixelWidth:(uint32_t)width
        pixelHeight:(uint32_t)height
        stockImageDigest:stockDigest
        stockCGImage:originalCGImage
        error:NULL];
    if (replacementCGImage == NULL) return nil;
    UIImage *replacement = [UIImage
        imageWithCGImage:replacementCGImage
        scale:scale
        orientation:originalImage.imageOrientation];
    CGImageRelease(replacementCGImage);
    if (replacement == nil || replacement.CGImage == NULL ||
        !CGSizeEqualToSize(replacement.size, pointSize) ||
        replacement.scale != scale ||
        CGImageGetWidth(replacement.CGImage) != width ||
        CGImageGetHeight(replacement.CGImage) != height) {
        return nil;
    }
    return replacement;
}

@end

static os_unfair_lock MTNotificationIconSnapshotLock =
    OS_UNFAIR_LOCK_INIT;
static MTNotificationIconSnapshotModule *
    MTNotificationIconSnapshotModuleInstance;

static void MTNotificationIconSnapshotSetError(
    NSError **error,
    NSString *description) {
    if (error == NULL) return;
    *error = [NSError
        errorWithDomain:MTNotificationIconSnapshotModuleErrorDomain
        code:1
        userInfo:@{ NSLocalizedDescriptionKey : description }];
}

BOOL MTNotificationIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) {
        MTNotificationIconSnapshotSetError(
            error, @"Notification icon snapshot requires a Runtime Kernel.");
        return NO;
    }
    os_unfair_lock_lock(&MTNotificationIconSnapshotLock);
    if (MTNotificationIconSnapshotModuleInstance == nil) {
        MTNotificationIconSnapshotModuleInstance =
            [[MTNotificationIconSnapshotModule alloc]
                initWithSnapshot:kernel.currentSnapshot];
    }
    BOOL configured = MTNotificationIconSnapshotModuleInstance != nil;
    os_unfair_lock_unlock(&MTNotificationIconSnapshotLock);
    if (!configured) {
        MTNotificationIconSnapshotSetError(error,
            @"Notification icon snapshot could not bind the shared IconServices compositor to the bootstrap Generation.");
    }
    return configured;
}

BOOL MTNotificationIconSnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTNotificationIconSnapshotLock);
    BOOL prepared = MTNotificationIconSnapshotModuleInstance != nil;
    os_unfair_lock_unlock(&MTNotificationIconSnapshotLock);
    return prepared;
}

id MTNotificationIconSnapshotResolve(NSString *bundleIdentifier,
                                     id originalImage) {
    if (![bundleIdentifier isKindOfClass:NSString.class] ||
        ![originalImage isKindOfClass:UIImage.class]) {
        return nil;
    }
    return [MTNotificationIconSnapshotModuleInstance
        resolveBundleIdentifier:bundleIdentifier
        originalImage:originalImage];
}
