#import "MTStaticIconCompiler.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTDigest.h"
#import "MTBadgeConfiguration.h"
#import "MTBadgesModule.h"
#import "MTCalendarIconConfiguration.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTDialerModule.h"
#import "MTFolderIconContract.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconMaskContract.h"
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
#import "MTThemeManifest.h"
#import "MTStatusBarContract.h"
#import "MTStatusBarModule.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeComponentCatalog.h"
#import "MTUIResourcesModule.h"

NSString *const MTStaticIconCompilerErrorDomain =
    @"com.hmmzzz.marktheme64e.static-icon-compiler";

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
        iconMask || folder || badge || dialer || statusBar || iconShadow;
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
        MTUIResourcesModuleID, MTIconMaskModuleID, MTFolderIconsModuleID,
        MTBadgesModuleID, MTDialerModuleID, MTIconShadowsModuleID,
        MTStatusBarModuleID,
        nil]];
    BOOL hasStaticIcons = [capabilities containsObject:@"icons.static"];
    BOOL hasCalendar = [capabilities containsObject:MTCalendarIconsModuleID];
    BOOL hasClock = [capabilities containsObject:MTClockIconsModuleID];
    BOOL hasUIResources =
        [capabilities containsObject:MTUIResourcesModuleID];
    BOOL hasIconMask = [capabilities containsObject:MTIconMaskModuleID];
    BOOL hasFolders = [capabilities containsObject:MTFolderIconsModuleID];
    BOOL hasBadges = [capabilities containsObject:MTBadgesModuleID];
    BOOL hasDialer = [capabilities containsObject:MTDialerModuleID];
    BOOL hasIconShadows =
        [capabilities containsObject:MTIconShadowsModuleID];
    BOOL hasStatusBar = [capabilities containsObject:MTStatusBarModuleID];
    if (unsupportedCapabilities.count > 0 ||
        (!hasStaticIcons && !hasUIResources && !hasIconMask && !hasFolders &&
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
        if ([resource.resourceKey.moduleID
                isEqualToString:MTIconShadowsModuleID] &&
            [resource.resourceKey.variant
                isEqualToString:iconShadowConfiguration.defaultVariant]) {
            hasDefaultIconShadow = YES;
        }
    }
    
    // We allow themes to omit backgrounds for Clock, Calendar, Folders, and Badges.
    // Native system assets or transparent fallbacks will be used dynamically.
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

@end
