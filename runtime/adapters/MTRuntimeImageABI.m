#import "MTRuntimeImageABI.h"

#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach/machine.h>

#include <string.h>

static const uint32_t MTRuntimeMaximumLoadCommandCount = 4096;
static const uint32_t MTRuntimeMaximumLoadCommandBytes = 4 * 1024 * 1024;

BOOL MTRuntimeClassMatchesImagePath(Class runtimeClass,
                                    const char *expectedImagePath) {
    if (runtimeClass == Nil || expectedImagePath == NULL) return NO;
    const char *imageName = class_getImageName(runtimeClass);
    return imageName != NULL && strcmp(imageName, expectedImagePath) == 0;
}

BOOL MTRuntimeImplementationMatchesImage(
    IMP implementation,
    const char *expectedImagePath,
    const uint8_t *expectedImageUUID) {
    if (implementation == NULL || expectedImagePath == NULL ||
        expectedImageUUID == NULL) {
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
    if (header->magic != MH_MAGIC_64 ||
        header->cputype != CPU_TYPE_ARM64 ||
        subtype != (uint32_t)CPU_SUBTYPE_ARM64E ||
        header->ncmds == 0 ||
        header->ncmds > MTRuntimeMaximumLoadCommandCount ||
        header->sizeofcmds < sizeof(struct load_command) ||
        header->sizeofcmds > MTRuntimeMaximumLoadCommandBytes) {
        return NO;
    }
    const uint8_t *commands = (const uint8_t *)(const void *)(header + 1);
    size_t offset = 0;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (offset > header->sizeofcmds - sizeof(struct load_command)) {
            return NO;
        }
        const struct load_command *command =
            (const struct load_command *)(const void *)(commands + offset);
        if (command->cmdsize < sizeof(struct load_command) ||
            command->cmdsize > header->sizeofcmds - offset) {
            return NO;
        }
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)(const void *)command;
            return memcmp(uuid->uuid, expectedImageUUID, 16) == 0;
        }
        offset += command->cmdsize;
    }
    return NO;
}
