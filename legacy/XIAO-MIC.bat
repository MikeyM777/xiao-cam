<# : XIAO-MIC - one file: installs tools, builds, flashes, records the microphone.
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
#  XIAO-MIC  -  microphone test for the Seeed XIAO ESP32S3 Sense
#   1. Downloads arduino-cli + the ESP32 core (first run only, ~1 GB, needs internet)
#   2. Builds the mic firmware below and flashes it over USB-C (camera is NOT used)
#   3. Opens a recorder on this PC: Record / Stop, as long as you want.
#      Each recording is saved as a WAV in the 'recordings' folder next to this file.
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Rate = 16000                 # sample rate (Hz): 16000, 24000, 32000, 44100 or 48000

$Data      = Join-Path $env:LOCALAPPDATA 'XiaoCam'     # same tools as XIAO-CAM.bat
$CliDir    = Join-Path $Data 'arduino-cli'
$Cli       = Join-Path $CliDir 'arduino-cli.exe'
$SketchDir = Join-Path $Data 'xiaomic'
$BuildDir  = Join-Path $Data 'build_mic'
$Fqbn      = 'esp32:esp32:XIAO_ESP32S3:PSRAM=opi,USBMode=hwcdc,CDCOnBoot=default'
$OutDir    = Join-Path (Split-Path -Parent $env:XCAM_SELF) 'recordings'   # next to this file (Music/Documents may be blocked by Defender)

$env:ARDUINO_DIRECTORIES_DATA      = Join-Path $Data 'arduino15'
$env:ARDUINO_DIRECTORIES_DOWNLOADS = Join-Path $Data 'staging'
$env:ARDUINO_DIRECTORIES_USER      = Join-Path $Data 'user'
$env:ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS = 'https://espressif.github.io/arduino-esp32/package_esp32_index.json'

function Say($m)  { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }
function Run-Arduino { & $Cli @args; if ($LASTEXITCODE -ne 0) { throw "arduino-cli $($args -join ' ') failed (exit $LASTEXITCODE)" } }

# ----------------------------------------------------------------------------
#  Mic firmware: PDM mic (CLK GPIO42, DATA GPIO41) -> USB as "XAUD"+len+PCM16
# ----------------------------------------------------------------------------
$Sketch = @'
#include <ESP_I2S.h>
#define RATE @@RATE@@
I2SClass i2s;
static bool ok = false;

static void sendPacket(const char* magic, const uint8_t* d, size_t n) {
  uint8_t h[8]; memcpy(h, magic, 4);
  h[4] = n; h[5] = n >> 8; h[6] = n >> 16; h[7] = n >> 24;
  Serial.write(h, 8); Serial.write(d, n);
}

