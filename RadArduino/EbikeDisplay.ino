// ===============================================================
//  Ebike-Display
//  Waveshare ESP32-S3-RLCD-4.2 (ST7305, 400 x 300, 1 bpp)
//
//  Layout, Skala, Symbole, Zeigertabelle und Ziffernfonts stammen
//  aus dem Delphi-Layoutsimulator. Dieser Sketch zeichnet nur noch
//  die beweglichen Teile - er kennt keine einzige eigene Koordinate.
//
//  Arduino IDE: Board "ESP32S3 Dev Module", arduino-esp32 >= 3.3.0,
//               PSRAM: OPI PSRAM
// ===============================================================

#include <Wire.h>
#include <Preferences.h>

#include "gauge_background.h"
#include "gauge_needle.h"
#include "gauge_fonts.h"
#include "gfx1bpp.h"
#include "rlcd_hal.h"

// --------------------------- Anpassen ---------------------------

#define PIN_HALL          17     // Reed- oder Hallsensor gegen GND
#define WHEEL_MM        2160     // gemessener Radumfang in mm
#define MAGNETS            1     // Magnete am Rad

#define PIN_KEY           18     // Taster auf dem Board (Licht ein/aus)
#define PIN_BATT_ADC       4     // Akkuspannung, 3-fach Teiler

// Blinker-Eingaenge. -1 = nicht benutzt.
#define PIN_BLINK_L       -1
#define PIN_BLINK_R       -1

#define REFRESH_MS       200     // Bildwiederholung
#define STOP_TIMEOUT_MS 4000     // danach gilt: Rad steht

// ----------------------------------------------------------------

#define MM_PER_PULSE  (WHEEL_MM / MAGNETS)

// Kuerzester plausibler Impulsabstand. Bremst Reedprellen aus und
// begrenzt gleichzeitig auf eine unrealistisch hohe Geschwindigkeit.
// 2160 mm / 50 ms entspraeche 155 km/h - alles darunter ist Prellen.
#define MIN_PULSE_US   50000UL

// --------------------------- Fonts ------------------------------

static const MonoFont FBig   = { &fontBig[0][0],   FONTBIG_W,   FONTBIG_H,
                                 FONTBIG_STRIDE,   FONTBIG_COUNT,   sizeof(fontBig[0]) };
static const MonoFont FClock = { &fontClock[0][0], FONTCLOCK_W, FONTCLOCK_H,
                                 FONTCLOCK_STRIDE, FONTCLOCK_COUNT, sizeof(fontClock[0]) };
static const MonoFont FSmall = { &fontSmall[0][0], FONTSMALL_W, FONTSMALL_H,
                                 FONTSMALL_STRIDE, FONTSMALL_COUNT, sizeof(fontSmall[0]) };

// --------------------------- Zustand ----------------------------

volatile uint32_t g_lastPulseUs = 0;
volatile uint32_t g_periodUs    = 0;
volatile uint32_t g_pulses      = 0;

Preferences prefs;
uint32_t g_odoMetersBase = 0;    // aus dem NVS geladen
uint32_t g_odoSavedAt    = 0;    // Stand beim letzten Speichern

float g_speed      = 0;          // geglaettet, fuer die Anzeige
int   g_hour = 0, g_min = 0, g_sec = 0;
bool  g_rtcOk      = false;
int   g_battPct    = 100;
float g_tempC      = 20.0f;
bool  g_lightOn    = false;

// ------------------------- Hall-Sensor --------------------------

void IRAM_ATTR hallISR() {
  uint32_t now = micros();
  uint32_t dt  = now - g_lastPulseUs;
  if (dt < MIN_PULSE_US) return;          // Prellen verwerfen
  g_lastPulseUs = now;
  g_periodUs    = dt;
  g_pulses++;
}

// Momentangeschwindigkeit in km/h.
//
// Mit einem Magneten kommt bei 10 km/h nur alle 0,78 s ein Impuls.
// Zwischen zwei Impulsen wuerde die Anzeige also stehenbleiben und
// beim Anhalten auf dem letzten Wert einfrieren. Deshalb: ist seit
// dem letzten Impuls schon mehr Zeit vergangen als die letzte volle
// Umdrehung gedauert hat, kann das Rad nicht schneller sein - der
// Wert wird dann anhand der verstrichenen Zeit nach unten gerechnet
// und faellt so von allein gegen null.
float measureSpeed() {
  noInterrupts();
  uint32_t per  = g_periodUs;
  uint32_t last = g_lastPulseUs;
  interrupts();

  if (per == 0) return 0;

  uint32_t since = micros() - last;
  if (since > (uint32_t)STOP_TIMEOUT_MS * 1000UL) return 0;

  uint32_t basis = (since > per) ? since : per;
  return (float)MM_PER_PULSE * 3600.0f / (float)basis;
}

