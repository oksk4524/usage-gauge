// UsageGauge - Codex / Claude / Grok / Antigravity weekly quota on the taskbar (glass ring gauges).
// Hardened after code review: CLI timeout+kill, abandoned-mutex safe, no per-tick capture/render,
// atomic position save, display/power events, no GDI+ object leaks, crash logging.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

class Quota
{
    public string Name;
    public bool Ok;
    public double Remaining;
    public DateTime? ResetsAt;      // UTC
    public bool Stale;              // failing AND last good values are old -> amber dot
    public bool Failing;            // most recent fetch failed (tooltip only)
    public DateTime LastOkUtc;
    public string Error;
}

static class Native
{
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int w, int l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint aff);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    // Windows light mode for the taskbar (used when the glass backdrop can't be sampled)
    public static bool LightTaskbar()
    {
        try
        {
            using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            { var v = k != null ? k.GetValue("SystemUsesLightTheme") : null; return v is int && (int)v == 1; }
        }
        catch { return false; }
    }
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint len);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO li);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string s);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("shell32.dll")] public static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public uint cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
    [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    /// Job that kills every process in it (incl. grandchildren) when the handle closes; runs them BelowNormal.
    public static IntPtr NewKillJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.Basic.LimitFlags = 0x2000 | 0x20;          // KILL_ON_JOB_CLOSE | PRIORITY_CLASS
        info.Basic.PriorityClass = 0x4000;               // BELOW_NORMAL
        SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        return job;
    }
    public static uint IdleMs()
    {
        var li = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
        if (!GetLastInputInfo(ref li)) return 0;
        return unchecked((uint)Environment.TickCount - li.dwTime);
    }
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref POINT pos, ref SIZE size, IntPtr src, ref POINT srcPos, int key, ref BLEND blend, int flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int W, H; public SIZE(int w, int h) { W = w; H = h; } }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLEND { public byte Op, Flags, Alpha, Format; }

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString();
    }
}

static class Log
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UsageGauge");
    static readonly string FilePath = Path.Combine(Dir, "error.log");
    static readonly object Gate = new object();
    static string lastMsg; static DateTime lastAt; static int repeats;
    public static void Write(string msg)
    {
        lock (Gate)
        try
        {
            // collapse identical repeats within 10 min so a stuck condition can't flood the log, but count them
            if (msg == lastMsg && (DateTime.UtcNow - lastAt).TotalMinutes < 10) { repeats++; return; }
            string prefix = repeats > 0 ? DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  (previous message repeated " + repeats + " more times)" + Environment.NewLine : "";
            repeats = 0;
            lastMsg = msg; lastAt = DateTime.UtcNow;
            Directory.CreateDirectory(Dir);
            var fi = new FileInfo(FilePath);
            if (fi.Exists && fi.Length > 64 * 1024)                  // cap at 64 KB, keep one old copy
            {
                string old = FilePath + ".old";
                try { if (File.Exists(old)) File.Delete(old); File.Move(FilePath, old); } catch { fi.Delete(); }
            }
            File.AppendAllText(FilePath, prefix + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
        }
        catch { }
    }
}

// UI language: follows the Windows display language (Korean or English; anything else -> English).
// Can be forced from the right-click menu; the choice is kept in lang.txt (auto | ko | en).
static class L
{
    static readonly string File_ = Path.Combine(Log.Dir, "lang.txt");
    public static string Mode = "auto";
    public static bool Ko;
    public static CultureInfo Culture = CultureInfo.InvariantCulture;
    public static void Load()
    {
        try { if (File.Exists(File_)) Mode = File.ReadAllText(File_).Trim().ToLowerInvariant(); } catch { }
        if (Mode != "ko" && Mode != "en") Mode = "auto";
        Apply();
    }
    public static void Set(string mode)
    {
        Mode = mode;
        try { Directory.CreateDirectory(Log.Dir); File.WriteAllText(File_, mode); } catch { }
        Apply();
    }
    static void Apply()
    {
        Ko = Mode == "ko" || (Mode == "auto" && CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko");
        try { Culture = Ko ? new CultureInfo("ko-KR") : new CultureInfo("en-US"); } catch { Culture = CultureInfo.InvariantCulture; }
    }
    public static string T(string ko, string en) { return Ko ? ko : en; }
}

// Reads weekly quota straight from each service, using the login the official tool already saved on this PC.
// Nothing is sent anywhere except the service's own API. Tokens are never logged.
static class Usage
{
    static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    const int TIMEOUT_MS = 12 * 1000;
    static readonly object ClaudeGate = new object(), GrokGate = new object();
    static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    // Opt-in: renew an expired Claude/Grok login on the user's behalf (off by default; see README).
    static readonly string RenewFile = Path.Combine(Log.Dir, "renew-logins.txt");
    public static bool RenewLogins;
    public static void LoadSettings() { try { RenewLogins = File.Exists(RenewFile) && File.ReadAllText(RenewFile).Trim() == "on"; } catch { } }
    public static void SetRenew(bool on)
    {
        RenewLogins = on;
        try { Directory.CreateDirectory(Log.Dir); File.WriteAllText(RenewFile, on ? "on" : "off"); } catch { }
    }

    static string EnvDir(string var, string fallback)
    {
        string v = Environment.GetEnvironmentVariable(var);
        return string.IsNullOrEmpty(v) || v.Trim().Length == 0 ? Path.Combine(Home, fallback) : v.Trim();   // empty = unset
    }
    static string CodexAuth() { return Path.Combine(EnvDir("CODEX_HOME", ".codex"), "auth.json"); }
    static string ClaudeCred() { return Path.Combine(EnvDir("CLAUDE_CONFIG_DIR", ".claude"), ".credentials.json"); }
    static string GrokAuth() { return Path.Combine(EnvDir("GROK_HOME", ".grok"), "auth.json"); }
    public static bool HasCodex() { return File.Exists(CodexAuth()); }
    public static bool HasClaude() { return File.Exists(ClaudeCred()); }
    public static bool HasGrok() { return File.Exists(GrokAuth()); }

    // Remove temp files a crash may have left next to the login files (they would contain a full login).
    public static void CleanupTemps()
    {
        foreach (var p in new[] { ClaudeCred(), GrokAuth() })
        {
            try
            {
                string dir = Path.GetDirectoryName(p);
                if (!Directory.Exists(dir)) continue;
                foreach (var t in Directory.GetFiles(dir, Path.GetFileName(p) + ".ug*.tmp")) { try { File.Delete(t); } catch { } }
            }
            catch { }
        }
    }

    // ---------- Codex (ChatGPT login of the Codex CLI / app) ----------
    // Read-only: the Codex CLI owns refreshing this login (its access token lives ~10 days).
    public static Quota Codex()
    {
        Dictionary<string, object> auth, tokens;
        if (!TryReadJson(CodexAuth(), out auth) || !TryDict(auth, "tokens", out tokens)) return Fail("Codex login not found");
        string access = Str(tokens, "access_token"), account = Str(tokens, "account_id");
        if (access == null) return Fail("Codex login not found");
        var h = new Dictionary<string, string> { { "Authorization", "Bearer " + access } };
        if (account != null) h["ChatGPT-Account-Id"] = account;
        int status; string body = Http("GET", "https://chatgpt.com/backend-api/wham/usage", h, null, null, out status);
        if (status == 401 || status == 403) return Fail("Codex login expired: run Codex once to renew it");
        if (status != 200) return Fail(HttpError(status));
        var j = Parse(body); Dictionary<string, object> rl;
        if (j == null || !TryDict(j, "rate_limit", out rl)) return Fail("Codex response format changed");
        foreach (var key in new[] { "primary_window", "secondary_window" })
        {
            Dictionary<string, object> w;
            if (!TryDict(rl, key, out w)) continue;
            if (Num(w, "limit_window_seconds") != 604800) continue;             // the 7-day window only
            double used = Num(w, "used_percent");
            if (double.IsNaN(used)) continue;
            var q = Ok(100 - used);
            object ra; if (w.TryGetValue("reset_at", out ra) && ra != null) q.ResetsAt = ParseTime(ra);
            return q;
        }
        return Fail("Codex weekly limit not found");
    }

    // ---------- Claude (Claude Code login) ----------
    public static Quota Claude()
    {
        string path = ClaudeCred();
        string access = ClaudeToken(path, false);
        if (access == null) return Fail("Claude login not found");
        int status; string body = ClaudeGet(access, out status);
        if (status == 401)
        {
            access = ClaudeToken(path, true);
            if (access == null) return Fail("Claude login expired: run Claude Code once to renew it");
            body = ClaudeGet(access, out status);
        }
        if (status == 401 || status == 403) return Fail("Claude login expired: run Claude Code once to renew it");
        if (status != 200) return Fail(HttpError(status));
        var j = Parse(body); Dictionary<string, object> w;
        if (j == null || !TryDict(j, "seven_day", out w)) return Fail("Claude response format changed");
        double used = Num(w, "utilization");
        if (double.IsNaN(used)) return Fail("Claude weekly limit not found");
        var q = Ok(100 - used);
        object ra; if (w.TryGetValue("resets_at", out ra) && ra != null) q.ResetsAt = ParseTime(ra);
        return q;
    }
    static string ClaudeGet(string access, out int status)
    {
        return Http("GET", "https://api.anthropic.com/api/oauth/usage", new Dictionary<string, string> {
            { "Authorization", "Bearer " + access }, { "anthropic-beta", "oauth-2025-04-20" } }, null, null, out status);
    }
    // Returns the saved access token. Only if renewal is switched on, the token is past expiry
    // (or rejected), and Claude Code hasn't renewed it meanwhile, it is renewed and written back.
    static string ClaudeToken(string path, bool rejected)
    {
        lock (ClaudeGate)
        {
            Dictionary<string, object> root, o;
            if (!TryReadJson(path, out root) || !TryDict(root, "claudeAiOauth", out o)) return null;
            string access = Str(o, "accessToken"), refresh = Str(o, "refreshToken");
            DateTime? exp = EpochMs(Num(o, "expiresAt"));
            if (!rejected && (exp == null || DateTime.UtcNow < exp.Value.AddMinutes(2))) return access;   // still valid (or unknown)
            if (!RenewLogins || refresh == null) return rejected ? null : access;

            // Claude Code may be renewing right now: wait a moment and look again before doing it ourselves.
            Thread.Sleep(1500);
            if (TryReadJson(path, out root) && TryDict(root, "claudeAiOauth", out o))
            {
                DateTime? exp2 = EpochMs(Num(o, "expiresAt"));
                string access2 = Str(o, "accessToken");
                if (access2 != null && access2 != access && exp2.HasValue && exp2.Value > DateTime.UtcNow) return access2;
                refresh = Str(o, "refreshToken") ?? refresh;
            }
            if (!CanWrite(path)) { Log.Write("Claude login not renewed: login file is busy"); return rejected ? null : access; }

            var body = new Dictionary<string, object> {
                { "grant_type", "refresh_token" }, { "refresh_token", refresh },
                { "client_id", "9d1c250a-e61b-44d9-88ed-5944d1962f5e" } };
            object sc; var scopes = o != null && o.TryGetValue("scopes", out sc) ? sc as object[] : null;
            if (scopes != null && scopes.Length > 0) body["scope"] = string.Join(" ", Array.ConvertAll(scopes, x => Convert.ToString(x)));
            int status; string resp = Http("POST", "https://platform.claude.com/v1/oauth/token", null,
                new JavaScriptSerializer().Serialize(body), "application/json", out status);
            var j = status == 200 ? Parse(resp) : null;
            string na = j != null ? Str(j, "access_token") : null;
            if (na == null) { Log.Write("Claude login renewal failed (HTTP " + status + ")"); return null; }
            string nr = Str(j, "refresh_token") ?? refresh;
            double ttl = Num(j, "expires_in"); if (double.IsNaN(ttl) || ttl <= 0) ttl = 8 * 3600;
            long newExp = (long)(DateTime.UtcNow.AddSeconds(ttl) - Epoch).TotalMilliseconds;

            // Patch only these three values in the original text, and only if nobody changed the login meanwhile.
            string err = PatchFile(path, refresh, "\"claudeAiOauth\"", delegate(string text)
            {
                text = ReplaceJsonString(text, "accessToken", na);
                text = ReplaceJsonString(text, "refreshToken", nr);
                return ReplaceJsonNumber(text, "expiresAt", newExp);
            });
            if (err == null) Log.Write("Claude login renewed");
            else Log.Write("Claude login renewed but NOT saved (" + err + "): run Claude Code once if it asks you to sign in");
            return na;
        }
    }

