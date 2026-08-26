#import "MTThemeSourceRoot.h"

#import <string.h>

#import "MTIconBundlesImporter.h"
#import "MTLegacyThemeResourcesImporter.h"
#import "MTSourceInventory.h"
#import "MTThemeComponentPath.h"
#import "MTUIResourcesImporter.h"

@interface MTThemeSourceRoot ()
@property(nonatomic, strong) id<MTAuditedSource> source;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSString *> *sourcePathsByLogicalPath;
- (instancetype)initWithSource:(id<MTAuditedSource>)source
                       inventory:(MTSourceInventory *)inventory
            sourcePathsByLogicalPath:
                (NSDictionary<NSString *, NSString *> *)sourcePathsByLogicalPath;
@end

static BOOL MTThemeSourceRootSetError(NSError **error,
                                      MTAuditedSourceErrorCode code,
                                      NSString *description,
                                      NSError *_Nullable underlying) {
    if (error != NULL) {
        NSMutableDictionary<NSString *, id> *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTAuditedSourceErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTThemeSourceRootContainsResourceTree(
    NSArray<MTSourceFile *> *files,
    NSString *prefix) {
    NSArray<NSString *> *resourcePrefixes = @[
        [prefix stringByAppendingString:@"IconBundles/"],
        [prefix stringByAppendingString:@"Bundles/"],
        [prefix stringByAppendingString:@"UIImages/"],
        [prefix stringByAppendingString:@"AnemoneEffects/"],
    ];
    for (MTSourceFile *file in files) {
        for (NSString *resourcePrefix in resourcePrefixes) {
            if (MTThemePathHasDirectoryPrefix(file.relativePath,
                                              resourcePrefix)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL MTThemeSourceRootPathIsPackagingArtifact(NSString *path) {
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSString *component in components) {
        if ([component caseInsensitiveCompare:@"__MACOSX"] ==
                NSOrderedSame) {
            return YES;
        }
    }
    NSString *name = components.lastObject ?: @"";
    return [name hasPrefix:@"._"] ||
        [name caseInsensitiveCompare:@".DS_Store"] == NSOrderedSame;
}

static NSString *MTThemeSourceRootPrefix(NSArray<MTSourceFile *> *files) {
    if (MTThemeSourceRootContainsResourceTree(files, @"")) return @"";
    // Real packages often wrap the theme in a folder and leave loose files
    // (a README, a preview image) beside it. Choose the wrapper that actually
    // holds a resource tree instead of requiring every file to share it.
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (MTSourceFile *file in files) {
        NSRange separator = [file.relativePath rangeOfString:@"/"];
        if (separator.location == NSNotFound || separator.location == 0) {
            continue;
        }
        NSString *candidate = [file.relativePath
            substringToIndex:separator.location + 1];
        if ([seen containsObject:candidate.lowercaseString]) continue;
        [seen addObject:candidate.lowercaseString];
        [candidates addObject:candidate];
    }
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (NSString *candidate in candidates) {
        if (MTThemeSourceRootContainsResourceTree(files, candidate)) {
            [matches addObject:candidate];
        }
    }
    // Exactly one wrapper may claim the root; anything else stays ambiguous
    // and is resolved at the original root.
    return matches.count == 1 ? matches.firstObject : @"";
}

static BOOL MTThemeSourceRootPNGSignatureIsPresent(MTSourceFile *file) {
    static const unsigned char signature[] = {
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a
    };
    return file.prefixData.length >= sizeof(signature) &&
        memcmp(file.prefixData.bytes, signature, sizeof(signature)) == 0;
}

static NSString *_Nullable MTThemeSourceRootClassifiedPath(
    MTSourceFile *file,
    NSString **group,
    BOOL *looseIcon) {
    NSArray<NSString *> *components =
        [file.relativePath componentsSeparatedByString:@"/"];
    NSDictionary<NSString *, NSString *> *anchors = @{
        @"iconbundles" : @"IconBundles",
        @"bundles" : @"Bundles",
        @"uiimages" : @"UIImages",
        @"anemoneeffects" : @"AnemoneEffects",
    };
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        NSString *anchor = anchors[components[index].lowercaseString];
        if (anchor == nil) continue;
        NSArray<NSString *> *prefix = [components
            subarrayWithRange:NSMakeRange(0, index)];
        NSArray<NSString *> *tail = [components subarrayWithRange:
            NSMakeRange(index + 1, components.count - index - 1)];
        if (group != NULL) *group = [prefix componentsJoinedByString:@"/"];
        if (looseIcon != NULL) *looseIcon = NO;
        return [NSString stringWithFormat:@"%@/%@", anchor,
            [tail componentsJoinedByString:@"/"]];
    }
    NSString *filename = components.lastObject;
    if (!MTThemeSourceRootPNGSignatureIsPresent(file)) return nil;

    NSDictionary<NSString *, NSString *> *knownBundles = @{
        @"com.apple.springboard" : @"com.apple.springboard",
        @"com.apple.telephonyui" : @"com.apple.TelephonyUI",
        @"com.apple.ui" : @"com.apple.UI",
        @"com.apple.uikit" : @"com.apple.UIKit",
        @"com.apple.mobileicons.framework" :
            @"com.apple.mobileicons.framework",
    };
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        NSString *bundleIdentifier = components[index];
        NSString *canonicalBundle =
            knownBundles[bundleIdentifier.lowercaseString];
        if (canonicalBundle == nil &&
            MTUIResourceBundleIsSupported(bundleIdentifier)) {
            canonicalBundle = bundleIdentifier;
        }
        NSString *suggested = canonicalBundle == nil
            ? MTIconBundlesSuggestedBundleRelativePath(bundleIdentifier,
                                                        filename)
            : [NSString stringWithFormat:@"Bundles/%@/%@",
                canonicalBundle, filename];
        if (suggested == nil) continue;
        NSArray<NSString *> *prefix = [components
            subarrayWithRange:NSMakeRange(0, index)];
        if (group != NULL) *group = [prefix componentsJoinedByString:@"/"];
        if (looseIcon != NULL) *looseIcon = YES;
        return suggested;
    }

    NSString *suggested =
        MTIconBundlesSuggestedRelativePathForLooseFilename(filename);
    if (suggested == nil) {
        suggested = MTLegacySuggestedRelativePathForLooseFilename(filename);
    }
    if (suggested == nil) return nil;
    NSArray<NSString *> *prefix = components.count > 1
        ? [components subarrayWithRange:NSMakeRange(0, components.count - 1)]
        : @[];
    if (group != NULL) *group = [prefix componentsJoinedByString:@"/"];
    if (looseIcon != NULL) *looseIcon = YES;
    return suggested;
}

static NSString *MTThemeSourceRootAutomaticComponentName(NSString *group) {
    NSString *name = group.lastPathComponent;
    if (name.length == 0) name = @"Imported Component";
    return [name.lowercaseString hasSuffix:@".theme"]
        ? name : [name stringByAppendingString:@".theme"];
}

static NSDictionary<NSString *, NSString *> *_Nullable
MTThemeSourceRootClassifiedPaths(NSArray<MTSourceFile *> *files,
                                 NSString *ordinaryPrefix) {
    NSMutableArray<NSDictionary<NSString *, id> *> *entries =
        [NSMutableArray array];
    BOOL needed = NO;
    for (MTSourceFile *file in files) {
        NSString *group = nil;
        BOOL loose = NO;
        NSString *logical = MTThemeSourceRootClassifiedPath(file, &group,
                                                             &loose);
        if (logical == nil) continue;
        [entries addObject:@{
            @"file" : file,
            @"group" : group ?: @"",
            @"logical" : logical,
        }];
        NSString *ordinary = ordinaryPrefix.length == 0
            ? file.relativePath
            : MTThemePathRemainderAfterDirectoryPrefix(file.relativePath,
                                                        ordinaryPrefix);
        if (loose || ordinary == nil || ![ordinary isEqualToString:logical]) {
            needed = YES;
        }
    }
    if (!needed || entries.count == 0) return nil;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [((MTSourceFile *)left[@"file"]).relativePath
            compare:((MTSourceFile *)right[@"file"]).relativePath
            options:NSLiteralSearch];
    }];
    NSMutableDictionary<NSString *, NSString *> *paths =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, MTSourceFile *> *filesByFoldedPath =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *componentNamesByGroup =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *usedComponentNames = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *entry in entries) {
        MTSourceFile *file = entry[@"file"];
        NSString *logical = entry[@"logical"];
        NSString *folded = logical.lowercaseString;
        MTSourceFile *existing = filesByFoldedPath[folded];
        if (existing != nil && existing.byteCount == file.byteCount &&
            [existing.contentSHA256 isEqualToString:file.contentSHA256]) {
            continue;
        }
        if (existing != nil) {
            NSString *group = entry[@"group"];
            NSString *componentName = componentNamesByGroup[group];
            if (componentName == nil) {
                NSString *base = MTThemeSourceRootAutomaticComponentName(group);
                componentName = base;
                NSUInteger suffix = 2;
                while ([usedComponentNames containsObject:
                        componentName.lowercaseString]) {
                    NSString *stem = [base.lowercaseString hasSuffix:@".theme"]
                        ? [base substringToIndex:base.length - 6] : base;
                    componentName = [NSString stringWithFormat:
                        @"%@ [%lu].theme", stem, (unsigned long)suffix++];
                }
                componentNamesByGroup[group] = componentName;
                [usedComponentNames addObject:componentName.lowercaseString];
            }
            logical = [NSString stringWithFormat:@"Components/%@/%@",
                componentName, logical];
            folded = logical.lowercaseString;
            if (filesByFoldedPath[folded] != nil) return nil;
        }
        paths[logical] = file.relativePath;
        filesByFoldedPath[folded] = file;
    }
    MTSourceFile *selectedInfo = nil;
    for (MTSourceFile *file in files) {
        if ([file.relativePath.lastPathComponent
                caseInsensitiveCompare:@"Info.plist"] != NSOrderedSame) {
            continue;
        }
        if (selectedInfo == nil ||
            [file.relativePath isEqualToString:@"Info.plist"] ||
            (![selectedInfo.relativePath isEqualToString:@"Info.plist"] &&
             [file.relativePath compare:selectedInfo.relativePath
                                 options:NSLiteralSearch] == NSOrderedAscending)) {
            selectedInfo = file;
        }
    }
    if (selectedInfo != nil) paths[@"Info.plist"] = selectedInfo.relativePath;
    return paths.count > 0 ? [paths copy] : nil;
}

