{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for L5 Net.Smtp (SMTP client, RFC 5321).  A MOCK SMTP server runs as a
  fiber on Net.Tcp inside the test-runner process, speaking just enough SMTP for
  the client to drive:

    220 greeting, 250 to EHLO (multi-line capabilities), 250 to MAIL/RCPT,
    354 to DATA, 250 after CRLF.CRLF, 221 to QUIT, 334/235 for AUTH.

  The mock records every command it received; the client-driving fiber then
  asserts the recorded transcript.  All plaintext (internal linker).

  NATIVE BACKEND ONLY.  Self-registers via the initialization section. }

unit Smtp.Tests;

interface

uses
  blaise.testing, SysUtils, Net.Tcp, Net.Smtp, Net.Mail.Reply,
  async.fibers, Net.Sockets;

type
  TSmtpTests = class(TTestCase)
  published
    procedure TestSendMailTranscript;
    procedure TestAuthLoginBase64;
    procedure TestMultiLineEhloCaps;
    procedure TestDotStuffing;
  end;

implementation

{ --- shared fixture state (single-worker scheduler => serial fibers) --- }

var
  GServer: TTcpServer;
  GHandler: IConnHandler;
  GPort: UInt16;
  GTranscript: string;      { commands the mock server saw, LF-joined }
  GBodyLines: string;       { DATA payload lines the mock saw, LF-joined }
  GClientOk: Boolean;
  GAuthUser: string;        { decoded/observed base64 tokens }
  GAuthPass: string;
  GAdvertiseAuth: Boolean;

{ The mock SMTP server handler.  Runs in its own fiber per connection. }
type
  TMockSmtpHandler = class(IConnHandler)
    procedure Handle(AConn: TTcpConn);
  end;

procedure TMockSmtpHandler.Handle(AConn: TTcpConn);
var
  Line: string;
  U: string;
  InData: Boolean;
begin
  AConn.Write('220 mock.smtp.test ESMTP ready' + CRLF);
  InData := False;
  while AConn.ReadLine(Line) do
  begin
    if InData then
    begin
      { collect body lines until the lone '.' terminator }
      if Line = '.' then
      begin
        InData := False;
        AConn.Write('250 2.0.0 Ok: queued' + CRLF);
        Continue;
      end;
      if GBodyLines <> '' then
        GBodyLines := GBodyLines + #10;
      GBodyLines := GBodyLines + Line;
      Continue;
    end;

    GTranscript := GTranscript + Line + #10;
    U := UpperCase(Line);

    if Copy(U, 0, 4) = 'EHLO' then
    begin
      AConn.Write('250-mock.smtp.test greets you' + CRLF);
      AConn.Write('250-PIPELINING' + CRLF);
      AConn.Write('250-SIZE 10240000' + CRLF);
      if GAdvertiseAuth then
        AConn.Write('250-AUTH LOGIN PLAIN' + CRLF);
      AConn.Write('250-STARTTLS' + CRLF);
      AConn.Write('250 HELP' + CRLF);
    end
    else if Copy(U, 0, 4) = 'HELO' then
      AConn.Write('250 mock.smtp.test' + CRLF)
    else if U = 'AUTH LOGIN' then
    begin
      AConn.Write('334 VXNlcm5hbWU6' + CRLF);   { 'Username:' }
      if AConn.ReadLine(GAuthUser) then
      begin
        AConn.Write('334 UGFzc3dvcmQ6' + CRLF); { 'Password:' }
        if AConn.ReadLine(GAuthPass) then
          AConn.Write('235 2.7.0 Authentication successful' + CRLF);
      end;
    end
    else if Copy(U, 0, 10) = 'AUTH PLAIN' then
    begin
      GAuthUser := Copy(Line, 11, Length(Line) - 11);
      AConn.Write('235 2.7.0 Authentication successful' + CRLF);
    end
    else if Copy(U, 0, 4) = 'MAIL' then
      AConn.Write('250 2.1.0 Ok' + CRLF)
    else if Copy(U, 0, 4) = 'RCPT' then
      AConn.Write('250 2.1.5 Ok' + CRLF)
    else if U = 'DATA' then
    begin
      AConn.Write('354 End data with <CR><LF>.<CR><LF>' + CRLF);
      InData := True;
    end
    else if U = 'QUIT' then
    begin
      AConn.Write('221 2.0.0 Bye' + CRLF);
      Break;
    end
    else
      AConn.Write('250 Ok' + CRLF);
  end;
end;

{ --- fibers --- }

procedure ServerFiber(AArg: Pointer);
begin
  GServer.Serve(GHandler);
end;

procedure ResetFixture(APort: UInt16);
begin
  GServer := TTcpServer.Create(APort);
  GServer.Start();
  GHandler := TMockSmtpHandler.Create();
  GPort := APort;
  GTranscript := '';
  GBodyLines := '';
  GClientOk := False;
  GAuthUser := '';
  GAuthPass := '';
  GAdvertiseAuth := True;
end;

procedure TeardownFixture;
begin
  ResetScheduler();
  GServer.Free();
  GHandler := nil;
end;

{ Client fiber: SendMail one-shot. }
procedure SendMailFiber(AArg: Pointer);
var
  Cli: TSmtpClient;
