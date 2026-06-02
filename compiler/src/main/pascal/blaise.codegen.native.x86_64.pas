{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.codegen.native.x86_64;

{ x86_64 (System V AMD64 ABI) backend for the native code generator.

  Emits AT&T-syntax assembly text (fed to `as`/`cc`, like QBE's .s output),
  using a naive stack-slot register allocator first for correctness, with
  optimisation deferred behind the same seam.

  Currently a SHELL (milestone M0b): the class exists and registers via
  blaise.codegen.native.CreateNativeBackend so target selection resolves, but
  instruction selection / register allocation / assembly emission are not yet
  implemented. }

interface

uses
  SysUtils, uAST, blaise.codegen.native.backend, blaise.codegen.target;

type
  TX86_64Backend = class(TNativeBackend)
  protected
    procedure EmitProgram(AProg: TProgram); override;
  public
    constructor Create(const ATarget: TTargetDesc); override;
  end;

implementation

constructor TX86_64Backend.Create(const ATarget: TTargetDesc);
begin
  inherited Create(ATarget);
end;

{ Emit the program entry function.

  The Blaise runtime expects an exported `main(argc, argv)` returning int.  It
  must call $_SetArgs(argc, argv) before any program code, then run the body,
  then return 0.  This mirrors the QBE backend's $main shape (see the QBE IR
  for an empty program).

  For M1 the body is empty, so this is just the prologue, _SetArgs, and a
  `return 0` epilogue.  The program-body lowering (statements) will be inserted
  between the _SetArgs call and the epilogue in later milestones. }
procedure TX86_64Backend.EmitProgram(AProg: TProgram);
begin
  Self.Emit('.text');
  Self.Emit('.globl main');
  Self.Emit('main:');
  { Prologue: establish a frame.  argc is in %edi, argv in %rsi per SysV. }
  Self.Emit(#9'pushq %rbp');
  Self.Emit(#9'movq %rsp, %rbp');
  { _SetArgs(argc, argv): args already in %edi/%rsi — pass through. }
  Self.Emit(#9'callq _SetArgs');
  { --- program body goes here (M2+) --- }
  { Epilogue: return 0. }
  Self.Emit(#9'movl $0, %eax');
  Self.Emit(#9'leave');
  Self.Emit(#9'ret');
  Self.Emit('.type main, @function');
  { Mark the stack non-executable (matches QBE output). }
  Self.Emit('.section .note.GNU-stack,"",@progbits');
end;

end.
