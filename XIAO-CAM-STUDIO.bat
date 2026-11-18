<# : XIAO-CAM Studio - one file: installs tools, builds, flashes, and opens the camera studio.
@echo off
setlocal
set "XCAM_SELF=%~f0"
if not "%~1"=="" set "XCAM_MODE=%~1"
if /i "%~2"=="nobrowser" set "XCAM_NOBROWSER=1"
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

$StudioVersion   = '2.3.0'      # bump on every release (Update button compares this)
$FirmwareVersion = '2.2'        # bump when the sketch below changes (Studio then asks to flash)
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

#define FW_VERSION "@@FWVER@@"
#define LED_PIN 21
#define MIC_RATE 16000

static Preferences prefs;
static I2SClass i2s;
static SemaphoreHandle_t lock;
static uint8_t* shared = nullptr;
static size_t sharedLen = 0, sharedCap = 0;
static uint32_t sharedTs = 0;            // capture time (board millis) of the frame in shared
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
static bool dirty = false, cfgNow = true, webStarted = false, autosave = true;
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
static void markDirty() { if (autosave) { dirty = true; dirtyAt = millis(); } }

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
    if (shared) {
      memcpy(shared, fb->buf, fb->len); sharedLen = fb->len; frameId++;
      uint32_t now = millis(), ts = (uint32_t)(fb->timestamp.tv_sec * 1000ULL + fb->timestamp.tv_usec / 1000);
      sharedTs = (ts <= now && now - ts < 2000) ? ts : now;
    }
    xSemaphoreGive(lock);
    esp_camera_fb_return(fb);
    capFrames++;
    vTaskDelay(1);
  }
}

// copy the newest frame (if newer than 'seen') into a private buffer
static size_t copyLatestTs(uint8_t*& buf, size_t& cap, uint32_t& seen, uint32_t* ts) {
  size_t n = 0;
  xSemaphoreTake(lock, portMAX_DELAY);
  if (frameId != seen && sharedLen) {
    if (sharedLen > cap) { free(buf); cap = sharedLen + 32768; buf = (uint8_t*)bigAlloc(cap); if (!buf) cap = 0; }
    if (buf) { memcpy(buf, shared, sharedLen); n = sharedLen; seen = frameId; if (ts) *ts = sharedTs; }
  }
  xSemaphoreGive(lock);
  return n;
}

