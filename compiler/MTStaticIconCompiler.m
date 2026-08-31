#import "MTStaticIconCompiler.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTCanonicalJSON.h"
#import "MTBadgeConfiguration.h"
#import "MTBadgesModule.h"
#import "MTCalendarIconConfiguration.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTDialerModule.h"
#import "MTFolderIconContract.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconMaskContract.h"
#import "MTIconOverlayContract.h"
#import "MTIconShadowConfiguration.h"
#import "MTIconShadowContract.h"
#import "MTIconShadowsModule.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTImportSession.h"
#import "MTResourceKey.h"
#import "MTSafeImageDecoder.h"
#import "MTSafeImageInspector.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeLibraryStoreInternal.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"
#import "MTThemeCapabilityReport.h"
#import "MTStatusBarContract.h"
#import "MTStatusBarModule.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeComponentCatalog.h"
#import "MTUIResourcesModule.h"

NSString *const MTStaticIconCompilerErrorDomain =
    @"com.hmmzzz.marktheme.static-icon-compiler";

static BOOL MTStaticIconCompilerSetError(
    NSError **error,
    MTStaticIconCompilerErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
            description
            forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTStaticIconCompilerErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTStaticIconCompilerCancelled(
    MTImportCancellationToken *_Nullable token,
    NSError **error) {
    if (!token.isCancelled) return NO;
    MTStaticIconCompilerSetError(error, MTStaticIconCompilerErrorCancelled,
                                 @"Static icon compilation was cancelled.", nil);
    return YES;
}

static BOOL MTStaticIconUnsignedByteCount(NSNumber *number,
                                          uint64_t *output) {
    if (![number isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
        return NO;
    }
    const char *type = number.objCType;
    if (type == NULL || type[0] == 'f' || type[0] == 'd') return NO;
    NSString *value = number.stringValue;
    if (value.length == 0 || [value characterAtIndex:0] == '-') return NO;
    uint64_t parsed = 0;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
        uint64_t digit = (uint64_t)(character - '0');
        if (parsed > (UINT64_MAX - digit) / 10) return NO;
        parsed = parsed * 10 + digit;
    }
    if (parsed == 0) return NO;
    *output = parsed;
    return YES;
}

static BOOL MTStaticIconStatusesMatch(const struct stat *left,
                                      const struct stat *right) {
    return left->st_dev == right->st_dev &&
        left->st_ino == right->st_ino &&
        left->st_mode == right->st_mode &&
        left->st_uid == right->st_uid &&
        left->st_gid == right->st_gid &&
        left->st_nlink == right->st_nlink &&
        left->st_size == right->st_size &&
        left->st_mtimespec.tv_sec == right->st_mtimespec.tv_sec &&
        left->st_mtimespec.tv_nsec == right->st_mtimespec.tv_nsec &&
        left->st_ctimespec.tv_sec == right->st_ctimespec.tv_sec &&
        left->st_ctimespec.tv_nsec == right->st_ctimespec.tv_nsec;
}

static BOOL MTStaticIconValidateAssetMetadata(const struct stat *status,
                                              uint64_t expectedBytes) {
    mode_t unsafe = S_IXUSR | S_IXGRP | S_IXOTH | S_IWGRP | S_IWOTH;
    return S_ISREG(status->st_mode) && status->st_uid == geteuid() &&
        status->st_nlink == 1 && (status->st_mode & unsafe) == 0 &&
        status->st_size >= 0 && (uint64_t)status->st_size == expectedBytes;
}

static BOOL MTStaticIconValidateAsset(
    NSURL *assetURL,
    NSString *expectedDigest,
    uint64_t expectedBytes,
    MTSafeImageDecoder *decoder,
    MTImportCancellationToken *_Nullable token,
    NSError **error) {
    if (![assetURL isKindOfClass:NSURL.class] || !assetURL.isFileURL ||
        assetURL.path.length == 0) {
        return MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorIntegrity,
            @"Library asset URL is invalid.", nil);
    }
    if (MTStaticIconCompilerCancelled(token, error)) return NO;
    int descriptor = open(assetURL.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorIntegrity,
            @"Library asset could not be opened without following links.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    }
    struct stat before;
    struct stat after;
    BOOL valid = fstat(descriptor, &before) == 0 &&
        MTStaticIconValidateAssetMetadata(&before, expectedBytes);
    NSError *digestError = nil;
    uint64_t bytesRead = 0;
    NSString *digest = valid
        ? MTSHA256HexDigestForFileDescriptor(descriptor, expectedBytes,
                                             &bytesRead, &digestError)
        : nil;
    valid = valid && digest != nil && bytesRead == expectedBytes &&
        [digest isEqualToString:expectedDigest] &&
        fstat(descriptor, &after) == 0 &&
        MTStaticIconStatusesMatch(&before, &after);
    int closeResult = close(descriptor);
    if (!valid || closeResult != 0) {
        return MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorIntegrity,
            @"Library asset identity, metadata, size, or digest is invalid.",
            digestError);
    }
    if (MTStaticIconCompilerCancelled(token, error)) return NO;

    NSError *decodeError = nil;
    MTSafeImageDecodeResult *decoded = [decoder
        decodeOwnedPNGFileAtURL:assetURL
        thumbnailMaximumDimension:1
        cancellationToken:token
        error:&decodeError];
    if (decoded == nil ||
        decoded.inspection.encodedByteCount != expectedBytes) {
        MTStaticIconCompilerErrorCode code = token.isCancelled
            ? MTStaticIconCompilerErrorCancelled
            : MTStaticIconCompilerErrorImageValidation;
        return MTStaticIconCompilerSetError(error, code,
            code == MTStaticIconCompilerErrorCancelled
                ? @"Static icon compilation was cancelled."
                : @"Library static icon failed strict compiler validation.",
            decodeError);
    }
    return YES;
}

