<# : XIAO-CAM Studio - one file: installs tools, builds, flashes, and opens the camera studio.
@echo off
setlocal
set "XCAM_SELF=%~f0"
if not defined XCAM_MODE set "XCAM_MODE=menu"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:XCAM_SELF))"
echo.
pause
exit /b
#>

# ============================================================================
#  XIAO-CAM Studio  -  Seeed XIAO ESP32S3 Sense camera, v2
#   1. Downloads arduino-cli + the ESP32 core (first run only, ~1 GB, needs internet)
#   2. Builds the camera firmware below and flashes it over USB-C
#   3. Opens the Studio in your browser (video comes over the USB cable):
#      resolution, quality, fps, exposure, gain, white balance, effects,
#      WiFi on/off/hotspot/join, recording to AVI (+ sound), timelapse,
#      snapshots, focus helper, histogram, zoom/rotate, profiles
#   Default hotspot from the board:  XIAO-CAM / xiaocam123  ->  http://192.168.4.1
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Ssid = 'XIAO-CAM'            # first-time hotspot name (change later in the Studio, WiFi tab)
$Pass = 'xiaocam123'          # first-time hotspot password: at least 8 characters
$StudioPort = 8787

$Root      = Split-Path -Parent $env:XCAM_SELF
$Data      = Join-Path $env:LOCALAPPDATA 'XiaoCam'
$CliDir    = Join-Path $Data 'arduino-cli'
$Cli       = Join-Path $CliDir 'arduino-cli.exe'
$SketchDir = Join-Path $Data 'xiaocam2'
$BuildDir  = Join-Path $Data 'build2'
$Fqbn      = 'esp32:esp32:XIAO_ESP32S3:PSRAM=opi,USBMode=hwcdc,CDCOnBoot=default'

$env:ARDUINO_DIRECTORIES_DATA      = Join-Path $Data 'arduino15'
$env:ARDUINO_DIRECTORIES_DOWNLOADS = Join-Path $Data 'staging'
$env:ARDUINO_DIRECTORIES_USER      = Join-Path $Data 'user'
$env:ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS = 'https://espressif.github.io/arduino-esp32/package_esp32_index.json'

function Say($m)  { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }
function Run-Arduino { & $Cli @args; if ($LASTEXITCODE -ne 0) { throw "arduino-cli $($args -join ' ') failed (exit $LASTEXITCODE)" } }

# ----------------------------------------------------------------------------
#  Camera firmware (Arduino sketch)
# ----------------------------------------------------------------------------
$Sketch = @'
// XIAO-CAM firmware v2 - Seeed XIAO ESP32S3 Sense
// USB-C packets to PC: 4-byte magic + uint32 LE length + data
//   XCAM = JPEG frame   XAUD = PCM16 mono 16 kHz   XCFG = JSON settings+status   XMSG = text
// USB-C commands from PC (text lines):
//   get | set <key> <int> | str <key> <text> | wifi_apply | save | defaults | reboot
// WiFi page: http://<board ip>/   stream :81/stream   /capture   /status
#include "esp_camera.h"
#include <WiFi.h>
#include <Preferences.h>
#include <ESP_I2S.h>
#include "esp_http_server.h"

#define FW_VERSION "2.0"
#define LED_PIN 21
#define MIC_RATE 16000

static Preferences prefs;
static I2SClass i2s;
static SemaphoreHandle_t lock;
static uint8_t* shared = nullptr;
static size_t sharedLen = 0, sharedCap = 0;
static volatile uint32_t frameId = 0;
static bool camOk = false;
static char camErr[96] = "";
static int maxSize = FRAMESIZE_UXGA;
static const char* sensorName = "unknown";

static int fpsLimit = 0, xclkMhz = 20, ledOn = 0, micOn = 0, usbOn = 1;
static int wifiMode = 1, apChan = 6, txPower = 78;
static String apSsid = "@@SSID@@", apPass = "@@PASS@@", staSsid = "", staPass = "";
static volatile int capFrames = 0, streamClients = 0;
static float capFps = 0, usbFps = 0;
static int usbFrames = 0;
static bool dirty = false, cfgNow = true, webStarted = false;
static uint32_t dirtyAt = 0;
static volatile bool micRunning = false, micBusy = false;

// ---------- sensor settings table ----------
typedef int (*SetFn)(sensor_t*, int);
typedef int (*GetFn)(sensor_t*);
struct Ctl { const char* k; SetFn set; GetFn get; };

static void* bigAlloc(size_t n) { return psramFound() ? ps_malloc(n) : malloc(n); }

#define CTL(name, fn, field, cast) { name, \
  [](sensor_t* s, int v) -> int { return s->fn ? s->fn(s, (cast)v) : -1; }, \
  [](sensor_t* s) -> int { return (int)s->status.field; } }
static const Ctl ctls[] = {
  CTL("framesize",   set_framesize,      framesize,      framesize_t),
  CTL("quality",     set_quality,        quality,        int),
  CTL("brightness",  set_brightness,     brightness,     int),
  CTL("contrast",    set_contrast,       contrast,       int),
  CTL("saturation",  set_saturation,     saturation,     int),
  CTL("sharpness",   set_sharpness,      sharpness,      int),
  CTL("denoise",     set_denoise,        denoise,        int),
  CTL("effect",      set_special_effect, special_effect, int),
  CTL("awb",         set_whitebal,       awb,            int),
  CTL("awb_gain",    set_awb_gain,       awb_gain,       int),
  CTL("wb_mode",     set_wb_mode,        wb_mode,        int),
  CTL("aec",         set_exposure_ctrl,  aec,            int),
  CTL("aec2",        set_aec2,           aec2,           int),
  CTL("ae_level",    set_ae_level,       ae_level,       int),
  CTL("aec_value",   set_aec_value,      aec_value,      int),
  CTL("agc",         set_gain_ctrl,      agc,            int),
  CTL("agc_gain",    set_agc_gain,       agc_gain,       int),
  CTL("gainceiling", set_gainceiling,    gainceiling,    gainceiling_t),
  CTL("bpc",         set_bpc,            bpc,            int),
  CTL("wpc",         set_wpc,            wpc,            int),
  CTL("raw_gma",     set_raw_gma,        raw_gma,        int),
  CTL("lenc",        set_lenc,           lenc,           int),
  CTL("hmirror",     set_hmirror,        hmirror,        int),
  CTL("vflip",       set_vflip,          vflip,          int),
  CTL("dcw",         set_dcw,            dcw,            int),
  CTL("colorbar",    set_colorbar,       colorbar,       int),
};
static const int NCTL = sizeof(ctls) / sizeof(ctls[0]);
static const Ctl* findCtl(const char* k) { for (int i = 0; i < NCTL; i++) if (!strcmp(ctls[i].k, k)) return &ctls[i]; return nullptr; }

// ---------- settings storage (NVS) ----------
static void loadPrefs() {
  prefs.begin("xcam", true);
  fpsLimit = prefs.getInt("fps_limit", 0);
  xclkMhz  = prefs.getInt("xclk", 20);
  ledOn    = prefs.getInt("led", 0);
  micOn    = prefs.getInt("mic", 0);
  usbOn    = prefs.getInt("usb", 1);
  wifiMode = prefs.getInt("wifi", 1);
  apChan   = prefs.getInt("ap_ch", 6);
  txPower  = prefs.getInt("tx_power", 78);
  apSsid   = prefs.getString("ap_ssid", apSsid);
  apPass   = prefs.getString("ap_pass", apPass);
  staSsid  = prefs.getString("sta_ssid", "");
  staPass  = prefs.getString("sta_pass", "");
  prefs.end();
}

static void applySensorPrefs(sensor_t* s) {
  if (!prefs.begin("xcam", true)) return;
  char key[16];
  for (int i = 0; i < NCTL; i++) {
    snprintf(key, sizeof key, "s_%s", ctls[i].k);
    if (prefs.isKey(key)) {
      int v = prefs.getInt(key, 0);
      if (i == 0 && v > maxSize) v = maxSize;
      ctls[i].set(s, v);
    }
  }
  prefs.end();
}

static void saveAll() {
  prefs.begin("xcam", false);
  if (camOk) {
    sensor_t* s = esp_camera_sensor_get();
    char key[16];
    for (int i = 0; i < NCTL; i++) { snprintf(key, sizeof key, "s_%s", ctls[i].k); prefs.putInt(key, ctls[i].get(s)); }
  }
  prefs.putInt("fps_limit", fpsLimit); prefs.putInt("xclk", xclkMhz); prefs.putInt("led", ledOn);
  prefs.putInt("mic", micOn); prefs.putInt("usb", usbOn); prefs.putInt("wifi", wifiMode);
  prefs.putInt("ap_ch", apChan); prefs.putInt("tx_power", txPower);
  prefs.putString("ap_ssid", apSsid); prefs.putString("ap_pass", apPass);
  prefs.putString("sta_ssid", staSsid); prefs.putString("sta_pass", staPass);
  prefs.end();
  dirty = false;
}
static void markDirty() { dirty = true; dirtyAt = millis(); }

// ---------- camera ----------
static bool camInitSize(framesize_t fs) {
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0;  c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = 15; c.pin_d1 = 17; c.pin_d2 = 18; c.pin_d3 = 16;
  c.pin_d4 = 14; c.pin_d5 = 12; c.pin_d6 = 11; c.pin_d7 = 48;
  c.pin_xclk = 10; c.pin_pclk = 13; c.pin_vsync = 38; c.pin_href = 47;
  c.pin_sccb_sda = 40; c.pin_sccb_scl = 39;
  c.pin_pwdn = -1; c.pin_reset = -1;
  c.xclk_freq_hz = xclkMhz * 1000000;
  c.pixel_format = PIXFORMAT_JPEG;
  c.grab_mode = CAMERA_GRAB_LATEST;
  if (psramFound()) {
    c.frame_size = fs; c.jpeg_quality = 10; c.fb_count = 2; c.fb_location = CAMERA_FB_IN_PSRAM;
  } else {
    c.frame_size = FRAMESIZE_QVGA; c.jpeg_quality = 15; c.fb_count = 1; c.fb_location = CAMERA_FB_IN_DRAM;
  }
  esp_err_t e = esp_camera_init(&c);
  if (e != ESP_OK) { snprintf(camErr, sizeof camErr, "camera init failed 0x%x - check the camera board / ribbon", e); return false; }
  return true;
}

static bool camInit() {
  // init at the biggest size, so the frame buffers fit every resolution later
  if (!camInitSize(FRAMESIZE_QXGA)) { esp_camera_deinit(); if (!camInitSize(FRAMESIZE_UXGA)) return false; }
  camErr[0] = 0;
  sensor_t* s = esp_camera_sensor_get();
  camera_sensor_info_t* info = esp_camera_sensor_get_info(&s->id);
  if (info) { maxSize = info->max_size; sensorName = info->name; }
  if (!psramFound()) maxSize = FRAMESIZE_QVGA;
  if (maxSize > FRAMESIZE_QXGA) maxSize = FRAMESIZE_QXGA;
  if (s->id.PID == OV3660_PID) { s->set_vflip(s, 1); s->set_brightness(s, 1); s->set_saturation(s, -2); }
  s->set_framesize(s, psramFound() ? FRAMESIZE_SVGA : FRAMESIZE_QVGA);
  s->set_quality(s, 10);
  applySensorPrefs(s);
  return true;
}

// capture task: always keeps the newest JPEG in 'shared'
static void captureTask(void*) {
  uint32_t last = 0;
  for (;;) {
    int fl = fpsLimit;
    if (fl > 0) {
      uint32_t period = 1000 / fl, now = millis();
      if (now - last < period) vTaskDelay(pdMS_TO_TICKS(period - (now - last)));
      last = millis();
    }
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) { vTaskDelay(10); continue; }
    xSemaphoreTake(lock, portMAX_DELAY);
    if (fb->len > sharedCap) {
      free(shared); sharedCap = fb->len + 32768;
      shared = (uint8_t*)bigAlloc(sharedCap);
      if (!shared) sharedCap = 0;
    }
    if (shared) { memcpy(shared, fb->buf, fb->len); sharedLen = fb->len; frameId++; }
    xSemaphoreGive(lock);
    esp_camera_fb_return(fb);
    capFrames++;
    vTaskDelay(1);
  }
}

// copy the newest frame (if newer than 'seen') into a private buffer
static size_t copyLatest(uint8_t*& buf, size_t& cap, uint32_t& seen) {
  size_t n = 0;
  xSemaphoreTake(lock, portMAX_DELAY);
  if (frameId != seen && sharedLen) {
    if (sharedLen > cap) { free(buf); cap = sharedLen + 32768; buf = (uint8_t*)bigAlloc(cap); if (!buf) cap = 0; }
    if (buf) { memcpy(buf, shared, sharedLen); n = sharedLen; seen = frameId; }
  }
  xSemaphoreGive(lock);
  return n;
}