void setup() {
  Serial.setTxBufferSize(16384);
  Serial.begin(921600);
  i2s.setPinsPdmRx(42, 41);
  ok = i2s.begin(I2S_MODE_PDM_RX, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
}

void loop() {
  static uint8_t buf[1920];
  if (!ok) {
    const char* m = "microphone init failed - is the Sense board attached?";
    if (Serial) sendPacket("XMSG", (const uint8_t*)m, strlen(m));
    delay(1000); return;
  }
  size_t n = i2s.readBytes((char*)buf, sizeof buf);   // always read, so the mic never stalls
  if (n && Serial) sendPacket("XAUD", buf, n);
}
'@

# ----------------------------------------------------------------------------
#  PC side: reads audio packets from the USB serial port
# ----------------------------------------------------------------------------
$ReaderCs = @'
using System; using System.IO; using System.IO.Ports; using System.Text; using System.Threading;
public class XMicReader {
  readonly string portName; SerialPort sp; Thread th; volatile bool running;
  readonly object lk = new object(); MemoryStream rec;
  public volatile string Status = "connecting...";
  public volatile bool Recording;
  public volatile float Level;        // peak of the last ~0.1 s, 0..1
  public long TotalBytes;
  public XMicReader(string p) { portName = p; }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { running = false; try { if (sp != null) sp.Close(); } catch { } }
  public void BeginRec() { lock (lk) { rec = new MemoryStream(); Recording = true; } }
  public byte[] EndRec() { lock (lk) { Recording = false; var b = rec == null ? new byte[0] : rec.ToArray(); rec = null; return b; } }
  public long RecBytes { get { lock (lk) { return rec == null ? 0 : rec.Length; } } }
  void Loop() {
    byte[] acc = new byte[1024 * 1024]; int len = 0; byte[] chunk = new byte[65536];
    float peak = 0; int peakSamples = 0;
    while (running) {
      try {
        if (sp == null || !sp.IsOpen) {
          sp = new SerialPort(portName, 921600);
          sp.DtrEnable = true; sp.RtsEnable = false;
          sp.ReadTimeout = 3000; sp.ReadBufferSize = 1 << 20;
          sp.Open(); len = 0; Status = "waiting for sound...";
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
          if (L <= 0 || L > 65536 || (isMsg && L > 500) || (!isMsg && (L & 1) == 1)) { pos = m + 1; continue; }
          if (len - m - 8 < L) { pos = m; break; }
          if (isMsg) {
            Status = "board says: " + Encoding.ASCII.GetString(acc, m + 8, L);
          } else {
            lock (lk) { if (Recording && rec != null) rec.Write(acc, m + 8, L); }
            TotalBytes += L;
            for (int i = m + 8; i + 1 < m + 8 + L; i += 2) {
              short s = (short)(acc[i] | (acc[i + 1] << 8));
              float a = Math.Abs(s / 32768f); if (a > peak) peak = a;
            }
            peakSamples += L / 2;
            if (peakSamples >= 4800) { Level = peak; peak = 0; peakSamples = 0; }
            Status = "live";
          }
          pos = m + 8 + L;
        }
        if (pos > 0) { Buffer.BlockCopy(acc, pos, acc, 0, len - pos); len -= pos; }
      } catch (TimeoutException) {
        Status = "no sound data - is the XIAO-MIC firmware flashed? (option 1)";
      } catch (Exception e) {
        if (!running) break;
        Status = "disconnected (" + e.Message.Trim() + ") - retrying...";
        try { if (sp != null) sp.Close(); } catch { }
        sp = null; Thread.Sleep(1000);
      }
    }
  }
  // "XAUD" or "XMSG"
  static int Find(byte[] a, int from, int len) {
    for (int i = from; i + 3 < len; i++)
      if (a[i] == 0x58 && ((a[i+1] == 0x41 && a[i+2] == 0x55 && a[i+3] == 0x44) || (a[i+1] == 0x4D && a[i+2] == 0x53 && a[i+3] == 0x47))) return i;
    return -1;
  }
  public static void SaveWav(string path, byte[] pcm, int rate) {
    using (var f = new BinaryWriter(File.Create(path))) {
      f.Write(Encoding.ASCII.GetBytes("RIFF")); f.Write(36 + pcm.Length);
      f.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); f.Write(16); f.Write((short)1); f.Write((short)1);
      f.Write(rate); f.Write(rate * 2); f.Write((short)2); f.Write((short)16);
      f.Write(Encoding.ASCII.GetBytes("data")); f.Write(pcm.Length); f.Write(pcm);
    }
  }
  // peak dBFS, RMS dBFS, DC offset
  public static string Stats(byte[] pcm) {
    int n = pcm.Length / 2; if (n == 0) return "empty";
    double sum = 0, sq = 0; int pk = 0;
    for (int i = 0; i < n; i++) { short s = (short)(pcm[2*i] | (pcm[2*i+1] << 8)); sum += s; int a = Math.Abs((int)s); if (a > pk) pk = a; }
    double mean = sum / n;
    for (int i = 0; i < n; i++) { short s = (short)(pcm[2*i] | (pcm[2*i+1] << 8)); double d = s - mean; sq += d * d; }
    double rms = Math.Sqrt(sq / n);
    Func<double, string> db = v => v <= 0 ? "-inf" : (20 * Math.Log10(v / 32768.0)).ToString("0.0");
    return "peak " + db(pk) + " dBFS, RMS " + db(rms) + " dBFS, DC " + mean.ToString("0");
  }
}
'@

# ----------------------------------------------------------------------------
function Get-BoardPort {
  $all = @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'")
  foreach ($d in $all) {
    if ($d.PNPDeviceID -match 'VID_303A|VID_2886' -and $d.Name -match '\((COM\d+)\)') { return $Matches[1] }
  }
  return $null
}

