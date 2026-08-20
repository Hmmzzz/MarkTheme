#import "MTThemePreviewProvider.h"

#import <ImageIO/ImageIO.h>

#import "MTResourceKey.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

@interface UIImage (MTApplicationIconPrivate)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:
    (NSString *)bundleIdentifier
                                                        format:(int)format
                                                         scale:(CGFloat)scale;
@end

static NSArray<NSString *> *MTThemePreviewBundleIdentifiers(void) {
    static NSArray<NSString *> *bundleIdentifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundleIdentifiers = @[
            @"com.apple.mobilephone",
            @"com.apple.MobileSMS",
            @"com.apple.mobilesafari",
            @"com.apple.mobilemail",
            @"com.apple.camera",
            @"com.apple.AppStore",
            @"com.apple.mobileslideshow",
            @"com.apple.Maps",
            @"com.apple.Preferences",
            @"com.apple.mobilecal",
            @"com.apple.mobiletimer",
        ];
    });
    return bundleIdentifiers;
}

static UIImage *MTSystemPreviewFallbackImage(NSString *bundleIdentifier) {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *styles = @{
        @"com.apple.mobilephone" : @{
            @"symbol" : @"phone.fill",
            @"color" : [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0],
        },
        @"com.apple.MobileSMS" : @{
            @"symbol" : @"message.fill",
            @"color" : [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0],
        },
        @"com.apple.mobilesafari" : @{
            @"symbol" : @"safari.fill",
            @"color" : [UIColor colorWithRed:0.05 green:0.48 blue:1.0 alpha:1.0],
        },
        @"com.apple.mobilemail" : @{
            @"symbol" : @"envelope.fill",
            @"color" : [UIColor colorWithRed:0.05 green:0.48 blue:1.0 alpha:1.0],
        },
    };
    NSDictionary<NSString *, id> *style = styles[bundleIdentifier];
    NSString *symbolName = style[@"symbol"] ?: @"app.fill";
    UIColor *backgroundColor = style[@"color"] ?:
        [UIColor colorWithWhite:0.48 alpha:1.0];
    CGSize size = CGSizeMake(120.0, 120.0);
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        UIBezierPath *background = [UIBezierPath
            bezierPathWithRoundedRect:(CGRect){CGPointZero, size}
                         cornerRadius:size.width * 0.2253];
        [backgroundColor setFill];
        [background fill];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:54.0
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *symbol = [[UIImage systemImageNamed:symbolName
                                    withConfiguration:configuration]
            imageWithTintColor:UIColor.whiteColor
                  renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGRect symbolRect = CGRectMake((size.width - symbol.size.width) * 0.5,
                                       (size.height - symbol.size.height) * 0.5,
                                       symbol.size.width, symbol.size.height);
        [symbol drawInRect:symbolRect];
    }];
}

static BOOL MTSystemPreviewImagesHaveEqualPixels(UIImage *left,
                                                   UIImage *right) {
    CGImageRef leftImage = left.CGImage;
    CGImageRef rightImage = right.CGImage;
    if (leftImage == NULL || rightImage == NULL ||
        CGImageGetWidth(leftImage) != CGImageGetWidth(rightImage) ||
        CGImageGetHeight(leftImage) != CGImageGetHeight(rightImage)) {
        return NO;
    }
    CFDataRef leftData = CGDataProviderCopyData(
        CGImageGetDataProvider(leftImage));
    CFDataRef rightData = CGDataProviderCopyData(
        CGImageGetDataProvider(rightImage));
    BOOL equal = leftData != NULL && rightData != NULL &&
        CFEqual(leftData, rightData);
    if (leftData != NULL) CFRelease(leftData);
    if (rightData != NULL) CFRelease(rightData);
    return equal;
}

NSArray<UIImage *> *MTSystemDefaultPreviewImages(void) {
    static NSArray<UIImage *> *images;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *bundleIdentifiers =
            [MTThemePreviewBundleIdentifiers() subarrayWithRange:NSMakeRange(0, 4)];
        NSMutableArray<UIImage *> *loaded =
            [NSMutableArray arrayWithCapacity:bundleIdentifiers.count];
        SEL selector = NSSelectorFromString(
            @"_applicationIconImageForBundleIdentifier:format:scale:");
        BOOL canReadSystemIcons = [UIImage respondsToSelector:selector];
        UIImage *missingApplicationImage = canReadSystemIcons
            ? [UIImage _applicationIconImageForBundleIdentifier:
                    @"com.hmmzzz.marktheme.missing-system-icon"
                                                              format:2
                                                               scale:UIScreen.mainScreen.scale]
            : nil;
        for (NSString *bundleIdentifier in bundleIdentifiers) {
            UIImage *image = canReadSystemIcons
                ? [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier
                                                              format:2
                                                               scale:UIScreen.mainScreen.scale]
                : nil;
            if (MTSystemPreviewImagesHaveEqualPixels(
                    image, missingApplicationImage)) {
                image = nil;
            }
            [loaded addObject:image ?:
                MTSystemPreviewFallbackImage(bundleIdentifier)];
        }
        images = [loaded copy];
    });
    return images;
}

