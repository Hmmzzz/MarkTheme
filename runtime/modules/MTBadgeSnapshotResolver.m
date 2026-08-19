#import "MTBadgeSnapshotResolver.h"

#import <dispatch/dispatch.h>

#import "MTBadgeContract.h"
#import "MTGenerationReader.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"

@interface MTBadgeSnapshotContext ()
- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait;
@end

@implementation MTBadgeSnapshotContext

+ (instancetype)contextWithScale:(NSUInteger)scale
                     deviceTrait:(nullable NSString *)deviceTrait {
    if (scale < 1 || scale > 3 ||
        (![deviceTrait isEqualToString:@"iphone"] &&
         ![deviceTrait isEqualToString:@"ipad"])) {
        return nil;
    }
    static NSArray<MTBadgeSnapshotContext *> *contexts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<MTBadgeSnapshotContext *> *values =
            [NSMutableArray arrayWithCapacity:6];
        for (NSString *trait in @[ @"iphone", @"ipad" ]) {
            for (NSUInteger candidateScale = 1;
                 candidateScale <= 3; candidateScale++) {
                [values addObject:[[self alloc]
                    initWithScale:candidateScale deviceTrait:trait]];
            }
        }
        contexts = [values copy];
    });
    NSUInteger deviceOffset = [deviceTrait isEqualToString:@"ipad"] ? 3 : 0;
    return contexts[deviceOffset + scale - 1];
}

- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait {
    self = [super init];
    if (self == nil) return nil;
    _scale = scale;
    _deviceTrait = [deviceTrait copy];
    _cacheKey = [NSString stringWithFormat:@"badge-background/%@/%lu",
        _deviceTrait, (unsigned long)_scale];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:MTBadgeSnapshotContext.class]) return NO;
    MTBadgeSnapshotContext *other = object;
    return self.scale == other.scale &&
        [self.deviceTrait isEqualToString:other.deviceTrait];
}

- (NSUInteger)hash {
    return self.cacheKey.hash;
}

@end

@interface MTBadgeSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTBadgeSnapshotResolution

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

@interface MTBadgeSnapshotResolver ()
@property(nonatomic, copy) MTBadgeSnapshotProvider snapshotProvider;
@end

@implementation MTBadgeSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTBadgeSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (MTBadgeSnapshotResolution *)
    resolutionForVariant:(NSString *)variant
                    scale:(NSUInteger)scale
              deviceTrait:(NSString *)deviceTrait
               appearance:(NSString *)appearance
                    error:(NSError **)error {
    if (error != NULL) *error = nil;
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    NSArray<NSString *> *traits = MTBadgeResourceTraitCandidates(
        deviceTrait, appearance);
    if (traits.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTResourceKeyErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Badge device or appearance trait is unsupported."
            }];
        }
        return nil;
    }

    NSUInteger scales[2] = { scale, 0 };
    NSUInteger scaleCount = scale == 0 ? 1 : 2;
    for (NSUInteger scaleIndex = 0;
         scaleIndex < scaleCount; scaleIndex++) {
        for (NSString *trait in traits) {
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:MTBadgesModuleID
                         surface:MTBadgeSurface
                         subject:MTBadgeGlobalSubject
                         variant:variant
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
                return [[MTBadgeSnapshotResolution alloc]
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

@end