function Wait-BoardPort {
  $p = Get-BoardPort
  if ($p) { return $p }
  Warn "XIAO not found. Plug it in with a USB-C DATA cable (not a charge-only cable)."
  Warn "Still nothing? Hold the tiny BOOT button (B), plug in, then let go."
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 1
    $p = Get-BoardPort
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
    New-Item -ItemType Directory -Force $Data | Out-Null
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
  Say "Building the microphone firmware"
  New-Item -ItemType Directory -Force $SketchDir, $BuildDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $SketchDir 'xiaomic.ino'), $Sketch.Replace('@@RATE@@', [string]$Rate))
  Run-Arduino compile --fqbn $Fqbn --output-dir $BuildDir $SketchDir
  Ok "build OK"
}

function Flash-Firmware {
  $port = Wait-BoardPort
  Say "Flashing to $port (do not unplug; close any other XIAO window first)"
  & $Cli upload -p $port --fqbn $Fqbn --input-dir $BuildDir $SketchDir
  if ($LASTEXITCODE -ne 0) {
    Warn "Flash failed. Close the XIAO-CAM / XIAO-MIC window if one is open."
    Warn "Still failing? Unplug the XIAO, HOLD the BOOT button (B), plug it back in, let go."
    Read-Host "Then press Enter to try again"
    $port = Wait-BoardPort
    & $Cli upload -p $port --fqbn $Fqbn --input-dir $BuildDir $SketchDir
    if ($LASTEXITCODE -ne 0) { throw "flash failed twice" }
    Warn "If you used the BOOT button: press the RESET button (R) or unplug/replug once now."
  }
  Ok "flashed. Board restarts..."
  Start-Sleep -Seconds 4
}

function Load-Reader { if (-not ('XMicReader' -as [type])) { Add-Type -TypeDefinition $ReaderCs } }

