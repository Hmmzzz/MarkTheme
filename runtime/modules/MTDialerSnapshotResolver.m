#import "MTDialerSnapshotResolver.h"

#import <dispatch/dispatch.h>

#import "MTDialerContract.h"
#import "MTGenerationReader.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"

@interface MTDialerSnapshotContext ()
- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait;
@end

@implementation MTDialerSnapshotContext

+ (instancetype)contextWithScale:(NSUInteger)scale
                     deviceTrait:(NSString *)deviceTrait {
    if (scale < 1 || scale > 3 ||
        (![deviceTrait isEqualToString:@"iphone"] &&
         ![deviceTrait isEqualToString:@"ipad"])) {
        return nil;
    }
    static NSArray<MTDialerSnapshotContext *> *contexts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<MTDialerSnapshotContext *> *values =
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
    NSUInteger traitOffset = [deviceTrait isEqualToString:@"ipad"] ? 3 : 0;
    return contexts[traitOffset + scale - 1];
}

- (instancetype)initWithScale:(NSUInteger)scale
                   deviceTrait:(NSString *)deviceTrait {
    self = [super init];
    if (self == nil) return nil;
    _scale = scale;
    _deviceTrait = [deviceTrait copy];
    _cacheKey = [NSString stringWithFormat:@"dialer/%@/%lu",
        _deviceTrait, (unsigned long)_scale];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:MTDialerSnapshotContext.class]) return NO;
    MTDialerSnapshotContext *other = object;
    return self.scale == other.scale &&
        [self.deviceTrait isEqualToString:other.deviceTrait];
}

- (NSUInteger)hash {
    return self.cacheKey.hash;
}

@end

@interface MTDialerSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTDialerSnapshotResolution

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

@interface MTDialerSnapshotResolver ()
@property(nonatomic, copy) MTDialerSnapshotProvider snapshotProvider;
@end

@implementation MTDialerSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTDialerSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

static NSArray<NSNumber *> *MTDialerScaleCandidates(NSUInteger scale) {
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray arrayWithCapacity:4];
    [candidates addObject:@(scale)];
    for (NSUInteger candidate = 3; candidate >= 1; candidate--) {
        NSNumber *number = @(candidate);
        if (![candidates containsObject:number]) [candidates addObject:number];
        if (candidate == 1) break;
    }
    [candidates addObject:@0];
    return candidates;
}

- (MTDialerSnapshotResolution *)
    resolutionForSubject:(NSString *)subject
                  context:(MTDialerSnapshotContext *)context
                    error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (!MTDialerResourceSubjectIsSupported(subject) || context == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTResourceKeyErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Dialer resource subject or rendering context is unsupported."
            }];
        }
        return nil;
    }
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (generation == nil) return nil;

    for (NSNumber *scale in MTDialerScaleCandidates(context.scale)) {
        for (NSString *trait in @[ context.deviceTrait, @"any" ]) {
            NSError *keyError = nil;
            MTResourceKey *key = [[MTResourceKey alloc]
                initWithModuleID:MTDialerModuleID
                         surface:MTDialerSurface
                         subject:subject
                         variant:@"primary"
                           scale:scale.unsignedIntegerValue
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
                return [[MTDialerSnapshotResolution alloc]
                    initWithGenerationIdentifier:
                        generation.generationIdentifier
                    canonicalResourceKey:key.canonicalString
                    generation:generation resource:resource];
            }
        }
    }
    return nil;
}

@end
