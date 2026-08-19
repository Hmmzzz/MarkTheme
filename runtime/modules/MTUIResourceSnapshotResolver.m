#import "MTUIResourceSnapshotResolver.h"

#import "MTGenerationReader.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"

@interface MTUIResourceSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTUIResourceSnapshotResolution

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

@interface MTUIResourceSnapshotResolver ()
@property(nonatomic, copy) MTUIResourceSnapshotProvider snapshotProvider;
@end

@implementation MTUIResourceSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTUIResourceSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (MTUIResourceSnapshotResolution *)resolutionForSurface:(NSString *)surface
                                             resourceName:(NSString *)resourceName
                                                    scale:(NSUInteger)scale
                                                    error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (![resourceName isKindOfClass:NSString.class] ||
        resourceName.length == 0 || scale > 3) {
        return nil;
    }
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    NSUInteger scales[2] = { scale, 0 };
    NSUInteger scaleCount = scale == 0 ? 1 : 2;
    for (NSUInteger scaleIndex = 0;
         scaleIndex < scaleCount; scaleIndex++) {
        for (NSString *trait in @[@"iphone", @"any"]) {
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:@"ui.resources"
                         surface:surface
                         subject:resourceName
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
                return [[MTUIResourceSnapshotResolution alloc]
                    initWithGenerationIdentifier:
                        generation.generationIdentifier
                    canonicalResourceKey:key.canonicalString
                    generation:generation
                    resource:resource];
            }
        }
    }
    return nil;
}

- (MTUIResourceSnapshotResolution *)
    resolutionForPreferencesIconName:(NSString *)resourceName
                               scale:(NSUInteger)scale
                               error:(NSError **)error {
    return [self resolutionForSurface:@"preferences.icon"
                         resourceName:resourceName
                                scale:scale
                                error:error];
}

- (MTUIResourceSnapshotResolution *)
    resolutionForShareActivityName:(NSString *)activityName
                              scale:(NSUInteger)scale
                              error:(NSError **)error {
    return [self resolutionForSurface:@"share.activity"
                         resourceName:activityName
                                scale:scale
                                error:error];
}

@end
