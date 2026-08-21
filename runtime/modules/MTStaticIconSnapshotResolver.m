#import "MTStaticIconSnapshotResolver.h"

#import "MTGenerationReader.h"
#import "MTGenerationDescriptor.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"
#import "MTStaticIconConfiguration.h"

@interface MTStaticIconSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTStaticIconSnapshotResolution

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _canonicalResourceKey = [canonicalResourceKey copy];
    _generation = generation;
    _resource = resource;
    return self;
}

@end

@interface MTStaticIconSnapshotResolver ()
@property(nonatomic, copy) MTRuntimeSnapshotProvider snapshotProvider;
@end

@implementation MTStaticIconSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTRuntimeSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (NSArray<NSDictionary<NSString *, id> *> *)sourceCandidatesForScale:
    (NSUInteger)scale deviceTrait:(NSString *)deviceTrait {
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    void (^append)(NSString *, NSUInteger, NSString *) =
        ^(NSString *variant, NSUInteger candidateScale, NSString *trait) {
            [candidates addObject:@{
                @"variant" : variant,
                @"scale" : @(candidateScale),
                @"trait" : trait,
            }];
        };

    // Modern SnowBoard themes treat -large as one universal authoring canvas.
    append(MTStaticIconSourceVariantLarge, 0, @"any");

    NSMutableArray<NSNumber *> *scales = [NSMutableArray array];
    if (scale >= 1 && scale <= 3) [scales addObject:@(scale)];
    // Prefer a higher-resolution alternate before accepting an upscale; then
    // retain lower-resolution sources as a compatibility fallback.
    for (NSUInteger candidate = scale + 1; candidate <= 3; candidate++) {
        [scales addObject:@(candidate)];
    }
    if (scale > 1) {
        for (NSUInteger candidate = scale - 1; candidate >= 1; candidate--) {
            [scales addObject:@(candidate)];
            if (candidate == 1) break;
        }
    }
    if (scales.count == 0) [scales addObjectsFromArray:@[@3, @2, @1]];

    BOOL firstScale = YES;
    for (NSNumber *scaleNumber in scales) {
        NSUInteger candidateScale = scaleNumber.unsignedIntegerValue;
        append(MTStaticIconSourceVariantDeviceScale,
               candidateScale, deviceTrait);
        append(MTStaticIconSourceVariantScaleDevice,
               candidateScale, deviceTrait);
        append(MTStaticIconSourceVariantScale,
               candidateScale, @"any");
        if (firstScale) {
            append(MTStaticIconSourceVariantDevice, 0, deviceTrait);
            firstScale = NO;
        }
    }
    append(MTStaticIconSourceVariantPlain, 0, @"any");

    // WinterBoard bundle icons are less specific than a flat IconBundles
    // source, but retain their authored scale/device forms.
    for (NSNumber *scaleNumber in scales) {
        NSUInteger candidateScale = scaleNumber.unsignedIntegerValue;
        append(MTStaticIconSourceVariantBundleIcon,
               candidateScale, deviceTrait);
        append(MTStaticIconSourceVariantBundleIcon,
               candidateScale, @"any");
    }
    append(MTStaticIconSourceVariantBundleIcon, 0, deviceTrait);
    append(MTStaticIconSourceVariantBundleIcon, 0, @"any");

    // Published Generations from earlier MarkTheme64e versions collapsed every
    // source family into "primary". Keep their exact-then-universal lookup.
    if (scale <= 3) {
        append(MTStaticIconSourceVariantPrimary, scale, deviceTrait);
        append(MTStaticIconSourceVariantPrimary, scale, @"any");
    }
    append(MTStaticIconSourceVariantPrimary, 0, deviceTrait);
    append(MTStaticIconSourceVariantPrimary, 0, @"any");
    return candidates;
}

- (NSArray<MTStaticIconSnapshotResolution *> *)
    resolutionsForBundleIdentifier:(NSString *)bundleIdentifier
                              scale:(NSUInteger)scale
                        deviceTrait:(NSString *)deviceTrait
                              error:(NSError **)error {
    if (error != NULL) *error = nil;
    NSError *validationError = nil;
    MTResourceKey *validationKey = [[MTResourceKey alloc]
        initWithModuleID:@"icons.static"
                 surface:@"springboard.home"
                 subject:bundleIdentifier
                 variant:MTStaticIconSourceVariantPrimary
                   scale:scale
                   trait:@"any"
                   error:&validationError];
    if (validationKey == nil) {
        if (error != NULL) *error = validationError;
        return nil;
    }
    if (!([deviceTrait isEqualToString:@"iphone"] ||
          [deviceTrait isEqualToString:@"ipad"])) {
        return nil;
    }
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    NSMutableArray<NSString *> *subjects = [NSMutableArray
        arrayWithObject:bundleIdentifier];
    MTGenerationDescriptor *descriptor = generation.descriptor;
    NSDictionary *configurationDictionary =
        descriptor.moduleConfigurations[@"icons.static"];
    if (configurationDictionary != nil) {
        MTStaticIconConfiguration *configuration =
            [[MTStaticIconConfiguration alloc]
                initWithDictionary:configurationDictionary error:NULL];
        for (NSString *fallback in [configuration
                themedBundleIdentifierCandidatesForRequestedIdentifier:
                    bundleIdentifier]) {
            if (fallback.length > 0 &&
                ![subjects containsObject:fallback]) {
                [subjects addObject:fallback];
            }
        }
    }

    NSArray<NSDictionary<NSString *, id> *> *candidates =
        [self sourceCandidatesForScale:scale deviceTrait:deviceTrait];
    NSMutableArray<MTStaticIconSnapshotResolution *> *resolutions =
        [NSMutableArray array];
    NSMutableSet<NSString *> *visitedKeys = [NSMutableSet set];
    for (NSString *subject in subjects) {
        for (NSDictionary<NSString *, id> *candidate in candidates) {
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:@"icons.static"
                         surface:@"springboard.home"
                         subject:subject
                         variant:candidate[@"variant"]
                           scale:[candidate[@"scale"] unsignedIntegerValue]
                           trait:candidate[@"trait"]
                           error:&keyError];
            if (key == nil) {
                if (error != NULL) *error = keyError;
                return nil;
            }
            if ([visitedKeys containsObject:key.canonicalString]) continue;
            [visitedKeys addObject:key.canonicalString];
            NSError *lookupError = nil;
            MTGenerationResource *resource = [generation
                resourceForCanonicalResourceKey:key.canonicalString
                error:&lookupError];
            if (lookupError != nil) {
                if (error != NULL) *error = lookupError;
                return nil;
            }
            if (resource != nil) {
                [resolutions addObject:[[MTStaticIconSnapshotResolution alloc]
                    initWithGenerationIdentifier:
                        generation.generationIdentifier
                    canonicalResourceKey:key.canonicalString
                    generation:generation
                    resource:resource]];
            }
        }
    }
    return resolutions.count == 0 ? nil : [resolutions copy];
}

- (MTStaticIconSnapshotResolution *)
    resolutionForBundleIdentifier:(NSString *)bundleIdentifier
                            scale:(NSUInteger)scale
                            error:(NSError **)error {
    return [self resolutionsForBundleIdentifier:bundleIdentifier
                                          scale:scale
                                    deviceTrait:@"iphone"
                                          error:error].firstObject;
}

@end
