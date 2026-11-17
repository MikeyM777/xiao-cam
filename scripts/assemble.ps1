$s = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'src'
$m = [IO.File]::ReadAllText("$s\main.ps1")
$parts = @{ FW = 'fw.ino'; CS = 'studio.cs'; HTML = 'ui.html' }
foreach ($k in $parts.Keys) {
  $c = [IO.File]::ReadAllText("$s\$($parts[$k])").TrimEnd()
  if ($c -match "(?m)^'@") { throw "bad $k" }
  $m = $m.Replace("##$k##", $c)
}
$m = ($m -replace "`r`n", "`n") -replace "`n", "`r`n"
if (($m.ToCharArray() | Where-Object { [int]$_ -gt 126 }).Count) { throw "non-ascii" }
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $s) 'XIAO-CAM-STUDIO.bat'), $m, [Text.Encoding]::ASCII)
"assembled"