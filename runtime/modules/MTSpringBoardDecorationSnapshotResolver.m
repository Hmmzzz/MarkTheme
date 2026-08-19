#import "MTSpringBoardDecorationSnapshotResolver.h"

#import "MTFolderIconContract.h"
#import "MTGenerationReader.h"
#import "MTIconMaskContract.h"
#import "MTResourceKey.h"
#import "MTRuntimeSnapshot.h"

@interface MTSpringBoardDecorationSnapshotResolution ()
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                         canonicalResourceKey:(NSString *)canonicalResourceKey
                                   generation:(MTGeneration *)generation
                                     resource:(MTGenerationResource *)resource;
@end

@implementation MTSpringBoardDecorationSnapshotResolution

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

@interface MTSpringBoardDecorationSnapshotResolver ()
@property(nonatomic, copy)
    MTSpringBoardDecorationSnapshotProvider snapshotProvider;
@end

@implementation MTSpringBoardDecorationSnapshotResolver

- (instancetype)initWithSnapshotProvider:
    (MTSpringBoardDecorationSnapshotProvider)snapshotProvider {
    NSParameterAssert(snapshotProvider != nil);
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    return self;
}

- (MTSpringBoardDecorationSnapshotResolution *)
    resolutionForKind:(MTSpringBoardDecorationKind)kind
                 error:(NSError **)error {
    if (error != NULL) *error = nil;
    NSString *moduleID = nil;
    NSString *surface = nil;
    NSString *subject = nil;
    NSString *variant = nil;
    switch (kind) {
        case MTSpringBoardDecorationKindIconMask:
            moduleID = MTIconMaskModuleID;
            surface = MTIconMaskSurface;
            subject = MTIconMaskGlobalSubject;
            variant = MTIconMaskVariantMask;
            break;
        case MTSpringBoardDecorationKindIconPattern:
            moduleID = MTIconMaskModuleID;
            surface = MTIconMaskSurface;
            subject = MTIconMaskGlobalSubject;
            variant = MTIconMaskVariantPattern;
            break;
        case MTSpringBoardDecorationKindFolderBackground:
            moduleID = MTFolderIconsModuleID;
            surface = MTFolderIconSurface;
            subject = MTFolderIconGlobalSubject;
            variant = MTFolderIconVariantBackground;
            break;
        case MTSpringBoardDecorationKindFolderBackgroundLight:
            moduleID = MTFolderIconsModuleID;
            surface = MTFolderIconSurface;
            subject = MTFolderIconGlobalSubject;
            variant = MTFolderIconVariantBackgroundLight;
            break;
        default:
            return nil;
    }

    MTGeneration *generation = self.snapshotProvider().generation;
    if (generation == nil) return nil;
    NSError *keyError = nil;
    MTResourceKey *key = [[MTResourceKey alloc]
        initWithModuleID:moduleID
                 surface:surface
                 subject:subject
                 variant:variant
                   scale:0
                   trait:@"any"
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
    if (resource == nil) return nil;
    return [[MTSpringBoardDecorationSnapshotResolution alloc]
        initWithGenerationIdentifier:generation.generationIdentifier
        canonicalResourceKey:key.canonicalString
        generation:generation
        resource:resource];
}

@end
