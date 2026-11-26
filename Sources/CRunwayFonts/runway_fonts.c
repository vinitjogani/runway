// The bundled fonts, compiled in with #embed (a C23 directive clang accepts
// in older modes as an extension), so no resource bundle has to travel
// with the app.
#include "runway_fonts.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
static const unsigned char inter[] = {
#embed "fonts/InterVariable.ttf"
};
static const unsigned char inter_italic[] = {
#embed "fonts/InterVariable-Italic.ttf"
};
static const unsigned char mono[] = {
#embed "fonts/JetBrainsMono.ttf"
};
static const unsigned char mono_italic[] = {
#embed "fonts/JetBrainsMono-Italic.ttf"
};
#pragma clang diagnostic pop

static const runway_font_file files[] = {
    {"InterVariable.ttf", inter, sizeof inter},
    {"InterVariable-Italic.ttf", inter_italic, sizeof inter_italic},
    {"JetBrainsMono.ttf", mono, sizeof mono},
    {"JetBrainsMono-Italic.ttf", mono_italic, sizeof mono_italic},
};

const runway_font_file *runway_bundled_fonts(int *count) {
    *count = (int)(sizeof files / sizeof files[0]);
    return files;
}
