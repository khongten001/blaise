{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.start.static.freebsd;

// Freestanding _start for a static, libc-free FreeBSD ET_EXEC (the FreeBSD
// kernel-leaf swap; docs/freebsd-x86_64-backend-design.adoc, Step 3).
//
// The FreeBSD sibling of runtime.start.static.linux.  A tiny asm trampoline
// captures the initial stack pointer and tail-calls the Pascal _BlaiseStartC,
// which parses argc / argv / envp off the kernel's initial stack, captures
// `environ`, calls main(argc, argv), and exits via the FreeBSD `exit` syscall.
//
// FreeBSD's process entry stack has the SAME shape as Linux: %rsp points at
// argc, followed by argv[0..argc-1], a NULL, envp[], a NULL, then the ELF auxv.
// (FreeBSD additionally passes an rtld cleanup pointer in %rdx for dynamic
// binaries; it is 0 for a static ET_EXEC and we ignore it.)
//
// Step 3 is deliberately minimal: it does NOT set up TLS / the thread pointer.
// A trivial program performs no threadvar (%fs-relative) access, so this start
// runs hello-world and file I/O.  TLS-block construction + the auxv PT_TLS walk
// (whose FreeBSD AT_* tags differ from Linux) arrive with the threads leaf in
// Step 4, mirroring how runtime.start.static.linux gained TLS alongside its
// threads work.

interface

uses
  runtime.syscall.freebsd;   { _exit + the `environ` global }

procedure _start;

implementation

type
  PPointer = ^Pointer;
  PInt64   = ^Int64;

{ Call the program's `main(argc, argv)` (emitted by the backend) and return its
  result.  The asm thunk tail-jumps to the bare `main` symbol; argc/argv are
  already in %edi/%rsi (SysV), exactly what main expects. }
function MainTrampoline(Argc: Integer; Argv: Pointer): Integer;
  assembler; nostackframe;
asm
    jmp main
end;

{ The C-level entry: SP points at the kernel's initial stack (argc at [SP]). }
procedure _BlaiseStartC(SP: Pointer);
var
  Argc: Int64;
  Argv, Envp: Pointer;
  Ret: Integer;
begin
  Argc := PInt64(SP)^;
  Argv := Pointer(PChar(SP) + 8);
  { envp = &argv[argc+1] }
  Envp := Pointer(PChar(Argv) + (Argc + 1) * 8);
  environ := Envp;

  Ret := MainTrampoline(Integer(Argc), Argv);
  _exit(Ret);
end;

{ The kernel entry.  Capture %rsp (points at argc), align, and call the Pascal
  core.  Never returns. }
procedure _start; assembler; nostackframe;
asm
    endbr64
    xor  %ebp, %ebp
    movq %rsp, %rdi           { SP -> first arg }
    andq $0xfffffffffffffff0, %rsp
    call _BlaiseStartC
    xorl %edi, %edi
    movq $1, %rax             { SYS_exit(0) guard }
    syscall
    hlt
end;

end.
