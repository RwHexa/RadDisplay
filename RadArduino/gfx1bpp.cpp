#include "gfx1bpp.h"

uint8_t fb[FB_BYTES];

void gfxRestore() {
  memcpy_P(fb, gaugeBackground, FB_BYTES);
}

void gfxSetPixel(int x, int y, bool black) {
  if ((unsigned)x >= BG_W || (unsigned)y >= BG_H) return;
  uint8_t *p = &fb[y * BG_STRIDE + (x >> 3)];
  uint8_t  m = 0x80 >> (x & 7);
  if (black) *p |= m; else *p &= ~m;
}

void gfxFillRect(int x, int y, int w, int h, bool black) {
  for (int yy = y; yy < y + h; yy++)
    for (int xx = x; xx < x + w; xx++)
      gfxSetPixel(xx, yy, black);
}

void gfxInvertRect(int x, int y, int w, int h) {
  for (int yy = y; yy < y + h; yy++) {
    if ((unsigned)yy >= BG_H) continue;
    for (int xx = x; xx < x + w; xx++) {
      if ((unsigned)xx >= BG_W) continue;
      fb[yy * BG_STRIDE + (xx >> 3)] ^= (0x80 >> (xx & 7));
    }
  }
}

void gfxFillDisc(int cx, int cy, int r, bool black) {
  int r2 = r * r;
  for (int dy = -r; dy <= r; dy++) {
    int dx = (int)(sqrtf((float)(r2 - dy * dy)) + 0.5f);
    for (int x = cx - dx; x <= cx + dx; x++)
      gfxSetPixel(x, cy + dy, black);
  }
}

// Scanline-Fuellung. Fuer jede Bildzeile werden die Schnittpunkte mit
// allen Kanten gesammelt, sortiert und paarweise ausgefuellt.
void gfxFillPoly(const int16_t p[][2], int n, bool black) {
  if (n < 3 || n > 8) return;

  int minY = p[0][1], maxY = p[0][1];
  for (int i = 1; i < n; i++) {
    if (p[i][1] < minY) minY = p[i][1];
    if (p[i][1] > maxY) maxY = p[i][1];
  }
  if (minY < 0) minY = 0;
  if (maxY > BG_H - 1) maxY = BG_H - 1;

  for (int y = minY; y <= maxY; y++) {
    int xs[8], cnt = 0;

    for (int i = 0; i < n; i++) {
      int j  = (i + 1) % n;
      int y1 = p[i][1], y2 = p[j][1];
      if (y1 == y2) continue;                 // waagerechte Kante ignorieren
      int lo = (y1 < y2) ? y1 : y2;
      int hi = (y1 < y2) ? y2 : y1;
      if (y < lo || y >= hi) continue;        // halboffen: keine Doppelzaehlung
      long num = (long)(y - y1) * (p[j][0] - p[i][0]);
      xs[cnt++] = p[i][0] + (int)(num / (y2 - y1));
    }

    for (int a = 1; a < cnt; a++) {           // Einfuegesortierung
      int v = xs[a], b = a - 1;
      while (b >= 0 && xs[b] > v) { xs[b + 1] = xs[b]; b--; }
      xs[b + 1] = v;
    }

    for (int k = 0; k + 1 < cnt; k += 2)
      for (int x = xs[k]; x <= xs[k + 1]; x++)
        gfxSetPixel(x, y, black);
  }
}

void gfxFillPolyP(const int16_t p[][2], int n, bool black) {
  int16_t tmp[8][2];
  if (n > 8) n = 8;
  for (int i = 0; i < n; i++) {
    tmp[i][0] = (int16_t)pgm_read_word(&p[i][0]);
    tmp[i][1] = (int16_t)pgm_read_word(&p[i][1]);
  }
  gfxFillPoly(tmp, n, black);
}

static int glyphIndex(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c == ':') return 10;                    // nur im Uhrenfont vorhanden
  return -1;
}

void gfxText(const MonoFont &f, const char *s, int x, int y) {
  for (const char *c = s; *c; c++) {
    int gi = glyphIndex(*c);
    if (gi >= 0 && gi < f.count) {
      const uint8_t *g = f.data + (uint32_t)gi * f.bytesPerGlyph;
      for (int row = 0; row < f.h; row++) {
        for (int col = 0; col < f.w; col++) {
          uint8_t b = pgm_read_byte(g + row * f.stride + (col >> 3));
          if (b & (0x80 >> (col & 7)))
            gfxSetPixel(x + col, y + row, true);
        }
      }
    }
    x += f.w;
  }
}

int gfxTextWidth(const MonoFont &f, const char *s) {
  return (int)strlen(s) * f.w;
}

void gfxTextCentered(const MonoFont &f, const char *s, int cx, int y) {
  gfxText(f, s, cx - gfxTextWidth(f, s) / 2, y);
}

void gfxTextRight(const MonoFont &f, const char *s, int right, int y) {
  gfxText(f, s, right - gfxTextWidth(f, s), y);
}
