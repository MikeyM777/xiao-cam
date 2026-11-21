# Headless test of the link test (USB + WiFi) on the demo camera. Run:  powershell -NoProfile -File tests\test-link.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
$cs = (@('studio.cs', 'crazy.cs', 'wifi.cs', 'link.cs', 'update.cs') | ForEach-Object { [IO.File]::ReadAllText("$src\$_") }) -join "`n"
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Management, System.Web.Extensions, System.Windows.Forms, System.Net
$fail = 0
function Check($name, $ok) { if ($ok) { Write-Host "PASS $name" -ForegroundColor Green } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:fail++ } }

$out = Join-Path $env:TEMP ("linktest-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$hub = New-Object XHub; $hub.Demo = $true; $hub.TestsDir = Join-Path $out 'link-tests'
$hub.StartAll((Join-Path $out 'crazy'))
$t = 0; while (-not $hub.IsLive -and $t -lt 90) { Start-Sleep 1; $t++ }
Check 'demo camera live' $hub.IsLive

function List { @(($hub.Test.ListJson() | ConvertFrom-Json) | ForEach-Object { $_ }) }
function RunTest($ant) {
  Start-Sleep 3
  $hub.Test.Start(5, $ant, "note $ant")
  $t = 0; while ($hub.Test.Running -and $t -lt 60) { Start-Sleep 1; $t++ }
  Check "test finished (err '$($hub.Test.Err)')" (-not $hub.Test.Running -and $hub.Test.Err -eq '')
  return (List)[0]
}

# ---- USB ----
$u = RunTest ''
Check "usb result: link=$($u.link) frames=$($u.frames) fps=$($u.fps)" ($u.link -eq 'usb' -and $u.frames -gt 20 -and $u.fps -gt 5)
Check "usb delay measured ($($u.lat) ms)" ($u.lat -ge 0 -and $u.lat -lt 200)
Check "usb delivered ($($u.delivered)%)" ($u.delivered -gt 50)
Check 'usb avi + thumb saved' ((Test-Path (Join-Path $hub.TestsDir "$($u.id).avi")) -and (Test-Path (Join-Path $hub.TestsDir "$($u.id).jpg")))
$avi = [IO.File]::ReadAllBytes((Join-Path $hub.TestsDir "$($u.id).avi"))
Check 'avi header' ([Text.Encoding]::ASCII.GetString($avi, 0, 4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($avi, 8, 4) -eq 'AVI ')

# ---- WiFi ----
$hub.LinkMgr.SetMode('wifi')
$t = 0; while ($t -lt 30) { Start-Sleep 1; $t++; if ($hub.IsLive -and $hub.LinkMgr.WifiFrames -gt 10) { break } }
Check "wifi video arrives ($($hub.LinkMgr.WifiFrames) frames, $($hub.LinkMgr.Status))" ($hub.LinkMgr.WifiFrames -gt 10)
$b = $hub.BoardJson | ConvertFrom-Json
Check 'usb video switched off for wifi' ($b.usb -eq 0)
$w = RunTest 'no'
Check "wifi result: link=$($w.link) antenna=$($w.antenna) frames=$($w.frames)" ($w.link -eq 'wifi' -and $w.antenna -eq 'no' -and $w.frames -gt 5)
Check "wifi delay measured ($($w.lat) ms)" ($w.lat -gt 0 -and $w.lat -lt 3000)
Check "wifi id names it ($($w.id))" ($w.id -match '_wifi-no-antenna$')
Check "note kept ($($w.note))" ($w.note -eq 'note no')

# ---- back to USB ----
$hub.LinkMgr.SetMode('usb')
Start-Sleep 4
$b = $hub.BoardJson | ConvertFrom-Json
Check 'usb video back on' ($b.usb -eq 1)
Check 'usb live again' $hub.IsLive

# ---- list / rename / delete / safety ----
Check 'two results' (@(List).Count -eq 2)
$hub.Test.Rename($u.id, 'renamed')
Check 'rename' (((List) | Where-Object id -eq $u.id).note -eq 'renamed')
$hub.Test.Delete($u.id)
$lc = @(List).Count; $ex = Test-Path (Join-Path $hub.TestsDir "$($u.id).avi")
Check "delete removes row + files (rows $lc, avi left $ex)" ($lc -eq 1 -and -not $ex)
Check 'traversal refused' ($null -eq $hub.Test.FileFor('..\..\x', '.avi') -and $null -eq $hub.Test.FileFor('a/b/c/d', '.jpg'))
$threw = $false; try { $hub.Test.Delete('..\evil') } catch { $threw = $true }; Check 'bad id delete refused' $threw

$hub.Shutdown()
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'XiaoCam\studio.json') -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Green }
