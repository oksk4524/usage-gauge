# Builds UsageGauge with the C# compiler that ships with Windows (.NET Framework 4)
# and installs it to %LOCALAPPDATA%\UsageGauge.
#   -Autostart   also start it at sign-in
#   -Uninstall   stop it, remove autostart and delete %LOCALAPPDATA%\UsageGauge
# Run with:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
param([switch]$Autostart, [switch]$Uninstall)
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
        if (-not $p.WaitForExit(2000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(5000) | Out-Null }
    }
}

if ($Uninstall) {
    Stop-Installed
    # remove the autostart entry only if it points at this install
    $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).UsageGauge
    if ($run -and ($run.Trim('"') -ieq $exe)) { Remove-ItemProperty $runKey -Name UsageGauge -ErrorAction SilentlyContinue }
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

New-Item -ItemType Directory $dest -Force | Out-Null

# Build next to the running copy first; only swap it in if the build succeeded.
$tmpExe = Join-Path $dest 'UsageGauge.build.exe'
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$tmpExe" `
    /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $src
if ($LASTEXITCODE -ne 0) { Remove-Item $tmpExe -ErrorAction SilentlyContinue; throw 'Build failed; the installed copy was left untouched.' }

Stop-Installed
Copy-Item (Join-Path $PSScriptRoot 'assets\*') $dest -Force
Copy-Item (Join-Path $PSScriptRoot 'NOTICE') $dest -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $PSScriptRoot 'LICENSE') $dest -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 10; $i++) {
    try { Move-Item $tmpExe $exe -Force; break } catch { if ($i -eq 9) { throw "Could not replace $exe (still in use)." }; Start-Sleep -Milliseconds 500 }
}

if ($Autostart) { Set-ItemProperty $runKey -Name UsageGauge -Value "`"$exe`"" }
Start-Process $exe
Write-Host "Installed to $dest"
