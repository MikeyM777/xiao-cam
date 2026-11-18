$s = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'src'
$m = [IO.File]::ReadAllText("$s\main.ps1")
$parts = @{ FW = @('fw.ino'); CS = @('studio.cs', 'crazy.cs', 'wifi.cs', 'update.cs'); HTML = @('ui.html') }
foreach ($k in $parts.Keys) {
  $c = (($parts[$k] | ForEach-Object { [IO.File]::ReadAllText("$s\$_").TrimEnd() }) -join "`n`n")
  if ($k -eq 'HTML') { $c = $c.Replace('<!--CRAZY-->', [IO.File]::ReadAllText("$s\crazy.html").TrimEnd()) }
  if ($c -match "(?m)^'@") { throw "bad $k" }
  $m = $m.Replace("##$k##", $c)
}
$m = ($m -replace "`r`n", "`n") -replace "`n", "`r`n"
if (($m.ToCharArray() | Where-Object { [int]$_ -gt 126 }).Count) { throw "non-ascii" }
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $s) 'XIAO-CAM-STUDIO.bat'), $m, [Text.Encoding]::ASCII)
"assembled"
$sv = [regex]::Match($m, "\`$StudioVersion\s*=\s*'([^']+)'").Groups[1].Value
$fv = [regex]::Match($m, "\`$FirmwareVersion\s*=\s*'([^']+)'").Groups[1].Value
$notes = if (Test-Path "$s\..\NOTES.txt") { (Get-Content "$s\..\NOTES.txt" -Raw).Trim() } else { '' }
@{ studio = $sv; firmware = $fv; notes = $notes } | ConvertTo-Json | Set-Content (Join-Path (Split-Path -Parent $s) 'version.json') -Encoding ASCII
"version $sv / firmware $fv"