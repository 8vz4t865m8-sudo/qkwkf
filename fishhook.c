#import "fishhook.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

static int _rebind_for_image(struct rebinding *rebindings, size_t count,
                             const struct mach_header *header, intptr_t slide) {
    for (size_t i = 0; i < count; i++) {
        void *orig = dlsym(RTLD_DEFAULT, rebindings[i].name);
        if (orig && rebindings[i].replaced) {
            *rebindings[i].replaced = orig;
        }
    }
    return 0;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
    int ret = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        ret |= _rebind_for_image(rebindings, rebindings_nel,
                                 _dyld_get_image_header(i),
                                 _dyld_get_image_vmaddr_slide(i));
    }
    return ret;
}

int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel) {
    return _rebind_for_image(rebindings, rebindings_nel, header, slide);
}