// ---------- microphone (PDM, CLK 42 / DATA 41) ----------
static uint8_t aring[32768];               // power of 2
static volatile uint32_t aW = 0, aR = 0;
static void micTask(void*) {
  static uint8_t b[1024];
  for (;;) {
    micBusy = true;
    if (!micRunning) { micBusy = false; vTaskDelay(20); continue; }
    size_t n = i2s.readBytes((char*)b, sizeof b);
    micBusy = false;
    n &= ~(size_t)1;
    if (!n) continue;
    if (sizeof(aring) - (aW - aR) < n) continue;   // PC not reading: drop
    for (size_t i = 0; i < n; i++) aring[(aW + i) & (sizeof(aring) - 1)] = b[i];
    aW += n;
  }
}
static void micSet(bool on) {
  if (on == micRunning) return;
  if (on) {
    i2s.setPinsPdmRx(42, 41);
    if (i2s.begin(I2S_MODE_PDM_RX, MIC_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) { aR = aW; micRunning = true; }
  } else {
    micRunning = false;
    while (micBusy) delay(2);
    i2s.end();
  }
}

// ---------- JSON status ----------
static void jStr(String& j, const char* k, const String& v) {
  j += ",\""; j += k; j += "\":\"";
  for (size_t i = 0; i < v.length(); i++) {
    char c = v[i];
    if (c == '"' || c == '\\') { j += '\\'; j += c; } else if ((uint8_t)c < 32) j += ' '; else j += c;
  }
  j += '"';
}
static void jInt(String& j, const char* k, long v) { j += ",\""; j += k; j += "\":"; j += String(v); }
static void jNum(String& j, const char* k, float v) { j += ",\""; j += k; j += "\":"; j += String(v, 1); }

static String cfgJson() {
  String j; j.reserve(2048);
  j += "{\"fw\":\"" FW_VERSION "\"";
  jInt(j, "cam", camOk ? 1 : 0); jStr(j, "cam_err", camErr); jStr(j, "sensor", sensorName);
  jInt(j, "max_size", maxSize);
  j += ",\"sizes\":[";
  for (int i = 0; i <= maxSize; i++) { if (i) j += ','; j += '['; j += String((int)resolution[i].width); j += ','; j += String((int)resolution[i].height); j += ']'; }
  j += ']';
  if (camOk) { sensor_t* s = esp_camera_sensor_get(); for (int i = 0; i < NCTL; i++) jInt(j, ctls[i].k, ctls[i].get(s)); }
  jInt(j, "fps_limit", fpsLimit); jInt(j, "xclk", xclkMhz); jInt(j, "led", ledOn); jInt(j, "mic", micRunning ? 1 : 0);
  jInt(j, "mic_rate", MIC_RATE); jInt(j, "usb", usbOn); jInt(j, "wifi", wifiMode); jInt(j, "ap_ch", apChan);
  jInt(j, "tx_power", txPower);
  jStr(j, "ap_ssid", apSsid); jStr(j, "ap_pass", apPass); jStr(j, "sta_ssid", staSsid); jStr(j, "sta_pass", staPass);
  bool sta = (wifiMode & 2) && WiFi.status() == WL_CONNECTED;
  jInt(j, "sta_status", (wifiMode & 2) ? (int)WiFi.status() : -1);
  jStr(j, "ap_ip", (wifiMode & 1) ? WiFi.softAPIP().toString() : String(""));
  jStr(j, "sta_ip", sta ? WiFi.localIP().toString() : String(""));
  jInt(j, "rssi", sta ? WiFi.RSSI() : 0);
  jInt(j, "ap_clients", (wifiMode & 1) ? WiFi.softAPgetStationNum() : 0);
  jInt(j, "stream_clients", streamClients);
  jNum(j, "cap_fps", capFps); jNum(j, "usb_fps", usbFps); jNum(j, "temp", temperatureRead());
  jInt(j, "heap", ESP.getFreeHeap()); jInt(j, "psram", ESP.getFreePsram()); jInt(j, "uptime", millis() / 1000);
  jInt(j, "saved", dirty ? 0 : 1);
  j += '}';
  return j;
}

// ---------- WiFi web page + MJPEG stream ----------
static const char PAGE[] =
  "<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
  "<title>XIAO CAM</title><style>body{margin:0;background:#0e1013;color:#9aa3ad;font-family:sans-serif;text-align:center}"
  "img{width:100%;max-width:1280px;display:block;margin:auto}a{color:#6aa6ff;margin:0 10px}</style></head><body>"
  "<img id=v alt='connecting...'><p>XIAO CAM &middot; <a href=/capture download=xiao.jpg>save picture</a><a href=/status>status</a></p>"
  "<script>document.getElementById('v').src='http://'+location.hostname+':81/stream';</script></body></html>";

static esp_err_t pageHandler(httpd_req_t* r) {
  httpd_resp_set_type(r, "text/html");
  return httpd_resp_send(r, PAGE, HTTPD_RESP_USE_STRLEN);
}
static esp_err_t statusHandler(httpd_req_t* r) {
  String j = cfgJson();
  httpd_resp_set_type(r, "application/json");
  return httpd_resp_send(r, j.c_str(), j.length());
}
static esp_err_t captureHandler(httpd_req_t* r) {
  uint8_t* b = nullptr; size_t cap = 0; uint32_t seen = 0;
  size_t n = copyLatest(b, cap, seen);
  if (!n) { free(b); httpd_resp_send_500(r); return ESP_FAIL; }
  httpd_resp_set_type(r, "image/jpeg");
  esp_err_t e = httpd_resp_send(r, (const char*)b, n);
  free(b);
  return e;
}

#define BOUNDARY "xcamframe"
static esp_err_t streamHandler(httpd_req_t* r) {
  httpd_resp_set_type(r, "multipart/x-mixed-replace;boundary=" BOUNDARY);
  httpd_resp_set_hdr(r, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(r, "Cache-Control", "no-cache");
  uint8_t* buf = nullptr; size_t cap = 0; uint32_t seen = 0; char hdr[100];
  streamClients++;
  for (;;) {
    size_t n = copyLatest(buf, cap, seen);
    if (!n) { vTaskDelay(5); continue; }
    int hl = snprintf(hdr, sizeof hdr, "\r\n--" BOUNDARY "\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n", (unsigned)n);
    if (httpd_resp_send_chunk(r, hdr, hl) != ESP_OK) break;
    if (httpd_resp_send_chunk(r, (const char*)buf, n) != ESP_OK) break;
  }
  streamClients--;
  free(buf);
  return ESP_FAIL;
}

static void startWeb() {
  if (webStarted) return;
  webStarted = true;
  httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
  httpd_handle_t page = nullptr, stream = nullptr;
  httpd_uri_t p = { "/", HTTP_GET, pageHandler, nullptr };
  httpd_uri_t st = { "/status", HTTP_GET, statusHandler, nullptr };
  httpd_uri_t cp = { "/capture", HTTP_GET, captureHandler, nullptr };
  if (httpd_start(&page, &cfg) == ESP_OK) {
    httpd_register_uri_handler(page, &p); httpd_register_uri_handler(page, &st); httpd_register_uri_handler(page, &cp);
  }
  cfg.server_port = 81; cfg.ctrl_port += 1;
  httpd_uri_t s = { "/stream", HTTP_GET, streamHandler, nullptr };
  if (httpd_start(&stream, &cfg) == ESP_OK) httpd_register_uri_handler(stream, &s);
}

static void applyWifi() {
  if (wifiMode == 0) { WiFi.softAPdisconnect(true); WiFi.disconnect(true); WiFi.mode(WIFI_OFF); return; }
  WiFi.mode(wifiMode == 1 ? WIFI_AP : wifiMode == 2 ? WIFI_STA : WIFI_AP_STA);
  WiFi.setSleep(false);
  if (wifiMode & 1) WiFi.softAP(apSsid.c_str(), apPass.length() >= 8 ? apPass.c_str() : nullptr, apChan);
  if ((wifiMode & 2) && staSsid.length()) { WiFi.disconnect(); WiFi.begin(staSsid.c_str(), staPass.c_str()); }
  WiFi.setTxPower((wifi_power_t)txPower);
  startWeb();
}

// ---------- USB-C ----------
static void sendPacket(const char* magic, const uint8_t* d, size_t n) {
  uint8_t h[8]; memcpy(h, magic, 4);
  h[4] = n; h[5] = n >> 8; h[6] = n >> 16; h[7] = n >> 24;
  Serial.write(h, 8); Serial.write(d, n);
}

static void sendAudio() {
  static uint8_t out[2048];
  uint32_t avail = aW - aR;
  while (avail >= 512) {
    uint32_t n = avail > sizeof out ? sizeof out : avail;
    n &= ~(uint32_t)1;
    for (uint32_t i = 0; i < n; i++) out[i] = aring[(aR + i) & (sizeof(aring) - 1)];
    aR += n;
    sendPacket("XAUD", out, n);
    avail = aW - aR;
  }
}

static void setValue(const char* k, int v) {
  if (!strcmp(k, "fps_limit")) fpsLimit = constrain(v, 0, 60);
  else if (!strcmp(k, "xclk")) {
    xclkMhz = constrain(v, 4, 24);
    if (camOk) { sensor_t* s = esp_camera_sensor_get(); if (s->set_xclk) s->set_xclk(s, LEDC_TIMER_0, xclkMhz); }
  }
  else if (!strcmp(k, "led")) { ledOn = v ? 1 : 0; digitalWrite(LED_PIN, ledOn ? LOW : HIGH); }
  else if (!strcmp(k, "mic")) { micOn = v ? 1 : 0; micSet(micOn); }
  else if (!strcmp(k, "usb")) usbOn = v ? 1 : 0;
  else if (!strcmp(k, "wifi")) { wifiMode = constrain(v, 0, 3); applyWifi(); }
  else if (!strcmp(k, "ap_ch")) apChan = constrain(v, 1, 13);
  else if (!strcmp(k, "tx_power")) { txPower = constrain(v, 8, 84); if (wifiMode) WiFi.setTxPower((wifi_power_t)txPower); }
  else if (camOk) {
    const Ctl* c = findCtl(k);
    if (c) {
      if (c == &ctls[0]) v = constrain(v, 0, maxSize);
      c->set(esp_camera_sensor_get(), v);
    }
  }
}

static void setString(const char* k, const String& v) {
  if (!strcmp(k, "ap_ssid") && v.length()) apSsid = v;
  else if (!strcmp(k, "ap_pass") && (v.length() == 0 || v.length() >= 8)) apPass = v;
  else if (!strcmp(k, "sta_ssid")) staSsid = v;
  else if (!strcmp(k, "sta_pass")) staPass = v;
}

static void runCmd(char* l) {
  char* arg = strchr(l, ' ');
  if (arg) *arg++ = 0;
  if (!strcmp(l, "set") && arg) {
    char* val = strchr(arg, ' ');
    if (!val) return;
    *val++ = 0;
    setValue(arg, atoi(val)); markDirty();
  } else if (!strcmp(l, "str") && arg) {
    char* val = strchr(arg, ' ');
    String v = "";
    if (val) { *val++ = 0; v = String(val); }
    setString(arg, v); markDirty();
  } else if (!strcmp(l, "wifi_apply")) { applyWifi(); markDirty(); }
  else if (!strcmp(l, "save")) saveAll();
  else if (!strcmp(l, "defaults")) { prefs.begin("xcam", false); prefs.clear(); prefs.end(); delay(100); ESP.restart(); }
  else if (!strcmp(l, "reboot")) { if (dirty) saveAll(); delay(100); ESP.restart(); }
  cfgNow = true;
}

static void handleSerial() {
  static char line[200]; static int len = 0;
  while (Serial.available()) {
    int c = Serial.read();
    if (c < 0) break;
    if (c == '\n' || c == '\r') { if (len) { line[len] = 0; runCmd(line); len = 0; } }
    else if (len < (int)sizeof(line) - 1) line[len++] = (char)c;
  }
}

void setup() {
  pinMode(LED_PIN, OUTPUT);
  Serial.setTxBufferSize(16384);
  Serial.begin(921600);
  lock = xSemaphoreCreateMutex();
  loadPrefs();
  digitalWrite(LED_PIN, ledOn ? LOW : HIGH);
  camOk = camInit();
  if (camOk) xTaskCreatePinnedToCore(captureTask, "cap", 4096, nullptr, 5, nullptr, 1);
  xTaskCreatePinnedToCore(micTask, "mic", 4096, nullptr, 4, nullptr, 0);
  if (micOn) micSet(true);
  applyWifi();
}

void loop() {
  handleSerial();
  uint32_t now = millis();
  static uint32_t lastStat = 0;
  if (now - lastStat >= 1000) {
    float dt = (now - lastStat) / 1000.0f;
    capFps = capFrames / dt; capFrames = 0;
    usbFps = usbFrames / dt; usbFrames = 0;
    lastStat = now; cfgNow = true;
  }
  if (dirty && now - dirtyAt > 1500) saveAll();
  if (!Serial) { delay(20); return; }
  if (cfgNow) { cfgNow = false; String j = cfgJson(); sendPacket("XCFG", (const uint8_t*)j.c_str(), j.length()); }
  if (micRunning) sendAudio();
  static uint8_t* buf = nullptr; static size_t cap = 0; static uint32_t seen = 0;
  if (camOk && usbOn) {
    size_t n = copyLatest(buf, cap, seen);
    if (n) { sendPacket("XCAM", buf, n); usbFrames++; return; }
  }
  delay(2);
}
'@

# ----------------------------------------------------------------------------
#  PC side: USB reader, recorder, local web server (C#)
# ----------------------------------------------------------------------------
$StudioCs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Ports;
using System.Management;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public interface IXSource {
  void Start(); void Stop(); bool Send(string line);
  bool Connected { get; } string PortLabel { get; }
}

// ============================================================================
//  Hub: newest frame, stats, recorder, board settings
// ============================================================================
public class XHub {
  public string Html = "", PicturesDir = "", VideosDir = "";
  public volatile string Status = "starting";
  public volatile string BoardJson = "";
  public volatile string LastMsg = "";
  public volatile bool Demo;
  public string WantPort = "auto";
  public IXSource Source;
  public XAvi Rec;
  public volatile float Level;
  public DateTime LastCfgAt = DateTime.MinValue, LastFrameAt = DateTime.MinValue;
  readonly object fl = new object(), sl = new object(), rl = new object();
  byte[] frame; long seq; int fw, fh;
  int winFrames; long winBytes; double fps, kbps;
  float peak; int peakN;
  long totalFrames;
  volatile bool shutdown;

  public void StartAll() {
    StartSource();
    var t = new Thread(TickLoop); t.IsBackground = true; t.Start();
  }
  public void StartSource() {
    IXSource old = Source;
    if (old != null) old.Stop();
    BoardJson = "";
    Source = Demo ? (IXSource)new XDemo(this) : new XSerial(this, WantPort);
    Source.Start();
  }
  void TickLoop() {
    int n = 0;
    while (!shutdown) {
      Thread.Sleep(1000); n++;
      lock (sl) { fps = winFrames; kbps = winBytes * 8.0 / 1000.0; winFrames = 0; winBytes = 0; }
      XAvi r = Rec;
      if (r != null && n % 2 == 0) { try { r.Tick(); } catch (Exception e) { LastMsg = "recording error: " + e.Message; } }
    }
  }
  public void OnFrame(byte[] jpg) {
    int w, h;
    XJpeg.Size(jpg, out w, out h);
    lock (fl) { frame = jpg; seq++; fw = w; fh = h; Monitor.PulseAll(fl); }
    LastFrameAt = DateTime.Now; totalFrames++;
    lock (sl) { winFrames++; winBytes += jpg.Length; }
    XAvi r = Rec;
    if (r != null) { try { r.AddVideo(jpg, w, h); } catch (Exception e) { LastMsg = "recording error: " + e.Message; StopRec(); } }
  }
  public void OnAudio(byte[] b, int off, int n) {
    for (int i = off; i + 1 < off + n; i += 2) {
      int s = (short)(b[i] | (b[i + 1] << 8));
      if (s < 0) s = -s;
      if (s > peak) peak = s;
      if (++peakN >= 1600) { Level = peak / 32768f; peak = 0; peakN = 0; }
    }
    XAvi r = Rec;
    if (r != null) { try { r.AddAudio(b, off, n); } catch (Exception e) { LastMsg = "recording error: " + e.Message; StopRec(); } }
  }
  public void OnCfg(string json) { BoardJson = json; LastCfgAt = DateTime.Now; }
  public void OnMsg(string m) { LastMsg = m; }
  public byte[] Latest() { lock (fl) { return frame; } }
  public byte[] WaitFrame(ref long last, int ms) {
    lock (fl) {
      if (seq == last) Monitor.Wait(fl, ms);
      if (seq == last || frame == null) return null;
      last = seq; return frame;
    }
  }
  public bool Cmd(string line) { IXSource s = Source; return s != null && s.Send(line); }

  public string Snapshot() {
    byte[] f = Latest();
    if (f == null) throw new Exception("no picture yet");
    Directory.CreateDirectory(PicturesDir);
    string p = Path.Combine(PicturesDir, "xiao-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".jpg");
    File.WriteAllBytes(p, f);
    LastMsg = "saved " + p;
    return p;
  }
  public string StartRec(double fpsReq, bool audio, double tl, double play) {
    lock (rl) {
      if (Rec != null) return Rec.FilePath;
      double f = fpsReq;
      if (f <= 0) { f = Math.Round(fps); if (f < 1) f = 10; }
      bool aud = audio && tl <= 0;
      if (aud && BoardJson.IndexOf("\"mic\":1", StringComparison.Ordinal) < 0) Cmd("set mic 1");
      string name = "xiao-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + (tl > 0 ? "-timelapse" : "");
      Rec = new XAvi(VideosDir, name, f, aud, tl, play <= 0 ? 30 : play, 16000);
      LastMsg = "recording " + name;
      return name;
    }
  }
  public void StopRec() {
    lock (rl) {
      XAvi r = Rec; Rec = null;
      if (r == null) return;
      try { r.Close(); LastMsg = r.Frames > 0 ? "saved " + r.FilePath : "nothing recorded (no frames arrived)"; }
      catch (Exception e) { LastMsg = "could not finish the file: " + e.Message; }
    }
  }
  public void Shutdown() {
    shutdown = true;
    StopRec();
    IXSource s = Source; if (s != null) s.Stop();
  }

  public static string Esc(string s) {
    if (s == null) return "";
    var sb = new StringBuilder();
    foreach (char c in s) {
      if (c == '"' || c == '\\') { sb.Append('\\'); sb.Append(c); }
      else if (c < 32) sb.Append(' ');
      else sb.Append(c);
    }
    return sb.ToString();
  }
  static string N(double d) { return d.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture); }

  public string StateJson() {
    var sb = new StringBuilder();
    IXSource s = Source;
    bool conn = s != null && s.Connected;
    bool live = (DateTime.Now - LastFrameAt).TotalSeconds < 2;
    bool oldFw = conn && live && (DateTime.Now - LastCfgAt).TotalSeconds > 4;
    double f, k; lock (sl) { f = fps; k = kbps; }
    byte[] fr = Latest();
    int w, h; lock (fl) { w = fw; h = fh; }
    sb.Append("{\"pc\":{");
    sb.Append("\"connected\":").Append(conn ? "true" : "false");
    sb.Append(",\"live\":").Append(live ? "true" : "false");
    sb.Append(",\"oldfw\":").Append(oldFw ? "true" : "false");
    sb.Append(",\"demo\":").Append(Demo ? "true" : "false");
    sb.Append(",\"port\":\"").Append(Esc(s == null ? "" : s.PortLabel)).Append("\"");
    sb.Append(",\"want\":\"").Append(Esc(WantPort)).Append("\"");
    sb.Append(",\"status\":\"").Append(Esc(Status)).Append("\"");
    sb.Append(",\"msg\":\"").Append(Esc(LastMsg)).Append("\"");
    sb.Append(",\"fps\":").Append(N(f)).Append(",\"kbps\":").Append(N(k));
    sb.Append(",\"kb\":").Append(fr == null ? "0" : N(fr.Length / 1024.0));
    sb.Append(",\"w\":").Append(w).Append(",\"h\":").Append(h);
    sb.Append(",\"level\":").Append(N(Level));
    sb.Append(",\"frames\":").Append(totalFrames);
    sb.Append(",\"pictures\":\"").Append(Esc(PicturesDir)).Append("\"");
    sb.Append(",\"videos\":\"").Append(Esc(VideosDir)).Append("\"");
    XAvi r = Rec;
    if (r != null) {
      sb.Append(",\"rec\":{\"file\":\"").Append(Esc(Path.GetFileName(r.FilePath))).Append("\"");
      sb.Append(",\"secs\":").Append(N((DateTime.Now - r.Started).TotalSeconds));
      sb.Append(",\"frames\":").Append(r.TotalFrames);
      sb.Append(",\"mb\":").Append(N(r.TotalBytes / 1048576.0));
      sb.Append(",\"fps\":").Append(N(r.Fps));
      sb.Append(",\"audio\":").Append(r.Audio ? "true" : "false");
      sb.Append(",\"tl\":").Append(N(r.TlSec));
      sb.Append(",\"part\":").Append(r.Part).Append("}");
    } else sb.Append(",\"rec\":null");
    sb.Append("},\"board\":");
    string b = BoardJson;
    sb.Append(string.IsNullOrEmpty(b) ? "null" : b);
    sb.Append("}");
    return sb.ToString();
  }

  // finish the recording if the console window is closed with X
  public delegate bool CtrlHandler(int type);
  [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(CtrlHandler h, bool add);
  static CtrlHandler keep;
  public static void HookConsole(XHub hub) {
    keep = delegate(int t) { try { hub.Shutdown(); } catch { } return false; };
    try { SetConsoleCtrlHandler(keep, true); } catch { }
  }
}

// ============================================================================
public static class XJpeg {
  public static bool Size(byte[] b, out int w, out int h) {
    w = 0; h = 0; int i = 2;
    while (i + 9 < b.Length) {
      if (b[i] != 0xFF) { i++; continue; }
      byte m = b[i + 1];
      if (m == 0xFF) { i++; continue; }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
      int L = (b[i + 2] << 8) | b[i + 3];
      if (m >= 0xC0 && m <= 0xC3) { h = (b[i + 5] << 8) | b[i + 6]; w = (b[i + 7] << 8) | b[i + 8]; return true; }
      if (m == 0xDA) return false;
      i += 2 + L;
    }
    return false;
  }
}

// ============================================================================
//  USB serial source
// ============================================================================
public class XSerial : IXSource {
  readonly XHub hub; readonly string want; SerialPort sp; Thread th; volatile bool running;
  readonly object wl = new object(); volatile bool connected; volatile string label = "";
  public XSerial(XHub h, string port) { hub = h; want = string.IsNullOrEmpty(port) ? "auto" : port; }
  public bool Connected { get { return connected; } }
  public string PortLabel { get { return label; } }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { running = false; connected = false; try { if (sp != null) sp.Close(); } catch { } }
  public bool Send(string line) {
    SerialPort s = sp;
    if (s == null || !s.IsOpen) return false;
    try { byte[] b = Encoding.UTF8.GetBytes(line + "\n"); lock (wl) { s.BaseStream.Write(b, 0, b.Length); } return true; }
    catch { return false; }
  }

  public static string FindPort() {
    try {
      using (var q = new ManagementObjectSearcher("SELECT Name, PNPDeviceID FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'")) {
        foreach (ManagementObject o in q.Get()) {
          string id = Convert.ToString(o["PNPDeviceID"]), name = Convert.ToString(o["Name"]);
          if (id.IndexOf("VID_303A", StringComparison.OrdinalIgnoreCase) >= 0 || id.IndexOf("VID_2886", StringComparison.OrdinalIgnoreCase) >= 0) {
            Match m = Regex.Match(name, @"\((COM\d+)\)");
            if (m.Success) return m.Groups[1].Value;
          }
        }
      }
    } catch { }
    return null;
  }

  static int Find(byte[] a, int from, int len) {
    for (int i = from; i + 3 < len; i++) {
      if (a[i] != 0x58) continue;
      byte b1 = a[i + 1], b2 = a[i + 2], b3 = a[i + 3];
      if ((b1 == 'C' && b2 == 'A' && b3 == 'M') || (b1 == 'A' && b2 == 'U' && b3 == 'D') ||
          (b1 == 'C' && b2 == 'F' && b3 == 'G') || (b1 == 'M' && b2 == 'S' && b3 == 'G')) return i;
    }
    return -1;
  }

  void Loop() {
    byte[] acc = new byte[8 << 20]; int len = 0; byte[] chunk = new byte[65536];
    while (running) {
      try {
        if (sp == null || !sp.IsOpen) {
          string p = want == "auto" ? FindPort() : want;
          if (p == null) { label = ""; connected = false; hub.Status = "XIAO not found - plug it in with a USB-C DATA cable"; Thread.Sleep(1000); continue; }
          label = p; hub.Status = "opening " + p;
          var s = new SerialPort(p, 921600);
          s.DtrEnable = true; s.RtsEnable = false;
          s.ReadTimeout = 3000; s.WriteTimeout = 1000; s.ReadBufferSize = 1 << 21;
          s.Open(); sp = s; len = 0; connected = true;
          hub.Status = "connected, waiting for pictures";
          Send("get");
        }
        int n = sp.BaseStream.Read(chunk, 0, chunk.Length);
        if (n <= 0) continue;
        if (len + n > acc.Length) len = 0;
        Buffer.BlockCopy(chunk, 0, acc, len, n); len += n;
        int pos = 0;
        while (true) {
          int m = Find(acc, pos, len);
          if (m < 0) { pos = Math.Max(pos, len - 3); break; }
          if (len - m < 8) { pos = m; break; }
          int L = acc[m + 4] | (acc[m + 5] << 8) | (acc[m + 6] << 16) | (acc[m + 7] << 24);
          char k = (char)acc[m + 1]; char k2 = (char)acc[m + 2];
          bool cam = k == 'C' && k2 == 'A', aud = k == 'A', cfg = k == 'C' && k2 == 'F', msg = k == 'M';
          int max = cam ? 3000000 : aud ? 65536 : cfg ? 16000 : 1000;
          int min = cam ? 100 : 1;
          if (L < min || L > max) { pos = m + 1; continue; }
          if (len - m - 8 < L) { pos = m; break; }
          int d = m + 8;
          if (cam) {
            if (acc[d] == 0xFF && acc[d + 1] == 0xD8) {
              var f = new byte[L]; Buffer.BlockCopy(acc, d, f, 0, L);
              hub.OnFrame(f); hub.Status = "live";
              pos = d + L;
            } else pos = m + 1;
          } else if (aud) { hub.OnAudio(acc, d, L); pos = d + L; }
          else if (cfg) {
            string j = Encoding.UTF8.GetString(acc, d, L);
            if (j.StartsWith("{") && j.EndsWith("}")) { hub.OnCfg(j); if (hub.Status != "live") hub.Status = "connected"; pos = d + L; }
            else pos = m + 1;
          } else { hub.OnMsg("camera says: " + Encoding.ASCII.GetString(acc, d, L)); pos = d + L; }
        }
        if (pos > 0) { Buffer.BlockCopy(acc, pos, acc, 0, len - pos); len -= pos; }
      } catch (TimeoutException) {
        hub.Status = "connected, but nothing arrives - flash the firmware (menu option 1)";
      } catch (Exception e) {
        connected = false;
        if (!running) break;
        hub.Status = "disconnected (" + e.Message.Trim() + ") - retrying";
        try { if (sp != null) sp.Close(); } catch { }
        sp = null; Thread.Sleep(1000);
      }
    }
    try { if (sp != null) sp.Close(); } catch { }
  }
}

// ============================================================================
//  Demo source (no board): fake camera with the same settings protocol
// ============================================================================
public class XDemo : IXSource {
  readonly XHub hub; Thread th; volatile bool running;
  readonly Dictionary<string, int> v = new Dictionary<string, int>();
  readonly Dictionary<string, string> s = new Dictionary<string, string>();
  readonly object l = new object();
  static readonly int[] SW = { 96, 160, 128, 176, 240, 240, 320, 320, 400, 480, 640, 800, 1024, 1280, 1280, 1600, 1920, 720, 864, 2048 };
  static readonly int[] SH = { 96, 120, 128, 144, 176, 240, 240, 320, 296, 320, 480, 600, 768, 720, 1024, 1200, 1080, 1280, 1536, 1536 };
  const int MAXS = 19;
  double fpsNow;
  public XDemo(XHub h) {
    hub = h;
    string init = "framesize=11,quality=10,brightness=0,contrast=0,saturation=0,sharpness=0,denoise=0,effect=0,awb=1,awb_gain=1,wb_mode=0," +
      "aec=1,aec2=0,ae_level=0,aec_value=300,agc=1,agc_gain=0,gainceiling=0,bpc=0,wpc=1,raw_gma=1,lenc=1,hmirror=0,vflip=1,dcw=1,colorbar=0," +
      "fps_limit=0,xclk=20,led=0,mic=0,usb=1,wifi=1,ap_ch=6,tx_power=78";
    foreach (string kv in init.Split(',')) { string[] p = kv.Split('='); v[p[0]] = int.Parse(p[1]); }
    s["ap_ssid"] = "XIAO-CAM"; s["ap_pass"] = "xiaocam123"; s["sta_ssid"] = ""; s["sta_pass"] = "";
  }
  public bool Connected { get { return running; } }
  public string PortLabel { get { return "DEMO"; } }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); hub.Status = "demo"; }
  public void Stop() { running = false; }
  int Get(string k) { lock (l) { int x; return v.TryGetValue(k, out x) ? x : 0; } }
  public bool Send(string line) {
    string[] p = line.Trim().Split(new[] { ' ' }, 3);
    lock (l) {
      if (p[0] == "set" && p.Length == 3) {
        int x; if (!int.TryParse(p[2], out x)) return false;
        if (p[1] == "framesize") x = Math.Max(0, Math.Min(MAXS, x));
        v[p[1]] = x;
      } else if (p[0] == "str" && p.Length >= 2) s[p[1]] = p.Length == 3 ? p[2] : "";
      else if (p[0] == "defaults") { v["framesize"] = 11; v["quality"] = 10; }
    }
    hub.OnCfg(Json());
    return true;
  }
  string Json() {
    var sb = new StringBuilder();
    sb.Append("{\"fw\":\"2.0-demo\",\"cam\":1,\"cam_err\":\"\",\"sensor\":\"DEMO (OV3660-like)\",\"max_size\":").Append(MAXS);
    sb.Append(",\"sizes\":[");
    for (int i = 0; i <= MAXS; i++) { if (i > 0) sb.Append(','); sb.Append('[').Append(SW[i]).Append(',').Append(SH[i]).Append(']'); }
    sb.Append(']');
    lock (l) {
      foreach (var kv in v) sb.Append(",\"").Append(kv.Key).Append("\":").Append(kv.Value);
      foreach (var kv in s) sb.Append(",\"").Append(kv.Key).Append("\":\"").Append(XHub.Esc(kv.Value)).Append('"');
      int wm = v["wifi"];
      sb.Append(",\"mic_rate\":16000,\"sta_status\":").Append((wm & 2) != 0 ? (s["sta_ssid"].Length > 0 ? 3 : 1) : -1);
      sb.Append(",\"ap_ip\":\"").Append((wm & 1) != 0 ? "192.168.4.1" : "").Append('"');
      sb.Append(",\"sta_ip\":\"").Append((wm & 2) != 0 && s["sta_ssid"].Length > 0 ? "192.168.1.77" : "").Append('"');
      sb.Append(",\"rssi\":").Append((wm & 2) != 0 ? -58 : 0);
      sb.Append(",\"ap_clients\":0,\"stream_clients\":0");
    }
    sb.Append(",\"cap_fps\":").Append(((int)fpsNow).ToString()).Append(",\"usb_fps\":").Append(((int)fpsNow).ToString());
    sb.Append(",\"temp\":41.5,\"heap\":231000,\"psram\":6800000,\"uptime\":").Append((int)(Environment.TickCount / 1000 % 100000));
    sb.Append(",\"saved\":1}");
    return sb.ToString();
  }
  void Loop() { try { Loop2(); } catch (Exception e) { hub.OnMsg("demo crashed: " + e.ToString()); } }
  void Loop2() {
    var sw = Stopwatch.StartNew();
    long audioDone = 0; double nextFrame = 0, nextCfg = 0, fpsT = 0; int fpsN = 0;
    ImageCodecInfo jpg = null;
    foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpg = c;
    while (running) {
      double t = sw.Elapsed.TotalSeconds;
      if (t >= nextCfg) { hub.OnCfg(Json()); nextCfg = t + 1; }
      if (t - fpsT >= 1) { fpsNow = fpsN / (t - fpsT); fpsN = 0; fpsT = t; }
      if (Get("mic") == 1) {
        long due = (long)(t * 16000);
        int n = (int)Math.Min(due - audioDone, 8000);
        if (n >= 320) {
          byte[] a = new byte[n * 2];
          for (int i = 0; i < n; i++) {
            double tt = (audioDone + i) / 16000.0;
            double amp = 0.25 * (0.5 + 0.5 * Math.Sin(tt * 3));
            short x = (short)(Math.Sin(2 * Math.PI * 440 * tt) * amp * 32767);
            a[2 * i] = (byte)x; a[2 * i + 1] = (byte)(x >> 8);
          }
          audioDone += n; hub.OnAudio(a, 0, a.Length);
        }
      } else audioDone = (long)(t * 16000);
      int fl = Get("fps_limit");
      double period = 1.0 / (fl > 0 ? Math.Min(fl, 25) : 20);
      if (t >= nextFrame && Get("usb") == 1) {
        nextFrame = t + period;
        try { hub.OnFrame(Render(t, jpg)); fpsN++; } catch (Exception e) { hub.OnMsg("demo: " + e.Message); }
      }
      Thread.Sleep(4);
    }
  }
  public byte[] Render(double t, ImageCodecInfo codec) {
    int fs = Get("framesize"); int w = SW[fs], h = SH[fs];
    int br = Get("brightness"), sat = Get("saturation");
    using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb))
    using (var g = Graphics.FromImage(bmp)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      int b0 = 30 + br * 20;
      using (var bg = new LinearGradientBrush(new Rectangle(0, 0, w, h), Color.FromArgb(b0, b0 + 10, b0 + 25 + sat * 10), Color.FromArgb(b0 + 40, b0 + 20, b0), 35f))
        g.FillRectangle(bg, 0, 0, w, h);
      if (Get("colorbar") == 1) {
        Color[] cols = { Color.White, Color.Yellow, Color.Cyan, Color.Lime, Color.Magenta, Color.Red, Color.Blue, Color.Black };
        for (int i = 0; i < 8; i++) using (var cb = new SolidBrush(cols[i])) g.FillRectangle(cb, i * w / 8, 0, w / 8 + 1, h);
      } else {
        using (var pen = new Pen(Color.FromArgb(60, 255, 255, 255), Math.Max(1, w / 400f)))
          for (int i = 1; i < 12; i++) { g.DrawLine(pen, i * w / 12, 0, i * w / 12, h); g.DrawLine(pen, 0, i * h / 12, w, i * h / 12); }
        float r = Math.Min(w, h) * 0.12f;
        float cx = (float)(w / 2 + Math.Cos(t * 0.9) * w * 0.3), cy = (float)(h / 2 + Math.Sin(t * 1.3) * h * 0.25);
        using (var cb = new SolidBrush(Color.FromArgb(220, 59, 130, 246))) g.FillEllipse(cb, cx - r, cy - r, 2 * r, 2 * r);
        using (var cb = new SolidBrush(Color.FromArgb(200, 239, 68, 68))) g.FillRectangle(cb, w * 0.1f, h * 0.65f, w * 0.15f, h * 0.2f);
        // fine detail target, for the focus meter
        using (var pen = new Pen(Color.White, 1)) for (int i = 0; i < 40; i++) g.DrawLine(pen, w * 0.7f + i * 3, h * 0.65f, w * 0.7f + i * 3, h * 0.85f);
      }
      float fsz = Math.Max(8, h / 18f);
      using (var font = new Font("Segoe UI", fsz, FontStyle.Bold))
      using (var tb = new SolidBrush(Color.White)) {
        g.DrawString("DEMO  " + w + "x" + h + "  q" + Get("quality"), font, tb, w * 0.03f, h * 0.04f);
        g.DrawString(DateTime.Now.ToString("HH:mm:ss.f"), font, tb, w * 0.03f, h * 0.04f + fsz * 1.6f);
      }
      if (Get("hmirror") == 1) bmp.RotateFlip(RotateFlipType.RotateNoneFlipX);
      if (Get("vflip") == 0) bmp.RotateFlip(RotateFlipType.RotateNoneFlipY);
      var ms = new MemoryStream();
      var ep = new EncoderParameters(1);
      long q = Math.Max(10, Math.Min(95, 100 - (Get("quality") - 4) * 3 / 2));
      ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, q);
      bmp.Save(ms, codec, ep);
      return ms.ToArray();
    }
  }
}

