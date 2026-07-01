{ FreeBSD cross-compile emulation smoke test (docs/freebsd-x86_64-backend-design
  Step 8).  Cross-compiled with --target freebsd-x86_64 on the Linux CI runner,
  then executed inside a FreeBSD VM.  A raw-syscall static ET_EXEC: printing
  Hello and exiting 0 proves _start, argv capture, write(2) and _exit(2) work
  under the real FreeBSD kernel. }
program hello;
begin
  WriteLn('Hello');
end.
