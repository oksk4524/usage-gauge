# Sets up the local usage dashboard and its 30-minute refresh.
#   pwsh -File tools\usage-insights-collector\install-dashboard.ps1 [-NodePath <node.exe>] [-ExtraAsideRoot <dir>] [-SavedReadings <dir>] [-Uninstall]
# What it does:
#   - copies the collector, assembler and page builder to %LOCALAPPDATA%\UsageGauge\dashboard\app
#   - registers the task "UsageGauge dashboard refresh" for the current user only:
#       every 30 minutes while signed in, normal user rights (no admin), no stored password, hidden window
#   - the task reads local log files only. It makes no network requests and never opens credential files.
param([string]$NodePath = "$env:ProgramFiles\nodejs\node.exe", [string[]]$ExtraAsideRoot = @(), [string]$SavedReadings = '', [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$TaskName = 'UsageGauge dashboard refresh'
$Dash = Join-Path $env:LOCALAPPDATA 'UsageGauge\dashboard'
$App = Join-Path $Dash 'app'
$Data = Join-Path $Dash 'data'
$Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $Dash) { Remove-Item $Dash -Recurse -Force }
    Write-Host 'Removed the dashboard and its refresh task. The usage index and the widget are untouched.'
    return
}

if (-not (Test-Path $NodePath)) { throw "Node.js not found at $NodePath (needs 22.13 or newer for node:sqlite)." }
$ver = [version]((& $NodePath --version).TrimStart('v'))
if ($ver -lt [version]'22.13.0') { throw "Node.js $ver is too old (needs 22.13 or newer)." }

# code: same relative layout as the repository, so the modules find each other
$files = @(
    'NOTICE', 'assets\service-logos.json',
    'tools\service-logos.cjs',
    'tools\usage-insights-collector\collect.cjs', 'tools\usage-insights-collector\indexed.cjs',
    'tools\usage-insights-collector\assemble.cjs', 'tools\usage-insights-collector\refresh-dashboard.cjs',
    'tools\usage-details-preview-v6\builder.cjs', 'tools\usage-details-preview-v6\client.cjs',
    'tools\usage-details-preview-v6\core.cjs', 'tools\usage-details-preview-v6\v2.css',
    'tools\usage-details-preview-v6\template.html'
)
# service logos (tools\service-logos.cjs reads the PNGs next to the manifest)
$files += @(Get-ChildItem (Join-Path $Repo 'assets') -File -Filter *.png | ForEach-Object { "assets\$($_.Name)" })
if (Test-Path $App) { Remove-Item $App -Recurse -Force }
foreach ($f in $files) {
    $src = Join-Path $Repo $f
    if (-not (Test-Path $src -PathType Leaf)) { continue }
    $dst = Join-Path $App $f
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
}
New-Item -ItemType Directory -Force $Data | Out-Null

# optional: extra (archived) Aside session folders to read, read-only
if ($ExtraAsideRoot.Count) { @{ extraAsideRoots = @($ExtraAsideRoot | ForEach-Object { (Resolve-Path $_).Path }) } | ConvertTo-Json | Set-Content (Join-Path $Data 'config.json') -Encoding utf8 }
# optional: last saved account readings (masked account labels, no tokens). The task never fetches them.
if ($SavedReadings) {
    foreach ($pair in @(@('codex.jsonl', 'codex.jsonl'), @('final-limits.jsonl', 'limits.jsonl'), @('ag.jsonl', 'antigravity-limits.jsonl'))) {
        $p = Join-Path $SavedReadings $pair[0]
        if (Test-Path $p) {
            $t = Get-Content $p -Raw
            if ($t -match '"(access_token|refresh_token|id_token|authorization|password)"\s*:' -or $t -match 'eyJ[A-Za-z0-9_-]{10,}\.') { throw "$($pair[0]) looks like it contains a credential; not copied." }
            Copy-Item $p (Join-Path $Data $pair[1]) -Force
        }
    }
}

# the task: current user, only while signed in (no stored password), limited rights, hidden console
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   # USERDOMAIN/USERNAME can be empty in some shells
$script = Join-Path $App 'tools\usage-insights-collector\refresh-dashboard.cjs'
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless `"$NodePath`" --no-warnings `"$script`"" -WorkingDirectory $Data
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)
$logon = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger, $logon -Principal $principal -Settings $settings -Description 'UsageGauge: refresh the local usage dashboard from this PC''s log files every 30 minutes. Local files only, no network.' -Force | Out-Null
Write-Host "Installed. Page: $(Join-Path $Dash 'usage-gauge.html')"