begin
  FiberSleep(2);
  Cli := TSmtpClient.Create();
  GClientOk := Cli.SendMail('127.0.0.1', GPort,
    'alice@example.com', 'bob@example.com', 'Hi', 'Hello Bob' + CRLF + 'Bye');
  Cli.Free();
  GServer.Stop();
end;

procedure TSmtpTests.TestSendMailTranscript;
const
  PORT = 29501;
begin
  ResetFixture(PORT);
  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@SendMailFiber, nil);
  RunScheduler();

  AssertTrue('SendMail succeeded', GClientOk);
  AssertTrue('EHLO sent', Pos('EHLO localhost', GTranscript) >= 0);
  AssertTrue('MAIL FROM sent',
    Pos('MAIL FROM:<alice@example.com>', GTranscript) >= 0);
  AssertTrue('RCPT TO sent',
    Pos('RCPT TO:<bob@example.com>', GTranscript) >= 0);
  AssertTrue('DATA sent', Pos('DATA' + #10, GTranscript) >= 0);
  AssertTrue('QUIT sent', Pos('QUIT', GTranscript) >= 0);
  AssertTrue('body carried the Subject header',
    Pos('Subject: Hi', GBodyLines) >= 0);
  AssertTrue('body carried the message text',
    Pos('Hello Bob', GBodyLines) >= 0);
  TeardownFixture();
end;

{ Client fiber: connect, EHLO, AUTH LOGIN. }
procedure AuthLoginFiber(AArg: Pointer);
var
  Cli: TSmtpClient;
begin
  FiberSleep(2);
  Cli := TSmtpClient.Create();
  if Cli.Connect('127.0.0.1', GPort) then
    if Cli.Ehlo('localhost') then
      GClientOk := Cli.AuthLogin('alice', 'secret');
  Cli.Quit();
  Cli.Free();
  GServer.Stop();
end;

procedure TSmtpTests.TestAuthLoginBase64;
const
  PORT = 29502;
begin
  ResetFixture(PORT);
  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@AuthLoginFiber, nil);
  RunScheduler();

  AssertTrue('AuthLogin succeeded (235)', GClientOk);
  { the client must have sent base64('alice') and base64('secret') }
  AssertEquals('username base64', 'YWxpY2U=', GAuthUser);
  AssertEquals('password base64', 'c2VjcmV0', GAuthPass);
  TeardownFixture();
end;

{ Client fiber: connect, EHLO, inspect capabilities. }
procedure EhloCapsFiber(AArg: Pointer);
var
  Cli: TSmtpClient;
begin
  FiberSleep(2);
  Cli := TSmtpClient.Create();
  if Cli.Connect('127.0.0.1', GPort) then
    if Cli.Ehlo('localhost') then
      GClientOk := Cli.HasCapability('STARTTLS')
        and Cli.HasCapability('PIPELINING')
        and Cli.HasCapability('SIZE')
        and (not Cli.HasCapability('NOSUCHCAP'));
  Cli.Quit();
  Cli.Free();
  GServer.Stop();
end;

procedure TSmtpTests.TestMultiLineEhloCaps;
const
  PORT = 29503;
begin
  ResetFixture(PORT);
  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@EhloCapsFiber, nil);
  RunScheduler();

  AssertTrue('multi-line EHLO capabilities parsed', GClientOk);
  TeardownFixture();
end;

{ Client fiber: send a body whose lines include a lone '.' — must be dot-stuffed
  so it does not prematurely terminate the DATA payload. }
procedure DotStuffFiber(AArg: Pointer);
var
  Cli: TSmtpClient;
  Body: string;
begin
  FiberSleep(2);
  Cli := TSmtpClient.Create();
  Body := 'line one' + CRLF + '.' + CRLF + 'line three';
  if Cli.Connect('127.0.0.1', GPort) then
    if Cli.Ehlo('localhost') then
      if Cli.MailFrom('a@x') then
        if Cli.RcptTo('b@y') then
          GClientOk := Cli.Data('Subject: test' + CRLF + CRLF + Body);
  Cli.Quit();
  Cli.Free();
  GServer.Stop();
end;

procedure TSmtpTests.TestDotStuffing;
const
  PORT = 29504;
begin
  ResetFixture(PORT);
  SpawnFiber(@ServerFiber, nil);
  SpawnFiber(@DotStuffFiber, nil);
  RunScheduler();

  AssertTrue('DATA accepted (dot-stuffing kept the payload intact)', GClientOk);
  { the mock un-frames the transport; the escaped '.' line arrives at the server
    as '..' (raw, before the server would un-dot-stuff).  We recorded raw body
    lines, so the escaped line must appear as '..'. }
  AssertTrue('lone-dot line was dot-stuffed to ..',
    Pos(#10 + '..' + #10, #10 + GBodyLines + #10) >= 0);
  AssertTrue('surrounding lines intact', Pos('line one', GBodyLines) >= 0);
  AssertTrue('surrounding lines intact', Pos('line three', GBodyLines) >= 0);
  TeardownFixture();
end;

initialization
  RegisterTest(TSmtpTests);

end.