function Show-Recorder {
  $port = Wait-BoardPort
  Say "Opening the recorder on $port  (close the window to stop)"
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  Load-Reader
  $global:mr = New-Object XMicReader $port
  $mr.Start()
  $global:lastWav = $null

  $form = New-Object Windows.Forms.Form
  $form.Text = "XIAO MIC  -  $port  -  $Rate Hz"
  $form.Width = 520; $form.Height = 300; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
  $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 30); $form.ForeColor = [Drawing.Color]::White
  $font = New-Object Drawing.Font('Segoe UI', 11)

  $global:btnRec = New-Object Windows.Forms.Button
  $btnRec.Text = "Record"; $btnRec.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
  $btnRec.SetBounds(20, 20, 150, 60); $btnRec.BackColor = [Drawing.Color]::FromArgb(170, 30, 30); $btnRec.FlatStyle = 'Flat'
  $global:btnPlay = New-Object Windows.Forms.Button
  $btnPlay.Text = "Play last"; $btnPlay.Font = $font; $btnPlay.SetBounds(185, 20, 140, 60); $btnPlay.FlatStyle = 'Flat'; $btnPlay.Enabled = $false
  $btnDir = New-Object Windows.Forms.Button
  $btnDir.Text = "Open folder"; $btnDir.Font = $font; $btnDir.SetBounds(340, 20, 140, 60); $btnDir.FlatStyle = 'Flat'

  $global:lblTime = New-Object Windows.Forms.Label
  $lblTime.Font = New-Object Drawing.Font('Consolas', 22); $lblTime.SetBounds(20, 95, 200, 40); $lblTime.Text = "00:00"
  $global:meter = New-Object Windows.Forms.ProgressBar
  $meter.SetBounds(230, 105, 250, 22); $meter.Maximum = 100
  $global:lblInfo = New-Object Windows.Forms.Label
  $lblInfo.Font = New-Object Drawing.Font('Segoe UI', 9); $lblInfo.SetBounds(20, 145, 470, 70)
  $global:lblStatus = New-Object Windows.Forms.Label
  $lblStatus.Font = New-Object Drawing.Font('Segoe UI', 9); $lblStatus.SetBounds(20, 225, 470, 22); $lblStatus.ForeColor = [Drawing.Color]::Silver
  $lblInfo.Text = "Press Record, talk, press Stop. The WAV is saved to`n$OutDir and played back."
  $form.Controls.AddRange(@($btnRec, $btnPlay, $btnDir, $lblTime, $meter, $lblInfo, $lblStatus))

  $global:player = $null
  $btnRec.Add_Click({
    if (-not $mr.Recording) {
      if ($player) { $player.Stop() }
      $mr.BeginRec()
      $btnRec.Text = "Stop"; $btnRec.BackColor = [Drawing.Color]::FromArgb(70, 70, 70)
      $lblInfo.Text = "Recording... talk, clap, play music. Press Stop when done."
    } else {
      $pcm = $mr.EndRec()
      $btnRec.Text = "Record"; $btnRec.BackColor = [Drawing.Color]::FromArgb(170, 30, 30)
      if ($pcm.Length -lt 2) { $lblInfo.Text = "Nothing recorded - is the status line 'live'?"; return }
      $f = Join-Path $OutDir ("xiao-mic-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".wav")
      try { New-Item -ItemType Directory -Force $OutDir | Out-Null; [XMicReader]::SaveWav($f, $pcm, $Rate) }
      catch { $lblInfo.Text = "Could not save to $OutDir
$($_.Exception.Message)"; return }
      $global:lastWav = $f; $btnPlay.Enabled = $true
      $sec = [math]::Round($pcm.Length / 2 / $Rate, 1)
      $lblInfo.Text = "Saved $sec s:  $f`n$([XMicReader]::Stats($pcm))`nPlaying it back now..."
      $global:player = New-Object Media.SoundPlayer $f
      $player.Play()
    }
  })
  $btnPlay.Add_Click({ if ($lastWav) { if ($player) { $player.Stop() }; $global:player = New-Object Media.SoundPlayer $lastWav; $player.Play() } })
  $btnDir.Add_Click({ New-Item -ItemType Directory -Force $OutDir | Out-Null; Start-Process explorer.exe $OutDir })

  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 100
  $timer.Add_Tick({
    $lv = $mr.Level
    $db = if ($lv -gt 0) { 20 * [math]::Log10($lv) } else { -60 }
    $meter.Value = [int][math]::Max(0, [math]::Min(100, ($db + 60) * 100 / 60))
    if ($mr.Recording) {
      $s = [int]($mr.RecBytes / 2 / $Rate)
      $lblTime.Text = "{0:00}:{1:00}" -f [int][math]::Floor($s / 60), ($s % 60)
      $lblTime.ForeColor = [Drawing.Color]::FromArgb(255, 90, 90)
    } else { $lblTime.ForeColor = [Drawing.Color]::White }
    $lblStatus.Text = "$($mr.Status)   |   level $([math]::Round($db,0)) dBFS"
  })
  $form.Add_FormClosing({ $timer.Stop(); if ($player) { $player.Stop() }; $mr.Stop() })
  $timer.Start()
  [void]$form.ShowDialog()
}

# headless check: record a few seconds, save, print stats
function Test-Recording($sec) {
  $port = Wait-BoardPort
  Load-Reader
  $r = New-Object XMicReader $port
  $r.Start(); Start-Sleep -Seconds 2
  $r.BeginRec(); Start-Sleep -Seconds $sec; $pcm = $r.EndRec()
  $st = $r.Status; $r.Stop()
  $f = Join-Path $env:TEMP 'xiao-mic-selftest.wav'
  [XMicReader]::SaveWav($f, $pcm, $Rate)
  Write-Host "status: $st"
  Write-Host ("got {0:0.00} s of audio for {1} s of wall time  ({2})" -f ($pcm.Length / 2 / $Rate), $sec, [XMicReader]::Stats($pcm))
  Write-Host "saved $f"
}

# ----------------------------------------------------------------------------
try {
  $mode = $env:XCAM_MODE
  if ($mode -eq 'menu') {
    Write-Host ""
    Write-Host "  XIAO-MIC  (Seeed XIAO ESP32S3 Sense microphone test)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1 = Install + build + flash, then record   (first time)"
    Write-Host "  2 = Just record (firmware already flashed)"
    Write-Host ""
    $c = Read-Host "Choose 1 or 2 [1]"
    $mode = if ($c -eq '2') { 'view' } else { 'flash' }
  }
  switch ($mode) {
    'build'    { Install-Tools; Build-Firmware }
    'flash'    { Install-Tools; Build-Firmware; Flash-Firmware; Show-Recorder }
    'view'     { Show-Recorder }
    'selftest' { Test-Recording 5 }
    default    { throw "unknown XCAM_MODE '$mode'" }
  }
} catch {
  Write-Host ""
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
