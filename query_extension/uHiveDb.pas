unit uHiveDb;
{
  Copyright (C) 2009-2012 Rajko Stojadinovic (original C++ implementation)
  Copyright (C) 2026 Nathan Davalos (Delphi port)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  Database access for the hive datamodule. Ports the parts of Database/Implementation/ConcreteDatabase.cpp + SqlDelayThread.cpp that the
  handlers actually rely on.

  Connection model, kept because behaviour depends on it:
    - reads go on their own connection
    - ALL writes - queued and direct alike - serialise on a single second connection, guarded by one lock

  That split is exactly why CHILD:388's retObjID has to retry-poll:
  the SELECT runs on the read connection and can beat the queued INSERT from CHILD:308.

  Deliberate change: where HiveExt interpolates escaped strings into SQL with %s, this uses UniDAC parameters.
  Same resulting statement, no hand-rolled escaping to get wrong. Identifiers (table names from the ini) are still interpolated, as they must be.
}

interface

uses
  Windows, SysUtils, Classes, SyncObjs, Generics.Collections, Variants,
  DB, DBAccess, Uni, MemDS, UniProvider, MySQLUniProvider,
  common;

type
  EHiveDb = class(Exception);

  THiveSqlOp = class
  public
    SQL: string;
    Args: TArray<Variant>;
    constructor Create(const ASQL: string; const AArgs: array of Variant);
  end;

  THiveDatabase = class;

  THiveDelayThread = class(TThread)
  private
    FDb: THiveDatabase;
  protected
    procedure Execute; override;
  public
    constructor Create(ADb: THiveDatabase);
  end;

  THiveDatabase = class
  private
    FReadConn: TUniConnection;
    FWriteConn: TUniConnection;
    FProvider: TMySQLUniProvider;
    FWriteLock: TCriticalSection;   // guards FWriteConn, like SqlConnection::Lock
    FQueueLock: TCriticalSection;
    FQueue: TQueue<THiveSqlOp>;
    FWake: TEvent;
    FThread: THiveDelayThread;
    FAsyncAllowed: Boolean;
    FConnected: Boolean;
    FAbandoned: Boolean;
    procedure ConfigureConn(Conn: TUniConnection; const Host, Database, User, Password: string; Port: Integer);
    function RunOn(Conn: TUniConnection; const SQL: string; const Args: array of Variant; const What: string): Boolean;
    procedure DrainQueue;
    function ServerVersion: string;
  public
    constructor Create;
    destructor Destroy; override;

    function Initialise(const Host, Database, User, Password: string;
      Port: Integer): Boolean;

    { Caller owns the returned query and must free it. Nil on failure. }
    function Query(const SQL: string; const Args: array of Variant): TUniQuery;

    { Queued when async is enabled, otherwise executed inline. }
    function Execute(const SQL: string; const Args: array of Variant): Boolean;

    { Always synchronous, on the write connection. Use where the result is needed immediately - new character insert, trader qty. }
    function DirectExecute(const SQL: string; const Args: array of Variant): Boolean;

    procedure AllowAsyncOperations;
    {
      True when everything stopped cleanly. False means the worker would not stop and its resources have been deliberately leaked
      the caller must then NOT free this object either, or the thread is left dangling.
    }
    function Shutdown: Boolean;

    property Connected: Boolean read FConnected;
    property Abandoned: Boolean read FAbandoned;
  end;

implementation

