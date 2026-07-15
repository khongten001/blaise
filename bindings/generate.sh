#!/bin/sh
# Regenerate the committed binding units.  Run from this directory.
# Requires: clang (any version >= 16) and a built bindgen
#   (pasbuild compile -m blaise-bindgen --compiler compiler/target/blaise).
set -e
BINDGEN=../tools/bindgen/target/bindgen
[ -x "$BINDGEN" ] || { echo "build bindgen first: pasbuild compile -m blaise-bindgen"; exit 1; }

# x11 — Xlib + Xutil + Xatom + keysym + cursorfont (see x11.h).
# --match /X11/ keeps declarations and #defines from the X11 header
# tree only; libc noise is filtered out.
"$BINDGEN" --header x11.h --unit x11 --lib X11 \
           --match /X11/ --out src/main/pascal/x11.pas
