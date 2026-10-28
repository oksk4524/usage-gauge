// UsageGauge - Codex / Claude / Grok / Antigravity weekly quota on the taskbar (glass ring gauges).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("UsageGauge")]
[assembly: AssemblyProduct("UsageGauge")]
[assembly: AssemblyDescription("Weekly AI quota gauges on the Windows taskbar")]
[assembly: AssemblyCompany("oksk4524")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

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
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("uxtheme.dll", EntryPoint = "#135")] static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#136")] static extern void FlushMenuThemes();
    // Native menus in the widget's light/dark look. Undocumented uxtheme calls (Windows 10 1903+, as used by
    // many desktop apps); skipped on older builds, where menus simply stay in the default look.
    public static void MenuTheme(bool dark)
    {
        if (WinBuild() < 18362) return;
        try { SetPreferredAppMode(dark ? 2 : 3); FlushMenuThemes(); } catch { }   // 2 = force dark, 3 = force light
    }
    static int build = -1;
    static int WinBuild()
    {
        if (build >= 0) return build;
        build = 0;
        try
        {
            using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                if (k != null) int.TryParse(k.GetValue("CurrentBuildNumber") as string, out build);
        }
        catch { }
        return build;
    }
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
    [DllImport("user32.dll", EntryPoint = "UpdateLayeredWindow")]
    static extern bool UpdateLayeredWindowAlpha(IntPtr h, IntPtr dst, IntPtr pos, IntPtr size, IntPtr src, IntPtr srcPos, int key, ref BLEND blend, int flags);
    // Change only the window's overall opacity; its picture stays as it is (no redraw).
    public static void SetAlpha(IntPtr h, byte a)
    {
        var b = new BLEND { Op = 0, Flags = 0, Alpha = a, Format = 1 };
        UpdateLayeredWindowAlpha(h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref b, 2);
    }

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString();
    }
}