static BOOL MTStaticIconResourceIsSupported(MTThemeResource *resource) {
    MTResourceKey *key = resource.resourceKey;
    BOOL supportedTrait = [key.trait isEqualToString:@"any"] ||
        [key.trait isEqualToString:@"iphone"] ||
        [key.trait isEqualToString:@"ipad"];
    BOOL staticIcon = [key.moduleID isEqualToString:@"icons.static"] &&
        [key.surface isEqualToString:@"springboard.home"] &&
        MTStaticIconSourceVariantIsSupported(key.variant) && key.scale <= 3 &&
        supportedTrait;
    BOOL clockComponent =
        [key.moduleID isEqualToString:MTClockIconsModuleID] &&
        [key.surface isEqualToString:@"springboard.home"] &&
        [key.subject isEqualToString:MTClockIconTargetBundleIdentifier] &&
        [MTClockIconResourceVariants() containsObject:key.variant] &&
        key.scale == 0 && [key.trait isEqualToString:@"any"];
    BOOL preferencesIcon =
        [key.moduleID isEqualToString:MTUIResourcesModuleID] &&
        [key.surface isEqualToString:@"preferences.icon"] &&
        MTStaticIconSourceVariantIsSupported(key.variant) && key.scale <= 3 &&
        supportedTrait;
    BOOL shareActivity =
        [key.moduleID isEqualToString:MTUIResourcesModuleID] &&
        [key.surface isEqualToString:@"share.activity"] &&
        MTStaticIconSourceVariantIsSupported(key.variant) && key.scale <= 3 &&
        supportedTrait;
    BOOL iconMask =
        [key.moduleID isEqualToString:MTIconMaskModuleID] &&
        [key.surface isEqualToString:MTIconMaskSurface] &&
        [key.subject isEqualToString:MTIconMaskGlobalSubject] &&
        [MTIconMaskResourceVariants() containsObject:key.variant] &&
        key.scale == 0 && [key.trait isEqualToString:@"any"];
    BOOL iconOverlay =
        [key.moduleID isEqualToString:MTIconOverlayModuleID] &&
        [key.surface isEqualToString:MTIconOverlaySurface] &&
        [key.subject isEqualToString:MTIconOverlayGlobalSubject] &&
        [MTIconOverlayResourceVariants() containsObject:key.variant] &&
        key.scale == 0 && [key.trait isEqualToString:@"any"];
    BOOL folder =
        [key.moduleID isEqualToString:MTFolderIconsModuleID] &&
        [key.surface isEqualToString:MTFolderIconSurface] &&
        [key.subject isEqualToString:MTFolderIconGlobalSubject] &&
        [MTFolderIconResourceVariants() containsObject:key.variant] &&
        key.scale == 0 && [key.trait isEqualToString:@"any"];
    BOOL badge = [key.moduleID isEqualToString:MTBadgesModuleID] &&
        [key.surface isEqualToString:MTBadgeSurface] &&
        [key.subject isEqualToString:MTBadgeGlobalSubject] &&
        key.scale <= 3 && MTBadgeResourceTraitIsSupported(key.trait);
    BOOL dialer = [key.moduleID isEqualToString:MTDialerModuleID] &&
        [key.surface isEqualToString:MTDialerSurface] &&
        [key.variant isEqualToString:@"primary"] && key.scale <= 3 &&
        supportedTrait;
    BOOL statusBar = [key.moduleID isEqualToString:MTStatusBarModuleID] &&
        [key.surface isEqualToString:MTStatusBarSurface] &&
        MTStatusBarResourceSubjectIsSupported(key.subject) &&
        [key.variant isEqualToString:@"primary"] && key.scale <= 3 &&
        supportedTrait;
    BOOL iconShadow =
        [key.moduleID isEqualToString:MTIconShadowsModuleID] &&
        [key.surface isEqualToString:MTIconShadowSurface] &&
        MTIconShadowSubjectIsSupported(key.subject) &&
        key.scale <= 3 && MTIconShadowDeviceTraitIsSupported(key.trait);
    return staticIcon || clockComponent || preferencesIcon || shareActivity ||
        iconMask || iconOverlay || folder || badge || dialer || statusBar ||
        iconShadow;
}

static NSArray<NSString *> *MTStaticIconMixFeatureIdentifiers(void) {
    return MTThemeMixableFeatureIdentifiers();
}

static BOOL MTStaticIconValidateMixLibraryRevision(
    MTThemeLibraryRevision *revision,
    NSString *expectedThemeIdentifier,
    NSString *expectedRevisionIdentifier,
    MTImportCancellationToken *cancellationToken,
    NSError **error) {
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return NO;
    if (![revision isKindOfClass:MTThemeLibraryRevision.class] ||
        ![revision.manifest.themeID isEqualToString:expectedThemeIdentifier] ||
        ![revision.revisionIdentifier
            isEqualToString:expectedRevisionIdentifier]) {
        return MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"A theme mix source does not match its requested Library identity.",
            nil);
    }
    NSError *manifestError = nil;
    NSString *manifestDigest = [revision.manifest
        contentDigestWithError:&manifestError];
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return NO;
    NSString *expectedRevision = manifestDigest == nil ? nil
        : [@"r1-" stringByAppendingString:manifestDigest];
    NSSet<NSString *> *URLDigests = [NSSet setWithArray:
        revision.assetURLsByContentSHA256.allKeys];
    NSSet<NSString *> *byteDigests = [NSSet setWithArray:
        revision.assetByteCountsByContentSHA256.allKeys];
    NSMutableSet<NSString *> *resourceDigests = [NSMutableSet set];
    for (MTThemeResource *resource in revision.manifest.resources) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return NO;
        [resourceDigests addObject:resource.contentSHA256];
    }
    if (manifestDigest == nil ||
        ![manifestDigest isEqualToString:revision.manifestDigest] ||
        ![revision.revisionIdentifier isEqualToString:expectedRevision] ||
        revision.assetCount != URLDigests.count ||
        revision.assetCount != byteDigests.count ||
        ![URLDigests isEqualToSet:byteDigests] ||
        ![URLDigests isEqualToSet:resourceDigests]) {
        return MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"A theme mix source has inconsistent Manifest or asset identity.",
            manifestError);
    }
    return YES;
}

static NSArray<MTThemeResource *> *_Nullable
MTStaticIconResourcesForMixSource(
    MTThemeLibraryRevision *revision,
    NSDictionary<NSString *, id> *selectionDictionary,
    MTImportCancellationToken *cancellationToken,
    NSError **error) {
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
    NSError *catalogError = nil;
    MTThemeComponentCatalog *catalog = [MTThemeComponentCatalog
        catalogForManifest:revision.manifest error:&catalogError];
    MTThemeComponentSelection *selection = catalog == nil ? nil :
        [MTThemeComponentSelection selectionForCatalog:catalog
            canonicalDictionary:selectionDictionary error:&catalogError];
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
    if (catalog == nil || selection == nil) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"A theme mix source component selection is stale or invalid.",
            catalogError);
        return nil;
    }
    NSMutableArray<MTThemeResource *> *resources =
        [NSMutableArray arrayWithCapacity:revision.manifest.resources.count];
    for (MTThemeResource *resource in revision.manifest.resources) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
        MTThemeVariantGroup *variantGroup = [catalog
            variantGroupForModuleIdentifier:resource.resourceKey.moduleID];
        BOOL selected = variantGroup != nil
            ? [resource.resourceKey.variant isEqualToString:[selection
                selectedVariantForGroup:variantGroup.groupIdentifier]]
            : [selection isComponentEnabled:
                [catalog componentIdentifierForResource:resource]];
        if (selected) [resources addObject:resource];
    }
    return [resources copy];
}

static BOOL MTStaticIconResourceMatchesMixFeature(
    MTThemeResource *resource,
    NSString *featureIdentifier) {
    MTResourceKey *key = resource.resourceKey;
    if ([featureIdentifier isEqualToString:MTThemeFeatureAppIcons]) {
        return [key.moduleID isEqualToString:@"icons.static"] &&
            [key.surface isEqualToString:@"springboard.home"];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureSettingsIcons]) {
        return [key.moduleID isEqualToString:MTUIResourcesModuleID] &&
            [key.surface isEqualToString:@"preferences.icon"];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureShareIcons]) {
        return [key.moduleID isEqualToString:MTUIResourcesModuleID] &&
            [key.surface isEqualToString:@"share.activity"];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureFolders]) {
        return [key.moduleID isEqualToString:MTFolderIconsModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureDynamicClock]) {
        return [key.moduleID isEqualToString:MTClockIconsModuleID] ||
            ([key.moduleID isEqualToString:@"icons.static"] &&
             [key.surface isEqualToString:@"springboard.home"] &&
             [key.subject isEqualToString:@"com.apple.mobiletimer"]);
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureDynamicCalendar]) {
        return [key.moduleID isEqualToString:@"icons.static"] &&
            [key.surface isEqualToString:@"springboard.home"] &&
            [key.subject isEqualToString:@"com.apple.mobilecal"];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureIconMask]) {
        return [key.moduleID isEqualToString:MTIconMaskModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureIconOverlay]) {
        return [key.moduleID isEqualToString:MTIconOverlayModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureBadges]) {
        return [key.moduleID isEqualToString:MTBadgesModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureStatusBar]) {
        return [key.moduleID isEqualToString:MTStatusBarModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureIconShadows]) {
        return [key.moduleID isEqualToString:MTIconShadowsModuleID];
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureDialer]) {
        return [key.moduleID isEqualToString:MTDialerModuleID];
    }
    return NO;
}

