$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('UsageGauge-AuthTests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
 $c=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 if(!(Test-Path $c)){$c=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
 & $c /nologo /target:exe /codepage:65001 /main:AuthReadOnlyTests /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$tmp\AuthTests.exe" "$repo\UsageGauge.cs" "$PSScriptRoot\AuthReadOnlyTests.cs"
 if($LASTEXITCODE -ne 0){throw 'test_compile_failed'}
 & "$tmp\AuthTests.exe" $tmp
 if($LASTEXITCODE -ne 0){throw 'auth_readonly_tests_failed'}
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force}
