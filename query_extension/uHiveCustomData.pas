unit uHiveCustomData;
{
  Copyright (C) 2009-2012 Rajko Stojadinovic (original C++ implementation)
  Copyright (C) 2026 Nathan Davalos (Delphi port)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.


  I personally do not recommend using any of this, I don't think I've ever seen anyone use this or know of anyone who realized this is here

  Port of HiveLib/DataSource/CustomDataSource.cpp - the CHILD:500-505 custom query API.

  501/502 build and run a select against a table that 500 has explicitly allowed, and hands back a token

  503 reports row/field counts

  504 pulls one row per call

  505 disposes. A token lives in exactly one of four buckets - active, pending, errored, cancelled

  Requests are always synchronous, because THiveDatabase.Query is

  502 is therefore accepted and answered immediately rather than ever reporting "WAIT"
  orig hive only returns "WAIT" while its async callback has not fired yet

  Callers poll 503 until it stops saying "WAIT", so answering straight away is a state they already handle
}

interface

uses
  SysUtils, Classes, Generics.Collections, DB, Uni,
  uSqfValue, uHiveDb;

type
  EHiveCustomData = class(Exception);
  { table not on the allow list }
  EDisallowedTable = class(EHiveCustomData);
  { malformed DbName.TableName }
  EInvalidTable = class(EHiveCustomData);
  { the SELECT itself failed }
  EDataFetch = class(EHiveCustomData);

  TDbSource = (dsChar, dsObj, dsUnknown);

  TTableInfo = record
    Dbase: TDbSource;
    Table: string;
    function ToString: string;
    class function Parse(Input: string): TTableInfo; static;
  end;

  TWhereOp = (opLT, opGT, opEqu, opNEqu, opIsNull, opIsNotNull,
    opLike, opNLike, opRLike, opNRLike, opCount);
  TLogicOp = (logAnd, logOr, logNot, logLB, logRB, logCount);

  TRequestState = (reqOk, reqPending, reqNoMoreRows, reqUnknown);

  { one active result set }
  TCustomRequest = class
  public
    Query: TUniQuery;
    Fetched: Boolean; // 504 advances before reading, like fetchRow()
    destructor Destroy; override;
  end;

  THiveCustomData = class
  private
    FCharDb: THiveDatabase;
    FObjDb: THiveDatabase;
    FAllowed: TList<TTableInfo>;
    FActive: TObjectDictionary<Cardinal, TCustomRequest>;
    FErrored: TDictionary<Cardinal, string>;
    function DbFor(Source: TDbSource): THiveDatabase;
    function NewToken: Cardinal;
    function GetRequestState(Token: Cardinal): TRequestState;
  public
    constructor Create(ACharDb, AObjDb: THiveDatabase);
    destructor Destroy; override;

    class procedure VerifyTable(const Name: string);
    function AllowTable(const Name: string): Boolean;
    function RemoveAllowedTable(const Name: string): Boolean;
    function GetAllowedTables: TArray<string>;

    function DataRequest(const TableName: string; const Columns: TArray<string>;
      Where: TSqfValue; LimitCount, LimitOffset: Int64): Cardinal;
    function RequestStatus(Token: Cardinal; out NumRows: Int64; out NumFields: Integer;
      out FieldNames: TArray<string>): TRequestState;
    function GetRowData(Token: Cardinal; Row: TSqfValue): TRequestState;
    function CloseRequest(Token: Cardinal): Boolean;
  end;

function WhereOpFromStr(S: string): TWhereOp;
function WhereOpToStr(Op: TWhereOp): string;
function TokenToHex(Token: Cardinal): string;
function HexToToken(S: string; out Token: Cardinal): Boolean;

implementation

uses
  StrUtils, Math;

{ ---------------------------------------------------------- TTableInfo --- }

function TTableInfo.ToString: string;
begin
  case Dbase of
    dsChar: Result := 'Character.' + Table;
    dsObj: Result := 'Object.' + Table;
  else
    Result := Table;
  end; //case Dbase of
end;

//"Char*.Table" / "Obj*.Table" - hive only compares the prefix, so Character" and "Char" are both accepted
class function TTableInfo.Parse(Input: string): TTableInfo;
var
  DotPos: Integer;
  DbName, Original: string;
