unit uSQFValue;
{
  Copyright (C) 2009-2012 Rajko Stojadinovic (original C++ implementation)
  Copyright (C) 2026 Nathan Davalos (Delphi port)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  SQF value model, parser and serialiser - a Delphi port of Hive/Source/HiveLib/SQF.cpp (Boost.Spirit qi grammar + karma generator).

  Deliberately standalone: no DB, no Arma, no logging. Everything here is testable offline against captured HiveExt.dll behaviour

  Notes:
    - doubles print at 3 decimal places, trailing zeros dropped, one digit kept
    - scientific when abs >= 1e5 or abs < 1e-3, exponent zero-padded to 2
    - bool_ is lowercase-only, so TRUE/True stay strings
    - the Parameters generator does NOT quote strings; the Value generator does
}

interface

uses
  SysUtils, Classes, Math, Generics.Collections;


type
  ESQFError = class(Exception);
  { raised where the C++ would throw boost::bad_get }
  ESQFBadGet = class(ESQFError);

  TSQFKind = (skDouble, skInt32, skInt64, skBool, skString, skAny, skArray);

  TSQFValue = class
  private
    FKind: TSQFKind;
    FDbl: Double;
    FInt: Int64;
    FBool: Boolean;
    FStr: AnsiString;
    FItems: TObjectList<TSQFValue>;
    function GetItem(Index: Integer): TSQFValue;
    function GetCount: Integer;
    procedure Emit(var Buf: AnsiString; var Len: Integer; QuoteStrings: Boolean);
  public
    constructor CreateDouble(const V: Double);
    constructor CreateInt32(const V: Integer);
    constructor CreateInt64(const V: Int64);
    constructor CreateBool(const V: Boolean);
    constructor CreateStr(const V: AnsiString);
    constructor CreateAny;
    constructor CreateArray;
    destructor Destroy; override;

    { array building - takes ownership }
    procedure Add(V: TSQFValue);
    { empties an array in place, like SQF::Parameters::clear }
    procedure Clear;
    { array element removal, for SanitiseInv's magazines.erase }
    procedure DeleteItem(Index: Integer);
    { replaces element Index with an empty array - playerUpdate does this to any "any" it finds in the medical array }
    procedure ReplaceWithEmptyArray(Index: Integer);

    property Kind: TSQFKind read FKind;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TSQFValue read GetItem; default;

    { SQFValueGenerator - strings are quoted }
    function ToSQF: AnsiString;

    {
      SQF.cpp accessors. These throw exactly where the visitors throw bad_get, because a throw there aborts the handler
      and HiveExt then returns nothing.
    }
    function IsNull: Boolean;
    function IsAny: Boolean;
    function AsDouble: Double;
    function AsIntAny: Integer;
    function AsBigInt: Int64;
    function AsStringAny: AnsiString;
    function AsBoolAny: Boolean;
  end;

  TSQFScanner = record
    S: AnsiString;
    P: Integer;   // 1-based cursor
    N: Integer;
    procedure Init(const Text: AnsiString);
    function Eof: Boolean;
    function Cur: AnsiChar;
    procedure SkipWs;
    function ParseValue: TSQFValue;
  end;

  TSQFParams = class(TObjectList<TSQFValue>)
  public
    { SQFParametersGenerator - colon separated with a trailing colon, and strings NOT quoted. This is what HiveExt.log's "Params:" line shows. }
    function ToSQF: AnsiString;
  end;

{ Parse one SQF::Value. Returns nil if the text is not a well-formed value. }
function SQFParseValue(const S: AnsiString): TSQFValue;

{ Parse a full "a:b:c:" parameter string. Never returns nil; a malformed or unterminated tail is dropped, matching *(one_value >> ":"). }
function SQFParseParams(const S: AnsiString): TSQFParams;

{ Karma's real_policies<double> defaults. Exposed for testing. }
function SQFFormatDouble(const V: Double): AnsiString;

implementation

var
  { every numeric conversion here must be locale-independent }
  SQFFmt: TFormatSettings;

procedure AppendStr(var Buf: AnsiString; var Len: Integer; const S: AnsiString);
var
  N: Integer;
begin
  N := System.Length(S);
  if N = 0 then
    Exit;
  if Len + N > System.Length(Buf) then
    SetLength(Buf, Max((Len + N) * 2, 256));
  Move(S[1], Buf[Len + 1], N);
  Inc(Len, N);
end;

{
  Karma's rounding, confirmed against the real DLL over every midpoint case:
  split with modf, then floor(frac * 10^precision + 0.5) and carry.

  This is NOT printf and NOT banker's rounding. Exact binary midpoints go away from zero (0.0625 -> 0.063), yet 2.3455 -> 2.345,
  because the split happens before the scaling and the fractional part alone is what gets scaled.
  Delphi's Format('%.3f') disagrees on both counts, which is why it is not used here.
}
function FormatFixed(const V: Double; Precision: Integer): AnsiString;
var
  Neg: Boolean;
{
  Must be Double, not Extended. The C++ does this in double, and the intermediate rounding is load-bearing: 0.0545 * 1000 rounds UP to exactly
  54.5 in double, giving 0.055, but stays at 54.4999... in 80-bit and would give 0.054.
  Each step is assigned back to a Double on purpose so the x87 intermediate gets rounded to 64 bits like C.
}
  N, IP, Fr, PrecExp: Double;
  IntStr, FracStr: string;
  I: Integer;
begin
  Neg := V < 0;
  N := Abs(V);
  PrecExp := IntPower(10, Precision);

  IP := Int(N); // orig hive - truncation, not rounding
  Fr := N - IP;
  Fr := Fr * PrecExp;
  Fr := Fr + 0.5;
  Fr := Int(Fr);
  if Fr >= PrecExp then
  begin
    Fr := Fr - PrecExp;
    IP := IP + 1;
  end;

  IntStr := Format('%.0f', [IP], SQFFmt);
  FracStr := Format('%.*d', [Precision, Trunc(Fr)], SQFFmt);

  // drop trailing zeros, but always keep one digit after the dot
  I := System.Length(FracStr);
  while (I > 1) and (FracStr[I] = '0') do
    Dec(I);
  FracStr := Copy(FracStr, 1, I);
  if FracStr = '' then
    FracStr := '0';

  Result := AnsiString(IntStr + '.' + FracStr);
  if Neg then
    Result := '-' + Result;
end;

function SQFFormatDouble(const V: Double): AnsiString;
var
  A, Mant: Double;
  Ex: Integer;
  ExStr, MantStr: AnsiString;
begin
  if IsNan(V) or IsInfinite(V) then
  begin
    Result := AnsiString(FloatToStr(V, SQFFmt));
    Exit;
  end;

  A := Abs(V);
  // zero is always fixed, and karma drops the sign
  if A = 0 then
  begin
    Result := '0.0';
    Exit;
  end;

  // The fixed/scientific choice is made on the ORIGINAL value, before any rounding: 99999.9999 stays fixed and prints as 100000.0,
  // while 0.00099999999 goes scientific and prints as 1.0e-03
  if (A >= 1e5) or (A < 1e-3) then
  begin
    Ex := Floor(Log10(A));
    Mant := V / Power(10, Ex);
    // hive: log10/division can land just outside [1,10)
    if Abs(Mant) >= 10 then
    begin
      Mant := Mant / 10;
      Inc(Ex);
    end
    else if Abs(Mant) < 1 then
    begin
      Mant := Mant * 10;
      Dec(Ex);
    end;
    MantStr := FormatFixed(Mant, 3);
    // hive: rounding the mantissa to 3dp can carry it up to 10.0 - 9.9999e5 must come out as 1.0e06, not 10.0e05
    if Abs(StrToFloat(string(MantStr), SQFFmt)) >= 10 then
    begin
      Mant := Mant / 10;
      Inc(Ex);
      MantStr := FormatFixed(Mant, 3);
    end;
    if Ex < 0 then
      ExStr := AnsiString('-' + Format('%.2d', [-Ex], SQFFmt))
    else
      ExStr := AnsiString(Format('%.2d', [Ex], SQFFmt));
    Result := MantStr + 'e' + ExStr;
  end
  else
    Result := FormatFixed(V, 3);
end;

//TSQFValue
constructor TSQFValue.CreateDouble(const V: Double);
begin
  inherited Create;
  FKind := skDouble;
  FDbl := V;
end;

constructor TSQFValue.CreateInt32(const V: Integer);
begin
  inherited Create;
  FKind := skInt32;
  FInt := V;
end;

constructor TSQFValue.CreateInt64(const V: Int64);
begin
  inherited Create;
  FKind := skInt64;
  FInt := V;
end;

constructor TSQFValue.CreateBool(const V: Boolean);
begin
  inherited Create;
  FKind := skBool;
  FBool := V;
end;

constructor TSQFValue.CreateStr(const V: AnsiString);
begin
  inherited Create;
  FKind := skString;
  FStr := V;
end;

constructor TSQFValue.CreateAny;
begin
  inherited Create;
  FKind := skAny;
end;

constructor TSQFValue.CreateArray;
begin
  inherited Create;
  FKind := skArray;
  FItems := TObjectList<TSQFValue>.Create(True);
end;

destructor TSQFValue.Destroy;
begin
  FreeAndNil(FItems);
  inherited;
end;

procedure TSQFValue.Add(V: TSQFValue);
begin
  if FKind <> skArray then
    raise ESQFError.Create('Add on a non-array SQF value');
  FItems.Add(V);
end;

procedure TSQFValue.Clear;
begin
  if FKind = skArray then
    FItems.Clear;
end;

procedure TSQFValue.DeleteItem(Index: Integer);
begin
  if FKind = skArray then
    FItems.Delete(Index);
end;

procedure TSQFValue.ReplaceWithEmptyArray(Index: Integer);
begin
  if FKind = skArray then
    FItems[Index] := TSQFValue.CreateArray;
end;

function TSQFValue.GetItem(Index: Integer): TSQFValue;
begin
  if FKind <> skArray then
    raise ESQFBadGet.Create('Indexed access on a non-array SQF value');
  Result := FItems[Index];
end;

function TSQFValue.GetCount: Integer;
begin
  if FKind = skArray then
    Result := FItems.Count
  else
    Result := 0;
end;

procedure TSQFValue.Emit(var Buf: AnsiString; var Len: Integer; QuoteStrings: Boolean);
var
  I: Integer;
begin
  case FKind of
    skDouble:
      AppendStr(Buf, Len, SQFFormatDouble(FDbl));
    skInt32, skInt64:
      AppendStr(Buf, Len, AnsiString(IntToStr(FInt)));
    skBool:
      if FBool then
        AppendStr(Buf, Len, 'true')
      else
        AppendStr(Buf, Len, 'false');
    skString:
      if QuoteStrings then
      begin
        AppendStr(Buf, Len, '"');
        AppendStr(Buf, Len, FStr);
        AppendStr(Buf, Len, '"');
      end
      else
        AppendStr(Buf, Len, FStr);
    skAny:
      AppendStr(Buf, Len, 'any');
    skArray:
      begin
        AppendStr(Buf, Len, '[');
        for I := 0 to FItems.Count - 1 do
        begin
          if I > 0 then
            AppendStr(Buf, Len, ',');
          FItems[I].Emit(Buf, Len, QuoteStrings);
        end;
        AppendStr(Buf, Len, ']');
      end;
  end;
end;

function TSQFValue.ToSQF: AnsiString;
var
  Buf: AnsiString;
  Len: Integer;
begin
  Len := 0;
  SetLength(Buf, 256);
  Emit(Buf, Len, True);
  Result := Copy(Buf, 1, Len);
end;

function TSQFValue.IsNull: Boolean;
begin
  Result := (FKind = skString) and (FStr = '');
end;

function TSQFValue.IsAny: Boolean;
begin
  Result := FKind = skAny;
end;

function TSQFValue.AsDouble: Double;
begin
  case FKind of
    skDouble: Result := FDbl;
    skInt32:  Result := FInt;
  else
    // DecimalVisitor only handles double/float/int - Int64 and string throw
    raise ESQFBadGet.Create('SQF value is not a decimal');
  end;
end;

function TSQFValue.AsIntAny: Integer;
var
  V: Integer;
begin
  case FKind of
    skInt32:
      Result := FInt;
    skString:
      if TryStrToInt(string(FStr), V) then
        Result := V
      else
        raise ESQFBadGet.Create('SQF string is not an int');
  else
    raise ESQFBadGet.Create('SQF value is not an int');
  end;
end;

function TSQFValue.AsBigInt: Int64;
var
  V: Int64;
begin
  case FKind of
    skInt64, skInt32:
      Result := FInt;
    skDouble:
      begin
        Result := Trunc(FDbl);
        if Result <> FDbl then
          raise ESQFBadGet.Create('SQF double is not integral');
      end;
    skString:
      if TryStrToInt64(string(FStr), V) then
        Result := V
      else
        raise ESQFBadGet.Create('SQF string is not an int64');
  else
    raise ESQFBadGet.Create('SQF value is not an int64');
  end;
end;

function TSQFValue.AsStringAny: AnsiString;
begin
  if FKind = skString then
    Result := FStr
  else
    Result := ToSQF;
end;

function TSQFValue.AsBoolAny: Boolean;
var
  S: AnsiString;
  D: Double;
begin
  case FKind of
    skBool:   Result := FBool;
    skAny:    Result := False;
    skArray:  Result := FItems.Count > 0;
    skInt32,
    skInt64:  Result := FInt <> 0;
    skDouble: Result := FDbl <> 0;
    skString:
      begin
        S := AnsiString(Trim(string(FStr)));
        if S = '' then
          Result := False
        else if SameText(string(S), 'false') then
          Result := False
        else if SameText(string(S), 'true') then
          Result := True
        else if TryStrToFloat(string(S), D, SQFFmt) then
          Result := D <> 0
        else
          Result := True; // any non-numeric non-empty string is true
      end;
  else
    Result := False;
  end;
end;

//TSQFParams
function TSQFParams.ToSQF: AnsiString;
var
  Buf: AnsiString;
  Len, I: Integer;
begin
  Len := 0;
  SetLength(Buf, 256);
  for I := 0 to Count - 1 do
  begin
    Items[I].Emit(Buf, Len, False);
    AppendStr(Buf, Len, ':');
  end;
  Result := Copy(Buf, 1, Len);
end;

//TSQFScanner
procedure TSQFScanner.Init(const Text: AnsiString);
begin
  S := Text;
  P := 1;
  N := System.Length(Text);
end;

function TSQFScanner.Eof: Boolean;
begin
  Result := P > N;
end;

function TSQFScanner.Cur: AnsiChar;
begin
  if Eof then
    Result := #0
  else
    Result := S[P];
end;

procedure TSQFScanner.SkipWs;
begin
  while (P <= N) and (S[P] in [#9, #10, #13, ' ']) do
    Inc(P);
end;

function IsDigit(C: AnsiChar): Boolean; inline;
begin
  Result := C in ['0' .. '9'];
end;

//orig hive: a dot OR an exponent is required, so bare integers do not match here and fall through to the integer rules
function TryScanDouble(var Sc: TSQFScanner; out V: Double): Boolean;
var
  Start, Q: Integer;
  SawDigit, SawDot, SawExp: Boolean;
  Txt: AnsiString;
begin
  Result := False;
  Start := Sc.P;
  Q := Sc.P;
  SawDigit := False;
  SawDot := False;
  SawExp := False;

  if (Q <= Sc.N) and (Sc.S[Q] in ['+', '-']) then
    Inc(Q);
  while (Q <= Sc.N) and IsDigit(Sc.S[Q]) do
  begin
    SawDigit := True;
    Inc(Q);
  end;
  if (Q <= Sc.N) and (Sc.S[Q] = '.') then
  begin
    SawDot := True;
    Inc(Q);
    while (Q <= Sc.N) and IsDigit(Sc.S[Q]) do
    begin
      SawDigit := True;
      Inc(Q);
    end;
  end;
  if not SawDigit then
    Exit;
  if (Q <= Sc.N) and (Sc.S[Q] in ['e', 'E']) then
  begin
    var R: Integer := Q + 1;
    if (R <= Sc.N) and (Sc.S[R] in ['+', '-']) then
      Inc(R);
    if (R <= Sc.N) and IsDigit(Sc.S[R]) then
    begin
      while (R <= Sc.N) and IsDigit(Sc.S[R]) do
        Inc(R);
      Q := R;
      SawExp := True;
    end;
  end;

  if not (SawDot or SawExp) then
    Exit; // expect_dot - plain integers are not strict reals

  Txt := Copy(Sc.S, Start, Q - Start);
  if not TryStrToFloat(string(Txt), V, SQFFmt) then
    Exit;
  Sc.P := Q;
  Result := True;
end;

//orig hive: int_ >> !digit, then long_long - overflow at each width falls through
function TryScanInteger(var Sc: TSQFScanner; out V: Int64; out Fits32: Boolean): Boolean;
var
  Start, Q: Integer;
  Txt: AnsiString;
  I32: Integer;
begin
  Result := False;
  Fits32 := False;
  Start := Sc.P;
  Q := Sc.P;
  if (Q <= Sc.N) and (Sc.S[Q] in ['+', '-']) then
    Inc(Q);
  if (Q > Sc.N) or not IsDigit(Sc.S[Q]) then
    Exit;
  while (Q <= Sc.N) and IsDigit(Sc.S[Q]) do
    Inc(Q);

  Txt := Copy(Sc.S, Start, Q - Start);
  if TryStrToInt(string(Txt), I32) then
  begin
    V := I32;
    Fits32 := True;
    Sc.P := Q;
    Result := True;
  end
  else if TryStrToInt64(string(Txt), V) then
  begin
    Sc.P := Q;
    Result := True;
  end;
end;

function TryScanQuoted(var Sc: TSQFScanner; out V: AnsiString): Boolean;
var
  Q: Integer;
  Quote: AnsiChar;
begin
  Result := False;
  if Sc.Eof then
    Exit;
  Quote := Sc.S[Sc.P];
  if not (Quote in ['"', '''']) then
    Exit;
  Q := Sc.P + 1;
  // no escape handling, exactly like lexeme[q >> *(char_ - q) >> q]
  while (Q <= Sc.N) and (Sc.S[Q] <> Quote) do
    Inc(Q);
  if Q > Sc.N then
    Exit; // unterminated
  V := Copy(Sc.S, Sc.P + 1, Q - Sc.P - 1);
  Sc.P := Q + 1;
  Result := True;
end;

function TSQFScanner.ParseValue: TSQFValue;
var
  Save: Integer;
  D: Double;
  I: Int64;
  Fits32: Boolean;
  Str: AnsiString;
  Arr, Child: TSQFValue;
begin
  Result := nil;
  SkipWs;
  if Eof then
    Exit;
  Save := P;

  if TryScanDouble(Self, D) then
    Exit(TSQFValue.CreateDouble(D));
  P := Save;

  if TryScanInteger(Self, I, Fits32) then
  begin
    // the !digit guard: an integer immediately followed by a digit is not one
    if IsDigit(Cur) then
      P := Save
    else if Fits32 then
      Exit(TSQFValue.CreateInt32(I))
    else
      Exit(TSQFValue.CreateInt64(I));
  end;
  P := Save;

  // bool_ is lowercase only
  if (P + 3 <= N) and (Copy(S, P, 4) = 'true') then
  begin
    Inc(P, 4);
    Exit(TSQFValue.CreateBool(True));
  end;
  if (P + 4 <= N) and (Copy(S, P, 5) = 'false') then
  begin
    Inc(P, 5);
    Exit(TSQFValue.CreateBool(False));
  end;

  if TryScanQuoted(Self, Str) then
    Exit(TSQFValue.CreateStr(Str));
  P := Save;

  if (P + 2 <= N) and (Copy(S, P, 3) = 'any') then
  begin
    Inc(P, 3);
    Exit(TSQFValue.CreateAny);
  end;

  if Cur = '[' then
  begin
    Inc(P);
    Arr := TSQFValue.CreateArray;
    try
      SkipWs;
      if Cur <> ']' then
        repeat
          Child := ParseValue;
          if Child = nil then
          begin
            FreeAndNil(Arr);
            P := Save;
            Exit(nil);
          end;
          Arr.Add(Child);
          SkipWs;
          if Cur = ',' then
          begin
            Inc(P);
            Continue;
          end;
          Break;
        until False;
      SkipWs;
      if Cur <> ']' then
      begin
        FreeAndNil(Arr);
        P := Save;
        Exit(nil);
      end;
      Inc(P);
    except
      FreeAndNil(Arr);
      raise;
    end;
    Exit(Arr);
  end;

  P := Save;
end;

function SQFParseValue(const S: AnsiString): TSQFValue;
var
  Sc: TSQFScanner;
begin
  Sc.Init(S);
  Result := Sc.ParseValue;
  if Result <> nil then
  begin
    Sc.SkipWs;
    if not Sc.Eof then
      FreeAndNil(Result); // trailing junk - not a well-formed value
  end;
end;

function SQFParseParams(const S: AnsiString): TSQFParams;
var
  Sc: TSQFScanner;
  V: TSQFValue;
  Save, RawStart: Integer;
  Raw: AnsiString;
begin
  Result := TSQFParams.Create(True);
  Sc.Init(S);

//start = *(one_value >> ":") one_value = (value >> &lit(":")) | (lexeme[*(char_ - ":")] >> &lit(":"))
  while not Sc.Eof do
  begin
    Save := Sc.P;

    V := Sc.ParseValue;
    if V <> nil then
    begin
      Sc.SkipWs; // &lit(":") pre-skips under the space skipper
      if Sc.Cur = ':' then
      begin
        Result.Add(V);
        Inc(Sc.P);
        Continue;
      end;
      FreeAndNil(V);
      Sc.P := Save;
    end
    else
      Sc.P := Save;

    // raw fallback: lexeme pre-skips, then takes everything up to the next ':'
    Sc.SkipWs;
    RawStart := Sc.P;
    while (Sc.P <= Sc.N) and (Sc.S[Sc.P] <> ':') do
      Inc(Sc.P);
    if Sc.Cur <> ':' then
    begin
      Sc.P := Save; // no terminator - the tail is dropped
      Break;
    end;
    Raw := Copy(Sc.S, RawStart, Sc.P - RawStart);
    Result.Add(TSQFValue.CreateStr(Raw));
    Inc(Sc.P);
  end;
end;

initialization
  SQFFmt := TFormatSettings.Create;
  SQFFmt.DecimalSeparator := '.';
  SQFFmt.ThousandSeparator := #0;

end.
