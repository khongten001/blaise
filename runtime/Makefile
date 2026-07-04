#
# Blaise — An Object Pascal Compiler
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
# Licensed under the Apache License v2.0 with Runtime Library Exception.
# See LICENSE file in the project root for full license terms.
#
# Builds blaise_rtl.a from the RTL units.  The RTL sources now live in the
# COMPILER's own source tree (compiler/src/main/pascal/runtime.*.pas — the
# dotted-flat unit names runtime.atomic, runtime.str, …) as part of the
# RTL-unification work; this Makefile is the transitional archive producer that
# keeps cold-bootstrap working from an existing release until the compiler
# itself produces the RTL object cache (see docs/rtl-unification-plan.adoc).
#
# Each RTL unit is compiled via Blaise's unit-as-top-level mode, with
# --assembler internal so the whole archive builds through Blaise's own
# in-process assembler — no external assembler, no gcc, no .s files.
SHELL   = /bin/bash

PAS_SRC_DIR = ../compiler/src/main/pascal
OBJ_DIR     = target
LIB         = $(OBJ_DIR)/blaise_rtl.a

# Where the compiler binary lives — install copies the RTL there so the
# driver finds it automatically next to itself.
COMPILER_BIN = ../compiler/target
BLAISE       = $(COMPILER_BIN)/blaise
# Whole-program per unit (--no-incremental) so every unit object is
# self-contained (no undefined cross-unit typeinfo symbols at archive link).
BLAISE_FLAGS = --no-incremental --assembler internal

# RTL unit objects.  Object basenames mirror the source unit names (dots and
# all); the archive's contents are unchanged in shape from before the rename.
PAS_OBJS = $(OBJ_DIR)/runtime.start.o \
           $(OBJ_DIR)/runtime.atomic.o \
           $(OBJ_DIR)/runtime.setjmp.o \
           $(OBJ_DIR)/runtime.utf8.o \
           $(OBJ_DIR)/runtime.mem.o \
           $(OBJ_DIR)/runtime.str.o \
           $(OBJ_DIR)/runtime.set.o \
           $(OBJ_DIR)/runtime.arc.o \
           $(OBJ_DIR)/runtime.weak.o \
           $(OBJ_DIR)/runtime.float.o \
           $(OBJ_DIR)/runtime.thread.o \
           $(OBJ_DIR)/runtime.exc.o \
           $(OBJ_DIR)/runtime.errno.linux.o \
           $(OBJ_DIR)/rtl.platform.layout.linux.o \
           $(OBJ_DIR)/rtl.platform.posix.o

OBJS = $(PAS_OBJS)

.PHONY: all install clean

all: $(LIB)

$(LIB): $(OBJS)
	ar rcs $@ $^

# --- Pascal unit rule (unit-as-top-level) ---
# One pattern rule now suffices: every unit compiles the same way, and the
# object basename equals the unit/source basename.
$(OBJ_DIR)/%.o: $(PAS_SRC_DIR)/%.pas
	@mkdir -p $(OBJ_DIR)
	$(BLAISE) $(BLAISE_FLAGS) --source $< --unit-path $(PAS_SRC_DIR) --output $@

install: $(LIB)
	@mkdir -p $(COMPILER_BIN)
	cp $(LIB) $(COMPILER_BIN)/blaise_rtl.a
	@echo "Installed blaise_rtl.a → $(COMPILER_BIN)/blaise_rtl.a"

clean:
	rm -f $(OBJ_DIR)/*.o $(OBJ_DIR)/*.s $(OBJ_DIR)/*.ssa $(LIB)
