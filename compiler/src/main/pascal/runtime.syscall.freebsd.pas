{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.syscall.freebsd;

// FreeBSD x86_64 direct-syscall kernel leaf — the libc replacement for a static,
// libc-free FreeBSD ET_EXEC (docs/freebsd-x86_64-backend-design.adoc, Step 3/4).
//
// This is the FreeBSD sibling of runtime.syscall.linux.  It DEFINES the bare
// POSIX names that rtl.platform.posix references via `external name 'write'`
// etc.; the FreeBSD RTL composition links it (the link-time swap) in place of
// the Linux leaf, so the resulting binary reaches the kernel with raw
// `syscall`s and needs no libc, no PT_INTERP.
//
// Step 3 scope: the minimum the freestanding _start needs — `_exit`, `write`,
// and the `environ` global.  The remaining file/process/thread leaves grow here
// in Step 4.
//
// System V AMD64 -> FreeBSD syscall ABI:
//   * syscall number in %rax; args in %rdi,%rsi,%rdx,%r10,%r8,%r9 (the 4th C
//     arg %rcx must be moved to %r10 — the `syscall` instruction clobbers %rcx).
//   * The syscall NUMBERS differ from Linux (exit=1, write=4, read=3, open=5,
//     close=6 — see sys/syscall.h); they are NOT Linux's.
//   * Errors are reported via the CARRY FLAG (errno returned in %rax), not the
//     -errno convention Linux uses.  The error-translating wrappers that need it
//     arrive in Step 4; `_exit` never returns and `write` on success returns the
//     byte count, so neither needs CF handling here.
//
// `nostackframe` lets each asm body own the frame so the registers hold the raw
// incoming arguments unmodified.

interface

{ The current process environment (envp), captured by _start.  rtl.platform.posix
  / getenv walk this NULL-terminated array.  Defined here (as on Linux) so the
  kernel leaf owns it. }
var
  environ: Pointer;

{ write(fd, buf, count) — SYS_write = 4.  The Pascal name is _sys_write because
  `write` collides with the Write/WriteLn builtin; the asm body emits a bare
  `write` label so the linker symbol matches posix's `external name 'write'`. }
function _sys_write(Fd: Integer; Buf: Pointer; Count: Int64): Int64;

{ _exit(code) — SYS_exit = 1.  Terminates the process; never returns.  The
  unit-level routine name `_exit` already emits the unmangled `_exit` symbol that
  satisfies posix's `external name '_exit'`. }
procedure _exit(Code: Integer);

implementation

function _sys_write(Fd: Integer; Buf: Pointer; Count: Int64): Int64;
  assembler; nostackframe;
asm
.globl write
write:
    movq $4, %rax             { SYS_write }
    syscall
    ret
end;

procedure _exit(Code: Integer); assembler; nostackframe;
asm
    movq $1, %rax             { SYS_exit }
    syscall
    ret
end;

end.