static class Log
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UsageGauge");
    public static readonly string FilePath = Path.Combine(Dir, "error.log");
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

    // ---------- Claude (Claude Code login) and Grok (Grok CLI login) ----------
    public static Quota Claude()
    {
        string path = ClaudeCred(), err = null;
        int st; var j = Parse(AuthedGet("https://api.anthropic.com/api/oauth/usage", "anthropic-beta", "oauth-2025-04-20",
            r => Token(ClaudeGate, path, r, ReadClaude, RenewClaude, out err), out st));
        if (st < 0) return Fail(err ?? "Claude login not found");
        if (st == 401 || st == 403) return Fail("Claude login expired: run Claude Code once to renew it");
        if (st != 200) return Fail(HttpError(st));
        Dictionary<string, object> w;
        if (j == null || !TryDict(j, "seven_day", out w)) return Fail("Claude response format changed");
        double used = Num(w, "utilization");
        if (double.IsNaN(used)) return Fail("Claude weekly limit not found");
        var q = Ok(100 - used);
        object ra; if (w.TryGetValue("resets_at", out ra) && ra != null) q.ResetsAt = ParseTime(ra);
        return q;
    }
    public static Quota Grok()
    {
        string path = GrokAuth(), err = null;
        int st; var j = Parse(AuthedGet("https://cli-chat-proxy.grok.com/v1/billing?format=credits", "x-xai-token-auth", "xai-grok-cli",
            r => Token(GrokGate, path, r, ReadGrok, RenewGrok, out err), out st));
        if (st < 0) return Fail(err ?? "Grok login not found");
        if (st == 401 || st == 403) return Fail("Grok login expired: run grok once to renew it");
        if (st != 200) return Fail(HttpError(st));
        Dictionary<string, object> c, period;
        if (j == null || !TryDict(j, "config", out c)) return Fail("Grok response format changed");
        if (!TryDict(c, "currentPeriod", out period) || Str(period, "type") != "USAGE_PERIOD_TYPE_WEEKLY")
            return Fail("Grok weekly period not found");
        double used = 0;                                                  // the field is omitted while nothing is used
        if (c.ContainsKey("creditUsagePercent") && c["creditUsagePercent"] != null)
        { used = Num(c, "creditUsagePercent"); if (double.IsNaN(used)) return Fail("Grok usage value is not a number"); }
        var q = Ok(100 - used);
        object end; if (period.TryGetValue("end", out end) && end != null) q.ResetsAt = ParseTime(end);
        return q;
    }
    // GET with the saved token; on 401 once more with a renewed one. status -1 = no usable login.
    static string AuthedGet(string url, string hName, string hValue, Func<bool, string> token, out int status)
    {
        status = -1;
        for (int attempt = 0; attempt < 2; attempt++)
        {
            string access = token(attempt > 0);
            if (access == null) { if (attempt > 0) status = 401; return null; }
            string body = Http("GET", url, new Dictionary<string, string> { { "Authorization", "Bearer " + access }, { hName, hValue } }, null, null, out status);
            if (status != 401) return body;
        }
        return null;
    }

    // A saved login, as far as renewal is concerned.
    class Login { public string Access, Refresh, Anchor, Extra, Error; public DateTime? Exp; }
    static Login ReadClaude(string path)
    {
        Dictionary<string, object> root, o;
        if (!TryReadJson(path, out root) || !TryDict(root, "claudeAiOauth", out o)) return null;
        object sc; var scopes = o.TryGetValue("scopes", out sc) ? sc as object[] : null;
        return new Login { Access = Str(o, "accessToken"), Refresh = Str(o, "refreshToken"), Exp = EpochMs(Num(o, "expiresAt")),
            Anchor = "\"claudeAiOauth\"", Extra = scopes == null ? null : string.Join(" ", Array.ConvertAll(scopes, x => Convert.ToString(x))) };
    }
    static Login ReadGrok(string path)
    {
        Dictionary<string, object> root;
        if (!TryReadJson(path, out root)) return null;
        Dictionary<string, object> e = null; string scope = null; int n = 0;
        foreach (var kv in root)
            if (kv.Key.StartsWith("https://auth.x.ai::") && kv.Value is Dictionary<string, object>) { n++; scope = kv.Key; e = (Dictionary<string, object>)kv.Value; }
        // with several accounts we can't know which one grok is using
        if (n != 1) return n > 1 ? new Login { Error = "Several Grok accounts in auth.json: can't tell which one is active" } : null;
        object ea; e.TryGetValue("expires_at", out ea);
        return new Login { Access = Str(e, "key"), Refresh = Str(e, "refresh_token"), Exp = ea == null ? null : ParseTime(ea),
            Anchor = "\"" + scope + "\"", Extra = scope.Substring("https://auth.x.ai::".Length) };
    }
    // POST to the official OAuth endpoint; returns the new login and a patch for the saved file.
    static Login RenewClaude(Login cur, out Func<string, string> patch)
    {
        var body = new Dictionary<string, object> { { "grant_type", "refresh_token" }, { "refresh_token", cur.Refresh },
            { "client_id", "9d1c250a-e61b-44d9-88ed-5944d1962f5e" } };
        if (cur.Extra != null) body["scope"] = cur.Extra;
        var n = PostToken("https://platform.claude.com/v1/oauth/token", new JavaScriptSerializer().Serialize(body), "application/json", cur, 8 * 3600);
        patch = null;
        if (n == null) return null;
        long expMs = (long)(n.Exp.Value - Epoch).TotalMilliseconds;
        patch = t =>
        {
            t = ReplaceJsonString(t, "accessToken", n.Access);
            t = ReplaceJsonString(t, "refreshToken", n.Refresh);
            return ReplaceJsonNumber(t, "expiresAt", expMs);
        };
        return n;
    }
    static Login RenewGrok(Login cur, out Func<string, string> patch)
    {
        string form = "grant_type=refresh_token&client_id=" + Uri.EscapeDataString(cur.Extra) + "&refresh_token=" + Uri.EscapeDataString(cur.Refresh);
        var n = PostToken("https://auth.x.ai/oauth2/token", form, "application/x-www-form-urlencoded", cur, 3600);
        patch = null;
        if (n == null) return null;
        string exp = n.Exp.Value.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        patch = t =>
        {
            t = ReplaceJsonString(t, "key", n.Access);
            t = ReplaceJsonString(t, "refresh_token", n.Refresh);
            return ReplaceJsonString(t, "expires_at", exp);
        };
        return n;
    }
    static Login PostToken(string url, string body, string type, Login cur, double defaultTtl)
    {
        int status; var j = Parse(Http("POST", url, null, body, type, out status));
        string na = status == 200 && j != null ? Str(j, "access_token") : null;
        if (na == null) { Log.Write("Login renewal failed (HTTP " + status + ")"); return null; }
        double ttl = Num(j, "expires_in"); if (double.IsNaN(ttl) || ttl <= 0) ttl = defaultTtl;
        return new Login { Access = na, Refresh = Str(j, "refresh_token") ?? cur.Refresh, Exp = DateTime.UtcNow.AddSeconds(ttl) };
    }
    delegate Login Renewer(Login cur, out Func<string, string> patch);

    // The saved access token. Only when renewal is switched on, the token is past expiry (or was rejected) and the
    // official tool hasn't renewed it meanwhile, it is renewed here and written back (see PatchFile).
    static string Token(object gate, string path, bool rejected, Func<string, Login> read, Renewer renew, out string error)
    {
        error = null;
        lock (gate)
        {
            var cur = read(path);
            if (cur == null || cur.Error != null) { error = cur == null ? null : cur.Error; return null; }
            if (!rejected && (cur.Exp == null || DateTime.UtcNow < cur.Exp.Value.AddMinutes(2))) return cur.Access;
            if (!RenewLogins || cur.Refresh == null) return rejected ? null : cur.Access;

            Thread.Sleep(1500);                                   // the official tool may be renewing right now
            var again = read(path);
            if (again != null && again.Error == null)
            {
                if (again.Access != null && again.Access != cur.Access && again.Exp.HasValue && again.Exp.Value > DateTime.UtcNow) return again.Access;
                cur = again;
            }
            if (!CanWrite(path)) { Log.Write("Login not renewed: " + Path.GetFileName(path) + " is busy"); return rejected ? null : cur.Access; }

            Func<string, string> patch;
            var n = renew(cur, out patch);
            if (n == null) return null;
            string err = PatchFile(path, cur.Refresh, cur.Anchor, patch);
            Log.Write(err == null ? "Login renewed (" + Path.GetFileName(path) + ")"
                : "Login renewed but NOT saved (" + err + "): if the official tool asks you to sign in, do so once");
            return n.Access;
        }
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

// "Start with Windows": the same HKCU Run entry install.ps1 -Autostart writes. Only an entry pointing at this exe counts
// as ours; Task Manager's "Disabled" mark (StartupApproved) shows as off and is cleared when switched on again.
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Approved = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    static bool Ours(RegistryKey k, string exe)
    {
        var v = k == null ? null : k.GetValue("UsageGauge") as string;
        return v != null && string.Equals(v.Trim().Trim('"'), exe, StringComparison.OrdinalIgnoreCase);
    }
    public static bool IsOn()
    {
        try
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) if (!Ours(k, Application.ExecutablePath)) return false;
            using (var k = Registry.CurrentUser.OpenSubKey(Approved))
            {
                var b = k == null ? null : k.GetValue("UsageGauge") as byte[];
                return b == null || b.Length == 0 || (b[0] & 1) == 0;   // odd first byte = disabled in Task Manager
            }
        }
        catch { return false; }
    }
    public static void Set(bool on) { SetFor(Application.ExecutablePath, on); }
    public static void SetFor(string exe, bool on)
    {
        try
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue("UsageGauge", "\"" + exe + "\"");
                else if (Ours(k, exe)) k.DeleteValue("UsageGauge", false);
            }
            using (var k = Registry.CurrentUser.OpenSubKey(Approved, true)) if (k != null) k.DeleteValue("UsageGauge", false);
        }
        catch (Exception ex) { Log.Write("Autostart: " + ex.Message); }
    }
}