static BOOL MTStaticIconEvaluateMixSourceFeature(
    NSString *featureIdentifier,
    MTThemeManifest *manifest,
    NSArray<MTThemeResource *> *selectedResources,
    MTImportCancellationToken *cancellationToken,
    BOOL *hasFeature,
    NSError **error) {
    if (hasFeature == NULL ||
        MTStaticIconCompilerCancelled(cancellationToken, error)) {
        return NO;
    }
    *hasFeature = NO;
    BOOL hasMatchingResource = NO;
    BOOL hasClockComponent = NO;
    BOOL hasClockBackground = NO;
    BOOL hasCalendarBackground = NO;
    BOOL hasFolderBackground = NO;
    for (MTThemeResource *resource in selectedResources) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return NO;
        MTResourceKey *key = resource.resourceKey;
        hasMatchingResource = hasMatchingResource ||
            MTStaticIconResourceMatchesMixFeature(resource, featureIdentifier);
        hasClockComponent = hasClockComponent ||
            ([key.moduleID isEqualToString:MTClockIconsModuleID] &&
             [key.variant isEqualToString:@"background"]);
        hasClockBackground = hasClockBackground ||
            ([key.moduleID isEqualToString:@"icons.static"] &&
             [key.surface isEqualToString:@"springboard.home"] &&
             [key.subject isEqualToString:@"com.apple.mobiletimer"]);
        hasCalendarBackground = hasCalendarBackground ||
            ([key.moduleID isEqualToString:@"icons.static"] &&
             [key.surface isEqualToString:@"springboard.home"] &&
             [key.subject isEqualToString:@"com.apple.mobilecal"]);
        hasFolderBackground = hasFolderBackground ||
            ([key.moduleID isEqualToString:MTFolderIconsModuleID] &&
             [key.variant isEqualToString:MTFolderIconVariantBackground]);
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureDynamicCalendar]) {
        *hasFeature = hasCalendarBackground &&
            manifest.moduleConfigurations[MTCalendarIconsModuleID] != nil &&
            [manifest.capabilities containsObject:MTCalendarIconsModuleID];
        return YES;
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureDynamicClock]) {
        *hasFeature = hasClockComponent && hasClockBackground;
        return YES;
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureFolders]) {
        *hasFeature = hasFolderBackground;
        return YES;
    }
    if ([featureIdentifier isEqualToString:MTThemeFeatureIconMask]) {
        *hasFeature = manifest.moduleConfigurations[MTIconMaskModuleID] != nil &&
            [manifest.capabilities containsObject:MTIconMaskModuleID];
        return YES;
    }
    *hasFeature = hasMatchingResource;
    return YES;
}

