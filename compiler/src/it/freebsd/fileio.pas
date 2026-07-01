{ FreeBSD cross-compile emulation smoke test (docs/freebsd-x86_64-backend-design
  Step 8).  Exercises the file path that STATIC ELF checks cannot catch: a wrong
  struct-stat offset or syscall number only shows up when the binary actually
  runs on FreeBSD.  Write a file, read it back, and stat it (FileExists), then
  print the results.  Expected output under FreeBSD:

      file-io-ok
      exists-ok
      done

  A wrong FreeBSD st_size / st_mode offset (they differ from Linux — see
  rtl.platform.layout.freebsd) would make ReadFile or FileExists misbehave.
  This also guards the memory manager's mmap path: WriteFile/ReadFile allocate,
  and runtime.mem passes the Linux MAP_ANONYMOUS bit which the FreeBSD mmap leaf
  must translate to MAP_ANON — without the translation the first allocation
  fails with EBADF and the program SIGSEGVs (regression caught here). }
program fileio;
uses sysutils;
var
  S: string;
begin
  WriteFile('blaise_fbsd_it.txt', 'file-io-ok');
  S := ReadFile('blaise_fbsd_it.txt');
  WriteLn(S);
  if FileExists('blaise_fbsd_it.txt') then
    WriteLn('exists-ok');
  DeleteFile('blaise_fbsd_it.txt');
  WriteLn('done');
end.