// The single-file build for sharing (UsageGauge-Setup.exe, made by install.ps1 -Package; logos and notices are embedded).
// Run from anywhere, it copies itself to %LOCALAPPDATA%\UsageGauge, starts with Windows and shows up in
// Settings > Apps, from where "/uninstall" removes it again. Nothing outside that folder and those two registry
// entries is touched; the services' login files never are.
static class Setup
{
    public static string Version { get { return Assembly.GetExecutingAssembly().GetName().Version.ToString(3); } }   // from AssemblyVersion
    public const string Repo = "https://github.com/oksk4524/usage-gauge";
    public static readonly string Exe = Path.Combine(Log.Dir, "UsageGauge.exe");
    const string UninstKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\UsageGauge";
    // Start menu entry, so a widget that was quit can be started again without the setup file
    static readonly string Shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "UsageGauge.lnk");
    static void MakeShortcut()
    {
        object shell = null, lnk = null;
        try
        {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            shell = Activator.CreateInstance(t);
            lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { Shortcut });
            var lt = lnk.GetType();
            lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { Exe });
            lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { Log.Dir });
            lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { "Weekly AI quota gauges on the taskbar" });
            lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
        }
        catch (Exception ex) { Log.Write("Start menu shortcut: " + ex.Message); }
        finally
        {
            if (lnk != null && Marshal.IsComObject(lnk)) Marshal.ReleaseComObject(lnk);
            if (shell != null && Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell);
        }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool DeleteFile(string path);

    public static Stream Resource(string name) { return Assembly.GetExecutingAssembly().GetManifestResourceStream(name); }
    public static bool Packaged { get { return Assembly.GetExecutingAssembly().GetManifestResourceInfo("codex.png") != null; } }
    public static bool IsInstalledCopy
    {
        get { return string.Equals(Path.GetFullPath(Application.ExecutablePath), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase); }
    }
    static bool Ask(string ko, string en, bool quiet)
    {
        return quiet || MessageBox.Show(L.T(ko, en), "UsageGauge", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    }
    static void Tell(string ko, string en, bool quiet, bool error)
    {
        if (!quiet) MessageBox.Show(L.T(ko, en), "UsageGauge", MessageBoxButtons.OK, error ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
    }
    // Stop the installed copy (never this process), so its file can be replaced or deleted.
    static void StopInstalled()
    {
        int me = Process.GetCurrentProcess().Id;
        foreach (var p in Process.GetProcessesByName("UsageGauge"))
            using (p)
                try
                {
                    if (p.Id == me || !string.Equals(p.MainModule.FileName, Exe, StringComparison.OrdinalIgnoreCase)) continue;
                    p.Kill(); p.WaitForExit(20000);   // with a request in flight, exiting can take several seconds
                }
                catch { }
    }

    public static void Install(bool quiet)
    {
        if (!Ask("UsageGauge를 설치할까요?\n\n작업표시줄에 Codex·Claude·Grok·Antigravity의 주간 남은 사용량을 보여줘요.\n"
                + "이 PC에 로그인된 서비스만 나타나요. 기본은 로그인 정보를 읽기만 해요.\n자동 갱신을 직접 켜면 Claude/Grok 로그인 파일을 갱신해요.\n\n설치 위치: " + Log.Dir,
                "Install UsageGauge?\n\nIt shows how much of your weekly Codex, Claude, Grok and Antigravity quota is left, on the taskbar.\n"
                + "Only services signed in on this PC appear. Credentials are read-only by default.\nEnabling optional renewal updates Claude/Grok credential files.\n\nInstall folder: " + Log.Dir, quiet)) return;
        try
        {
            StopInstalled();
            Directory.CreateDirectory(Log.Dir);
            for (int i = 0; ; i++)
                try { File.Copy(Application.ExecutablePath, Exe, true); break; }
                catch (IOException) { if (i >= 20) throw; Thread.Sleep(500); }
            DeleteFile(Exe + ":Zone.Identifier");   // a downloaded setup carries "from the internet"; the installed copy must not ask at every sign-in
            foreach (var n in new[] { "NOTICE", "LICENSE" })
                using (var s = Resource(n)) if (s != null) using (var f = File.Create(Path.Combine(Log.Dir, n + ".txt"))) s.CopyTo(f);
            Autostart.SetFor(Exe, true);
            MakeShortcut();
            using (var k = Registry.CurrentUser.CreateSubKey(UninstKey))
            {
                k.SetValue("DisplayName", "UsageGauge");
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", "oksk4524");
                k.SetValue("DisplayIcon", Exe);
                k.SetValue("InstallLocation", Log.Dir);
                k.SetValue("URLInfoAbout", Repo);
                k.SetValue("UninstallString", "\"" + Exe + "\" /uninstall");
                k.SetValue("QuietUninstallString", "\"" + Exe + "\" /uninstall /quiet");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                k.SetValue("EstimatedSize", (int)(new FileInfo(Exe).Length / 1024) + 1, RegistryValueKind.DWord);
            }
            using (Process.Start(Exe)) { }
            Tell("설치했어요. 작업표시줄 오른쪽(시계 옆)에 떠요.\n\n• 컴퓨터를 켜면 자동으로 실행돼요.\n• 우클릭하면 메뉴가 나와요.\n"
                + "• 끄고 나서 다시 켜려면 시작 메뉴에서 UsageGauge를 누르세요.\n• 지우려면 설정 > 앱에서 UsageGauge를 제거하세요.\n\n이 설치 파일은 지워도 돼요.",
                "Installed. It sits on the right of the taskbar, next to the clock.\n\n• It starts with Windows.\n• Right-click it for the menu.\n"
                + "• After quitting it, start it again from the Start menu.\n• To remove it, uninstall UsageGauge in Settings > Apps.\n\nYou can delete this setup file now.", quiet, false);
        }
        catch (Exception ex)
        {
            Log.Write("Install failed: " + ex.Message);
            Tell("설치하지 못했어요: " + ex.Message, "Could not install: " + ex.Message, quiet, true);
        }
    }

    public static void Uninstall(bool quiet)
    {
        if (!Ask("UsageGauge를 제거할까요?\n설정과 기록도 함께 지워져요. (각 서비스의 로그인은 그대로예요.)",
                 "Remove UsageGauge?\nIts settings and log go too. (Your service logins are left alone.)", quiet)) return;
        StopInstalled();
        Autostart.SetFor(Exe, false);
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstKey, false); } catch { }
        try { File.Delete(Shortcut); } catch { }
        Tell("제거했어요.", "UsageGauge was removed.", quiet, false);
        // this exe may be running from that folder: delete it once we have exited (retried: antivirus scans can hold files briefly)
        try
        {
            string q = "\"" + Log.Dir + "\"";
            var psi = new ProcessStartInfo("cmd.exe", "/c for /l %i in (1,1,8) do (ping 127.0.0.1 -n 2 >nul & rd /s /q " + q + " 2>nul & if not exist " + q + " exit /b)");
            psi.CreateNoWindow = true; psi.UseShellExecute = false; psi.WorkingDirectory = Path.GetTempPath();
            using (Process.Start(psi)) { }
        }
        catch { }
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
    static readonly string[] LogoFiles = { "codex.png", "claude.png", "grok.png", "gemini.png", "antigravity.png" };
    readonly Image[] logos = new Image[N];
    static Image LoadPng(string file)
    {
        try
        {
            using (var s = Setup.Resource(file))   // embedded in the shared build; loose files next to the exe otherwise
            using (var src = s != null ? Image.FromStream(s) : Image.FromFile(Path.Combine(Dir, file)))
                return new Bitmap(src);
        }
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
    static readonly uint WM_TASKBARCREATED = Native.RegisterWindowMessage("TaskbarCreated");
    bool loading = true, hover = false; float hoverT = 0;
    int busy = 0, generation = 0;
    readonly ToolTip tip = new ToolTip();
    System.Windows.Forms.Timer refreshTimer, retryTimer, guardTimer, slowTimer, animTimer, resumeTimer, showTimer, topTimer, grabTimer, loginWatchTimer, fadeTimer;
    readonly List<System.Windows.Forms.Timer> timers = new List<System.Windows.Forms.Timer>();
    System.Windows.Forms.Timer NewTimer(int ms, EventHandler tick)
    {
        var t = new System.Windows.Forms.Timer { Interval = ms }; t.Tick += tick; timers.Add(t); return t;
    }

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

        for (int i = 0; i < N; i++) logos[i] = LoadPng(LogoFiles[i]);

        MouseDown += OnDown;
        MouseUp += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Right) ShowMenu(e.Location); };
        MouseEnter += delegate { hover = true; Kick(); };
        MouseLeave += delegate { hover = false; Kick(); };

        refreshTimer = NewTimer(REFRESH_MS, delegate
        {
            if (Native.IdleMs() > IDLE_SKIP_MS) { missedWhileIdle = true; return; }
            retriedOnce = false; Refresh_();
        });
        retryTimer = NewTimer(RETRY_MS, delegate
        {
            retryTimer.Stop();
            if (Native.IdleMs() > IDLE_SKIP_MS) { missedWhileIdle = true; return; }
            Refresh_(agFailedLast, false);   // re-polls agy too if agy failed; keeps the 5-min schedule
        });
        guardTimer = NewTimer(GUARD_MS, delegate { Guard(); });
        slowTimer = NewTimer(SLOW_MS, delegate
        {
            if (Native.IdleMs() > IDLE_SKIP_MS) return;   // unattended: no sampling, no drawing (refreshed on return)
            if (!GrabBackdrop()) Render();                // a scheduled grab renders when done
            CheckPreviewRequest();
        });
        animTimer = NewTimer(15, delegate { Step(); });
        grabTimer = NewTimer(120, delegate { OnGrabTick(); });
        resumeTimer = NewTimer(12000, delegate   // 12 s: let Wi-Fi/DHCP come back after wake
            { resumeTimer.Stop(); Location = ClampToScreens(Location); GrabBackdrop(); Refresh_(true); });
        showTimer = NewTimer(220, delegate { showTimer.Stop(); if (!ShouldHide()) ShowNow(); });   // debounced re-show
        topTimer = NewTimer(60, delegate { topTimer.Stop(); Evaluate(); });                       // second topmost pass
        loginWatchTimer = NewTimer(30000, delegate { OnLoginWatch(); });                        // after opening a sign-in
        fadeTimer = NewTimer(15, delegate { FadeStep(); });
        MouseMove += delegate(object s, MouseEventArgs e)
        {
            int i = BlockAt(e.Location);
            Cursor = i >= 0 && i < LoginTool.Length && LoginExpired(qs[i]) ? Cursors.Hand : Cursors.Default;
        };

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
            foreach (var t in timers) t.Stop();
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
            Evaluate();   // already-fullscreen app at startup: hide right away
            GrabBackdrop(); Render(); Refresh_(true);
            BeginInvoke((MethodInvoker)delegate { Native.MenuTheme(!lightBg); using (BuildMenu()) { } });   // warm up: first right-click opens at once
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
        // sit just left of the clock/tray area, so it never lands on the (often centered) app icons
        int x = Math.Max(b.Left, b.Right - PW - (int)(300 * S));
        try
        {
            IntPtr tray = Native.FindWindow("Shell_TrayWnd", null);
            IntPtr notify = tray == IntPtr.Zero ? IntPtr.Zero : Native.FindWindowEx(tray, IntPtr.Zero, "TrayNotifyWnd", null);
            Native.RECT nr;
            if (notify != IntPtr.Zero && Native.GetWindowRect(notify, out nr) && nr.R - nr.L > 0 && nr.L > b.Left + PW)
                x = nr.L - PW - (int)(4 * S);
        }
        catch { }
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
        else { int i = BlockAt(e.Location); if (i >= 0 && LoginExpired(qs[i])) LaunchLogin(i); }   // a click, not a drag
    }

    // ---- "login expired" gauges: a click opens the official tool's own sign-in, which saves the login we read ----
    static readonly string[] LoginTool = { "codex", "claude", "grok" };
    static readonly string[] LoginArgs = { "login", "auth login", "login" };
    static bool LoginExpired(Quota q)
    {
        return (q.Failing || !q.Ok) && q.Error != null && q.Error.IndexOf("login expired", StringComparison.OrdinalIgnoreCase) >= 0;
    }
    int BlockAt(Point p)
    {
        float x = p.X / S - SH - PADX;
        int k = (int)Math.Floor((x + SEP / 2f) / (BLOCK + SEP));
        return k >= 0 && k < Vis.Length ? Vis[k] : -1;
    }
    // Looks the tool up the way a new terminal would (current user + system PATH, read fresh so a tool installed
    // after the widget started is found), plus the usual per-user install folders. Nothing is tied to one PC.
    static string FindTool(string name)
    {
        var dirs = new List<string>();
        foreach (var t in new[] { EnvironmentVariableTarget.User, EnvironmentVariableTarget.Machine, EnvironmentVariableTarget.Process })
        {
            var p = Environment.GetEnvironmentVariable("Path", t);
            if (p != null) dirs.AddRange(p.Split(';'));
        }
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        dirs.Add(Path.Combine(home, @".local\bin"));
        dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"));
        dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Links"));
        if (name == "claude")   // Claude Code bundled with the Claude desktop app: %APPDATA%\Claude\claude-code\<version>\
            dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Claude\claude-code\*"));
        foreach (var d in dirs)
        {
            if (d.EndsWith("\\*"))
            {
                string best = null; var bt = DateTime.MinValue;   // newest version folder
                try
                {
                    string root = d.Substring(0, d.Length - 2);
                    if (Directory.Exists(root))
                        foreach (var v in Directory.GetDirectories(root))
                        {
                            string f = Path.Combine(v, name + ".exe");
                            if (File.Exists(f) && File.GetLastWriteTimeUtc(f) > bt) { best = f; bt = File.GetLastWriteTimeUtc(f); }
                        }
                }
                catch { }
                if (best != null) return best;
                continue;
            }
            foreach (var ext in new[] { ".exe", ".cmd", ".bat" })
                try
                {
                    string dir = Environment.ExpandEnvironmentVariables(d.Trim().Trim('"'));
                    if (dir.Length == 0) continue;
                    string f = Path.Combine(dir, name + ext);
                    if (File.Exists(f)) return f;
                }
                catch { }   // malformed PATH entry
        }
        return null;
    }
    readonly double[] lastLaunchMs = new double[N];
    int loginWatchLeft;
    void LaunchLogin(int i)
    {
        if (i >= LoginTool.Length) return;
        double now = Clock.Elapsed.TotalMilliseconds;
        if (now - lastLaunchMs[i] < 5000) return;   // ignore double clicks
        lastLaunchMs[i] = now;
        string cmdLine = (LoginTool[i] + " " + LoginArgs[i]).Trim();
        string exe = FindTool(LoginTool[i]);
        if (exe == null)
        {
            MessageBox.Show(L.T(
                Names[i] + " 로그인이 만료됐어요.\n터미널에서 \"" + cmdLine + "\" 을 실행해 다시 로그인해 주세요" + (i == 1 ? " (Claude Code 안에서는 /login)." : "."),
                Names[i] + " login has expired.\nRun \"" + cmdLine + "\" in a terminal to sign in again" + (i == 1 ? " (or /login inside Claude Code)." : ".")),
                "UsageGauge", MessageBoxButtons.OK, MessageBoxIcon.Information, MessageBoxDefaultButton.Button1, (MessageBoxOptions)0x40000);   // MB_TOPMOST
            return;
        }
        try
        {
            var psi = new ProcessStartInfo("cmd.exe", "/k \"\"" + exe + "\" " + LoginArgs[i] + "\"");
            psi.UseShellExecute = true;   // its own visible console window
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            using (Process.Start(psi)) { }
            Log.Write("Opened sign-in: " + cmdLine);
            loginWatchLeft = 10; loginWatchTimer.Stop(); loginWatchTimer.Start();   // pick up the new login within ~30 s
        }
        catch (Exception ex) { Log.Write("Could not open sign-in (" + cmdLine + "): " + ex.Message); }
    }
    void OnLoginWatch()
    {
        bool any = false;
        foreach (int i in Vis) if (LoginExpired(qs[i])) any = true;
        if (!any || --loginWatchLeft < 0) { loginWatchTimer.Stop(); return; }
        Refresh_(false, false);
    }

    // ---- visibility & z-order: event-driven (instant), with a slow safety-net timer ----
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
            if (ShouldHide()) { FadeOut(); return; }
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
        if (ShouldHide()) { FadeOut(); return; }
        if (!Visible) { if (!showTimer.Enabled) showTimer.Start(); return; }   // re-show after it settles (no flicker)
        if (fadeTarget == 0) FadeTo(255, FADE_IN_MS);   // was fading out, but the fullscreen app is gone again
        KeepOnTop();
    }
    void ShowNow()
    {
        alpha = 0; fadeTarget = 0;   // appear from transparent
        Show(); KeepOnTop(); topTimer.Stop(); topTimer.Start(); if (!GrabBackdrop()) Render();
        FadeTo(255, FADE_IN_MS);
    }

    // ---- fade on hide/show: only the window's overall opacity changes, so it costs next to nothing ----
    const double FADE_OUT_MS = 100, FADE_IN_MS = 150;   // short: a fullscreen video must not wait on it
    byte alpha = 255; int fadeTarget = 255; double fadeFrom, fadeStartMs, fadeMs;
    void FadeOut() { showTimer.Stop(); if (Visible) FadeTo(0, FADE_OUT_MS); }
    void FadeTo(int target, double ms)
    {
        if (target == fadeTarget && (fadeTimer.Enabled || alpha == target)) return;
        fadeTarget = target; fadeFrom = alpha; fadeStartMs = Clock.Elapsed.TotalMilliseconds;
        fadeMs = ms * Math.Abs(target - alpha) / 255.0;   // reversing midway takes only the rest of the way
        fadeTimer.Start(); FadeStep();
    }
    void FadeStep()
    {
        double t = fadeMs <= 0 ? 1 : Math.Min(1, (Clock.Elapsed.TotalMilliseconds - fadeStartMs) / fadeMs);
        alpha = (byte)Math.Round(fadeFrom + (fadeTarget - fadeFrom) * t);
        if (IsHandleCreated && Visible) Native.SetAlpha(Handle, alpha);
        if (t < 1) return;
        fadeTimer.Stop();
        if (fadeTarget == 0 && Visible) Hide();
    }
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
    // Right-click menu: a native Windows menu (opens at once, Windows 11 look, follows the widget's light/dark),
    // rebuilt each time it opens so it follows the current language and state.
    ContextMenu menu;
    void ShowMenu(Point at)
    {
        IntPtr prev = Native.GetForegroundWindow();
        tip.Active = false;                       // the big tooltip would cover the menu
        Native.MenuTheme(!lightBg);
        if (menu != null) menu.Dispose();
        menu = BuildMenu();
        Native.SetForegroundWindow(Handle);       // so a click anywhere else closes the menu
        menu.Show(this, at);                      // returns when the menu closes
        Native.PostMessage(Handle, 0, IntPtr.Zero, IntPtr.Zero);   // WM_NULL, the documented TrackPopupMenu companion
        tip.Active = true;
        if (prev != IntPtr.Zero && prev != Handle && Native.GetForegroundWindow() == Handle) Native.SetForegroundWindow(prev);   // hand focus back
    }
    ContextMenu BuildMenu()
    {
        var m = new ContextMenu();
        m.MenuItems.Add(L.T("새로고침", "Refresh"), delegate { Refresh_(true); });
        m.MenuItems.Add("-");
        var gauges = new MenuItem(L.T("표시할 항목", "Gauges"));
        for (int i = 0; i < N; i++)
        {
            int idx = i; bool avail = Available(i);
            var it = new MenuItem(Names[i] + (avail ? "" : L.T("  (이 PC에 로그인 없음)", "  (not set up on this PC)")))
                { Checked = avail && !Hidden.Contains(Ids[i]), Enabled = avail };
            it.Click += delegate
            {
                if (Hidden.Contains(Ids[idx])) Hidden.Remove(Ids[idx]); else Hidden.Add(Ids[idx]);
                SaveHidden(); UpdateVisible(); UpdateTip(); Refresh_(true);
            };
            gauges.MenuItems.Add(it);
        }
        m.MenuItems.Add(gauges);
        var lang = new MenuItem(L.T("언어 / Language", "Language / 언어"));
        foreach (var opt in new[] { new[] { "auto", L.T("자동 (Windows 언어)", "Auto (Windows language)") }, new[] { "ko", "한국어" }, new[] { "en", "English" } })
        {
            string mode = opt[0];
            var it = new MenuItem(opt[1]) { Checked = L.Mode == mode, RadioCheck = true };
            it.Click += delegate { L.Set(mode); UpdateTip(); Render(); };
            lang.MenuItems.Add(it);
        }
        m.MenuItems.Add(lang);
        m.MenuItems.Add("-");
        bool auto = Autostart.IsOn();
        m.MenuItems.Add(new MenuItem(L.T("Windows 시작 시 자동 실행", "Start with Windows"), delegate { Autostart.Set(!auto); }) { Checked = auto });
        if (Available(1) || Available(2))
            m.MenuItems.Add(new MenuItem(L.T("Claude·Grok 로그인 자동 갱신 (실험적)", "Renew Claude/Grok logins (experimental)"),
                delegate { Usage.SetRenew(!Usage.RenewLogins); Refresh_(); }) { Checked = Usage.RenewLogins });
        m.MenuItems.Add(L.T("위치 초기화", "Reset position"), delegate
        {
            Location = ClampToScreens(DefaultPos()); RefreshCachedState(); SavePos(); if (!GrabBackdrop()) Render();
        });
        m.MenuItems.Add("-");
        m.MenuItems.Add(new MenuItem(L.T("오류 기록 보기", "View error log"), delegate { Open("notepad.exe", Log.FilePath); }) { Enabled = File.Exists(Log.FilePath) });
        m.MenuItems.Add(L.T("GitHub 페이지 (도움말·문의)", "GitHub page (help, issues)"), delegate { Open(Setup.Repo, null); });
        m.MenuItems.Add("-");
        m.MenuItems.Add(L.T("종료", "Quit"), delegate { Close(); });
        return m;
    }
    static void Open(string what, string arg)
    {
        try { using (arg == null ? Process.Start(what) : Process.Start(what, "\"" + arg + "\"")) { } }
        catch (Exception ex) { Log.Write("Could not open " + what + ": " + ex.Message); }
    }

    void UpdateTip()
    {
        var sbt = new StringBuilder();
        foreach (int i in Vis) sbt.Append(Line(qs[i])).Append("\n");
        tip.SetToolTip(this, sbt.ToString() + L.T(
            "\nCodex·Claude·Grok 5분, Antigravity 15분마다 갱신 (자리 비우면 쉬었다가 돌아오면 바로 갱신)\n주황 점: 값이 오래됐거나 갱신이 계속 실패하는 중\n드래그: 이동 · 우클릭: 메뉴·설정",
            "\nCodex·Claude·Grok every 5 min, Antigravity every 15 min (paused while you're away)\nAmber dot: the value is out of date or updates keep failing\nDrag: move · Right-click: menu and settings"));
    }
    static string Line(Quota q)
    {
        int ni = Array.IndexOf(Names, q.Name);
        string hint = LoginExpired(q) && ni >= 0 && ni < LoginTool.Length ? L.T("\n   눌러서 다시 로그인", "\n   click to sign in again") : "";
        if (!q.Ok) return q.Name + L.T(" 주간: 읽기 실패 (", " weekly: unavailable (") + q.Error + ")" + hint;
        string r = q.ResetsAt.HasValue ? L.T(" · 리셋 ", " · resets ") + q.ResetsAt.Value.ToLocalTime().ToString(L.T("M/d (ddd) HH:mm", "ddd MMM d, HH:mm"), L.Culture) : "";
        string at = q.LastOkUtc.ToLocalTime().ToString("HH:mm");
        string st = q.Failing
            ? L.T("\n   ⚠ " + at + " 값 표시 중 (최근 갱신 실패: ", "\n   ⚠ showing the " + at + " value (last update failed: ") + q.Error + ")"
            : L.T(" · " + at + " 기준", " · as of " + at);
        return q.Name + L.T(" 주간 " + Math.Round(q.Remaining) + "% 남음", " weekly " + Math.Round(q.Remaining) + "% left") + r + st + hint;
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
            using (var bmp = Compose()) Push(bmp);
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
    void DumpPreview(string file) { using (var bmp = Compose()) bmp.Save(file, ImageFormat.Png); }
    Bitmap Compose()
    {
        var bmp = new Bitmap(PW, PH, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.CompositingQuality = CompositingQuality.HighQuality;
            g.ScaleTransform(S, S);          // draw in 100% units, scaled to the display
            g.TranslateTransform(SH, SH);
            DrawAll(g);
        }
        return bmp;
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
        var logo = logos[idx];
        if (idx == 2) lr = RectangleF.Inflate(lr, -0.5f, -0.5f);
        if (logo != null && !(idx == 2 && lightBg)) g.DrawImage(logo, lr);
        else if (logo != null) using (var ia = new ImageAttributes())   // the Grok mark is white: draw it dark on a light taskbar
        {
            ia.SetColorMatrix(new ColorMatrix(new[] {
                new float[] { -1, 0, 0, 0, 0 }, new float[] { 0, -1, 0, 0, 0 }, new float[] { 0, 0, -1, 0, 0 },
                new float[] { 0, 0, 0, 1, 0 }, new float[] { 0.9f, 0.9f, 0.9f, 0, 1 } }));
            g.DrawImage(logo, Rectangle.Round(lr), 0, 0, logo.Width, logo.Height, GraphicsUnit.Pixel, ia);
        }

        float tx = ring.Right + TEXT_GAP;
        string num = loading ? "··" : (q.Ok ? ((int)Math.Round(shown)).ToString() : "!");
        bool expired = !loading && LoginExpired(q);
        string sub = loading ? L.T("불러오는 중", "loading")
            : expired ? L.T("로그인 만료", "sign in")
            : (q.Ok ? ResetShort(q.ResetsAt) : L.T("읽기 실패", "unavailable"));

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
            using (var sb = new SolidBrush(expired ? (lightBg ? Color.FromArgb(255, 176, 98, 0) : Color.FromArgb(250, 251, 191, 36))
                : lightBg ? Color.FromArgb(225, 70, 70, 82) : Color.FromArgb(222, 222, 222, 232))) g.FillPath(sb, p2);
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
            var blend = new Native.BLEND { Op = 0, Flags = 0, Alpha = alpha, Format = 1 };
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

        try { Native.SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        L.Load();
        bool quiet = Array.IndexOf(args, "/quiet") >= 0;
        if (Array.IndexOf(args, "/uninstall") >= 0) { Setup.Uninstall(quiet); return; }
        if (Setup.Packaged && !Setup.IsInstalledCopy) { Setup.Install(quiet); return; }   // the shared setup file

        Mutex m = null; bool created = false;
        try { m = new Mutex(true, "UsageGauge_SingleInstance", out created); }
        catch (AbandonedMutexException) { created = true; }   // previous instance died: take over
        catch (Exception ex) { Log.Write("mutex: " + ex.Message); created = true; }
        if (!created) { if (m != null) m.Dispose(); return; }

        try { System.Net.ServicePointManager.SecurityProtocol |= (System.Net.SecurityProtocolType)3072; } catch { }   // TLS 1.2
        try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        Usage.LoadSettings();
        Usage.CleanupTemps();

        Application.Run(new GaugeForm());
        GC.KeepAlive(m);
    }
}
