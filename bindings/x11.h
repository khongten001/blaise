/* Aggregation header for the Blaise 'x11' binding unit.
 *
 * One combined unit instead of per-header units: bindgen has no
 * cross-unit import emission yet, and Xutil/Xatom/keysym all lean on
 * Xlib's types anyway.  Regenerate with ./generate.sh after changing
 * this list.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/cursorfont.h>
