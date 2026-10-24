# Builds UsageGauge with the C# compiler that ships with Windows (.NET Framework 4)
# and installs it to %LOCALAPPDATA%\UsageGauge.
#   -Autostart   also start it at sign-in
#   -Uninstall   stop it, remove autostart and delete %LOCALAPPDATA%\UsageGauge
# Run with:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
param([switch]$Autostart, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$src  = Join-Path $PSScriptRoot 'UsageGauge.cs'
$dest = Join-Path $env:LOCALAPPDATA 'UsageGauge'

if ($Uninstall) {
    Get-Process UsageGauge -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name UsageGauge -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'UsageGauge removed.'
    return
}
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

New-Item -ItemType Directory $dest -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'assets\*') $dest -Force

Get-Process UsageGauge -ErrorAction SilentlyContinue | Stop-Process -Force
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$dest\UsageGauge.exe" `
    /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll $src
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

if ($Autostart) {
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name UsageGauge -Value "`"$dest\UsageGauge.exe`""
}
Start-Process "$dest\UsageGauge.exe"
Write-Host "Installed to $dest"
