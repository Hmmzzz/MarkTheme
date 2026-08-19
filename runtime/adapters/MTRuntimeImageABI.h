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
// Provenance variant for contracts whose defining image legitimately moves
// between Apple system images across OS builds: satisfied when the
// implementation resolves into any sealed system image (/System/Library,
// /usr/lib), which third-party Hook replacements never do.
FOUNDATION_EXPORT BOOL MTRuntimeImplementationMatchesSystemImagePath(
    IMP _Nullable implementation);
// Returns the image path the implementation resolves into, or NULL when it
// cannot be resolved. Used to report the actual image behind a contract.
FOUNDATION_EXPORT const char * _Nullable MTRuntimeImplementationImageName(
    IMP _Nullable implementation);

NS_ASSUME_NONNULL_END
