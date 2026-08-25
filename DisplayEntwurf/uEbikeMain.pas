unit uEbikeMain;

{
  Ebike-Display Layoutsimulator - Hauptformular

  Das Formular wird vollstaendig im Quelltext aufgebaut, es gibt also
  bewusst KEINE .dfm-Datei. Damit laesst sich das Projekt ohne
  Designer-Gefummel in jede Delphi-Version uebernehmen.

  Bedienung:
    Schieberegler  -> Geschwindigkeit, Zeiger folgt live
    Kontrollkaesten-> Blinker und Warnsymbole schalten
    Demo           -> laesst die Geschwindigkeit selbstaendig pendeln
    Export-Knoepfe -> schreiben .h-Dateien neben die EXE
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  System.IOUtils, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Dialogs,
  uEbikeRender, uEbikeExport;

type
  TFormMain = class(TForm)
  private
    FStatic: TBitmap;      // nur Hintergrund
    FWork: TBitmap;        // Hintergrund + dynamische Ebene
    FLayout: TGaugeLayout;
    FState: TDisplayState;

    FPreview: TPaintBox;
    FZoom: Integer;

    FTrackSpeed: TTrackBar;
    FLblSpeed: TLabel;
    FEditOdo: TEdit;
    FChkLeft, FChkRight: TCheckBox;
    FChkBatt, FChkLight, FChkWarn, FChkTemp, FChkCheck: TCheckBox;
    FChkDemo: TCheckBox;
    FTimer: TTimer;
    FDemoDir: Integer;

    procedure BuildUI;
    function AddCheck(ALeft, ATop: Integer; const ACaption: string;
      AChecked: Boolean): TCheckBox;
    procedure Rebuild;
    procedure Refresh1;

    procedure PreviewPaint(Sender: TObject);
    procedure ControlChanged(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure ExportStaticClick(Sender: TObject);
    procedure ExportNeedleClick(Sender: TObject);
    procedure ExportFontClick(Sender: TObject);
    procedure ExportPngClick(Sender: TObject);

    procedure SaveText(const AFileName, AText: string);
  public
    { Create ruft bewusst CreateNew - dadurch braucht das Formular keine
      .dfm-Ressource, laesst sich aber trotzdem ueber Application.CreateForm
      als Hauptformular anlegen. }
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  FormMain: TFormMain;

implementation

constructor TFormMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);

  FZoom := 2;
  FLayout := DefaultLayout;
  FState := DefaultState;
  FDemoDir := 1;

  Caption := 'Ebike-Display Layoutsimulator - ESP32-S3-RLCD-4.2 (400 x 300)';
  Position := poScreenCenter;
  BorderStyle := bsSingle;
  ClientWidth := DISP_W * FZoom + 40;
  ClientHeight := DISP_H * FZoom + 210;
  Color := clBtnFace;

  FStatic := TBitmap.Create;
  FWork := TBitmap.Create;
  FWork.PixelFormat := pf24bit;
  FWork.SetSize(DISP_W, DISP_H);

  BuildUI;
  Rebuild;
end;

destructor TFormMain.Destroy;
begin
  FWork.Free;
  FStatic.Free;
  inherited;
end;

function TFormMain.AddCheck(ALeft, ATop: Integer; const ACaption: string;
  AChecked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(ALeft, ATop, 120, 21);
  Result.Caption := ACaption;
  Result.Checked := AChecked;
  Result.OnClick := ControlChanged;
end;

procedure TFormMain.BuildUI;
var
  Y, BtnY: Integer;
  B: TButton;
begin
  FPreview := TPaintBox.Create(Self);
  FPreview.Parent := Self;
  FPreview.SetBounds(20, 15, DISP_W * FZoom, DISP_H * FZoom);
  FPreview.OnPaint := PreviewPaint;

  Y := DISP_H * FZoom + 30;

  FLblSpeed := TLabel.Create(Self);
  FLblSpeed.Parent := Self;
  FLblSpeed.SetBounds(20, Y + 4, 120, 20);
  FLblSpeed.Caption := 'Geschwindigkeit';

  FTrackSpeed := TTrackBar.Create(Self);
  FTrackSpeed.Parent := Self;
  FTrackSpeed.SetBounds(140, Y, 420, 32);
  FTrackSpeed.Min := 0;
  FTrackSpeed.Max := FLayout.MaxSpeed * 10;
  FTrackSpeed.Frequency := 50;
  FTrackSpeed.Position := Round(FState.Speed * 10);
  FTrackSpeed.OnChange := ControlChanged;

  FEditOdo := TEdit.Create(Self);
  FEditOdo.Parent := Self;
  FEditOdo.SetBounds(640, Y + 2, 70, 24);
  FEditOdo.Text := IntToStr(FState.Odo);
  FEditOdo.OnChange := ControlChanged;

  with TLabel.Create(Self) do
  begin
    Parent := Self;
    SetBounds(580, Y + 6, 60, 20);
    Caption := 'km-Stand';
  end;

  Inc(Y, 40);

  FChkLeft  := AddCheck(20,  Y, 'Blinker links', False);
  FChkRight := AddCheck(150, Y, 'Blinker rechts', False);
  FChkDemo  := AddCheck(290, Y, 'Demolauf', False);

  Inc(Y, 26);

  FChkBatt  := AddCheck(20,  Y, 'Akku', True);
  FChkLight := AddCheck(150, Y, 'Licht', True);
  FChkWarn  := AddCheck(290, Y, 'Warnung', True);
  FChkTemp  := AddCheck(430, Y, 'Temperatur', True);
  FChkCheck := AddCheck(570, Y, 'Warntext', True);

  Inc(Y, 34);
  BtnY := Y;

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(20, BtnY, 175, 30);
  B.Caption := 'Hintergrund -> .h';
  B.OnClick := ExportStaticClick;

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(205, BtnY, 175, 30);
  B.Caption := 'Zeigertabelle -> .h';
  B.OnClick := ExportNeedleClick;

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(390, BtnY, 175, 30);
  B.Caption := 'Ziffernfont -> .h';
  B.OnClick := ExportFontClick;

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(575, BtnY, 175, 30);
  B.Caption := 'Vorschau -> BMP';
  B.OnClick := ExportPngClick;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
end;

procedure TFormMain.Rebuild;
begin
  DrawStaticLayer(FStatic, FLayout, FState);
  Refresh1;
end;

procedure TFormMain.Refresh1;
begin
  { Genau wie spaeter auf dem ESP32: Hintergrund kopieren, dann die
    dynamischen Elemente daruebermalen. }
  FWork.Canvas.Draw(0, 0, FStatic);
  DrawDynamicLayer(FWork, FLayout, FState);
  FPreview.Invalidate;
end;

procedure TFormMain.PreviewPaint(Sender: TObject);
var
  R: TRect;
begin
  SetStretchBltMode(FPreview.Canvas.Handle, COLORONCOLOR);
  R := Rect(0, 0, DISP_W * FZoom, DISP_H * FZoom);
  FPreview.Canvas.StretchDraw(R, FWork);
  FPreview.Canvas.Brush.Style := bsClear;
  FPreview.Canvas.Pen.Color := clGray;
  FPreview.Canvas.Rectangle(R);
end;

procedure TFormMain.ControlChanged(Sender: TObject);
var
  V: Integer;
begin
  FState.Speed := FTrackSpeed.Position / 10;
  if TryStrToInt(FEditOdo.Text, V) then
    FState.Odo := V;
  FState.BlinkLeft := FChkLeft.Checked;
  FState.BlinkRight := FChkRight.Checked;
  FState.IconBatt := FChkBatt.Checked;
  FState.IconLight := FChkLight.Checked;
  FState.IconWarn := FChkWarn.Checked;
  FState.IconTemp := FChkTemp.Checked;
  FState.ShowCheck := FChkCheck.Checked;
  Refresh1;
end;

procedure TFormMain.TimerTick(Sender: TObject);
var
  T: TDateTime;
  H, M, S, MS: Word;
  P: Integer;
begin
  T := Now;
  DecodeTime(T, H, M, S, MS);
  FState.Hour := H;
  FState.Minute := M;
  FState.Second := S;

  if FChkDemo.Checked then
  begin
    P := FTrackSpeed.Position + FDemoDir * 7;
    if P >= FTrackSpeed.Max then
    begin
      P := FTrackSpeed.Max;
      FDemoDir := -1;
    end
    else if P <= 0 then
    begin
      P := 0;
      FDemoDir := 1;
    end;
    FTrackSpeed.Position := P;  { loest ControlChanged aus }
  end;

  Refresh1;
end;

procedure TFormMain.SaveText(const AFileName, AText: string);
var
  FN: string;
begin
  FN := TPath.Combine(ExtractFilePath(ParamStr(0)), AFileName);
  TFile.WriteAllText(FN, AText, TEncoding.ASCII);
  ShowMessage('Geschrieben:'#13#10 + FN);
end;

procedure TFormMain.ExportStaticClick(Sender: TObject);
var
  Data: TMonoBytes;
begin
  Data := PackBitmap1bpp(FStatic);
  SaveText('gauge_background.h',
    '#pragma once'#13#10 +
    '#include <Arduino.h>'#13#10#13#10 +
    BuildLayoutHeaderC(FLayout) + #13#10 +
    BuildStaticLayerC(Data));
end;

procedure TFormMain.ExportNeedleClick(Sender: TObject);
begin
  SaveText('gauge_needle.h',
    '#pragma once'#13#10 +
    '#include <Arduino.h>'#13#10#13#10 +
    BuildNeedleTableC(FLayout, 2));   { 0,5-km/h-Schritte }
end;

procedure TFormMain.ExportFontClick(Sender: TObject);
begin
  SaveText('gauge_fonts.h',
    '#pragma once'#13#10 +
    '#include <Arduino.h>'#13#10#13#10 +
    BuildDigitFontC(26, True, 'fontBig') + #13#10 +
    BuildDigitFontC(16, True, 'fontClock', ':') + #13#10 +
    BuildDigitFontC(12, True, 'fontSmall'));
end;

procedure TFormMain.ExportPngClick(Sender: TObject);
var
  FN: string;
begin
  FN := TPath.Combine(ExtractFilePath(ParamStr(0)), 'preview.bmp');
  FWork.SaveToFile(FN);
  ShowMessage('Geschrieben:'#13#10 + FN);
end;

end.