static BOOL MTThemeSourceRootSplitSuitePath(
    NSString *path,
    NSString **containerPrefix,
    NSString **themeDirectory,
    NSString **nestedPath) {
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSUInteger index = 0; index + 1 < components.count; index++) {
        NSString *component = components[index];
        if (![component.lowercaseString hasSuffix:@".theme"] ||
            component.length <= 6) {
            continue;
        }
        NSArray<NSString *> *prefixComponents =
            [components subarrayWithRange:NSMakeRange(0, index)];
        NSArray<NSString *> *nestedComponents = [components subarrayWithRange:
            NSMakeRange(index + 1, components.count - index - 1)];
        if (containerPrefix != NULL) {
            NSString *prefix = [prefixComponents componentsJoinedByString:@"/"];
            *containerPrefix = prefix.length == 0
                ? @"" : [prefix stringByAppendingString:@"/"];
        }
        if (themeDirectory != NULL) *themeDirectory = component;
        if (nestedPath != NULL) {
            *nestedPath = [nestedComponents componentsJoinedByString:@"/"];
        }
        return YES;
    }
    return NO;
}

static NSDictionary<NSString *, NSString *> *_Nullable
MTThemeSourceRootMergedThemePaths(NSArray<MTSourceFile *> *files) {
    NSMutableDictionary<NSString *, NSString *> *groupBySourcePath =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *nestedPathBySourcePath =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *themeDirectoryByGroup =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *containerByGroup =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *fileCountByGroup =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *resourceCountByGroup =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *hasInfoByGroup =
        [NSMutableDictionary dictionary];
    for (MTSourceFile *file in files) {
        NSString *containerPrefix = nil;
        NSString *themeDirectory = nil;
        NSString *nestedPath = nil;
        if (!MTThemeSourceRootSplitSuitePath(file.relativePath,
                &containerPrefix, &themeDirectory, &nestedPath)) {
            continue;
        }
        NSString *group = [containerPrefix stringByAppendingString:
            themeDirectory];
        groupBySourcePath[file.relativePath] = group;
        nestedPathBySourcePath[file.relativePath] = nestedPath;
        themeDirectoryByGroup[group] = themeDirectory;
        containerByGroup[group] = containerPrefix;
        fileCountByGroup[group] = @([fileCountByGroup[group]
            unsignedIntegerValue] + 1);
        NSArray<NSString *> *resourcePrefixes = @[
            @"IconBundles/", @"Bundles/", @"UIImages/",
            @"AnemoneEffects/",
        ];
        for (NSString *resourcePrefix in resourcePrefixes) {
            if ([nestedPath hasPrefix:resourcePrefix] &&
                nestedPath.length > resourcePrefix.length) {
                resourceCountByGroup[group] = @([resourceCountByGroup[group]
                    unsignedIntegerValue] + 1);
                break;
            }
        }
        if ([nestedPath caseInsensitiveCompare:@"Info.plist"] ==
                NSOrderedSame) {
            hasInfoByGroup[group] = @YES;
        }
    }
    if (themeDirectoryByGroup.count == 0) return nil;

    NSMutableSet<NSString *> *possibleRootPrefixes = [NSMutableSet setWithArray:
        containerByGroup.allValues];
    NSString *ordinaryPrefix = MTThemeSourceRootPrefix(files);
    if (MTThemeSourceRootContainsResourceTree(files, ordinaryPrefix)) {
        [possibleRootPrefixes addObject:ordinaryPrefix];
    }
    NSMutableDictionary<NSString *, NSNumber *> *groupCountByContainer =
        [NSMutableDictionary dictionary];
    for (NSString *container in containerByGroup.allValues) {
        groupCountByContainer[container] = @([groupCountByContainer[container]
            unsignedIntegerValue] + 1);
    }
    NSArray<NSString *> *rootPrefixes = [possibleRootPrefixes.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                       NSString *right) {
        NSUInteger leftGroups = [groupCountByContainer[left]
            unsignedIntegerValue];
        NSUInteger rightGroups = [groupCountByContainer[right]
            unsignedIntegerValue];
        if (leftGroups != rightGroups) {
            return leftGroups > rightGroups
                ? NSOrderedAscending : NSOrderedDescending;
        }
        if (left.length != right.length) {
            return left.length < right.length
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left compare:right options:NSLiteralSearch];
    }];
    NSString *rootPrefix = nil;
    for (NSString *candidate in rootPrefixes) {
        if (MTThemeSourceRootContainsResourceTree(files, candidate)) {
            rootPrefix = candidate;
            break;
        }
    }
    NSMutableDictionary<NSString *, NSString *> *rootNestedPathBySourcePath =
        [NSMutableDictionary dictionary];
    if (rootPrefix != nil) {
        for (MTSourceFile *file in files) {
            if (groupBySourcePath[file.relativePath] != nil ||
                (rootPrefix.length > 0 &&
                 ![file.relativePath hasPrefix:rootPrefix])) {
                continue;
            }
            NSString *nestedPath = [file.relativePath
                substringFromIndex:rootPrefix.length];
            if (nestedPath.length > 0) {
                rootNestedPathBySourcePath[file.relativePath] = nestedPath;
            }
        }
    }
    BOOL rootIsPrimary = rootNestedPathBySourcePath.count > 0;

    NSMutableDictionary<NSString *, NSNumber *> *suiteChildCountByGroup =
        [NSMutableDictionary dictionary];
    for (NSString *group in themeDirectoryByGroup) {
        NSString *directory = themeDirectoryByGroup[group];
        NSString *stem = [directory substringToIndex:directory.length - 6];
        NSString *childPrefix = [stem stringByAppendingString:@" - "];
        NSUInteger childCount = 0;
        for (NSString *otherGroup in themeDirectoryByGroup) {
            if ([group isEqualToString:otherGroup] ||
                ![containerByGroup[group]
                    isEqualToString:containerByGroup[otherGroup]]) {
                continue;
            }
            NSString *otherDirectory = themeDirectoryByGroup[otherGroup];
            if ([otherDirectory hasPrefix:childPrefix] &&
                [otherDirectory.lowercaseString hasSuffix:@".theme"]) {
                childCount++;
            }
        }
        suiteChildCountByGroup[group] = @(childCount);
    }

    NSArray<NSString *> *groups = [themeDirectoryByGroup.allKeys
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                       NSString *right) {
        NSArray<NSDictionary<NSString *, NSNumber *> *> *rankings = @[
            hasInfoByGroup, suiteChildCountByGroup, resourceCountByGroup,
            fileCountByGroup,
        ];
        for (NSDictionary<NSString *, NSNumber *> *ranking in rankings) {
            NSUInteger leftValue = [ranking[left] unsignedIntegerValue];
            NSUInteger rightValue = [ranking[right] unsignedIntegerValue];
            if (leftValue != rightValue) {
                return leftValue > rightValue
                    ? NSOrderedAscending : NSOrderedDescending;
            }
        }
        return [left compare:right options:NSLiteralSearch];
    }];
    NSString *primaryGroup = rootIsPrimary ? nil : groups.firstObject;

    NSMutableDictionary<NSString *, NSString *> *componentNameByGroup =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *usedComponentNames = [NSMutableSet set];
    for (NSString *group in groups) {
        if (!rootIsPrimary && [group isEqualToString:primaryGroup]) continue;
        NSString *directory = themeDirectoryByGroup[group];
        NSString *stem = [directory substringToIndex:directory.length - 6];
        NSString *candidate = directory;
        NSUInteger suffix = 2;
        while ([usedComponentNames containsObject:
                candidate.lowercaseString]) {
            candidate = [NSString stringWithFormat:@"%@ [%lu].theme", stem,
                (unsigned long)suffix++];
        }
        [usedComponentNames addObject:candidate.lowercaseString];
        componentNameByGroup[group] = candidate;
    }

    NSMutableDictionary<NSString *, NSString *> *paths =
        [NSMutableDictionary dictionaryWithCapacity:
            groupBySourcePath.count + rootNestedPathBySourcePath.count];
    for (NSString *sourcePath in rootNestedPathBySourcePath) {
        NSString *logicalPath = rootNestedPathBySourcePath[sourcePath];
        if (paths[logicalPath] != nil) return nil;
        paths[logicalPath] = sourcePath;
    }
    for (MTSourceFile *file in files) {
        NSString *group = groupBySourcePath[file.relativePath];
        if (group == nil) continue;
        NSString *nestedPath = nestedPathBySourcePath[file.relativePath];
        NSString *logicalPath = !rootIsPrimary &&
                [group isEqualToString:primaryGroup]
            ? nestedPath
            : [NSString stringWithFormat:@"Components/%@/%@",
                componentNameByGroup[group], nestedPath];
        if (logicalPath.length == 0 || paths[logicalPath] != nil) return nil;
        paths[logicalPath] = file.relativePath;
    }
    return paths.count > 0 ? [paths copy] : nil;
}

