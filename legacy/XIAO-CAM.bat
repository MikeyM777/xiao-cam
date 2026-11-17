<# : XIAO-CAM - one file: installs tools, builds, flashes, and shows the camera.
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
#  XIAO-CAM  -  Seeed XIAO ESP32S3 Sense camera
#   1. Downloads arduino-cli + the ESP32 core (first run only, ~1 GB, needs internet)
#   2. Builds the camera firmware below and flashes it over USB-C
#   3. Opens a viewer on this PC (pictures come over the USB cable)
#   The board also makes its own WiFi:  XIAO-CAM / xiaocam123
#   Phone: join that WiFi, open http://192.168.4.1
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Ssid = 'XIAO-CAM'
$Pass = 'xiaocam123'          # WiFi password: at least 8 characters
$FrameSize = 'QXGA'           # QVGA 320x240, VGA 640x480, SVGA 800x600, XGA 1024x768, HD 1280x720,
                              # SXGA 1280x1024, UXGA 1600x1200, FHD 1920x1080, QXGA 2048x1536 (max)
$Quality = 10                 # JPEG quality 4..63, lower = better picture, bigger files

$Data      = Join-Path $env:LOCALAPPDATA 'XiaoCam'
$CliDir    = Join-Path $Data 'arduino-cli'
$Cli       = Join-Path $CliDir 'arduino-cli.exe'
$SketchDir = Join-Path $Data 'xiaocam'
$BuildDir  = Join-Path $Data 'build'
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
// XIAO-CAM firmware - XIAO ESP32S3 Sense
// USB-C : frames as  "XCAM" + uint32 length (LE) + JPEG
// WiFi  : own access point, page http://192.168.4.1 , stream http://192.168.4.1:81/stream
#include "esp_camera.h"
#include <WiFi.h>
#include "esp_http_server.h"

#define AP_SSID "@@SSID@@"
#define AP_PASS "@@PASS@@"

static SemaphoreHandle_t lock;
static uint8_t* shared = nullptr;
static size_t sharedLen = 0, sharedCap = 0;
static volatile uint32_t frameId = 0;
static bool camOk = false;
static char camErr[64] = "";

static void* bigAlloc(size_t n) { return psramFound() ? ps_malloc(n) : malloc(n); }

static bool camInit() {
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0;  c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = 15; c.pin_d1 = 17; c.pin_d2 = 18; c.pin_d3 = 16;
  c.pin_d4 = 14; c.pin_d5 = 12; c.pin_d6 = 11; c.pin_d7 = 48;
  c.pin_xclk = 10; c.pin_pclk = 13; c.pin_vsync = 38; c.pin_href = 47;
  c.pin_sccb_sda = 40; c.pin_sccb_scl = 39;
  c.pin_pwdn = -1; c.pin_reset = -1;
  c.xclk_freq_hz = 20000000;
  c.pixel_format = PIXFORMAT_JPEG;
  c.grab_mode = CAMERA_GRAB_LATEST;
  if (psramFound()) {
    c.frame_size = FRAMESIZE_@@SIZE@@; c.jpeg_quality = @@QUALITY@@; c.fb_count = 2; c.fb_location = CAMERA_FB_IN_PSRAM;
  } else {
    c.frame_size = FRAMESIZE_QVGA; c.jpeg_quality = 15; c.fb_count = 1; c.fb_location = CAMERA_FB_IN_DRAM;
  }
  esp_err_t e = esp_camera_init(&c);
  if (e != ESP_OK) { snprintf(camErr, sizeof camErr, "camera init failed 0x%x - check the camera board/ribbon", e); return false; }
  sensor_t* s = esp_camera_sensor_get();
  if (s && s->id.PID == OV3660_PID) { s->set_vflip(s, 1); s->set_brightness(s, 1); s->set_saturation(s, -2); }
  return true;
}

