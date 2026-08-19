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

BOOL MTRuntimeImplementationMatchesImage(
    IMP implementation,
    const char *expectedImagePath) {
    if (implementation == NULL || expectedImagePath == NULL) {
        return NO;
    }
    Dl_info info = {0};
    if (dladdr((const void *)implementation, &info) == 0 ||
        info.dli_fname == NULL || info.dli_fbase == NULL ||
        strcmp(info.dli_fname, expectedImagePath) != 0) {
        return NO;
    }
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)info.dli_fbase;
    uint32_t subtype =
        (uint32_t)header->cpusubtype & ~((uint32_t)CPU_SUBTYPE_MASK);
    return header->magic == MH_MAGIC_64 &&
        header->cputype == CPU_TYPE_ARM64 &&
        subtype == (uint32_t)CPU_SUBTYPE_ARM64E;
}