@implementation MTThemeSourceRoot

+ (id<MTAuditedSource>)
    sourceByResolvingThemeRootInSource:(id<MTAuditedSource>)source
                                 error:(NSError **)error {
    if (source == nil ||
        ![(id)source conformsToProtocol:@protocol(MTAuditedSource)] ||
        ![source.inventory isKindOfClass:MTSourceInventory.class]) {
        MTThemeSourceRootSetError(error,
            MTAuditedSourceErrorInvalidRequest,
            @"Theme-root resolution requires an audited source.", nil);
        return nil;
    }
    NSArray<MTSourceFile *> *auditedFiles = source.inventory.files;
    NSMutableArray<MTSourceFile *> *contentFiles =
        [NSMutableArray arrayWithCapacity:auditedFiles.count];
    for (MTSourceFile *file in auditedFiles) {
        if (!MTThemeSourceRootPathIsPackagingArtifact(file.relativePath)) {
            [contentFiles addObject:file];
        }
    }
    if (contentFiles.count == 0) {
        MTThemeSourceRootSetError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The audited source contains no theme files after packaging metadata is ignored.",
            nil);
        return nil;
    }
    NSArray<MTSourceFile *> *files = [contentFiles copy];
    NSDictionary<NSString *, NSString *> *mergedThemePaths =
        MTThemeSourceRootMergedThemePaths(files);
    NSString *prefix = mergedThemePaths == nil
        ? MTThemeSourceRootPrefix(files) : nil;
    NSDictionary<NSString *, NSString *> *classifiedPaths =
        mergedThemePaths == nil
        ? MTThemeSourceRootClassifiedPaths(files, prefix) : nil;
    NSMutableDictionary<NSString *, NSString *> *sourcePaths = nil;
    if (mergedThemePaths != nil) {
        sourcePaths = [mergedThemePaths mutableCopy];
    } else if (classifiedPaths != nil) {
        sourcePaths = [classifiedPaths mutableCopy];
    } else {
        sourcePaths = [NSMutableDictionary dictionaryWithCapacity:files.count];
        for (MTSourceFile *file in files) {
            NSString *logicalPath = file.relativePath;
            if (prefix.length > 0) {
                // Files beside the wrapper are packaging extras, not theme
                // content; leaving them out keeps the root unambiguous.
                logicalPath = MTThemePathRemainderAfterDirectoryPrefix(
                    file.relativePath, prefix);
                if (logicalPath == nil) continue;
            }
            if (logicalPath.length == 0 || sourcePaths[logicalPath] != nil) {
                MTThemeSourceRootSetError(error,
                    MTAuditedSourceErrorCorruptSource,
                    @"The audited source cannot be represented by one logical theme root.",
                    nil);
                return nil;
            }
            sourcePaths[logicalPath] = file.relativePath;
        }
    }

    NSMutableDictionary<NSString *, MTSourceFile *> *filesBySourcePath =
        [NSMutableDictionary dictionaryWithCapacity:files.count];
    for (MTSourceFile *file in files) {
        filesBySourcePath[file.relativePath] = file;
    }
    NSMutableArray<MTSourceFile *> *logicalFiles =
        [NSMutableArray arrayWithCapacity:sourcePaths.count];
    NSArray<NSString *> *logicalPaths = [sourcePaths.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *logicalPath in logicalPaths) {
        MTSourceFile *file = filesBySourcePath[sourcePaths[logicalPath]];
        if (file == nil) {
            MTThemeSourceRootSetError(error,
                MTAuditedSourceErrorCorruptSource,
                @"The logical theme source references a missing audited file.",
                nil);
            return nil;
        }
        [logicalFiles addObject:[[MTSourceFile alloc]
            initWithRelativePath:logicalPath
                       byteCount:file.byteCount
                   contentSHA256:file.contentSHA256
                      prefixData:file.prefixData]];
    }
    NSError *inventoryError = nil;
    MTSourceInventory *inventory = [MTSourceInventory
        inventoryWithFiles:logicalFiles error:&inventoryError];
    if (inventory == nil) {
        MTThemeSourceRootSetError(error,
            MTAuditedSourceErrorCorruptSource,
            @"The logical theme-root inventory is invalid.", inventoryError);
        return nil;
    }
    return [[self alloc] initWithSource:source
                              inventory:inventory
                   sourcePathsByLogicalPath:sourcePaths];
}