// Runtime has one static-icon configuration per Generation. Preserve one
// matching layer per ready App-icon source so exact resources, aliases, and
// fuzzy subjects all share the same source-priority boundary. Aggregate hint
// counts remain bounded by the existing configuration limits; earlier layers
// consume the budget first.
static NSDictionary<NSString *, id> *_Nullable
MTStaticIconMergedConfigurationForRevisions(
    NSArray<MTThemeLibraryRevision *> *revisions) {
    if (revisions.count == 0 ||
        revisions.count > MTStaticIconMaximumMatchingLayerCount) {
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *matchingLayers =
        [NSMutableArray arrayWithCapacity:revisions.count];
    NSUInteger remainingFuzzy =
        MTStaticIconMaximumFuzzyBundleIdentifierCount;
    NSUInteger remainingAliases = MTStaticIconMaximumBundleAliasCount;
    for (MTThemeLibraryRevision *revision in revisions) {
        NSDictionary *dictionary =
            revision.manifest.moduleConfigurations[@"icons.static"];
        MTStaticIconConfiguration *configuration = dictionary == nil ? nil :
            [[MTStaticIconConfiguration alloc]
                initWithDictionary:dictionary error:NULL];
        NSMutableArray<NSString *> *fuzzyIdentifiers =
            [NSMutableArray array];
        for (NSString *identifier in configuration.fuzzyBundleIdentifiers) {
            if (remainingFuzzy == 0) break;
            [fuzzyIdentifiers addObject:identifier];
            remainingFuzzy--;
        }
        NSMutableDictionary<NSString *, NSString *> *aliases =
            [NSMutableDictionary dictionary];
        NSArray<NSString *> *sortedAliases = [configuration.bundleAliases.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *alias in sortedAliases) {
            if (remainingAliases == 0) break;
            aliases[alias] = configuration.bundleAliases[alias];
            remainingAliases--;
        }
        [matchingLayers addObject:@{
            @"bundleAliases" : aliases,
            @"fuzzyBundleIdentifiers" : fuzzyIdentifiers,
        }];
    }
    MTStaticIconConfiguration *configuration = [MTStaticIconConfiguration
        configurationWithOrderedMatchingLayers:matchingLayers];
    return configuration.canonicalDictionary;
}

static MTThemeResource *_Nullable
MTStaticIconResourceForMatchingLayer(MTThemeResource *resource,
                                     NSUInteger layerIndex,
                                     NSError **error) {
    MTResourceKey *sourceKey = resource.resourceKey;
    NSString *variant = MTStaticIconSourceVariantForMatchingLayer(
        sourceKey.variant, layerIndex);
    MTResourceKey *layeredKey = variant == nil ? nil : [[MTResourceKey alloc]
        initWithModuleID:sourceKey.moduleID
        surface:sourceKey.surface
        subject:sourceKey.subject
        variant:variant
        scale:sourceKey.scale
        trait:sourceKey.trait
        error:error];
    if (layeredKey == nil) return nil;
    return [[MTThemeResource alloc]
        initWithResourceKey:layeredKey
        relativeAssetPath:resource.relativeAssetPath
        contentSHA256:resource.contentSHA256
        sourceFormat:resource.sourceFormat
        matchRank:resource.matchRank
        error:error];
}

@interface MTCompiledGeneration ()

@property(nonatomic, strong, readwrite) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readwrite) MTGenerationIndex *index;
@property(nonatomic, copy, readwrite)
    NSDictionary<NSString *, NSURL *> *sourceAssetURLsByContentSHA256;

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
    (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest;

@end

@implementation MTCompiledGeneration

- (instancetype)initWithDescriptor:(MTGenerationDescriptor *)descriptor
                              index:(MTGenerationIndex *)index
            sourceAssetURLsByDigest:
                (NSDictionary<NSString *, NSURL *> *)sourceAssetURLsByDigest {
    self = [super init];
    if (self == nil) return nil;
    _descriptor = descriptor;
    _index = index;
    _sourceAssetURLsByContentSHA256 = [sourceAssetURLsByDigest copy];
    return self;
}

@end

@interface MTStaticIconCompiler ()

@property(nonatomic, strong) MTSafeImageDecoder *decoder;

- (instancetype)initWithDecoder:(MTSafeImageDecoder *)decoder;

@end

@implementation MTStaticIconCompiler

+ (instancetype)defaultCompiler {
    return [[self alloc] initWithDecoder:MTSafeImageDecoder.defaultDecoder];
}

- (instancetype)initWithDecoder:(MTSafeImageDecoder *)decoder {
    self = [super init];
    if (self == nil) return nil;
    _decoder = decoder;
    return self;
}

- (MTCompiledGeneration *)compileLibraryRevision:
    (MTThemeLibraryRevision *)revision
                                      cancellationToken:
    (MTImportCancellationToken *)cancellationToken
                                                   error:(NSError **)error {
    return [self compileLibraryRevision:revision
                     componentSelection:nil
                      cancellationToken:cancellationToken
                                   error:error];
}

- (MTCompiledGeneration *)compileLibraryRevision:
    (MTThemeLibraryRevision *)revision
                                     componentSelection:
                                         (MTThemeComponentSelection *)componentSelection
                                       cancellationToken:
                                           (MTImportCancellationToken *)cancellationToken
                                                error:(NSError **)error {
    if (![revision isKindOfClass:MTThemeLibraryRevision.class] ||
        revision.manifest == nil || revision.revisionIdentifier.length == 0 ||
        revision.manifestDigest.length == 0) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Static icon compiler requires a full Library revision.", nil);
        return nil;
    }
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
    NSError *manifestError = nil;
    NSString *manifestDigest = [revision.manifest
        contentDigestWithError:&manifestError];
    NSString *expectedRevisionID = manifestDigest == nil
        ? nil
        : [@"r1-" stringByAppendingString:manifestDigest];
    if (manifestDigest == nil ||
        ![manifestDigest isEqualToString:revision.manifestDigest] ||
        ![revision.revisionIdentifier isEqualToString:expectedRevisionID] ||
        revision.assetCount !=
            revision.assetURLsByContentSHA256.count ||
        revision.assetCount !=
            revision.assetByteCountsByContentSHA256.count ||
        ![[NSSet setWithArray:revision.assetURLsByContentSHA256.allKeys]
            isEqualToSet:[NSSet setWithArray:
                revision.assetByteCountsByContentSHA256.allKeys]]) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Library revision identity or asset maps are inconsistent.",
            manifestError);
        return nil;
    }
    NSSet<NSString *> *revisionDigests = [NSSet setWithArray:
        revision.assetURLsByContentSHA256.allKeys];
    NSMutableSet<NSString *> *manifestResourceDigests = [NSMutableSet set];
    for (MTThemeResource *resource in revision.manifest.resources) {
        [manifestResourceDigests addObject:resource.contentSHA256];
    }
    if (![manifestResourceDigests isEqualToSet:revisionDigests]) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Library assets are not the exact immutable Manifest asset set.",
            nil);
        return nil;
    }

    NSError *catalogError = nil;
    MTThemeComponentCatalog *componentCatalog =
        [MTThemeComponentCatalog catalogForManifest:revision.manifest
                                               error:&catalogError];
    MTThemeComponentSelection *effectiveSelection = componentSelection ?:
        componentCatalog.defaultSelection;
    MTThemeComponentSelection *validatedSelection = componentCatalog == nil
        ? nil : [MTThemeComponentSelection
            selectionForCatalog:componentCatalog
            canonicalDictionary:effectiveSelection.canonicalDictionary
            error:&catalogError];
    if (componentCatalog == nil || validatedSelection == nil) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Theme component selection does not match this Library revision.",
            catalogError);
        return nil;
    }
    effectiveSelection = validatedSelection;

    NSMutableArray<MTThemeResource *> *selectedResources =
        [NSMutableArray arrayWithCapacity:revision.manifest.resources.count];
    NSUInteger originalIconMaskResourceCount = 0;
    NSUInteger selectedIconMaskResourceCount = 0;
    BOOL selectedCalendarBackground = NO;
    BOOL selectedClockBackground = NO;
    BOOL selectedFolderBackground = NO;
    for (MTThemeResource *resource in revision.manifest.resources) {
        MTResourceKey *key = resource.resourceKey;
        if ([key.moduleID isEqualToString:MTIconMaskModuleID]) {
            originalIconMaskResourceCount += 1;
        }
        MTThemeVariantGroup *variantGroup = [componentCatalog
            variantGroupForModuleIdentifier:key.moduleID];
        BOOL selected = variantGroup != nil
            ? [key.variant isEqualToString:[effectiveSelection
                selectedVariantForGroup:variantGroup.groupIdentifier]]
            : [effectiveSelection isComponentEnabled:
                [componentCatalog componentIdentifierForResource:resource]];
        if (!selected) continue;
        [selectedResources addObject:resource];
        if ([key.moduleID isEqualToString:MTIconMaskModuleID]) {
            selectedIconMaskResourceCount += 1;
        }
        if ([key.moduleID isEqualToString:@"icons.static"] &&
            [key.surface isEqualToString:@"springboard.home"] &&
            [key.subject isEqualToString:@"com.apple.mobilecal"] &&
            MTStaticIconSourceVariantIsSupported(key.variant)) {
            selectedCalendarBackground = YES;
        }
        if ([key.moduleID isEqualToString:@"icons.static"] &&
            [key.surface isEqualToString:@"springboard.home"] &&
            [key.subject isEqualToString:@"com.apple.mobiletimer"] &&
            MTStaticIconSourceVariantIsSupported(key.variant)) {
            selectedClockBackground = YES;
        }
        if ([key.moduleID isEqualToString:MTFolderIconsModuleID] &&
            [key.variant isEqualToString:MTFolderIconVariantBackground]) {
            selectedFolderBackground = YES;
        }
    }
    if (!selectedClockBackground) {
        NSIndexSet *orphanedClockResources = [selectedResources
            indexesOfObjectsPassingTest:^BOOL(MTThemeResource *resource,
                                              NSUInteger index,
                                              BOOL *stop) {
            (void)index;
            (void)stop;
            return [resource.resourceKey.moduleID
                isEqualToString:MTClockIconsModuleID];
        }];
        [selectedResources removeObjectsAtIndexes:orphanedClockResources];
    }
    if (!selectedFolderBackground) {
        NSIndexSet *orphanedFolderResources = [selectedResources
            indexesOfObjectsPassingTest:^BOOL(MTThemeResource *resource,
                                              NSUInteger index,
                                              BOOL *stop) {
            (void)index;
            (void)stop;
            return [resource.resourceKey.moduleID
                isEqualToString:MTFolderIconsModuleID];
        }];
        [selectedResources removeObjectsAtIndexes:orphanedFolderResources];
    }

    NSSet<NSString *> *manifestCapabilities =
        [NSSet setWithArray:revision.manifest.capabilities];
    NSMutableSet<NSString *> *mutableCapabilities = [NSMutableSet set];
    for (MTThemeResource *resource in selectedResources) {
        [mutableCapabilities addObject:resource.resourceKey.moduleID];
    }
    if ([manifestCapabilities containsObject:MTCalendarIconsModuleID] &&
        revision.manifest.moduleConfigurations[MTCalendarIconsModuleID] != nil &&
        selectedCalendarBackground) {
        [mutableCapabilities addObject:MTCalendarIconsModuleID];
    }
    if ([manifestCapabilities containsObject:MTIconMaskModuleID] &&
        revision.manifest.moduleConfigurations[MTIconMaskModuleID] != nil &&
        (originalIconMaskResourceCount == 0 ||
         selectedIconMaskResourceCount > 0)) {
        [mutableCapabilities addObject:MTIconMaskModuleID];
    }
    NSSet<NSString *> *capabilities = [mutableCapabilities copy];
    NSMutableSet<NSString *> *unsupportedCapabilities =
        [capabilities mutableCopy];
    [unsupportedCapabilities minusSet:[NSSet setWithObjects:
        @"icons.static", MTCalendarIconsModuleID, MTClockIconsModuleID,
        MTUIResourcesModuleID, MTIconMaskModuleID, MTIconOverlayModuleID,
        MTFolderIconsModuleID,
        MTBadgesModuleID, MTDialerModuleID, MTIconShadowsModuleID,
        MTStatusBarModuleID,
        nil]];
    BOOL hasStaticIcons = [capabilities containsObject:@"icons.static"];
    BOOL hasCalendar = [capabilities containsObject:MTCalendarIconsModuleID];
    BOOL hasClock = [capabilities containsObject:MTClockIconsModuleID];
    BOOL hasUIResources =
        [capabilities containsObject:MTUIResourcesModuleID];
    BOOL hasIconMask = [capabilities containsObject:MTIconMaskModuleID];
    // The overlay activates on authored artwork alone, so it carries no module
    // configuration and only has to count as real themed content.
    BOOL hasIconOverlay =
        [capabilities containsObject:MTIconOverlayModuleID];
    BOOL hasFolders = [capabilities containsObject:MTFolderIconsModuleID];
    BOOL hasBadges = [capabilities containsObject:MTBadgesModuleID];
    BOOL hasDialer = [capabilities containsObject:MTDialerModuleID];
    BOOL hasIconShadows =
        [capabilities containsObject:MTIconShadowsModuleID];
    BOOL hasStatusBar = [capabilities containsObject:MTStatusBarModuleID];
    if (unsupportedCapabilities.count > 0 ||
        (!hasStaticIcons && !hasUIResources && !hasIconMask &&
         !hasIconOverlay && !hasFolders &&
         !hasBadges && !hasDialer && !hasIconShadows && !hasStatusBar) ||
        ((hasCalendar || hasClock) && !hasStaticIcons)) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"This compiler encountered an unsupported module composition.",
            nil);
        return nil;
    }
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
        effectiveModuleConfigurations = [NSMutableDictionary dictionary];
    for (NSString *moduleID in revision.manifest.moduleConfigurations) {
        if ([capabilities containsObject:moduleID]) {
            effectiveModuleConfigurations[moduleID] =
                revision.manifest.moduleConfigurations[moduleID];
        }
    }
    if (hasBadges) {
        NSString *selectedBadgeVariant = [effectiveSelection
            selectedVariantForGroup:MTBadgesModuleID];
        MTBadgeConfiguration *selectedBadge = [MTBadgeConfiguration
            configurationWithDefaultVariant:selectedBadgeVariant];
        if (selectedBadge == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorUnsupportedResource,
                @"The selected Badge style has no canonical configuration.",
                nil);
            return nil;
        }
        effectiveModuleConfigurations[MTBadgesModuleID] =
            selectedBadge.canonicalDictionary;
    }
    if (hasIconShadows) {
        NSString *selectedShadowVariant = [effectiveSelection
            selectedVariantForGroup:MTIconShadowsModuleID];
        MTIconShadowConfiguration *selectedShadow =
            [MTIconShadowConfiguration
                configurationWithDefaultVariant:selectedShadowVariant];
        if (selectedShadow == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorUnsupportedResource,
                @"The selected Icon Shadow style has no canonical configuration.",
                nil);
            return nil;
        }
        effectiveModuleConfigurations[MTIconShadowsModuleID] =
            selectedShadow.canonicalDictionary;
    }

    NSDictionary *calendarDictionary =
        effectiveModuleConfigurations[MTCalendarIconsModuleID];
    NSError *calendarError = nil;
    MTCalendarIconConfiguration *calendar = calendarDictionary == nil ? nil :
        [[MTCalendarIconConfiguration alloc]
            initWithDictionary:calendarDictionary error:&calendarError];
    NSDictionary *iconMaskDictionary =
        effectiveModuleConfigurations[MTIconMaskModuleID];
    NSError *iconMaskError = nil;
    MTIconMaskConfiguration *iconMask = iconMaskDictionary == nil ? nil :
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:iconMaskDictionary error:&iconMaskError];
    NSDictionary *badgeDictionary =
        effectiveModuleConfigurations[MTBadgesModuleID];
    NSError *badgeError = nil;
    MTBadgeConfiguration *badge = badgeDictionary == nil ? nil :
        [[MTBadgeConfiguration alloc]
            initWithDictionary:badgeDictionary error:&badgeError];
    NSDictionary *iconShadowDictionary =
        effectiveModuleConfigurations[MTIconShadowsModuleID];
    NSError *iconShadowError = nil;
    MTIconShadowConfiguration *iconShadowConfiguration =
        iconShadowDictionary == nil ? nil :
            [[MTIconShadowConfiguration alloc]
                initWithDictionary:iconShadowDictionary
                error:&iconShadowError];
    NSDictionary *staticIconDictionary =
        effectiveModuleConfigurations[@"icons.static"];
    NSError *staticIconError = nil;
    MTStaticIconConfiguration *staticIconConfiguration =
        staticIconDictionary == nil ? nil :
            [[MTStaticIconConfiguration alloc]
                initWithDictionary:staticIconDictionary
                error:&staticIconError];
    NSUInteger expectedConfigurationCount =
        (hasCalendar ? 1 : 0) + (hasIconMask ? 1 : 0) +
        (hasBadges ? 1 : 0) + (staticIconDictionary == nil ? 0 : 1);
    expectedConfigurationCount += hasIconShadows ? 1 : 0;
    if ((hasCalendar && calendar == nil) ||
        (!hasCalendar && calendarDictionary != nil) ||
        (hasIconMask && iconMask == nil) ||
        (!hasIconMask && iconMaskDictionary != nil) ||
        (hasBadges && badge == nil) ||
        (!hasBadges && badgeDictionary != nil) ||
        (hasIconShadows && iconShadowConfiguration == nil) ||
        (!hasIconShadows && iconShadowDictionary != nil) ||
        (staticIconDictionary != nil &&
         (!hasStaticIcons || staticIconConfiguration == nil)) ||
        effectiveModuleConfigurations.count !=
            expectedConfigurationCount) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Module capabilities and configurations do not form an exact supported set.",
            calendarError ?: iconMaskError ?: badgeError ?: iconShadowError ?:
                staticIconError);
        return nil;
    }

    NSMutableArray<MTGenerationIndexRecord *> *records =
        [NSMutableArray arrayWithCapacity:selectedResources.count];
    NSMutableSet<NSString *> *referencedDigests = [NSMutableSet set];
    BOOL hasCalendarBackground = NO;
    BOOL hasClockBackground = NO;
    BOOL hasFolderBackground = NO;
    BOOL hasDefaultBadge = NO;
    BOOL hasDefaultIconShadow = NO;
    for (MTThemeResource *resource in selectedResources) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
        if (!MTStaticIconResourceIsSupported(resource)) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorUnsupportedResource,
                @"The current generation compiler encountered an unsupported resource.",
                nil);
            return nil;
        }
        NSNumber *byteNumber =
            revision.assetByteCountsByContentSHA256[resource.contentSHA256];
        uint64_t byteCount = 0;
        if (!MTStaticIconUnsignedByteCount(byteNumber, &byteCount) ||
            revision.assetURLsByContentSHA256[resource.contentSHA256] == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorInvalidRevision,
                @"A static icon resource is missing its exact Library asset.", nil);
            return nil;
        }
        NSError *recordError = nil;
        MTGenerationIndexRecord *record = [[MTGenerationIndexRecord alloc]
            initWithCanonicalResourceKey:resource.resourceKey.canonicalString
                           contentSHA256:resource.contentSHA256
                           assetByteCount:byteCount
                                    error:&recordError];
        if (record == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorInvalidRevision,
                @"A static icon resource could not enter the generation index.",
                recordError);
            return nil;
        }
        [records addObject:record];
        [referencedDigests addObject:resource.contentSHA256];
        if ([resource.resourceKey.subject
                isEqualToString:@"com.apple.mobilecal"] &&
            [resource.resourceKey.surface
                isEqualToString:@"springboard.home"] &&
            MTStaticIconSourceVariantIsSupported(
                resource.resourceKey.variant)) {
            hasCalendarBackground = YES;
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTClockIconsModuleID] &&
            [resource.resourceKey.variant isEqualToString:@"background"]) {
            hasClockBackground = YES;
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTFolderIconsModuleID] &&
            [resource.resourceKey.variant
                isEqualToString:MTFolderIconVariantBackground]) {
            hasFolderBackground = YES;
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTBadgesModuleID] &&
            [resource.resourceKey.variant
                isEqualToString:badge.defaultVariant]) {
            hasDefaultBadge = YES;
        }
        if ([resource.resourceKey.moduleID
                isEqualToString:MTIconShadowsModuleID] &&
            [resource.resourceKey.variant
                isEqualToString:iconShadowConfiguration.defaultVariant]) {
            hasDefaultIconShadow = YES;
        }
    }
    if (hasCalendar && !hasCalendarBackground) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Calendar configuration requires an imported Calendar background.",
            nil);
        return nil;
    }
    if (hasClock && !hasClockBackground) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Clock capability requires its imported background component.",
            nil);
        return nil;
    }
    if (hasFolders && !hasFolderBackground) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Folder capability requires its base background resource.", nil);
        return nil;
    }
    if (hasBadges && !hasDefaultBadge) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Badge configuration requires its selected default style resources.",
            nil);
        return nil;
    }
    if (hasIconShadows && !hasDefaultIconShadow) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"Icon Shadow configuration requires its selected default style resources.",
            nil);
        return nil;
    }
    if (![referencedDigests isSubsetOfSet:revisionDigests]) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Selected Generation resources are absent from the Library asset set.",
            nil);
        return nil;
    }

    NSArray<NSString *> *sortedDigests =
        [referencedDigests.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<MTGenerationAssetDescriptor *> *assetDescriptors =
        [NSMutableArray arrayWithCapacity:sortedDigests.count];
    NSMutableDictionary<NSString *, NSURL *> *selectedAssetURLs =
        [NSMutableDictionary dictionaryWithCapacity:sortedDigests.count];
    uint64_t selectedAssetByteCount = 0;
    for (NSString *digest in sortedDigests) {
        NSNumber *byteNumber =
            revision.assetByteCountsByContentSHA256[digest];
        uint64_t byteCount = 0;
        if (!MTStaticIconUnsignedByteCount(byteNumber, &byteCount) ||
            !MTStaticIconValidateAsset(
                revision.assetURLsByContentSHA256[digest], digest, byteCount,
                self.decoder, cancellationToken, error)) {
            if (error != NULL && *error == nil) {
                MTStaticIconCompilerSetError(error,
                    MTStaticIconCompilerErrorIntegrity,
                    @"Generation asset validation failed.", nil);
            }
            return nil;
        }
        NSError *assetError = nil;
        MTGenerationAssetDescriptor *asset = [[MTGenerationAssetDescriptor alloc]
            initWithContentSHA256:digest
                        byteCount:byteCount
                            error:&assetError];
        if (asset == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorInvalidRevision,
                @"Generation asset metadata is invalid.", assetError);
            return nil;
        }
        [assetDescriptors addObject:asset];
        selectedAssetURLs[digest] =
            revision.assetURLsByContentSHA256[digest];
        if (byteCount > UINT64_MAX - selectedAssetByteCount) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorIntegrity,
                @"Selected Generation asset bytes overflow their contract.",
                nil);
            return nil;
        }
        selectedAssetByteCount += byteCount;
    }

    NSError *indexError = nil;
    NSData *indexData = [MTGenerationIndex encodedDataWithRecords:records
                                                            error:&indexError];
    MTGenerationIndex *index = indexData == nil ? nil :
        [[MTGenerationIndex alloc] initWithEncodedData:indexData
                                                 error:&indexError];
    MTGenerationDescriptor *descriptor = index == nil ? nil :
        [[MTGenerationDescriptor alloc]
            initWithThemeID:revision.manifest.themeID
            libraryRevisionIdentifier:revision.revisionIdentifier
            manifestDigest:revision.manifestDigest
            indexSHA256:MTSHA256HexDigestForData(indexData)
            indexByteCount:indexData.length
            indexFormatVersion:MTGenerationIndexFormatVersion
            resourceCount:index.recordCount
            assets:assetDescriptors
            moduleIDs:capabilities.allObjects
            moduleConfigurations:effectiveModuleConfigurations
            error:&indexError];
    if (descriptor == nil ||
        descriptor.assetByteCount != selectedAssetByteCount) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorIntegrity,
            @"Generation index or completion descriptor could not be built.",
            indexError);
        return nil;
    }
    return [[MTCompiledGeneration alloc]
        initWithDescriptor:descriptor
                     index:index
   sourceAssetURLsByDigest:selectedAssetURLs];
}