// capture task: always keeps the newest JPEG in 'shared'
static void captureTask(void*) {
  for (;;) {
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

// ---------- WiFi web page + MJPEG stream ----------
static const char PAGE[] =
  "<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
  "<title>XIAO CAM</title><style>body{margin:0;background:#000;color:#aaa;font-family:sans-serif;text-align:center}"
  "img{width:100%;max-width:1280px;display:block;margin:auto}</style></head><body>"
  "<img id=v alt='connecting...'><p>XIAO CAM</p>"
  "<script>document.getElementById('v').src='http://'+location.hostname+':81/stream';</script></body></html>";

static esp_err_t pageHandler(httpd_req_t* r) {
  httpd_resp_set_type(r, "text/html");
  return httpd_resp_send(r, PAGE, HTTPD_RESP_USE_STRLEN);
}

#define BOUNDARY "xcamframe"
static esp_err_t streamHandler(httpd_req_t* r) {
  httpd_resp_set_type(r, "multipart/x-mixed-replace;boundary=" BOUNDARY);
  httpd_resp_set_hdr(r, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(r, "Cache-Control", "no-cache");
  uint8_t* buf = nullptr; size_t cap = 0; uint32_t seen = 0; char hdr[100];
  for (;;) {
    size_t n = copyLatest(buf, cap, seen);
    if (!n) { vTaskDelay(5); continue; }
    int hl = snprintf(hdr, sizeof hdr, "\r\n--" BOUNDARY "\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n", (unsigned)n);
    if (httpd_resp_send_chunk(r, hdr, hl) != ESP_OK) break;
    if (httpd_resp_send_chunk(r, (const char*)buf, n) != ESP_OK) break;
  }
  free(buf);
  return ESP_FAIL;
}

static void startWeb() {
  httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
  httpd_handle_t page = nullptr, stream = nullptr;
  httpd_uri_t p = { "/", HTTP_GET, pageHandler, nullptr };
  if (httpd_start(&page, &cfg) == ESP_OK) httpd_register_uri_handler(page, &p);
  cfg.server_port = 81; cfg.ctrl_port += 1;
  httpd_uri_t s = { "/stream", HTTP_GET, streamHandler, nullptr };
  if (httpd_start(&stream, &cfg) == ESP_OK) httpd_register_uri_handler(stream, &s);
}

// ---------- USB-C ----------
static void sendPacket(const char* magic, const uint8_t* d, size_t n) {
  uint8_t h[8]; memcpy(h, magic, 4);
  h[4] = n; h[5] = n >> 8; h[6] = n >> 16; h[7] = n >> 24;
  Serial.write(h, 8); Serial.write(d, n);
}

void setup() {
  Serial.setTxBufferSize(16384);
  Serial.begin(921600);
  lock = xSemaphoreCreateMutex();
  camOk = camInit();
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  WiFi.setSleep(false);
  if (camOk) xTaskCreatePinnedToCore(captureTask, "cap", 4096, nullptr, 5, nullptr, 1);
  startWeb();
}

void loop() {
  static uint8_t* buf = nullptr; static size_t cap = 0; static uint32_t seen = 0;
  if (!Serial) { delay(50); return; }
  if (!camOk) { sendPacket("XMSG", (const uint8_t*)camErr, strlen(camErr)); delay(1000); return; }
  size_t n = copyLatest(buf, cap, seen);
  if (!n) { delay(2); return; }
  sendPacket("XCAM", buf, n);
}
'@

# ----------------------------------------------------------------------------
#  PC viewer: reads frames from the USB serial port
# ----------------------------------------------------------------------------
$ReaderCs = @'
using System; using System.IO.Ports; using System.Text; using System.Threading;
public class XCamReader {
  readonly string portName; SerialPort sp; Thread th; volatile bool running;
  readonly object lk = new object(); byte[] latest;
  public volatile string Status = "connecting...";
  public int FrameCount;
  public XCamReader(string p) { portName = p; }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { running = false; try { if (sp != null) sp.Close(); } catch { } }
  public byte[] Take() { lock (lk) { var b = latest; latest = null; return b; } }
  void Loop() {
    byte[] acc = new byte[4 * 1024 * 1024]; int len = 0; byte[] chunk = new byte[65536];
    while (running) {
      try {
        if (sp == null || !sp.IsOpen) {
          sp = new SerialPort(portName, 921600);
          sp.DtrEnable = true; sp.RtsEnable = false;
          sp.ReadTimeout = 3000; sp.ReadBufferSize = 1 << 20;
          sp.Open(); len = 0; Status = "waiting for pictures...";
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
          bool isMsg = acc[m + 1] == 0x4D;
          if (L <= 0 || L > 2000000 || (isMsg && L > 500) || (!isMsg && L < 100)) { pos = m + 1; continue; }
          if (len - m - 8 < L) { pos = m; break; }
          if (isMsg) {
            Status = "camera says: " + Encoding.ASCII.GetString(acc, m + 8, L); pos = m + 8 + L;
          } else if (acc[m + 8] == 0xFF && acc[m + 9] == 0xD8) {
            var f = new byte[L]; Buffer.BlockCopy(acc, m + 8, f, 0, L);
            lock (lk) { latest = f; }
            Interlocked.Increment(ref FrameCount); Status = "live"; pos = m + 8 + L;
          } else pos = m + 1;
        }
        if (pos > 0) { Buffer.BlockCopy(acc, pos, acc, 0, len - pos); len -= pos; }
      } catch (TimeoutException) {
        Status = "no pictures - is the XIAO-CAM firmware flashed? (option 1)";
      } catch (Exception e) {
        Status = "disconnected (" + e.Message.Trim() + ") - retrying...";
        try { if (sp != null) sp.Close(); } catch { }
        sp = null; Thread.Sleep(1000);
      }
    }
  }
  // "XCAM" or "XMSG"
  static int Find(byte[] a, int from, int len) {
    for (int i = from; i + 3 < len; i++)
      if (a[i] == 0x58 && ((a[i+1] == 0x43 && a[i+2] == 0x41 && a[i+3] == 0x4D) || (a[i+1] == 0x4D && a[i+2] == 0x53 && a[i+3] == 0x47))) return i;
    return -1;
  }
}
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
  $code = $Sketch.Replace('@@SSID@@', $Ssid).Replace('@@PASS@@', $Pass).Replace('@@SIZE@@', $FrameSize).Replace('@@QUALITY@@', [string]$Quality)
  [IO.File]::WriteAllText((Join-Path $SketchDir 'xiaocam.ino'), $code)
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

function Show-Viewer {
  $port = Wait-CamPort
  Say "Opening the viewer on $port  (close the window to stop)"
  Write-Host "   Phone: join WiFi '$Ssid' (password $Pass) and open http://192.168.4.1" -ForegroundColor White
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  if (-not ('XCamReader' -as [type])) { Add-Type -TypeDefinition $ReaderCs }
  $global:xr = New-Object XCamReader $port
  $xr.Start()

  $form = New-Object Windows.Forms.Form
  $form.Text = "XIAO CAM  -  $port"
  $form.Width = 820; $form.Height = 700
  $form.BackColor = [Drawing.Color]::Black
  $form.KeyPreview = $true
  $global:pb = New-Object Windows.Forms.PictureBox
  $pb.Dock = 'Fill'; $pb.SizeMode = 'Zoom'; $pb.BackColor = [Drawing.Color]::Black
  $global:lbl = New-Object Windows.Forms.Label
  $lbl.Dock = 'Bottom'; $lbl.Height = 26; $lbl.TextAlign = 'MiddleLeft'
  $lbl.ForeColor = [Drawing.Color]::White; $lbl.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
  $lbl.Font = New-Object Drawing.Font('Segoe UI', 9)
  $form.Controls.Add($pb); $form.Controls.Add($lbl)

  $global:sw = [Diagnostics.Stopwatch]::StartNew(); $global:lastCount = 0; $global:fps = 0
  $global:info = "Phone: WiFi '$Ssid' / $Pass -> http://192.168.4.1   |   S = save picture"
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 30
  $timer.Add_Tick({
    $b = $xr.Take()
    if ($b) {
      try {
        $ms = New-Object IO.MemoryStream(, $b)
        $tmp = [Drawing.Image]::FromStream($ms)
        $img = New-Object Drawing.Bitmap $tmp
        $tmp.Dispose(); $ms.Dispose()
        $old = $pb.Image; $pb.Image = $img
        if ($old) { $old.Dispose() }
      } catch { }
    }
    if ($sw.ElapsedMilliseconds -ge 1000) {
      $c = $xr.FrameCount; $global:fps = $c - $lastCount; $global:lastCount = $c; $sw.Restart()
    }
    $lbl.Text = "  $($xr.Status)   |   $fps fps   |   $info"
  })
  $form.Add_KeyDown({
    if ($_.KeyCode -eq 'S' -and $pb.Image) {
      $dir = Join-Path (Split-Path -Parent $env:XCAM_SELF) 'pictures'
      $f = Join-Path $dir ("xiao-cam-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".jpg")
      try { New-Item -ItemType Directory -Force $dir | Out-Null; $pb.Image.Save($f, [Drawing.Imaging.ImageFormat]::Jpeg) } catch { $global:info = "could not save: $($_.Exception.Message)"; return }
      $global:info = "saved $f"
    }
  })
  $form.Add_FormClosing({ $timer.Stop(); $xr.Stop() })
  $timer.Start()
  [void]$form.ShowDialog()
}

# ----------------------------------------------------------------------------
try {
  $mode = $env:XCAM_MODE
  if ($mode -eq 'menu') {
    Write-Host ""
    Write-Host "  XIAO-CAM  (Seeed XIAO ESP32S3 Sense)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1 = Install + build + flash, then watch   (first time)"
    Write-Host "  2 = Just watch on this PC (USB)"
    Write-Host ""
    $c = Read-Host "Choose 1 or 2 [1]"
    $mode = if ($c -eq '2') { 'view' } else { 'flash' }
  }
  switch ($mode) {
    'build' { Install-Tools; Build-Firmware }
    'flash' { Install-Tools; Build-Firmware; Flash-Firmware; Show-Viewer }
    'view'  { Show-Viewer }
    default { throw "unknown XCAM_MODE '$mode'" }
  }
} catch {
  Write-Host ""
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
