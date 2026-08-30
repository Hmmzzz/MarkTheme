#import "MTThemePreviewProvider.h"

#import <ImageIO/ImageIO.h>

#import "MTResourceKey.h"
#import "MTImportSession.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

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

static NSArray<NSString *> *MTSystemPreviewApplicationBundlePaths(
    NSString *bundleIdentifier) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @{
            @"com.apple.mobilephone" : @[
                @"/Applications/MobilePhone.app",
                @"/System/Applications/MobilePhone.app",
            ],
            @"com.apple.MobileSMS" : @[
                @"/Applications/MobileSMS.app",
                @"/System/Applications/MobileSMS.app",
            ],
            @"com.apple.mobilesafari" : @[
                @"/Applications/MobileSafari.app",
                @"/System/Applications/MobileSafari.app",
            ],
            @"com.apple.mobilemail" : @[
                @"/Applications/MobileMail.app",
                @"/System/Applications/MobileMail.app",
            ],
        };
    });
    return paths[bundleIdentifier] ?: @[];
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

static void MTSystemPreviewAppendIconNames(
    NSMutableOrderedSet<NSString *> *names,
    NSDictionary<NSString *, id> *iconDictionary) {
    if (![iconDictionary isKindOfClass:NSDictionary.class]) return;
    NSDictionary<NSString *, id> *primary =
        [iconDictionary[@"CFBundlePrimaryIcon"]
            isKindOfClass:NSDictionary.class]
            ? iconDictionary[@"CFBundlePrimaryIcon"] : nil;
    NSString *iconName = [primary[@"CFBundleIconName"]
        isKindOfClass:NSString.class] ? primary[@"CFBundleIconName"] : nil;
    if (iconName.length > 0) [names addObject:iconName];
    NSArray<NSString *> *files = [primary[@"CFBundleIconFiles"]
        isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : nil;
    for (id value in files.reverseObjectEnumerator) {
        if ([value isKindOfClass:NSString.class] &&
            [(NSString *)value length] > 0) {
            [names addObject:value];
        }
    }
}

static BOOL MTSystemPreviewBundleImageIsUsable(UIImage *image) {
    return image != nil && image.size.width > 0.0 &&
        image.size.height > 0.0 &&
        (image.CGImage != NULL || image.CIImage != nil);
}

static UIImage *_Nullable MTSystemPreviewBundleImage(
    NSString *bundleIdentifier) {
    for (NSString *bundlePath in
            MTSystemPreviewApplicationBundlePaths(bundleIdentifier)) {
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        NSDictionary<NSString *, id> *info = bundle.infoDictionary;
        if (bundle == nil ||
            ![info[@"CFBundleIdentifier"] isEqual:bundleIdentifier]) {
            continue;
        }
        NSMutableOrderedSet<NSString *> *names =
            [NSMutableOrderedSet orderedSet];
        MTSystemPreviewAppendIconNames(names, info[@"CFBundleIcons"]);
        MTSystemPreviewAppendIconNames(names, info[@"CFBundleIcons~iphone"]);
        NSString *rootIconName = [info[@"CFBundleIconName"]
            isKindOfClass:NSString.class] ? info[@"CFBundleIconName"] : nil;
        if (rootIconName.length > 0) [names addObject:rootIconName];
        NSArray<NSString *> *rootFiles = [info[@"CFBundleIconFiles"]
            isKindOfClass:NSArray.class] ? info[@"CFBundleIconFiles"] : nil;
        for (id value in rootFiles.reverseObjectEnumerator) {
            if ([value isKindOfClass:NSString.class] &&
                [(NSString *)value length] > 0) {
                [names addObject:value];
            }
        }
        [names addObject:@"AppIcon60x60"];
        [names addObject:@"AppIcon"];

        for (NSString *name in names) {
            // UIImage resolves this name inside the system App's own
            // Assets.car. It does not ask IconServices to generate the
            // currently selected application appearance.
            UIImage *image = [UIImage imageNamed:name
                                        inBundle:bundle
                   compatibleWithTraitCollection:nil];
            if (MTSystemPreviewBundleImageIsUsable(image)) {
                return [image imageWithRenderingMode:
                    UIImageRenderingModeAlwaysOriginal];
            }
            NSString *baseName = name.stringByDeletingPathExtension;
            for (NSString *suffix in @[@"@3x", @"@2x", @""]) {
                NSString *resource = [baseName
                    stringByAppendingString:suffix];
                NSString *path = [bundle pathForResource:resource
                                                  ofType:@"png"];
                image = path.length == 0 ? nil :
                    [UIImage imageWithContentsOfFile:path];
                if (MTSystemPreviewBundleImageIsUsable(image)) {
                    return [image imageWithRenderingMode:
                        UIImageRenderingModeAlwaysOriginal];
                }
            }
        }
    }
    return nil;
}

NSArray<UIImage *> *MTSystemDefaultPreviewImages(void) {
    static NSArray<UIImage *> *images;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *bundleIdentifiers =
            [MTThemePreviewBundleIdentifiers() subarrayWithRange:NSMakeRange(0, 4)];
        NSMutableArray<UIImage *> *loaded =
            [NSMutableArray arrayWithCapacity:bundleIdentifiers.count];
        for (NSString *bundleIdentifier in bundleIdentifiers) {
            UIImage *image = MTSystemPreviewBundleImage(bundleIdentifier);
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
    return MTLoadThemePreviewImagesWithCancellation(
        libraryStore, themeSummary, nil, error);
}

NSArray<UIImage *> *MTLoadThemePreviewImagesWithCancellation(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryThemeSummary *themeSummary,
    MTImportCancellationToken *cancellationToken,
    NSError **error) {
    if (cancellationToken.isCancelled) return @[];
    MTThemeLibraryRevisionSummary *revision = themeSummary.currentRevision;
    MTThemeManifest *manifest = revision.manifest;
    if (themeSummary == nil || revision == nil || manifest == nil) return @[];

    NSArray<NSString *> *preferredSubjectOrder =
        MTThemePreviewBundleIdentifiers();
    NSSet<NSString *> *preferredSubjects =
        [NSSet setWithArray:preferredSubjectOrder];
    NSMutableDictionary<NSString *, NSMutableArray<MTThemeResource *> *> *
        preferredResources = [NSMutableDictionary
            dictionaryWithCapacity:preferredSubjects.count];
    // One pass groups only preferred app icons. The old implementation
    // rescanned the entire manifest once per preferred bundle identifier.
    for (MTThemeResource *resource in manifest.resources) {
        if (cancellationToken.isCancelled) return @[];
        NSString *subject = resource.resourceKey.subject;
        if (!MTThemePreviewResourceIsPrimaryAppIcon(resource) ||
            ![preferredSubjects containsObject:subject]) {
            continue;
        }
        NSMutableArray<MTThemeResource *> *resources =
            preferredResources[subject];
        if (resources == nil) {
            resources = [NSMutableArray array];
            preferredResources[subject] = resources;
        }
        [resources addObject:resource];
    }

    NSMutableArray<MTThemeResource *> *selectedResources =
        [NSMutableArray arrayWithCapacity:4];
    NSMutableSet<NSString *> *subjects = [NSMutableSet set];
    for (NSString *subject in preferredSubjectOrder) {
        if (cancellationToken.isCancelled) return @[];
        NSMutableArray<MTThemeResource *> *resources =
            preferredResources[subject];
        [resources sortUsingComparator:
            ^NSComparisonResult(MTThemeResource *left,
                                MTThemeResource *right) {
                return MTCompareThemePreviewResources(left, right);
            }];
        MTThemeResource *resource = resources.firstObject;
        if (resource == nil || [subjects containsObject:subject]) continue;
        [subjects addObject:subject];
        [selectedResources addObject:resource];
        if (selectedResources.count >= 4) break;
    }
    // Most themes satisfy the four-image preview from preferred icons, so the
    // fallback scans are paid only when they can contribute an image.
    if (selectedResources.count < 4) {
        for (MTThemeResource *resource in manifest.resources) {
            if (cancellationToken.isCancelled) return @[];
            NSString *subject = resource.resourceKey.subject;
            if (!MTThemePreviewResourceIsPrimaryAppIcon(resource) ||
                [preferredSubjects containsObject:subject] ||
                [subjects containsObject:subject]) {
                continue;
            }
            [subjects addObject:subject];
            [selectedResources addObject:resource];
            if (selectedResources.count >= 4) break;
        }
    }
    if (selectedResources.count < 4) {
        for (MTThemeResource *resource in manifest.resources) {
            if (cancellationToken.isCancelled) return @[];
            NSString *subject = resource.resourceKey.subject;
            if (MTThemePreviewResourceIsPrimaryAppIcon(resource) ||
                [subjects containsObject:subject]) {
                continue;
            }
            [subjects addObject:subject];
            [selectedResources addObject:resource];
            if (selectedResources.count >= 4) break;
        }
    }

    NSMutableOrderedSet<NSString *> *digests = [NSMutableOrderedSet orderedSet];
    for (MTThemeResource *resource in selectedResources) {
        if (cancellationToken.isCancelled) return @[];
        [digests addObject:resource.contentSHA256];
    }
    if (digests.count == 0) return @[];
    if (cancellationToken.isCancelled) return @[];
    NSDictionary<NSString *, NSData *> *assetData = [libraryStore
        loadPreviewAssetDataForThemeID:themeSummary.themeID
        expectedRevisionIdentifier:revision.revisionIdentifier
        expectedManifest:manifest
        contentSHA256Digests:digests.array
        cancellationToken:cancellationToken
        error:error];
    if (assetData == nil || cancellationToken.isCancelled) return @[];

    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:4];
    NSMutableDictionary<NSString *, UIImage *> *imagesByDigest =
        [NSMutableDictionary dictionaryWithCapacity:digests.count];
    for (MTThemeResource *resource in selectedResources) {
        if (cancellationToken.isCancelled) return @[];
        UIImage *image = imagesByDigest[resource.contentSHA256];
        if (image == nil) {
            image = MTCreateBoundedThemePreviewImage(
                assetData[resource.contentSHA256]);
            if (image != nil) {
                imagesByDigest[resource.contentSHA256] = image;
            }
        }
        if (cancellationToken.isCancelled) return @[];
        if (image != nil) [images addObject:image];
    }
    return images;
}
