/* The single-file libraries the canvas runtime (vcanvas.c) uses, compiled once here:
 *   stb_image (PNG/BMP/JPG/GIF/TGA loading), stb_image_write (PNG/BMP/JPG saving), stb_truetype (TTF fonts),
 *   stb_vorbis (OGG music) — all by Sean Barrett, public domain / MIT (see the end of each file in stb/). */
#define STBI_NO_PSD
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_HDR
#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb/stb_image_write.h"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb/stb_truetype.h"
#include "stb/stb_vorbis.c"
