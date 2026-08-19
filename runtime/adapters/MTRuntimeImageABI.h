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
// Coexistence acceptance primitive for Hook provenance. Users install many
// tweaks, so an implementation another tweak has already replaced must remain
// hookable: hooking chains through whatever implementation is current, so
// accepting any resolvable IMP composes this Runtime with earlier Hooks
// instead of disabling them. Provenance is still recorded separately for
// diagnostics; the expected-image predicates below delegate here.
FOUNDATION_EXPORT BOOL MTRuntimeImplementationResolves(
    IMP _Nullable implementation);
// Provenance classification for diagnostics: satisfied when the implementation
// resolves into any sealed system image (/System/Library, /usr/lib). A
// negative result means a third-party image, which coexistence still accepts.
FOUNDATION_EXPORT BOOL MTRuntimeImplementationMatchesSystemImagePath(
    IMP _Nullable implementation);
// Returns the image path the implementation resolves into, or NULL when it
// cannot be resolved. Used to report the actual image behind a contract.
FOUNDATION_EXPORT const char * _Nullable MTRuntimeImplementationImageName(
    IMP _Nullable implementation);

NS_ASSUME_NONNULL_END
