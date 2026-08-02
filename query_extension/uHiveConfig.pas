unit uHiveConfig;
{
  HiveExt.ini discovery and reading. Ports AppServer::initialize/initConfig plus
  ExtStartup::CreateApp's -profiles= handling.

  The profile directory comes off OUR process command line, exactly as the Arma
  server passes it, and defaults to "@hive" resolved against the current
  directory. The ini is then <profileDir>\HiveExt.ini.
}

interface

uses
  Windows, SysUtils, Classes, IniFiles;

type
  EHiveConfig = class(Exception);

  THiveConfig = class
  private
    //FAppDir: string;
    FAppName: string;
    FIniPath: string;
    FIni: TMemIniFile;
    FLoaded: Boolean;
  public
    constructor Create(const AAppName: string = 'HiveExt');
    destructor Destroy; override;

    { Reads the value, or returns Default when the key is absent or blank.
      Poco treats a present-but-empty value as absent for our purposes. }
    function ReadStr(const Section, Key, Default: string): string;
    function ReadInt(const Section, Key: string; Default: Integer): Integer;
    function ReadBool(const Section, Key: string; Default: Boolean): Boolean;
    function HasKey(const Section, Key: string): Boolean;

    //property AppDir: string read FAppDir;
    property AppName: string read FAppName;
    property IniPath: string read FIniPath;
    property Loaded: Boolean read FLoaded;
  end;


implementation

uses common;

constructor THiveConfig.Create(const AAppName: string);
begin
  inherited Create;
  FAppName := AAppName;
  //FAppDir := GetConfigDir;
  //if trim(FAppDir) = EmptyStr then FAppDir := GetCurrentDLLDirectory;
  FIniPath := MakeFileName(AppDir,FAppName + '.ini');
  FLoaded := FileExists(FIniPath);
  // TMemIniFile on a missing path just yields an empty config, which matches
  // Poco swallowing the IOException and carrying on with defaults.
  FIni := TMemIniFile.Create(FIniPath);
end;

destructor THiveConfig.Destroy;
begin
  FreeAndNil(FIni);
  inherited;
end;

function THiveConfig.HasKey(const Section, Key: string): Boolean;
begin
  Result := FIni.ValueExists(Section, Key) and (Trim(FIni.ReadString(Section, Key, '')) <> '');
end;

function THiveConfig.ReadStr(const Section, Key, Default: string): string;
begin
  Result := Trim(FIni.ReadString(Section, Key, ''));
  if Result = '' then
    Result := Default;
end;

function THiveConfig.ReadInt(const Section, Key: string; Default: Integer): Integer;
var
  S: string;
  V: Integer;
begin
  S := ReadStr(Section, Key, '');
  if S = '' then
    Exit(Default);
  if TryStrToInt(S, V) then
    Result := V
  else
    Result := Default;
end;

function THiveConfig.ReadBool(const Section, Key: string; Default: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(ReadStr(Section, Key, ''));
  if S = '' then
    Exit(Default);
  if (S = 'true') or (S = 'yes') or (S = 'on') or (S = '1') then
    Result := True
  else if (S = 'false') or (S = 'no') or (S = 'off') or (S = '0') then
    Result := False
  else
    Result := Default;
end;

end.
