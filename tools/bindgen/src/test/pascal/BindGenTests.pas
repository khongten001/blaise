{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

program BindGenTests;

uses
  blaise.testing,
  blaise.testing.runner.text,
  bg.test.typemap,
  bg.test.clang,
  bg.test.emit,
  bg.test.layout,
  bg.test.macros;

begin
  Halt(RunAll());
end.