static UIImage *_Nullable MTCreateBoundedThemePreviewImage(NSData *data) {
    NSDictionary *sourceOptions = @{
        (NSString *)kCGImageSourceShouldCache : @NO,
    };
    CGImageSourceRef source = CGImageSourceCreateWithData(
        (__bridge CFDataRef)data, (__bridge CFDictionaryRef)sourceOptions);
    if (source == NULL || CGImageSourceGetCount(source) != 1) {
        if (source != NULL) CFRelease(source);
        return nil;
    }
    NSDictionary *thumbnailOptions = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize : @320,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
    CFRelease(source);
    if (thumbnail == NULL) return nil;
    UIImage *image = [UIImage imageWithCGImage:thumbnail
                                         scale:UIScreen.mainScreen.scale
                                   orientation:UIImageOrientationUp];
    CGImageRelease(thumbnail);
    return image;
}

static BOOL MTThemePreviewResourceIsPrimaryAppIcon(
    MTThemeResource *resource) {
    MTResourceKey *key = resource.resourceKey;
    return [key.moduleID isEqualToString:@"icons.static"] &&
        [key.surface isEqualToString:@"springboard.home"] &&
        MTStaticIconSourceVariantIsSupported(key.variant);
}

static NSComparisonResult MTCompareThemePreviewResources(
    MTThemeResource *left,
    MTThemeResource *right) {
    if (left.matchRank != right.matchRank) {
        return left.matchRank < right.matchRank
            ? NSOrderedAscending : NSOrderedDescending;
    }
    return [left.relativeAssetPath compare:right.relativeAssetPath
                                     options:NSLiteralSearch];
}

NSArray<UIImage *> *MTLoadThemePreviewImages(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryThemeSummary *themeSummary,
    NSError **error) {
    MTThemeLibraryRevisionSummary *revision = themeSummary.currentRevision;
    MTThemeManifest *manifest = revision.manifest;
    if (themeSummary == nil || revision == nil || manifest == nil) return @[];

    NSMutableArray<MTThemeResource *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *preferredSubjects = [NSMutableSet set];
    for (NSString *subject in MTThemePreviewBundleIdentifiers()) {
        [preferredSubjects addObject:subject];
        NSMutableArray<MTThemeResource *> *subjectResources =
            [NSMutableArray array];
        for (MTThemeResource *resource in manifest.resources) {
            if (MTThemePreviewResourceIsPrimaryAppIcon(resource) &&
                [resource.resourceKey.subject isEqualToString:subject]) {
                [subjectResources addObject:resource];
            }
        }
        [subjectResources sortUsingComparator:
            ^NSComparisonResult(MTThemeResource *left,
                                MTThemeResource *right) {
                return MTCompareThemePreviewResources(left, right);
            }];
        [candidates addObjectsFromArray:subjectResources];
    }
    for (MTThemeResource *resource in manifest.resources) {
        if (MTThemePreviewResourceIsPrimaryAppIcon(resource) &&
            ![preferredSubjects containsObject:resource.resourceKey.subject]) {
            [candidates addObject:resource];
        }
    }
    for (MTThemeResource *resource in manifest.resources) {
        if (!MTThemePreviewResourceIsPrimaryAppIcon(resource)) {
            [candidates addObject:resource];
        }
    }

    NSMutableArray<MTThemeResource *> *selectedResources =
        [NSMutableArray arrayWithCapacity:4];
    NSMutableSet<NSString *> *subjects = [NSMutableSet set];
    for (MTThemeResource *resource in candidates) {
        if (selectedResources.count >= 4) break;
        NSString *subject = resource.resourceKey.subject;
        if ([subjects containsObject:subject]) continue;
        [subjects addObject:subject];
        [selectedResources addObject:resource];
    }

    NSMutableOrderedSet<NSString *> *digests = [NSMutableOrderedSet orderedSet];
    for (MTThemeResource *resource in selectedResources) {
        [digests addObject:resource.contentSHA256];
    }
    if (digests.count == 0) return @[];
    NSDictionary<NSString *, NSData *> *assetData = [libraryStore
        loadPreviewAssetDataForThemeID:themeSummary.themeID
        expectedRevisionIdentifier:revision.revisionIdentifier
        expectedManifest:manifest
        contentSHA256Digests:digests.array
        error:error];
    if (assetData == nil) return @[];

    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:4];
    NSMutableDictionary<NSString *, UIImage *> *imagesByDigest =
        [NSMutableDictionary dictionaryWithCapacity:digests.count];
    for (MTThemeResource *resource in selectedResources) {
        UIImage *image = imagesByDigest[resource.contentSHA256];
        if (image == nil) {
            image = MTCreateBoundedThemePreviewImage(
                assetData[resource.contentSHA256]);
            if (image != nil) {
                imagesByDigest[resource.contentSHA256] = image;
            }
        }
        if (image != nil) [images addObject:image];
    }
    return images;
}
