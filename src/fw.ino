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