begin
  Input := Trim(Input);
  Original := Input;
  if Input = '' then
    raise EInvalidTable.Create('TableInfo empty: ' + Input);

  DbName := '';
  Result.Table := '';
  DotPos := Pos('.', Input);
  if DotPos > 0 then
  begin
    DbName := Copy(Input, 1, DotPos - 1);
    if DotPos < Length(Input) then
      Result.Table := Copy(Input, DotPos + 1, MaxInt);
  end
  else
    Result.Table := Input;

  DbName := LowerCase(Trim(DbName));
  Result.Table := Trim(Result.Table);

  Result.Dbase := dsUnknown;
  if (Length(DbName) >= 4) and (Copy(DbName, 1, 4) = 'char') then
    Result.Dbase := dsChar
  else if (Length(DbName) >= 3) and (Copy(DbName, 1, 3) = 'obj') then
    Result.Dbase := dsObj;

  if Result.Dbase = dsUnknown then
    raise EInvalidTable.Create('TableInfo has unknown Database: ' + Original);
  if Result.Table = '' then
    raise EInvalidTable.Create('TableInfo has empty Table Name: ' + Original);
end;

function SameTable(const A, B: TTableInfo): Boolean;
begin
  Result := (A.Dbase = B.Dbase) and SameText(A.Table, B.Table);
end;

//operators
function WhereOpToStr(Op: TWhereOp): string;
begin
  case Op of
    opLT: Result := '<';
    opGT: Result := '>';
    opEqu: Result := '=';
    opNEqu: Result := '<>';
    opIsNull: Result := 'IS NULL';
    opIsNotNull: Result := 'IS NOT NULL';
    opLike: Result := 'LIKE';
    opNLike: Result := 'NOT LIKE';
    opRLike: Result := 'RLIKE';
    opNRLike: Result := 'NOT RLIKE';
  else
    Result := 'UNKNOWNOP';
  end;
end;

function WhereOpFromStr(S: string): TWhereOp;
var
  Prev: string;
begin
  S := UpperCase(Trim(S));
  repeat // collapse runs of spaces, like the C++ replace_all loop
    Prev := S;
    S := StringReplace(S, '  ', ' ', [rfReplaceAll]);
  until S = Prev;

  if S = '<' then
    Exit(opLT);
  if S = '>' then
    Exit(opGT);
  if S = '=' then
    Exit(opEqu);
  if (S = '<>') or (S = '!=') then
    Exit(opNEqu);
  if S = 'IS NULL' then
    Exit(opIsNull);
  if S = 'IS NOT NULL' then
    Exit(opIsNotNull);
  if S = 'LIKE' then
    Exit(opLike);
  if S = 'NOT LIKE' then
    Exit(opNLike);
  if (S = 'RLIKE') or (S = 'REGEXP') then
    Exit(opRLike);
  if (S = 'NOT RLIKE') or (S = 'NOT REGEXP') then
    Exit(opNRLike);
  Result := opCount;
end;

//"AND"/"OR"/"NOT", or a run of all-identical brackets
function GlueToSql(S: string; out Ok: Boolean): string;
var
  I: Integer;
  First: Char;
  Stripped: string;
