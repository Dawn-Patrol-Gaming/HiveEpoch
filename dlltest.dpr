program dlltest;

uses
  Forms,
  frmtest in 'frmtest.pas' {FormTester};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormTester, FormTester);
  Application.Run;
end.