// ============================================================================
//  AVI writer: MJPEG video (+ PCM16 mono audio), plays in VLC / Windows players
// ============================================================================
public class XAvi {
  readonly object l = new object();
  readonly string dir, baseName;
  FileStream f; BinaryWriter w;
  public string FilePath = "";
  public double Fps, TlSec, PlayFps; public bool Audio; public int Rate;
  public int Part = 1, W, H;
  public long Frames, AudioBytes, TotalFrames, TotalBytesClosed;
  public DateTime Started = DateTime.Now;
  DateTime t0, lastTl;
  long moviSizePos, moviPos, avihFramesPos, avihBufPos, vLenPos, aLenPos;
  List<uint> idx = new List<uint>();
  int maxChunk; bool closed;
  const long SplitBytes = 1800L * 1024 * 1024;

  public XAvi(string dir, string baseName, double fps, bool audio, double tlSec, double playFps, int rate) {
    this.dir = dir; this.baseName = baseName; Fps = fps; Audio = audio; TlSec = tlSec; PlayFps = playFps; Rate = rate;
  }
  public long TotalBytes { get { lock (l) { return TotalBytesClosed + (f == null ? 0 : f.Position); } } }

  void FCC(string s) { w.Write((byte)s[0]); w.Write((byte)s[1]); w.Write((byte)s[2]); w.Write((byte)s[3]); }
  static uint Code(string s) { return (uint)(s[0] | (s[1] << 8) | (s[2] << 16) | (s[3] << 24)); }
  void At(long pos, uint val) { long e = f.Position; f.Seek(pos, SeekOrigin.Begin); w.Write(val); f.Seek(e, SeekOrigin.Begin); }
  void SizeFrom(long pos) { At(pos, (uint)(f.Position - pos - 4)); }

