#include "rlcd_hal.h"
#include "gauge_background.h"
#include <SPI.h>

static SPIClass lcdSpi(HSPI);

void rlcdCmd(uint8_t c) {
  digitalWrite(PIN_LCD_DC, LOW);
  digitalWrite(PIN_LCD_CS, LOW);
  lcdSpi.transfer(c);
  digitalWrite(PIN_LCD_CS, HIGH);
}

void rlcdData(uint8_t d) {
  digitalWrite(PIN_LCD_DC, HIGH);
  digitalWrite(PIN_LCD_CS, LOW);
  lcdSpi.transfer(d);
  digitalWrite(PIN_LCD_CS, HIGH);
}

void rlcdDataBuf(const uint8_t *p, size_t n) {
  digitalWrite(PIN_LCD_DC, HIGH);
  digitalWrite(PIN_LCD_CS, LOW);
  lcdSpi.writeBytes(p, n);
  digitalWrite(PIN_LCD_CS, HIGH);
}

void rlcdInit() {
  pinMode(PIN_LCD_DC, OUTPUT);
  pinMode(PIN_LCD_CS, OUTPUT);
  pinMode(PIN_LCD_RST, OUTPUT);
  digitalWrite(PIN_LCD_CS, HIGH);

  lcdSpi.begin(PIN_LCD_CLK, -1, PIN_LCD_MOSI, -1);
  lcdSpi.beginTransaction(SPISettings(LCD_SPI_HZ, MSBFIRST, SPI_MODE0));

  // Hardware-Reset
  digitalWrite(PIN_LCD_RST, HIGH); delay(20);
  digitalWrite(PIN_LCD_RST, LOW);  delay(20);
  digitalWrite(PIN_LCD_RST, HIGH); delay(120);

  // ============================================================
  // TODO 1 - Initialisierungssequenz des ST7305
  //
  // Im Waveshare-Beispielpaket findest du eine Datei, die eine
  // lange Folge von rlcdCmd()/rlcdData()-Paaren enthaelt; meist
  // heisst die Funktion LCD_Init() oder ST7305_Init(). Uebertrage
  // diese Folge hierher, oder binde die Datei direkt ein und rufe
  // deren Init-Funktion an dieser Stelle auf.
  //
  // Achte darauf, dass die Sequenz Querformat 400 x 300 einstellt
  // (MADCTL / Memory Data Access Control). Steht das Bild um 90
  // Grad gedreht, ist genau dieses Register die Stellschraube.
  // ============================================================
}

void rlcdFlush(const uint8_t *framebuffer) {
  // ============================================================
  // TODO 2 - Bild uebertragen
  //
  // Zwei Punkte sind hier zu klaeren, beide beantwortet der
  // Waveshare-Beispielcode:
  //
  // a) Fensteradressierung: vor der Datenuebertragung setzt man
  //    ueblich 0x2A (Spaltenbereich) und 0x2B (Zeilenbereich),
  //    danach 0x2C (Speicherschreiben). Fuer das Vollbild also
  //    0..399 und 0..299.
  //
  // b) Pixelanordnung: der ST7305 legt die Pixel NICHT zwingend
  //    zeilenweise linear ab wie unser Framebuffer. Wenn das Bild
  //    zerhackt oder gestreift erscheint, gehoert die Umsortierung
  //    genau hierher. Der Framebuffer bleibt dabei unangetastet -
  //    er ist unser sauberes Format, die Umsortierung passiert nur
  //    beim Senden.
  //
  // Solange die Anordnung linear passt, reicht:
  //
  //   rlcdCmd(0x2C);
  //   rlcdDataBuf(framebuffer, BG_H * BG_STRIDE);
  //
  // ============================================================
  (void)framebuffer;
}
