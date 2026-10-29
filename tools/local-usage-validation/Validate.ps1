[CmdletBinding()]
param([switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (!(Test-Path -LiteralPath $compiler)) { throw 'framework_compiler_unavailable' }
$build = Join-Path $PSScriptRoot '.build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
& $compiler /nologo /target:exe /optimize+ /r:System.Web.Extensions.dll /out:"$build\LocalUsage.exe" "$PSScriptRoot\LocalUsage.cs" "$PSScriptRoot\JsonProjection.cs" "$PSScriptRoot\FileSafety.cs"
if ($LASTEXITCODE -ne 0) { throw 'collector_compile_failed' }
& $compiler /nologo /target:exe /optimize+ /r:System.Web.Extensions.dll /r:System.Core.dll /main:Tests /out:"$build\Tests.exe" "$PSScriptRoot\LocalUsage.cs" "$PSScriptRoot\JsonProjection.cs" "$PSScriptRoot\FileSafety.cs" "$PSScriptRoot\Tests.cs"
if ($LASTEXITCODE -ne 0) { throw 'tests_compile_failed' }
if (!$BuildOnly) {
    & "$build\Tests.exe" $build
    if ($LASTEXITCODE -ne 0) { throw 'fixtures_failed' }
}
