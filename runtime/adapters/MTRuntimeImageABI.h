#import <Foundation/Foundation.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// Shared live-image provenance primitive for capability-probed adapters. The
// caller separately validates every class, selector, type encoding, and object
// layout it consumes before installing a Hook.
FOUNDATION_EXPORT BOOL MTRuntimeClassMatchesImagePath(
    Class _Nullable runtimeClass,
    const char *expectedImagePath);
FOUNDATION_EXPORT BOOL MTRuntimeImplementationMatchesImage(
    IMP _Nullable implementation,
    const char *expectedImagePath);

NS_ASSUME_NONNULL_END
