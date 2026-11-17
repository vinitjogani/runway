#ifndef RUNWAY_CPANGOCAIRO_SHIM_H
#define RUNWAY_CPANGOCAIRO_SHIM_H
#include <pango/pangocairo.h>
#include <fontconfig/fontconfig.h>

static inline int runway_pango_scale(void) { return PANGO_SCALE; }
#endif
