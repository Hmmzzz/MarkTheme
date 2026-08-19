#import "MTRuntimeSnapshot.h"

#import "MTGenerationReader.h"
#import "MTRuntimeState.h"

@interface MTRuntimeSnapshot ()
@property(nonatomic, strong, readwrite) MTRuntimeState *state;
@property(nonatomic, strong, readwrite, nullable) MTGeneration *generation;
@end

@implementation MTRuntimeSnapshot

+ (instancetype)stockSnapshot {
    return [[self alloc] initWithState:MTRuntimeState.initialState
                           generation:nil];
}

- (instancetype)initWithState:(MTRuntimeState *)state
                    generation:(MTGeneration *)generation {
    NSParameterAssert(state != nil);
    NSParameterAssert(state.isRuntimeEnabled
        ? generation != nil &&
            [state.activeGenerationIdentifier
                isEqualToString:generation.generationIdentifier]
        : generation == nil);
    self = [super init];
    if (self == nil) return nil;
    _state = state;
    _generation = generation;
    return self;
}

- (BOOL)isReady {
    return self.generation != nil;
}

@end
