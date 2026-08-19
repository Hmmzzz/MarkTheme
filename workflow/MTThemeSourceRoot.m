#import "MTThemeSourceRoot.h"

#import "MTSourceInventory.h"

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
            if ([file.relativePath hasPrefix:resourcePrefix] &&
                file.relativePath.length > resourcePrefix.length) {
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
    NSString *wrapper = nil;
    for (MTSourceFile *file in files) {
        NSRange separator = [file.relativePath rangeOfString:@"/"];
        if (separator.location == NSNotFound || separator.location == 0) {
            return @"";
        }
        NSString *candidate = [file.relativePath
            substringToIndex:separator.location + 1];
        if (wrapper == nil) {
            wrapper = candidate;
        } else if (![wrapper isEqualToString:candidate]) {
            return @"";
        }
    }
    if (wrapper == nil ||
        !MTThemeSourceRootContainsResourceTree(files, wrapper)) {
        return @"";
    }
    return wrapper;
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
    NSMutableDictionary<NSString *, NSString *> *sourcePaths =
        mergedThemePaths == nil
        ? [NSMutableDictionary dictionaryWithCapacity:files.count]
        : [mergedThemePaths mutableCopy];
    if (mergedThemePaths == nil) {
        for (MTSourceFile *file in files) {
            NSString *logicalPath = prefix.length == 0
                ? file.relativePath
                : [file.relativePath substringFromIndex:prefix.length];
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
