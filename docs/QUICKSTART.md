# Setup and troubleshooting

## Supported logins

Sign in to one or more of these tools before installing UsageGauge. You only need the tools you use.

| Gauge | Required local login |
| --- | --- |
| Codex | Codex CLI |
| Claude | Claude Code |
| Grok | Grok CLI |
| Antigravity / Gemini | Antigravity CLI (`agy`) |

Browser-only ChatGPT and Claude logins do not work. Codex credentials stored only in the OS keyring are not supported. The Gemini gauge reads Antigravity's quota, not the Gemini web app limit.

## Install or update

Download **UsageGauge-Setup.exe** from the [latest release](https://github.com/oksk4524/usage-gauge/releases/latest), run it and confirm installation.

The widget appears next to the taskbar clock. Drag it to move it. Right-click for services, language, refresh and startup settings.

Files are installed under `%LOCALAPPDATA%\UsageGauge`. The installer adds a Start menu shortcut and enables startup with Windows. To remove it, use **Settings > Apps > UsageGauge**.

To update, run the new installer. It closes and replaces the installed copy.

## Security warnings

The installer is unsigned. Windows SmartScreen or antivirus software may warn about it. Check that the file came from this repository's release page, and compare its SHA-256 with **SHA256SUMS.txt** in the same release:

```powershell
Get-FileHash .\UsageGauge-Setup.exe -Algorithm SHA256
```

A matching hash confirms that your download matches the published file; it is not a code signature or a safety guarantee.

If you trust the file and SmartScreen offers the option, select **More info > Run anyway**. Do not disable antivirus. On a managed PC, ask your administrator if policy blocks installation.

## Common issues

**A service is missing.** Sign in through its official tool, then right-click the widget and refresh. UsageGauge only shows services with login files in supported locations.

**The login has expired.** Click the affected gauge to open the official tool's sign-in command, then sign in again.

**A gauge has an amber dot.** Its value is stale. Check that the official tool works, then refresh. If the provider changed its internal API, UsageGauge may need an update.

**The size looks wrong after moving monitors.** Quit and reopen UsageGauge from the Start menu. Display scaling is read at startup.

**The widget was closed.** Open UsageGauge from the Start menu.

## Login renewal

Credentials are read without being changed by default. Requests go directly to each service; UsageGauge has no collection server or telemetry.

Experimental Claude/Grok renewal is off by default. If enabled from the right-click menu, it saves refreshed tokens to those tools' credential files. If the official tool refreshes at the same instant, you may need to sign in again. Leave it off if you do not need it.

## Reporting a problem

[Open an issue](https://github.com/oksk4524/usage-gauge/issues) with your Windows version, affected service and what happened.

The error log is available from the right-click menu or at `%LOCALAPPDATA%\UsageGauge\error.log`. Review it and remove personal information before sharing. Never upload login files, access tokens or passwords.
