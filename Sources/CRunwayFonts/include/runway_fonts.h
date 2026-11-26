// Fonts Runway ships inside every app (SIL Open Font License 1.1; the
// licences are in ../fonts): Inter, the closest open face to the Mac's San
// Francisco, and JetBrains Mono for code. Backends register them at start
// so apps look the same whatever the system has installed.
#ifndef RUNWAY_FONTS_H
#define RUNWAY_FONTS_H

typedef struct {
    const char *file_name;
    const unsigned char *data;
    unsigned long size;
} runway_font_file;

/// The bundled font files.
const runway_font_file *runway_bundled_fonts(int *count);

#endif