// ------------------------- Kilometerstand ------------------------

uint32_t odoMeters() {
  noInterrupts();
  uint32_t p = g_pulses;
  interrupts();
  return g_odoMetersBase + (uint32_t)((uint64_t)p * MM_PER_PULSE / 1000ULL);
}

void odoMaybeSave() {
  uint32_t m = odoMeters();
  if (m - g_odoSavedAt >= 100) {           // alle 100 m
    prefs.putUInt("odo_m", m);
    g_odoSavedAt = m;
  }
}

// ------------------------------ RTC ------------------------------
// PCF85063, I2C 0x51. Register 0x04 Sekunden, 0x05 Minuten, 0x06 Stunden.
// Bit 7 der Sekunden meldet einen Oszillatorausfall.

#define RTC_ADDR 0x51

static int bcd2dec(uint8_t b) { return (b >> 4) * 10 + (b & 0x0F); }

bool rtcRead(int &h, int &m, int &s) {
  Wire.beginTransmission(RTC_ADDR);
  Wire.write(0x04);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(RTC_ADDR, 3) != 3) return false;

  uint8_t rs = Wire.read();
  uint8_t rm = Wire.read();
  uint8_t rh = Wire.read();

  if (rs & 0x80) return false;             // Uhr lief nicht durch
  s = bcd2dec(rs & 0x7F);
  m = bcd2dec(rm & 0x7F);
  h = bcd2dec(rh & 0x3F);
  return (h < 24 && m < 60 && s < 60);
}

// ---------------------------- SHTC3 ------------------------------
// I2C 0x70. Aufwecken, Messung ohne Clock Stretching, wieder schlafen.

#define SHTC3_ADDR 0x70

static void shtc3Cmd(uint16_t c) {
  Wire.beginTransmission(SHTC3_ADDR);
  Wire.write(c >> 8);
  Wire.write(c & 0xFF);
  Wire.endTransmission();
}

bool shtc3Read(float &tempC) {
  shtc3Cmd(0x3517);                        // wakeup
  delayMicroseconds(300);
  shtc3Cmd(0x7866);                        // T zuerst, ohne Stretching
  delay(15);
  if (Wire.requestFrom(SHTC3_ADDR, 6) != 6) { shtc3Cmd(0xB098); return false; }

  uint16_t raw = ((uint16_t)Wire.read() << 8);
  raw |= Wire.read();
  Wire.read();                             // CRC verworfen
  Wire.read(); Wire.read(); Wire.read();   // Feuchte interessiert hier nicht
  shtc3Cmd(0xB098);                        // sleep

  tempC = -45.0f + 175.0f * (float)raw / 65535.0f;
  return true;
}

// ---------------------------- Akku -------------------------------

int battPercent() {
  uint32_t mv = analogReadMilliVolts(PIN_BATT_ADC) * 3;   // 3-fach Teiler
  int pct = (int)(((long)mv - 2500) * 100 / (4200 - 2500));
  return constrain(pct, 0, 100);
}

// --------------------------- Bildaufbau ---------------------------

void drawNeedle(float kmh) {
  int idx = (int)lroundf(kmh * NEEDLE_STEPS_PER_KMH);
  idx = constrain(idx, 0, NEEDLE_ENTRIES - 1);

  int16_t q[4][2];
  for (int k = 0; k < 4; k++) {
    q[k][0] = (int16_t)pgm_read_word(&needleTable[idx][k * 2]);
    q[k][1] = (int16_t)pgm_read_word(&needleTable[idx][k * 2 + 1]);
  }
  gfxFillPoly(q, 4, true);

  // Nabe: schwarzer Ring, weisser Kern, schwarzer Punkt
  gfxFillDisc(GAUGE_CX, GAUGE_CY, GAUGE_HUB_R + 2, true);
  gfxFillDisc(GAUGE_CX, GAUGE_CY, GAUGE_HUB_R - 2, false);
  gfxFillDisc(GAUGE_CX, GAUGE_CY, 4, true);
}

