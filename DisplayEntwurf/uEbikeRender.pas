unit uEbikeRender;

{
  Ebike-Display Layout-Renderer
  Zielhardware: Waveshare ESP32-S3-RLCD-4.2 (ST7305, 400 x 300, 1 bpp, s/w)

  Alles wird ausschliesslich in Schwarz und Weiss gezeichnet, ohne
  Antialiasing - so wie es spaeter auf dem Reflexivdisplay aussieht.

  Zweischichtiges Modell (identisch zur spaeteren ESP32-Umsetzung):
    STATISCHE EBENE : Rahmen, Skala, Ticks, Skalenbeschriftung, km/h, Branding
                      -> wird einmal gerendert und als PROGMEM-Array exportiert
    DYNAMISCHE EBENE: Zeiger, Digitalanzeige, Uhr, Blinker, Icon-Kaesten
                      -> wird auf dem ESP32 pro Frame in die Dirty-Rects gemalt
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Types, System.Math, Vcl.Graphics;

const
  DISP_W = 400;
  DISP_H = 300;

  { Ankerpunkte der beweglichen Texte. Delphi zeichnet hier, der ESP32
    setzt seine Bitmap-Fonts an dieselben Koordinaten. }
  CLOCK_CX    = 150;   CLOCK_TOP  = 18;
  ODO_CX      = 140;   ODO_TOP    = 222;
  SPEED_RIGHT = 218;   SPEED_TOP  = 248;

  { Fuer den Pixel-Look: 'Consolas' geht sofort, echter Retro-Look kommt mit
    einem Bitmap-Font wie 'Px437 IBM VGA8' oder 'Perfect DOS VGA 437'.
    Einfach hier umstellen, sobald der Font installiert ist. }
  FONT_NAME = 'Consolas';

type
  TGaugeLayout = record
    CX, CY: Integer;              // Drehpunkt des Zeigers
    RTickOuter: Integer;          // Aussenradius aller Ticks
    RTickMajorIn: Integer;        // Innenradius Hauptstriche
    RTickMinorIn: Integer;        // Innenradius Zwischenstriche
    RLabel: Integer;              // Radius der Zahlenbeschriftung
    NeedleLen: Integer;           // Zeigerlaenge
    HubR: Integer;                // Radius der Zeigernabe
    StartAngle: Double;           // Grad, math. Konvention (0 = rechts)
    SweepAngle: Double;           // negativ = im Uhrzeigersinn
    MaxSpeed: Integer;            // Skalenendwert in km/h
    MajorStep: Integer;           // Beschriftungsschritt
    MinorPerMajor: Integer;       // Zwischenstriche je Hauptabschnitt
  end;

  TArrowPoly = array[0..6] of TPoint;

  TDisplayState = record
    Speed: Double;                // km/h
    Odo: Integer;                 // Gesamtkilometer
    Hour, Minute, Second: Integer;
    BlinkLeft, BlinkRight: Boolean;
    IconBatt, IconLight, IconWarn, IconTemp: Boolean;
    ShowCheck: Boolean;           // Warntext oben rechts
    CornerLine1, CornerLine2: string;
    Brand: string;
  end;

function DefaultLayout: TGaugeLayout;
function DefaultState: TDisplayState;

function SpeedToAngle(const L: TGaugeLayout; ASpeed: Double): Double;
procedure PolarPoint(const L: TGaugeLayout; AAngleDeg: Double; R: Integer;
  out X, Y: Integer);

procedure DrawStaticLayer(ABmp: TBitmap; const L: TGaugeLayout;
  const S: TDisplayState);
procedure DrawDynamicLayer(ABmp: TBitmap; const L: TGaugeLayout;
  const S: TDisplayState);

{ Liefert das Rechteck, das der Zeiger maximal ueberstreicht - auf dem ESP32
  der Bereich, der pro Frame aus dem Hintergrund-Array nachgeladen wird. }
function NeedleBounds(const L: TGaugeLayout): TRect;

{ Geometrie, die der ESP32 ebenfalls kennen muss. Sie wird ueber
  BuildLayoutHeaderC mitexportiert, damit Simulator und Sketch nie
  auseinanderlaufen. }
function IconRect(AIndex: Integer): TRect;    // 0=Akku 1=Licht 2=Warnung 3=Temp
function CheckRect: TRect;
function ArrowRect(ALeft: Boolean): TRect;
procedure ArrowPolygon(const R: TRect; ALeft: Boolean; out P: TArrowPoly);

implementation

const
  { Rechte Icon-Spalte }
  COL_X0 = 264;
  COL_X1 = 384;
  BOX_H  = 48;
  BOX_Y0 = 78;
  BOX_GAP = 4;

procedure SetPixelFont(C: TCanvas; ASize: Integer; ABold: Boolean;
  AColor: TColor = clBlack);
begin
  C.Font.Name := FONT_NAME;
  C.Font.Size := ASize;
  C.Font.Quality := fqNonAntialiased;
  if ABold then
    C.Font.Style := [fsBold]
  else
    C.Font.Style := [];
  C.Font.Color := AColor;
  C.Brush.Style := bsClear;
end;

procedure TextCentered(C: TCanvas; ACenterX, ATop: Integer; const S: string);
begin
  C.TextOut(ACenterX - C.TextWidth(S) div 2, ATop, S);
end;

procedure TextRight(C: TCanvas; ARight, ATop: Integer; const S: string);
begin
  C.TextOut(ARight - C.TextWidth(S), ATop, S);
end;

function DefaultLayout: TGaugeLayout;
begin
  Result.CX := 140;
  Result.CY := 185;
  Result.RTickOuter := 120;
  Result.RTickMajorIn := 101;
  Result.RTickMinorIn := 111;
  Result.RLabel := 97;
  Result.NeedleLen := 78;
  Result.HubR := 11;
  Result.StartAngle := 210;
  Result.SweepAngle := -240;
  Result.MaxSpeed := 45;
  Result.MajorStep := 5;
  Result.MinorPerMajor := 2;
end;

function DefaultState: TDisplayState;
begin
  Result.Speed := 27;
  Result.Odo := 70;
  Result.Hour := 16;
  Result.Minute := 15;
  Result.Second := 24;
  Result.BlinkLeft := False;
  Result.BlinkRight := False;
  Result.IconBatt := True;
  Result.IconLight := True;
  Result.IconWarn := True;
  Result.IconTemp := True;
  Result.ShowCheck := True;
  Result.CornerLine1 := 'RWTEC';
  Result.CornerLine2 := 'EBIKE';
  Result.Brand := 'RwTec';
end;

function SpeedToAngle(const L: TGaugeLayout; ASpeed: Double): Double;
var
  T: Double;
begin
  T := ASpeed / L.MaxSpeed;
  if T < 0 then T := 0;
  if T > 1 then T := 1;
  Result := L.StartAngle + L.SweepAngle * T;
end;

procedure PolarPoint(const L: TGaugeLayout; AAngleDeg: Double; R: Integer;
  out X, Y: Integer);
var
  A: Double;
begin
  A := DegToRad(AAngleDeg);
  X := L.CX + Round(R * Cos(A));
  Y := L.CY - Round(R * Sin(A));   // Bildschirm-Y zeigt nach unten
end;

function NeedleBounds(const L: TGaugeLayout): TRect;
var
  R: Integer;
begin
  R := L.NeedleLen + L.HubR + 3;
  Result := Rect(L.CX - R, L.CY - R, L.CX + R, L.CY + R);
  if Result.Left < 10 then Result.Left := 10;
  if Result.Top < 10 then Result.Top := 10;
  if Result.Right > DISP_W - 10 then Result.Right := DISP_W - 10;
  if Result.Bottom > DISP_H - 10 then Result.Bottom := DISP_H - 10;
end;

function IconRect(AIndex: Integer): TRect;
var
  Y: Integer;
begin
  Y := BOX_Y0 + AIndex * (BOX_H + BOX_GAP);
  Result := Rect(COL_X0, Y, COL_X1, Y + BOX_H);
end;

function CheckRect: TRect;
begin
  Result := Rect(COL_X0, 54, COL_X1, 73);
end;

function ArrowRect(ALeft: Boolean): TRect;
begin
  if ALeft then
    Result := Rect(25, 20, 85, 50)
  else
    Result := Rect(198, 20, 258, 50);
end;

procedure ArrowPolygon(const R: TRect; ALeft: Boolean; out P: TArrowPoly);
var
  MidY, HW, TH: Integer;
begin
  MidY := (R.Top + R.Bottom) div 2;
  HW := Round((R.Right - R.Left) * 0.42);
  TH := Round((R.Bottom - R.Top) * 0.26);

  if ALeft then
  begin
    P[0] := Point(R.Left, MidY);
    P[1] := Point(R.Left + HW, R.Top);
    P[2] := Point(R.Left + HW, MidY - TH);
    P[3] := Point(R.Right, MidY - TH);
    P[4] := Point(R.Right, MidY + TH);
    P[5] := Point(R.Left + HW, MidY + TH);
    P[6] := Point(R.Left + HW, R.Bottom);
  end
  else
  begin
    P[0] := Point(R.Right, MidY);
    P[1] := Point(R.Right - HW, R.Top);
    P[2] := Point(R.Right - HW, MidY - TH);
    P[3] := Point(R.Left, MidY - TH);
    P[4] := Point(R.Left, MidY + TH);
    P[5] := Point(R.Right - HW, MidY + TH);
    P[6] := Point(R.Right - HW, R.Bottom);
  end;
end;

{ ------------------------------------------------------------------ }
{  Statische Ebene                                                     }
{ ------------------------------------------------------------------ }

procedure DrawFrameBorder(C: TCanvas);
begin
  C.Pen.Color := clBlack;
  C.Brush.Style := bsClear;
  C.Pen.Width := 3;
  C.Rectangle(5, 5, DISP_W - 5, DISP_H - 5);
  C.Pen.Width := 2;
  C.Rectangle(12, 12, DISP_W - 12, DISP_H - 12);
end;

{ Striche werden als gefuellte Vierecke gezeichnet, nicht als dicke Linien.
  GDI setzt bei schraegen Linien mit Pen.Width > 1 die Endkappen unsauber -
  auf 1 bpp ohne Antialiasing sieht man jede ausgefranste Kante. }
procedure DrawTickPoly(C: TCanvas; const L: TGaugeLayout; AAngleDeg: Double;
  ARIn, AROut, AWidth: Integer);
var
  P: array[0..3] of TPoint;
  AP: Double;
  HX, HY, X1, Y1, X2, Y2: Integer;
begin
  AP := DegToRad(AAngleDeg + 90);
  HX := Round(AWidth / 2 * Cos(AP));
  HY := -Round(AWidth / 2 * Sin(AP));

  PolarPoint(L, AAngleDeg, ARIn, X1, Y1);
  PolarPoint(L, AAngleDeg, AROut, X2, Y2);

  P[0] := Point(X1 + HX, Y1 + HY);
  P[1] := Point(X2 + HX, Y2 + HY);
  P[2] := Point(X2 - HX, Y2 - HY);
  P[3] := Point(X1 - HX, Y1 - HY);

  C.Pen.Color := clBlack;
  C.Pen.Width := 1;
  C.Brush.Color := clBlack;
  C.Brush.Style := bsSolid;
  C.Polygon(P);
end;

procedure DrawScale(C: TCanvas; const L: TGaugeLayout);
var
  I, Steps, LX, LY, TW, TH: Integer;
  A: Double;
  IsMajor: Boolean;
  Val: Double;
  S: string;
begin
  Steps := (L.MaxSpeed div L.MajorStep) * L.MinorPerMajor;

  for I := 0 to Steps do
  begin
    Val := L.MaxSpeed * I / Steps;
    A := SpeedToAngle(L, Val);
    IsMajor := (I mod L.MinorPerMajor) = 0;

    if IsMajor then
      DrawTickPoly(C, L, A, L.RTickMajorIn, L.RTickOuter, 5)
    else
      DrawTickPoly(C, L, A, L.RTickMinorIn, L.RTickOuter, 3);

    if IsMajor then
    begin
      SetPixelFont(C, 10, True);
      S := IntToStr(Round(Val));
      TW := C.TextWidth(S);
      TH := C.TextHeight(S);

      { RLabel ist der Radius, den die AEUSSERE Kante der Zahl erreichen
        darf. Der Mittelpunkt wandert deshalb um die halbe Textausdehnung
        in radialer Richtung nach innen - sonst schieben sich breite Zahlen
        wie 45 seitlich in ihren eigenen Strich. }
      PolarPoint(L, A, L.RLabel, LX, LY);
      LX := LX - Round(TW / 2 * Cos(DegToRad(A)));
      LY := LY + Round(TH / 2 * Sin(DegToRad(A)));

      C.Brush.Style := bsClear;
      C.TextOut(LX - TW div 2, LY - TH div 2, S);
    end;
  end;
  C.Pen.Width := 1;
end;

{ Vorwaertsdeklarationen - die Zeichenroutinen fuer Symbole und Pfeile
  stehen weiter unten, werden aber schon von der statischen Ebene gebraucht. }
procedure DrawBatteryIcon(C: TCanvas; const R: TRect; AActive: Boolean); forward;
procedure DrawLightIcon(C: TCanvas; const R: TRect; AActive: Boolean); forward;
procedure DrawWarnIcon(C: TCanvas; const R: TRect; AActive: Boolean); forward;
procedure DrawTempIcon(C: TCanvas; const R: TRect; AActive: Boolean); forward;
procedure DrawArrow(C: TCanvas; const R: TRect; ALeft, AFilled: Boolean); forward;

procedure DrawStaticLayer(ABmp: TBitmap; const L: TGaugeLayout;
  const S: TDisplayState);
var
  C: TCanvas;
begin
  ABmp.PixelFormat := pf24bit;
  ABmp.SetSize(DISP_W, DISP_H);
  C := ABmp.Canvas;

  C.Brush.Color := clWhite;
  C.Brush.Style := bsSolid;
  C.FillRect(Rect(0, 0, DISP_W, DISP_H));

  DrawFrameBorder(C);
  DrawScale(C, L);

  { Unterstrich unter der Uhr }
  C.Pen.Color := clBlack;
  C.Pen.Width := 3;
  C.MoveTo(84, 50);
  C.LineTo(216, 50);
  C.Pen.Width := 1;

  { Einheit }
  SetPixelFont(C, 11, True);
  C.TextOut(228, 266, 'km/h');

  { Branding im Zifferblatt }
  SetPixelFont(C, 9, False);
  TextCentered(C, 92, 162, S.Brand);

  { Text oben rechts }
  SetPixelFont(C, 8, True);
  TextCentered(C, (COL_X0 + COL_X1) div 2, 18, S.CornerLine1);
  TextCentered(C, (COL_X0 + COL_X1) div 2, 30, S.CornerLine2);

  { Warntext - immer zeichnen. Soll er aus sein, uebermalt die dynamische
    Ebene sein Rechteck einfach weiss. }
  SetPixelFont(C, 10, True);
  TextCentered(C, (COL_X0 + COL_X1) div 2, 56, 'CHECK ENGINE!');

  { Symbole im Ruhezustand: weisser Kasten, schwarzes Symbol. Der aktive
    Zustand entsteht spaeter durch Umkehren des Rechtecks. }
  DrawBatteryIcon(C, IconRect(0), False);
  DrawLightIcon(C, IconRect(1), False);
  DrawWarnIcon(C, IconRect(2), False);
  DrawTempIcon(C, IconRect(3), False);

  { Blinkerpfeile als Umriss }
  DrawArrow(C, ArrowRect(True), True, False);
  DrawArrow(C, ArrowRect(False), False, False);
end;

{ ------------------------------------------------------------------ }
{  Icons                                                               }
{ ------------------------------------------------------------------ }

procedure PrepIcon(C: TCanvas; const R: TRect; AActive: Boolean);
begin
  C.Pen.Color := clBlack;
  C.Pen.Width := 2;
  if AActive then
    C.Brush.Color := clBlack
  else
    C.Brush.Color := clWhite;
  C.Brush.Style := bsSolid;
  C.Rectangle(R);
  if AActive then
  begin
    C.Pen.Color := clWhite;
    C.Brush.Color := clWhite;
  end
  else
  begin
    C.Pen.Color := clBlack;
    C.Brush.Color := clBlack;
  end;
  C.Brush.Style := bsSolid;
end;

procedure DrawBatteryIcon(C: TCanvas; const R: TRect; AActive: Boolean);
var
  CXm, CYm, I, BX: Integer;
begin
  PrepIcon(C, R, AActive);
  CXm := (R.Left + R.Right) div 2;
  CYm := (R.Top + R.Bottom) div 2;

  C.Pen.Width := 3;
  C.Brush.Style := bsClear;
  C.Rectangle(CXm - 22, CYm - 15, CXm + 22, CYm + 2);
  C.Brush.Style := bsSolid;
  C.FillRect(Rect(CXm - 14, CYm - 20, CXm - 6, CYm - 15));
  C.FillRect(Rect(CXm + 6, CYm - 20, CXm + 14, CYm - 15));

  { Balkenanzeige darunter }
  for I := 0 to 3 do
  begin
    BX := CXm - 22 + I * 12;
    C.FillRect(Rect(BX, CYm + 7, BX + 8, CYm + 15));
  end;
end;

procedure DrawLightIcon(C: TCanvas; const R: TRect; AActive: Boolean);
var
  CXm, CYm, I, Y: Integer;
begin
  PrepIcon(C, R, AActive);
  CXm := (R.Left + R.Right) div 2;
  CYm := (R.Top + R.Bottom) div 2;

  { Scheinwerferkoerper: halbrunde Form }
  C.Pen.Width := 1;
  C.Pie(CXm - 34, CYm - 16, CXm + 4, CYm + 16,
        CXm - 15, CYm - 16, CXm - 15, CYm + 16);
  C.FillRect(Rect(CXm - 15, CYm - 16, CXm - 4, CYm + 16));

  { Lichtstrahlen }
  C.Pen.Width := 3;
  for I := 0 to 2 do
  begin
    Y := CYm - 10 + I * 10;
    C.MoveTo(CXm + 2, Y);
    C.LineTo(CXm + 22, Y + 5);
  end;
end;

procedure DrawWarnIcon(C: TCanvas; const R: TRect; AActive: Boolean);
var
  CXm, CYm: Integer;
begin
  PrepIcon(C, R, AActive);
  CXm := (R.Left + R.Right) div 2;
  CYm := (R.Top + R.Bottom) div 2;

  C.Pen.Width := 3;
  C.Brush.Style := bsClear;
  C.Ellipse(CXm - 13, CYm - 13, CXm + 13, CYm + 13);
  C.Brush.Style := bsSolid;

  { Ausrufezeichen }
  C.FillRect(Rect(CXm - 2, CYm - 8, CXm + 2, CYm + 2));
  C.FillRect(Rect(CXm - 2, CYm + 5, CXm + 2, CYm + 9));

  { Seitliche Klammern }
  C.Pen.Width := 3;
  C.Arc(CXm - 24, CYm - 18, CXm + 24, CYm + 18,
        CXm - 24, CYm - 8, CXm - 24, CYm + 8);
  C.Arc(CXm - 24, CYm - 18, CXm + 24, CYm + 18,
        CXm + 24, CYm + 8, CXm + 24, CYm - 8);
end;

procedure DrawTempIcon(C: TCanvas; const R: TRect; AActive: Boolean);
var
  CXm, CYm, I, Y: Integer;
begin
  PrepIcon(C, R, AActive);
  CXm := (R.Left + R.Right) div 2;
  CYm := (R.Top + R.Bottom) div 2;

  { Stiel }
  C.Pen.Width := 1;
  C.FillRect(Rect(CXm - 4, CYm - 18, CXm + 4, CYm + 6));
  { Kolben }
  C.Ellipse(CXm - 9, CYm + 1, CXm + 9, CYm + 19);

  { Skalenstriche links }
  C.Pen.Width := 2;
  for I := 0 to 2 do
  begin
    Y := CYm - 14 + I * 7;
    C.MoveTo(CXm - 12, Y);
    C.LineTo(CXm - 6, Y);
  end;
end;

{ ------------------------------------------------------------------ }
{  Blinkerpfeile                                                       }
{ ------------------------------------------------------------------ }

procedure DrawArrow(C: TCanvas; const R: TRect; ALeft, AFilled: Boolean);
var
  P: TArrowPoly;
begin
  ArrowPolygon(R, ALeft, P);
  C.Pen.Color := clBlack;
  C.Pen.Width := 3;
  if AFilled then
    C.Brush.Color := clBlack
  else
    C.Brush.Color := clWhite;
  C.Brush.Style := bsSolid;
  C.Polygon(P);
end;

{ Kehrt einen Bereich um: aus weiss wird schwarz und umgekehrt. Genau so
  macht es der ESP32 auch - dadurch braucht er keinen eigenen Zeichencode
  fuer die vier Symbole. }
procedure InvertRect(ABmp: TBitmap; const R: TRect);
var
  X, Y: Integer;
  Row: PByteArray;
begin
  for Y := R.Top to R.Bottom - 1 do
  begin
    if (Y < 0) or (Y >= ABmp.Height) then Continue;
    Row := ABmp.ScanLine[Y];
    for X := R.Left to R.Right - 1 do
    begin
      if (X < 0) or (X >= ABmp.Width) then Continue;
      Row^[X * 3]     := 255 - Row^[X * 3];
      Row^[X * 3 + 1] := 255 - Row^[X * 3 + 1];
      Row^[X * 3 + 2] := 255 - Row^[X * 3 + 2];
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{  Zeiger                                                              }
{ ------------------------------------------------------------------ }

procedure DrawNeedle(C: TCanvas; const L: TGaugeLayout; ASpeed: Double);
var
  A, AP: Double;
  P: array[0..3] of TPoint;
  TipX, TipY: Integer;
  BW, TailR: Integer;
begin
  A := SpeedToAngle(L, ASpeed);
  AP := A + 90;
  BW := 5;
  TailR := 14;

  PolarPoint(L, A, L.NeedleLen, TipX, TipY);

  P[0] := Point(TipX, TipY);
  P[1] := Point(L.CX + Round(BW * Cos(DegToRad(AP))),
                L.CY - Round(BW * Sin(DegToRad(AP))));
  P[2] := Point(L.CX - Round(TailR * Cos(DegToRad(A))),
                L.CY + Round(TailR * Sin(DegToRad(A))));
  P[3] := Point(L.CX - Round(BW * Cos(DegToRad(AP))),
                L.CY + Round(BW * Sin(DegToRad(AP))));

  C.Pen.Color := clBlack;
  C.Pen.Width := 1;
  C.Brush.Color := clBlack;
  C.Brush.Style := bsSolid;
  C.Polygon(P);

  { Nabe }
  C.Pen.Width := 4;
  C.Brush.Color := clWhite;
  C.Ellipse(L.CX - L.HubR, L.CY - L.HubR, L.CX + L.HubR, L.CY + L.HubR);
  C.Brush.Color := clBlack;
  C.Ellipse(L.CX - 4, L.CY - 4, L.CX + 4, L.CY + 4);
  C.Pen.Width := 1;
end;

{ ------------------------------------------------------------------ }
{  Dynamische Ebene                                                    }
{ ------------------------------------------------------------------ }

procedure DrawDynamicLayer(ABmp: TBitmap; const L: TGaugeLayout;
  const S: TDisplayState);
var
  C: TCanvas;
begin
  C := ABmp.Canvas;

  { Blinker: Umriss steht schon im Hintergrund, aktiv wird er ausgefuellt }
  if S.BlinkLeft then
    DrawArrow(C, ArrowRect(True), True, True);
  if S.BlinkRight then
    DrawArrow(C, ArrowRect(False), False, True);

  { Warntext ausblenden }
  if not S.ShowCheck then
  begin
    C.Brush.Color := clWhite;
    C.Brush.Style := bsSolid;
    C.FillRect(CheckRect);
  end;

  { Symbole: aktiv = Rechteck umkehren }
  if S.IconBatt then InvertRect(ABmp, IconRect(0));
  if S.IconLight then InvertRect(ABmp, IconRect(1));
  if S.IconWarn then InvertRect(ABmp, IconRect(2));
  if S.IconTemp then InvertRect(ABmp, IconRect(3));

  { Uhr }
  SetPixelFont(C, 16, True);
  TextCentered(C, CLOCK_CX, CLOCK_TOP, Format('%.2d:%.2d:%.2d',
    [S.Hour, S.Minute, S.Second]));

  { Kilometerstand }
  SetPixelFont(C, 12, True);
  TextCentered(C, ODO_CX, ODO_TOP, Format('%.5d', [S.Odo]));

  { Zeiger }
  DrawNeedle(C, L, S.Speed);

  { Digitale Geschwindigkeit }
  SetPixelFont(C, 26, True);
  TextRight(C, SPEED_RIGHT, SPEED_TOP, IntToStr(Round(S.Speed)));
end;

end.
