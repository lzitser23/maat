/* Single translation unit providing the stb_image / stb_image_write /
 * stb_image_resize2 implementations for the Zig build (see build.zig,
 * which compiles this alongside the vendored headers in this
 * directory). Header-only libraries: exactly one .c file may define
 * the *_IMPLEMENTATION macros before including them. */

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"
