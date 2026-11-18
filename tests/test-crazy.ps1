# Headless test of crazy mode (USB + WiFi) on the demo camera. Run:  powershell -NoProfile -File tests\test-crazy.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
$cs = (@('studio.cs', 'crazy.cs', 'wifi.cs', 'update.cs') | ForEach-Object { [IO.File]::ReadAllText("$src\$_") }) -join "`n"
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Management, System.Web.Extensions, System.Windows.Forms, System.Net
$fail = 0
function Check($name, $ok) { if ($ok) { Write-Host "PASS $name" -ForegroundColor Green } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:fail++ } }

$out = Join-Path $env:TEMP ("crazytest-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$hub = New-Object XHub; $hub.Demo = $true
$hub.StartAll($out)
[void]$hub.Crazy.SetDir($out)
$t = 0; while (-not $hub.IsLive -and $t -lt 60) { Start-Sleep 1; $t++ }
Check 'demo camera live' $hub.IsLive
[void]$hub.Cmd('set brightness 1')     # base value that must come back after the run
Start-Sleep 1
$b = $hub.BoardJson | ConvertFrom-Json

function RunRound($mode) {
  $hub.Crazy.Mode = $mode; $hub.Crazy.Quick = $true; $hub.Crazy.MaxRounds = 1
  $hub.Crazy.Start()
  $t = 0; while ($hub.Crazy.Running -and $t -lt 240) { Start-Sleep 1; $t++ }
  Check "$mode round finished" (-not $hub.Crazy.Running)
  Check "$mode no error ($($hub.Crazy.Err))" ($hub.Crazy.Err -eq '')
  Start-Sleep 2
}

# ---- USB round ----
RunRound 'usb'
$rd = Get-ChildItem $out -Directory | Where-Object Name -notmatch 'wifi' | Select-Object -First 1
Check 'usb round folder' ($rd -and $rd.Name -match '_R001_(day|dim|night)$')
$r = Get-Content (Join-Path $rd.FullName 'round.json') -Raw | ConvertFrom-Json
$sweep = @($r.shots | Where-Object phase -eq 'sweep'); $mix = @($r.shots | Where-Object phase -eq 'mix')
Check "sweep clips = 8 ($($sweep.Count))" ($sweep.Count -eq 8)
Check "mix clips > 0 ($($mix.Count))" ($mix.Count -gt 0)
$missing = @($r.shots | Where-Object { -not (Test-Path (Join-Path $out $_.file)) -or -not (Test-Path (Join-Path $out $_.thumb)) -or -not (Test-Path (Join-Path $out $_.index)) })
Check 'all avi + index + thumbs exist' ($missing.Count -eq 0)
$s0 = $r.shots[0]; $ix = Get-Content (Join-Path $out $s0.index) -Raw | ConvertFrom-Json
Check "clip has frames ($($ix.frames.Count)) and fps ($($s0.scores.fps))" ($ix.frames.Count -ge 10 -and $s0.scores.fps -gt 5)
$bytes = [IO.File]::ReadAllBytes((Join-Path $out $s0.file)); $f0 = $ix.frames[0]
Check 'index offset points at a JPEG' ($bytes[[int]$f0[1]] -eq 0xFF -and $bytes[[int]$f0[1] + 1] -eq 0xD8)
$e50 = $r.shots | Where-Object label -eq 'exp0050'; $e1000 = $r.shots | Where-Object label -eq 'exp1000'
Check "manual exposure changes brightness ($($e50.scores.mean) < $($e1000.scores.mean))" ($e50.scores.mean -lt $e1000.scores.mean)
$vga = $r.shots | Where-Object { $_.group -eq 'resolution' -and $_.label -eq '640x480' }
$hd = $r.shots | Where-Object { $_.group -eq 'resolution' -and $_.label -eq '1280x720' }
Check "resolution really changed ($($vga.scores.w) / $($hd.scores.w))" ($vga.scores.w -eq 640 -and $hd.scores.w -eq 1280)
Check "fps higher at VGA ($($vga.scores.fps) > $($hd.scores.fps))" ($vga.scores.fps -gt $hd.scores.fps)

# ---- WiFi round (demo serves a simulated stream on 127.0.0.1:8181) ----
RunRound 'wifi'
$wd = Get-ChildItem $out -Directory | Where-Object Name -match '_wifi_' | Select-Object -First 1
Check 'wifi round folder' ($null -ne $wd)
$w = Get-Content (Join-Path $wd.FullName 'round.json') -Raw | ConvertFrom-Json
Check "wifi clips ($(@($w.shots).Count))" (@($w.shots).Count -ge 4)
$lat = @($w.shots | ForEach-Object { $_.scores.lat }); Check "delay measured (median of first: $($lat[0]) ms)" ($lat[0] -gt 0 -and $lat[0] -lt 3000)
$lo = $w.shots | Where-Object label -eq '02dBm'; $hi = $w.shots | Where-Object label -eq '21dBm'
Check "more WiFi power = more data ($($lo.scores.kbps) < $($hi.scores.kbps) KB/s)" ($lo.scores.kbps -lt $hi.scores.kbps)
Check 'usb video was off during wifi round' (@($w.shots | Where-Object { $_.set.usb -ne 0 }).Count -eq 0)

$a = $hub.BoardJson | ConvertFrom-Json
$diff = @('framesize', 'quality', 'aec', 'aec_value', 'brightness', 'agc', 'usb', 'tx_power') | Where-Object { $a.$_ -ne $b.$_ }
Check "base settings restored (diff: $($diff -join ','))" ($diff.Count -eq 0)

Check 'traversal refused' ($null -eq $hub.Crazy.SafeFile('..\..\Windows\win.ini') -and $null -eq $hub.Crazy.SafeFile('../x.jpg'))
Check 'real clip allowed' ($null -ne $hub.Crazy.SafeFile($r.shots[0].file))
Check 'rounds list' (($hub.Crazy.RoundsJson() | ConvertFrom-Json).rounds.Count -eq 2)
$hub.Crazy.Star($r.shots[0].file, $true)
Check 'star saved' (@($hub.Crazy.Stars()) -contains $r.shots[0].file)

$hub.Shutdown()
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'XiaoCam\studio.json') -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Green }