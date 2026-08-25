#pragma once
#include <Arduino.h>
#include "gauge_background.h"

// ---------------------------------------------------------------
//  Framebuffer 400 x 300, 1 Bit je Pixel, MSB links, Bit = schwarz
//  Exakt das Format, das der Delphi-Simulator exportiert.
// ---------------------------------------------------------------

#define FB_BYTES (BG_H * BG_STRIDE)

extern uint8_t fb[FB_BYTES];

struct MonoFont {
  const uint8_t *data;   // Zeiger auf das erste Byte des ersten Zeichens
  uint8_t  w, h, stride;
  uint8_t  count;
  uint16_t bytesPerGlyph;
};

// Hintergrundbild komplett in den Framebuffer holen
void gfxRestore();

void gfxSetPixel(int x, int y, bool black);
void gfxFillRect(int x, int y, int w, int h, bool black);
void gfxInvertRect(int x, int y, int w, int h);
void gfxFillDisc(int cx, int cy, int r, bool black);

// Konvexes Polygon fuellen. Punkte im RAM, n <= 8.
void gfxFillPoly(const int16_t pts[][2], int n, bool black);

// Polygon direkt aus dem Flash (arrowLeft / arrowRight)
void gfxFillPolyP(const int16_t pts[][2], int n, bool black);

// Ziffernketten. Erlaubte Zeichen: '0'..'9' und ':' (nur fontClock).
void gfxText(const MonoFont &f, const char *s, int x, int y);
int  gfxTextWidth(const MonoFont &f, const char *s);
void gfxTextCentered(const MonoFont &f, const char *s, int cx, int y);
void gfxTextRight(const MonoFont &f, const char *s, int right, int y);
