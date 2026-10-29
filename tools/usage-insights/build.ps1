param([switch]$Test)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $compiler)) { throw 'Built-in .NET Framework compiler not found. No installation attempted.' }
$output = Join-Path $PSScriptRoot 'UsageInsights.exe'
& $compiler /nologo /target:exe /optimize+ /r:System.Web.Extensions.dll /r:System.Core.dll "/out:$output" (Join-Path $PSScriptRoot 'UsageInsights.cs')
if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed.' }
Write-Host "Built $output"
if ($Test) {
  & node (Join-Path $PSScriptRoot 'tests.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}