begin
  Ok := True;
  S := UpperCase(Trim(S));
  if S = 'AND' then
    Exit('AND');
  if S = 'OR' then
    Exit('OR');
  if S = 'NOT' then
    Exit('NOT');

  Stripped := '';
  for I := 1 to Length(S) do
    if not CharInSet(S[I], [' ', #9, #10, #13]) then
      Stripped := Stripped + S[I];
  if Stripped = '' then
  begin
    Ok := False;
    Exit('');
  end;

  First := Stripped[1];
  for I := 2 to Length(Stripped) do
    if Stripped[I] <> First then
    begin
      Ok := False;
      Exit('');
    end;
  if not CharInSet(First, ['(', ')']) then
  begin
    Ok := False;
    Exit('');
  end;
  Result := StringOfChar(First, Length(Stripped));
end;

//tokens
function TokenToHex(Token: Cardinal): string;
var
  B: array[0..3] of Byte;
  I: Integer;
begin
  // Poco writes the raw UInt32 bytes in memory order, so little-endian
  Move(Token, B, SizeOf(B));
  Result := '';
  for I := 0 to 3 do
    Result := Result + LowerCase(IntToHex(B[I], 2));
end;

function HexToToken(S: string; out Token: Cardinal): Boolean;
var
  Clean: string;
  I, Nibble: Integer;
  B: array[0..3] of Byte;
begin
  Result := False;
  Token := 0;
  Clean := '';
  for I := 1 to Length(S) do
    if not CharInSet(S[I], [' ', #9, #10, #13]) then
      Clean := Clean + S[I];
  if Length(Clean) <> 8 then
    Exit;
  for I := 0 to 3 do
  begin
    if not TryStrToInt('$' + Copy(Clean, I * 2 + 1, 2), Nibble) then
      Exit;
    B[I] := Byte(Nibble);
  end;
  Move(B, Token, SizeOf(Token));
  Result := True;
end;

//TCustomRequest
destructor TCustomRequest.Destroy;
begin
  FreeAndNil(Query);
  inherited;
end;

//THiveCustomData
constructor THiveCustomData.Create(ACharDb, AObjDb: THiveDatabase);
begin
  inherited Create;
  FCharDb := ACharDb;
  FObjDb := AObjDb;
  FAllowed := TList<TTableInfo>.Create;
  FActive := TObjectDictionary<Cardinal, TCustomRequest>.Create([doOwnsValues]);
  FErrored := TDictionary<Cardinal, string>.Create;
  Randomize;
end;

destructor THiveCustomData.Destroy;
begin
  FreeAndNil(FActive);
  FreeAndNil(FErrored);
  FreeAndNil(FAllowed);
  inherited;
end;

function THiveCustomData.DbFor(Source: TDbSource): THiveDatabase;
begin
  if Source = dsObj then
    Result := FObjDb
  else
    Result := FCharDb;
end;

function THiveCustomData.NewToken: Cardinal;
begin
  repeat
    Result := (Cardinal(Random($10000)) shl 16) or Cardinal(Random($10000));
  until (Result <> 0) and not FActive.ContainsKey(Result) and not FErrored.ContainsKey(Result);
end;

class procedure THiveCustomData.VerifyTable(const Name: string);
begin
  TTableInfo.Parse(Name); // raises if malformed
end;

function THiveCustomData.AllowTable(const Name: string): Boolean;
var
  Info: TTableInfo;
  I: Integer;
begin
  Info := TTableInfo.Parse(Name);
  for I := 0 to FAllowed.Count - 1 do
    if SameTable(FAllowed[I], Info) then
      Exit(False);
  FAllowed.Add(Info);
  Result := True;
end;

function THiveCustomData.RemoveAllowedTable(const Name: string): Boolean;
var
  Info: TTableInfo;
  I: Integer;
begin
  Info := TTableInfo.Parse(Name);
  for I := 0 to FAllowed.Count - 1 do
    if SameTable(FAllowed[I], Info) then
    begin
      FAllowed.Delete(I);
      Exit(True);
    end;
  Result := False;
end;

function THiveCustomData.GetAllowedTables: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, FAllowed.Count);
  for I := 0 to FAllowed.Count - 1 do
    Result[I] := FAllowed[I].ToString;
end;

{
  builds the select, identifiers are backtick-quoted (sqlTableSim) and constants are inlined as quoted literals, exactly like the hive
  the whole point of the allow list is that these are attacker-adjacent strings, so the table must have been explicitly permitted by
  CHILD:500 first
}
function THiveCustomData.DataRequest(const TableName: string; const Columns: TArray<string>; Where: TSqfValue; LimitCount, LimitOffset: Int64):
  Cardinal;
var
  Info: TTableInfo;
  Db: THiveDatabase;
  SQL, Frag, Col, ConstStr: string;
  I, J: Integer;
  Found: Boolean;
  Elem: TSqfValue;
  Op: TWhereOp;
  LengthOf: Boolean;
  DotPos: Integer;
  AfterDot: string;
  Ok: Boolean;
  Req: TCustomRequest;
  Q: TUniQuery;
begin
  Info := TTableInfo.Parse(TableName);

  Found := False;
  for I := 0 to FAllowed.Count - 1 do
    if SameTable(FAllowed[I], Info) then
    begin
      Found := True;
      Break;
    end;
  if not Found then
    raise EDisallowedTable.Create('TableInfo not allowed: ' + Info.ToString);

  Db := DbFor(Info.Dbase);

  SQL := 'SELECT ';
  for I := 0 to High(Columns) do
  begin
    SQL := SQL + '`' + Columns[I] + '`';
    if I <> High(Columns) then
      SQL := SQL + ', ';
  end;
  SQL := SQL + ' FROM `' + Info.Table + '`';

  if (Where <> nil) and (Where.Kind = skArray) and (Where.Count > 0) then
  begin
    SQL := SQL + ' WHERE ';
    for I := 0 to Where.Count - 1 do
    begin
      Elem := Where[I];
      Frag := '';
      if Elem.Kind = skString then
      begin
        Frag := GlueToSql(string(Elem.AsStringAny), Ok);
        if not Ok then
          raise EHiveCustomData.Create(Format('WHERE[%d] Logical operator unknown: ''%s''',
            [I, string(Elem.AsStringAny)]));
      end//if Elem.Kind = skString then
      else if Elem.Kind = skArray then
      begin
        if Elem.Count < 2 then
          raise EHiveCustomData.Create(Format('WHERE[%d] Condition doesn''t have OP element', [I]));
        Col := Trim(string(Elem[0].AsStringAny));
        Op := WhereOpFromStr(string(Elem[1].AsStringAny));
        if Op = opCount then
          raise EHiveCustomData.Create(Format('WHERE[%d] Condition has unknown OP ''%s''',
            [I, string(Elem[1].AsStringAny)]));

        // a trailing ".length" on the column means compare its length
        LengthOf := False;
        DotPos := LastDelimiter('.', Col);
        if (DotPos > 0) and (DotPos < Length(Col)) then
        begin
          AfterDot := LowerCase(Trim(Copy(Col, DotPos + 1, MaxInt)));
          if AfterDot = 'length' then
          begin
            Col := Copy(Col, 1, DotPos - 1);
            LengthOf := True;
          end;//if AfterDot = 'length' then
        end;//if (DotPos > 0) and (DotPos < Length(Col)) then
        if Col = '' then
          raise EHiveCustomData.Create(Format('WHERE[%d] Condition COLUMN is empty', [I]));

        Frag := '`' + Col + '`';
        if LengthOf then
          Frag := 'LENGTH(' + Frag + ')';
        Frag := Frag + ' ' + WhereOpToStr(Op);

        if not (Op in [opIsNull, opIsNotNull]) then
        begin
          if Elem.Count < 3 then
            raise EHiveCustomData.Create(Format('WHERE[%d] Condition doesn''t have CONSTANT element', [I]));
          ConstStr := string(Elem[2].AsStringAny);
          Frag := Frag + ' ''' + StringReplace(ConstStr, '''', '''''', [rfReplaceAll]) + '''';
        end;//if not (Op in [opIsNull, opIsNotNull]) then
      end//else if Elem.Kind = skArray then
      else
        raise EHiveCustomData.Create(Format('WHERE[%d] not a string or array', [I]));

      SQL := SQL + Frag;
      if I <> Where.Count - 1 then
        SQL := SQL + ' ';
    end;//for I := 0 to Where.Count - 1 do
  end;//if (Where <> nil) and (Where.Kind = skArray) and (Where.Count > 0) then

  if (LimitCount >= 0) or (LimitOffset > 0) then
  begin
    SQL := SQL + ' LIMIT ';
    if LimitCount < 0 then
      LimitCount := 0;
    if LimitOffset > 0 then
      SQL := SQL + IntToStr(LimitOffset) + ',';
    SQL := SQL + IntToStr(LimitCount);
  end;//if (LimitCount >= 0) or (LimitOffset > 0) then

  Q := Db.Query(SQL, []);
  if Q = nil then
    raise EDataFetch.Create('Error: SQL Error running query: ' + SQL);

  Req := TCustomRequest.Create;
  Req.Query := Q;
  Result := NewToken;
  FActive.Add(Result, Req);
end;

function THiveCustomData.GetRequestState(Token: Cardinal): TRequestState;
var
  Msg: string;
begin
  if FErrored.TryGetValue(Token, Msg) then
  begin
    FErrored.Remove(Token); // reading the error clears it, like the C++
    raise EDataFetch.Create(Msg);
  end;
  Result := reqUnknown;
end;

function THiveCustomData.RequestStatus(Token: Cardinal; out NumRows: Int64; out NumFields: Integer; out FieldNames: TArray<string>): TRequestState;
var
  Req: TCustomRequest;
  I: Integer;
begin
  NumRows := 0;
  NumFields := 0;
  SetLength(FieldNames, 0);
  if FActive.TryGetValue(Token, Req) then
  begin
    NumRows := Req.Query.RecordCount;
    NumFields := Req.Query.FieldCount;
    SetLength(FieldNames, NumFields);
    for I := 0 to NumFields - 1 do
      FieldNames[I] := Req.Query.Fields[I].FieldName;
    Exit(reqOk);
  end;//if FActive.TryGetValue(Token, Req) then
  Result := GetRequestState(Token);
end;

//One row per call. A NULL column comes back as boolean false, everything else as a string
function THiveCustomData.GetRowData(Token: Cardinal; Row: TSqfValue): TRequestState;
var
  Req: TCustomRequest;
  I: Integer;
  F: TField;
begin
  if FActive.TryGetValue(Token, Req) then
  begin
    if Req.Fetched then
      Req.Query.Next;
    Req.Fetched := True;
    if Req.Query.Eof then
      Exit(reqNoMoreRows);

    for I := 0 to Req.Query.FieldCount - 1 do
    begin
      F := Req.Query.Fields[I];
      if F.IsNull then
        Row.Add(TSqfValue.CreateBool(False))
      else
        Row.Add(TSqfValue.CreateStr(AnsiString(F.AsString)));
    end;//for I := 0 to Req.Query.FieldCount - 1 do
    Exit(reqOk);
  end;
  Result := GetRequestState(Token);
end;

function THiveCustomData.CloseRequest(Token: Cardinal): Boolean;
begin
  if FActive.ContainsKey(Token) then
  begin
    FActive.Remove(Token); // owns values, so the query is freed
    Exit(True);
  end;//if FActive.ContainsKey(Token) then
  if FErrored.ContainsKey(Token) then
  begin
    FErrored.Remove(Token);
    Exit(True);
  end;//if FErrored.ContainsKey(Token) then
  Result := False;
end;

end.

