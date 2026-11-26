#if defined(__linux__) || defined(__FreeBSD__)
// Fonts an app brings with it (Runway's bundled Inter and JetBrains Mono),
// registered with fontconfig for this process only, and the Mac family
// names that should draw with them.
#include "runway_gtk.h"
#include <fontconfig/fontconfig.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>

void runway_register_fonts(const char *const *paths, int count, const char *const *aliases, int alias_pairs) {
    FcConfig *config = FcConfigGetCurrent();
    if (!config) return;
    for (int i = 0; i < count; i++) FcConfigAppFontAddFile(config, (const FcChar8 *)paths[i]);
    if (alias_pairs > 0) {
        GString *xml = g_string_new("<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig>");
        for (int i = 0; i < alias_pairs; i++) {
            char *from = g_markup_escape_text(aliases[i * 2], -1), *to = g_markup_escape_text(aliases[i * 2 + 1], -1);
            g_string_append_printf(xml, "<alias binding=\"same\"><family>%s</family><prefer><family>%s</family></prefer></alias>", from, to);
            g_free(from);
            g_free(to);
        }
        g_string_append(xml, "</fontconfig>");
        FcConfigParseAndLoadFromMemory(config, (const FcChar8 *)xml->str, FcTrue);
        g_string_free(xml, TRUE);
    }
    // A font map already made (text laid out before) sees the new fonts.
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (map && PANGO_IS_FC_FONT_MAP(map)) pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
}

void runway_tune_text_rendering(void) {
    GtkSettings *s = gtk_settings_get_default();
    if (!s) return;
    GObjectClass *k = G_OBJECT_GET_CLASS(s);
    // Glyphs at their exact positions (rounding them to whole pixels makes
    // the uneven gaps "volum e" shows), slight hinting and greyscale
    // antialiasing: text laid out and drawn as the Mac does.
    if (g_object_class_find_property(k, "gtk-hint-font-metrics")) g_object_set(s, "gtk-hint-font-metrics", FALSE, NULL);
    if (g_object_class_find_property(k, "gtk-xft-hintstyle")) g_object_set(s, "gtk-xft-hintstyle", "hintslight", NULL);
    if (g_object_class_find_property(k, "gtk-xft-antialias")) g_object_set(s, "gtk-xft-antialias", 1, NULL);
    if (g_object_class_find_property(k, "gtk-xft-rgba")) g_object_set(s, "gtk-xft-rgba", "none", NULL);
}
#endif
