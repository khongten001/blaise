{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for L5 Net.Tcp (docs/async-networking-design.adoc, [#components]):
  a fiber-per-connection TTcpServer + TTcpClient over loopback, all inside the
  single-worker scheduler in the test-runner process.

    * TestClientServerEcho — server accepts, spawns a handler fiber that echoes
      a line; client connects, sends a line, reads the echo back.
    * TestConcurrentClients — several client fibers each get served by their own
      handler fiber, all round-trips succeed.
    * TestGracefulStop — a running server stops cleanly and Serve returns.

  NATIVE BACKEND ONLY (Net.Tcp -> async.io -> async.fibers).  Self-registers
  via the initialization section. }

unit NetTcp.Tests;

interface

uses
  blaise.testing, SysUtils, Net.Tcp, async.fibers, Net.Sockets;

type
  TNetTcpTests = class(TTestCase)
  published
    procedure TestClientServerEcho;
    procedure TestConcurrentClients;
    procedure TestGracefulStop;
  end;

  { Handler: read one line, write it back with an 'echo:' prefix, close. }
  TLineEchoHandler = class(IConnHandler)
    procedure Handle(AConn: TTcpConn);
  end;

implementation

procedure TLineEchoHandler.Handle(AConn: TTcpConn);
var
  Line: string;
begin
  if AConn.ReadLine(Line) then
    AConn.Write('echo:' + Line + #10);
end;

{ --- shared fixture state (single-worker scheduler is serial, so globals are
  safe across the cooperating fibers of one test) --- }

var
  GServer: TTcpServer;
  GHandler: IConnHandler;
  GPort: UInt16;
  GResult: string;
  GDone: Integer;
  GExpected: Integer;

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

{ One client: connect, send a numbered line, read the echo, record it, and —
  when the last client finishes — stop the server so Serve returns and the
  scheduler can drain. }
procedure ClientFiber(AArg: Pointer);
var
  Cli: TTcpClient;
  Conn: TTcpConn;
  Id: Integer;
  Line: string;
begin
  Id := Integer(AArg);
  FiberSleep(2);                    { let the server accept-park first }
  Cli := TTcpClient.Create();
  Conn := Cli.Connect('127.0.0.1', GPort);
  Cli.Free();
  if Conn = nil then
  begin
    GResult := GResult + 'connfail ';
    GDone := GDone + 1;
    Exit;
  end;
  Conn.Write('req' + IntToStr(Id) + #10);
  if Conn.ReadLine(Line) then
    GResult := GResult + Line + ' '
  else
    GResult := GResult + 'noecho ';
  Conn.Free();
  GDone := GDone + 1;
  if GDone >= GExpected then
    GServer.Stop();
end;

procedure TNetTcpTests.TestClientServerEcho;
const
  PORT = 29401;
begin
  GServer := TTcpServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TLineEchoHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := 0;
  GExpected := 1;

  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@ClientFiber, Pointer(0));
  RunScheduler();

  AssertEquals('single round-trip echoes the line',
    'echo:req0 ', GResult);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

procedure TNetTcpTests.TestConcurrentClients;
const
  PORT = 29402;
  NCLIENTS = 8;
var
  I, Cnt: Integer;
begin
  GServer := TTcpServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TLineEchoHandler.Create();
  GPort := PORT;
  GResult := '';
  GDone := 0;
  GExpected := NCLIENTS;

  SpawnFiber(@ServerFiber, nil);
  for I := 0 to NCLIENTS - 1 do
    SpawnFiber(@ClientFiber, Pointer(I));
  RunScheduler();

  { Every client must have received its own echo; order is not deterministic
    across concurrent fibers, so assert each expected token is present. }
  for I := 0 to NCLIENTS - 1 do
    AssertTrue('client ' + IntToStr(I) + ' got its echo',
      Pos('echo:req' + IntToStr(I) + ' ', GResult) >= 0);
  Cnt := 0;
  for I := 0 to Length(GResult) - 1 do
    if Byte(GResult[I]) = 32 then
      Cnt := Cnt + 1;
  AssertEquals('exactly NCLIENTS echoes returned', NCLIENTS, Cnt);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

{ --- graceful stop: a stopper fiber stops the idle-accepting server --- }

procedure StopperFiber(AArg: Pointer);
begin
  FiberSleep(5);
  GServer.Stop();
  GResult := GResult + 'stopped ';
end;

procedure TNetTcpTests.TestGracefulStop;
const
  PORT = 29403;
begin
  GServer := TTcpServer.Create(PORT);
  AssertTrue('server start', GServer.Start());
  GHandler := TLineEchoHandler.Create();
  GResult := '';

  SpawnFiber(@ServerFiber, nil);   { parks in FiberAccept, no clients }
  SpawnFiber(@StopperFiber, nil);
  RunScheduler();                  { must terminate: Stop unblocks accept }

  AssertEquals('server stopped and Serve returned', 'stopped ', GResult);
  AssertFalse('server not running after stop', GServer.Running);
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

initialization
  RegisterTest(TNetTcpTests);

end.
