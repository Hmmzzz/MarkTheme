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

- (MTStaticIconSnapshotResolution *)
    resolutionForBundleIdentifier:(NSString *)bundleIdentifier
                            scale:(NSUInteger)scale
                            error:(NSError **)error {
    if (error != NULL) *error = nil;
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

    for (NSString *subject in subjects) {
        NSUInteger scales[2] = { scale, 0 };
        NSUInteger scaleCount = scale == 0 ? 1 : 2;
        for (NSUInteger scaleIndex = 0;
             scaleIndex < scaleCount; scaleIndex++) {
            for (NSString *trait in @[@"iphone", @"any"]) {
                NSError *keyError = nil;
                MTResourceKey *key = [[MTResourceKey alloc]
                    initWithModuleID:@"icons.static"
                             surface:@"springboard.home"
                             subject:subject
                             variant:@"primary"
                               scale:scales[scaleIndex]
                               trait:trait
                               error:&keyError];
                if (key == nil) {
                    if (error != NULL) *error = keyError;
                    return nil;
                }
                NSError *lookupError = nil;
                MTGenerationResource *resource = [generation
                    resourceForCanonicalResourceKey:key.canonicalString
                    error:&lookupError];
                if (lookupError != nil) {
                    if (error != NULL) *error = lookupError;
                    return nil;
                }
                if (resource != nil) {
                    return [[MTStaticIconSnapshotResolution alloc]
                        initWithGenerationIdentifier:
                            generation.generationIdentifier
                        canonicalResourceKey:key.canonicalString
                        generation:generation
                        resource:resource];
                }
            }
        }
    }
    return nil;
}

@end
