#import <Foundation/Foundation.h>

#if defined(MT_RUNTIME_STORE_FAULT_TESTING)

// Test-only checkpoints compiled into Host tests and the isolated durability
// probe. The product Helper never defines MT_RUNTIME_STORE_FAULT_TESTING.
typedef NS_ENUM(NSUInteger, MTRuntimeStoreTestingCheckpoint) {
    MTRuntimeStoreTestingCheckpointBeforeStateRename = 1,
    MTRuntimeStoreTestingCheckpointAfterStateRename = 2,
};

FOUNDATION_EXPORT void MTRuntimeStoreTestingReachCheckpoint(
    MTRuntimeStoreTestingCheckpoint checkpoint);

#endif
