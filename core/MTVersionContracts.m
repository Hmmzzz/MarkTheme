#import "MTVersionContracts.h"

NSString *const MTThemeManifestVersionKey = @"themeManifest";
NSString *const MTNormalizedModelVersionKey = @"normalizedModel";
NSString *const MTCompilerVersionKey = @"compiler";
NSString *const MTRuntimeSnapshotVersionKey = @"runtimeSnapshot";
NSString *const MTModuleAPIVersionKey = @"moduleAPI";

NSUInteger const MTThemeManifestVersion = 2;
NSUInteger const MTNormalizedModelVersion = 2;
NSUInteger const MTCompilerVersion = 2;
NSUInteger const MTRuntimeSnapshotVersion = 1;
NSUInteger const MTModuleAPIVersion = 1;

NSString *const MTVersionContractsErrorDomain =
    @"com.hmmzzz.marktheme.version-contracts";

NSDictionary<NSString *, NSNumber *> *MTCurrentContractVersions(void) {
    static NSDictionary<NSString *, NSNumber *> *versions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        versions = @{
            MTThemeManifestVersionKey : @(MTThemeManifestVersion),
            MTNormalizedModelVersionKey : @(MTNormalizedModelVersion),
            MTCompilerVersionKey : @(MTCompilerVersion),
            MTRuntimeSnapshotVersionKey : @(MTRuntimeSnapshotVersion),
            MTModuleAPIVersionKey : @(MTModuleAPIVersion),
        };
    });
    return versions;
}

BOOL MTContractVersionsAreSupported(NSDictionary<NSString *, id> *versions,
                                    NSError **error) {
    if (![versions isKindOfClass:NSDictionary.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTVersionContractsErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Contract versions must be a dictionary."
            }];
        }
        return NO;
    }

    NSDictionary<NSString *, NSNumber *> *current = MTCurrentContractVersions();
    for (NSString *key in current) {
        id candidate = versions[key];
        NSNumber *expected = current[key];
        BOOL numeric = [candidate isKindOfClass:NSNumber.class];
        BOOL integral = numeric &&
            [candidate doubleValue] == (double)[candidate unsignedIntegerValue];
        if (!integral || [candidate unsignedIntegerValue] != expected.unsignedIntegerValue) {
            if (error != NULL) {
                NSString *description = [NSString stringWithFormat:
                    @"Unsupported or missing %@ contract version.", key];
                *error = [NSError errorWithDomain:MTVersionContractsErrorDomain
                                             code:2
                                         userInfo:@{
                    NSLocalizedDescriptionKey : description,
                    @"contract" : key,
                    @"expected" : expected,
                    @"actual" : candidate ?: NSNull.null,
                }];
            }
            return NO;
        }
    }
    return YES;
}