- (MTCompiledGeneration *)compileLibraryRevisionsByThemeIdentifier:
        (NSDictionary<NSString *,MTThemeLibraryRevision *> *)
            revisionsByThemeIdentifier
    mixSelection:(MTThemeMixSelection *)mixSelection
    cancellationToken:(MTImportCancellationToken *)cancellationToken
    error:(NSError **)error {
    MTThemeMixSelection *validatedMix =
        [mixSelection isKindOfClass:MTThemeMixSelection.class]
        ? [MTThemeMixSelection selectionWithCanonicalDictionary:
            mixSelection.canonicalDictionary error:NULL]
        : nil;
    NSSet<NSString *> *revisionKeys = [revisionsByThemeIdentifier
        isKindOfClass:NSDictionary.class]
        ? [NSSet setWithArray:revisionsByThemeIdentifier.allKeys]
        : nil;
    NSSet<NSString *> *effectiveThemes = validatedMix == nil ? nil :
        [NSSet setWithArray:validatedMix.effectiveThemeIdentifiers];
    NSSet<NSString *> *supportedFeatures = [NSSet setWithArray:
        MTStaticIconMixFeatureIdentifiers()];
    NSSet<NSString *> *sourceFeatures = validatedMix == nil ? nil :
        [NSSet setWithArray:
            validatedMix.sourceThemeIdentifiersByFeature.allKeys];
    NSSet<NSString *> *disabledFeatures = validatedMix == nil ? nil :
        [NSSet setWithArray:validatedMix.disabledFeatureIdentifiers];
    if (validatedMix == nil || revisionKeys == nil ||
        ![revisionKeys isEqualToSet:effectiveThemes] ||
        ![sourceFeatures isSubsetOfSet:supportedFeatures] ||
        ![disabledFeatures isSubsetOfSet:supportedFeatures]) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorInvalidRevision,
            @"Theme mix selection or its exact Library source set is invalid.",
            nil);
        return nil;
    }
    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;

    NSMutableDictionary<NSString *, NSArray<MTThemeResource *> *> *
        resourcesByTheme = [NSMutableDictionary
            dictionaryWithCapacity:validatedMix.effectiveThemeIdentifiers.count];
    for (NSString *themeIdentifier in validatedMix.effectiveThemeIdentifiers) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
        MTThemeLibraryRevision *revision =
            revisionsByThemeIdentifier[themeIdentifier];
        NSString *expectedRevision =
            validatedMix.revisionIdentifiersByThemeIdentifier[themeIdentifier];
        if (!MTStaticIconValidateMixLibraryRevision(revision, themeIdentifier,
                expectedRevision, cancellationToken, error)) {
            return nil;
        }
        NSArray<MTThemeResource *> *resources =
            MTStaticIconResourcesForMixSource(revision,
                validatedMix.componentSelectionDictionariesByThemeIdentifier[
                    themeIdentifier], cancellationToken, error);
        if (resources == nil) return nil;
        resourcesByTheme[themeIdentifier] = resources;
    }

    BOOL calendarDisabled = ![validatedMix
        isFeatureEnabled:MTThemeFeatureDynamicCalendar];
    BOOL clockDisabled = ![validatedMix
        isFeatureEnabled:MTThemeFeatureDynamicClock];
    NSString *calendarSource = [validatedMix
        sourceThemeIdentifierForFeatureIdentifier:
            MTThemeFeatureDynamicCalendar];
    NSString *clockSource = [validatedMix
        sourceThemeIdentifierForFeatureIdentifier:MTThemeFeatureDynamicClock];
    BOOL calendarDedicated = NO;
    if (!calendarDisabled && !MTStaticIconEvaluateMixSourceFeature(
            MTThemeFeatureDynamicCalendar,
            revisionsByThemeIdentifier[calendarSource].manifest,
            resourcesByTheme[calendarSource], cancellationToken,
            &calendarDedicated, error)) {
        return nil;
    }
    BOOL clockDedicated = NO;
    if (!clockDisabled && !MTStaticIconEvaluateMixSourceFeature(
            MTThemeFeatureDynamicClock,
            revisionsByThemeIdentifier[clockSource].manifest,
            resourcesByTheme[clockSource], cancellationToken,
            &clockDedicated, error)) {
        return nil;
    }

    NSMutableDictionary<NSString *, MTThemeResource *> *resourceByKey =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, MTThemeLibraryRevision *> *revisionByKey =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *capabilities = [NSMutableSet set];

    void (^setConfigurationIfPresent)(NSString *, MTThemeLibraryRevision *, BOOL) =
        ^(NSString *moduleIdentifier,
          MTThemeLibraryRevision *sourceRevision,
          BOOL replaceExisting) {
        NSDictionary<NSString *, id> *configuration =
            sourceRevision.manifest.moduleConfigurations[moduleIdentifier];
        if (configuration != nil &&
            (replaceExisting || moduleConfigurations[moduleIdentifier] == nil)) {
            moduleConfigurations[moduleIdentifier] = configuration;
        }
    };

    for (NSString *featureIdentifier in MTStaticIconMixFeatureIdentifiers()) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
        if (![validatedMix isFeatureEnabled:featureIdentifier]) continue;

        if ([featureIdentifier isEqualToString:MTThemeFeatureAppIcons]) {
            NSMutableDictionary<NSString *, NSString *> *ownerBySubject =
                [NSMutableDictionary dictionary];
            NSMutableArray<MTThemeLibraryRevision *> *readyRevisions =
                [NSMutableArray array];
            BOOL explicitPrimary = validatedMix
                .sourceThemeIdentifiersByFeature[MTThemeFeatureAppIcons] != nil;
            NSArray<NSString *> *iconThemes =
                validatedMix.appIconThemeIdentifiersInPriorityOrder;
            for (NSUInteger priority = 0; priority < iconThemes.count;
                 priority++) {
                if (MTStaticIconCompilerCancelled(cancellationToken, error)) {
                    return nil;
                }
                NSString *iconTheme = iconThemes[priority];
                MTThemeLibraryRevision *iconRevision =
                    revisionsByThemeIdentifier[iconTheme];
                NSArray<MTThemeResource *> *iconResources =
                    resourcesByTheme[iconTheme];
                BOOL sourceReady = NO;
                if (iconRevision != nil && iconResources != nil &&
                    !MTStaticIconEvaluateMixSourceFeature(
                        MTThemeFeatureAppIcons, iconRevision.manifest,
                        iconResources, cancellationToken, &sourceReady, error)) {
                    return nil;
                }
                if (!sourceReady) {
                    // An implicit base theme may contain no App icons at all;
                    // an explicit primary or fallback is a user-selected icon
                    // source and must still satisfy the feature contract.
                    if (priority > 0 || explicitPrimary) {
                        MTStaticIconCompilerSetError(error,
                            MTStaticIconCompilerErrorUnsupportedResource,
                            @"A selected App icon fallback source no longer provides App icons.",
                            nil);
                        return nil;
                    }
                    continue;
                }
                [readyRevisions addObject:iconRevision];
                NSUInteger matchingLayerIndex = readyRevisions.count - 1;
                for (MTThemeResource *resource in iconResources) {
                    if (MTStaticIconCompilerCancelled(cancellationToken, error)) {
                        return nil;
                    }
                    if (!MTStaticIconResourceMatchesMixFeature(resource,
                            MTThemeFeatureAppIcons)) {
                        continue;
                    }
                    MTResourceKey *key = resource.resourceKey;
                    BOOL isCalendar = [key.subject
                        isEqualToString:@"com.apple.mobilecal"];
                    BOOL isClock = [key.subject
                        isEqualToString:@"com.apple.mobiletimer"];
                    if ((isCalendar &&
                            (calendarDisabled || calendarDedicated)) ||
                        (isClock && (clockDisabled || clockDedicated))) {
                        continue;
                    }
                    NSString *owner = ownerBySubject[key.subject];
                    if (owner == nil) {
                        ownerBySubject[key.subject] = iconTheme;
                    } else if (![owner isEqualToString:iconTheme]) {
                        continue;
                    }
                    NSError *layerError = nil;
                    MTThemeResource *layeredResource =
                        MTStaticIconResourceForMatchingLayer(
                            resource, matchingLayerIndex, &layerError);
                    if (layeredResource == nil) {
                        MTStaticIconCompilerSetError(error,
                            MTStaticIconCompilerErrorUnsupportedResource,
                            @"An App icon fallback resource could not retain its source priority.",
                            layerError);
                        return nil;
                    }
                    NSString *canonicalKey =
                        layeredResource.resourceKey.canonicalString;
                    if (resourceByKey[canonicalKey] == nil) {
                        resourceByKey[canonicalKey] = layeredResource;
                        revisionByKey[canonicalKey] = iconRevision;
                    }
                }
            }
            NSDictionary<NSString *, id> *configuration =
                MTStaticIconMergedConfigurationForRevisions(readyRevisions);
            if (readyRevisions.count > 0 && configuration == nil) {
                MTStaticIconCompilerSetError(error,
                    MTStaticIconCompilerErrorUnsupportedResource,
                    @"App icon fallback matching layers exceed the supported configuration contract.",
                    nil);
                return nil;
            }
            if (configuration != nil) {
                moduleConfigurations[@"icons.static"] = configuration;
            }
            continue;
        }

        NSString *sourceTheme = [validatedMix
            sourceThemeIdentifierForFeatureIdentifier:featureIdentifier];
        MTThemeLibraryRevision *sourceRevision =
            revisionsByThemeIdentifier[sourceTheme];
        NSArray<MTThemeResource *> *sourceResources =
            resourcesByTheme[sourceTheme];
        BOOL sourceReady = NO;
        if (sourceRevision != nil && sourceResources != nil &&
            !MTStaticIconEvaluateMixSourceFeature(featureIdentifier,
                sourceRevision.manifest, sourceResources, cancellationToken,
                &sourceReady, error)) {
            return nil;
        }
        BOOL explicitSource =
            validatedMix.sourceThemeIdentifiersByFeature[featureIdentifier] != nil;
        if (!sourceReady) {
            if (explicitSource) {
                MTStaticIconCompilerSetError(error,
                    MTStaticIconCompilerErrorUnsupportedResource,
                    @"The selected source theme does not provide the requested enabled feature.",
                    nil);
                return nil;
            }
            continue;
        }

        if ([featureIdentifier
                isEqualToString:MTThemeFeatureDynamicCalendar]) {
            setConfigurationIfPresent(MTCalendarIconsModuleID,
                                      sourceRevision, YES);
            setConfigurationIfPresent(@"icons.static", sourceRevision, NO);
            [capabilities addObject:MTCalendarIconsModuleID];
        } else if ([featureIdentifier
                isEqualToString:MTThemeFeatureDynamicClock]) {
            setConfigurationIfPresent(@"icons.static", sourceRevision, NO);
        } else if ([featureIdentifier
                isEqualToString:MTThemeFeatureIconMask]) {
            setConfigurationIfPresent(MTIconMaskModuleID,
                                      sourceRevision, YES);
            [capabilities addObject:MTIconMaskModuleID];
        } else if ([featureIdentifier
                isEqualToString:MTThemeFeatureBadges]) {
            setConfigurationIfPresent(MTBadgesModuleID,
                                      sourceRevision, YES);
        } else if ([featureIdentifier
                isEqualToString:MTThemeFeatureIconShadows]) {
            setConfigurationIfPresent(MTIconShadowsModuleID,
                                      sourceRevision, YES);
        }

        for (MTThemeResource *resource in sourceResources) {
            if (MTStaticIconCompilerCancelled(cancellationToken, error)) {
                return nil;
            }
            if (!MTStaticIconResourceMatchesMixFeature(resource,
                                                       featureIdentifier)) {
                continue;
            }
            MTResourceKey *key = resource.resourceKey;
            NSString *canonicalKey = key.canonicalString;
            BOOL dedicatedDynamicFeature =
                [featureIdentifier isEqualToString:
                    MTThemeFeatureDynamicCalendar] ||
                [featureIdentifier isEqualToString:
                    MTThemeFeatureDynamicClock];
            if (resourceByKey[canonicalKey] == nil ||
                dedicatedDynamicFeature) {
                resourceByKey[canonicalKey] = resource;
                revisionByKey[canonicalKey] = sourceRevision;
            }
        }
    }

    for (MTThemeResource *resource in resourceByKey.allValues) {
        [capabilities addObject:resource.resourceKey.moduleID];
    }
    for (NSString *moduleIdentifier in
            [moduleConfigurations.allKeys copy]) {
        if (![capabilities containsObject:moduleIdentifier]) {
            [moduleConfigurations removeObjectForKey:moduleIdentifier];
        }
    }

    MTThemeLibraryRevision *baseRevision =
        revisionsByThemeIdentifier[validatedMix.baseThemeIdentifier];
    NSArray<NSString *> *sortedCapabilities = [capabilities.allObjects
        sortedArrayUsingSelector:@selector(compare:)];
    if (resourceByKey.count == 0) {
        NSError *indexError = nil;
        NSData *indexData = [MTGenerationIndex encodedDataWithRecords:@[]
                                                               error:&indexError];
        MTGenerationIndex *index = indexData == nil ? nil :
            [[MTGenerationIndex alloc] initWithEncodedData:indexData
                                                     error:&indexError];
        MTGenerationDescriptor *descriptor = index == nil ? nil :
            [[MTGenerationDescriptor alloc]
                initWithThemeID:baseRevision.manifest.themeID
                libraryRevisionIdentifier:baseRevision.revisionIdentifier
                manifestDigest:baseRevision.manifestDigest
                indexSHA256:MTSHA256HexDigestForData(indexData)
                indexByteCount:indexData.length
                indexFormatVersion:MTGenerationIndexFormatVersion
                resourceCount:0
                assets:@[]
                moduleIDs:sortedCapabilities
                moduleConfigurations:moduleConfigurations
                error:&indexError];
        if (descriptor == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorUnsupportedResource,
                @"The disabled theme feature set could not form an empty Generation.",
                indexError);
            return nil;
        }
        return [[MTCompiledGeneration alloc]
            initWithDescriptor:descriptor index:index
            sourceAssetURLsByDigest:@{}];
    }

    if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
    NSArray<NSString *> *sortedResourceKeys = [resourceByKey.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<MTThemeResource *> *composedResources =
        [NSMutableArray arrayWithCapacity:sortedResourceKeys.count];
    NSMutableDictionary<NSString *, NSURL *> *assetURLs =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *assetByteCounts =
        [NSMutableDictionary dictionary];
    uint64_t assetByteCount = 0;
    for (NSString *canonicalKey in sortedResourceKeys) {
        if (MTStaticIconCompilerCancelled(cancellationToken, error)) return nil;
        MTThemeResource *resource = resourceByKey[canonicalKey];
        MTThemeLibraryRevision *sourceRevision = revisionByKey[canonicalKey];
        NSNumber *byteNumber = sourceRevision
            .assetByteCountsByContentSHA256[resource.contentSHA256];
        NSURL *assetURL = sourceRevision
            .assetURLsByContentSHA256[resource.contentSHA256];
        uint64_t byteCount = 0;
        if (!MTStaticIconUnsignedByteCount(byteNumber, &byteCount) ||
            assetURL == nil) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorInvalidRevision,
                @"A selected theme mix resource is missing its Library asset.",
                nil);
            return nil;
        }
        NSNumber *existingBytes = assetByteCounts[resource.contentSHA256];
        if (existingBytes != nil &&
            existingBytes.unsignedLongLongValue != byteCount) {
            MTStaticIconCompilerSetError(error,
                MTStaticIconCompilerErrorIntegrity,
                @"Equal theme mix asset digests disagree about byte size.", nil);
            return nil;
        }
        if (existingBytes == nil) {
            if (UINT64_MAX - assetByteCount < byteCount) {
                MTStaticIconCompilerSetError(error,
                    MTStaticIconCompilerErrorIntegrity,
                    @"Theme mix asset bytes overflow their contract.", nil);
                return nil;
            }
            assetURLs[resource.contentSHA256] = assetURL;
            assetByteCounts[resource.contentSHA256] = @(byteCount);
            assetByteCount += byteCount;
        }
        [composedResources addObject:resource];
    }

    NSError *compositionError = nil;
    NSData *mixData = MTCanonicalJSONData(
        validatedMix.effectiveCanonicalDictionary, &compositionError);
    NSString *sourceFingerprint = mixData == nil ? nil :
        MTSHA256HexDigestForData(mixData);
    MTThemeManifest *composedManifest = sourceFingerprint == nil ? nil :
        [[MTThemeManifest alloc]
            initWithThemeID:baseRevision.manifest.themeID
            displayName:baseRevision.manifest.displayName
            author:baseRevision.manifest.author
            themeVersion:baseRevision.manifest.themeVersion
            importerID:@"marktheme.mix"
            importerVersion:1
            sourceFingerprint:sourceFingerprint
            capabilities:sortedCapabilities
            moduleConfigurations:moduleConfigurations
            resources:composedResources
            error:&compositionError];
    NSString *composedDigest = [composedManifest
        contentDigestWithError:&compositionError];
    MTThemeLibraryRevision *composedRevision = composedDigest == nil ? nil :
        [[MTThemeLibraryRevision alloc]
            initWithRevisionIdentifier:
                [@"r1-" stringByAppendingString:composedDigest]
            manifestDigest:composedDigest
            manifest:composedManifest
            assetURLsByContentSHA256:assetURLs
            assetByteCountsByContentSHA256:assetByteCounts
            resourcesDirectoryURL:nil
            assetByteCount:assetByteCount];
    MTCompiledGeneration *compiled = composedRevision == nil ? nil :
        [self compileLibraryRevision:composedRevision
             cancellationToken:cancellationToken error:&compositionError];
    if (compiled == nil) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorUnsupportedResource,
            @"The selected cross-theme feature composition is not runnable.",
            compositionError);
        return nil;
    }

    NSError *descriptorError = nil;
    MTGenerationDescriptor *descriptor = [[MTGenerationDescriptor alloc]
        initWithThemeID:baseRevision.manifest.themeID
        libraryRevisionIdentifier:baseRevision.revisionIdentifier
        manifestDigest:baseRevision.manifestDigest
        indexSHA256:compiled.descriptor.indexSHA256
        indexByteCount:compiled.descriptor.indexByteCount
        indexFormatVersion:compiled.descriptor.indexFormatVersion
        resourceCount:compiled.descriptor.resourceCount
        assets:compiled.descriptor.assets
        moduleIDs:compiled.descriptor.moduleIDs
        moduleConfigurations:compiled.descriptor.moduleConfigurations
        error:&descriptorError];
    if (descriptor == nil) {
        MTStaticIconCompilerSetError(error,
            MTStaticIconCompilerErrorIntegrity,
            @"The compiled theme mix could not bind to its base revision identity.",
            descriptorError);
        return nil;
    }
    return [[MTCompiledGeneration alloc]
        initWithDescriptor:descriptor
                     index:compiled.index
   sourceAssetURLsByDigest:compiled.sourceAssetURLsByContentSHA256];
}

@end