    // ---------- Grok (SuperGrok login of the Grok CLI) ----------
    public static Quota Grok()
    {
        string path = GrokAuth();
        string err0;
        string access = GrokToken(path, false, out err0);
        if (access == null) return Fail(err0 ?? "Grok login not found");
        int status; string body = GrokGet(access, out status);
        if (status == 401)
        {
            access = GrokToken(path, true, out err0);
            if (access == null) return Fail(err0 ?? "Grok login expired: run grok once to renew it");
            body = GrokGet(access, out status);
        }
        if (status == 401 || status == 403) return Fail("Grok login expired: run grok once to renew it");
        if (status != 200) return Fail(HttpError(status));
        var j = Parse(body); Dictionary<string, object> c, period;
        if (j == null || !TryDict(j, "config", out c)) return Fail("Grok response format changed");
        if (!TryDict(c, "currentPeriod", out period) || Str(period, "type") != "USAGE_PERIOD_TYPE_WEEKLY")
            return Fail("Grok weekly period not found");
        double used;
        object up;
        if (!c.TryGetValue("creditUsagePercent", out up) || up == null) used = 0;   // omitted when nothing is used yet
        else { used = Num(c, "creditUsagePercent"); if (double.IsNaN(used)) return Fail("Grok usage value is not a number"); }
        var q = Ok(100 - used);
        object end; if (period.TryGetValue("end", out end) && end != null) q.ResetsAt = ParseTime(end);
        return q;
    }
    static string GrokGet(string access, out int status)
    {
        return Http("GET", "https://cli-chat-proxy.grok.com/v1/billing?format=credits", new Dictionary<string, string> {
            { "Authorization", "Bearer " + access }, { "x-xai-token-auth", "xai-grok-cli" } }, null, null, out status);
    }
    static string GrokToken(string path, bool rejected, out string error)
    {
        error = null;
        lock (GrokGate)
        {
            Dictionary<string, object> root;
            if (!TryReadJson(path, out root)) return null;
            string scope; Dictionary<string, object> e;
            if (!GrokEntry(root, out scope, out e, out error)) return null;
            string access = Str(e, "key"), refresh = Str(e, "refresh_token");
            DateTime? exp = null; object ea;
            if (e.TryGetValue("expires_at", out ea) && ea != null) exp = ParseTime(ea);
            if (!rejected && (exp == null || DateTime.UtcNow < exp.Value.AddMinutes(2))) return access;
            if (!RenewLogins || refresh == null) return rejected ? null : access;

            Thread.Sleep(1500);   // grok may be renewing right now
            if (TryReadJson(path, out root) && GrokEntry(root, out scope, out e, out error))
            {
                string access2 = Str(e, "key"); DateTime? exp2 = null;
                if (e.TryGetValue("expires_at", out ea) && ea != null) exp2 = ParseTime(ea);
                if (access2 != null && access2 != access && exp2.HasValue && exp2.Value > DateTime.UtcNow) return access2;
                refresh = Str(e, "refresh_token") ?? refresh;
            }
            if (!CanWrite(path)) { Log.Write("Grok login not renewed: login file is busy"); return rejected ? null : access; }

            string clientId = scope.Substring("https://auth.x.ai::".Length);
            string form = "grant_type=refresh_token&client_id=" + Uri.EscapeDataString(clientId) + "&refresh_token=" + Uri.EscapeDataString(refresh);
            int status; string resp = Http("POST", "https://auth.x.ai/oauth2/token", null, form, "application/x-www-form-urlencoded", out status);
            var j = status == 200 ? Parse(resp) : null;
            string na = j != null ? Str(j, "access_token") : null;
            if (na == null) { Log.Write("Grok login renewal failed (HTTP " + status + ")"); return null; }
            string nr = Str(j, "refresh_token") ?? refresh;
            double ttl = Num(j, "expires_in"); if (double.IsNaN(ttl) || ttl <= 0) ttl = 3600;
            string newExp = DateTime.UtcNow.AddSeconds(ttl).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
            string err = PatchFile(path, refresh, "\"" + scope + "\"", delegate(string text)
            {
                text = ReplaceJsonString(text, "key", na);
                text = ReplaceJsonString(text, "refresh_token", nr);
                return ReplaceJsonString(text, "expires_at", newExp);
            });
            if (err == null) Log.Write("Grok login renewed");
            else Log.Write("Grok login renewed but NOT saved (" + err + "): run grok once if it asks you to sign in");
            return na;
        }
    }
    // Exactly one xAI login must be present; with several we can't know which one grok uses.
    static bool GrokEntry(Dictionary<string, object> root, out string scope, out Dictionary<string, object> e, out string error)
    {
        scope = null; e = null; error = null; int n = 0;
        foreach (var kv in root)
            if (kv.Key.StartsWith("https://auth.x.ai::") && kv.Value is Dictionary<string, object>)
            { n++; scope = kv.Key; e = (Dictionary<string, object>)kv.Value; }
        if (n == 1) return true;
        if (n > 1) error = "Several Grok accounts in auth.json: can't tell which one is active";
        scope = null; e = null;
        return false;
    }

    // ---------- careful write-back of a renewed login ----------
    static bool CanWrite(string path)
    {
        try { using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) return true; }
        catch { return false; }
    }
    // Re-reads the file; gives up if its refresh token is no longer the one we just used (the official tool
    // renewed it meanwhile - its copy wins). Otherwise patches the text and swaps it in via a protected temp file.
    // Only the flat JSON object that follows `anchor` (e.g. "claudeAiOauth") is touched; everything else stays byte-for-byte.
    static string PatchFile(string path, string usedRefresh, string anchor, Func<string, string> patch)
    {
        for (int attempt = 0; attempt < 8; attempt++)
        {
            if (attempt > 0) Thread.Sleep(200);
            string text;
            try { text = File.ReadAllText(path, new UTF8Encoding(false)); } catch { continue; }
            int a = text.IndexOf(anchor, StringComparison.Ordinal);
            int open = a < 0 ? -1 : text.IndexOf('{', a);
            int close = open < 0 ? -1 : text.IndexOf('}', open);
            if (close < 0) return "unexpected file layout";
            string seg = text.Substring(open, close - open + 1);
            if (seg.IndexOf("\"" + usedRefresh + "\"", StringComparison.Ordinal) < 0) return "the official tool already saved a newer login";
            string patched = patch(seg);
            if (patched == null || patched == seg) return "unexpected file layout";
            string updated = text.Substring(0, open) + patched + text.Substring(close + 1);
            string tmp = path + ".ug" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp";
            try
            {
                using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    try { File.SetAccessControl(tmp, File.GetAccessControl(path)); } catch { }   // same protection as the login file
                    byte[] b = new UTF8Encoding(false).GetBytes(updated);
                    fs.Write(b, 0, b.Length);
                }
                File.Replace(tmp, path, null);
                return null;
            }
            catch { }
            finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
        }
        return "file stayed locked";
    }
    static string ReplaceJsonString(string text, string key, string value)
    {
        if (text == null) return null;
        var re = new Regex("(\"" + Regex.Escape(key) + "\"\\s*:\\s*\")((?:[^\"\\\\]|\\\\.)*)(\")");
        if (!re.IsMatch(text)) return null;
        string v = value.Replace("\\", "\\\\").Replace("\"", "\\\"");
        return re.Replace(text, m => m.Groups[1].Value + v + m.Groups[3].Value, 1);
    }
    static string ReplaceJsonNumber(string text, string key, long value)
    {
        if (text == null) return null;
        var re = new Regex("(\"" + Regex.Escape(key) + "\"\\s*:\\s*)(-?\\d+(?:\\.\\d+)?)");
        if (!re.IsMatch(text)) return null;
        return re.Replace(text, m => m.Groups[1].Value + value.ToString(CultureInfo.InvariantCulture), 1);
    }
    static DateTime? EpochMs(double ms)
    {
        if (double.IsNaN(ms) || ms <= 0 || ms > 4102444800000.0) return null;   // missing or beyond year 2100
        return Epoch.AddMilliseconds(ms);
    }

    // ---------- Antigravity CLI location ----------
    static string agyCache;
    public static string FindAgy()
    {
        if (agyCache != null && File.Exists(agyCache)) return agyCache;
        var dirs = new List<string>((Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'));
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        dirs.Add(Path.Combine(local, @"Microsoft\WinGet\Links"));
        dirs.Add(Path.Combine(local, @"agy\bin"));
        foreach (var d in dirs)
        {
            try { string p = Path.Combine(d.Trim(), "agy.exe"); if (d.Trim().Length > 0 && File.Exists(p)) return agyCache = p; } catch { }
        }
        try
        {
            foreach (var d in Directory.GetDirectories(Path.Combine(local, @"Microsoft\WinGet\Packages"), "Google.AntigravityCLI_*"))
            { string p = Path.Combine(d, "agy.exe"); if (File.Exists(p)) return agyCache = p; }
        }
        catch { }
        return null;
    }

    // ---------- helpers ----------
    static Quota Ok(double remaining)
    {
        // over-quota (used > 100%) shows as 0% left; only absurd values are rejected
        if (double.IsNaN(remaining) || double.IsInfinity(remaining) || remaining < -1000 || remaining > 100.5) return Fail("Invalid value");
        return new Quota { Ok = true, Remaining = Math.Max(0, Math.Min(100, remaining)) };
    }
    static Quota Fail(string msg) { return new Quota { Error = msg }; }
    static string HttpError(int status)
    {
        if (status <= 0) return "Timed out (network)";
        if (status == 429) return "Rate limited (429), will retry";
        if (status >= 500) return "Lookup error: server " + status;
        return "Request failed (HTTP " + status + ")";
    }
    // status: HTTP code, or 0 on network error / timeout
    static string Http(string method, string url, Dictionary<string, string> headers, string body, string contentType, out int status)
    {
        status = 0;
        try
        {
            var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            req.Method = method; req.Timeout = TIMEOUT_MS; req.ReadWriteTimeout = TIMEOUT_MS;
            req.Accept = "application/json"; req.UserAgent = "UsageGauge";
            req.ServicePoint.Expect100Continue = false;   // some proxies stall on Expect: 100-continue
            req.AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate;
            if (headers != null) foreach (var kv in headers) req.Headers[kv.Key] = kv.Value;
            if (body != null)
            {
                byte[] b = Encoding.UTF8.GetBytes(body);
                req.ContentType = contentType; req.ContentLength = b.Length;
                using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
            }
            using (var resp = (System.Net.HttpWebResponse)req.GetResponse())
            {
                status = (int)resp.StatusCode;
                return ReadCapped(resp);
            }
        }
        catch (System.Net.WebException ex)
        {
            var r = ex.Response as System.Net.HttpWebResponse;
            if (r != null) { using (r) { status = (int)r.StatusCode; return ReadCapped(r); } }
            return null;
        }
        catch { return null; }
    }
    static string ReadCapped(System.Net.HttpWebResponse resp)
    {
        using (var s = resp.GetResponseStream())
        using (var rd = new StreamReader(s, Encoding.UTF8))
        {
            var buf = new char[8192]; var sb = new StringBuilder(); int n;
            while ((n = rd.Read(buf, 0, buf.Length)) > 0) { sb.Append(buf, 0, n); if (sb.Length > 512 * 1024) break; }
            return sb.ToString();
        }
    }
    static Dictionary<string, object> Parse(string json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try { return new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 }.DeserializeObject(json) as Dictionary<string, object>; }
        catch { return null; }
    }
    static bool TryReadJson(string path, out Dictionary<string, object> d)
    {
        d = null;
        for (int i = 0; i < 3 && d == null; i++)   // the owning app may be rewriting it right now
        {
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var rd = new StreamReader(fs, Encoding.UTF8)) d = Parse(rd.ReadToEnd());
            }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }
            catch { }
            if (d == null) Thread.Sleep(150);
        }
        return d != null;
    }
    static bool TryDict(Dictionary<string, object> d, string key, out Dictionary<string, object> v)
    {
        object o; v = d != null && d.TryGetValue(key, out o) ? o as Dictionary<string, object> : null; return v != null;
    }
    static string Str(Dictionary<string, object> d, string key)
    {
        object o; return d != null && d.TryGetValue(key, out o) && o != null && o.ToString().Length > 0 ? o.ToString() : null;
    }
    static double Num(Dictionary<string, object> d, string key)
    {
        object o;
        if (d == null || !d.TryGetValue(key, out o) || o == null) return double.NaN;
        try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return double.NaN; }
    }
    public static DateTime? ParseTime(object v)
    {
        try
        {
            DateTime dt;
            if (v is int || v is long || v is double || v is decimal)
            {
                double n = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (n > 1e11) n /= 1000;                                       // milliseconds -> seconds
                if (double.IsNaN(n) || n <= 0 || n > 4102444800) return null;   // missing or beyond year 2100
                return Epoch.AddSeconds(n);
            }
            if (DateTime.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out dt)) return dt;
        }
        catch { }
        return null;
    }
}

