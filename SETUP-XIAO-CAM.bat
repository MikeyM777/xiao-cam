<# : SETUP-XIAO-CAM - moves the XIAO CAM files from Downloads into C:\XiaoCam and makes a desktop shortcut.
@echo off
setlocal
set "XSETUP_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:XSETUP_SELF))"
echo.
pause
exit /b
#>

$ErrorActionPreference = 'Stop'
$Home2 = if ($env:XSETUP_HOME) { $env:XSETUP_HOME } else { 'C:\XiaoCam' }
function Ok($m)   { Write-Host "   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }

try {
  Write-Host ""
  Write-Host "  XIAO CAM setup  ->  $Home2" -ForegroundColor Cyan
  Write-Host ""

  # where downloads land (normal Downloads + Telegram Desktop's own subfolder)
  $dl = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
  if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
  if ($env:XSETUP_DL) { $dl = $env:XSETUP_DL }
  $places = @($dl, (Join-Path $dl 'Telegram Desktop'), (Split-Path -Parent $env:XSETUP_SELF)) | Select-Object -Unique | Where-Object { Test-Path $_ }

  # folders
  foreach ($d in @($Home2, "$Home2\videos", "$Home2\pictures", "$Home2\recordings", "$Home2\old")) { New-Item -ItemType Directory -Force $d | Out-Null }

  # newest copy of each file wins (Telegram names repeats like "XIAO-CAM-STUDIO (1).bat")
  $wanted = @(
    @{ Pattern = 'XIAO-CAM-STUDIO*.bat'; Target = 'XIAO-CAM-STUDIO.bat' },
    @{ Pattern = 'XIAO-CAM.bat';         Target = 'old\XIAO-CAM.bat' },
    @{ Pattern = 'XIAO-CAM (*.bat';      Target = 'old\XIAO-CAM.bat' },
    @{ Pattern = 'XIAO-MIC*.bat';        Target = 'XIAO-MIC.bat' }
  )
  $found = 0
  foreach ($w in $wanted) {
    $files = @(foreach ($p in $places) { Get-ChildItem -Path $p -Filter $w.Pattern -File -ErrorAction SilentlyContinue })
    if (-not $files.Count) { continue }
    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $dest = Join-Path $Home2 $w.Target
    Unblock-File $newest.FullName -ErrorAction SilentlyContinue
    Copy-Item $newest.FullName $dest -Force
    foreach ($f in $files) { if ($f.DirectoryName -ne $Home2) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } }
    Ok "$($newest.Name)  ->  $dest"
    $found++
  }

  # loose pictures/videos/wav from older runs, if they were next to the bats in Downloads
  foreach ($p in $places) {
    foreach ($sub in 'videos', 'pictures', 'recordings') {
      $src = Join-Path $p $sub
      if ((Test-Path $src) -and ($src -ne "$Home2\$sub")) {
        Get-ChildItem $src -File | ForEach-Object { Move-Item $_.FullName "$Home2\$sub\" -Force }
        Ok "moved old $sub from $p"
      }
    }
  }

  if (-not (Test-Path "$Home2\XIAO-CAM-STUDIO.bat")) {
    throw "XIAO-CAM-STUDIO.bat not found in $($places -join ' or '). Download it from Telegram first, then run this again."
  }

  # desktop shortcut
  $desk = if ($env:XSETUP_DESK) { $env:XSETUP_DESK } else { [Environment]::GetFolderPath('Desktop') }
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut((Join-Path $desk 'XIAO CAM Studio.lnk'))
  $lnk.TargetPath = "$Home2\XIAO-CAM-STUDIO.bat"
  $lnk.WorkingDirectory = $Home2
  $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,203"
  $lnk.Save()
  Ok "desktop shortcut: XIAO CAM Studio"

  Write-Host ""
  Write-Host "  Done. Everything is in $Home2" -ForegroundColor Cyan
  Write-Host "     XIAO-CAM-STUDIO.bat   the camera studio (double-click, or the desktop shortcut)"
  Write-Host "     videos\  pictures\    what you record / snap"
  Write-Host ""
  $go = Read-Host "Start the studio now? First time choose 1 there (flash). [Y/n]"
  if ($go -notmatch '^[nN]') {
    Start-Process -FilePath "$Home2\XIAO-CAM-STUDIO.bat" -WorkingDirectory $Home2
  }
} catch {
  Write-Host ""
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
