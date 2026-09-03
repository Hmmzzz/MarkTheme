#import "MTBootstrapPaths.h"

#import <TargetConditionals.h>

#if !defined(MT_HOST_TESTING) && !TARGET_OS_SIMULATOR
#import <roothide.h>
#endif

NSString *const MTRuntimeStoreLogicalPath =
    @"/var/lib/marktheme";
NSString *const MTGenerationStoreLogicalPath =
    @"/var/lib/marktheme/generations";
NSString *const MTRuntimeStateLogicalPath =
    @"/var/lib/marktheme/state";
NSString *const MTGenerationInboxLogicalPath =
    @"/var/mobile/Library/Application Support/MarkTheme/PublishInbox";
NSString *const MTManagerDataRootLogicalPath =
    @"/var/mobile/Library/Application Support/MarkTheme";
NSString *const MTRuntimeHelperLogicalPath =
    @"/usr/libexec/marktheme-helper";
NSString *const MTDiagnosticsLogicalPath =
    @"/var/mobile/Library/Application Support/MarkTheme/Diagnostics";
NSString *const MTDesktopReloadExecutableLogicalPath =
    @"/usr/bin/sbreload";
NSString *const MTServiceControlExecutableLogicalPath =
    @"/usr/bin/launchctl";
NSString *const MTBootstrapPathsErrorDomain = @"com.hmmzzz.marktheme.bootstrap-paths";

NSString *MTPackageSchemeName(MTPackageScheme scheme) {
    switch (scheme) {
        case MTPackageSchemeHost:
            return @"host";
        case MTPackageSchemeRootless:
            return @"rootless";
        case MTPackageSchemeRootHide:
            return @"roothide";
    }
    return @"invalid";
}

NSURL *MTDefaultManagerDataRootURL(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    return applicationSupport == nil ? nil : [applicationSupport
        URLByAppendingPathComponent:@"MarkTheme" isDirectory:YES];
#else
    NSError *error = nil;
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTManagerDataRootLogicalPath error:&error];
    return path == nil ? nil : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

NSURL *MTDefaultRuntimeStoreURL(NSError **error) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    if (applicationSupport == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Application Support is unavailable for Runtime data."
            }];
        }
        return nil;
    }
    return [[applicationSupport
        URLByAppendingPathComponent:@"MarkTheme" isDirectory:YES]
        URLByAppendingPathComponent:@"Runtime" isDirectory:YES];
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTRuntimeStoreLogicalPath error:error];
    return path == nil ? nil
        : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

NSURL *MTDefaultGenerationInboxURL(NSError **error) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    if (applicationSupport == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Application Support is unavailable for Generation publication."
            }];
        }
        return nil;
    }
    return [[applicationSupport
        URLByAppendingPathComponent:@"MarkTheme" isDirectory:YES]
        URLByAppendingPathComponent:@"PublishInbox" isDirectory:YES];
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTGenerationInboxLogicalPath error:error];
    return path == nil ? nil
        : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

NSURL *MTDefaultRuntimeHelperURL(NSError **error) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                     code:3
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"The Runtime Helper is unavailable outside a jailbreak package."
        }];
    }
    return nil;
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTRuntimeHelperLogicalPath error:error];
    return path == nil ? nil : [NSURL fileURLWithPath:path isDirectory:NO];
#endif
}

NSURL *MTDefaultDiagnosticsURL(NSError **error) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    if (applicationSupport == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Application Support is unavailable for diagnostics."
            }];
        }
        return nil;
    }
    return [[applicationSupport
        URLByAppendingPathComponent:@"MarkTheme" isDirectory:YES]
        URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTDiagnosticsLogicalPath error:error];
    return path == nil ? nil
        : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

static BOOL MTLogicalBootstrapPathIsValid(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length < 2 ||
        ![path hasPrefix:@"/"] || [path hasSuffix:@"/"] ||
        [path containsString:@"//"] || [path containsString:@"\\"] ||
        [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) {
        return NO;
    }
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    for (NSUInteger index = 1; index < components.count; index++) {
        NSString *component = components[index];
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."]) {
            return NO;
        }
        for (NSUInteger offset = 0; offset < component.length; offset++) {
            unichar character = [component characterAtIndex:offset];
            if (character == 0 || character < 0x20 || character == 0x7f) {
                return NO;
            }
        }
    }
    return YES;
}

@interface MTBootstrapPathResolver ()
@property(nonatomic, assign) BOOL usesSyntheticPrefix;
@property(nonatomic, copy) NSString *syntheticPrefix;
- (instancetype)initWithScheme:(MTPackageScheme)scheme
             usesSyntheticPrefix:(BOOL)usesSyntheticPrefix
                 syntheticPrefix:(NSString *)syntheticPrefix;
@end

@implementation MTBootstrapPathResolver

- (instancetype)initWithScheme:(MTPackageScheme)scheme
             usesSyntheticPrefix:(BOOL)usesSyntheticPrefix
                 syntheticPrefix:(NSString *)syntheticPrefix {
    self = [super init];
    if (self == nil) return nil;
    _scheme = scheme;
    _usesSyntheticPrefix = usesSyntheticPrefix;
    _syntheticPrefix = [syntheticPrefix copy];
    return self;
}

+ (instancetype)currentResolver {
#if defined(MT_HOST_TESTING)
    return [[self alloc] initWithScheme:MTPackageSchemeHost
                   usesSyntheticPrefix:YES
                       syntheticPrefix:@""];
#elif TARGET_OS_SIMULATOR
    return [[self alloc] initWithScheme:MTPackageSchemeHost
                   usesSyntheticPrefix:YES
                       syntheticPrefix:@""];
#elif defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    return [[self alloc] initWithScheme:MTPackageSchemeRootHide
                   usesSyntheticPrefix:NO
                       syntheticPrefix:@""];
#else
    return [[self alloc] initWithScheme:MTPackageSchemeRootless
                   usesSyntheticPrefix:NO
                       syntheticPrefix:@""];
#endif
}

+ (instancetype)resolverForTestingScheme:(MTPackageScheme)scheme
                           physicalPrefix:(NSString *)physicalPrefix {
    return [[self alloc] initWithScheme:scheme
                   usesSyntheticPrefix:YES
                       syntheticPrefix:physicalPrefix ?: @""];
}

- (NSString *)resolvedPathForLogicalPath:(NSString *)logicalPath
                                    error:(NSError **)error {
    if (!MTLogicalBootstrapPathIsValid(logicalPath)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Bootstrap path must be a normalized absolute logical path."
            }];
        }
        return nil;
    }

    if (self.usesSyntheticPrefix) {
        NSString *prefix = self.syntheticPrefix;
        while (prefix.length > 1 && [prefix hasSuffix:@"/"]) {
            prefix = [prefix substringToIndex:prefix.length - 1];
        }
        return prefix.length == 0 || [prefix isEqualToString:@"/"]
            ? logicalPath
            : [prefix stringByAppendingString:logicalPath];
    }

#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    return logicalPath;
#else
    // RootHide's jbroot API is deliberately evaluated at the point of use.
    // The physical jailbreak root is randomized and can change after a new
    // jailbreak, so never cache or persist the resolved physical path.
    const char *resolved = jbroot(logicalPath.UTF8String);
    if (resolved == NULL || resolved[0] == '\0') {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTBootstrapPathsErrorDomain
                                         code:4
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"RootHide could not resolve a jailbreak path."
            }];
        }
        return nil;
    }
    return [NSString stringWithUTF8String:resolved];
#endif
}

@end
