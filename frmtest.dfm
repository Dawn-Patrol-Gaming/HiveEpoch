object FormTester: TFormTester
  Left = 527
  Top = 129
  Caption = 'DLL Extension Test'
  ClientHeight = 637
  ClientWidth = 975
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'MS Sans Serif'
  Font.Style = []
  OnClose = FormClose
  OnShow = FormShow
  TextHeight = 13
  object PanelTop: TPanel
    Left = 0
    Top = 0
    Width = 975
    Height = 73
    Align = alTop
    BevelInner = bvSpace
    BevelOuter = bvLowered
    TabOrder = 0
    object LabelEXT: TLabel
      Left = 695
      Top = 15
      Width = 75
      Height = 13
      Caption = 'Function Name:'
    end
    object LabelFN: TLabel
      Left = 30
      Top = 16
      Width = 50
      Height = 13
      Caption = 'File Name:'
    end
    object LabelParam: TLabel
      Left = 24
      Top = 43
      Width = 56
      Height = 13
      Caption = 'Parameters:'
    end
    object EditExtension: TEdit
      Left = 86
      Top = 12
      Width = 593
      Height = 21
      TabOrder = 0
      OnDblClick = EditExtensionDblClick
    end
    object EditParameters: TEdit
      Left = 86
      Top = 39
      Width = 593
      Height = 21
      TabOrder = 1
      Text = 'CHILD:302:11:false:'
    end
    object EditFunctionName: TEdit
      Left = 776
      Top = 12
      Width = 161
      Height = 21
      TabOrder = 2
      Text = '_RVExtension@12'
    end
    object ButtonExecute: TButton
      Left = 816
      Top = 37
      Width = 75
      Height = 25
      Caption = 'Execute'
      TabOrder = 3
      OnClick = ButtonExecuteClick
    end
  end
  object MemoOutput: TMemo
    Left = 0
    Top = 73
    Width = 975
    Height = 564
    Align = alClient
    ScrollBars = ssBoth
    TabOrder = 1
    WordWrap = False
  end
  object OpenDialog: TOpenDialog
    Filter = 'Application Extension|*.dll'
    Left = 840
    Top = 120
  end
end
