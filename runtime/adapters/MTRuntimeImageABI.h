#import <Foundation/Foundation.h>

#import <objc/runtime.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Shared exact-image primitive for build-pinned ProcessAdapters. A profile
// still owns the process/build decision; this only verifies the live class or
// implementation before a Hook is installed.
FOUNDATION_EXPORT BOOL MTRuntimeClassMatchesImagePath(
    Class _Nullable runtimeClass,
    const char *expectedImagePath);
FOUNDATION_EXPORT BOOL MTRuntimeImplementationMatchesImage(
    IMP _Nullable implementation,
    const char *expectedImagePath,
    const uint8_t *expectedImageUUID);

NS_ASSUME_NONNULL_END
