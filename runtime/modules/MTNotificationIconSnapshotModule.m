#import "MTNotificationIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#include <math.h>
#include <stdint.h>

#import "MTDigest.h"
#import "MTIconServiceImageResolver.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshot.h"

NSString *const MTNotificationIconSnapshotModuleErrorDomain =
    @"com.hmmzzz.marktheme.notification-icon-snapshot";

@interface MTNotificationIconSnapshotModule : NSObject
@property(nonatomic, strong) MTRuntimeSnapshot *snapshot;
@property(nonatomic, strong) MTIconServiceImageResolver *resolver;
- (instancetype)initWithSnapshot:(MTRuntimeSnapshot *)snapshot;
- (UIImage *_Nullable)resolveBundleIdentifier:(NSString *)bundleIdentifier
                                originalImage:(UIImage *)originalImage;
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
    return _resolver == nil ? nil : self;
}

- (UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                       originalImage:(UIImage *)originalImage {
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
    CGDataProviderRef provider = CGImageGetDataProvider(originalCGImage);
    CFDataRef pixelData = provider == NULL ? NULL :
        CGDataProviderCopyData(provider);
    if (pixelData == NULL) return nil;
    NSString *stockDigest = MTSHA256HexDigestForData(
        (__bridge NSData *)pixelData);
    CFRelease(pixelData);
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