void render(bool blinkL, bool blinkR, bool icons[4], bool showCheck) {
  gfxRestore();

  if (blinkL) gfxFillPolyP(arrowLeft,  7, true);
  if (blinkR) gfxFillPolyP(arrowRight, 7, true);

  if (!showCheck)
    gfxFillRect(CHECK_RECT_X, CHECK_RECT_Y, CHECK_RECT_W, CHECK_RECT_H, false);

  for (int i = 0; i < 4; i++)
    if (icons[i])
      gfxInvertRect((int)pgm_read_word(&iconRect[i][0]),
                    (int)pgm_read_word(&iconRect[i][1]),
                    (int)pgm_read_word(&iconRect[i][2]),
                    (int)pgm_read_word(&iconRect[i][3]));

  char buf[16];

  if (g_rtcOk) snprintf(buf, sizeof buf, "%02d:%02d:%02d", g_hour, g_min, g_sec);
  else         snprintf(buf, sizeof buf, "--:--:--");
  gfxTextCentered(FClock, buf, CLOCK_CX, CLOCK_TOP);

  snprintf(buf, sizeof buf, "%05lu", (unsigned long)(odoMeters() / 1000));
  gfxTextCentered(FSmall, buf, ODO_CX, ODO_TOP);

  drawNeedle(g_speed);

  snprintf(buf, sizeof buf, "%d", (int)lroundf(g_speed));
  gfxTextRight(FBig, buf, SPEED_RIGHT, SPEED_TOP);
}

// ------------------------------ Setup -----------------------------

void setup() {
  Serial.begin(115200);

  pinMode(PIN_HALL, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_HALL), hallISR, FALLING);

  pinMode(PIN_KEY, INPUT_PULLUP);
  if (PIN_BLINK_L >= 0) pinMode(PIN_BLINK_L, INPUT_PULLUP);
  if (PIN_BLINK_R >= 0) pinMode(PIN_BLINK_R, INPUT_PULLUP);

  analogSetPinAttenuation(PIN_BATT_ADC, ADC_11db);

  Wire.begin(13, 14);

  prefs.begin("ebike", false);
  g_odoMetersBase = prefs.getUInt("odo_m", 0);
  g_odoSavedAt    = g_odoMetersBase;

  rlcdInit();

  bool icons[4] = { false, false, false, false };
  render(false, false, icons, false);
  rlcdFlush(fb);
}

// ------------------------------ Loop ------------------------------

void loop() {
  static uint32_t tFrame = 0, tSlow = 0;
  static bool     keyPrev = HIGH;

  // Taster: Licht umschalten
  bool key = digitalRead(PIN_KEY);
  if (keyPrev == HIGH && key == LOW) g_lightOn = !g_lightOn;
  keyPrev = key;

  uint32_t now = millis();

  // Langsame Messwerte
  if (now - tSlow >= 2000) {
    tSlow = now;
    g_rtcOk  = rtcRead(g_hour, g_min, g_sec);
    g_battPct = battPercent();
    shtc3Read(g_tempC);
    odoMaybeSave();
  }

  if (now - tFrame < REFRESH_MS) return;
  tFrame = now;

  // Geschwindigkeit glaetten. Bei einem Magneten liegen zwischen
  // zwei Messwerten mehrere hundert Millisekunden - ohne Glaettung
  // wuerde der Zeiger springen statt zu wandern.
  float target = measureSpeed();
  g_speed += (target - g_speed) * 0.25f;
  if (g_speed < 0.2f) g_speed = 0;

  bool blinkL = (PIN_BLINK_L >= 0) && (digitalRead(PIN_BLINK_L) == LOW);
  bool blinkR = (PIN_BLINK_R >= 0) && (digitalRead(PIN_BLINK_R) == LOW);

  bool icons[4];
  icons[0] = (g_battPct <= 15);                        // Akku schwach
  icons[1] = g_lightOn;                                // Licht
  icons[2] = !g_rtcOk;                                 // Stoerung
  icons[3] = (g_tempC <= 3.0f) || (g_tempC >= 45.0f);  // Glaette / Hitze

  bool showCheck = icons[0] || icons[2];

  // Nur senden, wenn sich wirklich etwas geaendert hat. Die
  // Uebertragung ist der mit Abstand teuerste Teil des Frames.
  static int lastKey = -1;
  int key2 = (int)lroundf(g_speed) * 1000
           + g_min * 10 + g_sec / 6
           + (blinkL ? 100000 : 0) + (blinkR ? 200000 : 0)
           + (icons[0] ? 400000 : 0) + (icons[1] ? 800000 : 0)
           + (icons[2] ? 1600000 : 0) + (icons[3] ? 3200000 : 0);

  if (key2 != lastKey) {
    lastKey = key2;
    render(blinkL, blinkR, icons, showCheck);
    rlcdFlush(fb);
  }
}