- (instancetype)initWithSource:(id<MTAuditedSource>)source
                       inventory:(MTSourceInventory *)inventory
            sourcePathsByLogicalPath:
                (NSDictionary<NSString *, NSString *> *)sourcePathsByLogicalPath {
    self = [super init];
    if (self == nil) return nil;
    _source = source;
    _inventory = inventory;
    _sourcePathsByLogicalPath = [sourcePathsByLogicalPath copy];
    return self;
}

- (NSData *)readFileDataAtRelativePath:(NSString *)relativePath
                       maximumByteCount:(uint64_t)maximumByteCount
                      cancellationToken:
                          (MTImportCancellationToken *)cancellationToken
                                  error:(NSError **)error {
    NSString *sourcePath = self.sourcePathsByLogicalPath[relativePath];
    if (sourcePath == nil) {
        MTThemeSourceRootSetError(error,
            MTAuditedSourceErrorNotInventoried,
            @"The requested path is outside the resolved theme root.", nil);
        return nil;
    }
    return [self.source readFileDataAtRelativePath:sourcePath
                                  maximumByteCount:maximumByteCount
                                 cancellationToken:cancellationToken
                                             error:error];
}

- (BOOL)streamFileAtRelativePath:(NSString *)relativePath
                 maximumByteCount:(uint64_t)maximumByteCount
                cancellationToken:
                    (MTImportCancellationToken *)cancellationToken
                     byteConsumer:(MTAuditedSourceByteConsumer)byteConsumer
                            error:(NSError **)error {
    NSString *sourcePath = self.sourcePathsByLogicalPath[relativePath];
    if (sourcePath == nil) {
        return MTThemeSourceRootSetError(error,
            MTAuditedSourceErrorNotInventoried,
            @"The requested path is outside the resolved theme root.", nil);
    }
    return [self.source streamFileAtRelativePath:sourcePath
                                maximumByteCount:maximumByteCount
                               cancellationToken:cancellationToken
                                    byteConsumer:byteConsumer
                                           error:error];
}

@end
