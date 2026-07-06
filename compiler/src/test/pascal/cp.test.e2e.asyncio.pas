{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.e2e.asyncio;

{ E2E test for L2 (reactor) + L3 (fiber I/O) of the fiber runtime
  (docs/async-networking-design.adoc, [#reactor], [#fiber-io]): a fiber echo
  server on a loopback TCP port plus a fiber client that connects, sends, and
  reads back the echo — the full compile -> QBE/native -> run integration proof
  the IR/stdlib harness cannot give.

  BACKEND POSTURE: async.fibers/async.io pull in the inline-asm context leaf, so
  this runs on the NATIVE backend only. }

interface

uses
  SysUtils, blaise.testing, cp.test.e2e.base;

type
  TAsyncIoE2ETests = class(TE2ETestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestFiberEchoServerClient_RoundTrip;
  end;

implementation

const
  LE = #10;

  { A fiber echo server and a fiber client cooperating on one single-worker
    scheduler.  The server accepts one connection, echoes what it receives; the
    client connects, sends 'hello', reads the echo, and prints it. }
  SrcEchoServerClient =
    '''
    program echoe2e;
    uses SysUtils, async.io, async.fibers, net.sockets;
    const PORT = 29377;
    var
      ListenFd: Integer;

    procedure ServerFiber(AArg: Pointer);
    var
      Conn: Integer;
      Buf: array[0..63] of Byte;
      N: Int64;
    begin
      Conn := FiberAccept(ListenFd);
      if Conn < 0 then begin WriteLn('ACCFAIL'); Exit; end;
      N := FiberRecv(Conn, @Buf[0], 64);
      if N > 0 then
        FiberSend(Conn, @Buf[0], N);
      Close(Conn);
    end;

    procedure ClientFiber(AArg: Pointer);
    var
      Fd, Rc, I: Integer;
      SA: TSockAddrIn;
      Buf: array[0..63] of Byte;
      N: Int64;
      S: string;
    begin
      FiberSleep(3);
      Fd := Socket(AF_INET, SOCK_STREAM, 0);
      SetNonBlocking(Fd);
      SA.sin_family := AF_INET;
      SA.sin_port := Htons(PORT);
      SA.sin_addr := INADDR_LOOPBACK;
      for I := 0 to 7 do SA.sin_zero[I] := 0;
      Rc := FiberConnect(Fd, @SA, 16);
      if Rc <> 0 then begin WriteLn('CONNFAIL'); Exit; end;
      FiberSend(Fd, PChar('hello'), 5);
      N := FiberRecv(Fd, @Buf[0], 64);
      S := '';
      for I := 0 to Integer(N) - 1 do S := S + Chr(Buf[I]);
      WriteLn('ECHO:', S);
      Close(Fd);
    end;

    begin
      ListenFd := TcpListenLocal(PORT, 8);
      if ListenFd < 0 then begin WriteLn('LISTENFAIL'); Halt(1); end;
      SetNonBlocking(ListenFd);
      SpawnFiber(@ServerFiber, nil);
      SpawnFiber(@ClientFiber, nil);
      RunScheduler();
      Close(ListenFd);
      WriteLn('DONE');
    end.
    ''';

procedure TAsyncIoE2ETests.SetUp;
begin
  inherited SetUp();
  SetUpScratch('compiler/target/test-e2e-asyncio')
end;

procedure TAsyncIoE2ETests.TestFiberEchoServerClient_RoundTrip;
begin
  if not ToolchainAvailable() then begin Ignore('toolchain unavailable'); Exit; end;
  AssertRTLRunsOnOne(beNative, 'asyncio-echo', SrcEchoServerClient,
    'ECHO:hello' + LE + 'DONE' + LE, 0)
end;

initialization
  RegisterTest(TAsyncIoE2ETests);

end.