static size_t copyLatest(uint8_t*& buf, size_t& cap, uint32_t& seen) { return copyLatestTs(buf, cap, seen, nullptr); }

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
  uint8_t* buf = nullptr; size_t cap = 0; uint32_t seen = 0, ts = 0; char hdr[160];
  streamClients++;
  for (;;) {
    size_t n = copyLatestTs(buf, cap, seen, &ts);
    if (!n) { vTaskDelay(5); continue; }
    int hl = snprintf(hdr, sizeof hdr, "\r\n--" BOUNDARY "\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\nX-Timestamp: %lu\r\n\r\n", (unsigned)n, (unsigned long)ts);
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
  if (!strcmp(k, "autosave")) autosave = v != 0;   // PC crazy mode turns this off: no flash wear
  else if (!strcmp(k, "fps_limit")) fpsLimit = constrain(v, 0, 60);
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
  else if (!strcmp(l, "ping")) {     // clock sync for WiFi delay measurement: echo the PC time + board millis
    char r[48]; int n = snprintf(r, sizeof r, "%s %lu", arg ? arg : "0", (unsigned long)millis());
    sendPacket("XPNG", (const uint8_t*)r, n); return;
  }
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
  public string Html = "", PicturesDir = "", VideosDir = "", Version = "0", FwExpected = "", SelfPath = "";
  public volatile string Status = "starting";
  public volatile string BoardJson = "";
  public volatile string LastMsg = "";
  public volatile bool Demo;
  public string WantPort = "auto";
  public IXSource Source;
  public XWeb Web;
  public XAvi Rec;
  public volatile float Level;
  public DateTime LastCfgAt = DateTime.MinValue, LastFrameAt = DateTime.MinValue;
  readonly object fl = new object(), sl = new object(), rl = new object();
  byte[] frame; long seq; int fw, fh; DateTime frameAt;
  public XCrazy Crazy;
  // monotonic PC clock (ms) + board clock offset (boardMs - pcMs) from USB pings
  static readonly Stopwatch clock = Stopwatch.StartNew();
  public static double NowMs { get { return clock.Elapsed.TotalMilliseconds; } }
  public double ClockOffset = double.NaN, ClockRtt = double.MaxValue;
  public delegate void FrameTap(byte[] jpg, int w, int h, double pcMs, double latencyMs);
  public volatile FrameTap Tap;
  public void ResetClock() { ClockOffset = double.NaN; ClockRtt = double.MaxValue; }
  public void OnPong(string s) {
    string[] p = s.Trim().Split(' ');
    double sent, board;
    if (p.Length < 2 || !double.TryParse(p[0], out sent) || !double.TryParse(p[1], out board)) return;
    double rtt = NowMs - sent;
    if (rtt >= 0 && rtt < ClockRtt) { ClockRtt = rtt; ClockOffset = board - (sent + rtt / 2); }
  }
  public bool IsLive { get { return (DateTime.Now - LastFrameAt).TotalSeconds < 2; } }
  public long TotalFrames { get { return Interlocked.Read(ref totalFrames); } }
  public byte[] LatestWithTime(out DateTime at, out int w, out int h) { lock (fl) { at = frameAt; w = fw; h = fh; return frame; } }
  int winFrames; long winBytes; double fps, kbps;
  float peak; int peakN;
  long totalFrames;
  volatile bool shutdown;

  public void StartAll(string crazyDefault) {
    Crazy = new XCrazy(this);
    Crazy.LoadDir(crazyDefault);
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
  public void OnFrame(byte[] jpg) { OnFrame(jpg, -1); }
  public void OnFrame(byte[] jpg, double latency) {
    int w, h;
    XJpeg.Size(jpg, out w, out h);
    DateTime now = DateTime.Now;
    lock (fl) { frame = jpg; seq++; fw = w; fh = h; frameAt = now; Monitor.PulseAll(fl); }
    LastFrameAt = now; Interlocked.Increment(ref totalFrames);
    lock (sl) { winFrames++; winBytes += jpg.Length; }
    FrameTap tap = Tap; if (tap != null) { try { tap(jpg, w, h, NowMs, latency); } catch { } }
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
    XCrazy cz = Crazy; if (cz != null) cz.StopAndWait(8000);
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
    sb.Append(",\"version\":\"").Append(Esc(Version)).Append("\",\"fwExpected\":\"").Append(Esc(FwExpected)).Append("\"");
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
    sb.Append("},\"crazy\":").Append(Crazy == null ? "null" : Crazy.StateJson());
    sb.Append(",\"board\":");
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
          (b1 == 'C' && b2 == 'F' && b3 == 'G') || (b1 == 'M' && b2 == 'S' && b3 == 'G') || (b1 == 'P' && b2 == 'N' && b3 == 'G')) return i;
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
          bool cam = k == 'C' && k2 == 'A', aud = k == 'A', cfg = k == 'C' && k2 == 'F', png = k == 'P';
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
          } else if (png) { hub.OnPong(Encoding.ASCII.GetString(acc, d, L)); pos = d + L; }
          else { hub.OnMsg("camera says: " + Encoding.ASCII.GetString(acc, d, L)); pos = d + L; }
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
  public void Start() {
    running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); hub.Status = "demo";
    try { wl = new TcpListener(IPAddress.Loopback, 8181); wl.Start(); var t = new Thread(WifiAccept); t.IsBackground = true; t.Start(); } catch { wl = null; }
  }
  public void Stop() { running = false; try { if (wl != null) wl.Stop(); } catch { } }
  // ---- simulated WiFi stream (like the board's :81/stream) ----
  const double BoardOffset = 123456;
  TcpListener wl; volatile int wifiClients; byte[] wFrame; double wTs; long wSeq; readonly object wlk = new object();
  void WifiAccept() {
    while (running) {
      TcpClient c; try { c = wl.AcceptTcpClient(); } catch { return; }
      var t = new Thread(delegate() { WifiClient(c); }); t.IsBackground = true; t.Start();
    }
  }
  void WifiClient(TcpClient c) {
    wifiClients++;
    var rnd = new Random();
    try {
      var ns = c.GetStream(); var buf = new byte[2048]; ns.Read(buf, 0, buf.Length);
      byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=xcamframe\r\n\r\n");
      ns.Write(h, 0, h.Length);
      long seen = -1;
      while (running) {
        byte[] f; double ts;
        lock (wlk) { if (wSeq == seen) { Monitor.Wait(wlk, 500); } if (wSeq == seen || wFrame == null) continue; f = wFrame; ts = wTs; seen = wSeq; }
        // network model: bandwidth grows with tx power, random stalls
        double kbs = 40 + 6 * Get("tx_power");                 // KB/s
        Thread.Sleep((int)(f.Length / 1024.0 / kbs * 1000));
        if (rnd.NextDouble() < 0.02 + (84 - Get("tx_power")) / 2000.0) Thread.Sleep(300 + rnd.Next(500));
        byte[] ph = Encoding.ASCII.GetBytes("\r\n--xcamframe\r\nContent-Type: image/jpeg\r\nContent-Length: " + f.Length + "\r\nX-Timestamp: " + (long)ts + "\r\n\r\n");
        ns.Write(ph, 0, ph.Length); ns.Write(f, 0, f.Length);
      }
    } catch { } finally { wifiClients--; try { c.Close(); } catch { } }
  }
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
      else if (p[0] == "ping" && p.Length >= 2) { hub.OnPong(p[1] + " " + ((long)(XHub.NowMs + BoardOffset)).ToString()); return true; }
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
      sb.Append(",\"ap_clients\":0,\"stream_clients\":").Append(wifiClients).Append(",\"stream_url\":\"http://127.0.0.1:8181/stream\"");
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
      int dfs = Get("framesize");
      double dfps = 25 * Math.Pow(480000.0 / (SW[dfs] * SH[dfs]), 0.7) * Math.Pow(Math.Max(4, Get("quality")) / 10.0, 0.3) * Get("xclk") / 20.0;
      dfps = Math.Max(2, Math.Min(25, dfps));
      if (fl > 0) dfps = Math.Min(dfps, fl);
      double period = 1.0 / dfps;
      if (t >= nextFrame && (Get("usb") == 1 || wifiClients > 0)) {
        nextFrame = t + period;
        try {
          byte[] fr = Render(t, jpg); fpsN++;
          lock (wlk) { wFrame = fr; wTs = XHub.NowMs + BoardOffset - 30; wSeq++; Monitor.PulseAll(wlk); }
          if (Get("usb") == 1) hub.OnFrame(fr);
        } catch (Exception e) { hub.OnMsg("demo: " + e.Message); }
      }
      Thread.Sleep(4);
    }
  }
  public byte[] Render(double t, ImageCodecInfo codec) {
    int fs = Get("framesize"); int w = SW[fs], h = SH[fs];
    int br = 0, sat = 0;
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
      // camera model: exposure, gain, noise, color
      double lum;
      if (Get("aec") == 1) lum = 0.45 + Get("ae_level") * 0.08 + (Get("aec2") == 1 ? 0.03 : 0);
      else lum = 0.55 * Get("aec_value") / 400.0 * (Get("agc") == 1 ? 1 + Get("gainceiling") * 0.3 : Get("agc_gain") + 1);
      lum += Get("brightness") * 0.05;
      float k = (float)(lum / 0.45), ct = 1 + Get("contrast") * 0.15f, st = Get("effect") == 2 ? 0 : 1 + Get("saturation") * 0.25f;
      float tr = 0, tbl = 0; int wm = Get("wb_mode");
      if (Get("awb") == 0) tbl = 0.08f; else if (Get("awb_gain") == 1) { if (wm == 1) tr = 0.05f; else if (wm == 2) tr = 0.08f; else if (wm == 3) tbl = 0.05f; else if (wm == 4) tr = 0.1f; }
      float lr = 0.299f, lg = 0.587f, lb = 0.114f;
      float a = (1 - st) * lr, b2 = (1 - st) * lg, c2 = (1 - st) * lb;
      var cm = new ColorMatrix(new float[][] {
        new float[] { (a + st) * k * ct, a * k * ct, a * k * ct, 0, 0 },
        new float[] { b2 * k * ct, (b2 + st) * k * ct, b2 * k * ct, 0, 0 },
        new float[] { c2 * k * ct, c2 * k * ct, (c2 + st) * k * ct, 0, 0 },
        new float[] { 0, 0, 0, 1, 0 },
        new float[] { 0.5f * (1 - ct) + tr, 0.5f * (1 - ct), 0.5f * (1 - ct) + tbl, 0, 1 } });
      using (var src = (Bitmap)bmp.Clone())
      using (var ia = new ImageAttributes()) {
        ia.SetColorMatrix(cm);
        g.DrawImage(src, new Rectangle(0, 0, w, h), 0, 0, w, h, GraphicsUnit.Pixel, ia);
      }
      double noise = (Get("agc") == 1 ? Get("gainceiling") * 0.02 : Get("agc_gain") * 0.015) * (1 - Get("denoise") / 10.0);
      if (noise > 0) {
        var rnd = new Random();
        int nd = (int)(noise * w * h / 6);
        using (var nb = new SolidBrush(Color.Black))
          for (int i = 0; i < nd; i++) { int gv = rnd.Next(256); nb.Color = Color.FromArgb(150, gv, gv, gv); g.FillRectangle(nb, rnd.Next(w), rnd.Next(h), 2, 2); }
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
  public XWeb(XHub h) { hub = h; h.Web = this; }
  public void Stop() { try { lst.Stop(); } catch { } }
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
      case "/api/crazy/start":
        try { hub.Crazy.Mode = G(q, "mode") == "wifi" ? "wifi" : "usb"; hub.Crazy.Quick = G(q, "quick") == "1"; hub.Crazy.MaxRounds = (int)D(q, "rounds", 0); hub.Crazy.Start(); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/stop": hub.Crazy.Stop(); Json(ns, Ok(true, null)); return;
      case "/api/crazy/folder":
        try {
          string d = G(q, "pick") == "1" ? XCrazy.PickFolder(hub.Crazy.OutDir) : G(q, "path");
          if (d == null) { Json(ns, Ok(false, "\"err\":\"cancelled\"")); return; }
          d = hub.Crazy.SetDir(d.Trim());
          Json(ns, Ok(true, "\"dir\":\"" + XHub.Esc(d) + "\""));
        } catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/open":
        try { Directory.CreateDirectory(hub.Crazy.OutDir); Process.Start("explorer.exe", "\"" + hub.Crazy.OutDir + "\""); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/rounds": Json(ns, hub.Crazy.RoundsJson()); return;
      case "/api/crazy/round": {
        string j = hub.Crazy.RoundJson(G(q, "id"));
        if (j == null) Send(ns, "404 Not Found", "application/json", Encoding.ASCII.GetBytes("{\"ok\":false}")); else Json(ns, j);
        return;
      }
      case "/api/crazy/stars": Json(ns, XCrazy.Js().Serialize(hub.Crazy.Stars())); return;
      case "/api/crazy/star":
        try { hub.Crazy.Star(G(q, "p"), G(q, "on") == "1"); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/crazy/file": {
        string f = hub.Crazy.SafeFile(G(q, "p"));
        if (f == null) Send(ns, "403 Forbidden", "text/plain", Encoding.ASCII.GetBytes("no"));
        else { string e = Path.GetExtension(f).ToLowerInvariant(); Send(ns, "200 OK", e == ".json" ? "application/json" : e == ".avi" ? "video/x-msvideo" : "image/jpeg", File.ReadAllBytes(f)); }
        return;
      }
      case "/api/update/check": Json(ns, XUpdate.Check(hub)); return;
      case "/api/update/apply":
        try { XUpdate.Apply(hub, G(q, "flash") == "1"); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/flash":
        if (hub.Demo) { Json(ns, Ok(false, "\"err\":\"not in demo mode\"")); return; }
        XUpdate.Relaunch(hub, "flash"); Json(ns, Ok(true, null)); return;
      case "/api/quit": {
        Json(ns, Ok(true, null));
        var t = new Thread(delegate() { Thread.Sleep(300); hub.Shutdown(); XUpdate.ExitNow(); });
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

// ============================================================================
//  Crazy mode: nonstop settings sweep -> organized, scored 5-second clips (USB or WiFi)
// ============================================================================
public class XStopEx : Exception { }

public class XShot {
  public string Group, Label, Phase, Mix;
  public Dictionary<string, int> Set = new Dictionary<string, int>();
  public List<string> From = new List<string>();
  public XShot(string phase, string group, string label) { Phase = phase; Group = group; Label = label; }
  public XShot S(string k, int v) { Set[k] = v; return this; }
}

public class XScores {
  public double Sharp, Noise, Mean, Clip, Cast, Kb, Fps;
  public double Kbps, Stalls, MaxGap, Jitter, LatMed = -1, LatP90 = -1, Dur; public int W, H, Frames;
  public Dictionary<string, object> ToDict() {
    var d = new Dictionary<string, object>();
    d["sharp"] = Math.Round(Sharp, 2); d["noise"] = Math.Round(Noise, 3); d["mean"] = Math.Round(Mean, 4);
    d["clip"] = Math.Round(Clip, 4); d["cast"] = Math.Round(Cast, 4); d["kb"] = Math.Round(Kb, 1);
    d["fps"] = Math.Round(Fps, 1); d["w"] = W; d["h"] = H;
    d["kbps"] = Math.Round(Kbps); d["stalls"] = Stalls; d["maxgap"] = Math.Round(MaxGap); d["jitter"] = Math.Round(Jitter, 1);
    d["lat"] = Math.Round(LatMed); d["lat90"] = Math.Round(LatP90); d["frames"] = Frames; d["dur"] = Math.Round(Dur, 2);
    return d;
  }
}

public static class XScore {
  // decodes the JPEG once: scores on a 640 px copy, plus a 320 px thumbnail
  public static XScores Compute(byte[] jpg, out byte[] thumb) {
    var s = new XScores(); s.Kb = jpg.Length / 1024.0;
    using (var ms = new MemoryStream(jpg))
    using (var src = Image.FromStream(ms)) {
      s.W = src.Width; s.H = src.Height;
      int W = Math.Min(640, src.Width), H = Math.Max(1, (int)Math.Round((double)src.Height * W / src.Width));
      using (var bmp = new Bitmap(W, H, PixelFormat.Format24bppRgb)) {
        using (var g = Graphics.FromImage(bmp)) { g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.DrawImage(src, 0, 0, W, H); }
        Analyse(bmp, s);
        int tw = Math.Min(320, W), th = Math.Max(1, H * tw / W);
        using (var tb = new Bitmap(tw, th, PixelFormat.Format24bppRgb)) {
          using (var g = Graphics.FromImage(tb)) { g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.DrawImage(bmp, 0, 0, tw, th); }
          using (var to = new MemoryStream()) { tb.Save(to, ImageFormat.Jpeg); thumb = to.ToArray(); }
        }
      }
    }
    return s;
  }

  static void Analyse(Bitmap bmp, XScores s) {
    int W = bmp.Width, H = bmp.Height;
    var data = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
    byte[] px = new byte[data.Stride * H];
    Marshal.Copy(data.Scan0, px, 0, px.Length);
    bmp.UnlockBits(data);
    float[] gy = new float[W * H];
    double sr = 0, sg = 0, sb = 0, sum = 0; long clip = 0;
    for (int y = 0; y < H; y++) {
      int row = y * data.Stride;
      for (int x = 0; x < W; x++) {
        int i = row + x * 3; byte b = px[i], g = px[i + 1], r = px[i + 2];
        float v = (r * 77 + g * 150 + b * 29) / 256f;
        gy[y * W + x] = v; sum += v; sr += r; sg += g; sb += b;
        if (v < 5 || v > 250) clip++;
      }
    }
    double n = (double)W * H;
    s.Mean = sum / n / 255.0; s.Clip = clip / n;
    s.Cast = (Math.Abs(sr - sg) + Math.Abs(sb - sg)) / n / 255.0;
    // sharpness: variance of the laplacian in the middle third
    double l1 = 0, l2 = 0; long c = 0;
    for (int y = Math.Max(1, H / 3); y < Math.Min(H - 1, 2 * H / 3); y++)
      for (int x = Math.Max(1, W / 3); x < Math.Min(W - 1, 2 * W / 3); x++) {
        int i = y * W + x; double L = 4 * gy[i] - gy[i - 1] - gy[i + 1] - gy[i - W] - gy[i + W];
        l1 += L; l2 += L * L; c++;
      }
    s.Sharp = c > 0 ? Math.Sqrt(Math.Max(0, l2 / c - (l1 / c) * (l1 / c))) : 0;
    // noise: mean |laplacian| in the flattest 20% of 16x16 blocks
    var blocks = new List<double>();
    for (int by = 1; by + 16 < H; by += 16)
      for (int bx = 1; bx + 16 < W; bx += 16) {
        double a = 0;
        for (int y = by; y < by + 16; y++)
          for (int x = bx; x < bx + 16; x++) { int i = y * W + x; a += Math.Abs(4 * gy[i] - gy[i - 1] - gy[i + 1] - gy[i - W] - gy[i + W]); }
        blocks.Add(a / 256.0);
      }
    blocks.Sort();
    int k = Math.Max(1, blocks.Count / 5); double ns = 0;
    for (int i = 0; i < k && i < blocks.Count; i++) ns += blocks[i];
    s.Noise = blocks.Count > 0 ? ns / k : 0;
  }

  // profile score over a set of shots (each metric normalized min-max inside the set)
  public static readonly string[] Profiles = { "daylight", "night", "indoor", "fast" };
  public static readonly string[] WifiProfiles = { "wifi_smooth", "wifi_delay", "wifi_stable", "wifi_picture" };
  public static double[] Rank(List<XScores> list, string profile) {
    int n = list.Count; var r = new double[n];
    if (n == 0) return r;
    Func<Func<XScores, double>, double[]> norm = f => {
      double mn = double.MaxValue, mx = double.MinValue;
      foreach (var x in list) { double v = f(x); mn = Math.Min(mn, v); mx = Math.Max(mx, v); }
      var o = new double[n];
      for (int i = 0; i < n; i++) o[i] = mx - mn < 1e-9 ? 0.5 : (f(list[i]) - mn) / (mx - mn);
      return o;
    };
    double[] sh = norm(x => x.Sharp), no = norm(x => x.Noise / Math.Max(x.Mean, 0.05)), cl = norm(x => x.Clip), ca = norm(x => x.Cast), fp = norm(x => x.Fps);
    double[] st = norm(x => x.Stalls), mg = norm(x => x.MaxGap), ji = norm(x => x.Jitter), la = norm(x => x.LatMed < 0 ? 1e6 : x.LatMed), l9 = norm(x => x.LatP90 < 0 ? 1e6 : x.LatP90);
    for (int i = 0; i < n; i++) {
      double ex = Math.Max(0, 1 - Math.Abs(list[i].Mean - 0.45) / 0.45);
      switch (profile) {
        case "daylight": r[i] = .35 * sh[i] + .25 * ex + .15 * (1 - ca[i]) + .15 * (1 - no[i]) + .10 * (1 - cl[i]); break;
        case "night":    r[i] = .35 * ex + .30 * (1 - no[i]) + .20 * sh[i] + .15 * (1 - cl[i]); break;
        case "indoor":   r[i] = .30 * ex + .25 * (1 - ca[i]) + .25 * sh[i] + .20 * (1 - no[i]); break;
        case "fast":     r[i] = .50 * fp[i] + .20 * sh[i] + .20 * ex + .10 * (1 - no[i]); break;
        case "wifi_smooth":  r[i] = .60 * fp[i] + .25 * (1 - st[i]) + .15 * (1 - mg[i]); break;
        case "wifi_delay":   r[i] = .60 * (1 - la[i]) + .20 * (1 - l9[i]) + .20 * fp[i]; break;
        case "wifi_stable":  r[i] = .45 * (1 - st[i]) + .35 * (1 - mg[i]) + .20 * (1 - ji[i]); break;
        default:             r[i] = (.55 * sh[i] + .25 * ex + .20 * (1 - no[i])) * Math.Min(1, list[i].Fps / 10) * (list[i].Stalls > 0 ? 0.7 : 1); break;   // wifi_picture
      }
      if (!profile.StartsWith("wifi") || profile == "wifi_picture") r[i] *= 0.4 + 0.6 * Math.Min(1, ex / 0.6);   // too dark / too bright is never "best"
    }
    return r;
  }
}

public class XCrazy {
  readonly XHub hub;
  public string OutDir = "";
  Thread th; volatile bool running;
  public volatile string Phase = "idle", Current = "", Err = "", Light = "", RoundName = "", LastShot = "";
  public int Round, ShotN, ShotTotal, RoundsDone;
  public bool Quick;                 // tests: tiny plan, short waits
  public int MaxRounds;              // 0 = nonstop
  public DateTime ShotStarted = DateTime.Now; public double AvgShotSec = 3.2;
  public string LastScoresJson = "null";
  Dictionary<string, int> baseSet, cur = new Dictionary<string, int>();
  List<int[]> sizes = new List<int[]>(); int maxSize;
  readonly object fileLock = new object();
  public static readonly string[] Keys = { "framesize", "quality", "xclk", "fps_limit", "brightness", "contrast", "saturation", "sharpness",
    "denoise", "effect", "aec", "aec_value", "aec2", "ae_level", "agc", "agc_gain", "gainceiling", "awb", "awb_gain", "wb_mode",
    "bpc", "wpc", "raw_gma", "lenc", "hmirror", "vflip", "dcw", "colorbar", "tx_power", "usb" };

  public XCrazy(XHub h) { hub = h; }
  public bool Running { get { return running; } }

  // ---------- settings store ----------
  static string StorePath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XiaoCam\\studio.json"); } }
  public void LoadDir(string def) {
    OutDir = def;
    try {
      if (File.Exists(StorePath)) {
        var d = Js().DeserializeObject(File.ReadAllText(StorePath)) as Dictionary<string, object>;
        if (d != null && d.ContainsKey("crazyDir") && Convert.ToString(d["crazyDir"]).Length > 0) OutDir = Convert.ToString(d["crazyDir"]);
      }
    } catch { }
  }
  public string SetDir(string dir) {
    if (running) throw new Exception("stop crazy mode first");
    if (string.IsNullOrEmpty(dir) || !Path.IsPathRooted(dir)) throw new Exception("use a full folder path, like C:\\XiaoCam\\crazy");
    dir = Path.GetFullPath(dir);
    Directory.CreateDirectory(dir);
    OutDir = dir;
    try {
      Directory.CreateDirectory(Path.GetDirectoryName(StorePath));
      var d = new Dictionary<string, object>(); d["crazyDir"] = dir;
      File.WriteAllText(StorePath, Js().Serialize(d));
    } catch { }
    return dir;
  }
  public static string PickFolder(string start) {
    string res = null;
    var t = new Thread(delegate() {
      try {
        using (var owner = new System.Windows.Forms.Form()) {
          owner.TopMost = true; owner.ShowInTaskbar = false; owner.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;
          owner.Width = 1; owner.Height = 1; owner.Opacity = 0; owner.Show(); owner.Activate();
          using (var d = new System.Windows.Forms.FolderBrowserDialog()) {
            d.Description = "Choose where crazy mode saves the photos";
            d.ShowNewFolderButton = true;
            if (!string.IsNullOrEmpty(start) && Directory.Exists(start)) d.SelectedPath = start;
            if (d.ShowDialog(owner) == System.Windows.Forms.DialogResult.OK) res = d.SelectedPath;
          }
        }
      } catch { }
    });
    t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join();
    return res;
  }
  public static System.Web.Script.Serialization.JavaScriptSerializer Js() {
    var j = new System.Web.Script.Serialization.JavaScriptSerializer(); j.MaxJsonLength = int.MaxValue; return j;
  }

  // ---------- plans ----------
  static string Sg(int v) { return v > 0 ? "+" + v : v.ToString(); }
  public static List<XShot> SweepPlan(int maxSize, List<int[]> sizes) {
    var p = new List<XShot>();
    int[] res = { 6, 8, 9, 10, 11, 12, 13, 14, 15, 16, 19 };
    foreach (int r in res) if (r <= maxSize && r < sizes.Count) p.Add(new XShot("sweep", "resolution", sizes[r][0] + "x" + sizes[r][1]).S("framesize", r));
    foreach (int q in new[] { 4, 6, 8, 10, 12, 15, 20, 30, 45, 63 }) p.Add(new XShot("sweep", "quality", "q" + q.ToString("00")).S("quality", q));
    foreach (string k in new[] { "brightness", "contrast", "saturation", "sharpness" })
      for (int v = -2; v <= 2; v++) p.Add(new XShot("sweep", k, Sg(v)).S(k, v));
    foreach (int v in new[] { 0, 2, 4, 6, 8 }) p.Add(new XShot("sweep", "denoise", v.ToString()).S("denoise", v));
    for (int v = -2; v <= 2; v++) p.Add(new XShot("sweep", "exposure-comp", "ev" + Sg(v)).S("aec", 1).S("ae_level", v));
    foreach (int v in new[] { 25, 50, 100, 200, 400, 700, 1000, 1200 }) p.Add(new XShot("sweep", "manual-exposure", "exp" + v.ToString("0000")).S("aec", 0).S("aec_value", v));
    for (int v = 0; v <= 1; v++) p.Add(new XShot("sweep", "exposure-dsp", v == 1 ? "on" : "off").S("aec", 1).S("aec2", v));
    string[] gc = { "2x", "4x", "8x", "16x", "32x", "64x", "128x" };
    for (int v = 0; v <= 6; v++) p.Add(new XShot("sweep", "gain-ceiling", (v + 1) + "-" + gc[v]).S("agc", 1).S("gainceiling", v));
    foreach (int v in new[] { 0, 3, 6, 10, 15, 20, 30 }) p.Add(new XShot("sweep", "manual-gain", "gain" + (v + 1).ToString("00") + "x").S("agc", 0).S("agc_gain", v));
    string[] wb = { "auto", "sunny", "cloudy", "office", "home" };
    for (int v = 0; v <= 4; v++) p.Add(new XShot("sweep", "white-balance", v + "-" + wb[v]).S("awb", 1).S("awb_gain", 1).S("wb_mode", v));
    p.Add(new XShot("sweep", "white-balance", "5-awb-off").S("awb", 0));
    string[][] tg = { new[] { "lens-correction", "lenc" }, new[] { "gamma", "raw_gma" }, new[] { "black-pixel-fix", "bpc" }, new[] { "white-pixel-fix", "wpc" }, new[] { "downscale-dcw", "dcw" } };
    foreach (var t in tg) for (int v = 0; v <= 1; v++) p.Add(new XShot("sweep", t[0], v == 1 ? "on" : "off").S(t[1], v));
    foreach (int v in new[] { 10, 16, 20, 24 }) p.Add(new XShot("sweep", "clock", v + "MHz").S("xclk", v));
    return p;
  }
  public static List<XShot> QuickPlan(int maxSize, List<int[]> sizes) {
    var p = new List<XShot>();
    p.Add(new XShot("sweep", "resolution", sizes[10][0] + "x" + sizes[10][1]).S("framesize", 10));
    p.Add(new XShot("sweep", "resolution", sizes[13][0] + "x" + sizes[13][1]).S("framesize", 13));
    p.Add(new XShot("sweep", "quality", "q06").S("quality", 6));
    p.Add(new XShot("sweep", "quality", "q30").S("quality", 30));
    p.Add(new XShot("sweep", "manual-exposure", "exp0050").S("aec", 0).S("aec_value", 50));
    p.Add(new XShot("sweep", "manual-exposure", "exp1000").S("aec", 0).S("aec_value", 1000));
    p.Add(new XShot("sweep", "brightness", "-2").S("brightness", -2));
    p.Add(new XShot("sweep", "brightness", "+2").S("brightness", 2));
    return p;
  }
  // WiFi: only what matters for streaming
  public static List<XShot> WifiPlan(int maxSize, List<int[]> sizes) {
    var p = new List<XShot>();
    int[] res = { 10, 11, 12, 13, 14, 15, 19 };
    foreach (int r in res) {
      if (r > maxSize || r >= sizes.Count) continue;
      foreach (int q in new[] { 6, 10, 15, 20, 30 })
        p.Add(new XShot("sweep", "res-quality", sizes[r][0] + "x" + sizes[r][1] + "_q" + q.ToString("00")).S("framesize", r).S("quality", q));
    }
    foreach (int f in new[] { 5, 10, 15, 20, 25 }) p.Add(new XShot("sweep", "fps-limit", f.ToString("00") + "fps").S("fps_limit", f));
    int[] tx = { 8, 20, 44, 60, 78, 84 }; string[] txn = { "02dBm", "05dBm", "11dBm", "15dBm", "19.5dBm", "21dBm" };
    for (int i = 0; i < tx.Length; i++) p.Add(new XShot("sweep", "wifi-power", txn[i]).S("tx_power", tx[i]));
    foreach (int v in new[] { 10, 16, 20, 24 }) p.Add(new XShot("sweep", "clock", v + "MHz").S("xclk", v));
    return p;
  }
  public static List<XShot> QuickWifiPlan(List<int[]> sizes) {
    var p = new List<XShot>();
    p.Add(new XShot("sweep", "res-quality", sizes[10][0] + "x" + sizes[10][1] + "_q10").S("framesize", 10).S("quality", 10));
    p.Add(new XShot("sweep", "res-quality", sizes[13][0] + "x" + sizes[13][1] + "_q10").S("framesize", 13).S("quality", 10));
    p.Add(new XShot("sweep", "wifi-power", "02dBm").S("tx_power", 8));
    p.Add(new XShot("sweep", "wifi-power", "21dBm").S("tx_power", 84));
    return p;
  }  // winners of the sweep, mixed: per profile, top 4 groups by score spread x top 2 values
  public static List<XShot> MixPlan(List<XShot> shots, List<XScores> scores, int groupsPer, int valuesPer, string[] profiles) {
    var outp = new List<XShot>(); var seen = new HashSet<string>();
    foreach (string prof in profiles) {
      double[] r = XScore.Rank(scores, prof);
      var byGroup = new Dictionary<string, List<int>>();
      for (int i = 0; i < shots.Count; i++) {
        if (!byGroup.ContainsKey(shots[i].Group)) byGroup[shots[i].Group] = new List<int>();
        byGroup[shots[i].Group].Add(i);
      }
      var spread = new List<KeyValuePair<string, double>>();
      foreach (var kv in byGroup) {
        if (kv.Value.Count < 2) continue;
        double mn = 1e9, mx = -1e9; foreach (int i in kv.Value) { mn = Math.Min(mn, r[i]); mx = Math.Max(mx, r[i]); }
        spread.Add(new KeyValuePair<string, double>(kv.Key, mx - mn));
      }
      spread.Sort((a, b) => b.Value.CompareTo(a.Value));
      var choices = new List<List<XShot>>();
      for (int g = 0; g < Math.Min(groupsPer, spread.Count); g++) {
        var idx = new List<int>(byGroup[spread[g].Key]);
        idx.Sort((a, b) => r[b].CompareTo(r[a]));
        var top = new List<XShot>();
        for (int j = 0; j < Math.Min(valuesPer, idx.Count); j++) top.Add(shots[idx[j]]);
        choices.Add(top);
      }
      int combos = 1; foreach (var c in choices) combos *= c.Count;
      int nn = 0;
      for (int m = 0; m < combos; m++) {
        var s = new XShot("mix", "mix-" + prof, ""); s.Mix = prof; int rest = m;
        foreach (var c in choices) {
          XShot pick = c[rest % c.Count]; rest /= c.Count;
          foreach (var kv in pick.Set) s.Set[kv.Key] = kv.Value;
          s.From.Add(pick.Group + "=" + pick.Label);
        }
        var keys = new List<string>(s.Set.Keys); keys.Sort();
        var sig = new StringBuilder(); foreach (string k in keys) sig.Append(k).Append('=').Append(s.Set[k]).Append(';');
        if (!seen.Add(sig.ToString())) continue;
        nn++; s.Label = prof + "_" + nn.ToString("00");
        outp.Add(s);
      }
    }
    return outp;
  }

  // ---------- run ----------
  public string Mode = "usb";          // "usb" or "wifi"
  public volatile string WifiStatus = "";
  public double ClipSec = 5;
  Dictionary<string, int> roundOver = new Dictionary<string, int>();
  XWifi wifi;

  public void Start() {
    if (running) return;
    if (string.IsNullOrEmpty(OutDir)) throw new Exception("choose an output folder first");
    if (ReadBoard() == null) throw new Exception("camera not connected over USB (or old firmware - flash with option 1)");
    if (Mode == "usb" && !hub.IsLive) throw new Exception("no picture coming from the camera");
    if (Mode == "wifi") { string u = StreamUrl(); if (!XWifi.Reachable(u, 2500)) throw new Exception("cannot reach the camera WiFi video at " + u + " - connect this PC to the XIAO-CAM WiFi first"); }
    Directory.CreateDirectory(OutDir);
    Err = ""; RoundsDone = 0; running = true; Phase = "starting";
    th = new Thread(Loop); th.IsBackground = true; th.Start();
  }
  public void Stop() { running = false; }
  public void StopAndWait(int ms) { running = false; Thread t = th; if (t != null) t.Join(ms); }

  public string StreamUrl() {
    try {
      var d = Js().DeserializeObject(hub.BoardJson) as Dictionary<string, object>;
      if (d != null && d.ContainsKey("stream_url")) return Convert.ToString(d["stream_url"]);
      string ip = d != null && d.ContainsKey("ap_ip") ? Convert.ToString(d["ap_ip"]) : "";
      return "http://" + (ip.Length > 0 ? ip : "192.168.4.1") + ":81/stream";
    } catch { return "http://192.168.4.1:81/stream"; }
  }

  Dictionary<string, int> ReadBoard() {
    string j = hub.BoardJson;
    if (string.IsNullOrEmpty(j) || j.IndexOf("\"framesize\"", StringComparison.Ordinal) < 0) return null;
    try {
      var d = Js().DeserializeObject(j) as Dictionary<string, object>;
      if (d == null) return null;
      var o = new Dictionary<string, int>();
      foreach (string k in Keys) if (d.ContainsKey(k)) o[k] = Convert.ToInt32(d[k]);
      if (d.ContainsKey("max_size")) maxSize = Convert.ToInt32(d["max_size"]);
      if (d.ContainsKey("sizes")) {
        sizes = new List<int[]>();
        foreach (object z in (object[])d["sizes"]) { var a = (object[])z; sizes.Add(new[] { Convert.ToInt32(a[0]), Convert.ToInt32(a[1]) }); }
      }
      return o;
    } catch { return null; }
  }

  void Wait(int ms) {
    var until = DateTime.Now.AddMilliseconds(ms);
    while (DateTime.Now < until) { if (!running) throw new XStopEx(); Thread.Sleep(50); }
  }

  void Loop() {
    try {
      baseSet = ReadBoard();
      cur = new Dictionary<string, int>(baseSet);
      hub.Cmd("set autosave 0");      // do not wear the board's flash with thousands of changes
      while (running) {
        RunRound();
        RoundsDone++;
        if (MaxRounds > 0 && RoundsDone >= MaxRounds) break;
      }
    } catch (XStopEx) {
    } catch (Exception e) { Err = e.Message; hub.OnMsg("crazy mode stopped: " + e.Message); }
    finally {
      Phase = "restoring your settings";
      StopWifi();
      roundOver.Clear();
      try { Apply(new Dictionary<string, int>(), false); } catch { }
      running = false;
      hub.Cmd("set autosave 1");
      Phase = "idle"; Current = "";
    }
  }

  // send only what differs from what the camera has now; base + round overrides + shot overrides
  bool Apply(Dictionary<string, int> over, bool forceAll) {
    var full = new Dictionary<string, int>(baseSet);
    foreach (var kv in roundOver) full[kv.Key] = kv.Value;
    foreach (var kv in over) full[kv.Key] = kv.Value;
    bool resChange = false;
    foreach (string k in Keys) {
      if (!full.ContainsKey(k)) continue;
      int v = full[k], c;
      if (!forceAll && cur.TryGetValue(k, out c) && c == v) continue;
      if (k == "framesize" || k == "xclk") resChange = true;
      hub.Cmd("set " + k + " " + v);
      cur[k] = v;
    }
    return resChange;
  }

  int[] Expect(Dictionary<string, int> over) {
    int fs = over.ContainsKey("framesize") ? over["framesize"] : baseSet["framesize"];
    return fs >= 0 && fs < sizes.Count ? sizes[fs] : null;
  }

  void StartWifi() {
    StopWifi();
    hub.ResetClock();
    for (int i = 0; i < 8; i++) { hub.Cmd("ping " + ((long)XHub.NowMs).ToString()); Wait(60); }
    wifi = new XWifi(hub, StreamUrl()); wifi.Start();
  }
  void StopWifi() { XWifi w = wifi; wifi = null; if (w != null) w.Stop(); }

  // one clip: apply, settle, record ClipSec seconds of what arrives (USB or WiFi)
  XClip Capture(Dictionary<string, int> over, double seconds) {
    for (int attempt = 0; ; attempt++) {
      int waited = 0;
      while (!hub.IsLive) {
        Phase = Mode == "wifi" ? "waiting for WiFi video" + (wifi != null && wifi.Status.Length > 0 ? " (" + wifi.Status + ")" : "") : "waiting for the camera (unplugged?)";
        Wait(500); waited += 500;
        if (Mode == "wifi" && waited % 10000 == 0) StartWifi();
      }
      Phase = "recording";
      bool big = Apply(over, attempt > 0);
      Wait(Quick ? 400 : (1200 + (big ? 1500 : 0)));
      var clip = new XClip(Expect(over));
      hub.Tap = clip.Add;
      try { Wait((int)(seconds * 1000)); } finally { hub.Tap = null; }
      clip.Done(seconds);
      if (clip.Count > 0) return clip;
      if (attempt >= 2) throw new Exception("no pictures from the camera");
      cur.Clear();                           // after a reconnect, send everything again
    }
  }

  void CheckDisk() {
    try {
      var di = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(OutDir)));
      if (di.AvailableFreeSpace < 5L * 1024 * 1024 * 1024) throw new Exception("the disk is almost full (less than 5 GB free) - crazy mode stopped");
    } catch (ArgumentException) { }
  }

  void RunRound() {
    ReadBoard();
    bool wf = Mode == "wifi";
    Round++; ShotN = 0;
    roundOver.Clear();
    if (wf) { roundOver["usb"] = 0; Apply(new Dictionary<string, int>(), false); StartWifi(); }
    try {
      Phase = "measuring the light"; Current = "light probe";
      var probe = new Dictionary<string, int>(); probe["aec"] = 0; probe["aec_value"] = 300; probe["agc"] = 0; probe["agc_gain"] = 0;
      XClip pc = Capture(probe, 1.0);
      byte[] pth; XScores ps = XScore.Compute(pc.Middle, out pth);
      Light = ps.Mean > 0.35 ? "day" : ps.Mean > 0.10 ? "dim" : "night";
      int num = NextRoundNumber();
      RoundName = DateTime.Now.ToString("yyyy-MM-dd_HHmm") + "_R" + num.ToString("000") + "_" + (wf ? "wifi_" : "") + Light;
      string rdir = Path.Combine(OutDir, RoundName);
      Directory.CreateDirectory(rdir);
      var round = new Dictionary<string, object>();
      round["round"] = num; round["name"] = RoundName; round["mode"] = Mode; round["light"] = Light; round["lightMean"] = Math.Round(ps.Mean, 4);
      round["started"] = DateTime.Now.ToString("s"); round["base"] = baseSet; round["sizes"] = sizes; round["maxSize"] = maxSize;
      round["clipSec"] = ClipSec;
      if (wf) { round["streamUrl"] = StreamUrl(); round["pcWifi"] = XWifi.PcSignal(); round["clockRttMs"] = double.IsNaN(hub.ClockOffset) ? -1 : Math.Round(hub.ClockRtt, 1); }
      var shotList = new List<object>(); round["shots"] = shotList;
      File.WriteAllBytes(Path.Combine(rdir, "0-light-probe.jpg"), pc.Middle);

      List<XShot> plan = wf ? (Quick ? QuickWifiPlan(sizes) : WifiPlan(maxSize, sizes)) : (Quick ? QuickPlan(maxSize, sizes) : SweepPlan(maxSize, sizes));
      ShotTotal = plan.Count + (Quick ? 4 : 32);
      var done = new List<XShot>(); var sc = new List<XScores>();
      foreach (XShot s in plan) { XScores r = Shoot(s, rdir, round, shotList); if (r != null) { done.Add(s); sc.Add(r); } }
      List<XShot> mix = MixPlan(done, sc, Quick ? 2 : (wf ? 3 : 4), 2, wf ? XScore.WifiProfiles : XScore.Profiles);
      ShotTotal = ShotN + mix.Count;
      foreach (XShot s in mix) Shoot(s, rdir, round, shotList);
      round["finished"] = DateTime.Now.ToString("s");
      WriteRound(rdir, round);
    } finally {
      if (wf) StopWifi();
    }
  }

  int NextRoundNumber() {
    int mx = 0;
    foreach (string d in Directory.GetDirectories(OutDir)) {
      var m = Regex.Match(Path.GetFileName(d), "_R(\\d{3,})_");
      if (m.Success) mx = Math.Max(mx, int.Parse(m.Groups[1].Value));
    }
    return mx + 1;
  }

  static string Safe(string s) { return Regex.Replace(s, "[^A-Za-z0-9_+\\-.]", "_"); }

  XScores Shoot(XShot s, string rdir, Dictionary<string, object> round, List<object> shotList) {
    CheckDisk();
    ShotN++; Current = s.Group + " = " + s.Label; ShotStarted = DateTime.Now;
    XClip clip = Capture(s.Set, Quick ? 1.5 : ClipSec);
    byte[] thumb; XScores r = XScore.Compute(clip.Middle, out thumb);
    clip.FillStats(r);
    string sub = s.Phase == "mix" ? "2-mix" : "1-sweep\\" + Safe(s.Group);
    string dir = Path.Combine(rdir, sub), tdir = Path.Combine(dir, "thumbs");
    Directory.CreateDirectory(tdir);
    string name = Safe(s.Label);
    var index = clip.WriteAvi(Path.Combine(dir, name + ".avi"));
    File.WriteAllText(Path.Combine(dir, name + ".json"), Js().Serialize(index));
    File.WriteAllBytes(Path.Combine(tdir, name + ".jpg"), thumb);
    // what the camera really took
    var now = ReadBoard() ?? new Dictionary<string, int>();
    var full = new Dictionary<string, int>(baseSet); foreach (var kv in roundOver) full[kv.Key] = kv.Value; foreach (var kv in s.Set) full[kv.Key] = kv.Value;
    var notApplied = new List<string>();
    foreach (var kv in s.Set) { int v; if (now.TryGetValue(kv.Key, out v) && v != kv.Value) notApplied.Add(kv.Key); }
    string rel = RoundName + "/" + sub.Replace('\\', '/') + "/" + name;
    var d = new Dictionary<string, object>();
    d["file"] = rel + ".avi"; d["index"] = rel + ".json"; d["thumb"] = RoundName + "/" + sub.Replace('\\', '/') + "/thumbs/" + name + ".jpg";
    d["mode"] = Mode; d["phase"] = s.Phase; d["group"] = s.Group; d["label"] = s.Label; d["changed"] = s.Set; d["set"] = full;
    if (s.Mix != null) { d["mix"] = s.Mix; d["from"] = s.From; }
    d["notApplied"] = notApplied; d["scores"] = r.ToDict(); d["time"] = DateTime.Now.ToString("s");
    shotList.Add(d);
    WriteRound(rdir, round);
    LastShot = d["thumb"].ToString(); LastScoresJson = Js().Serialize(r.ToDict());
    double took = (DateTime.Now - ShotStarted).TotalSeconds;
    AvgShotSec = AvgShotSec * 0.8 + took * 0.2;
    return r;
  }

  void WriteRound(string rdir, Dictionary<string, object> round) {
    lock (fileLock) {
      string p = Path.Combine(rdir, "round.json"), tmp = p + ".tmp";
      File.WriteAllText(tmp, Js().Serialize(round));
      if (File.Exists(p)) File.Delete(p);
      File.Move(tmp, p);
    }
  }
  // ---------- library for Compare ----------
  public string RoundsJson() {
    var list = new List<object>();
    if (Directory.Exists(OutDir)) {
      var dirs = Directory.GetDirectories(OutDir); Array.Sort(dirs);
      foreach (string d in dirs) {
        if (File.Exists(Path.Combine(d, "round.json"))) list.Add(Path.GetFileName(d));
      }
    }
    var o = new Dictionary<string, object>(); o["ok"] = true; o["dir"] = OutDir; o["rounds"] = list;
    return Js().Serialize(o);
  }
  public string RoundJson(string id) {
    if (!Regex.IsMatch(id ?? "", "^[A-Za-z0-9_\\-]+$")) return null;
    string p = Path.Combine(OutDir, id, "round.json");
    lock (fileLock) { return File.Exists(p) ? File.ReadAllText(p) : null; }
  }
  // only files inside the output folder
  public string SafeFile(string rel) {
    if (string.IsNullOrEmpty(rel) || string.IsNullOrEmpty(OutDir)) return null;
    string root = Path.GetFullPath(OutDir).TrimEnd('\\') + "\\";
    string full;
    try { full = Path.GetFullPath(Path.Combine(root, rel.Replace('/', '\\'))); } catch { return null; }
    if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return null;
    string ext = Path.GetExtension(full).ToLowerInvariant();
    if (ext != ".jpg" && ext != ".avi" && ext != ".json") return null;
    return File.Exists(full) ? full : null;
  }
  string StarsPath { get { return Path.Combine(OutDir, "stars.json"); } }
  public List<string> Stars() {
    try { if (File.Exists(StarsPath)) { var a = Js().DeserializeObject(File.ReadAllText(StarsPath)) as object[]; var l = new List<string>(); if (a != null) foreach (object x in a) l.Add(Convert.ToString(x)); return l; } } catch { }
    return new List<string>();
  }
  public void Star(string rel, bool on) {
    lock (fileLock) {
      var s = Stars(); s.Remove(rel); if (on) s.Add(rel);
      File.WriteAllText(StarsPath, Js().Serialize(s));
    }
  }

  public string StateJson() {
    var o = new Dictionary<string, object>();
    o["running"] = running; o["phase"] = Phase; o["current"] = Current; o["err"] = Err; o["dir"] = OutDir;
    o["round"] = RoundName; o["light"] = Light; o["shot"] = ShotN; o["total"] = ShotTotal; o["roundsDone"] = RoundsDone;
    o["eta"] = running ? Math.Round(Math.Max(0, ShotTotal - ShotN) * AvgShotSec) : 0;
    o["last"] = LastShot; o["mode"] = Mode; o["streamUrl"] = StreamUrl();
    XWifi w = wifi; o["wifi"] = w == null ? "" : w.Status;
    return Js().Serialize(o).TrimEnd('}') + ",\"scores\":" + LastScoresJson + "}";
  }
}

// ============================================================================
//  5-second clip: frames with their real arrival time -> AVI + index + stats
// ============================================================================
public class XClip {
  readonly object l = new object();
  readonly int[] want;
  public readonly List<byte[]> Jpgs = new List<byte[]>();
  public readonly List<double> T = new List<double>(), Lat = new List<double>();
  double t0 = -1, dur;
  bool open = true;
  public XClip(int[] wantSize) { want = wantSize; }
  public int Count { get { lock (l) return Jpgs.Count; } }
  public void Add(byte[] jpg, int w, int h, double pcMs, double lat) {
    lock (l) {
      if (!open) return;
      if (t0 < 0) t0 = pcMs;
      if (want != null && (w != want[0] || h != want[1])) return;   // old size still in flight
      Jpgs.Add(jpg); T.Add(pcMs); Lat.Add(lat);
    }
  }
  public void Done(double seconds) { lock (l) { open = false; dur = seconds; } }
  public byte[] Middle { get { lock (l) return Jpgs.Count == 0 ? null : Jpgs[Jpgs.Count / 2]; } }

  static double Pct(List<double> v, double p) {
    if (v.Count == 0) return -1;
    var s = new List<double>(v); s.Sort();
    return s[Math.Min(s.Count - 1, (int)Math.Floor(p * (s.Count - 1) + 0.5))];
  }
  public void FillStats(XScores r) {
    lock (l) {
      int n = Jpgs.Count; r.Frames = n; r.Dur = dur;
      long bytes = 0; foreach (var j in Jpgs) bytes += j.Length;
      r.Fps = dur > 0 ? n / dur : 0;
      r.Kbps = dur > 0 ? bytes / 1024.0 / dur : 0;
      var gaps = new List<double>();
      for (int i = 1; i < n; i++) gaps.Add(T[i] - T[i - 1]);
      double med = gaps.Count > 0 ? Pct(gaps, 0.5) : dur * 1000;
      double thr = Math.Max(3 * med, 250);
      int stalls = 0; double mg = 0, s1 = 0, s2 = 0;
      foreach (double g in gaps) { if (g > thr) stalls++; mg = Math.Max(mg, g); s1 += g; s2 += g * g; }
      if (n < 2) { stalls = 1; mg = dur * 1000; }
      r.Stalls = stalls; r.MaxGap = mg;
      r.Jitter = gaps.Count > 1 ? Math.Sqrt(Math.Max(0, s2 / gaps.Count - (s1 / gaps.Count) * (s1 / gaps.Count))) : 0;
      var lat = new List<double>(); foreach (double x in Lat) if (x >= 0 && x < 10000) lat.Add(x);
      r.LatMed = lat.Count > 0 ? Pct(lat, 0.5) : -1; r.LatP90 = lat.Count > 0 ? Pct(lat, 0.9) : -1;
    }
  }

  // AVI MJPEG at a nominal 30 fps; empty chunks keep the real timing (freezes stay visible)
  public Dictionary<string, object> WriteAvi(string path) {
    lock (l) {
      const int F = 30;
      int n = Jpgs.Count;
      int W = 0, H = 0; if (n > 0) XJpeg.Size(Jpgs[0], out W, out H);
      double start = n > 0 ? T[0] : 0;
      var frames = new List<object>();
      using (var f = new FileStream(path, FileMode.Create, FileAccess.ReadWrite))
      using (var w = new BinaryWriter(f)) {
        Action<string> fcc = s => { w.Write((byte)s[0]); w.Write((byte)s[1]); w.Write((byte)s[2]); w.Write((byte)s[3]); };
        Action<long, uint> at = (pos, v) => { long e = f.Position; f.Seek(pos, SeekOrigin.Begin); w.Write(v); f.Seek(e, SeekOrigin.Begin); };
        fcc("RIFF"); w.Write(0u); fcc("AVI ");
        fcc("LIST"); long hdrl = f.Position; w.Write(0u); fcc("hdrl");
        fcc("avih"); w.Write(56u); w.Write((uint)(1000000 / F)); w.Write(0u); w.Write(0u); w.Write(0x10u);
        long totPos = f.Position; w.Write(0u); w.Write(0u); w.Write(1u); w.Write(1u << 20);
        w.Write((uint)W); w.Write((uint)H); w.Write(0u); w.Write(0u); w.Write(0u); w.Write(0u);
        fcc("LIST"); long strl = f.Position; w.Write(0u); fcc("strl");
        fcc("strh"); w.Write(56u); fcc("vids"); fcc("MJPG"); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
        w.Write(1u); w.Write((uint)F); w.Write(0u); long lenPos = f.Position; w.Write(0u);
        w.Write(1u << 20); w.Write(0xFFFFFFFFu); w.Write(0u); w.Write((short)0); w.Write((short)0); w.Write((short)W); w.Write((short)H);
        fcc("strf"); w.Write(40u); w.Write(40u); w.Write(W); w.Write(H); w.Write((ushort)1); w.Write((ushort)24); fcc("MJPG");
        w.Write((uint)(W * H * 3)); w.Write(0); w.Write(0); w.Write(0u); w.Write(0u);
        at(strl, (uint)(f.Position - strl - 4)); at(hdrl, (uint)(f.Position - hdrl - 4));
        fcc("LIST"); long movi = f.Position; w.Write(0u); long moviData = f.Position; fcc("movi");
        var idx = new List<uint>(); int slot = -1;
        Action<byte[]> chunk = d => {
          uint rel = (uint)(f.Position - moviData); int len = d == null ? 0 : d.Length;
          fcc("00dc"); w.Write((uint)len); if (len > 0) { w.Write(d); if ((len & 1) == 1) w.Write((byte)0); }
          idx.Add(0x63643030u); idx.Add(len > 0 ? 0x10u : 0u); idx.Add(rel); idx.Add((uint)len);
        };
        for (int i = 0; i < n; i++) {
          int s = (int)Math.Round((T[i] - start) / 1000.0 * F);
          if (s <= slot) continue;                       // two frames in one 1/30 s: keep the first
          while (slot < s - 1) { chunk(null); slot++; }  // freeze: repeat the previous frame
          long dataOff = f.Position + 8;
          chunk(Jpgs[i]); slot++;
          frames.Add(new object[] { Math.Round(T[i] - start, 1), dataOff, Jpgs[i].Length, Math.Round(Lat[i]) });
        }
        long endSlots = (long)Math.Round(dur * F);
        while (slot < endSlots - 1 && slot >= 0) { chunk(null); slot++; }
        at(movi, (uint)(f.Position - movi - 4));
        fcc("idx1"); w.Write((uint)(idx.Count * 4)); foreach (uint u in idx) w.Write(u);
        at(4, (uint)(f.Position - 8)); at(totPos, (uint)(slot + 1)); at(lenPos, (uint)(slot + 1));
      }
      var o = new Dictionary<string, object>();
      o["w"] = W; o["h"] = H; o["dur"] = Math.Round(dur * 1000); o["frames"] = frames;   // [t ms, byte offset in the avi, length, latency]
      return o;
    }
  }
}

// ============================================================================
//  WiFi video reader: the camera's :81/stream, exactly as a phone would get it
// ============================================================================
public class XWifi {
  readonly XHub hub; readonly string url; Thread th; volatile bool run; WebResponse resp;
  public volatile string Status = "";
  public long Frames;
  public XWifi(XHub h, string u) { hub = h; url = u; }
  public void Start() { run = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { run = false; try { if (resp != null) resp.Close(); } catch { } }

  public static bool Reachable(string u, int ms) {
    try {
      var uri = new Uri(u);
      using (var c = new TcpClient()) { var ar = c.BeginConnect(uri.Host, uri.Port, null, null); bool ok = ar.AsyncWaitHandle.WaitOne(ms) && c.Connected; return ok; }
    } catch { return false; }
  }
  // this PC's WiFi signal (netsh), for the round notes
  public static string PcSignal() {
    try {
      var psi = new ProcessStartInfo("netsh", "wlan show interfaces"); psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
      using (var p = Process.Start(psi)) {
        string o = p.StandardOutput.ReadToEnd(); p.WaitForExit(3000);
        var ss = Regex.Match(o, @"^\s*SSID\s*:\s*(.+)$", RegexOptions.Multiline); var sg = Regex.Match(o, @"^\s*Signal\s*:\s*(\d+)%", RegexOptions.Multiline);
        return (ss.Success ? ss.Groups[1].Value.Trim() : "?") + " " + (sg.Success ? sg.Groups[1].Value + "%" : "");
      }
    } catch { return ""; }
  }

  static string ReadLine(Stream s) {
    var sb = new StringBuilder(); int b;
    while ((b = s.ReadByte()) >= 0) { if (b == '\n') break; if (b != '\r') sb.Append((char)b); if (sb.Length > 400) break; }
    if (b < 0 && sb.Length == 0) throw new IOException("stream ended");
    return sb.ToString();
  }

  void Loop() {
    while (run) {
      try {
        var rq = (HttpWebRequest)WebRequest.Create(url);
        rq.Timeout = 4000; rq.ReadWriteTimeout = 3000; rq.KeepAlive = false; rq.Proxy = null;
        resp = rq.GetResponse();
        using (var bs = new BufferedStream(resp.GetResponseStream(), 65536)) {
          Status = "connected";
          int len = -1; double ts = -1;
          while (run) {
            string line = ReadLine(bs);
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) int.TryParse(line.Substring(15).Trim(), out len);
            else if (line.StartsWith("X-Timestamp:", StringComparison.OrdinalIgnoreCase)) double.TryParse(line.Substring(12).Trim(), out ts);
            else if (line.Length == 0 && len > 0) {
              var jpg = new byte[len]; int got = 0;
              while (got < len) { int r = bs.Read(jpg, got, len - got); if (r <= 0) throw new IOException("stream ended"); got += r; }
              double now = XHub.NowMs, off = hub.ClockOffset;
              double lat = (ts >= 0 && !double.IsNaN(off)) ? now - (ts - off) : -1;
              if (jpg.Length > 2 && jpg[0] == 0xFF && jpg[1] == 0xD8) { Frames++; hub.OnFrame(jpg, lat); }
              len = -1; ts = -1;
            }
          }
        }
      } catch (Exception e) {
        if (!run) break;
        Status = "reconnecting (" + e.Message + ")";
        Thread.Sleep(400);
      } finally { try { if (resp != null) resp.Close(); } catch { } }
    }
    Status = "";
  }
}

// ============================================================================
//  Updates from GitHub (public repo) + restart / re-flash from the Studio
// ============================================================================
public static class XUpdate {
  public const string Repo = "MikeyM777/xiao-cam";
  static string Raw(string f) { return "https://raw.githubusercontent.com/" + Repo + "/main/" + f + "?nocache=" + DateTime.UtcNow.Ticks; }
  // GitHub API first (always fresh), raw CDN as fallback
  static byte[] Fetch(string file) {
    try {
      using (var w = Client()) { w.Headers["Accept"] = "application/vnd.github.raw"; return w.DownloadData("https://api.github.com/repos/" + Repo + "/contents/" + file + "?ref=main"); }
    } catch { using (var w = Client()) return w.DownloadData(Raw(file)); }
  }
  static WebClient Client() {
    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
    var w = new WebClient(); w.Headers["User-Agent"] = "xiao-cam-studio"; w.Encoding = Encoding.UTF8; return w;
  }

  public static string Check(XHub hub) {
    var o = new Dictionary<string, object>();
    try {
      string j = Encoding.UTF8.GetString(Fetch("version.json")).TrimStart((char)0xFEFF);
      var d = XCrazy.Js().DeserializeObject(j) as Dictionary<string, object>;
      string latest = Convert.ToString(d["studio"]);
      o["ok"] = true; o["current"] = hub.Version; o["latest"] = latest;
      o["firmware"] = d.ContainsKey("firmware") ? Convert.ToString(d["firmware"]) : "";
      o["notes"] = d.ContainsKey("notes") ? Convert.ToString(d["notes"]) : "";
      o["newer"] = Newer(latest, hub.Version);
    } catch (Exception e) { o["ok"] = false; o["err"] = "could not reach GitHub: " + e.Message; o["current"] = hub.Version; }
    return XCrazy.Js().Serialize(o);
  }
  static bool Newer(string a, string b) {
    try { return new Version(a) > new Version(b); } catch { return a != b; }
  }

  // download the new bat, keep the old one as .prev.bat, restart (and flash if the firmware changed)
  public static void Apply(XHub hub, bool flash) {
    if (string.IsNullOrEmpty(hub.SelfPath) || !File.Exists(hub.SelfPath)) throw new Exception("cannot find the running bat file");
    byte[] b = Fetch("XIAO-CAM-STUDIO.bat");
    string head = Encoding.ASCII.GetString(b, 0, Math.Min(b.Length, 200));
    if (b.Length < 50000 || !head.StartsWith("<# : XIAO-CAM Studio")) throw new Exception("the downloaded file does not look right - not updated");
    var mv = Regex.Match(Encoding.ASCII.GetString(b), "\\$StudioVersion\\s*=\\s*'([^']+)'");
    if (!mv.Success || !Newer(mv.Groups[1].Value, hub.Version)) throw new Exception("GitHub is still updating - try again in a few minutes");
    string dir = Path.GetDirectoryName(hub.SelfPath);
    string tmp = hub.SelfPath + ".new", prev = Path.Combine(dir, "XIAO-CAM-STUDIO.prev.bat");
    File.WriteAllBytes(tmp, b);
    File.Copy(hub.SelfPath, prev, true);
    File.Copy(tmp, hub.SelfPath, true);
    File.Delete(tmp);
    Relaunch(hub, flash ? "flash" : "view");
  }

  // close this Studio for good: its cmd window too (it would keep reading the replaced bat file).
  // Environment.Exit from a worker thread can hang inside PowerShell, so kill instead (shutdown already ran).
  public static void ExitNow() {
    var me = Process.GetCurrentProcess();
    try {
      using (var q = new ManagementObjectSearcher("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" + me.Id))
        foreach (ManagementObject o in q.Get()) {
          var parent = Process.GetProcessById(Convert.ToInt32(o["ParentProcessId"]));
          if (parent.ProcessName.Equals("cmd", StringComparison.OrdinalIgnoreCase)) parent.Kill();
        }
    } catch { }
    me.Kill();
  }

  // start the bat again in a new window, then close this one (the camera port must be free for flashing)
  public static void Relaunch(XHub hub, string mode) {
    // ShellExecute = new window and NO inherited handles (an inherited socket would keep the port busy)
    var psi = new ProcessStartInfo(hub.SelfPath, mode + " nobrowser");   // the open browser tab reconnects by itself
    psi.UseShellExecute = true;
    psi.WorkingDirectory = Path.GetDirectoryName(hub.SelfPath);
    var t = new Thread(delegate() {
      Thread.Sleep(400);
      hub.Shutdown();
      XWeb web = hub.Web; if (web != null) web.Stop();
      Thread.Sleep(300);
      Process.Start(psi);
      ExitNow();
    });
    t.IsBackground = true; t.Start();
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
#tabs{display:grid;grid-template-columns:repeat(7,1fr);border-bottom:1px solid var(--ln)}
#tabs button{border:0;border-radius:0;background:transparent;padding:11px 2px;color:var(--mu);border-bottom:2px solid transparent;font-size:12px}
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
  <button id="updBadge" class="pri" style="display:none" title="A new version is on GitHub">Update available</button>
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
<style>
#modeSw{margin-left:4px}#modeSw button{padding:5px 14px}
body.crazyOn #p_image,body.crazyOn #p_light,body.crazyOn #p_color{pointer-events:none;opacity:.4}
.lockmsg{display:none;margin:10px 0 0;padding:7px 10px;border-radius:6px;background:#2a210c;border:1px solid #5c4613;color:#fde3a7;font-size:12px}
body.crazyOn .lockmsg{display:block}
#cmp{display:none;grid-row:1/3;min-height:0;min-width:0;overflow:hidden;flex-direction:column;position:relative}
body.cmpMode #stage,body.cmpMode #bottom{display:none}body.cmpMode #cmp{display:flex}
#cmpBar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;padding:9px 10px;border-bottom:1px solid var(--ln);background:var(--p)}
#cmpBar select{width:auto;max-width:230px}#cmpBar label{color:var(--mu);display:flex;align-items:center;gap:5px}
#cmpBar .seg button{padding:5px 10px;white-space:nowrap}
#cmpEmpty{display:none;flex:1;align-items:center;justify-content:center;flex-direction:column;gap:6px;color:var(--mu);text-align:center;padding:30px}
#cmpEmpty b{color:var(--tx);font-size:15px}
#best{display:flex;gap:8px;padding:10px;overflow-x:auto;border-bottom:1px solid var(--ln);flex:none;scrollbar-width:thin}
.bestc{flex:none;width:168px;background:var(--bg);border:1px solid var(--ln);border-radius:8px;overflow:hidden;cursor:pointer}
.bestc:hover{border-color:#3a4250}
.bestc img{width:100%;aspect-ratio:4/3;object-fit:cover;display:block;background:#000}
.bestc div{padding:5px 8px;font-size:12px;line-height:1.35}.bestc div b{color:#bfd6ff}
#gridw{flex:1;overflow:auto;padding:10px;scrollbar-width:thin;scrollbar-color:#2a2f37 transparent}
#cgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(168px,1fr));gap:8px}
.cc{position:relative;background:var(--bg);border:1px solid var(--ln);border-radius:8px;overflow:hidden;cursor:pointer}
.cc:hover{border-color:#3a4250}.cc.sel{outline:2px solid var(--ac);outline-offset:-1px}
.cc img{width:100%;aspect-ratio:4/3;object-fit:cover;display:block;background:#000}
.cc .ci{padding:5px 8px 7px;font-size:12px}.cc .ci b{display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cc .ci span{color:var(--mu)}
.cc .num{position:absolute;left:6px;top:6px;background:var(--ac);color:#fff;border-radius:50%;width:22px;height:22px;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:12px}
.star{position:absolute;right:4px;top:2px;font-size:19px;line-height:1;color:#ffd54a;text-shadow:0 1px 3px #000;cursor:pointer;background:none;border:0;padding:2px 4px}
.star.off{color:rgba(255,255,255,.55)}
.sbar{height:4px;background:#20242b;border-radius:2px;margin-top:4px}.sbar i{display:block;height:100%;background:var(--ac);border-radius:2px}
#tray{display:flex;align-items:center;gap:8px;padding:8px 10px;border-top:1px solid var(--ln);background:var(--p);flex:none}
#tray img{height:38px;border-radius:4px}#tray .sp{flex:1}
#cview{position:absolute;inset:0;background:var(--bg);display:none;flex-direction:column;z-index:6}
#cvBar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 10px;border-bottom:1px solid var(--ln);background:var(--p)}
#cvBar button.on{border-color:var(--ac);color:#bfd6ff}
#cpanes{flex:1;display:grid;gap:6px;padding:6px;min-height:0}
.cvp{position:relative;overflow:hidden;background:#000;cursor:grab;min-height:0}
.cvp img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;transform-origin:50% 50%;user-select:none;-webkit-user-drag:none}
.cvp .tag{position:absolute;left:8px;top:8px;background:rgba(20,23,28,.85);padding:2px 8px;border-radius:5px;font-size:12px;z-index:3}
.cvp .tag.r{left:auto;right:8px}
#cinfos{display:grid;gap:6px;padding:0 6px 6px;flex:none;max-height:40vh;overflow:auto}
.cinfo{background:var(--p);border:1px solid var(--ln);border-radius:8px;padding:8px 10px;font-size:12px;min-width:0}
.cinfo h5{margin:0 0 5px;font-size:13px;display:flex;align-items:center;gap:8px}
.cinfo h5 .n{background:var(--ac);color:#fff;border-radius:50%;width:20px;height:20px;display:inline-flex;align-items:center;justify-content:center;font-size:11px;flex:none}
.cinfo table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}.cinfo td{padding:1px 4px;border-bottom:1px solid #1d2127}
.cinfo td:last-child{text-align:right}.cinfo tr.d td{color:#ffd54a}.cinfo tr.best td:last-child{color:#4ade80;font-weight:600}
.cinfo .cols{display:grid;grid-template-columns:1fr 1fr;gap:10px;align-items:start}
.cinfo .btns{margin-top:6px}.cinfo .btns button{padding:4px 9px;font-size:12px}
.cinfo input{width:130px;padding:3px 6px}
.wline{position:absolute;top:0;bottom:0;width:2px;background:#fff;z-index:4;cursor:ew-resize;box-shadow:0 0 0 1px rgba(0,0,0,.4)}
.wline::after{content:"";position:absolute;top:50%;left:-9px;width:20px;height:20px;margin-top:-10px;border-radius:50%;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.5)}
</style>
<script>
'use strict';
// ===================== Crazy mode + Compare =====================
let CZ=null;
const CX={shots:[],stars:new Set(),sel:[],prof:'daylight',limit:300,z:{z:1,x:0,y:0},wipe:false,wx:50,all:false,mode:localStorage.xczmode||'usb'};
const PROF={daylight:'Daylight',night:'Night',indoor:'Indoor',fast:'Fast video',wifi_smooth:'WiFi smooth',wifi_delay:'WiFi low delay',wifi_stable:'WiFi no freezes',wifi_picture:'WiFi best picture'};
const PL={t:0,playing:true,speed:1,dur:5000,last:0};
const czEnc=p=>'/crazy/file?p='+encodeURIComponent(p);
const czEsc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const czName=s=>s.mix?'Mix for '+PROF[s.mix]+' #'+parseInt(s.label.split('_').pop(),10):s.group+': '+s.label;
const czTime=s=>{s=s|0;const m=s/60|0;return m?m+' min '+(s%60)+' s':s+' s'};

function crazyPane(p){
  p.innerHTML=`<div class="sec">Crazy mode</div>
  <div class="hint">Shoots the same scene with every setting, nonstop, and saves scored photos in neat folders. Tape the camera down so it always sees the same thing. Your own settings come back when you stop.</div>
  <div class="field" style="margin-top:10px"><label>Test over</label><div class="seg" id="czMode"><button data-v="usb">USB cable</button><button data-v="wifi">WiFi (camera hotspot)</button></div></div>
  <div class="hint" id="czWifiHelp" style="display:none">1. Keep the USB cable plugged in (settings go over it).<br>2. Connect this PC to the <b>XIAO-CAM</b> WiFi (Windows WiFi menu) - no internet while testing.<br>3. Start. USB video is switched off during the test so WiFi gets the camera to itself; the live view shows what WiFi delivers.</div>
  <div class="field" style="margin-top:10px"><label>Output folder</label><div style="display:flex;gap:6px"><input type="text" id="czDir" spellcheck="false"><button id="czPick">Choose...</button></div></div>
  <div class="btns" style="margin-top:0"><button id="czSet">Use typed path</button><button id="czOpen">Open folder</button></div>
  <button id="czGo" class="pri" style="width:100%;padding:11px;font-size:14px;font-weight:600;margin-top:12px">Start crazy mode</button>
  <div class="meter" style="margin-top:10px"><i id="czBar" style="background:var(--ac)"></i></div>
  <div class="kv" id="czInfo" style="margin-top:8px"></div>
  <div class="sec">Last shot</div>
  <img id="czLast" alt="" style="width:100%;border-radius:6px;display:none;background:#000">
  <div class="kv" id="czScores" style="margin-top:6px"></div>
  <button id="czCmp" style="width:100%;margin-top:12px">Open Compare</button>
  <div class="sec">One round</div>
  <div class="hint">Every test = a 5-second video clip, saved on this PC (AVI, plays in VLC) with its scores.<br><b>USB:</b> light probe, then every value of every setting one at a time (~95 clips), then a mix of the winners per need. About 15 min per round.<br><b>WiFi:</b> resolution x quality, fps limit, WiFi power, clock (~50 clips), measuring fps, freezes and delay, then a mix of the winners. About 6-8 min per round.<br>Rounds repeat until you press Stop.</div>`;
  const dir=p.querySelector('#czDir');dir.addEventListener('input',()=>dir.dataset.dirty=1);
  p.querySelector('#czPick').onclick=async()=>{toast('A folder window opened - it may be behind the browser');const r=await api('/api/crazy/folder?pick=1');if(r.ok){delete dir.dataset.dirty;dir.value=r.dir;toast('Folder: '+r.dir)}else if(r.err!=='cancelled')toast(r.err||'Could not set the folder')};
  p.querySelector('#czSet').onclick=async()=>{const r=await api('/api/crazy/folder?path='+encodeURIComponent(dir.value));if(r.ok){delete dir.dataset.dirty;dir.value=r.dir;toast('Folder: '+r.dir)}else toast(r.err||'Bad folder')};
  p.querySelector('#czOpen').onclick=()=>api('/api/crazy/open');
  p.querySelector('#czGo').onclick=async()=>{if(CZ&&CZ.running){await api('/api/crazy/stop');toast('Stopping - putting your settings back...');return}
    const r=await api('/api/crazy/start?mode='+CX.mode);toast(r.ok?'Crazy mode started ('+(CX.mode==='wifi'?'WiFi':'USB')+')':'Could not start: '+(r.err||''))};
  const ms=()=>{p.querySelectorAll('#czMode button').forEach(b=>b.classList.toggle('on',b.dataset.v===CX.mode));p.querySelector('#czWifiHelp').style.display=CX.mode==='wifi'?'block':'none'};
  p.querySelectorAll('#czMode button').forEach(b=>b.onclick=()=>{if(CZ&&CZ.running){toast('Stop crazy mode first');return}CX.mode=b.dataset.v;localStorage.xczmode=CX.mode;ms()});ms();
  p.querySelector('#czCmp').onclick=()=>setMode('cmp');
  ['p_image','p_light','p_color'].forEach(id=>{const pane=document.getElementById(id);if(pane){const m=el('div','lockmsg','Crazy mode is running - settings are locked. Stop it in the Crazy tab.');pane.prepend(m)}});
}

function updCrazy(c){CZ=c;if(!c)return;
  document.body.classList.toggle('crazyOn',!!c.running);
  const g=$('#czGo');if(!g)return;
  g.textContent=c.running?'Stop crazy mode':'Start crazy mode';g.classList.toggle('pri',!c.running);g.classList.toggle('danger',!!c.running);
  const d=$('#czDir');if(d&&!d.dataset.dirty&&document.activeElement!==d)d.value=c.dir||'';
  $('#czBar').style.width=c.running&&c.total?Math.min(100,c.shot/c.total*100)+'%':'0';
  const rows=c.running?[['Mode',c.mode==='wifi'?'WiFi'+(c.wifi?' - '+c.wifi:''):'USB'],['State',c.phase],['Round',c.round||'-'],['Light',c.light||'-'],['Clip',c.shot+' of '+c.total],['Testing now',c.current||'-'],['Round ends in','~'+czTime(c.eta)],['Rounds done',c.roundsDone]]
    :[['State',c.phase==='idle'?'stopped':c.phase],['Rounds done this run',c.roundsDone]];
  if(c.err)rows.push(['Last error',c.err]);
  $('#czInfo').innerHTML=rows.map(([a,b])=>`<span>${a}</span><b title="${czEsc(b)}">${czEsc(b)}</b>`).join('');
  const li=$('#czLast');if(c.last&&li.dataset.p!==c.last){li.dataset.p=c.last;li.src=czEnc(c.last);li.style.display='block'}
  const s=c.scores;$('#czScores').innerHTML=s?[['Size',s.w+' x '+s.h],['FPS',s.fps],['Freezes',s.stalls+(s.maxgap?' (longest '+s.maxgap+' ms)':'')],['Delay',s.lat>=0?s.lat+' ms (90%: '+s.lat90+')':'-'],['Data',s.kbps+' KB/s'],['Sharpness',s.sharp],['Brightness',Math.round(s.mean*100)+'%']].map(([a,b])=>`<span>${a}</span><b>${b}</b>`).join(''):'';
  if(c.running){$('#stat').textContent='CRAZY MODE '+(c.mode==='wifi'?'(WiFi) ':'')+'- clip '+c.shot+' of '+c.total+' - '+(c.current||c.phase)}
}

// ---------- compare: data ----------
function setMode(m){document.body.classList.toggle('cmpMode',m==='cmp');document.querySelectorAll('#modeSw button').forEach(b=>b.classList.toggle('on',b.dataset.m===m));
  if(m==='cmp')loadLib();else{closeView();layout()}}
async function loadLib(){
  const r=await api('/api/crazy/rounds');const shots=[];
  if(r.ok)for(const id of r.rounds){const j=await api('/api/crazy/round?id='+encodeURIComponent(id));if(!j||!j.shots)continue;
    j.shots.forEach(s=>{s.round=id;s.light=j.light;s.rnum=j.round;s.mode=s.mode||j.mode||'usb';shots.push(s)})}
  const st=await api('/api/crazy/stars');CX.stars=new Set(Array.isArray(st)?st:[]);
  CX.shots=shots;CX.rounds=r.ok?r.rounds:[];CX.dir=r.dir||'';
  const keep=new Set(CX.sel.map(s=>s.file));CX.sel=shots.filter(s=>keep.has(s.file));
  fillFilters();cmpRender()}
function fillFilters(){
  const opt=(sel,list,all)=>{const s=$(sel),v=s.value;s.innerHTML=`<option value="">${all}</option>`+list.map(x=>`<option value="${czEsc(x[0])}">${czEsc(x[1])}</option>`).join('');if([...s.options].some(o=>o.value===v))s.value=v};
  opt('#fRound',CX.rounds.slice().reverse().map(r=>[r,r.replace(/_/g,' ')]),'All rounds');
  opt('#fLight',['day','dim','night'].filter(l=>CX.shots.some(s=>s.light===l)).map(l=>[l,l]),'All light');
  const gs=[...new Set(CX.shots.map(s=>s.group))].sort();opt('#fGroup',gs.map(g=>[g,g]),'All settings');
}
function filtered(){const r=$('#fRound').value,l=$('#fLight').value,g=$('#fGroup').value,st=$('#fStar').checked,ty=$('#fType').value;
  return CX.shots.filter(s=>(!r||s.round===r)&&(!l||s.light===l)&&(!g||s.group===g)&&(!ty||s.mode===ty)&&(!st||CX.stars.has(s.file)))}
// same formula as the PC engine (XScore.Rank); noise is judged relative to brightness
function rank(list,prof){const n=list.length,o=new Map();if(!n)return o;
  const nm=f=>{let mn=Infinity,mx=-Infinity;list.forEach(s=>{const v=f(s.scores);mn=Math.min(mn,v);mx=Math.max(mx,v)});return list.map(s=>mx-mn<1e-9?.5:(f(s.scores)-mn)/(mx-mn))};
  const sh=nm(x=>x.sharp),no=nm(x=>x.noise/Math.max(x.mean,.05)),cl=nm(x=>x.clip),ca=nm(x=>x.cast),fp=nm(x=>x.fps);
  const st=nm(x=>x.stalls||0),mg=nm(x=>x.maxgap||0),ji=nm(x=>x.jitter||0),la=nm(x=>x.lat>=0?x.lat:1e6),l9=nm(x=>x.lat90>=0?x.lat90:1e6);
  list.forEach((s,i)=>{const ex=Math.max(0,1-Math.abs(s.scores.mean-.45)/.45);let v;
    if(prof==='daylight')v=.35*sh[i]+.25*ex+.15*(1-ca[i])+.15*(1-no[i])+.10*(1-cl[i]);
    else if(prof==='night')v=.35*ex+.30*(1-no[i])+.20*sh[i]+.15*(1-cl[i]);
    else if(prof==='indoor')v=.30*ex+.25*(1-ca[i])+.25*sh[i]+.20*(1-no[i]);
    else if(prof==='fast')v=.50*fp[i]+.20*sh[i]+.20*ex+.10*(1-no[i]);
    else if(prof==='wifi_smooth')v=.60*fp[i]+.25*(1-st[i])+.15*(1-mg[i]);
    else if(prof==='wifi_delay')v=.60*(1-la[i])+.20*(1-l9[i])+.20*fp[i];
    else if(prof==='wifi_stable')v=.45*(1-st[i])+.35*(1-mg[i])+.20*(1-ji[i]);
    else v=(.55*sh[i]+.25*ex+.20*(1-no[i]))*Math.min(1,s.scores.fps/10)*((s.scores.stalls||0)>0?.7:1);
    if(!prof.startsWith('wifi')||prof==='wifi_picture')v*=.4+.6*Math.min(1,ex/.6);o.set(s,v)});return o}

// ---------- compare: grid ----------
function cmpRender(){
  const list=filtered();const has=CX.shots.length>0;
  $('#cmpEmpty').style.display=has?'none':'flex';$('#best').style.display=has?'flex':'none';$('#gridw').style.display=has?'block':'none';
  $('#cmpCount').textContent=has?list.length+' of '+CX.shots.length+' clips':'';
  const sc=rank(list,CX.prof),srt=$('#fSort').value;
  const key={score:s=>-sc.get(s),sharp:s=>-s.scores.sharp,noise:s=>s.scores.noise,bright:s=>-s.scores.mean,fps:s=>-s.scores.fps,lat:s=>s.scores.lat>=0?s.scores.lat:1e9,stalls:s=>(s.scores.stalls||0)*1e5+(s.scores.maxgap||0),kb:s=>s.scores.kb,time:s=>-(Date.parse(s.time)||0)}[srt];
  const sorted=list.slice().sort((a,b)=>key(a)-key(b));
  // best per need, per light level
  const best=$('#best');best.innerHTML='';
  const lights=['day','dim','night'].filter(l=>list.some(s=>s.light===l));
  Object.keys(PROF).forEach(p=>lights.forEach(l=>{const sub=list.filter(s=>s.light===l&&(p.startsWith('wifi')?s.mode==='wifi':s.mode!=='wifi'));const r=rank(sub,p);let b=null,bv=-1;sub.forEach(s=>{if(r.get(s)>bv){bv=r.get(s);b=s}});if(!b)return;
    const c=el('div','bestc',`<img loading="lazy" src="${czEnc(b.thumb)}" alt=""><div><b>${PROF[p]}</b> &middot; ${l}<br>${czEsc(czName(b))}</div>`);c.title='Best for '+PROF[p]+' in '+l+' light - click to select';c.onclick=()=>toggleSel(b);best.appendChild(c)}));
  const g=$('#cgrid');g.innerHTML='';
  sorted.slice(0,CX.limit).forEach(s=>{const v=sc.get(s)||0;const i=CX.sel.indexOf(s);
    const c=el('div','cc'+(i>=0?' sel':''),`<img loading="lazy" src="${czEnc(s.thumb)}" alt="">${s.index?`<span class="tag" style="position:absolute;left:6px;bottom:52px;background:rgba(20,23,28,.85);padding:1px 7px;border-radius:5px;font-size:11px">&#9654; ${Math.round(s.scores.dur||5)} s</span>`:""}${i>=0?`<span class="num">${i+1}</span>`:''}
      <button class="star${CX.stars.has(s.file)?'':' off'}" title="Star">${CX.stars.has(s.file)?'&#9733;':'&#9734;'}</button>
      <div class="ci"><b>${czEsc(czName(s))}</b><span>R${s.rnum} &middot; ${s.mode==="wifi"?"WiFi":"USB"} &middot; ${s.scores.w}x${s.scores.h} &middot; ${s.scores.fps} fps${s.scores.stalls!==undefined?" &middot; "+s.scores.stalls+" freezes":""}${s.scores.lat>=0?" &middot; "+s.scores.lat+" ms":""}</span><div class="sbar"><i style="width:${(v*100).toFixed(0)}%"></i></div></div>`);
    c.onclick=()=>toggleSel(s);c.querySelector('.star').onclick=e=>{e.stopPropagation();starToggle(s)};g.appendChild(c)});
  $('#more').style.display=sorted.length>CX.limit?'inline-block':'none';
  drawTray()}
function toggleSel(s){const i=CX.sel.indexOf(s);if(i>=0)CX.sel.splice(i,1);else{if(CX.sel.length>=4)CX.sel.shift();CX.sel.push(s)}cmpRender()}
async function starToggle(s){const on=!CX.stars.has(s.file);const r=await api('/api/crazy/star?p='+encodeURIComponent(s.file)+'&on='+(on?1:0));
  if(!r.ok){toast('Could not save the star');return}if(on)CX.stars.add(s.file);else CX.stars.delete(s.file);cmpRender();if($('#cview').style.display==='flex')openView()}
function drawTray(){const t=$('#trayImgs');t.innerHTML=CX.sel.map(s=>`<img src="${czEnc(s.thumb)}" alt="" title="${czEsc(czName(s))}">`).join('');
  $('#trayTxt').textContent=CX.sel.length?CX.sel.length+' selected':'Click clips to pick 2-4 to compare';
  $('#goCmp').disabled=CX.sel.length<2;$('#goCmp').textContent='Compare ('+CX.sel.length+')'}

// ---------- compare: side by side ----------
const SKEYS=()=>SENSOR_KEYS;
const SNAME={framesize:'Resolution',quality:'JPEG quality',fps_limit:'FPS limit',brightness:'Brightness',contrast:'Contrast',saturation:'Saturation',sharpness:'Sharpness',denoise:'Denoise',effect:'Effect',awb:'Auto WB',awb_gain:'WB gain',wb_mode:'WB mode',aec:'Auto exposure',aec2:'Exposure DSP',ae_level:'Exposure comp',aec_value:'Manual exposure',agc:'Auto gain',agc_gain:'Manual gain',gainceiling:'Max gain',bpc:'Black pixel fix',wpc:'White pixel fix',raw_gma:'Gamma',lenc:'Lens correction',hmirror:'Mirror',vflip:'Flip',dcw:'Downscale',xclk:'Clock MHz',tx_power:'WiFi power'};
function sval(s,k){const v=s.set[k];if(v===undefined)return'-';if(k==='framesize')return s.scores.w+'x'+s.scores.h;if(k==='wb_mode')return['Auto','Sunny','Cloudy','Office','Home'][v]||v;if(k==='gainceiling')return(2<<v)+'x';if(k==='tx_power')return(v/4)+' dBm';if(k==='agc_gain')return(v+1)+'x';
  if(['awb','awb_gain','aec','aec2','agc','bpc','wpc','raw_gma','lenc','hmirror','vflip','dcw'].includes(k))return v?'on':'off';return v}
function openView(){const sel=CX.sel;if(sel.length<2){toast('Pick at least 2 clips');return}
  const v=$('#cview');v.style.display='flex';const wipe=CX.wipe&&sel.length===2;
  $('#cvWipe').style.display=sel.length===2?'':'none';$('#cvWipe').classList.toggle('on',wipe);$('#cvAll').classList.toggle('on',CX.all);
  const panes=$('#cpanes');panes.innerHTML='';panes.style.gridTemplateColumns=wipe?'1fr':`repeat(${sel.length},1fr)`;
  if(wipe){const p=el('div','cvp');p.innerHTML=`<img src="${czEnc(sel[0].index?sel[0].thumb:sel[0].file)}" alt=""><img class="wtop" src="${czEnc(sel[1].index?sel[1].thumb:sel[1].file)}" alt=""><span class="tag">1</span><span class="tag r">2</span><div class="wline"></div>`;panes.appendChild(p);wireView(p,true)}
  else sel.forEach((s,i)=>{const p=el('div','cvp');p.innerHTML=`<img src="${czEnc(s.index?s.thumb:s.file)}" alt=""><span class="tag">${i+1}</span>`;panes.appendChild(p);wireView(p,false)});
  zoomApply();
  // info
  const infos=$('#cinfos');infos.style.gridTemplateColumns=`repeat(${sel.length},1fr)`;infos.innerHTML='';
  const diff=SKEYS().filter(k=>new Set(sel.map(s=>String(s.set[k]))).size>1);const keys=CX.all?SKEYS():diff;
  const prof=Object.keys(PROF).map(p=>[p,rank(sel,p)]);startPlayer(sel);
  const met=[['FPS','fps',1],['Freezes','stalls',-1],['Longest gap ms','maxgap',-1],['Delay ms','lat',-1],['Delay 90% ms','lat90',-1],['Jitter ms','jitter',-1],['Data KB/s','kbps',0],['Sharpness','sharp',1],['Noise','noise',-1],['Brightness','mean',0],['Clipped','clip',-1],['Color cast','cast',-1]].filter(([n,k])=>sel.some(x=>x.scores[k]!==undefined&&x.scores[k]>=0));
  sel.forEach((s,i)=>{const c=el('div','cinfo');
    const bestOf=(k,dir)=>{const vals=sel.map(x=>x.scores[k]).filter(v=>v!==undefined&&v>=0);const b=dir>0?Math.max(...vals):Math.min(...vals);return s.scores[k]===b};
    const mrows=met.map(([n,k,d])=>{const v=s.scores[k]===undefined||s.scores[k]<0?'-':k==='mean'?Math.round(s.scores.mean*100)+'%':k==='clip'?(s.scores.clip*100).toFixed(1)+'%':s.scores[k];return`<tr class="${d&&bestOf(k,d)?'best':''}"><td>${n}</td><td>${v}</td></tr>`}).join('')
      +prof.filter(([p])=>p.startsWith('wifi')===(s.mode==='wifi')).map(([p,r])=>{const mx=Math.max(...sel.map(x=>r.get(x)));const v=r.get(s);return`<tr class="${v===mx?'best':''}"><td>${PROF[p]} score</td><td>${Math.round(v*100)}</td></tr>`}).join('');
    const srows=keys.length?keys.map(k=>`<tr class="${diff.includes(k)?'d':''}"><td>${SNAME[k]||k}</td><td>${czEsc(sval(s,k))}</td></tr>`).join(''):'<tr><td colspan="2">Same settings</td></tr>';
    c.innerHTML=`<h5><span class="n">${i+1}</span>${czEsc(czName(s))}</h5><div class="hint" style="margin:0 0 6px">${czEsc(s.round)} &middot; ${s.light}${s.from?' &middot; mix of '+czEsc(s.from.join(', ')):''}</div>
      <div class="cols"><table>${srows}</table><table>${mrows}</table></div>
      <div class="btns"><button class="st">${CX.stars.has(s.file)?'&#9733; Starred':'&#9734; Star'}</button><button class="ap pri">Apply to camera</button><input type="text" placeholder="Profile name"><button class="sv">Save as profile</button></div>`;
    c.querySelector('.st').onclick=()=>starToggle(s);
    c.querySelector('.ap').onclick=()=>{if(CZ&&CZ.running){toast('Stop crazy mode first');return}applySet(s.set);toast('Applied to the camera: '+czName(s))};
    c.querySelector('.sv').onclick=()=>{const n=c.querySelector('input').value.trim();if(!n){toast('Type a profile name');return}const P_=profs();const o={};SENSOR_KEYS.forEach(k=>{if(s.set[k]!==undefined)o[k]=s.set[k]});P_[n]=o;localStorage.xprof=JSON.stringify(P_);if($('#profList'))drawProfs();toast('Profile saved: '+n)};
    infos.appendChild(c)})}
function closeView(){const v=$('#cview');if(v)v.style.display='none';PL.on=false;CX.shots.forEach(s=>{if(s._fr){s._fr.forEach(f=>URL.revokeObjectURL(f.url));delete s._fr}})}
// ---------- synced clip player ----------
async function clipFrames(s){if(s._fr)return s._fr;if(!s.index)return null;
  const ix=await (await fetch(czEnc(s.index))).json();const buf=await (await fetch(czEnc(s.file))).arrayBuffer();
  s._fr=ix.frames.map(f=>({t:f[0],url:URL.createObjectURL(new Blob([new Uint8Array(buf,f[1],f[2])],{type:'image/jpeg'}))}));s._dur=ix.dur;return s._fr}
function frameIdx(fr,t){let lo=0,hi=fr.length-1,r=0;while(lo<=hi){const m=(lo+hi)>>1;if(fr[m].t<=t){r=m;lo=m+1}else hi=m-1}return r}
async function startPlayer(sel){const clips=sel.some(s=>s.index);$('#plBar').style.display=clips?'flex':'none';PL.on=false;if(!clips)return;
  $('#plTime').textContent='loading...';await Promise.all(sel.map(clipFrames));
  PL.sel=sel;PL.dur=Math.max(...sel.map(s=>s._dur||0),1000);PL.t=0;PL.last=performance.now();PL.on=true;PL.playing=true;$('#plPlay').textContent='Pause';requestAnimationFrame(plTick)}
function plShow(){const imgs=document.querySelectorAll('#cpanes img');const sel=PL.sel||[];
  imgs.forEach((im,i)=>{const s=CX.wipe&&sel.length===2?sel[im.classList.contains('wtop')?1:0]:sel[i];if(!s||!s._fr||!s._fr.length)return;const u=s._fr[frameIdx(s._fr,PL.t)].url;if(im.dataset.u!==u){im.dataset.u=u;im.src=u}});
  $('#plSeek').value=Math.round(PL.t/PL.dur*1000);$('#plTime').textContent=(PL.t/1000).toFixed(2)+' / '+(PL.dur/1000).toFixed(1)+' s'}
function plTick(now){if(!PL.on)return;if(PL.playing){PL.t+=(now-PL.last)*PL.speed;if(PL.t>PL.dur)PL.t=0}PL.last=now;plShow();requestAnimationFrame(plTick)}
function plStep(d){PL.playing=false;$('#plPlay').textContent='Play';const s=(PL.sel||[]).find(x=>x._fr&&x._fr.length);if(!s)return;let i=frameIdx(s._fr,PL.t)+d;i=Math.max(0,Math.min(s._fr.length-1,i));PL.t=s._fr[i].t;plShow()}
function zoomApply(){const z=CX.z;document.querySelectorAll('#cpanes img').forEach(i=>i.style.transform=`translate(${z.x}px,${z.y}px) scale(${z.z})`);
  document.querySelectorAll('#cpanes .wtop').forEach(i=>i.style.clipPath=`inset(0 0 0 ${CX.wx}%)`);document.querySelectorAll('#cpanes .wline').forEach(l=>l.style.left=CX.wx+'%')}
function wireView(p,wipe){
  p.addEventListener('wheel',e=>{e.preventDefault();const f=e.deltaY<0?1.2:1/1.2,z=CX.z,nz=Math.min(12,Math.max(1,z.z*f));const r=p.getBoundingClientRect();const cx=e.clientX-r.left-r.width/2,cy=e.clientY-r.top-r.height/2;
    z.x=cx-(cx-z.x)*nz/z.z;z.y=cy-(cy-z.y)*nz/z.z;z.z=nz;if(nz===1){z.x=0;z.y=0}zoomApply()},{passive:false});
  p.addEventListener('mousedown',e=>{e.preventDefault();CX.drag=wipe&&e.target.classList.contains('wline')?{p,wipe:true}:{p,x:e.clientX-CX.z.x,y:e.clientY-CX.z.y}});
  p.addEventListener('dblclick',()=>{CX.z={z:1,x:0,y:0};zoomApply()})}

function initCompare(){
  const sw=el('div','seg');sw.id='modeSw';sw.innerHTML='<button data-m="live" class="on">Live</button><button data-m="cmp">Compare</button>';
  document.querySelector('.brand').after(sw);sw.querySelectorAll('button').forEach(b=>b.onclick=()=>setMode(b.dataset.m));
  const c=el('div');c.id='cmp';c.innerHTML=`<div id="cmpBar">
    <div class="seg fProf" title="Rank for (USB tests)">${Object.entries(PROF).filter(([k])=>!k.startsWith("wifi")).map(([k,v])=>`<button data-p="${k}"${k===CX.prof?' class="on"':''}>${v}</button>`).join('')}</div>
    <div class="seg fProf" title="Rank for (WiFi tests)">${Object.entries(PROF).filter(([k])=>k.startsWith("wifi")).map(([k,v])=>`<button data-p="${k}"${k===CX.prof?' class="on"':''}>${v.replace("WiFi ","")}</button>`).join('')}</div>
    <select id="fType"><option value="">USB + WiFi</option><option value="usb">USB tests</option><option value="wifi">WiFi tests</option></select>
    <select id="fRound"></select><select id="fLight"></select><select id="fGroup"></select>
    <select id="fSort"><option value="score">Sort: best for the need</option><option value="sharp">Sort: sharpest</option><option value="noise">Sort: least noise</option><option value="bright">Sort: brightest</option><option value="fps">Sort: highest fps</option><option value="lat">Sort: lowest delay</option><option value="stalls">Sort: fewest freezes</option><option value="kb">Sort: smallest file</option><option value="time">Sort: newest</option></select>
    <label><input type="checkbox" id="fStar"> Starred only</label><span class="sp"></span><span id="cmpCount" style="color:var(--mu)"></span><button id="cmpReload">Reload</button></div>
    <div id="cmpEmpty"><b>No crazy-mode clips yet</b><span>Start crazy mode in the Crazy tab. Clips appear here as they are taken (press Reload).</span></div>
    <div id="best"></div>
    <div id="gridw"><div id="cgrid"></div><div style="text-align:center;margin:12px"><button id="more">Show more</button></div></div>
    <div id="tray"><span id="trayImgs" style="display:flex;gap:6px"></span><span id="trayTxt" style="color:var(--mu)"></span><span class="sp"></span><button id="selClr">Clear</button><button id="goCmp" class="pri" disabled>Compare (0)</button></div>
    <div id="cview"><div id="cvBar"><button id="cvBack">&larr; Back to all clips</button><button id="cvWipe" title="Drag the white line">A/B wipe</button><button id="cvAll">Show all settings</button><button id="cvFit">Reset zoom</button>
      <span id="plBar" style="display:none;align-items:center;gap:6px"><button id="plPlay">Pause</button><button id="plPrev" title="Previous frame">&#9664;|</button><button id="plNext" title="Next frame">|&#9654;</button>
      <input type="range" id="plSeek" min="0" max="1000" value="0" style="width:200px"><span id="plTime" style="font-variant-numeric:tabular-nums;color:var(--mu);min-width:86px"></span>
      <select id="plSpeed" style="width:auto"><option value="1">1x</option><option value="0.5">0.5x</option><option value="0.25">0.25x</option></select></span>
      <span class="hint" style="margin:0 0 0 6px">Wheel = zoom all, drag = move. Yellow = different setting, green = best.</span></div>
      <div id="cpanes"></div><div id="cinfos"></div></div>`;
  $('#left').appendChild(c);
  c.querySelectorAll('.fProf button').forEach(b=>b.onclick=()=>{CX.prof=b.dataset.p;c.querySelectorAll('.fProf button').forEach(x=>x.classList.toggle('on',x===b));
    const ty=$('#fType');if(CX.prof.startsWith('wifi'))ty.value='wifi';else if(ty.value==='wifi')ty.value='usb';cmpRender()});
  ['#fType','#fRound','#fLight','#fGroup','#fSort','#fStar'].forEach(s=>c.querySelector(s).onchange=()=>{CX.limit=300;cmpRender()});
  c.querySelector('#cmpReload').onclick=loadLib;c.querySelector('#more').onclick=()=>{CX.limit+=300;cmpRender()};
  c.querySelector('#selClr').onclick=()=>{CX.sel=[];cmpRender()};c.querySelector('#goCmp').onclick=()=>{CX.z={z:1,x:0,y:0};openView()};
  c.querySelector('#cvBack').onclick=closeView;c.querySelector('#cvWipe').onclick=()=>{CX.wipe=!CX.wipe;openView()};
  c.querySelector('#cvAll').onclick=()=>{CX.all=!CX.all;openView()};
  c.querySelector('#plPlay').onclick=()=>{PL.playing=!PL.playing;$('#plPlay').textContent=PL.playing?'Pause':'Play'};
  c.querySelector('#plPrev').onclick=()=>plStep(-1);c.querySelector('#plNext').onclick=()=>plStep(1);
  c.querySelector('#plSeek').oninput=e=>{PL.playing=false;$('#plPlay').textContent='Play';PL.t=e.target.value/1000*PL.dur;plShow()};
  c.querySelector('#plSpeed').onchange=e=>PL.speed=+e.target.value;c.querySelector('#cvFit').onclick=()=>{CX.z={z:1,x:0,y:0};zoomApply()};
  addEventListener('keydown',e=>{if(e.key==='Escape')closeView()});
  addEventListener('mousemove',e=>{const d=CX.drag;if(!d)return;if(d.wipe){const r=d.p.getBoundingClientRect();CX.wx=Math.max(0,Math.min(100,(e.clientX-r.left)/r.width*100))}else{CX.z.x=e.clientX-d.x;CX.z.y=e.clientY-d.y}zoomApply()});
  addEventListener('mouseup',()=>{CX.drag=null});
  setInterval(()=>{if(document.body.classList.contains('cmpMode')&&CZ&&CZ.running&&$('#cview').style.display!=='flex'&&!document.hidden)loadLib()},20000);
}
</script>
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
const TABS=[['image','Image',IMAGE],['light','Light',LIGHT],['color','Color',COLOR],['crazy','Crazy',crazyPane],['rec','Record',recPane],['wifi','WiFi',wifiPane],['board','Board',boardPane]];
// ---------- presets + profiles ----------
const SENSOR_KEYS=['framesize','quality','fps_limit','brightness','contrast','saturation','sharpness','denoise','effect','awb','awb_gain','wb_mode','aec','aec2','ae_level','aec_value','agc','agc_gain','gainceiling','bpc','wpc','raw_gma','lenc','hmirror','vflip','dcw','xclk','tx_power'];
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
  <div class="sec">Updates</div>
  <div class="kv" id="upInfo"></div>
  <div class="btns"><button id="upChk">Check for updates</button><button id="upGo" class="pri" style="display:none">Update now</button><button id="fwGo">Flash camera firmware</button></div>
  <div class="hint" id="upNote"></div>
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
  p.querySelector('#upChk').onclick=()=>checkUpd(false);
  const two=(b,label,fn)=>{b.onclick=()=>{if(!b.dataset.arm){b.dataset.arm=1;const t=b.textContent;b.textContent=label;setTimeout(()=>{delete b.dataset.arm;b.textContent=t},3000);return}delete b.dataset.arm;fn()}};
  two(p.querySelector('#upGo'),'Click again to update',async()=>{const flash=!!(UP&&UP.firmware&&B&&B.fw!==UP.firmware);const r=await api('/api/update/apply?flash='+(flash?1:0));
    toast(r.ok?'Updating - the studio restarts in a new window'+(flash?' and flashes the camera':'')+'. This page reconnects by itself.':'Update failed: '+(r.err||''))});
  two(p.querySelector('#fwGo'),'Click again to flash',async()=>{const r=await api('/api/flash');toast(r.ok?'Flashing - watch the new black window. This page reconnects by itself.':'Cannot flash: '+(r.err||''))});
  drawProfs();loadPorts();
}
let UP=null;
async function checkUpd(silent){const r=await api('/api/update/check');UP=r;if(!silent)toast(!r.ok?(r.err||'Check failed'):r.newer?'Update available: '+r.latest:'You have the latest version');drawUpd()}
function drawUpd(){const i=$('#upInfo');if(!i||!P)return;
  const rows=[['Studio',P.version],['Latest on GitHub',UP?(UP.ok?UP.latest:'offline'):'checking...'],['Camera firmware',B?B.fw:'-'],['This studio wants',P.fwExpected]];
  i.innerHTML=rows.map(([a,b])=>`<span>${a}</span><b>${b}</b>`).join('');
  $('#upGo').style.display=UP&&UP.newer?'':'none';
  let n='';if(UP&&UP.newer)n+='New version '+UP.latest+(UP.notes?': '+UP.notes:'')+'. ';
  if(B&&!P.demo&&P.fwExpected&&B.fw!==P.fwExpected)n+='The camera runs firmware '+B.fw+' - press Flash camera firmware to get '+P.fwExpected+'.';
  $('#upNote').textContent=n;const bd=$('#updBadge');if(bd)bd.style.display=UP&&UP.newer?'':'none'}
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
addEventListener('keydown',e=>{if(e.target.matches('input,select,textarea')||document.body.classList.contains('cmpMode'))return;const k=e.key.toLowerCase();
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
function refresh(){upd.forEach(d=>d.upd());updWifi();updBoard();drawUpd()}
async function poll(){const s=await api('/api/state');if(s&&s.pc){if(poll.down){location.reload();return}P=s.pc;B=s.board}else{P=null;poll.down=true}
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
    updCrazy(s.crazy);
    if(P.msg&&P.msg!==poll.msg){if(poll.msg!==undefined)toast(P.msg);poll.msg=P.msg}}
  refresh()}
TABS.forEach(([id,label,items],i)=>{
  const b=el('button',i?'':'on',label);b.onclick=()=>{document.querySelectorAll('#tabs button').forEach(x=>x.classList.remove('on'));document.querySelectorAll('.pane').forEach(x=>x.classList.remove('on'));b.classList.add('on');$('#p_'+id).classList.add('on');localStorage.xtab=id};b.dataset.id=id;$('#tabs').appendChild(b);
  const p=el('div','pane'+(i?'':' on'));p.id='p_'+id;$('#panes').appendChild(p);
  if(typeof items==='function')items(p);else items.forEach(it=>{if(it.sec)p.appendChild(el('div','sec',it.sec));else if(it.custom)it.custom(p);else p.appendChild(build(it))});
});
if(localStorage.xtab){const b=document.querySelector(`#tabs button[data-id="${localStorage.xtab}"]`);if(b)b.click()}

initCompare();
setTimeout(()=>checkUpd(true),3000);
$('#updBadge').onclick=()=>document.querySelector('#tabs button[data-id=board]').click();
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
  $code = $Sketch.Replace('@@SSID@@', $Ssid).Replace('@@PASS@@', $Pass).Replace('@@FWVER@@', $FirmwareVersion)
  [IO.File]::WriteAllText((Join-Path $SketchDir 'xiaocam2.ino'), $code)
  Run-Arduino compile --fqbn $Fqbn --output-dir $BuildDir $SketchDir
  Ok "build OK"
}

# a Studio that is still open keeps the camera port busy ("Access is denied"): ask it to quit
function Stop-OtherStudio {
  $found = $false
  foreach ($p in 8787..8816) {
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:$p/api/state" -UseBasicParsing -TimeoutSec 2
      if ($r.Content -match '"pc"') {
        Warn "Closing the Studio that is still open on port $p (it holds the camera port)"
        try { Invoke-WebRequest "http://127.0.0.1:$p/api/quit" -UseBasicParsing -TimeoutSec 3 | Out-Null } catch { }
        $found = $true
      }
    } catch { }
  }
  if ($found) { Start-Sleep -Seconds 3 }
}

function Flash-Firmware {
  Stop-OtherStudio
  $bootUsed = $false
  for ($try = 1; $try -le 3; $try++) {
    $port = Wait-CamPort
    Say "Flashing to $port (do not unplug)  - try $try of 3"
    & $Cli upload -p $port --fqbn $Fqbn --input-dir $BuildDir $SketchDir
    if ($LASTEXITCODE -eq 0) { break }
    if ($try -eq 1) {
      Warn "Flash failed - the port may be busy. Freeing it and trying again..."
      Stop-OtherStudio; Start-Sleep -Seconds 2
    } elseif ($try -eq 2) {
      Warn "Still failing. Close Arduino IDE / serial monitors / other camera windows if any are open."
      Warn "Then: unplug the XIAO, HOLD the BOOT button (B), plug it back in, let go."
      Read-Host "Press Enter to try again"
      $bootUsed = $true
    } else { throw "flash failed 3 times - another program is probably using $port" }
  }
  if ($bootUsed) { Warn "You used the BOOT button: press the RESET button (R) or unplug/replug once now." }
  Ok "flashed. Camera restarts..."
  Start-Sleep -Seconds 4
}

function Start-Studio([bool]$demo) {
  Say "Starting XIAO CAM Studio"
  if (-not ('XHub' -as [type])) { Add-Type -TypeDefinition $StudioCs -ReferencedAssemblies System.Drawing, System.Management, System.Web.Extensions, System.Windows.Forms, System.Net }
  $hub = New-Object XHub
  $hub.Html = $Html
  $hub.Version = $StudioVersion; $hub.FwExpected = $FirmwareVersion; $hub.SelfPath = $env:XCAM_SELF
  $hub.PicturesDir = Join-Path $Root 'pictures'
  $hub.VideosDir = Join-Path $Root 'videos'
  $hub.Demo = $demo
  [XHub]::HookConsole($hub)
  $hub.StartAll((Join-Path $Root 'crazy'))
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