  void Open() {
    Directory.CreateDirectory(dir);
    FilePath = Path.Combine(dir, baseName + (Part > 1 ? "_part" + Part : "") + ".avi");
    f = new FileStream(FilePath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 1 << 20);
    w = new BinaryWriter(f);
    idx = new List<uint>(); Frames = 0; AudioBytes = 0; maxChunk = 0; aLenPos = 0;
    double pf = TlSec > 0 ? PlayFps : Fps;
    int streams = Audio ? 2 : 1;
    FCC("RIFF"); w.Write(0u); FCC("AVI ");
    FCC("LIST"); long hdrl = f.Position; w.Write(0u); FCC("hdrl");
    FCC("avih"); w.Write(56u);
    w.Write((uint)Math.Round(1000000.0 / pf)); w.Write(0u); w.Write(0u); w.Write(0x10u);
    avihFramesPos = f.Position; w.Write(0u); w.Write(0u); w.Write((uint)streams);
    avihBufPos = f.Position; w.Write(1u << 20);
    w.Write((uint)W); w.Write((uint)H); w.Write(0u); w.Write(0u); w.Write(0u); w.Write(0u);
    // video stream
    FCC("LIST"); long s1 = f.Position; w.Write(0u); FCC("strl");
    FCC("strh"); w.Write(56u); FCC("vids"); FCC("MJPG"); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
    w.Write(1000u); w.Write((uint)Math.Round(pf * 1000)); w.Write(0u);
    vLenPos = f.Position; w.Write(0u);
    w.Write(1u << 20); w.Write(0xFFFFFFFFu); w.Write(0u);
    w.Write((short)0); w.Write((short)0); w.Write((short)W); w.Write((short)H);
    FCC("strf"); w.Write(40u); w.Write(40u); w.Write(W); w.Write(H); w.Write((ushort)1); w.Write((ushort)24); FCC("MJPG");
    w.Write((uint)(W * H * 3)); w.Write(0); w.Write(0); w.Write(0u); w.Write(0u);
    SizeFrom(s1);
    if (Audio) {
      FCC("LIST"); long s2 = f.Position; w.Write(0u); FCC("strl");
      FCC("strh"); w.Write(56u); FCC("auds"); w.Write(0u); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
      w.Write(2u); w.Write((uint)(Rate * 2)); w.Write(0u);
      aLenPos = f.Position; w.Write(0u);
      w.Write(16384u); w.Write(0xFFFFFFFFu); w.Write(2u);
      w.Write((short)0); w.Write((short)0); w.Write((short)0); w.Write((short)0);
      FCC("strf"); w.Write(18u); w.Write((ushort)1); w.Write((ushort)1); w.Write((uint)Rate); w.Write((uint)(Rate * 2));
      w.Write((ushort)2); w.Write((ushort)16); w.Write((ushort)0);
      SizeFrom(s2);
    }
    SizeFrom(hdrl);
    FCC("LIST"); moviSizePos = f.Position; w.Write(0u); moviPos = f.Position; FCC("movi");
    w.Flush();
  }

  void Chunk(string fcc, byte[] d, int off, int n) {
    uint rel = (uint)(f.Position - moviPos);
    FCC(fcc); w.Write((uint)n); w.Write(d, off, n);
    if ((n & 1) == 1) w.Write((byte)0);
    idx.Add(Code(fcc)); idx.Add(0x10u); idx.Add(rel); idx.Add((uint)n);
    if (n > maxChunk) maxChunk = n;
  }

  void Patch() {
    At(4, (uint)(f.Position - 8));
    At(moviSizePos, (uint)(f.Position - moviSizePos - 4));
    At(avihFramesPos, (uint)Frames); At(vLenPos, (uint)Frames);
    At(avihBufPos, (uint)(maxChunk + 8));
    if (aLenPos > 0) At(aLenPos, (uint)(AudioBytes / 2));
  }

  void Finish() {
    if (f == null) return;
    At(moviSizePos, (uint)(f.Position - moviSizePos - 4));
    FCC("idx1"); w.Write((uint)(idx.Count * 4));
    foreach (uint u in idx) w.Write(u);
    Patch();
    w.Flush(); TotalBytesClosed += f.Length; f.Close();
    f = null; w = null;
  }

  public void AddVideo(byte[] jpg, int jw, int jh) {
    lock (l) {
      if (closed || jw <= 0 || jh <= 0) return;
      DateTime now = DateTime.Now;
      if (f == null) { W = jw; H = jh; t0 = now; Open(); }
      else if (jw != W || jh != H || f.Position > SplitBytes) {
        // resolution changed (or file too big): continue in a new part file
        Finish(); Part++; W = jw; H = jh; t0 = now; Open();
      }
      if (TlSec > 0) {
        if (Frames == 0 || (now - lastTl).TotalSeconds >= TlSec) { Chunk("00dc", jpg, 0, jpg.Length); Frames++; TotalFrames++; lastTl = now; }
        return;
      }
      long target = (long)Math.Floor((now - t0).TotalSeconds * Fps) + 1;
      long n = target - Frames;
      if (n <= 0) return;
      if (n > Fps + 2) { t0 = now - TimeSpan.FromSeconds(Frames / Fps); n = 1; }  // long gap (unplugged): cut instead of freezing
      for (long i = 0; i < n; i++) { Chunk("00dc", jpg, 0, jpg.Length); Frames++; TotalFrames++; }
    }
  }
  public void AddAudio(byte[] d, int off, int n) {
    lock (l) {
      if (closed || f == null || !Audio || TlSec > 0) return;
      Chunk("01wb", d, off, n & ~1); AudioBytes += n & ~1;
    }
  }
  public void Tick() { lock (l) { if (f != null && !closed) { Patch(); w.Flush(); f.Flush(); } } }
  public void Close() { lock (l) { if (closed) return; closed = true; Finish(); } }
}

// ============================================================================
//  Tiny local web server (127.0.0.1 only)
// ============================================================================
public class XWeb {
  readonly XHub hub; TcpListener lst; public int Port;
  public XWeb(XHub h) { hub = h; }
  public int Start(int port) {
    for (int i = 0; i < 30; i++) {
      try {
        lst = new TcpListener(IPAddress.Loopback, port + i); lst.Start(); Port = port + i;
        var t = new Thread(Accept); t.IsBackground = true; t.Start();
        return Port;
      } catch (SocketException) { }
    }
    throw new Exception("no free local port for the studio");
  }
  void Accept() {
    while (true) {
      TcpClient c;
      try { c = lst.AcceptTcpClient(); } catch { return; }
      var t = new Thread(Handle); t.IsBackground = true; t.Start(c);
    }
  }
  static string ReadHead(NetworkStream ns) {
    var buf = new List<byte>(); int b;
    while (buf.Count < 16384 && (b = ns.ReadByte()) >= 0) {
      buf.Add((byte)b);
      int n = buf.Count;
      if (n >= 4 && buf[n - 1] == 10 && buf[n - 2] == 13 && buf[n - 3] == 10 && buf[n - 4] == 13) return Encoding.ASCII.GetString(buf.ToArray());
    }
    return null;
  }
  static Dictionary<string, string> Query(string q) {
    var d = new Dictionary<string, string>();
    foreach (string part in q.Split('&')) {
      if (part.Length == 0) continue;
      int e = part.IndexOf('=');
      string k = e < 0 ? part : part.Substring(0, e), v = e < 0 ? "" : part.Substring(e + 1);
      d[Uri.UnescapeDataString(k.Replace('+', ' '))] = Uri.UnescapeDataString(v.Replace('+', ' '));
    }
    return d;
  }
  static void Send(NetworkStream ns, string code, string type, byte[] body) {
    string h = "HTTP/1.1 " + code + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    byte[] hb = Encoding.ASCII.GetBytes(h);
    ns.Write(hb, 0, hb.Length); ns.Write(body, 0, body.Length);
  }
  static void Json(NetworkStream ns, string j) { Send(ns, "200 OK", "application/json", Encoding.UTF8.GetBytes(j)); }
  static string Ok(bool ok, string extra) { return "{\"ok\":" + (ok ? "true" : "false") + (extra == null ? "" : "," + extra) + "}"; }
  static string G(Dictionary<string, string> q, string k) { string v; return q.TryGetValue(k, out v) ? v : ""; }
  static double D(Dictionary<string, string> q, string k, double def) {
    double d; return double.TryParse(G(q, k), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d) ? d : def;
  }
  static readonly Regex KeyRx = new Regex("^[a-z0-9_]{1,20}$");
  static readonly string[] Cmds = { "get", "save", "defaults", "reboot", "wifi_apply" };

  void Handle(object o) {
    var c = (TcpClient)o;
    try {
      c.NoDelay = true;
      NetworkStream ns = c.GetStream(); ns.ReadTimeout = 10000;
      string head = ReadHead(ns);
      if (head == null) return;
      string[] first = head.Split('\n')[0].Trim().Split(' ');
      if (first.Length < 2) return;
      string url = first[1], path = url, qs = "";
      int qi = url.IndexOf('?');
      if (qi >= 0) { path = url.Substring(0, qi); qs = url.Substring(qi + 1); }
      var q = Query(qs);
      ns.ReadTimeout = Timeout.Infinite;
      Route(c, ns, path, q);
    } catch { }
    finally { try { c.Close(); } catch { } }
  }

