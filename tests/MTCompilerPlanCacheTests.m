#import "MTCompilerPlanCacheTests.h"
#import <sys/stat.h>
#import "MTStaticIconCompiler.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeMixSelection.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeLibraryStoreInternal.h"
#import "MTThemeManifest.h"
#import "MTThemeCapabilityReport.h"
#import "MTImportSession.h"
#import "MTResourceKey.h"

@interface MTStaticIconCompiler (MTCompilerPlanCacheTests)
- (NSDictionary<NSString *, NSNumber *> *)sourcePlanCacheStatistics;
@end

static NSUInteger MTCompilerPlanAssertions;
static void MTCompilerPlanAssert(BOOL condition, NSString *message) {
    MTCompilerPlanAssertions++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static MTThemeMixSelection *MTCompilerPlanMix(MTThemeLibraryRevision *revision) {
    MTThemeComponentCatalog *catalog = [MTThemeComponentCatalog catalogForManifest:revision.manifest error:NULL];
    return [MTThemeMixSelection selectionWithBaseThemeIdentifier:revision.manifest.themeID
        sourceThemeIdentifiersByFeature:@{} disabledFeatureIdentifiers:@[]
        revisionIdentifiersByThemeIdentifier:@{ revision.manifest.themeID : revision.revisionIdentifier }
        componentSelectionsByThemeIdentifier:@{ revision.manifest.themeID : catalog.defaultSelection }
        error:NULL];
}

static MTThemeLibraryRevision *MTCompilerPlanRevision(MTThemeLibraryRevision *source,
    NSString *name, NSArray<MTThemeResource *> *resources) {
    MTThemeManifest *original = source.manifest;
    MTThemeManifest *manifest = [[MTThemeManifest alloc] initWithThemeID:original.themeID
        displayName:name author:original.author themeVersion:original.themeVersion
        importerID:original.importerID importerVersion:original.importerVersion
        sourceFingerprint:original.sourceFingerprint capabilities:original.capabilities
        moduleConfigurations:original.moduleConfigurations resources:resources error:NULL];
    NSString *digest = [manifest contentDigestWithError:NULL];
    MTCompilerPlanAssert(digest != nil, @"Changed plan fixture must have a valid immutable Manifest");
    return [[MTThemeLibraryRevision alloc] initWithRevisionIdentifier:[@"r1-" stringByAppendingString:digest]
        manifestDigest:digest manifest:manifest assetURLsByContentSHA256:source.assetURLsByContentSHA256
        assetByteCountsByContentSHA256:source.assetByteCountsByContentSHA256
        resourcesDirectoryURL:nil assetByteCount:source.assetByteCount];
}

NSUInteger MTRunCompilerPlanCacheTests(MTThemeLibraryRevision *revision) {
    MTCompilerPlanAssertions = 0;
    MTStaticIconCompiler *compiler = MTStaticIconCompiler.defaultCompiler;
    MTThemeMixSelection *mix = MTCompilerPlanMix(revision);
    NSDictionary *revisions = @{ revision.manifest.themeID : revision };
    NSError *error = nil;
    MTCompiledGeneration *cold = [compiler compileLibraryRevisionsByThemeIdentifier:revisions
        mixSelection:mix cancellationToken:nil error:&error];
    MTCompiledGeneration *warm = [compiler compileLibraryRevisionsByThemeIdentifier:revisions
        mixSelection:mix cancellationToken:nil error:&error];
    NSDictionary *stats = [compiler sourcePlanCacheStatistics];
    MTCompilerPlanAssert(cold != nil && warm != nil && error == nil &&
        [cold.descriptor.canonicalData isEqual:warm.descriptor.canonicalData] &&
        [cold.index.encodedData isEqual:warm.index.encodedData] &&
        [stats[@"builds"] unsignedIntegerValue] == 1 && [stats[@"hits"] unsignedIntegerValue] == 1,
        @"Warm mix compilation must reuse one source plan and preserve exact Generation bytes");

    MTThemeMixSelection *disabled = [mix selectionBySettingFeatureIdentifier:MTThemeFeatureSettingsIcons
        enabled:NO error:&error];
    MTCompiledGeneration *changed = [compiler compileLibraryRevisionsByThemeIdentifier:revisions
        mixSelection:disabled cancellationToken:nil error:&error];
    MTCompiledGeneration *freshChanged = [MTStaticIconCompiler.defaultCompiler
        compileLibraryRevisionsByThemeIdentifier:revisions mixSelection:disabled cancellationToken:nil error:&error];
    stats = [compiler sourcePlanCacheStatistics];
    MTCompilerPlanAssert(changed != nil && freshChanged != nil && error == nil &&
        [changed.descriptor.canonicalData isEqual:freshChanged.descriptor.canonicalData] &&
        [changed.index.encodedData isEqual:freshChanged.index.encodedData] &&
        ![cold.descriptor.canonicalData isEqual:changed.descriptor.canonicalData] &&
        [stats[@"builds"] unsignedIntegerValue] == 1 && [stats[@"hits"] unsignedIntegerValue] == 2,
        @"Changing a feature must reuse source projection without reusing a stale composed Generation");

    MTImportCancellationToken *cancelled = [[MTImportCancellationToken alloc] init];
    [cancelled cancel];
    error = nil;
    MTCompilerPlanAssert([compiler compileLibraryRevisionsByThemeIdentifier:revisions mixSelection:mix
        cancellationToken:cancelled error:&error] == nil &&
        [error.domain isEqualToString:MTStaticIconCompilerErrorDomain] &&
        error.code == MTStaticIconCompilerErrorCancelled,
        @"A warm plan must not bypass compilation cancellation");

    // A cache hit must resolve current asset URLs and revalidate their bytes.
    NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"marktheme-plan-" stringByAppendingString:NSUUID.UUID.UUIDString]]
        isDirectory:YES];
    error = nil;
    MTCompilerPlanAssert([NSFileManager.defaultManager createDirectoryAtURL:temporary
        withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error],
        @"Plan-cache asset relocation fixture must be created");
    NSMutableDictionary *relocatedURLs = [NSMutableDictionary dictionary];
    for (NSString *digest in revision.assetURLsByContentSHA256) {
        NSURL *target = [temporary URLByAppendingPathComponent:digest];
        MTCompilerPlanAssert([NSFileManager.defaultManager copyItemAtURL:revision.assetURLsByContentSHA256[digest]
            toURL:target error:&error] && chmod(target.fileSystemRepresentation, 0600) == 0,
            @"Plan-cache fixture must copy current assets");
        relocatedURLs[digest] = target;
    }
    MTThemeLibraryRevision *relocated = [[MTThemeLibraryRevision alloc]
        initWithRevisionIdentifier:revision.revisionIdentifier manifestDigest:revision.manifestDigest
        manifest:revision.manifest assetURLsByContentSHA256:relocatedURLs
        assetByteCountsByContentSHA256:revision.assetByteCountsByContentSHA256
        resourcesDirectoryURL:nil assetByteCount:revision.assetByteCount];
    NSDictionary *relocatedRevisions = @{revision.manifest.themeID : relocated};
    error = nil;
    MTCompiledGeneration *moved = [compiler compileLibraryRevisionsByThemeIdentifier:relocatedRevisions
        mixSelection:mix cancellationToken:nil error:&error];
    MTCompilerPlanAssert(moved != nil && error == nil &&
        [moved.descriptor.canonicalData isEqual:cold.descriptor.canonicalData] &&
        [moved.sourceAssetURLsByContentSHA256 isEqual:relocatedURLs],
        @"Source plans must never retain stale Library asset URLs");
    NSURL *selectedURL = moved.sourceAssetURLsByContentSHA256.allValues.firstObject;
    NSMutableData *corrupted = [[NSData dataWithContentsOfURL:selectedURL] mutableCopy];
    MTCompilerPlanAssert(corrupted.length > 16, @"Integrity fixture must contain a selected PNG");
    ((uint8_t *)corrupted.mutableBytes)[16] ^= 0x01;
    MTCompilerPlanAssert([corrupted writeToURL:selectedURL options:0 error:&error],
        @"Integrity fixture must mutate bytes without changing the expected asset identity");
    error = nil;
    MTCompilerPlanAssert([compiler compileLibraryRevisionsByThemeIdentifier:relocatedRevisions mixSelection:mix
        cancellationToken:nil error:&error] == nil && error != nil,
        @"Warm source plans must still reject tampered asset bytes");
    MTCompilerPlanAssert([NSFileManager.defaultManager removeItemAtURL:temporary error:NULL],
        @"Plan-cache fixture must clean up its private files");

    error = nil;
    MTThemeLibraryRevision *newRevision = MTCompilerPlanRevision(revision, @"Updated plan source", revision.manifest.resources);
    MTCompiledGeneration *updated = [compiler compileLibraryRevisionsByThemeIdentifier:
        @{newRevision.manifest.themeID:newRevision} mixSelection:MTCompilerPlanMix(newRevision)
        cancellationToken:nil error:&error];
    stats = [compiler sourcePlanCacheStatistics];
    MTCompilerPlanAssert(updated != nil && error == nil && [stats[@"builds"] unsignedIntegerValue] == 2 &&
        ![updated.descriptor.canonicalData isEqual:cold.descriptor.canonicalData],
        @"A changed source revision must build a distinct plan and Generation");

    // A large metadata corpus shares verified fixture PNGs. Its warm path must
    // skip projection work, without a timing threshold tied to host load.
    NSMutableArray *largeResources = [revision.manifest.resources mutableCopy];
    MTThemeResource *example = revision.manifest.resources.firstObject;
    for (NSUInteger index = 0; index < 1024; index++) {
        NSString *subject = [NSString stringWithFormat:@"com.hmmzzz.plan.app%04lu", (unsigned long)index];
        MTResourceKey *key = [[MTResourceKey alloc] initWithModuleID:@"icons.static"
            surface:@"springboard.home" subject:subject variant:@"primary" scale:3 trait:@"iphone" error:NULL];
        MTThemeResource *resource = [[MTThemeResource alloc] initWithResourceKey:key
            relativeAssetPath:[NSString stringWithFormat:@"IconBundles/%@@3x.png", subject]
            contentSHA256:example.contentSHA256 sourceFormat:example.sourceFormat matchRank:example.matchRank error:NULL];
        if (resource == nil) MTCompilerPlanAssert(NO, @"Large plan corpus resource must be valid");
        [largeResources addObject:resource];
    }
    MTCompilerPlanAssert(largeResources.count == revision.manifest.resources.count + 1024,
        @"Large plan corpus must exercise at least a thousand resources");
    MTThemeLibraryRevision *large = MTCompilerPlanRevision(revision, @"Large plan source", largeResources);
    MTStaticIconCompiler *largeCompiler = MTStaticIconCompiler.defaultCompiler;
    MTThemeMixSelection *largeMix = MTCompilerPlanMix(large);
    NSDictionary *largeMap = @{large.manifest.themeID:large};
    MTCompiledGeneration *largeCold = [largeCompiler compileLibraryRevisionsByThemeIdentifier:largeMap
        mixSelection:largeMix cancellationToken:nil error:&error];
    MTCompiledGeneration *largeWarm = [largeCompiler compileLibraryRevisionsByThemeIdentifier:largeMap
        mixSelection:largeMix cancellationToken:nil error:&error];
    MTCompiledGeneration *largeChanged = [largeCompiler compileLibraryRevisionsByThemeIdentifier:largeMap
        mixSelection:[largeMix selectionBySettingFeatureIdentifier:MTThemeFeatureSettingsIcons enabled:NO error:&error]
        cancellationToken:nil error:&error];
    stats = [largeCompiler sourcePlanCacheStatistics];
    MTCompilerPlanAssert(largeCold != nil && largeWarm != nil && largeChanged != nil && error == nil &&
        [largeCold.descriptor.canonicalData isEqual:largeWarm.descriptor.canonicalData] &&
        [largeCold.index.encodedData isEqual:largeWarm.index.encodedData] &&
        [stats[@"builds"] unsignedIntegerValue] == 1 && [stats[@"hits"] unsignedIntegerValue] == 2,
        @"Large repeated and feature-only mixes must project source metadata once");
    printf("PLAN-CACHE: %lu resources, 3 compiles, %lu source-plan build, %lu cache hits\n",
        (unsigned long)largeResources.count, (unsigned long)[stats[@"builds"] unsignedIntegerValue],
        (unsigned long)[stats[@"hits"] unsignedIntegerValue]);

    for (NSUInteger index = 0; index < 9; index++) {
        MTThemeLibraryRevision *variant = MTCompilerPlanRevision(revision,
            [NSString stringWithFormat:@"Eviction %lu", (unsigned long)index], revision.manifest.resources);
        MTCompilerPlanAssert([compiler compileLibraryRevisionsByThemeIdentifier:@{variant.manifest.themeID:variant}
            mixSelection:MTCompilerPlanMix(variant) cancellationToken:nil error:&error] != nil && error == nil,
            @"Bounded cache eviction must preserve ordinary compilation");
    }
    stats = [compiler sourcePlanCacheStatistics];
    MTCompilerPlanAssert([stats[@"plans"] unsignedIntegerValue] <= 8 &&
        [stats[@"resourceReferences"] unsignedIntegerValue] <= 32768,
        @"Plan metadata retention must obey hard entry and resource-reference bounds");
    return MTCompilerPlanAssertions;
}
