param([switch]$Live, [switch]$Credits)
$ErrorActionPreference = 'Stop'
$build = Join-Path ([IO.Path]::GetTempPath()) ('UsageGauge-validation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
function Build([string]$Main, [string]$Out, [string[]]$Sources) {
    & $csc /nologo /optimize+ /target:exe "/main:$Main" /r:System.Web.Extensions.dll "/out:$Out" @Sources
    if ($LASTEXITCODE -ne 0) { throw 'Validation compile failed' }
}
try {
    $probe = Join-Path $PSScriptRoot 'UsageDetailsProbe.cs'
    Build 'Tests' (Join-Path $build 'Tests.exe') @($probe, (Join-Path $PSScriptRoot 'Tests.cs'))
    & (Join-Path $build 'Tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Core validation tests failed' }
    Build 'Probe' (Join-Path $build 'UsageDetailsProbe.exe') @($probe)
    $fixture = Join-Path $build '가상 사용자 경로'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $vars = @('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'GROK_HOME')
    $old = @{}
    $passed = 0
    foreach ($v in $vars) { $old[$v] = [Environment]::GetEnvironmentVariable($v, 'Process'); [Environment]::SetEnvironmentVariable($v, $fixture, 'Process') }
    try {
        foreach ($scenario in @('missing', 'malformed', 'oversized', 'missing_access', 'ambiguous_grok')) {
            foreach ($f in @('auth.json', '.credentials.json')) { $p = Join-Path $fixture $f; if (Test-Path $p) { Remove-Item -LiteralPath $p } }
            switch ($scenario) {
                'malformed' { '{bad' | Set-Content (Join-Path $fixture 'auth.json'); '{bad' | Set-Content (Join-Path $fixture '.credentials.json') }
                'oversized' { ('x' * 70000) | Set-Content (Join-Path $fixture 'auth.json'); ('x' * 70000) | Set-Content (Join-Path $fixture '.credentials.json') }
                'missing_access' { '{"tokens":{},"https://auth.x.ai::test":{}}' | Set-Content (Join-Path $fixture 'auth.json'); '{"claudeAiOauth":{}}' | Set-Content (Join-Path $fixture '.credentials.json') }
                'ambiguous_grok' { '{"tokens":{},"https://auth.x.ai::test1":{},"https://auth.x.ai::test2":{}}' | Set-Content (Join-Path $fixture 'auth.json'); '{"claudeAiOauth":{}}' | Set-Content (Join-Path $fixture '.credentials.json') }
            }
            $rows = @(& (Join-Path $build 'UsageDetailsProbe.exe') --live | ForEach-Object { $_ | ConvertFrom-Json })
            if ($rows.Count -ne 3) { throw 'Expected three provider results' }
            foreach ($r in $rows) {
                $expected = switch ($scenario) {
                    'missing' { 'credential_unavailable' }; 'malformed' { 'invalid_json' }; 'oversized' { 'credential_too_large' }; 'missing_access' { 'login_missing' }
                    'ambiguous_grok' { if ($r.service -eq 'Grok') { 'ambiguous_or_missing_account' } else { 'login_missing' } }
                }
                if ($r.status -ne $expected -or $null -ne $r.http) { throw "Fixture failed: $scenario/$($r.service)" }
                $passed++
            }
        }
    } finally { foreach ($v in $vars) { [Environment]::SetEnvironmentVariable($v, $old[$v], 'Process') } }
    Write-Output "Credential/path fixtures passed: $passed/15"
    if ($Live) { & (Join-Path $build 'UsageDetailsProbe.exe') --live }
    if ($Credits) {
        $agy = (Get-Command agy -ErrorAction Stop).Source
        $version = & $agy --version
        if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)') { throw 'Cannot verify agy version' }
        if ([Version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -lt [Version]'1.1.11') { throw 'agy >= 1.1.11 required for no-inference credits query' }
        Build 'CliProbe' (Join-Path $build 'CliProbe.exe') @($probe, (Join-Path $PSScriptRoot 'CliProbe.cs'))
        & (Join-Path $build 'CliProbe.exe') $agy
    }
} finally { Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue }
