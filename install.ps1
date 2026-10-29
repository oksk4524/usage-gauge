# Builds UsageGauge with Windows' own C# compiler and installs it to %LOCALAPPDATA%\UsageGauge.
# powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Autostart | -Uninstall | -Package]
#   -Package  only builds dist\UsageGauge-Setup.exe, a single file to share (double-click installs it)
param([switch]$Autostart, [switch]$Uninstall, [switch]$Package)
$ErrorActionPreference = 'Stop'

$src  = Join-Path $PSScriptRoot 'UsageGauge.cs'
$dest = Join-Path $env:LOCALAPPDATA 'UsageGauge'
$exe  = Join-Path $dest 'UsageGauge.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Stop only the copy installed here, and wait until it has really exited (it holds the .exe open).
function Stop-Installed {
    $procs = @(Get-Process UsageGauge -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($exe)) } catch { $false } })
    foreach ($p in $procs) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
        if (-not $p.WaitForExit(2000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(20000) | Out-Null }
    }
}

if ($Uninstall) {
    Stop-Installed
    # remove the autostart entry only if it points at this install
    $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).UsageGauge
    if ($run -and ($run.Trim('"') -ieq $exe)) { Remove-ItemProperty $runKey -Name UsageGauge -ErrorAction SilentlyContinue }
    Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UsageGauge' -Recurse -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'UsageGauge dashboard refresh' -Confirm:$false -ErrorAction SilentlyContinue   # set up by tools\usage-insights-collector\install-dashboard.ps1   # left by the setup file
    for ($i = 0; $i -lt 10 -and (Test-Path $dest); $i++) {
        try { Remove-Item $dest -Recurse -Force } catch { Start-Sleep -Milliseconds 500 }
    }
    if (Test-Path $dest) { throw "Could not delete $dest (a file is still in use). Close it and run -Uninstall again." }
    Write-Host 'UsageGauge removed.'
    return
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '.NET Framework 4 C# compiler (csc.exe) not found.' }

# Logos, NOTICE and LICENSE are embedded, so the .exe works on its own.
function Build($out) {
    $res = @(Get-ChildItem (Join-Path $PSScriptRoot 'assets') -Filter *.png | ForEach-Object { "/resource:$($_.FullName),$($_.Name)" })
    $res += "/resource:$(Join-Path $PSScriptRoot 'NOTICE'),NOTICE", "/resource:$(Join-Path $PSScriptRoot 'LICENSE'),LICENSE"
    & $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$out" "/win32icon:$(Join-Path $PSScriptRoot 'assets\app.ico')" @res `
        /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $src | Out-Host   # compiler messages must not become part of the return value (that made a failed build look successful)
    return $LASTEXITCODE -eq 0
}

if ($Package) {
    $dist = Join-Path $PSScriptRoot 'dist'; New-Item -ItemType Directory $dist -Force | Out-Null
    $setup = Join-Path $dist 'UsageGauge-Setup.exe'
    if (-not (Build $setup)) { throw 'Build failed.' }
    Write-Host "Built $setup"
    return
}

New-Item -ItemType Directory $dest -Force | Out-Null

# Build next to the running copy first; only swap it in if the build succeeded.
$tmpExe = Join-Path $dest 'UsageGauge.build.exe'
if (-not (Build $tmpExe)) { Remove-Item $tmpExe -ErrorAction SilentlyContinue; throw 'Build failed; the installed copy was left untouched.' }

Stop-Installed
Copy-Item (Join-Path $PSScriptRoot 'NOTICE') $dest -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $PSScriptRoot 'LICENSE') $dest -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) {
    try { Move-Item $tmpExe $exe -Force; break } catch { if ($i -eq 19) { throw "Could not replace $exe (still in use)." }; Start-Sleep -Milliseconds 500 }
}

if ($Autostart) { Set-ItemProperty $runKey -Name UsageGauge -Value "`"$exe`"" }
Start-Process $exe
Write-Host "Installed to $dest"
