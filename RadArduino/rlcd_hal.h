#pragma once
#include <Arduino.h>

// ---------------------------------------------------------------
//  Anbindung des ST7305 auf dem ESP32-S3-RLCD-4.2
//
//  WICHTIG - hier musst du selbst noch Hand anlegen:
//  Die Initialisierungssequenz des ST7305 und die Anordnung der
//  Pixel im Displayspeicher stehen NICHT in diesem Sketch. Sie
//  gehoeren zum Waveshare-Beispielpaket, das du dir aus deren
//  Wiki laedst (Abschnitt "Working with Arduino"). Ich habe
//  bewusst keine Registerfolge erfunden - eine falsche Sequenz
//  kostet dich mehr Zeit als das Nachschlagen.
//
//  Es gibt genau zwei Stellen zum Ausfuellen, beide in
//  rlcd_hal.cpp und mit TODO markiert.
// ---------------------------------------------------------------

#define PIN_LCD_CLK    11
#define PIN_LCD_MOSI   12
#define PIN_LCD_DC      5
#define PIN_LCD_CS     40
#define PIN_LCD_RST    41

// SPI-Takt. 1 MHz ist die konservative Empfehlung, hoeher geht
// meist problemlos. Bei Bildstoerungen wieder senken.
#define LCD_SPI_HZ  8000000

void rlcdInit();
void rlcdFlush(const uint8_t *framebuffer);

// niederschwellige Helfer, falls du die Waveshare-Sequenz
// von Hand uebertragen willst
void rlcdCmd(uint8_t c);
void rlcdData(uint8_t d);
void rlcdDataBuf(const uint8_t *p, size_t n);
