{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit runtime.thread.static.linux;

// Single-threaded mutex stubs for the --static (libc-free) build.  Real threads
// (pthread_create via clone + futex-based mutexes) are deferred to the threads
// step of the migration (docs/linux-syscall-migration.adoc); until then a
// static program is single-threaded, so the locks are uncontended and these
// no-op stubs are correct.  pthread_create itself is intentionally NOT provided:
// a static program that spawns a thread will fail to link, which is the honest
// signal that the threads leaf is not done yet.
//
// DEFINES the bare pthread_mutex_* names that runtime.weak / runtime.thread
// import via `external name`.

interface

function pthread_mutex_init(Mutex, Attr: Pointer): Integer;
function pthread_mutex_lock(Mutex: Pointer): Integer;
function pthread_mutex_unlock(Mutex: Pointer): Integer;
function pthread_mutex_destroy(Mutex: Pointer): Integer;

implementation

{ All no-ops returning success: a single-threaded process never contends. }

function pthread_mutex_init(Mutex, Attr: Pointer): Integer;
begin
  Result := 0;
end;

function pthread_mutex_lock(Mutex: Pointer): Integer;
begin
  Result := 0;
end;

function pthread_mutex_unlock(Mutex: Pointer): Integer;
begin
  Result := 0;
end;

function pthread_mutex_destroy(Mutex: Pointer): Integer;
begin
  Result := 0;
end;

end.
