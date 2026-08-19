#import "MTRuntimeImageABI.h"

#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach/machine.h>

#include <string.h>

BOOL MTRuntimeClassMatchesImagePath(Class runtimeClass,
                                    const char *expectedImagePath) {
    if (runtimeClass == Nil || expectedImagePath == NULL) return NO;
    const char *imageName = class_getImageName(runtimeClass);
    return imageName != NULL && strcmp(imageName, expectedImagePath) == 0;
}

// dli_fname alone does not prove the mapping is a device image; the header
// at dli_fbase must be the arm64e Mach-O the contracts were captured from.
static BOOL MTRuntimeImageHeaderIsArm64E(const Dl_info *info) {
    if (info->dli_fname == NULL || info->dli_fbase == NULL) return NO;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)info->dli_fbase;
    uint32_t subtype =
        (uint32_t)header->cpusubtype & ~((uint32_t)CPU_SUBTYPE_MASK);
    return header->magic == MH_MAGIC_64 &&
        header->cputype == CPU_TYPE_ARM64 &&
        subtype == (uint32_t)CPU_SUBTYPE_ARM64E;
}

BOOL MTRuntimeImplementationMatchesImage(
    IMP implementation,
    const char *expectedImagePath) {
    if (implementation == NULL || expectedImagePath == NULL) {
        return NO;
    }
    Dl_info info = {0};
    if (dladdr((const void *)implementation, &info) == 0 ||
        strcmp(info.dli_fname, expectedImagePath) != 0) {
        return NO;
    }
    return MTRuntimeImageHeaderIsArm64E(&info);
}

BOOL MTRuntimeImplementationResolves(IMP implementation) {
    if (implementation == NULL) {
        return NO;
    }
    Dl_info info = {0};
    return dladdr((const void *)implementation, &info) != 0 &&
        info.dli_fname != NULL;
}

BOOL MTRuntimeImplementationMatchesSystemImagePath(IMP implementation) {
    if (implementation == NULL) {
        return NO;
    }
    Dl_info info = {0};
    if (dladdr((const void *)implementation, &info) == 0 ||
        !MTRuntimeImageHeaderIsArm64E(&info)) {
        return NO;
    }
    // The sealed system volume cannot host third-party code; every Hook
    // replacement resolves outside it, in a jailbreak bootstrap image.
    return strncmp(info.dli_fname, "/System/Library/", 16) == 0 ||
        strncmp(info.dli_fname, "/usr/lib/", 9) == 0;
}

const char *MTRuntimeImplementationImageName(IMP implementation) {
    if (implementation == NULL) {
        return NULL;
    }
    Dl_info info = {0};
    if (dladdr((const void *)implementation, &info) == 0) {
        return NULL;
    }
    return info.dli_fname;
}
