unit uEbikeExport;

{
  Export der im Simulator entworfenen Grafik als C-Quelltext fuer den
  Arduino-Sketch des ESP32-S3-RLCD-4.2.

  Bitformat (identisch zum ST7305-Arbeitspuffer, wie ihn Adafruit_GFX
  bzw. GFXcanvas1 verwendet):
    - zeilenweise, 400 Pixel = 50 Bytes je Zeile
    - MSB zuerst, Bit 7 = linkestes Pixel des Bytes
    - Bit gesetzt = schwarzes Pixel
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.Math,
  Vcl.Graphics, uEbikeRender;

type
  TMonoBytes = array of Byte;

function PackBitmap1bpp(ABmp: TBitmap; AThreshold: Integer = 128): TMonoBytes;
function ByteArrayToC(const AData: TMonoBytes; const AName: string;
  APerLine: Integer = 16): string;

function BuildStaticLayerC(const AData: TMonoBytes): string;
function BuildNeedleTableC(const L: TGaugeLayout; AStepPerKmh: Integer): string;
function BuildLayoutHeaderC(const L: TGaugeLayout): string;

{ Rendert die Ziffern 0..9 in fester Zellgroesse und exportiert sie als
  Bitmap-Font - damit sehen Digitalanzeige und Uhr auf dem ESP32 exakt so
  aus wie im Simulator. }
function BuildDigitFontC(AFontSize: Integer; ABold: Boolean;
  const AName: string; AExtraChars: string = ''): string;

implementation

function PackBitmap1bpp(ABmp: TBitmap; AThreshold: Integer): TMonoBytes;
var
  X, Y, RowBytes, Idx: Integer;
  Row: PByteArray;
  Lum: Integer;
begin
  ABmp.PixelFormat := pf24bit;
  RowBytes := (ABmp.Width + 7) div 8;
  SetLength(Result, RowBytes * ABmp.Height);
  FillChar(Result[0], Length(Result), 0);

  for Y := 0 to ABmp.Height - 1 do
  begin
    Row := ABmp.ScanLine[Y];
    for X := 0 to ABmp.Width - 1 do
    begin
      { pf24bit liegt als BGR vor }
      Lum := (Row^[X * 3] + Row^[X * 3 + 1] + Row^[X * 3 + 2]) div 3;
      if Lum < AThreshold then
      begin
        Idx := Y * RowBytes + (X shr 3);
        Result[Idx] := Result[Idx] or (128 shr (X and 7));
      end;
    end;
  end;
end;

function ByteArrayToC(const AData: TMonoBytes; const AName: string;
  APerLine: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('const uint8_t %s[%d] PROGMEM = {',
      [AName, Length(AData)]);
    SB.AppendLine;
    for I := 0 to High(AData) do
    begin
      if I mod APerLine = 0 then
        SB.Append('  ');
      SB.AppendFormat('0x%.2x', [AData[I]]);
      if I < High(AData) then
        SB.Append(',');
      if (I mod APerLine = APerLine - 1) or (I = High(AData)) then
        SB.AppendLine
      else
        SB.Append(' ');
    end;
    SB.AppendLine('};');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BuildStaticLayerC(const AData: TMonoBytes): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendLine('// Statische Displayebene 400 x 300, 1 bpp, MSB first');
    SB.AppendLine('// 50 Bytes je Zeile, Bit gesetzt = schwarz');
    SB.AppendLine('// erzeugt vom Delphi-Layoutsimulator');
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendLine('#define BG_W      400');
    SB.AppendLine('#define BG_H      300');
    SB.AppendLine('#define BG_STRIDE  50');
    SB.AppendLine;
    SB.Append(ByteArrayToC(AData, 'gaugeBackground'));
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BuildNeedleTableC(const L: TGaugeLayout; AStepPerKmh: Integer): string;
const
  BW = 5;
  TailR = 14;
var
  SB: TStringBuilder;
  I, N: Integer;
  Spd, A, AP: Double;
  TipX, TipY, B1X, B1Y, B2X, B2Y, TX, TY: Integer;
begin
  if AStepPerKmh < 1 then AStepPerKmh := 1;
  N := L.MaxSpeed * AStepPerKmh + 1;

  SB := TStringBuilder.Create;
  try
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendLine('// Zeigergeometrie, vorberechnet - keine Trigonometrie');
    SB.AppendLine('// zur Laufzeit noetig.');
    SB.AppendFormat('// Index = km/h * %d, 0 .. %d km/h',
      [AStepPerKmh, L.MaxSpeed]);
    SB.AppendLine;
    SB.AppendLine('// Je Eintrag: tipX, tipY, b1X, b1Y, tailX, tailY, b2X, b2Y');
    SB.AppendLine('// -> Polygon(tip, b1, tail, b2) ergibt den Zeiger.');
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendFormat('#define NEEDLE_STEPS_PER_KMH %d', [AStepPerKmh]);
    SB.AppendLine;
    SB.AppendFormat('#define NEEDLE_ENTRIES       %d', [N]);
    SB.AppendLine;
    SB.AppendLine;
    SB.AppendFormat('const int16_t needleTable[%d][8] PROGMEM = {', [N]);
    SB.AppendLine;

    for I := 0 to N - 1 do
    begin
      Spd := I / AStepPerKmh;
      A := SpeedToAngle(L, Spd);
      AP := A + 90;

      PolarPoint(L, A, L.NeedleLen, TipX, TipY);
      B1X := L.CX + Round(BW * Cos(DegToRad(AP)));
      B1Y := L.CY - Round(BW * Sin(DegToRad(AP)));
      B2X := L.CX - Round(BW * Cos(DegToRad(AP)));
      B2Y := L.CY + Round(BW * Sin(DegToRad(AP)));
      TX  := L.CX - Round(TailR * Cos(DegToRad(A)));
      TY  := L.CY + Round(TailR * Sin(DegToRad(A)));

      SB.AppendFormat('  {%4d,%4d, %4d,%4d, %4d,%4d, %4d,%4d}',
        [TipX, TipY, B1X, B1Y, TX, TY, B2X, B2Y]);
      if I < N - 1 then
        SB.Append(',');
      SB.AppendFormat('  // %5.1f km/h', [Spd]);
      SB.AppendLine;
    end;
    SB.AppendLine('};');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BuildLayoutHeaderC(const L: TGaugeLayout): string;
var
  SB: TStringBuilder;
  R: TRect;
  I: Integer;
  P: TArrowPoly;

  procedure EmitArrow(ALeft: Boolean; const AName: string);
  var
    K: Integer;
  begin
    ArrowPolygon(ArrowRect(ALeft), ALeft, P);
    SB.AppendFormat('const int16_t %s[7][2] PROGMEM = {', [AName]);
    SB.AppendLine;
    SB.Append('  ');
    for K := 0 to 6 do
    begin
      SB.AppendFormat('{%3d,%3d}', [P[K].X, P[K].Y]);
      if K < 6 then SB.Append(', ');
    end;
    SB.AppendLine;
    SB.AppendLine('};');
  end;

begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendLine('// Layoutkonstanten aus dem Delphi-Simulator');
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendFormat('#define GAUGE_CX        %d', [L.CX]); SB.AppendLine;
    SB.AppendFormat('#define GAUGE_CY        %d', [L.CY]); SB.AppendLine;
    SB.AppendFormat('#define GAUGE_MAXSPEED  %d', [L.MaxSpeed]); SB.AppendLine;
    SB.AppendFormat('#define GAUGE_HUB_R     %d', [L.HubR]); SB.AppendLine;
    SB.AppendLine;

    R := NeedleBounds(L);
    SB.AppendLine('// Dirty-Rect des Zeigers');
    SB.AppendFormat('#define NEEDLE_RECT_X   %d', [R.Left]); SB.AppendLine;
    SB.AppendFormat('#define NEEDLE_RECT_Y   %d', [R.Top]); SB.AppendLine;
    SB.AppendFormat('#define NEEDLE_RECT_W   %d', [R.Right - R.Left]); SB.AppendLine;
    SB.AppendFormat('#define NEEDLE_RECT_H   %d', [R.Bottom - R.Top]); SB.AppendLine;
    SB.AppendLine;

    SB.AppendLine('// Ankerpunkte der beweglichen Texte');
    SB.AppendFormat('#define CLOCK_CX        %d', [CLOCK_CX]); SB.AppendLine;
    SB.AppendFormat('#define CLOCK_TOP       %d', [CLOCK_TOP]); SB.AppendLine;
    SB.AppendFormat('#define ODO_CX          %d', [ODO_CX]); SB.AppendLine;
    SB.AppendFormat('#define ODO_TOP         %d', [ODO_TOP]); SB.AppendLine;
    SB.AppendFormat('#define SPEED_RIGHT     %d', [SPEED_RIGHT]); SB.AppendLine;
    SB.AppendFormat('#define SPEED_TOP       %d', [SPEED_TOP]); SB.AppendLine;
    SB.AppendLine;

    SB.AppendLine('// Symbolkaesten: aktiv = Rechteck umkehren');
    SB.AppendLine('// Reihenfolge 0=Akku 1=Licht 2=Warnung 3=Temperatur');
    SB.AppendLine('const int16_t iconRect[4][4] PROGMEM = {');
    for I := 0 to 3 do
    begin
      R := IconRect(I);
      SB.AppendFormat('  {%3d,%3d,%3d,%3d}', [R.Left, R.Top,
        R.Right - R.Left, R.Bottom - R.Top]);
      if I < 3 then SB.Append(',');
      SB.AppendLine;
    end;
    SB.AppendLine('};');
    SB.AppendLine;

    R := CheckRect;
    SB.AppendLine('// Warntext: inaktiv = Rechteck weiss uebermalen');
    SB.AppendFormat('#define CHECK_RECT_X    %d', [R.Left]); SB.AppendLine;
    SB.AppendFormat('#define CHECK_RECT_Y    %d', [R.Top]); SB.AppendLine;
    SB.AppendFormat('#define CHECK_RECT_W    %d', [R.Right - R.Left]); SB.AppendLine;
    SB.AppendFormat('#define CHECK_RECT_H    %d', [R.Bottom - R.Top]); SB.AppendLine;
    SB.AppendLine;

    SB.AppendLine('// Blinkerpfeile: Umriss steht im Hintergrund,');
    SB.AppendLine('// aktiv wird das Polygon gefuellt.');
    EmitArrow(True, 'arrowLeft');
    EmitArrow(False, 'arrowRight');

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BuildDigitFontC(AFontSize: Integer; ABold: Boolean;
  const AName: string; AExtraChars: string): string;
var
  Chars: string;
  Bmp, Cell: TBitmap;
  I, CellW, CellH, X, Y, RowBytes, Idx: Integer;
  Data: TMonoBytes;
  SB: TStringBuilder;
  Row: PByteArray;
  Lum: Integer;
begin
  Chars := '0123456789' + AExtraChars;

  Bmp := TBitmap.Create;
  Cell := TBitmap.Create;
  SB := TStringBuilder.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(10, 10);
    Bmp.Canvas.Font.Name := FONT_NAME;
    Bmp.Canvas.Font.Size := AFontSize;
    Bmp.Canvas.Font.Quality := fqNonAntialiased;
    if ABold then
      Bmp.Canvas.Font.Style := [fsBold]
    else
      Bmp.Canvas.Font.Style := [];

    CellW := Bmp.Canvas.TextWidth('0');
    CellH := Bmp.Canvas.TextHeight('0');
    RowBytes := (CellW + 7) div 8;

    Cell.PixelFormat := pf24bit;
    Cell.SetSize(CellW, CellH);
    Cell.Canvas.Font := Bmp.Canvas.Font;
    Cell.Canvas.Font.Color := clBlack;

    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendFormat('// Bitmap-Font "%s" - Zellen %d x %d Pixel',
      [AName, CellW, CellH]);
    SB.AppendLine;
    SB.AppendFormat('// Zeichen in Reihenfolge: %s', [Chars]); SB.AppendLine;
    SB.AppendFormat('// %d Bytes je Zeile, MSB zuerst', [RowBytes]);
    SB.AppendLine;
    SB.AppendLine('// ----------------------------------------------------');
    SB.AppendFormat('#define %s_W      %d', [UpperCase(AName), CellW]);
    SB.AppendLine;
    SB.AppendFormat('#define %s_H      %d', [UpperCase(AName), CellH]);
    SB.AppendLine;
    SB.AppendFormat('#define %s_STRIDE %d', [UpperCase(AName), RowBytes]);
    SB.AppendLine;
    SB.AppendFormat('#define %s_COUNT  %d', [UpperCase(AName), Length(Chars)]);
    SB.AppendLine;
    SB.AppendLine;
    SB.AppendFormat('const uint8_t %s[%d][%d] PROGMEM = {',
      [AName, Length(Chars), RowBytes * CellH]);
    SB.AppendLine;

    for I := 1 to Length(Chars) do
    begin
      Cell.Canvas.Brush.Color := clWhite;
      Cell.Canvas.Brush.Style := bsSolid;
      Cell.Canvas.FillRect(Rect(0, 0, CellW, CellH));
      Cell.Canvas.Brush.Style := bsClear;
      Cell.Canvas.TextOut(
        (CellW - Cell.Canvas.TextWidth(Chars[I])) div 2, 0, Chars[I]);

      SetLength(Data, RowBytes * CellH);
      FillChar(Data[0], Length(Data), 0);
      for Y := 0 to CellH - 1 do
      begin
        Row := Cell.ScanLine[Y];
        for X := 0 to CellW - 1 do
        begin
          Lum := (Row^[X * 3] + Row^[X * 3 + 1] + Row^[X * 3 + 2]) div 3;
          if Lum < 128 then
          begin
            Idx := Y * RowBytes + (X shr 3);
            Data[Idx] := Data[Idx] or (128 shr (X and 7));
          end;
        end;
      end;

      SB.Append('  {');
      for X := 0 to High(Data) do
      begin
        SB.AppendFormat('0x%.2x', [Data[X]]);
        if X < High(Data) then SB.Append(',');
      end;
      SB.Append('}');
      if I < Length(Chars) then SB.Append(',');
      SB.AppendFormat('  // ''%s''', [Chars[I]]);
      SB.AppendLine;
    end;
    SB.AppendLine('};');
    Result := SB.ToString;
  finally
    SB.Free;
    Cell.Free;
    Bmp.Free;
  end;
end;

end.
