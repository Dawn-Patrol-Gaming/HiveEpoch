unit frmtest;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms, Dialogs, StdCtrls, Vcl.ExtCtrls;

type
  TDLLFunction = procedure(toArma: PAnsiChar; outputSize: Integer; fromArma: PAnsiChar); stdcall;

  TFormTester = class(TForm)
    OpenDialog: TOpenDialog;
    PanelTop: TPanel;
    MemoOutput: TMemo;
    EditExtension: TEdit;
    EditParameters: TEdit;
    EditFunctionName: TEdit;
    ButtonExecute: TButton;
    LabelEXT: TLabel;
    LabelFN: TLabel;
    LabelParam: TLabel;
    procedure EditExtensionDblClick(Sender: TObject);
    procedure ButtonExecuteClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  private
    { Private declarations }
    procedure LoadDLL;
  public
    { Public declarations }
  end;

var
  FormTester: TFormTester;
  HInst: THandle;
  FPointer: TFarProc;
  DLLFunc: TDLLFunction;

implementation

{$R *.dfm}

procedure TFormTester.EditExtensionDblClick(Sender: TObject);
begin
  if OpenDialog.Execute then
    EditExtension.Text := OpenDialog.FileName;
end;

procedure TFormTester.ButtonExecuteClick(Sender: TObject);
var
  TheResult: AnsiString;
begin
  try
    LoadDLL;
    SetLength(TheResult, 16384);

    DLLFunc(PAnsiChar(TheResult), 16384, PAnsiChar(AnsiString(EditParameters.Text)));
    if TheResult = '' then
      MessageDlg('Execution of library code failed.', mtError, [mbOK], 0);
    MemoOutput.Lines.Clear;
    MemoOutput.Lines.Add(TheResult);
  except
    on E: exception do
      MessageDlg('Test application: ' + E.Message, mtError, [mbOK], 0);
  end;

end;

procedure TFormTester.LoadDLL;
var
  TheFile: string;
begin
  TheFile := EditExtension.Text;
  HInst := SafeLoadLibrary(PChar(TheFile));
  if HInst > 0 then
  begin
    try
      FPointer := GetProcAddress(HInst, PChar(EditFunctionName.Text));
      if FPointer <> nil then
      begin
        DLLFunc := TDLLFunction(FPointer);
      end;
    except
      on E: exception do
        MessageDlg('Test application: ' + E.Message, mtError, [mbOK], 0);

    end;
  end
  else
    MessageDlg('Test application could not load dll', mtError, [mbOK], 0);
end;

procedure TFormTester.FormShow(Sender: TObject);
var
  TheFile: string;
  tmpstringlist: tstringlist;
begin
  if fileexists(ExtractFilePath(Application.ExeName) + 'defaultvalue.txt') then
  begin
    tmpstringlist := tstringlist.create;
    try
      tmpstringlist.loadfromfile(ExtractFilePath(Application.ExeName) + 'defaultvalue.txt');
      EditParameters.Text := tmpstringlist[0];
    finally
      freeandnil(tmpstringlist);
    end;

  end;
  if fileexists(extractfilepath(application.exename) + 'HiveExt.dll') or fileexists(extractfilepath(application.exename) + 'dzfunctions.dll') then
  begin
    if fileexists(extractfilepath(application.exename) + 'dzfunctions.dll') then
      EditExtension.Text := extractfilepath(application.exename) + 'dzfunctions.dll';
    if fileexists(extractfilepath(application.exename) + 'HiveExt.dll') then
      EditExtension.Text := extractfilepath(application.exename) + 'HiveExt.dll';
  end;
end;

procedure TFormTester.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  FreeLibrary(HInst);
  HInst := 0;
end;

end.

