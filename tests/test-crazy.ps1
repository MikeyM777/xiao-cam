# Headless test of crazy mode on the demo camera. Run:  powershell -NoProfile -File tests\test-crazy.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
$cs = [IO.File]::ReadAllText("$src\studio.cs") + "`n" + [IO.File]::ReadAllText("$src\crazy.cs") + "`n" + [IO.File]::ReadAllText("$src\update.cs")
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Management, System.Web.Extensions, System.Windows.Forms
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
$before = $hub.BoardJson

$hub.Crazy.Quick = $true; $hub.Crazy.MaxRounds = 1
$hub.Crazy.Start()
$t = 0; while ($hub.Crazy.Running -and $t -lt 180) { Start-Sleep 1; $t++ }
Check 'round finished' (-not $hub.Crazy.Running)
Check 'no error' ($hub.Crazy.Err -eq '')
Start-Sleep 2

$rd = Get-ChildItem $out -Directory | Select-Object -First 1
Check 'round folder' ($rd -and $rd.Name -match '_R001_(day|dim|night)$')
$r = Get-Content (Join-Path $rd.FullName 'round.json') -Raw | ConvertFrom-Json
$sweep = @($r.shots | Where-Object phase -eq 'sweep'); $mix = @($r.shots | Where-Object phase -eq 'mix')
Check "sweep shots = 8 ($($sweep.Count))" ($sweep.Count -eq 8)
Check "mix shots > 0 ($($mix.Count))" ($mix.Count -gt 0)
$missing = @($r.shots | Where-Object { -not (Test-Path (Join-Path $out $_.file)) -or -not (Test-Path (Join-Path $out $_.thumb)) })
Check 'all jpg + thumbs exist' ($missing.Count -eq 0)
$e50 = $r.shots | Where-Object label -eq 'exp0050'; $e1000 = $r.shots | Where-Object label -eq 'exp1000'
Check "manual exposure changes brightness ($($e50.scores.mean) < $($e1000.scores.mean))" ($e50.scores.mean -lt $e1000.scores.mean)
$vga = $r.shots | Where-Object { $_.group -eq 'resolution' -and $_.label -eq '640x480' }
$hd = $r.shots | Where-Object { $_.group -eq 'resolution' -and $_.label -eq '1280x720' }
Check "resolution really changed ($($vga.scores.w) / $($hd.scores.w))" ($vga.scores.w -eq 640 -and $hd.scores.w -eq 1280)
Check "fps higher at VGA ($($vga.scores.fps) > $($hd.scores.fps))" ($vga.scores.fps -gt $hd.scores.fps)

$after = $hub.BoardJson | ConvertFrom-Json; $b = $before | ConvertFrom-Json
$diff = @('framesize', 'quality', 'aec', 'aec_value', 'brightness', 'agc') | Where-Object { $after.$_ -ne $b.$_ }
Check "base settings restored (diff: $($diff -join ','))" ($diff.Count -eq 0)

Check 'traversal refused' ($null -eq $hub.Crazy.SafeFile('..\..\Windows\win.ini') -and $null -eq $hub.Crazy.SafeFile('../x.jpg'))
Check 'real file allowed' ($null -ne $hub.Crazy.SafeFile($r.shots[0].file))
Check 'rounds list' (($hub.Crazy.RoundsJson() | ConvertFrom-Json).rounds.Count -eq 1)
$hub.Crazy.Star($r.shots[0].file, $true)
Check 'star saved' (@($hub.Crazy.Stars()) -contains $r.shots[0].file)

$hub.Shutdown()
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'XiaoCam\studio.json') -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Green }