const
  { SqlDelayThread's loopSleepMS }
  LoopSleepMS = 10;
  { How long Shutdown waits for the worker before giving up and abandoning it }
  ShutdownWaitMs = 1000;

//THiveSqlOp
constructor THiveSqlOp.Create(const ASQL: string; const AArgs: array of Variant);
var
  I: Integer;
begin
  inherited Create;
  SQL := ASQL;
  SetLength(Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Args[I] := AArgs[I];
end;

//THiveDelayThread
constructor THiveDelayThread.Create(ADb: THiveDatabase);
begin
  FDb := ADb;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure THiveDelayThread.Execute;
begin
  NameThreadForDebugging('HiveSqlDelay');
  while not Terminated do
  begin
    FDb.FWake.WaitFor(LoopSleepMS);
    FDb.DrainQueue;
  end;
  // empty whatever arrived while stopping, like ~SqlDelayThread
  FDb.DrainQueue;
end;

//THiveDatabase
constructor THiveDatabase.Create;
begin
  inherited Create;
  FWriteLock := TCriticalSection.Create;
  FQueueLock := TCriticalSection.Create;
  FQueue := TQueue<THiveSqlOp>.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FProvider := TMySQLUniProvider.Create(nil);
  FReadConn := TUniConnection.Create(nil);
  FWriteConn := TUniConnection.Create(nil);
end;

destructor THiveDatabase.Destroy;
begin
  if Shutdown then
  begin
    FreeAndNil(FReadConn);
    FreeAndNil(FWriteConn);
    FreeAndNil(FProvider);
    FreeAndNil(FQueue);
    FreeAndNil(FWake);
    FreeAndNil(FQueueLock);
    FreeAndNil(FWriteLock);
  end;
  // else the worker is still alive, so everything it touches is left in place deliberately - leaking beats faulting the Arma process on unload
  inherited;
end;

procedure THiveDatabase.ConfigureConn(Conn: TUniConnection; const Host, Database, User, Password: string; Port: Integer);
begin
  Conn.ProviderName := 'MySQL';
  Conn.Server := Host;
  Conn.Port := Port;
  Conn.Database := Database;
  Conn.Username := User;
  Conn.Password := Password;
  Conn.LoginPrompt := False;
  // UniDAC's MySQL provider is always direct - no client library involved, which is the entire point of replacing HiveExt.
  Conn.SpecificOptions.Values['MySQL.Charset'] := 'utf8mb4';
end;

function THiveDatabase.Initialise(const Host, Database, User, Password: string; Port: Integer): Boolean;
begin
  Result := False;
  try
    ConfigureConn(FReadConn, Host, Database, User, Password, Port);
    ConfigureConn(FWriteConn, Host, Database, User, Password, Port);
    FReadConn.Connect;
    FWriteConn.Connect;
    FConnected := True;
    // HiveExt logs "client ver: X server ver: Y" here. There is no client library in direct mode, so say so rather than inventing a version.
    HiveLog(hlInformation, 'Database', Format('Connected to MySQL database %s:%d/%s client ver: direct server ver: %s',
      [Host, Port, Database, ServerVersion]));
    FThread := THiveDelayThread.Create(Self);
    Result := True;
  except
    on E: Exception do
      HiveLog(hlError, 'Database', 'Failed to connect: ' + E.Message);
  end;
end;

procedure THiveDatabase.AllowAsyncOperations;
begin
  FAsyncAllowed := True;
end;

function THiveDatabase.Shutdown: Boolean;
var
  Op: THiveSqlOp;
begin
  Result := True;
  if FThread <> nil then
  begin
    FThread.Terminate;
    if FWake <> nil then
      FWake.SetEvent;

    {
      Bounded, not TThread.WaitFor. Shutdown runs from unit finalization, which during DLL_PROCESS_DETACH happens under the loader lock
      an unbounded wait there is a deadlock, and that is exactly how HiveExt hangs on unload.
    }
    if WaitForSingleObject(FThread.Handle, ShutdownWaitMs) = WAIT_OBJECT_0 then
      FreeAndNil(FThread)
    else
    begin
      {
        Either the worker is wedged in a query, or the OS already killed it at process exit - possibly mid-drain, still holding the write lock
        Freeing anything out from under it faults the host process, so abandon it all. We are on the way out regardless.
      }
      FAbandoned := True;
      FConnected := False;
      Exit(False);
    end;
  end;

//The worker is gone, so nothing should hold the write lock. TryEnter anyway: if it was killed while holding it, blocking here would hang the host.
  repeat
    Op := nil;
    FQueueLock.Enter;
    try
      if FQueue.Count > 0 then
        Op := FQueue.Dequeue;
    finally
      FQueueLock.Leave;
    end;
    if Op = nil then
      Break;
    try
      if not FWriteLock.TryEnter then
      begin
        HiveLog(hlError, 'Database', Format(
          'Write lock still held at shutdown; %d queued statement(s) not flushed',
          [FQueue.Count + 1]));
        Break;
      end;
      try
        RunOn(FWriteConn, Op.SQL, Op.Args, 'SqlExec');
      finally
        FWriteLock.Leave;
      end;
    finally
      Op.Free;
    end;
  until False;

  FConnected := False;
  try
    if (FReadConn <> nil) and FReadConn.Connected then
      FReadConn.Disconnect;
    if (FWriteConn <> nil) and FWriteConn.Connected then
      FWriteConn.Disconnect;
  except
    // shutting down anyway
  end;
end;

function THiveDatabase.ServerVersion: string;
var
  Q: TUniQuery;
begin
  Result := 'unknown';
  Q := TUniQuery.Create(nil);
  try
    try
      Q.Connection := FReadConn;
      Q.SQL.Text := 'SELECT VERSION()';
      Q.Open;
      if not Q.Eof then
        Result := Q.Fields[0].AsString;
    except
      // version is cosmetic, never fail the connect over it
    end;
  finally
    FreeAndNil(Q);
  end;
end;

{
  Bind Args[I] to the parameter literally named pI.

  Must be by NAME, not by position. Statements built from a sorted field list CHILD:201) emit :p0 somewhere other than first,
  so binding Params[I] := Args[I] silently writes each value into the wrong column.
}
procedure BindArgs(Q: TUniQuery; const Args: array of Variant);
var
  I: Integer;
  P: TDAParam;
begin
  for I := 0 to High(Args) do
  begin
    P := Q.FindParam('p' + IntToStr(I));
    if P <> nil then
      P.Value := Args[I];
  end;
end;

//HiveExt's trace appends the bound values after the statement, e.g. INSERT ... VALUES (?, ?) VALUES("14352902", -1)
function BoundValues(const Args: array of Variant): string;
var
  I: Integer;
  V: string;
begin
  if Length(Args) = 0 then
    Exit('');
  Result := ' VALUES(';
  for I := 0 to High(Args) do
  begin
    if I > 0 then
      Result := Result + ', ';
    if VarIsNull(Args[I]) or VarIsEmpty(Args[I]) then
      V := 'NULL'
    else if VarIsStr(Args[I]) then
      V := '"' + VarToStr(Args[I]) + '"'
    else
      V := VarToStr(Args[I]);
    Result := Result + V;
  end;
  Result := Result + ')';
end;

function THiveDatabase.RunOn(Conn: TUniConnection; const SQL: string; const Args: array of Variant; const What: string): Boolean;
var
  Q: TUniQuery;
  T0: Cardinal;
begin
  Result := False;
  Q := TUniQuery.Create(nil);
  try
    try
      Q.Connection := Conn;
      Q.SQL.Text := SQL;
      BindArgs(Q, Args);
      T0 := GetTickCount;
      Q.ExecSQL;
      if LogAccepts(hlTrace) then
        HiveLog(hlTrace, 'Database', Format('%s [%d ms] SQL: ''%s%s''', [What, GetTickCount - T0, SQL, BoundValues(Args)]))
      else if LogAccepts(hlDebug) then
        // at Debug the statement text is noise, but its effect is not - this is what answers "my data is not saving"
        HiveLog(hlDebug, 'Database', Format('%s [%d ms] %d row(s) affected', [What, GetTickCount - T0, Q.RowsAffected]));
      Result := True;
    except
      on E: Exception do
        HiveLog(hlError, 'Database', Format('%s failed: %s SQL: ''%s''',
          [What, E.Message, SQL]));
    end;
  finally
    FreeAndNil(Q);
  end;
end;

procedure THiveDatabase.DrainQueue;
var
  Op: THiveSqlOp;
begin
  repeat
    Op := nil;
    FQueueLock.Enter;
    try
      if FQueue.Count > 0 then
        Op := FQueue.Dequeue;
    finally
      FQueueLock.Leave;
    end;
    if Op = nil then
      Break;
    try
      FWriteLock.Enter;
      try
        RunOn(FWriteConn, Op.SQL, Op.Args, 'SqlExec');
      finally
        FWriteLock.Leave;
      end;
    finally
      Op.Free;
    end;
  until False;
end;

function THiveDatabase.Query(const SQL: string; const Args: array of Variant): TUniQuery;
var
  T0: Cardinal;
begin
  Result := TUniQuery.Create(nil);
  try
    Result.Connection := FReadConn;
    Result.SQL.Text := SQL;
    BindArgs(Result, Args);
    T0 := GetTickCount;
    Result.Open;
    if LogAccepts(hlTrace) then
      HiveLog(hlTrace, 'Database', Format('Query [%d ms] SQL: ''%s%s''', [GetTickCount - T0, SQL, BoundValues(Args)]))
    else if LogAccepts(hlDebug) then
      HiveLog(hlDebug, 'Database', Format('Query [%d ms] %d row(s) returned', [GetTickCount - T0, Result.RecordCount]));
  except
    on E: Exception do
    begin
      HiveLog(hlError, 'Database', Format('Query failed: %s SQL: ''%s''', [E.Message, SQL]));
      FreeAndNil(Result);
    end;
  end;
end;

function THiveDatabase.Execute(const SQL: string; const Args: array of Variant): Boolean;
var
  Depth: Integer;
begin
  if not FAsyncAllowed then
    Exit(DirectExecute(SQL, Args));

  FQueueLock.Enter;
  try
    FQueue.Enqueue(THiveSqlOp.Create(SQL, Args));
    Depth := FQueue.Count;
  finally
    FQueueLock.Leave;
  end;
  FWake.SetEvent;
  // a depth that keeps climbing means the worker is stalled or the DB is slow
  if (Depth > 1) and LogAccepts(hlDebug) then
    HiveLog(hlDebug, 'Database', Format('write queue depth %d', [Depth]));
  // HiveExt's execute() reports success on enqueue, not on completion
  Result := True;
end;

function THiveDatabase.DirectExecute(const SQL: string; const Args: array of Variant): Boolean;
begin
  FWriteLock.Enter;
  try
    Result := RunOn(FWriteConn, SQL, Args, 'DirectStmtExec');
  finally
    FWriteLock.Leave;
  end;
end;

end.