class GaugeForm : Form
{
    // ---- layout (px) ----
    const int H = 40, PADX = 10, RING = 30, LOGO = 16, TEXT_GAP = 7, TEXT_W = 58, SEP = 12;
    const float STROKE = 3.0f, RADIUS = 9f;
    const int BLOCK = RING + TEXT_GAP + TEXT_W;
    static readonly string[] Ids = { "codex", "claude", "grok", "ag-gemini", "ag-3p" };
    static readonly string[] Names = { "Codex", "Claude", "Grok", "Gemini (Antigravity)", "Claude·GPT (Antigravity)" };
    const int N = 5;
    static readonly string[] MainIds = { "codex", "claude", "grok" };   // read directly over HTTPS
    const int AG_EVERY_MS = 15 * 60 * 1000;                              // agy is heavy: refresh it less often
    static double lastAgMs = -AG_EVERY_MS;                                // monotonic (Clock), immune to clock changes
    const int STALE_MAIN_MIN = 12, STALE_AG_MIN = 35;                    // amber dot only once data is really old
    const int SH = 4;                               // shadow margin
    // Logical size (at 100% scaling) depends on how many gauges are shown; physical size = logical x S.
    static int W, WW, HH = H + SH * 2, PW, PH;
    static float S = 1f;                            // display scaling (1.0 = 100%, 1.5 = 150%)
    static int[] Vis = { 0, 1, 2, 3, 4 };           // indexes of the gauges currently shown
    static void Relayout(int count)
    {
        W = count <= 0 ? 200 : PADX + count * BLOCK + (count - 1) * SEP + PADX - 2;   // 0 = "nothing to show" hint
        WW = W + SH * 2; HH = H + SH * 2;
        PW = (int)Math.Ceiling(WW * S); PH = (int)Math.Ceiling(HH * S);
    }

    // A gauge is shown when its service is set up on this PC and the user hasn't hidden it.
    static readonly string HiddenFile = Path.Combine(Log.Dir, "hidden.txt");
    static HashSet<string> Hidden = new HashSet<string>();
    static void LoadHidden()
    {
        try { if (File.Exists(HiddenFile)) Hidden = new HashSet<string>(File.ReadAllText(HiddenFile).Split(new[] { ',', ' ', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)); } catch { }
    }
    static void SaveHidden() { try { File.WriteAllText(HiddenFile, string.Join(",", Hidden)); } catch { } }
    static bool Available(int i)
    {
        return i == 0 ? Usage.HasCodex() : i == 1 ? Usage.HasClaude() : i == 2 ? Usage.HasGrok() : Usage.FindAgy() != null;
    }
    static int[] ComputeVisible()
    {
        var v = new List<int>();
        for (int i = 0; i < N; i++) if (!Hidden.Contains(Ids[i]) && Available(i)) v.Add(i);
        return v.ToArray();
    }
    static int[] running = new int[3];   // per-service "worker still in flight" flags
    static bool Shown_(string id) { int i = Array.IndexOf(Ids, id); return Array.IndexOf(Vis, i) >= 0; }
    // Re-check which gauges to show; resize the window when that changes.
    void UpdateVisible()
    {
        var v = ComputeVisible();
        if (v.Length == Vis.Length && Array.TrueForAll(v, i => Array.IndexOf(Vis, i) >= 0)) return;
        int right = Left + Width;
        Vis = v; Relayout(Vis.Length);
        Size = new Size(PW, PH);
        Location = ClampToScreens(new Point(right - PW, Top));   // keep the right edge where it was
        SavePos();
        if (!GrabBackdrop()) Render();
    }

    // ---- timing ----
    const int REFRESH_MS = 5 * 60 * 1000;           // quota poll
    const int GUARD_MS = 3000;                      // safety-net check; real work is event-driven
    const int SLOW_MS = 30 * 1000;                  // backdrop re-sample + countdown redraw
    const int CLI_TIMEOUT_MS = 30 * 1000;
    const double ANIM_MS = 1100;

    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    static readonly string Dir = Log.Dir;
    static readonly string PosFile = Path.Combine(Dir, "position.txt");
    const int HTTP_TIMEOUT_MS = 12 * 1000;

    // ---- cached type resources (created once, never per frame) ----
    static readonly FontFamily FNum = PickFamily("Segoe UI Variable Display", "Segoe UI");
    static readonly FontFamily FKor = PickFamily("Malgun Gothic", "Segoe UI");
    const float NUM_PX = 17f, PCT_PX = 11f, SUB_PX = 11.5f, LINE_GAP = 5f;
    static readonly StringFormat Typo = MakeTypo();
    static readonly Font NumFont = new Font(FNum, NUM_PX, FontStyle.Bold, GraphicsUnit.Pixel);

    readonly Quota[] qs = { new Quota { Name = Names[0] }, new Quota { Name = Names[1] }, new Quota { Name = Names[2] }, new Quota { Name = Names[3] }, new Quota { Name = Names[4] } };
    readonly double[] shown = new double[N], from = new double[N];
    Image codexLogo, grokLogo, geminiLogo, agLogo; GraphicsPath claudeLogo;
    static Image LoadPng(string file)
    {
        try { using (var src = Image.FromFile(Path.Combine(Dir, file))) return new Bitmap(src); }
        catch (Exception ex) { Log.Write(file + ": " + ex.Message); return null; }
    }
    Bitmap backdrop; bool backdropAllowed = true;

    static readonly Stopwatch Clock = Stopwatch.StartNew();   // monotonic: immune to clock/DST changes
    double animStartMs;
    int refreshPending = 0, forceAgPending = 0; bool missedWhileIdle = false, retriedOnce = false, agFailedLast = false;
    static readonly uint SelfPid = (uint)Process.GetCurrentProcess().Id;
    bool dragging = false;
    const uint IDLE_SKIP_MS = 15 * 60 * 1000;                 // no polling while the PC is unattended
    const int RETRY_MS = 60 * 1000;                           // one quick retry after a failure
    const int MAX_OUT = 256 * 1024;                           // cap CLI stdout
    readonly System.Windows.Forms.Timer retryTimer = new System.Windows.Forms.Timer();
    static readonly uint WM_TASKBARCREATED = Native.RegisterWindowMessage("TaskbarCreated");
    bool loading = true, hover = false; float hoverT = 0;
    int busy = 0, generation = 0;
    readonly ToolTip tip = new ToolTip();
    readonly System.Windows.Forms.Timer refreshTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer guardTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer slowTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer animTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer resumeTimer = new System.Windows.Forms.Timer();

    static FontFamily PickFamily(string want, string fallback)
    {
        try { return new FontFamily(want); } catch { return new FontFamily(fallback); }
    }
    static StringFormat MakeTypo()
    {
        var sf = (StringFormat)StringFormat.GenericTypographic.Clone();
        sf.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        return sf;
    }

    public GaugeForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        try { using (var sg = Graphics.FromHwnd(IntPtr.Zero)) S = Math.Max(1f, Math.Min(3f, sg.DpiX / 96f)); } catch { }
        float so; if (float.TryParse(Environment.GetEnvironmentVariable("USAGEGAUGE_SCALE"), NumberStyles.Float, CultureInfo.InvariantCulture, out so) && so >= 1 && so <= 3) S = so;   // testing aid
        LoadHidden();
        Vis = ComputeVisible();
        Relayout(Vis.Length);
        Size = new Size(PW, PH);
        Location = ClampToScreens(LoadPos());
        tip.InitialDelay = 350; tip.AutoPopDelay = 20000;

        try { using (var src = Image.FromFile(Path.Combine(Dir, "codex.png"))) codexLogo = new Bitmap(src); } catch (Exception ex) { Log.Write("codex logo: " + ex.Message); }
        try { claudeLogo = ParseSvgPath(File.ReadAllText(Path.Combine(Dir, "claude.path"))); } catch (Exception ex) { Log.Write("claude logo: " + ex.Message); }
        grokLogo = LoadPng("grok.png"); geminiLogo = LoadPng("gemini.png"); agLogo = LoadPng("antigravity.png");

        var menu = new ContextMenuStrip();
        menu.Opening += delegate { BuildMenu(menu); };
        BuildMenu(menu);
        ContextMenuStrip = menu;

        MouseDown += OnDown;
        MouseEnter += delegate { hover = true; Kick(); };
        MouseLeave += delegate { hover = false; Kick(); };

        refreshTimer.Interval = REFRESH_MS;
        refreshTimer.Tick += delegate
        {
            if (Native.IdleMs() > IDLE_SKIP_MS) { missedWhileIdle = true; return; }
            retriedOnce = false;
            Refresh_();
        };
        retryTimer.Interval = RETRY_MS;
        retryTimer.Tick += delegate
        {
            retryTimer.Stop();
            if (Native.IdleMs() > IDLE_SKIP_MS) { missedWhileIdle = true; return; }
            Refresh_(agFailedLast, false);   // re-polls agy too if agy failed; keeps the 5-min schedule
        };
        guardTimer.Interval = GUARD_MS; guardTimer.Tick += delegate { Guard(); };
        slowTimer.Interval = SLOW_MS;
        slowTimer.Tick += delegate
        {
            // unattended (locked / away): no screen sampling; just keep the countdown text current
            if (Native.IdleMs() > IDLE_SKIP_MS) return;   // unattended: no sampling, no drawing (refreshed on return)
            if (!GrabBackdrop()) Render();                // a scheduled grab renders when done
            CheckPreviewRequest();
        };
        animTimer.Interval = 15; animTimer.Tick += delegate { Step(); };
        grabTimer.Interval = 120; grabTimer.Tick += delegate { OnGrabTick(); };   // subscribed once
        resumeTimer.Interval = 12000;   // let Wi-Fi/DHCP come back after wake
        resumeTimer.Tick += delegate { resumeTimer.Stop(); Location = ClampToScreens(Location); GrabBackdrop(); Refresh_(true); };

        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        SystemEvents.PowerModeChanged += OnPowerChanged;
        SystemEvents.TimeChanged += OnTimeChanged;
        SystemEvents.UserPreferenceChanged += OnPrefChanged;
        FormClosed += delegate
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
            SystemEvents.PowerModeChanged -= OnPowerChanged;
            SystemEvents.TimeChanged -= OnTimeChanged;
            SystemEvents.UserPreferenceChanged -= OnPrefChanged;
        };

