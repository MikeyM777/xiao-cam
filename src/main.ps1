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

$StudioVersion   = '2.2.0'      # bump on every release (Update button compares this)
$FirmwareVersion = '2.1'        # bump when the sketch below changes (Studio then asks to flash)
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
##FW##
'@

# ----------------------------------------------------------------------------
#  PC side: USB reader, recorder, local web server (C#)
# ----------------------------------------------------------------------------
$StudioCs = @'
##CS##
'@

# ----------------------------------------------------------------------------
#  Studio web page
# ----------------------------------------------------------------------------
$Html = @'
##HTML##
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
