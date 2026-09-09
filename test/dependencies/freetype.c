#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>

static const unsigned char font[] =
    "STARTFONT 2.1\nFONT signals-probe\nSIZE 2 72 72\n"
    "FONTBOUNDINGBOX 2 2 0 0\nSTARTPROPERTIES 2\n"
    "FONT_ASCENT 2\nFONT_DESCENT 0\nENDPROPERTIES\nCHARS 1\n"
    "STARTCHAR A\nENCODING 65\nSWIDTH 500 0\nDWIDTH 2 0\n"
    "BBX 2 2 0 0\nBITMAP\nC0\nC0\nENDCHAR\nENDFONT\n";

int main(void) {
    FT_Library library = NULL;
    FT_Face face = NULL;
    int major, minor, patch;
    if (FT_Init_FreeType(&library)) return 1;
    FT_Library_Version(library, &major, &minor, &patch);
    if (major != 2 || minor != 14 || patch != 3) return 2;
    if (FT_New_Memory_Face(library, font, sizeof(font) - 1, 0, &face)) return 3;
    if (!FT_Get_Char_Index(face, 'A')) return 4;
    if (FT_Set_Pixel_Sizes(face, 0, 2)) return 5;
    if (FT_Load_Char(face, 'A', FT_LOAD_RENDER)) return 6;
    FT_Bitmap bitmap = face->glyph->bitmap;
    if (bitmap.width != 2 || bitmap.rows != 2 || bitmap.pitch != 1 ||
        bitmap.pixel_mode != FT_PIXEL_MODE_MONO ||
        bitmap.buffer[0] != 0xc0 || bitmap.buffer[1] != 0xc0) return 7;
    if (FT_Done_Face(face) || FT_Done_FreeType(library)) return 8;
    puts("PASS: candidate FreeType 2.14.3 parsed and rendered the exact test glyph");
    return 0;
}
