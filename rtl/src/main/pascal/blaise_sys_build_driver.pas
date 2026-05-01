{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

{ Build driver for blaise_sys.pas — used only by the RTL Makefile to compile
  the unit into an object file for inclusion in blaise_rtl.a.  The program
  body is stripped from the IR before assembly; only the unit functions are
  archived. }

program blaise_sys_build_driver;

uses
  blaise_sys;

begin
end.