        showTimer.Interval = 220; showTimer.Tick += delegate { showTimer.Stop(); if (!ShouldHide()) ShowNow(); };
        topTimer.Interval = 60; topTimer.Tick += delegate { topTimer.Stop(); Evaluate(); };
        FormClosed += delegate
        {
            refreshTimer.Stop(); retryTimer.Stop(); guardTimer.Stop(); slowTimer.Stop(); animTimer.Stop();
            resumeTimer.Stop(); showTimer.Stop(); topTimer.Stop(); grabTimer.Stop();
            foreach (var h in hooks) if (h != IntPtr.Zero) Native.UnhookWinEvent(h);
            if (locHook != IntPtr.Zero) Native.UnhookWinEvent(locHook);
        };

        Shown += delegate
        {
            refreshTimer.Start(); guardTimer.Start(); slowTimer.Start();
            // event hooks: react instantly to foreground / fullscreen / minimize changes instead of polling
            winEvent = OnWinEvent;
            hooks.Add(Native.SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, winEvent, 0, 0, 0x0002));   // FOREGROUND
            hooks.Add(Native.SetWinEventHook(0x0016, 0x0017, IntPtr.Zero, winEvent, 0, 0, 0x0002));   // MINIMIZESTART..END
            lastFg = Native.GetForegroundWindow();
            RehookLocation(lastFg);
            RefreshCachedState();
            Evaluate();   // already-fullscreen app at startup: hide right away                                                                     // LOCATIONCHANGE, active app only
            GrabBackdrop(); Render(); Refresh_(true);
        };
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80000 | 0x80 | 0x08000000 | 0x8; // LAYERED | TOOLWINDOW | NOACTIVATE | TOPMOST
            return cp;
        }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void WndProc(ref Message m)
    {
        // Explorer restarted: re-dock and re-assert z-order
        if (WM_TASKBARCREATED != 0 && m.Msg == (int)WM_TASKBARCREATED)
        {
            Location = ClampToScreens(Location);
            RefreshCachedState();
            Native.SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
            GrabBackdrop(); Render();
        }
        base.WndProc(ref m);
    }
    void OnTimeChanged(object s, EventArgs e) { try { BeginInvoke((MethodInvoker)delegate { UpdateTip(); Render(); }); } catch { } }
    void OnPrefChanged(object s, UserPreferenceChangedEventArgs e) { try { BeginInvoke((MethodInvoker)delegate { RefreshCachedState(); GrabBackdrop(); Render(); }); } catch { } }
    protected override void OnPaint(PaintEventArgs e) { }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // We hide ourselves from capture ONLY for ~0.1 s while sampling the backdrop (every 30 s),
        // so normal screenshots/recordings include the widget. Probe support once.
        bool okAff = false;
        try { okAff = Native.SetWindowDisplayAffinity(Handle, 0x11); Native.SetWindowDisplayAffinity(Handle, 0); } catch { }
        backdropAllowed = okAff;
        if (!okAff) Log.Write("SetWindowDisplayAffinity unsupported; glass blur disabled");
    }
    void OnGrabTick()
    {
        grabTimer.Stop();
        try { DoGrab(); }
        finally { try { Native.SetWindowDisplayAffinity(Handle, 0); } catch { } }
        Render();
    }

    // ---- events ----
    void OnDisplayChanged(object s, EventArgs e)
    {
        try { BeginInvoke((MethodInvoker)delegate { Location = ClampToScreens(Location); RefreshCachedState(); GrabBackdrop(); Render(); }); } catch { }
    }
    void OnPowerChanged(object s, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume) return;
        try { BeginInvoke((MethodInvoker)delegate { resumeTimer.Stop(); resumeTimer.Start(); }); } catch { }
    }

    // ---- SVG path (absolute M L H V C Z) ----
    static GraphicsPath ParseSvgPath(string d)
    {
        var path = new GraphicsPath(FillMode.Winding);
        var tokens = Regex.Matches(d, @"[MLHVCZmlhvcz]|-?\d*\.?\d+(?:e-?\d+)?");
        int i = 0; char cmd = 'M'; PointF cur = PointF.Empty;
        Func<float> num = delegate { return float.Parse(tokens[i++].Value, CultureInfo.InvariantCulture); };
        while (i < tokens.Count)
        {
            string t = tokens[i].Value;
            if (char.IsLetter(t[0])) { cmd = t[0]; i++; if (cmd == 'Z' || cmd == 'z') { path.CloseFigure(); continue; } }
            switch (cmd)
            {
                case 'M': cur = new PointF(num(), num()); path.StartFigure(); cmd = 'L'; break;
                case 'L': { var p = new PointF(num(), num()); path.AddLine(cur, p); cur = p; break; }
                case 'H': { var p = new PointF(num(), cur.Y); path.AddLine(cur, p); cur = p; break; }
                case 'V': { var p = new PointF(cur.X, num()); path.AddLine(cur, p); cur = p; break; }
                case 'C':
                    {
                        var c1 = new PointF(num(), num()); var c2 = new PointF(num(), num()); var p = new PointF(num(), num());
                        path.AddBezier(cur, c1, c2, p); cur = p; break;
                    }
                default: i++; break;
            }
        }
        return path;
    }

    // ---- position ----
    Point LoadPos()
    {
        try
        {
            var p = File.ReadAllText(PosFile).Trim().Split(',');
            return new Point(int.Parse(p[0]), int.Parse(p[1]));
        }
        catch { }
        return DefaultPos();
    }
    // Dock next to the tray on whichever edge the taskbar sits (bottom, top, left or right).
    static Point DefaultPos()
    {
        var b = Screen.PrimaryScreen.Bounds; var wa = Screen.PrimaryScreen.WorkingArea;
        int bottom = b.Bottom - wa.Bottom, top = wa.Top - b.Top, left = wa.Left - b.Left, right = b.Right - wa.Right;
        int x = Math.Max(b.Left, b.Right - PW - (int)(300 * S));
        if (top > bottom && top >= left && top >= right && top >= PH)
            return new Point(x, b.Top + (top - PH) / 2);                       // taskbar on top: sit inside it
        if (bottom >= PH || (bottom >= left && bottom >= right && bottom > 0))
            return new Point(x, b.Bottom - bottom + (bottom - PH) / 2);        // bottom (normal)
        // vertical taskbar (too narrow for the strip) or none: bottom-right corner of the work area
        return new Point(Math.Max(wa.Left, wa.Right - PW - 12), wa.Bottom - PH - 12);
    }
    static Point ClampToScreens(Point p)
    {
        var center = new Point(p.X + PW / 2, p.Y + PH / 2);
        foreach (var s in Screen.AllScreens)
            if (s.Bounds.Contains(center))
            {
                var b0 = s.Bounds;   // keep the whole widget on that monitor
                return new Point(Math.Max(b0.Left, Math.Min(p.X, b0.Right - PW)), Math.Max(b0.Top, Math.Min(p.Y, b0.Bottom - PH)));
            }
        // off every screen (monitor unplugged / resolution change): dock to the primary taskbar
        return DefaultPos();
    }
    void SavePos()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            string tmp = PosFile + ".tmp";
            File.WriteAllText(tmp, Left + "," + Top);
            if (File.Exists(PosFile)) File.Replace(tmp, PosFile, null); else File.Move(tmp, PosFile);
        }
        catch (Exception ex) { Log.Write("save pos: " + ex.Message); }
    }
    void OnDown(object s, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        var before = Location;
        Native.ReleaseCapture();
        dragging = true;
        try { Native.SendMessage(Handle, 0xA1, 2, 0); }   // modal move loop; returns on mouse-up
        finally { dragging = false; }
        hover = ClientRectangle.Contains(PointToClient(Cursor.Position));   // mouse-leave is skipped by the move loop
        Kick();
        if (Location != before) { Location = ClampToScreens(Location); RefreshCachedState(); SavePos(); if (!GrabBackdrop()) Render(); }
    }

    // ---- visibility & z-order: event-driven (instant), with a slow safety-net timer ----
    readonly System.Windows.Forms.Timer showTimer = new System.Windows.Forms.Timer();   // debounce re-show
    readonly System.Windows.Forms.Timer topTimer = new System.Windows.Forms.Timer();    // second topmost pass
    readonly List<IntPtr> hooks = new List<IntPtr>();
    Native.WinEventProc winEvent;   // keep a reference so the GC never collects the callback
    IntPtr lastFg = IntPtr.Zero;

    // Shell surfaces that are screen-sized but are NOT fullscreen apps (alt-tab, task view, start, desktop ...)
    static readonly HashSet<string> ShellClasses = new HashSet<string> {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "XamlExplorerHostIslandWindow",
        "MultitaskingViewFrame", "TaskSwitcherWnd", "ForegroundStaging",
        "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow", "#32768", "Shell_InputSwitchTopLevelWindow" };

    void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (ev == 0x800B)   // location change: only the foreground window's own frame matters
        {
            if (idObject != 0 || hwnd != lastFg) return;
            // drag/resize fires this many times a second: check at most every 50 ms (a trailing
            // check via topTimer catches the final state), and do the z-order walk only once moves settle
            double nowMs = Clock.Elapsed.TotalMilliseconds;
            if (nowMs - lastLocMs < 50) { topTimer.Stop(); topTimer.Start(); return; }
            lastLocMs = nowMs;
            if (ShouldHide()) { showTimer.Stop(); if (Visible) Hide(); return; }
            topTimer.Stop(); topTimer.Start();
            return;
        }
        if (ev == 0x0003) { lastFg = hwnd; RehookLocation(hwnd); }
        Evaluate();
        if (ev == 0x0003) { topTimer.Stop(); topTimer.Start(); }   // re-check once the change settles
    }

    // Watch window moves/resizes only inside the active app's process (a system-wide hook would wake us on every mouse move).
    IntPtr locHook = IntPtr.Zero; uint locPid = 0;
    void RehookLocation(IntPtr fg)
    {
        uint pid = 0;
        if (fg != IntPtr.Zero) Native.GetWindowThreadProcessId(fg, out pid);
        if (pid == locPid && locHook != IntPtr.Zero) return;
        if (locHook != IntPtr.Zero) { Native.UnhookWinEvent(locHook); locHook = IntPtr.Zero; }
        locPid = pid;
        if (pid == 0 || pid == SelfPid) return;
        locHook = Native.SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, winEvent, pid, 0, 0x0002);
    }
    bool IsFullscreenForeground()
    {
        IntPtr fg = Native.GetForegroundWindow();
        if (fg == IntPtr.Zero || fg == Handle) return false;
        if (ShellClasses.Contains(Native.ClassOf(fg))) return false;
        if (Native.IsIconic(fg)) return false;
        Native.RECT r; if (!Native.GetWindowRect(fg, out r)) return false;
        var scr = myScreen;   // cached; refreshed by the guard / move / display change
        if (!(r.L <= scr.Left && r.T <= scr.Top && r.R >= scr.Right && r.B >= scr.Bottom)) return false;
        // A normal maximized window overhangs the screen by its ~8px frame (and only covers the whole
        // screen when the taskbar auto-hides). Real fullscreen (F11, video, games) matches the screen edge.
        if (Native.IsZoomed(fg) && (scr.Left - r.L) >= 4 && (r.R - scr.Right) >= 4) return false;
        return true;
    }
    bool ShouldHide() { return IsFullscreenForeground() || TaskbarAutoHidden(); }
    // Cached system state for the hot path (window-move events can fire 100+ times a second).
    Rectangle myScreen = Screen.PrimaryScreen.Bounds;
    bool autoHideOn = false;
    double lastLocMs = -1000;
    void RefreshCachedState()
    {
        try { myScreen = Screen.FromPoint(new Point(Left + PW / 2, Top + PH / 2)).Bounds; } catch { }
        lightBg = backdrop == null ? Native.LightTaskbar() : lightBg;
        try
        {
            var abd = new Native.APPBARDATA { cbSize = (uint)Marshal.SizeOf(typeof(Native.APPBARDATA)) };
            autoHideOn = (((uint)Native.SHAppBarMessage(4 /*ABM_GETSTATE*/, ref abd)) & 1) != 0;
        }
        catch { }
    }

    void Evaluate()
    {
        if (ShouldHide())
        {
            showTimer.Stop();
            if (Visible) Hide();          // hide instantly
            return;
        }
        if (!Visible) { if (!showTimer.Enabled) showTimer.Start(); return; }   // re-show after it settles (no flicker)
        KeepOnTop();
    }
    void ShowNow() { Show(); KeepOnTop(); topTimer.Stop(); topTimer.Start(); if (!GrabBackdrop()) Render(); }
    void KeepOnTop()
    {
        if (Visible && TaskbarAboveUs())
            Native.SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); // NOSIZE|NOMOVE|NOACTIVATE
    }
    void Guard()
    {
        RefreshCachedState();
        Evaluate();
        if (missedWhileIdle && Native.IdleMs() < 5000) { missedWhileIdle = false; Refresh_(); }
    }
    // With taskbar auto-hide on, hide the widget while the taskbar is slid away.
    bool TaskbarAutoHidden()
    {
        if (!autoHideOn) return false;                                // cached ABS_AUTOHIDE (cheap)
        try
        {
            IntPtr tray = TrayForMyMonitor();
            if (tray == IntPtr.Zero) return false;
            Native.RECT r; Native.GetWindowRect(tray, out r);
            var scr = Screen.FromHandle(tray).Bounds;                 // the taskbar's own monitor
            int visW = Math.Min(r.R, scr.Right) - Math.Max(r.L, scr.Left);
            int visH = Math.Min(r.B, scr.Bottom) - Math.Max(r.T, scr.Top);
            return visW < 8 || visH < 8;                              // only the reveal sliver is on screen
        }
        catch { return false; }
    }
    bool TaskbarAboveUs()
    {
        IntPtr h = Handle;
        for (int n = 0; n < 1024; n++)
        {
            h = Native.GetWindow(h, 3); // GW_HWNDPREV (higher in z-order)
            if (h == IntPtr.Zero) return false;
            if (!Native.IsWindowVisible(h)) continue;
            string cls = Native.ClassOf(h);
            if (cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return true;
        }
        return false;
    }

    // ---- backdrop (blurred copy of what is behind) ----
    readonly System.Windows.Forms.Timer grabTimer = new System.Windows.Forms.Timer();
    // Phase 1: exclude from capture, wait for DWM to compose a frame without us, then sample (phase 2).
    // Returns true when a grab is scheduled (the grab renders when it completes).
    // The taskbar on the monitor the widget sits on (primary or secondary).
    IntPtr TrayForMyMonitor()
    {
        var mine = Screen.FromHandle(Handle);
        IntPtr primary = Native.FindWindow("Shell_TrayWnd", null);
        if (mine.Primary) return primary;
        IntPtr h = IntPtr.Zero;
        while ((h = Native.FindWindowEx(IntPtr.Zero, h, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero)
            if (Screen.FromHandle(h).DeviceName == mine.DeviceName) return h;
        return primary;
    }
    bool GrabBackdrop()
    {
        if (!backdropAllowed || !IsHandleCreated || !Visible || dragging) return false;
        if (grabTimer.Enabled) { grabTimer.Stop(); grabTimer.Start(); return true; }   // moved again: wait for a clean frame
        bool ok = false;
        try { ok = Native.SetWindowDisplayAffinity(Handle, 0x11); } catch { }
        if (ok) grabTimer.Start();
        return ok;
    }
    void DoGrab()
    {
        if (!IsHandleCreated || !Visible) return;
        Bitmap small = null;
        try
        {
            // same rounding as the window itself (PW/PH), so the sample lines up at 125%/175%
            int off = (PW - (int)Math.Round(W * S)) / 2, pw = PW - 2 * off, ph = PH - 2 * off;
            using (var raw = new Bitmap(pw, ph, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(raw)) g.CopyFromScreen(Left + off, Top + off, 0, 0, new Size(pw, ph));
                int sw = Math.Max(2, W / 6), sh = Math.Max(2, H / 6);
                small = new Bitmap(sw, sh, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(small))
                using (var ia = new ImageAttributes())
                {
                    ia.SetWrapMode(WrapMode.TileFlipXY);
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    g.DrawImage(raw, new Rectangle(0, 0, sw, sh), 0, 0, pw, ph, GraphicsUnit.Pixel, ia);
                }
            }
            // light or dark behind us? (pick text colors to match)
            double lum = 0; int nPix = 0;
            for (int yy = 0; yy < small.Height; yy++)
                for (int xx = 0; xx < small.Width; xx++)
                { var px = small.GetPixel(xx, yy); lum += (0.2126 * px.R + 0.7152 * px.G + 0.0722 * px.B) / 255.0; nPix++; }
            // hysteresis: a background near the threshold must not flip the colors back and forth
            if (nPix > 0) { double avg = lum / nPix; if (avg > 0.62) lightBg = true; else if (avg < 0.48) lightBg = false; }
            string forced = Environment.GetEnvironmentVariable("USAGEGAUGE_THEME");   // testing aid: light | dark
            if (forced == "light") lightBg = true; else if (forced == "dark") lightBg = false;
            var old = backdrop; backdrop = small; small = null;
            if (old != null) old.Dispose();
        }
        catch (System.ComponentModel.Win32Exception) { }   // desktop locked / secure desktop: expected, keep old backdrop
        catch (Exception ex) { Log.Write("backdrop: " + ex.Message); }
        finally { if (small != null) small.Dispose(); }
    }

    // ---- data ----
    void Refresh_() { Refresh_(false, true); }
    void Refresh_(bool forceAg) { Refresh_(forceAg, true); }
    void Refresh_(bool forceAg, bool resetClock)
    {
        if (forceAg) Interlocked.Exchange(ref forceAgPending, 1);   // never lose a forced agy refresh
        if (Interlocked.Exchange(ref busy, 1) == 1) { Interlocked.Exchange(ref refreshPending, 1); return; }
        retryTimer.Stop();
        // restart the 5-min clock (no back-to-back runs) - except for the quick retry, which must not push the regular poll back
        if (resetClock) { refreshTimer.Stop(); refreshTimer.Start(); }
        bool force = Interlocked.Exchange(ref forceAgPending, 0) == 1;
        int gen = Interlocked.Increment(ref generation);
        double nowMs = Clock.Elapsed.TotalMilliseconds;
        UpdateVisible();   // pick up a service that was just set up, before deciding what to poll
        bool agShown = Shown_("ag-gemini") || Shown_("ag-3p");
        bool includeAg = agShown && (force || nowMs - lastAgMs >= AG_EVERY_MS);
        bool[] want = { Shown_("codex"), Shown_("claude"), Shown_("grok") };
        if (includeAg) lastAgMs = nowMs;
        ThreadPool.QueueUserWorkItem(delegate
        {
            Dictionary<string, Quota> got = null;
            try { got = FetchAll(includeAg, want); }
            catch (Exception ex) { Log.Write("refresh: " + ex.Message); }
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    try
                    {
                        if (got == null)   // FetchAll itself blew up: still go through the failure path
                        {
                            got = new Dictionary<string, Quota>();
                            for (int i = 0; i < 3; i++) got[Ids[i]] = Err(Names[i], "Lookup error");
                            if (includeAg) for (int i = 3; i < N; i++) got[Ids[i]] = Err(Names[i], "Lookup error");
                        }
                        if (gen == generation) Apply(got);
                    }
                    finally
                    {
                        Interlocked.Exchange(ref busy, 0);
                        if (Interlocked.Exchange(ref refreshPending, 0) == 1) Refresh_();
                    }
                });
            }
            catch { Interlocked.Exchange(ref busy, 0); }   // form gone
        });
    }

    // Merge fresh results; on failure keep the last good numbers and mark them stale.
    void Apply(Dictionary<string, Quota> got)
    {
        bool wasLoading = loading, changed = false, anyBad = false;
        for (int i = 0; i < N; i++)
        {
            double before = qs[i].Ok ? qs[i].Remaining : -1;
            if (!got.ContainsKey(Ids[i])) continue;   // not polled this round (agy every 15 min): don't let it trigger retries
            qs[i] = Merge(qs[i], got[Ids[i]], i >= 3 ? STALE_AG_MIN : STALE_MAIN_MIN);
            double after = qs[i].Ok ? qs[i].Remaining : -1;
            if (Math.Abs(after - before) > 0.05) changed = true;
            if (qs[i].Failing || !qs[i].Ok) anyBad = true;
        }
        loading = false;
        UpdateVisible();   // a service may have been set up (or removed) since the last round
        agFailedLast = got.ContainsKey("ag-gemini") && (!got["ag-gemini"].Ok || !got["ag-3p"].Ok);
        // at most ONE quick retry per 5-min cycle (a broken provider must not trigger a CLI run every minute)
        if (anyBad && !retriedOnce) { retriedOnce = true; retryTimer.Start(); }
        else if (!anyBad) retriedOnce = false;
        UpdateTip();
        if (wasLoading || changed)
        {
            for (int i = 0; i < N; i++) from[i] = shown[i];
            animStartMs = Clock.Elapsed.TotalMilliseconds;
            Kick();
        }
        else Render();   // numbers unchanged: one redraw (countdown / stale marker), no animation
    }
    // A single blip keeps the last good numbers silently; the amber dot appears only once they are old.
    static Quota Merge(Quota prev, Quota fresh, int staleAfterMin)
    {
        if (fresh.Ok) { fresh.LastOkUtc = DateTime.UtcNow; return fresh; }
        if (prev.Ok)
        {
            prev.Failing = true; prev.Error = fresh.Error;
            // network blips heal by themselves; auth/format errors won't, so show those right away
            prev.Stale = !IsTransient(fresh.Error) || (DateTime.UtcNow - prev.LastOkUtc).TotalMinutes >= staleAfterMin;
            Log.Write(prev.Name + " fetch failed: " + fresh.Error);
            return prev;
        }
        Log.Write(fresh.Name + " failed: " + fresh.Error);
        return fresh;
    }

    static bool IsTransient(string err)
    {
        if (string.IsNullOrEmpty(err)) return true;
        return err.StartsWith("Timed out") || err.StartsWith("Empty output") || err.StartsWith("Empty response") || err.StartsWith("Lookup error") || err.StartsWith("Rate limited")
            || err.IndexOf("timed out", StringComparison.OrdinalIgnoreCase) >= 0
            || err.IndexOf("connect", StringComparison.OrdinalIgnoreCase) >= 0
            || err.IndexOf("network", StringComparison.OrdinalIgnoreCase) >= 0
            || err.IndexOf("dns", StringComparison.OrdinalIgnoreCase) >= 0
            || err.IndexOf(" 5", StringComparison.Ordinal) >= 0 && err.IndexOf("server", StringComparison.OrdinalIgnoreCase) >= 0;
    }
    // Amber dot: last fetch failed and the numbers are old/unusable, OR the numbers are simply old
    // (e.g. polling was paused while the PC was unattended).
    static bool ShowDot(Quota q, int idx)
    {
        if (!q.Ok) return false;
        if (q.Stale) return true;
        if (q.LastOkUtc == DateTime.MinValue) return false;
        return (DateTime.UtcNow - q.LastOkUtc).TotalMinutes >= (idx >= 3 ? STALE_AG_MIN : STALE_MAIN_MIN);
    }

    static string NameOf(string id) { int i = Array.IndexOf(Ids, id); return i >= 0 ? Names[i] : id; }

    // One refresh: Codex, Claude and Grok over HTTPS (in parallel) and, when due, Antigravity via `agy -p /usage`.
    static Dictionary<string, Quota> FetchAll(bool includeAg) { return FetchAll(includeAg, new[] { true, true, true }); }
    static Dictionary<string, Quota> FetchAll(bool includeAg, bool[] want)
    {
        var res = new Dictionary<string, Quota>();
        var jobs = new List<KeyValuePair<string, Func<Quota>>>();
        if (want[0]) jobs.Add(new KeyValuePair<string, Func<Quota>>("codex", Usage.Codex));
        if (want[1]) jobs.Add(new KeyValuePair<string, Func<Quota>>("claude", Usage.Claude));
        if (want[2]) jobs.Add(new KeyValuePair<string, Func<Quota>>("grok", Usage.Grok));
        Quota[] agOut = null;
        var threads = new List<KeyValuePair<string, Thread>>();
        var results = new Dictionary<string, Quota>();
        foreach (var j in jobs)
        {
            var job = j;
            int slot = Array.IndexOf(MainIds, job.Key);
            // a previous worker for this service is still stuck: don't pile another one on top
            if (Interlocked.CompareExchange(ref running[slot], 1, 0) != 0) { lock (results) results[job.Key] = Err(NameOf(job.Key), "Timed out (previous request still running)"); continue; }
            var t = new Thread(() =>
            {
                Quota q;
                try { q = job.Value(); } catch (Exception ex) { q = Err(NameOf(job.Key), Sanitize(ex.Message)); }
                finally { Interlocked.Exchange(ref running[slot], 0); }
                q.Name = NameOf(job.Key);
                lock (results) if (!results.ContainsKey(job.Key)) results[job.Key] = q;
            });
            t.IsBackground = true; t.Start();
            threads.Add(new KeyValuePair<string, Thread>(job.Key, t));
        }
        Thread agThread = null;
        if (includeAg)
        {
            agThread = new Thread(() =>
            {
                Quota[] r;
                try { r = Antigravity(); }
                catch (Exception ex) { string m = "agy: " + Sanitize(ex.Message); r = new[] { Err(NameOf("ag-gemini"), m), Err(NameOf("ag-3p"), m) }; }
                Thread.MemoryBarrier(); agOut = r;
            });
            agThread.IsBackground = true; agThread.Start();
        }
        var sw = Stopwatch.StartNew();
        foreach (var t in threads)
        {
            int left = Math.Max(0, HTTP_TIMEOUT_MS * 3 + 5000 - (int)sw.ElapsedMilliseconds);   // usage + renew + usage, plus re-check pause
            if (!t.Value.Join(left)) lock (results) if (!results.ContainsKey(t.Key)) results[t.Key] = Err(NameOf(t.Key), "Timed out");
        }
        lock (results) foreach (var kv in results) res[kv.Key] = kv.Value;
        for (int i = 0; i < MainIds.Length; i++) if (want[i] && !res.ContainsKey(MainIds[i])) res[MainIds[i]] = Err(NameOf(MainIds[i]), "Timed out");

        if (agThread != null)
        {
            bool joined = agThread.Join(CLI_TIMEOUT_MS + 5000);
            Thread.MemoryBarrier();
            Quota[] ag = joined ? agOut : null;
            res["ag-gemini"] = ag != null ? ag[0] : Err(NameOf("ag-gemini"), "Timed out");
            res["ag-3p"] = ag != null ? ag[1] : Err(NameOf("ag-3p"), "Timed out");
        }
        return res;
    }

    // Antigravity: the official CLI's own `/usage` slash command (no model call, no tokens).
    static Quota[] Antigravity()
    {
        string gName = NameOf("ag-gemini"), pName = NameOf("ag-3p");
        string agy = Usage.FindAgy();
        if (agy == null) return new[] { Err(gName, "agy not found"), Err(pName, "agy not found") };
        string work = Path.Combine(Path.GetTempPath(), "UsageGauge-agy");
        try { Directory.CreateDirectory(work); } catch { }
        object parsed;
        string fail = RunCli(agy, "-p /usage --output-format json --print-timeout 25s", work, out parsed);
        if (fail != null) return new[] { Err(gName, fail), Err(pName, fail) };
        var buckets = new Dictionary<string, Dictionary<string, object>>();
        try
        {
            var root = parsed as Dictionary<string, object>;
            var cmd = root["command"] as Dictionary<string, object>;
            var data = cmd["data"] as Dictionary<string, object>;
            foreach (var go in (object[])data["groups"])
            {
                var g = go as Dictionary<string, object>; if (g == null) continue;
                foreach (var bo in (object[])g["buckets"])
                {
                    var b = bo as Dictionary<string, object>; object id;
                    if (b != null && b.TryGetValue("id", out id) && id != null) buckets[id.ToString()] = b;
                }
            }
        }
        catch { string m = "agy response format changed"; return new[] { Err(gName, m), Err(pName, m) }; }

        // Gemini: the general weekly pool and the Gemini 4 Argon weekly pool; show the tighter one.
        Quota gen = Bucket(buckets, "gemini-weekly", gName), argon = null;
        foreach (var kv in buckets)
            if (kv.Key.StartsWith("gemini-") && kv.Key.EndsWith("-weekly") && kv.Key != "gemini-weekly") { argon = Bucket(buckets, kv.Key, gName); break; }
        Quota gem = gen;
        if (gen.Ok && argon != null) gem = argon.Ok ? (argon.Remaining < gen.Remaining ? argon : gen) : argon;
        return new[] { gem, Bucket(buckets, "3p-weekly", pName) };
    }
    static Quota Bucket(Dictionary<string, Dictionary<string, object>> buckets, string id, string name)
    {
        Dictionary<string, object> b;
        if (!buckets.TryGetValue(id, out b)) return Err(name, "Limit not found");
        object w, rf, rt;
        if (b.TryGetValue("window", out w) && w != null && w.ToString() != "weekly") return Err(name, "Not a weekly limit");
        if (!b.TryGetValue("remaining_fraction", out rf) || rf == null) return Err(name, "Remaining amount missing");
        double frac;
        try { frac = Convert.ToDouble(rf, CultureInfo.InvariantCulture); } catch { return Err(name, "Invalid value"); }
        if (double.IsNaN(frac) || frac < -0.005 || frac > 1.005) return Err(name, "Invalid value");
        var q = new Quota { Name = name, Ok = true, Remaining = Math.Max(0, Math.Min(100, frac * 100)) };
        if (b.TryGetValue("reset_time", out rt) && rt != null) q.ResetsAt = Usage.ParseTime(rt);
        return q;
    }

    // Runs a CLI inside a kill-on-close job with one hard deadline. Returns null on success, else a failure text.
    static string RunCli(string exe, string args, string workDir, out object parsedOut)
    {
        parsedOut = null;
        if (exe == null || !File.Exists(exe)) return "CLI not found";
        Process p = null; IntPtr job = IntPtr.Zero;
        var outBuf = new StringBuilder(); var errBuf = new StringBuilder();
        var outDone = new ManualResetEvent(false); var errDone = new ManualResetEvent(false);
        bool overflow = false;
        string failure = null;
        try
        {
            var psi = new ProcessStartInfo(exe, args);
            if (workDir != null) psi.WorkingDirectory = workDir;
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
            p = new Process { StartInfo = psi };
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) { try { outDone.Set(); } catch { } return; }   // may arrive after we closed the handle
                lock (outBuf) { if (outBuf.Length < MAX_OUT) outBuf.AppendLine(e.Data); else overflow = true; }
            };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) { try { errDone.Set(); } catch { } return; }
                lock (errBuf) { if (errBuf.Length < 2048) errBuf.AppendLine(e.Data); }
            };
            job = Native.NewKillJob();
            p.Start();
            bool inJob = false;
            if (job != IntPtr.Zero) { try { inJob = Native.AssignProcessToJobObject(job, p.Handle); } catch { } }
            if (!inJob) Log.Write("job assign failed; falling back to parent-only kill");
            p.BeginOutputReadLine(); p.BeginErrorReadLine();

            var sw = Stopwatch.StartNew();
            Func<int> left = delegate { return Math.Max(0, CLI_TIMEOUT_MS - (int)sw.ElapsedMilliseconds); };
            bool exited = p.WaitForExit(left());
            if (!exited) { try { exited = p.HasExited; } catch { } }
            if (exited)
            {
                // The CLI is done. A leftover child can still hold the stdout pipe open (no EOF until it dies),
                // which used to burn the whole 30 s and discard good output. Kill the tree now, then drain briefly.
                if (job != IntPtr.Zero) { Native.CloseHandle(job); job = IntPtr.Zero; }
                outDone.WaitOne(1500); errDone.WaitOne(300);
            }
            string json; lock (outBuf) json = outBuf.ToString();
            if (!exited) failure = "Timed out (" + (int)sw.Elapsed.TotalSeconds + "s, still running)";
            else if (overflow) failure = "Response too large";
            else if (json.Trim().Length == 0) failure = "Empty output (" + (int)sw.Elapsed.TotalSeconds + "s)";

            if (failure == null)
            {
                // agy prints one JSON object (sometimes followed by extra lines): parse the first line that is JSON
                object parsed = null;
                foreach (var line in json.Split('\n'))
                {
                    string tl = line.Trim();
                    if (!tl.StartsWith("{")) continue;
                    try { parsed = new JavaScriptSerializer { MaxJsonLength = MAX_OUT }.DeserializeObject(tl); break; } catch { }
                }
                var dict = parsed as Dictionary<string, object>; object eo, st;
                if (dict == null) failure = "Empty response (exit " + p.ExitCode + ")";
                else if (dict.TryGetValue("status", out st) && st != null && st.ToString() != "SUCCESS")
                    failure = Sanitize(dict.TryGetValue("error", out eo) && eo != null ? eo.ToString() : st.ToString());
                else parsedOut = parsed;
            }
        }
        catch (Exception ex) { failure = ex.Message; }
        finally
        {
            if (job != IntPtr.Zero) Native.CloseHandle(job);            // kills the CLI and anything it spawned
            if (p != null) { try { if (!p.HasExited) p.Kill(); } catch { } p.Dispose(); }
            outDone.Close(); errDone.Close();
        }
        if (failure != null)
        {
            string err; lock (errBuf) err = Sanitize(errBuf.ToString());
            Log.Write("cli (" + Path.GetFileNameWithoutExtension(exe) + "): " + failure + (err.Length > 0 ? " | " + err : ""));
        }
        return failure;
    }
    static Quota Err(string name, string msg) { return new Quota { Name = name, Error = msg }; }
    static string Sanitize(string s)
    {
        s = Regex.Replace(s, @"\x1B\[[0-9;]*m", "");                 // ANSI colors
        s = Regex.Replace(s, @"[A-Za-z0-9_\-\.=+/]{32,}", "…");     // anything token-like
        s = s.Replace("\r", " ").Replace("\n", " ").Trim();
        return s.Length > 300 ? s.Substring(0, 300) + "…" : s;
    }
    static string ResetShort(DateTime? t)
    {
        if (t == null) return "";
        var d = t.Value - DateTime.UtcNow;
        if (d.TotalSeconds <= 0) return L.T("갱신 대기", "updating");
        if (d.TotalMinutes < 1) return L.T("곧 리셋", "resets now");
        int days = (int)d.TotalDays, hours = (int)d.TotalHours, mins = (int)d.TotalMinutes;
        if (d.TotalHours < 1) return L.T(mins + "분", mins + "m");
        if (d.TotalHours < 3) return L.T(hours + "시간 " + d.Minutes + "분", hours + "h " + d.Minutes + "m");
        if (d.TotalDays < 1) return L.T(hours + "시간", hours + "h");
        return L.T(days + "일 " + d.Hours + "시간", days + "d " + d.Hours + "h");
    }
    // Right-click menu, rebuilt each time it opens so it follows the current language.
    void BuildMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add(L.T("새로고침", "Refresh"), null, delegate { Refresh_(true); });
        var lang = new ToolStripMenuItem(L.T("언어 / Language", "Language / 언어"));
        foreach (var opt in new[] { new[] { "auto", L.T("자동 (Windows 언어)", "Auto (Windows language)") }, new[] { "ko", "한국어" }, new[] { "en", "English" } })
        {
            string mode = opt[0];
            var it = new ToolStripMenuItem(opt[1]) { Checked = L.Mode == mode };
            it.Click += delegate { L.Set(mode); UpdateTip(); Render(); };
            lang.DropDownItems.Add(it);
        }
        menu.Items.Add(lang);
        var gauges = new ToolStripMenuItem(L.T("표시할 항목", "Gauges"));
        for (int i = 0; i < N; i++)
        {
            int idx = i; bool avail = Available(i);
            var it = new ToolStripMenuItem(Names[i] + (avail ? "" : L.T("  (이 PC에 로그인 없음)", "  (not set up on this PC)")))
                { Checked = avail && !Hidden.Contains(Ids[i]), Enabled = avail };
            it.Click += delegate
            {
                if (Hidden.Contains(Ids[idx])) Hidden.Remove(Ids[idx]); else Hidden.Add(Ids[idx]);
                SaveHidden(); UpdateVisible(); UpdateTip(); Refresh_(true);
            };
            gauges.DropDownItems.Add(it);
        }
        menu.Items.Add(gauges);
        var renew = new ToolStripMenuItem(L.T("Claude·Grok 로그인 자동 갱신 (실험적)", "Renew Claude/Grok logins (experimental)"))
            { Checked = Usage.RenewLogins, ToolTipText = L.T(
                "켜면 로그인이 만료됐을 때 위젯이 대신 갱신해요. 끄면 Claude Code·grok을 쓸 때만 값이 갱신돼요.",
                "When on, the widget renews an expired login itself. When off, values update only while you use Claude Code / grok.") };
        renew.Click += delegate { Usage.SetRenew(!Usage.RenewLogins); Refresh_(); };
        menu.Items.Add(renew);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L.T("종료", "Quit"), null, delegate { Close(); });
    }

    void UpdateTip()
    {
        var sbt = new StringBuilder();
        foreach (int i in Vis) sbt.Append(Line(qs[i])).Append("\n");
        tip.SetToolTip(this, sbt.ToString() + L.T(
            "\nCodex·Claude·Grok 5분, Antigravity 15분마다 갱신 (자리 비우면 쉬었다가 돌아오면 바로 갱신)\n주황 점: 값이 오래됐거나 갱신이 계속 실패하는 중\n드래그: 이동 · 우클릭: 새로고침/언어/종료",
            "\nCodex·Claude·Grok every 5 min, Antigravity every 15 min (paused while you're away)\nAmber dot: the value is out of date or updates keep failing\nDrag: move · Right-click: refresh/language/quit"));
    }
    static string Line(Quota q)
    {
        if (!q.Ok) return q.Name + L.T(" 주간: 읽기 실패 (", " weekly: unavailable (") + q.Error + ")";
        string r = q.ResetsAt.HasValue ? L.T(" · 리셋 ", " · resets ") + q.ResetsAt.Value.ToLocalTime().ToString(L.T("M/d (ddd) HH:mm", "ddd MMM d, HH:mm"), L.Culture) : "";
        string at = q.LastOkUtc.ToLocalTime().ToString("HH:mm");
        string st = q.Failing
            ? L.T("\n   ⚠ " + at + " 값 표시 중 (최근 갱신 실패: ", "\n   ⚠ showing the " + at + " value (last update failed: ") + q.Error + ")"
            : L.T(" · " + at + " 기준", " · as of " + at);
        return q.Name + L.T(" 주간 " + Math.Round(q.Remaining) + "% 남음", " weekly " + Math.Round(q.Remaining) + "% left") + r + st;
    }

    // ---- animation (timer only runs while something moves) ----
    void Kick() { if (!animTimer.Enabled) animTimer.Start(); }
    static double EaseOut(double t) { t = Math.Max(0, Math.Min(1, t)); return 1 - Math.Pow(1 - t, 4); }
    void Step()
    {
        bool moving = false;
        if (!loading)
        {
            double t = (Clock.Elapsed.TotalMilliseconds - animStartMs) / ANIM_MS;
            double e = EaseOut(t);
            for (int i = 0; i < N; i++) shown[i] = from[i] + ((qs[i].Ok ? qs[i].Remaining : 0) - from[i]) * e;
            moving = t < 1;
        }
        float target = hover ? 1f : 0f;
        if (Math.Abs(hoverT - target) > 0.01f) { hoverT += (target - hoverT) * 0.18f; moving = true; } else hoverT = target;
        Render();
        if (!moving) animTimer.Stop();
    }

    // ---- colors / geometry helpers ----
    static Color Lerp(Color a, Color b, double t)
    {
        t = Math.Max(0, Math.Min(1, t));
        return Color.FromArgb((int)(a.A + (b.A - a.A) * t), (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
    static readonly Color CHigh = Color.FromArgb(52, 211, 153), CMid = Color.FromArgb(251, 191, 36), CLow = Color.FromArgb(244, 63, 94);
    static Color Level(double rem)
    {
        if (rem >= 60) return CHigh;
        if (rem >= 30) return Lerp(CMid, CHigh, (rem - 30) / 30.0);
        if (rem >= 10) return Lerp(CLow, CMid, (rem - 10) / 20.0);
        return CLow;
    }
    static Color A(Color c, int a) { return Color.FromArgb(a, c.R, c.G, c.B); }
    static GraphicsPath Round(RectangleF r, float rad)
    {
        var p = new GraphicsPath(); float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
    static GraphicsPath TextPath(string s, FontFamily ff, FontStyle st, float emPx, float x)
    {
        var p = new GraphicsPath();
        float ascent = emPx * ff.GetCellAscent(st) / ff.GetEmHeight(st);
        p.AddString(s, ff, (int)st, emPx, new PointF(x, -ascent), Typo);
        return p;
    }
    static void Shift(GraphicsPath p, float dx, float dy)
    {
        using (var m = new Matrix()) { m.Translate(dx, dy); p.Transform(m); }
    }

    // ---- rendering (only on data change, animation, hover, move, or the 30 s slow tick) ----
    void Render()
    {
        if (!IsHandleCreated || !Visible) return;
        if (dragging && !animTimer.Enabled) return;   // don't fight the move loop
        try
        {
            using (var bmp = new Bitmap(PW, PH, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.Clear(Color.Transparent);
                    g.ScaleTransform(S, S);          // draw in 100% units, scaled to the display
                    g.TranslateTransform(SH, SH);
                    DrawAll(g);
                }
                Push(bmp);
            }
        }
        catch (Exception ex) { Log.Write("render: " + ex.Message); }
    }

    // On-demand preview for screenshots (the widget is excluded from screen capture):
    // create "preview.flag" in the app folder; within 30 s the widget writes preview.png.
    void CheckPreviewRequest()
    {
        try
        {
            string flag = Path.Combine(Dir, "preview.flag");
            if (!File.Exists(flag)) return;
            File.Delete(flag);
            DumpPreview(Path.Combine(Dir, "preview.png"));
        }
        catch (Exception ex) { Log.Write("preview: " + ex.Message); }
    }
    void DumpPreview(string file)
    {
        using (var bmp = new Bitmap(PW, PH, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.CompositingQuality = CompositingQuality.HighQuality;
                g.ScaleTransform(S, S);
                g.TranslateTransform(SH, SH);
                DrawAll(g);
            }
            bmp.Save(file, ImageFormat.Png);
        }
    }

    void DrawAll(Graphics g)
    {
        DrawPanel(g);
        if (Vis.Length == 0)   // nothing to show: a small hint instead of gauges
        {
            string msg = L.T("표시할 항목 없음 · 우클릭", "Nothing to show · right-click");
            using (var p = TextPath(msg, FKor, FontStyle.Regular, SUB_PX, 0))
            {
                var b = p.GetBounds();
                Shift(p, (W - b.Width) / 2f - b.X, H / 2f + SUB_PX * 0.35f);
                using (var br = new SolidBrush(Ink(200))) g.FillPath(br, p);
            }
            return;
        }
        for (int k = 0; k < Vis.Length; k++)
        {
            int i = Vis[k];
            float x = PADX + k * (BLOCK + SEP);
            if (k > 0) DrawDivider(g, x - SEP / 2f);
            DrawBlock(g, qs[i], shown[i], x, i);
        }
    }

    void DrawPanel(Graphics g)
    {
        var r = new RectangleF(0.5f, 0.5f, W - 1f, H - 1f);
        using (var shadow = new SolidBrush(Color.FromArgb(9, 0, 0, 0)))
            for (int i = SH; i >= 1; i--)
            {
                var sr = new RectangleF(r.X - i + 0.5f, r.Y - i + 1.5f, r.Width + 2 * i - 1, r.Height + 2 * i - 1);
                using (var sp = Round(sr, RADIUS + i)) g.FillPath(shadow, sp);
            }
        using (var path = Round(r, RADIUS))
        {
            var state = g.Save();
            g.SetClip(path, CombineMode.Intersect);
            if (backdrop != null)
                using (var ia = new ImageAttributes())
                {
                    ia.SetWrapMode(WrapMode.TileFlipXY);
                    g.DrawImage(backdrop, new Rectangle(-1, -1, W + 2, H + 2), 0, 0, backdrop.Width, backdrop.Height, GraphicsUnit.Pixel, ia);
                }
            else
                using (var fb = new SolidBrush(lightBg ? Color.FromArgb(170, 245, 245, 248) : Color.FromArgb(150, 30, 26, 40))) g.FillPath(fb, path);   // fallback when blur is unavailable
            int a1 = (int)(13 + 16 * hoverT), a2 = (int)(2 + 10 * hoverT);
            using (var bg = new LinearGradientBrush(new RectangleF(0, 0, W, H), Color.FromArgb(a1, 255, 255, 255), Color.FromArgb(a2, 255, 255, 255), 25f))
                g.FillPath(bg, path);
            var sheen = new RectangleF(0, 0, W, H * 0.55f);
            using (var sb = new LinearGradientBrush(sheen, Color.FromArgb(12, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), LinearGradientMode.Vertical))
                g.FillRectangle(sb, sheen);
            g.Restore(state);
            using (var bb = lightBg
                ? new LinearGradientBrush(new RectangleF(0, 0, W, H), Color.FromArgb((int)(55 + 25 * hoverT), 0, 0, 0), Color.FromArgb(25, 0, 0, 0), 35f)
                : new LinearGradientBrush(new RectangleF(0, 0, W, H), Color.FromArgb((int)(130 + 40 * hoverT), 255, 255, 255), Color.FromArgb(22, 255, 255, 255), 35f))
            using (var pen = new Pen(bb, 1f))
                g.DrawPath(pen, path);
        }
    }

    // Text/line color that contrasts with what is behind the widget.
    bool lightBg = false;
    Color Ink(int alpha) { return lightBg ? Color.FromArgb(alpha, 0, 0, 0) : Color.FromArgb(alpha, 255, 255, 255); }

    void DrawDivider(Graphics g, float x)
    {
        var rect = new RectangleF(x - 0.5f, 9, 1, H - 18);
        using (var div = new LinearGradientBrush(new RectangleF(rect.X, rect.Y - 1, 1, rect.Height + 2), Color.Transparent, Color.Transparent, LinearGradientMode.Vertical))
        {
            var cb = new ColorBlend(3);
            cb.Colors = new[] { Ink(0), Ink(45), Ink(0) };
            cb.Positions = new[] { 0f, 0.5f, 1f };
            div.InterpolationColors = cb;
            g.FillRectangle(div, rect);
        }
    }

    void DrawLogoPath(Graphics g, GraphicsPath logo, RectangleF lr, Color color)
    {
        using (var p = (GraphicsPath)logo.Clone())
        {
            var b = p.GetBounds();
            float s = lr.Width / Math.Max(b.Width, b.Height);
            using (var m = new Matrix())
            {
                m.Translate(lr.X + (lr.Width - b.Width * s) / 2f, lr.Y + (lr.Height - b.Height * s) / 2f);
                m.Scale(s, s);
                m.Translate(-b.X, -b.Y);
                p.Transform(m);
            }
            using (var br = new SolidBrush(color)) g.FillPath(br, p);
        }
    }

    void DrawBlock(Graphics g, Quota q, double shown, float x, int idx)
    {
        float cy = H / 2f;
        bool ok = q.Ok && !loading;
        Color c = ok ? Level(shown) : Color.FromArgb(150, 150, 160);

        var ring = new RectangleF(x, cy - RING / 2f, RING, RING);
        var arcRect = RectangleF.Inflate(ring, -STROKE / 2f, -STROKE / 2f);
        using (var tp = new Pen(Ink(lightBg ? 40 : 38), STROKE)) g.DrawEllipse(tp, arcRect);
        float sweep = (float)(360.0 * Math.Max(0, Math.Min(100, shown)) / 100.0);
        if (ok && sweep > 0.5f)
        {
            using (var gp = new Pen(A(c, 45), STROKE + 3f)) { gp.StartCap = gp.EndCap = LineCap.Round; g.DrawArc(gp, arcRect, -90, sweep); }
            using (var ap = new Pen(c, STROKE)) { ap.StartCap = ap.EndCap = LineCap.Round; g.DrawArc(ap, arcRect, -90, sweep); }
        }

        if (!loading && ShowDot(q, idx))   // amber dot: numbers are the last good ones and are out of date
            using (var sb = new SolidBrush(Color.FromArgb(240, 251, 191, 36)))
            using (var sp = new Pen(Color.FromArgb(200, 20, 20, 28), 1.2f))
            {
                var dot = new RectangleF(ring.Right - 8, ring.Y, 8, 8);
                g.FillEllipse(sb, dot); g.DrawEllipse(sp, dot);
            }

        var lr = new RectangleF(ring.X + (RING - LOGO) / 2f, ring.Y + (RING - LOGO) / 2f, LOGO, LOGO);
        if (idx == 3 && geminiLogo != null) g.DrawImage(geminiLogo, lr);
        else if (idx == 4 && agLogo != null) g.DrawImage(agLogo, lr);
        else if (idx == 0 && codexLogo != null) g.DrawImage(codexLogo, lr);
        else if (idx == 1 && claudeLogo != null) DrawLogoPath(g, claudeLogo, lr, Color.FromArgb(217, 119, 87));
        else if (idx == 2 && grokLogo != null)
        {
            var gr = RectangleF.Inflate(lr, -0.5f, -0.5f);
            if (!lightBg) g.DrawImage(grokLogo, gr);
            else using (var ia = new ImageAttributes())   // the Grok mark is white: draw it dark on a light taskbar
            {
                ia.SetColorMatrix(new ColorMatrix(new[] {
                    new float[] { -1, 0, 0, 0, 0 }, new float[] { 0, -1, 0, 0, 0 }, new float[] { 0, 0, -1, 0, 0 },
                    new float[] { 0, 0, 0, 1, 0 }, new float[] { 0.9f, 0.9f, 0.9f, 0, 1 } }));
                g.DrawImage(grokLogo, new[] { gr.Location, new PointF(gr.Right, gr.Top), new PointF(gr.Left, gr.Bottom) },
                    new RectangleF(0, 0, grokLogo.Width, grokLogo.Height), GraphicsUnit.Pixel, ia);
            }
        }

        float tx = ring.Right + TEXT_GAP;
        string num = loading ? "··" : (q.Ok ? ((int)Math.Round(shown)).ToString() : "!");
        string sub = loading ? L.T("불러오는 중", "loading") : (q.Ok ? ResetShort(q.ResetsAt) : L.T("읽기 실패", "unavailable"));

        using (var p1 = TextPath(num, FNum, FontStyle.Bold, NUM_PX, 0))
        using (var p2 = TextPath(sub, FKor, FontStyle.Regular, SUB_PX, 0))
        {
            if (ok)
            {
                float adv = g.MeasureString(num, NumFont, 1000, Typo).Width;
                using (var pp = TextPath("%", FNum, FontStyle.Regular, PCT_PX, adv + 1.5f)) p1.AddPath(pp, false);
            }
            float cap = NUM_PX * 0.70f, subAsc = SUB_PX * 0.80f;
            float total = cap + LINE_GAP + subAsc;
            float base1 = cy - total / 2f + cap;
            float base2 = base1 + LINE_GAP + subAsc;
            var b1 = p1.GetBounds(); var b2 = p2.GetBounds();
            Shift(p1, tx - b1.X, base1);
            Shift(p2, tx - b2.X, base2);
            // keep text inside its own column so a long string can't run into the next gauge
            var clipState = g.Save();
            g.SetClip(new RectangleF(tx - 1, 0, TEXT_W + 2, H), CombineMode.Intersect);
            using (var wb = new SolidBrush(lightBg ? Color.FromArgb(245, 22, 22, 28) : Color.FromArgb(250, 255, 255, 255))) g.FillPath(wb, p1);
            using (var sb = new SolidBrush(lightBg ? Color.FromArgb(225, 70, 70, 82) : Color.FromArgb(222, 222, 222, 232))) g.FillPath(sb, p2);
            g.Restore(clipState);
        }
    }

    void Push(Bitmap bmp)
    {
        IntPtr screenDc = IntPtr.Zero, memDc = IntPtr.Zero, hBmp = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            screenDc = Native.GetDC(IntPtr.Zero);
            memDc = Native.CreateCompatibleDC(screenDc);
            hBmp = bmp.GetHbitmap(Color.FromArgb(0));
            old = Native.SelectObject(memDc, hBmp);
            var size = new Native.SIZE(bmp.Width, bmp.Height); var src = new Native.POINT(0, 0); var pos = new Native.POINT(Left, Top);
            var blend = new Native.BLEND { Op = 0, Flags = 0, Alpha = 255, Format = 1 };
            Native.UpdateLayeredWindow(Handle, screenDc, ref pos, ref size, memDc, ref src, 0, ref blend, 2);
        }
        finally
        {
            if (old != IntPtr.Zero) Native.SelectObject(memDc, old);
            if (hBmp != IntPtr.Zero) Native.DeleteObject(hBmp);
            if (memDc != IntPtr.Zero) Native.DeleteDC(memDc);
            if (screenDc != IntPtr.Zero) Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) { Log.Write("ui: " + e.Exception); };
        AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { Log.Write("fatal: " + e.ExceptionObject); };

        Mutex m = null; bool created = false;
        try { m = new Mutex(true, "UsageGauge_SingleInstance", out created); }
        catch (AbandonedMutexException) { created = true; }   // previous instance died: take over
        catch (Exception ex) { Log.Write("mutex: " + ex.Message); created = true; }
        if (!created) { if (m != null) m.Dispose(); return; }

        try { Native.SetProcessDPIAware(); } catch { }
        try { System.Net.ServicePointManager.SecurityProtocol |= (System.Net.SecurityProtocolType)3072; } catch { }   // TLS 1.2
        try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        Application.EnableVisualStyles();
        L.Load();
        Usage.LoadSettings();
        Usage.CleanupTemps();

        Application.Run(new GaugeForm());
        GC.KeepAlive(m);
    }
}