  void Route(TcpClient c, NetworkStream ns, string path, Dictionary<string, string> q) {
    switch (path) {
      case "/":
        Send(ns, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(hub.Html)); return;
      case "/stream": Stream(c, ns); return;
      case "/frame.jpg": {
        byte[] f = hub.Latest();
        if (f == null) Send(ns, "404 Not Found", "text/plain", Encoding.ASCII.GetBytes("no frame"));
        else Send(ns, "200 OK", "image/jpeg", f);
        return;
      }
      case "/api/state": Json(ns, hub.StateJson()); return;
      case "/api/set": {
        string k = G(q, "k"); int v;
        bool ok = KeyRx.IsMatch(k) && int.TryParse(G(q, "v"), out v) && hub.Cmd("set " + k + " " + v.ToString());
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/str": {
        string k = G(q, "k"), v = G(q, "v").Replace("\r", "").Replace("\n", "");
        bool ok = KeyRx.IsMatch(k) && v.Length <= 64 && hub.Cmd("str " + k + " " + v);
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/cmd": {
        string cmd = G(q, "c");
        bool ok = Array.IndexOf(Cmds, cmd) >= 0 && hub.Cmd(cmd);
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/snap":
        try { string p = hub.Snapshot(); Json(ns, Ok(true, "\"file\":\"" + XHub.Esc(p) + "\"")); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/rec/start":
        try {
          string n = hub.StartRec(D(q, "fps", 0), G(q, "audio") == "1", D(q, "tl", 0), D(q, "play", 30));
          Json(ns, Ok(true, "\"file\":\"" + XHub.Esc(n) + "\""));
        } catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/rec/stop": hub.StopRec(); Json(ns, Ok(true, "\"msg\":\"" + XHub.Esc(hub.LastMsg) + "\"")); return;
      case "/api/open": {
        string d = G(q, "d") == "pictures" ? hub.PicturesDir : hub.VideosDir;
        try { Directory.CreateDirectory(d); Process.Start("explorer.exe", "\"" + d + "\""); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      }
      case "/api/ports": {
        var sb = new StringBuilder("{\"ok\":true,\"auto\":\"");
        sb.Append(XHub.Esc(XSerial.FindPort() ?? "")).Append("\",\"ports\":[");
        string[] ps = SerialPort.GetPortNames(); Array.Sort(ps);
        for (int i = 0; i < ps.Length; i++) { if (i > 0) sb.Append(','); sb.Append('"').Append(XHub.Esc(ps[i])).Append('"'); }
        sb.Append("]}");
        Json(ns, sb.ToString()); return;
      }
      case "/api/port": {
        string p = G(q, "p");
        if (p == "demo") { hub.Demo = true; }
        else if (p == "auto" || Regex.IsMatch(p, "^COM[0-9]{1,3}$")) { hub.Demo = false; hub.WantPort = p; }
        else { Json(ns, Ok(false, null)); return; }
        hub.StartSource(); Json(ns, Ok(true, null)); return;
      }
      case "/api/quit": {
        Json(ns, Ok(true, null));
        var t = new Thread(delegate() { Thread.Sleep(300); hub.Shutdown(); Environment.Exit(0); });
        t.IsBackground = true; t.Start();
        return;
      }
      default:
        Send(ns, "404 Not Found", "text/plain", Encoding.ASCII.GetBytes("not found")); return;
    }
  }

  void Stream(TcpClient c, NetworkStream ns) {
    byte[] hb = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=xframe\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
    ns.Write(hb, 0, hb.Length);
    long last = -1;
    while (true) {
      byte[] f = hub.WaitFrame(ref last, 1000);
      if (f == null) {
        if (c.Client.Poll(0, SelectMode.SelectRead) && c.Client.Available == 0) return;  // browser went away
        continue;
      }
      byte[] ph = Encoding.ASCII.GetBytes("--xframe\r\nContent-Type: image/jpeg\r\nContent-Length: " + f.Length + "\r\n\r\n");
      ns.Write(ph, 0, ph.Length); ns.Write(f, 0, f.Length); ns.Write(new byte[] { 13, 10 }, 0, 2);
    }
  }
}
'@

# ----------------------------------------------------------------------------
#  Studio web page
# ----------------------------------------------------------------------------
$Html = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>XIAO CAM Studio</title><link rel="icon" href="data:,">
<style>
:root{--bg:#0d0f12;--p:#15181d;--p2:#1b1f25;--ln:#262b33;--tx:#d9dee6;--mu:#8b94a1;--ac:#3b82f6;--ok:#22c55e;--wa:#f59e0b;--er:#ef4444;--r:8px}
*{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--tx);font:13px/1.4 "Segoe UI",system-ui,sans-serif}
button,select,input{font:inherit;color:inherit}
button{background:var(--p2);border:1px solid var(--ln);border-radius:6px;padding:6px 11px;cursor:pointer;transition:background .12s,border-color .12s}
button:hover{background:#232830;border-color:#323844}button:active{transform:translateY(1px)}
button.pri{background:var(--ac);border-color:var(--ac);color:#fff}button.pri:hover{background:#2f6fdc}
button.danger{border-color:#5b2626;color:#fca5a5}button.danger.arm{background:var(--er);color:#fff}
select,input[type=text],input[type=password],input[type=number]{background:var(--bg);border:1px solid var(--ln);border-radius:6px;padding:5px 8px;width:100%}
select:focus,input:focus{outline:none;border-color:var(--ac)}
#app{display:grid;grid-template-rows:50px 1fr;height:100%}
header{display:flex;align-items:center;gap:10px;padding:0 14px;background:var(--p);border-bottom:1px solid var(--ln)}
.brand{font-weight:700;letter-spacing:.3px;display:flex;align-items:center;gap:8px}.brand small{color:var(--mu);font-weight:400}
.pill{display:flex;align-items:center;gap:6px;padding:3px 10px;border-radius:99px;background:var(--p2);border:1px solid var(--ln);color:var(--mu);max-width:360px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:8px;height:8px;border-radius:50%;background:var(--mu);flex:none}.dot.ok{background:var(--ok)}.dot.wa{background:var(--wa)}.dot.er{background:var(--er)}
.chips{display:flex;gap:6px;margin-left:6px}.chip{padding:3px 8px;border-radius:6px;background:var(--bg);border:1px solid var(--ln);color:var(--mu);font-variant-numeric:tabular-nums;white-space:nowrap}.chip b{color:var(--tx);font-weight:600}
.sp{flex:1}
#recBtnTop{display:flex;align-items:center;gap:7px;font-weight:600}#recBtnTop .rd{width:10px;height:10px;border-radius:50%;background:var(--er)}
#recBtnTop.on{background:#3a1414;border-color:var(--er);color:#fecaca}#recBtnTop.on .rd{animation:bl 1s infinite}
@keyframes bl{50%{opacity:.25}}
main{display:grid;grid-template-columns:1fr 372px;min-height:0}
#left{display:grid;grid-template-rows:1fr auto;min-height:0;min-width:0}
#stage{position:relative;overflow:hidden;background:#050607;cursor:grab}
#stage.drag{cursor:grabbing}
#box{position:absolute;left:50%;top:50%;transform-origin:50% 50%}
#v{display:block;width:100%;height:100%;user-select:none;-webkit-user-drag:none}
#ovl{position:absolute;inset:0;pointer-events:none}
.grid3{background:linear-gradient(90deg,transparent calc(33.33% - .5px),rgba(255,255,255,.45) 0,rgba(255,255,255,.45) calc(33.33% + .5px),transparent 0,transparent calc(66.66% - .5px),rgba(255,255,255,.45) 0,rgba(255,255,255,.45) calc(66.66% + .5px),transparent 0),linear-gradient(transparent calc(33.33% - .5px),rgba(255,255,255,.45) 0,rgba(255,255,255,.45) calc(33.33% + .5px),transparent 0,transparent calc(66.66% - .5px),rgba(255,255,255,.45) 0,rgba(255,255,255,.45) calc(66.66% + .5px),transparent 0)}
.cross::before,.cross::after{content:"";position:absolute;background:rgba(255,70,70,.85)}
.cross::before{left:50%;top:calc(50% - 22px);width:1px;height:44px}.cross::after{top:50%;left:calc(50% - 22px);height:1px;width:44px}
#tools{position:absolute;top:10px;left:10px;display:flex;gap:4px;z-index:3}
#tools button{background:rgba(20,23,28,.82);backdrop-filter:blur(6px);padding:5px 9px;font-size:12px}
#tools button.on{border-color:var(--ac);color:#bfd6ff}
#zoomlbl{position:absolute;right:10px;top:10px;background:rgba(20,23,28,.82);padding:3px 8px;border-radius:6px;color:var(--mu);font-size:12px;z-index:3}
#recbadge{position:absolute;right:10px;bottom:10px;display:none;align-items:center;gap:7px;background:rgba(58,20,20,.9);color:#fecaca;padding:4px 10px;border-radius:6px;font-weight:600;font-variant-numeric:tabular-nums;z-index:3}
#recbadge .rd{width:9px;height:9px;border-radius:50%;background:var(--er);animation:bl 1s infinite}
#empty{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;color:var(--mu);text-align:center;padding:20px}
#empty b{color:var(--tx);font-size:15px}
#banner{position:absolute;left:50%;transform:translateX(-50%);top:52px;z-index:4;display:none;max-width:80%;background:#3a2a0c;border:1px solid #6b4e12;color:#fde3a7;padding:8px 14px;border-radius:8px}
#bottom{display:grid;grid-template-columns:1.2fr 1fr 1fr;gap:10px;padding:10px;background:var(--p);border-top:1px solid var(--ln)}
.card{background:var(--bg);border:1px solid var(--ln);border-radius:var(--r);padding:8px 10px;min-width:0}
.card h4{margin:0 0 6px;font-size:11px;letter-spacing:.6px;text-transform:uppercase;color:var(--mu);font-weight:600;display:flex;justify-content:space-between;align-items:center}
.card h4 button{padding:1px 7px;font-size:11px;text-transform:none;letter-spacing:0}
.meter{height:10px;border-radius:5px;background:#20242b;position:relative;overflow:hidden}
.meter i{position:absolute;left:0;top:0;bottom:0;background:linear-gradient(90deg,#16a34a,#84cc16,#f59e0b);width:0;transition:width .12s}
.meter u{position:absolute;top:0;bottom:0;width:2px;background:#fff;left:0}
.big{font-size:20px;font-weight:700;font-variant-numeric:tabular-nums}
#hist{width:100%;height:44px;display:block}
aside{background:var(--p);border-left:1px solid var(--ln);display:grid;grid-template-rows:auto 1fr;min-height:0}
#tabs{display:grid;grid-template-columns:repeat(6,1fr);border-bottom:1px solid var(--ln)}
#tabs button{border:0;border-radius:0;background:transparent;padding:11px 2px;color:var(--mu);border-bottom:2px solid transparent;font-size:12.5px}
#tabs button.on{color:var(--tx);border-bottom-color:var(--ac)}
#panes{overflow:auto;padding:4px 14px 24px;scrollbar-width:thin;scrollbar-color:#2a2f37 transparent}
.pane{display:none}.pane.on{display:block}
.sec{margin:16px 0 8px;font-size:11px;letter-spacing:.6px;text-transform:uppercase;color:var(--mu);font-weight:600}
.row{padding:7px 0;border-bottom:1px solid #1d2127}
.row.na{display:none}.row.dis{opacity:.4}
.rl{display:flex;justify-content:space-between;margin-bottom:5px}.rl b{font-weight:600;font-variant-numeric:tabular-nums;color:#bfd6ff}
input[type=range]{width:100%;accent-color:var(--ac);margin:0}
.hint{color:var(--mu);font-size:12px;margin-top:3px}
label.tog{display:flex;align-items:center;justify-content:space-between;cursor:pointer;gap:10px}
label.tog input{display:none}
label.tog i{width:34px;height:19px;border-radius:10px;background:#2a2f37;position:relative;flex:none;transition:background .15s}
label.tog i::after{content:"";position:absolute;left:2px;top:2px;width:15px;height:15px;border-radius:50%;background:#c9cfd8;transition:transform .15s}
label.tog input:checked+i{background:var(--ac)}label.tog input:checked+i::after{transform:translateX(15px);background:#fff}
.seg{display:flex;border:1px solid var(--ln);border-radius:7px;overflow:hidden}
.seg button{flex:1;border:0;border-radius:0;border-right:1px solid var(--ln);background:var(--bg);padding:7px 4px}
.seg button:last-child{border-right:0}.seg button.on{background:var(--ac);color:#fff}
.btns{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.presets{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.presets button{text-align:left;padding:7px 9px}.presets button small{display:block;color:var(--mu);font-size:12px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;font-variant-numeric:tabular-nums}
.kv span{color:var(--mu)}.kv b{font-weight:500;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.field{margin:7px 0}.field label{display:block;color:var(--mu);font-size:12px;margin-bottom:3px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:8px}
#recGo{width:100%;padding:11px;font-size:14px;font-weight:600;margin-top:10px}
#recGo.on{background:var(--er);border-color:var(--er);color:#fff}
.prof{display:flex;align-items:center;gap:6px;padding:5px 0;border-bottom:1px solid #1d2127}.prof span{flex:1}
.prof button{padding:3px 8px;font-size:12px}
#toast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%) translateY(20px);opacity:0;background:#20252d;border:1px solid var(--ln);padding:8px 14px;border-radius:8px;transition:all .2s;pointer-events:none;z-index:9;max-width:70%}
#toast.on{opacity:1;transform:translateX(-50%)}
kbd{background:#222730;border:1px solid #333a45;border-bottom-width:2px;border-radius:4px;padding:0 5px;font-size:11px}
</style></head>
<body><div id="app">
<header>
  <div class="brand"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#3b82f6" stroke-width="2"><rect x="2" y="6" width="20" height="14" rx="3"/><circle cx="12" cy="13" r="4"/><path d="M8 6l1.5-2h5L16 6"/></svg>XIAO CAM <small>Studio</small></div>
  <div class="pill"><span class="dot" id="dot"></span><span id="stat">starting...</span></div>
  <div class="chips">
    <span class="chip">USB <b id="cFps">-</b> fps</span>
    <span class="chip"><b id="cRate">-</b></span>
    <span class="chip"><b id="cRes">-</b></span>
    <span class="chip"><b id="cKb">-</b> KB/frame</span>
    <span class="chip" id="cTempW">board <b id="cTemp">-</b></span>
  </div>
  <div class="sp"></div>
  <button id="snapTop" title="Save picture (S)">Snapshot</button>
  <button id="recBtnTop" title="Record (R)"><span class="rd"></span><span id="recTopTxt">REC</span></button>
  <button id="quitTop" title="Stop the studio">Quit</button>
</header>
<main>
  <div id="left">
    <div id="stage">
      <div id="box"><img id="v" alt=""><div id="ovl"></div></div>
      <div id="empty"><b>No picture yet</b><span id="emptyTxt">Waiting for the camera...</span></div>
      <div id="tools">
        <button data-t="grid" title="Rule of thirds (G)">Grid</button>
        <button data-t="cross" title="Center cross (C)">Cross</button>
        <button data-t="rot" title="Rotate the view">Rotate 0&deg;</button>
        <button data-t="mir" title="Mirror the view">Mirror</button>
        <button data-t="fit" title="Reset zoom (0)">Fit</button>
        <button data-t="pause" title="Freeze the view (P)">Freeze</button>
        <button data-t="full" title="Fullscreen (F)">Fullscreen</button>
      </div>
      <div id="zoomlbl">100%</div>
      <div id="recbadge"><span class="rd"></span><span id="recBadgeTxt">00:00</span></div>
    </div>
    <div id="banner"></div>
    <div id="bottom">
      <div class="card"><h4>Focus helper <button id="focReset" title="Reset peak">reset peak</button></h4>
        <div style="display:flex;align-items:center;gap:10px"><span class="big" id="focVal">-</span><div class="meter" style="flex:1"><i id="focBar"></i><u id="focPeak"></u></div></div>
        <div class="hint">Turn the lens until the bar reaches its peak (center of the picture).</div></div>
      <div class="card"><h4>Brightness histogram</h4><canvas id="hist" width="256" height="44"></canvas></div>
      <div class="card"><h4>Microphone <span id="micState">off</span></h4>
        <div class="meter"><i id="vu"></i></div>
        <div class="hint" id="micHint">Turn the mic on in Record tab.</div></div>
    </div>
  </div>
  <aside>
    <div id="tabs"></div>
    <div id="panes"></div>
  </aside>
</main>
</div>
<div id="toast"></div>
<script>
'use strict';
const $=s=>document.querySelector(s);
const el=(t,c,h)=>{const e=document.createElement(t);if(c)e.className=c;if(h!=null)e.innerHTML=h;return e};
let B=null,P=null;const pend={};const upd=[];
const SN=['96x96','QQVGA','128x128','QCIF','HQVGA','240x240','QVGA','320x320','CIF','HVGA','VGA','SVGA','XGA','HD','SXGA','UXGA','FHD','Portrait HD','Portrait 3MP','QXGA (3MP)','QHD','WQXGA','Portrait FHD','QSXGA','5MP'];
async function api(p){try{const r=await fetch(p,{cache:'no-store'});return await r.json()}catch(e){return{ok:false,err:String(e)}}}
function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('on');clearTimeout(toast.t);toast.t=setTimeout(()=>t.classList.remove('on'),2600)}
function bv(k){const p=pend[k];if(p&&Date.now()-p.t<2500)return p.v;return B?B[k]:undefined}
async function setv(k,v){pend[k]={v:+v,t:Date.now()};refresh();const r=await api('/api/set?k='+k+'&v='+v);if(!r.ok)toast('Not sent - camera not connected')}
function fmt(it,v){return it.fmt?it.fmt(+v):(it.min<0&&v>0?'+'+v:''+v)}

// ---------- control builders ----------
function rRange(it){const d=el('div','row');d.innerHTML=`<div class="rl"><span>${it.l}</span><b></b></div><input type="range" min="${it.min}" max="${it.max}" step="${it.step||1}">`+(it.hint?`<div class="hint">${it.hint}</div>`:'');
  const inp=d.querySelector('input'),val=d.querySelector('b');let tm;
  inp.oninput=()=>{val.textContent=fmt(it,inp.value);pend[it.k]={v:+inp.value,t:Date.now()};clearTimeout(tm);tm=setTimeout(()=>setv(it.k,inp.value),140)};
  d.upd=()=>{const v=bv(it.k);d.classList.toggle('na',v===undefined);if(v===undefined)return;const dis=!!(it.dis&&it.dis());d.classList.toggle('dis',dis);inp.disabled=dis;if(+inp.value!==v)inp.value=v;val.textContent=fmt(it,v)};return d}
function rTog(it){const d=el('label','row tog');d.innerHTML=`<span>${it.l}${it.hint?`<div class="hint">${it.hint}</div>`:''}</span><input type="checkbox"><i></i>`;
  const c=d.querySelector('input');c.onchange=()=>setv(it.k,c.checked?1:0);
  d.upd=()=>{const v=bv(it.k);d.classList.toggle('na',v===undefined);const dis=!!(it.dis&&it.dis());c.disabled=dis;d.classList.toggle('dis',dis);c.checked=!!v};return d}
function rSel(it){const d=el('div','row');d.innerHTML=`<div class="rl"><span>${it.l}</span></div><select></select>`+(it.hint?`<div class="hint">${it.hint}</div>`:'');
  const s=d.querySelector('select');let sig='';
  s.onchange=()=>setv(it.k,s.value);
  d.upd=()=>{const v=bv(it.k);d.classList.toggle('na',v===undefined);if(v===undefined)return;
    let opts=it.opts;if(it.t==='size')opts=(B&&B.sizes||[]).map((z,i)=>z[0]+' x '+z[1]+'  '+(SN[i]||''));
    const ns=JSON.stringify(opts);if(ns!==sig){sig=ns;s.innerHTML='';opts.forEach((o,i)=>{const op=el('option');op.value=it.vals?it.vals[i]:i;op.textContent=o;s.appendChild(op)})}
    const dis=!!(it.dis&&it.dis());s.disabled=dis;d.classList.toggle('dis',dis);if(document.activeElement!==s)s.value=v};return d}
function build(it){const d=it.t==='range'?rRange(it):it.t==='tog'?rTog(it):rSel(it);upd.push(d);return d}

// ---------- tabs ----------
const IMAGE=[
 {sec:'Quick presets'},{custom:presets},
 {sec:'Picture'},
 {k:'framesize',t:'size',l:'Resolution',hint:'Bigger = more detail but fewer fps over USB'},
 {k:'quality',t:'range',min:4,max:63,l:'JPEG quality',fmt:v=>v+(v<=8?'  (best)':v>=30?'  (low)':''),hint:'Lower number = better picture, bigger frames'},
 {k:'fps_limit',t:'range',min:0,max:60,l:'Frame rate limit',fmt:v=>v==0?'No limit':v+' fps'},
 {k:'brightness',t:'range',min:-2,max:2,l:'Brightness'},
 {k:'contrast',t:'range',min:-2,max:2,l:'Contrast'},
 {k:'saturation',t:'range',min:-2,max:2,l:'Saturation'},
 {k:'sharpness',t:'range',min:-2,max:2,l:'Sharpness',hint:'Not every sensor supports this'},
 {k:'effect',t:'sel',l:'Special effect',opts:['None','Negative','Black & white','Red tint','Green tint','Blue tint','Sepia']},
 {sec:'Orientation (on the camera)'},
 {k:'hmirror',t:'tog',l:'Mirror left / right'},
 {k:'vflip',t:'tog',l:'Flip upside down'},
];
const LIGHT=[
 {sec:'Exposure'},
 {k:'aec',t:'tog',l:'Auto exposure'},
 {k:'aec2',t:'tog',l:'Exposure DSP',hint:'Helps in low light'},
 {k:'ae_level',t:'range',min:-2,max:2,l:'Exposure compensation',dis:()=>!bv('aec')},
 {k:'aec_value',t:'range',min:0,max:1200,l:'Manual exposure time',dis:()=>!!bv('aec'),hint:'Only when auto exposure is off'},
 {sec:'Gain (ISO)'},
 {k:'agc',t:'tog',l:'Auto gain'},
 {k:'gainceiling',t:'sel',l:'Max auto gain',opts:['2x','4x','8x','16x','32x','64x','128x'],dis:()=>!bv('agc'),hint:'Higher = brighter in the dark, more noise'},
 {k:'agc_gain',t:'range',min:0,max:30,l:'Manual gain',fmt:v=>(v+1)+'x',dis:()=>!!bv('agc')},
 {sec:'Clock (advanced)'},
 {k:'xclk',t:'sel',l:'Sensor clock (XCLK)',opts:['8 MHz','10 MHz','16 MHz','20 MHz (default)','24 MHz'],vals:[8,10,16,20,24],hint:'Lower can fix stripes / flicker; higher can add fps'},
];
const COLOR=[
 {sec:'White balance'},
 {k:'awb',t:'tog',l:'Auto white balance'},
 {k:'awb_gain',t:'tog',l:'White balance gain'},
 {k:'wb_mode',t:'sel',l:'Light type',opts:['Auto','Sunny','Cloudy','Office','Home'],dis:()=>!bv('awb_gain')},
 {sec:'Corrections'},
 {k:'lenc',t:'tog',l:'Lens shading correction',hint:'Removes dark corners'},
 {k:'raw_gma',t:'tog',l:'Gamma correction'},
 {k:'bpc',t:'tog',l:'Black pixel fix'},
 {k:'wpc',t:'tog',l:'White pixel fix'},
 {k:'dcw',t:'tog',l:'Downscale (DCW)',hint:'Keep on for small resolutions'},
 {k:'denoise',t:'range',min:0,max:8,l:'Denoise'},
 {sec:'Test'},
 {k:'colorbar',t:'tog',l:'Color bars test pattern'},
];
const TABS=[['image','Image',IMAGE],['light','Exposure',LIGHT],['color','Color',COLOR],['rec','Record',recPane],['wifi','WiFi',wifiPane],['board','Board',boardPane]];
// ---------- presets + profiles ----------
const SENSOR_KEYS=['framesize','quality','fps_limit','brightness','contrast','saturation','sharpness','denoise','effect','awb','awb_gain','wb_mode','aec','aec2','ae_level','aec_value','agc','agc_gain','gainceiling','bpc','wpc','raw_gma','lenc','hmirror','vflip','dcw','xclk'];
async function applySet(o){for(const k of SENSOR_KEYS)if(k in o){pend[k]={v:+o[k],t:Date.now()};await api('/api/set?k='+k+'&v='+o[k])}refresh()}
function presets(p){const g=el('div','presets');
  const L=[['Fast','VGA, smooth video',{framesize:10,quality:12,fps_limit:0}],['Balanced','HD 1280x720',{framesize:13,quality:10,fps_limit:0}],
   ['Max detail','Full sensor, slow over USB',{framesize:-1,quality:8}],['Focus lens','HD, sharp, no denoise',{framesize:13,quality:6,denoise:0,sharpness:1}],
   ['Low light','More gain + DSP',{aec:1,aec2:1,ae_level:2,agc:1,gainceiling:5}],['Daylight','Normal exposure',{aec:1,aec2:0,ae_level:0,agc:1,gainceiling:1,awb:1}]];
  L.forEach(([n,d,o])=>{const b=el('button','',`${n}<small>${d}</small>`);b.onclick=()=>{const x=Object.assign({},o);if(x.framesize<0)x.framesize=B?B.max_size:15;applySet(x);toast('Preset: '+n)};g.appendChild(b)});p.appendChild(g)}
function profs(){try{return JSON.parse(localStorage.xprof||'{}')}catch(e){return{}}}
function drawProfs(){const box=$('#profList');box.innerHTML='';const P_=profs();const ks=Object.keys(P_);if(!ks.length)box.innerHTML='<div class="hint">No saved profiles yet.</div>';
  ks.forEach(k=>{const r=el('div','prof');r.appendChild(el('span','',k.replace(/</g,'&lt;')));const a=el('button','','Apply');a.onclick=()=>{applySet(P_[k]);toast('Profile: '+k)};const x=el('button','danger','Delete');x.onclick=()=>{delete P_[k];localStorage.xprof=JSON.stringify(P_);drawProfs()};r.append(a,x);box.appendChild(r)})}

// ---------- record pane ----------
let recMode='video';
function recPane(p){
  p.innerHTML=`<div class="sec">Record to this PC</div>
  <div class="seg" id="rMode"><button data-v="video" class="on">Video</button><button data-v="tl">Timelapse</button></div>
  <div id="rVid"><div class="two"><div class="field"><label>Frame rate</label><select id="rFps"><option value="0">Auto (live fps)</option><option>5</option><option>10</option><option>15</option><option>20</option><option>25</option><option>30</option></select></div>
   <div class="field"><label>Sound</label><select id="rAud"><option value="1">With microphone</option><option value="0">No sound</option></select></div></div></div>
  <div id="rTl" style="display:none"><div class="two"><div class="field"><label>One picture every (sec)</label><input type="number" id="rInt" value="5" min="0.2" step="0.5"></div>
   <div class="field"><label>Playback speed</label><select id="rPlay"><option>10</option><option>24</option><option selected>30</option><option>60</option></select></div></div>
   <div class="hint" id="tlCalc"></div></div>
  <button id="recGo" class="pri">Start recording</button>
  <div class="kv" id="recInfo" style="margin-top:10px"></div>
  <div class="hint" style="margin-top:6px">Saved as AVI (MJPEG). Plays in VLC, Windows Media Player and video editors. Changing resolution while recording starts a new part file.</div>
  <div class="btns"><button id="openVid">Open videos folder</button></div>
  <div class="sec">Pictures</div>
  <div class="btns" style="margin-top:0"><button class="pri" id="snapB">Take snapshot <kbd>S</kbd></button><button id="openPic">Open pictures folder</button></div>
  <div class="hint">Full camera resolution, exactly as the camera sent it.</div>
  <div class="sec">Microphone (on the camera board)</div><div id="micRow"></div>`;
  p.querySelector('#micRow').appendChild(build({k:'mic',t:'tog',l:'Microphone on',hint:'Needed for sound in videos. 16 kHz mono.'}));
  p.querySelectorAll('#rMode button').forEach(b=>b.onclick=()=>{recMode=b.dataset.v;p.querySelectorAll('#rMode button').forEach(x=>x.classList.toggle('on',x===b));$('#rVid').style.display=recMode==='video'?'':'none';$('#rTl').style.display=recMode==='tl'?'':'none';tlCalc()});
  const tlCalc=()=>{const i=+$('#rInt').value||1,pl=+$('#rPlay').value;$('#tlCalc').textContent=`1 hour of real time = ${(3600/i/pl).toFixed(1)} s of video (${(pl*i).toFixed(0)}x faster)`};
  p.querySelector('#rInt').oninput=tlCalc;p.querySelector('#rPlay').onchange=tlCalc;tlCalc();
  p.querySelector('#recGo').onclick=toggleRec;p.querySelector('#snapB').onclick=snap;
  p.querySelector('#openVid').onclick=()=>api('/api/open?d=videos');p.querySelector('#openPic').onclick=()=>api('/api/open?d=pictures');
}
async function toggleRec(){
  if(P&&P.rec){const r=await api('/api/rec/stop');toast(r.msg||'Stopped');refresh();return}
  if(!P||!P.live){toast('No picture coming - cannot record');return}
  let q;if(recMode==='tl')q=`tl=${+$('#rInt').value||5}&play=${$('#rPlay').value}`;else q=`fps=${$('#rFps').value}&audio=${$('#rAud').value}`;
  const r=await api('/api/rec/start?'+q);toast(r.ok?'Recording '+r.file:'Could not start: '+(r.err||''));refresh()}
async function snap(){const r=await api('/api/snap');if(r.ok){toast('Saved '+r.file.split('\\').pop());flash()}else toast('No picture yet')}
function flash(){const s=$('#stage');s.animate([{boxShadow:'inset 0 0 0 4px #fff'},{boxShadow:'inset 0 0 0 0 #fff'}],{duration:350})}

// ---------- wifi pane ----------
const TXP=[[8,'2 dBm (lowest)'],[20,'5 dBm'],[34,'8.5 dBm'],[44,'11 dBm'],[52,'13 dBm'],[60,'15 dBm'],[68,'17 dBm'],[78,'19.5 dBm (default)'],[84,'21 dBm (max)']];
function wifiPane(p){
  p.innerHTML=`<div class="sec">WiFi on the camera</div>
  <div class="seg" id="wMode"><button data-v="0">Off</button><button data-v="1">Own hotspot</button><button data-v="2">Join WiFi</button><button data-v="3">Both</button></div>
  <div class="hint" style="margin-top:6px">WiFi off saves power and heat. USB keeps working in every mode.</div>
  <div class="sec">Own hotspot</div>
  <div class="two"><div class="field"><label>Name (SSID)</label><input type="text" id="wApS" maxlength="32"></div><div class="field"><label>Password (8+ chars)</label><input type="text" id="wApP" maxlength="63"></div></div>
  <div class="field"><label>Channel</label><select id="wCh">${Array.from({length:13},(_,i)=>`<option>${i+1}</option>`).join('')}</select></div>
  <div class="sec">Join a WiFi network</div>
  <div class="two"><div class="field"><label>Network name</label><input type="text" id="wStS" maxlength="32"></div><div class="field"><label>Password</label><input type="password" id="wStP" maxlength="63"></div></div>
  <div class="field"><label>Transmit power</label><select id="wTx">${TXP.map(([v,l])=>`<option value="${v}">${l}</option>`).join('')}</select></div>
  <button class="pri" id="wApply" style="width:100%;margin-top:8px">Apply WiFi settings</button>
  <div class="sec">Status</div><div class="kv" id="wInfo"></div>
  <div class="hint" id="wHow" style="margin-top:8px"></div>`;
  p.querySelectorAll('#wMode button').forEach(b=>b.onclick=()=>setv('wifi',b.dataset.v));
  p.querySelector('#wTx').onchange=e=>setv('tx_power',e.target.value);
  p.querySelectorAll('input,select').forEach(i=>i.addEventListener('input',()=>i.dataset.dirty=1));
  p.querySelector('#wApply').onclick=async()=>{const ap=$('#wApP').value;if(ap&&ap.length<8){toast('Hotspot password must be 8+ characters (or empty)');return}
    const ss=$('#wApS').value.trim();if(!ss){toast('Hotspot name is empty');return}
    await api('/api/str?k=ap_ssid&v='+encodeURIComponent(ss));await api('/api/str?k=ap_pass&v='+encodeURIComponent(ap));
    await api('/api/str?k=sta_ssid&v='+encodeURIComponent($('#wStS').value.trim()));await api('/api/str?k=sta_pass&v='+encodeURIComponent($('#wStP').value));
    await api('/api/set?k=ap_ch&v='+$('#wCh').value);const r=await api('/api/cmd?c=wifi_apply');
    p.querySelectorAll('[data-dirty]').forEach(i=>delete i.dataset.dirty);toast(r.ok?'WiFi settings sent':'Not sent - camera not connected')};
}
const STA={'-1':'not used','0':'idle','1':'network not found','2':'scan done','3':'connected','4':'wrong password / failed','5':'connection lost','6':'disconnected','255':'off'};
function updWifi(){if(!B)return;const m=bv('wifi');document.querySelectorAll('#wMode button').forEach(b=>b.classList.toggle('on',+b.dataset.v===m));
  const fill=(id,v)=>{const e=$(id);if(e&&!e.dataset.dirty&&document.activeElement!==e&&v!==undefined)e.value=v};
  fill('#wApS',B.ap_ssid);fill('#wApP',B.ap_pass);fill('#wStS',B.sta_ssid);fill('#wStP',B.sta_pass);fill('#wCh',B.ap_ch);fill('#wTx',B.tx_power);
  const rows=[['Mode',['Off','Own hotspot','Join WiFi','Both'][m]||'-']];
  if(m&1)rows.push(['Hotspot',`${B.ap_ssid} @ ${B.ap_ip}`],['Phones connected',B.ap_clients]);
  if(m&2)rows.push(['Network',B.sta_ssid||'(none set)'],['State',STA[B.sta_status]||B.sta_status],['IP',B.sta_ip||'-'],['Signal',B.rssi?B.rssi+' dBm':'-']);
  rows.push(['WiFi viewers now',B.stream_clients]);
  $('#wInfo').innerHTML=rows.map(([a,b])=>`<span>${a}</span><b>${String(b).replace(/</g,'&lt;')}</b>`).join('');
  let how='';if(m&1)how+=`Phone: join WiFi <b>${B.ap_ssid}</b> and open <b>http://${B.ap_ip}</b>. `;if((m&2)&&B.sta_ip)how+=`Same network: open <b>http://${B.sta_ip}</b>.`;$('#wHow').innerHTML=how}

// ---------- board pane ----------
function boardPane(p){
  p.innerHTML=`<div class="sec">Camera board</div><div class="kv" id="bInfo"></div>
  <div class="sec">Options</div><div id="bOpts"></div>
  <div class="sec">Connection</div>
  <div class="two"><div class="field"><label>Port</label><select id="bPort"></select></div><div class="field"><label>&nbsp;</label><button id="bRe" style="width:100%">Reconnect</button></div></div>
  <div class="sec">My profiles (saved on this PC)</div>
  <div style="display:flex;gap:6px"><input type="text" id="profName" placeholder="Profile name, e.g. Night yard"><button id="profSave">Save</button></div>
  <div id="profList" style="margin-top:6px"></div>
  <div class="sec">Maintenance</div>
  <div class="btns" style="margin-top:0"><button id="bSave">Save settings to board now</button><button id="bBoot">Reboot camera</button><button class="danger" id="bDef">Reset camera to defaults</button></div>
  <div class="hint">Settings are saved on the camera automatically, so they stay after unplugging.</div>
  <div class="sec">Keyboard</div><div class="hint"><kbd>S</kbd> snapshot &nbsp; <kbd>R</kbd> record &nbsp; <kbd>F</kbd> fullscreen &nbsp; <kbd>G</kbd> grid &nbsp; <kbd>C</kbd> cross &nbsp; <kbd>P</kbd> freeze &nbsp; <kbd>0</kbd> reset zoom &nbsp; mouse wheel = zoom, drag = move</div>`;
  const o=p.querySelector('#bOpts');
  o.appendChild(build({k:'usb',t:'tog',l:'Send video over USB',hint:'Turn off to give WiFi viewers full speed'}));
  o.appendChild(build({k:'led',t:'tog',l:'Board LED (orange)'}));
  p.querySelector('#bSave').onclick=async()=>{const r=await api('/api/cmd?c=save');toast(r.ok?'Saved on the camera':'Not connected')};
  p.querySelector('#bBoot').onclick=async()=>{const r=await api('/api/cmd?c=reboot');toast(r.ok?'Camera restarting...':'Not connected')};
  const d=p.querySelector('#bDef');d.onclick=async()=>{if(!d.classList.contains('arm')){d.classList.add('arm');d.textContent='Click again to reset';setTimeout(()=>{d.classList.remove('arm');d.textContent='Reset camera to defaults'},3000);return}
    d.classList.remove('arm');d.textContent='Reset camera to defaults';const r=await api('/api/cmd?c=defaults');toast(r.ok?'Defaults restored, camera restarting...':'Not connected')};
  p.querySelector('#bRe').onclick=async()=>{const r=await api('/api/port?p='+$('#bPort').value);toast(r.ok?'Reconnecting...':'Bad port')};
  p.querySelector('#profSave').onclick=()=>{const n=$('#profName').value.trim();if(!n||!B){toast(B?'Type a name first':'Camera not connected');return}const o={};SENSOR_KEYS.forEach(k=>{if(B[k]!==undefined)o[k]=B[k]});const P_=profs();P_[n]=o;localStorage.xprof=JSON.stringify(P_);$('#profName').value='';drawProfs();toast('Profile saved: '+n)};
  drawProfs();loadPorts();
}
async function loadPorts(){const r=await api('/api/ports');const s=$('#bPort');if(!r.ok)return;const cur=P?(P.demo?'demo':P.want):'auto';
  s.innerHTML=`<option value="auto">Auto${r.auto?' ('+r.auto+')':''}</option>`+r.ports.map(x=>`<option>${x}</option>`).join('')+`<option value="demo">Demo (no camera)</option>`;s.value=cur}
const up=s=>{s=s|0;const h=s/3600|0,m=(s%3600)/60|0;return(h?h+'h ':'')+m+'m '+(s%60)+'s'};
function updBoard(){if(!B){$('#bInfo').innerHTML='<span>Status</span><b>not connected</b>';return}
  const rows=[['Sensor',B.sensor],['Firmware',B.fw],['Max resolution',B.sizes&&B.sizes.length?B.sizes[B.sizes.length-1].join(' x '):'-'],['Camera fps',B.cap_fps],['USB fps (board)',B.usb_fps],['Temperature',B.temp+' C'],['Free RAM',(B.heap/1024|0)+' KB'],['Free PSRAM',(B.psram/1048576).toFixed(1)+' MB'],['Uptime',up(B.uptime)],['Settings',B.saved?'saved on board':'saving...']];
  $('#bInfo').innerHTML=rows.map(([a,b])=>`<span>${a}</span><b>${String(b).replace(/</g,'&lt;')}</b>`).join('')}

// ---------- viewer: fit, zoom, pan, rotate ----------
const V={rot:0,mir:false,z:1,x:0,y:0,grid:false,cross:false,pause:false};
const img=$('#v'),box=$('#box'),stage=$('#stage');
function startStream(){img.src='/stream?'+Date.now()}
img.onload=layout;img.onerror=()=>setTimeout(startStream,1500);
function layout(){const w=img.naturalWidth||(P&&P.w)||4,h=img.naturalHeight||(P&&P.h)||3;const sw=stage.clientWidth,sh=stage.clientHeight;const rot=V.rot%180!==0;
  const s=Math.min(sw/(rot?h:w),sh/(rot?w:h));box.style.width=w*s+'px';box.style.height=h*s+'px';
  box.style.transform=`translate(-50%,-50%) translate(${V.x}px,${V.y}px) scale(${V.z}) rotate(${V.rot}deg) scaleX(${V.mir?-1:1})`;
  $('#zoomlbl').textContent=Math.round(V.z*100)+'%';$('#ovl').className=(V.grid?'grid3 ':'')+(V.cross?'cross':'')}
new ResizeObserver(layout).observe(stage);
stage.addEventListener('wheel',e=>{e.preventDefault();const f=e.deltaY<0?1.15:1/1.15;const nz=Math.min(10,Math.max(1,V.z*f));const r=stage.getBoundingClientRect();const cx=e.clientX-r.left-r.width/2,cy=e.clientY-r.top-r.height/2;V.x=cx-(cx-V.x)*nz/V.z;V.y=cy-(cy-V.y)*nz/V.z;V.z=nz;if(V.z===1){V.x=0;V.y=0}layout()},{passive:false});
let drag=null;stage.addEventListener('mousedown',e=>{if(e.target.closest('#tools'))return;drag={x:e.clientX-V.x,y:e.clientY-V.y};stage.classList.add('drag')});
addEventListener('mousemove',e=>{if(!drag)return;V.x=e.clientX-drag.x;V.y=e.clientY-drag.y;layout()});addEventListener('mouseup',()=>{drag=null;stage.classList.remove('drag')});
stage.addEventListener('dblclick',()=>{V.z=1;V.x=0;V.y=0;layout()});
function tool(t){const b=document.querySelector(`#tools [data-t="${t}"]`);
  if(t==='grid'){V.grid=!V.grid;b.classList.toggle('on',V.grid)}
  if(t==='cross'){V.cross=!V.cross;b.classList.toggle('on',V.cross)}
  if(t==='rot'){V.rot=(V.rot+90)%360;b.innerHTML='Rotate '+V.rot+'&deg;';b.classList.toggle('on',V.rot!==0)}
  if(t==='mir'){V.mir=!V.mir;b.classList.toggle('on',V.mir)}
  if(t==='fit'){V.z=1;V.x=0;V.y=0}
  if(t==='pause'){V.pause=!V.pause;b.classList.toggle('on',V.pause);b.textContent=V.pause?'Frozen':'Freeze';if(V.pause)img.src='/frame.jpg?'+Date.now();else startStream()}
  if(t==='full'){if(document.fullscreenElement)document.exitFullscreen();else stage.requestFullscreen()}
  localStorage.xview=JSON.stringify({rot:V.rot,mir:V.mir,grid:V.grid,cross:V.cross});layout()}
document.querySelectorAll('#tools button').forEach(b=>b.onclick=()=>tool(b.dataset.t));
try{const s=JSON.parse(localStorage.xview||'{}');if(s.grid)tool('grid');if(s.cross)tool('cross');if(s.mir)tool('mir');for(let i=0;i<(s.rot||0)/90;i++)tool('rot')}catch(e){}
addEventListener('keydown',e=>{if(e.target.matches('input,select,textarea'))return;const k=e.key.toLowerCase();
  if(k==='s')snap();else if(k==='r')toggleRec();else if(k==='f')tool('full');else if(k==='g')tool('grid');else if(k==='c')tool('cross');else if(k==='p')tool('pause');else if(k==='0')tool('fit')});

// ---------- focus helper + histogram (from /frame.jpg) ----------
const cv=document.createElement('canvas'),cx=cv.getContext('2d',{willReadFrequently:true});let fPeak=0,busy=false;
$('#focReset').onclick=()=>{fPeak=0};
async function analyse(){if(busy||!P||!P.live||document.hidden)return;busy=true;
  try{const bl=await (await fetch('/frame.jpg',{cache:'no-store'})).blob();const bm=await createImageBitmap(bl);
    const W=240,H=Math.round(W*bm.height/bm.width);cv.width=W;cv.height=H;cx.drawImage(bm,0,0,W,H);
    const d=cx.getImageData(0,0,W,H).data;const hist=new Array(256).fill(0);const g=new Float32Array(W*H);
    for(let i=0,j=0;i<d.length;i+=4,j++){const y=(d[i]*77+d[i+1]*150+d[i+2]*29)>>8;g[j]=y;hist[y]++}
    // focus: variance of laplacian in the middle third
    let s=0,s2=0,n=0;const x0=W/3|0,x1=2*W/3|0,y0=H/3|0,y1=2*H/3|0;
    for(let y=Math.max(1,y0);y<Math.min(H-1,y1);y++)for(let x=Math.max(1,x0);x<Math.min(W-1,x1);x++){const i=y*W+x;const L=4*g[i]-g[i-1]-g[i+1]-g[i-W]-g[i+W];s+=L;s2+=L*L;n++}
    const fv=n?Math.sqrt(s2/n-(s/n)**2):0;fPeak=Math.max(fPeak,fv);
    $('#focVal').textContent=fv.toFixed(1);const mx=Math.max(fPeak*1.15,1);$('#focBar').style.width=(fv/mx*100)+'%';$('#focPeak').style.left=(fPeak/mx*100)+'%';
    const hc=$('#hist'),h=hc.getContext('2d');h.clearRect(0,0,256,44);const m=Math.max(...hist.slice(1,255),1);h.fillStyle='#5b8def';
    for(let i=0;i<256;i++){const v=Math.min(44,hist[i]/m*44);h.fillRect(i,44-v,1,v)}
  }catch(e){}busy=false}
setInterval(analyse,350);

// ---------- state polling ----------
let lastLive=false;
function fmtRate(k){return k>=1000?(k/8000).toFixed(2)+' MB/s':(k/8).toFixed(0)+' KB/s'}
const mmss=s=>{s=s|0;return String(s/60|0).padStart(2,'0')+':'+String(s%60).padStart(2,'0')};
function refresh(){upd.forEach(d=>d.upd());updWifi();updBoard()}
async function poll(){const s=await api('/api/state');if(s&&s.pc){P=s.pc;B=s.board}else{P=null}
  const dot=$('#dot'),st=$('#stat');
  if(!P){dot.className='dot er';st.textContent='studio stopped - run the bat again'}
  else{dot.className='dot '+(P.live?'ok':P.connected?'wa':'er');st.textContent=P.demo?'Demo camera (no board)':(P.port?P.port+' - ':'')+P.status}
  if(P){$('#cFps').textContent=P.live?P.fps.toFixed(0):'0';$('#cRate').textContent=P.live?fmtRate(P.kbps):'-';$('#cRes').textContent=P.w?P.w+' x '+P.h:'-';$('#cKb').textContent=P.live?P.kb.toFixed(0):'-';
    $('#cTemp').textContent=B?B.temp.toFixed?B.temp.toFixed(0)+' C':B.temp+' C':'-';
    $('#empty').style.display=P.live||V.pause?'none':'flex';$('#emptyTxt').textContent=P.connected?(P.oldfw?'Old firmware on the camera.':'Connected - waiting for pictures...'):'Plug the XIAO in with a USB-C data cable.';
    if(P.live&&!lastLive&&!V.pause)startStream();lastLive=P.live;
    const ban=$('#banner');let bt='';
    if(P.oldfw)bt='The camera runs the OLD firmware - settings will not work. Close this, run the bat and choose 1 (flash).';
    else if(B&&!B.cam)bt='Camera problem: '+B.cam_err;
    ban.style.display=bt?'block':'none';ban.textContent=bt;
    const r=P.rec;$('#recBtnTop').classList.toggle('on',!!r);$('#recTopTxt').textContent=r?'STOP  '+mmss(r.secs):'REC';
    $('#recbadge').style.display=r?'flex':'none';if(r)$('#recBadgeTxt').textContent=(r.tl?'TIMELAPSE ':'REC ')+mmss(r.secs)+'  '+r.mb.toFixed(1)+' MB';
    const g=$('#recGo');g.classList.toggle('on',!!r);g.textContent=r?'Stop recording':'Start recording';
    $('#recInfo').innerHTML=r?[['File',r.file],['Time',mmss(r.secs)],['Frames',r.frames],['Size',r.mb.toFixed(1)+' MB'],['Frame rate',r.tl?'1 every '+r.tl+' s':r.fps+' fps'],['Sound',r.audio?'yes':'no']].map(([a,b])=>`<span>${a}</span><b>${b}</b>`).join(''):`<span>Folder</span><b title="${P.videos}">${P.videos}</b>`;
    const micOn=B&&B.mic;$('#micState').textContent=micOn?'on':'off';$('#vu').style.width=micOn?Math.min(100,P.level*130)+'%':'0';$('#micHint').textContent=micOn?'Level from the board microphone.':'Turn the mic on in the Record tab.';
    if(P.msg&&P.msg!==poll.msg){if(poll.msg!==undefined)toast(P.msg);poll.msg=P.msg}}
  refresh()}
TABS.forEach(([id,label,items],i)=>{
  const b=el('button',i?'':'on',label);b.onclick=()=>{document.querySelectorAll('#tabs button').forEach(x=>x.classList.remove('on'));document.querySelectorAll('.pane').forEach(x=>x.classList.remove('on'));b.classList.add('on');$('#p_'+id).classList.add('on');localStorage.xtab=id};b.dataset.id=id;$('#tabs').appendChild(b);
  const p=el('div','pane'+(i?'':' on'));p.id='p_'+id;$('#panes').appendChild(p);
  if(typeof items==='function')items(p);else items.forEach(it=>{if(it.sec)p.appendChild(el('div','sec',it.sec));else if(it.custom)it.custom(p);else p.appendChild(build(it))});
});
if(localStorage.xtab){const b=document.querySelector(`#tabs button[data-id="${localStorage.xtab}"]`);if(b)b.click()}

setInterval(poll,500);poll();
$('#snapTop').onclick=snap;$('#recBtnTop').onclick=toggleRec;
$('#quitTop').onclick=async()=>{if(!$('#quitTop').dataset.arm){$('#quitTop').dataset.arm=1;$('#quitTop').textContent='Click to confirm';setTimeout(()=>{delete $('#quitTop').dataset.arm;$('#quitTop').textContent='Quit'},3000);return}
  await api('/api/quit');document.body.innerHTML='<div style="display:flex;height:100%;align-items:center;justify-content:center;color:#8b94a1">Studio stopped. You can close this tab.</div>'};
</script></body></html>
'@

# ----------------------------------------------------------------------------
function Get-CamPort {
  $all = @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'")
  foreach ($d in $all) {
    if ($d.PNPDeviceID -match 'VID_303A|VID_2886' -and $d.Name -match '\((COM\d+)\)') { return $Matches[1] }
  }
  return $null
}

function Wait-CamPort {
  $p = Get-CamPort
  if ($p) { return $p }
  Warn "XIAO not found. Plug it in with a USB-C DATA cable (not a charge-only cable)."
  Warn "Still nothing? Hold the tiny BOOT button (B), plug in, then let go."
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 1
    $p = Get-CamPort
    if ($p) { Ok "found $p"; return $p }
  }
  $ports = @([IO.Ports.SerialPort]::GetPortNames())
  Warn "Ports on this PC: $($ports -join ', ')"
  $p = Read-Host "Type the COM port of the XIAO (e.g. COM5)"
  if (-not $p) { throw "no COM port" }
  return $p.Trim().ToUpper()
}

function Install-Tools {
  if (-not (Test-Path $Cli)) {
    Say "Downloading arduino-cli (first time only)"
    New-Item -ItemType Directory -Force $CliDir | Out-Null
    $zip = Join-Path $Data 'arduino-cli.zip'
    Invoke-WebRequest 'https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip' -OutFile $zip -UseBasicParsing
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Remove-Item $CliDir -Recurse -Force -ErrorAction SilentlyContinue
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $CliDir)
    Remove-Item $zip
    Ok "arduino-cli ready"
  }
  $installed = (& $Cli core list 2>$null | Out-String) -match 'esp32:esp32'
  if (-not $installed) {
    Say "Installing the ESP32 board package (first time only, ~1 GB, can take 5-15 min)"
    Run-Arduino core update-index
    Run-Arduino core install esp32:esp32
    Ok "ESP32 package ready"
  }
}

function Build-Firmware {
  Say "Building the camera firmware"
  New-Item -ItemType Directory -Force $SketchDir, $BuildDir | Out-Null
  $code = $Sketch.Replace('@@SSID@@', $Ssid).Replace('@@PASS@@', $Pass)
  [IO.File]::WriteAllText((Join-Path $SketchDir 'xiaocam2.ino'), $code)
  Run-Arduino compile --fqbn $Fqbn --output-dir $BuildDir $SketchDir
  Ok "build OK"
}

function Flash-Firmware {
  $port = Wait-CamPort
  Say "Flashing to $port (do not unplug)"
  & $Cli upload -p $port --fqbn $Fqbn --input-dir $BuildDir $SketchDir
  if ($LASTEXITCODE -ne 0) {
    Warn "Flash failed. Unplug the XIAO, HOLD the BOOT button (B), plug it back in, let go."
    Read-Host "Then press Enter to try again"
    $port = Wait-CamPort
    & $Cli upload -p $port --fqbn $Fqbn --input-dir $BuildDir $SketchDir
    if ($LASTEXITCODE -ne 0) { throw "flash failed twice" }
    Warn "If you used the BOOT button: press the RESET button (R) or unplug/replug once now."
  }
  Ok "flashed. Camera restarts..."
  Start-Sleep -Seconds 4
}

function Start-Studio([bool]$demo) {
  Say "Starting XIAO CAM Studio"
  if (-not ('XHub' -as [type])) { Add-Type -TypeDefinition $StudioCs -ReferencedAssemblies System.Drawing, System.Management }
  $hub = New-Object XHub
  $hub.Html = $Html
  $hub.PicturesDir = Join-Path $Root 'pictures'
  $hub.VideosDir = Join-Path $Root 'videos'
  $hub.Demo = $demo
  [XHub]::HookConsole($hub)
  $hub.StartAll()
  $web = New-Object XWeb $hub
  $port = $web.Start($StudioPort)
  $url = "http://127.0.0.1:$port/"
  Ok "Studio is running:  $url"
  Write-Host "   Videos:   $($hub.VideosDir)"
  Write-Host "   Pictures: $($hub.PicturesDir)"
  Write-Host ""
  Write-Host "   Keep this window open.  B = open the browser again,  Q = quit." -ForegroundColor White
  if (-not $env:XCAM_NOBROWSER) { Start-Process $url }
  $console = $true
  while ($true) {
    Start-Sleep -Milliseconds 250
    if (-not $console) { continue }
    try {
      if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        if ($k -eq 'Q') { break }
        if ($k -eq 'B') { Start-Process $url }
      }
    } catch { $console = $false }
  }
  Say "Stopping (finishing any recording)"
  $hub.Shutdown()
  Ok "bye"
}

# ----------------------------------------------------------------------------
try {
  $mode = $env:XCAM_MODE
  if ($mode -eq 'menu') {
    Write-Host ""
    Write-Host "  XIAO CAM Studio  (Seeed XIAO ESP32S3 Sense)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1 = Install + build + flash, then open the Studio   (first time / new version)"
    Write-Host "  2 = Open the Studio  (camera already flashed with this version)"
    Write-Host "  3 = Demo  (try the Studio without a camera)"
    Write-Host ""
    $c = Read-Host "Choose 1, 2 or 3 [2]"
    $mode = if ($c -eq '1') { 'flash' } elseif ($c -eq '3') { 'demo' } else { 'view' }
  }
  switch ($mode) {
    'build' { Install-Tools; Build-Firmware }
    'flash' { Install-Tools; Build-Firmware; Flash-Firmware; Start-Studio $false }
    'view'  { Start-Studio $false }
    'demo'  { Start-Studio $true }
    default { throw "unknown XCAM_MODE '$mode'" }
  }
} catch {
  Write-Host ""
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
