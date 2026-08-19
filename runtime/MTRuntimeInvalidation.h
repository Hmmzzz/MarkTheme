#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeInvalidationNotificationName;

// Best-effort wake-up only. Canonical state remains the sole source of truth.
FOUNDATION_EXPORT BOOL MTRuntimePostInvalidation(void);

// Apply delivery is a one-shot control-plane acknowledgement, not Runtime hot
// path IPC. The name contains both the exact package build generation and the
// canonical state sequence, so an older image still mapped in SpringBoard
// cannot acknowledge a newly installed Runtime build.
FOUNDATION_EXPORT NSString *MTRuntimeAcknowledgementNotificationName(
    uint64_t sequence);
FOUNDATION_EXPORT BOOL
    MTRuntimePostInvalidationAndWaitForAcknowledgement(uint64_t sequence);
FOUNDATION_EXPORT BOOL MTRuntimePostAcknowledgement(uint64_t sequence);

NS_ASSUME_NONNULL_END
