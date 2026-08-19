#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The caller must serialize access to mapTable while this snapshot is built.
// Each returned two-object array strongly retains one live key/value pair, so
// callbacks may mutate the original weak map without invalidating iteration.
FOUNDATION_EXPORT NSArray<NSArray *> *
MTRuntimeWeakObjectMapSnapshot(NSMapTable * _Nullable mapTable);

NS_ASSUME_NONNULL_END
