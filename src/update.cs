// ============================================================================
//  Updates from GitHub (public repo) + restart / re-flash from the Studio
// ============================================================================
public static class XUpdate {
  public const string Repo = "MikeyM777/xiao-cam";
  static string Raw(string f) { return "https://raw.githubusercontent.com/" + Repo + "/main/" + f + "?nocache=" + DateTime.UtcNow.Ticks; }
  // GitHub API first (always fresh), raw CDN as fallback
  static byte[] Fetch(string file) {
    try {
      using (var w = Client()) { w.Headers["Accept"] = "application/vnd.github.raw"; return w.DownloadData("https://api.github.com/repos/" + Repo + "/contents/" + file + "?ref=main"); }
    } catch { using (var w = Client()) return w.DownloadData(Raw(file)); }
  }
  static WebClient Client() {
    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
    var w = new WebClient(); w.Headers["User-Agent"] = "xiao-cam-studio"; w.Encoding = Encoding.UTF8; return w;
  }

  public static string Check(XHub hub) {
    var o = new Dictionary<string, object>();
    try {
      string j = Encoding.UTF8.GetString(Fetch("version.json")).TrimStart((char)0xFEFF);
      var d = XCrazy.Js().DeserializeObject(j) as Dictionary<string, object>;
      string latest = Convert.ToString(d["studio"]);
      o["ok"] = true; o["current"] = hub.Version; o["latest"] = latest;
      o["firmware"] = d.ContainsKey("firmware") ? Convert.ToString(d["firmware"]) : "";
      o["notes"] = d.ContainsKey("notes") ? Convert.ToString(d["notes"]) : "";
      o["newer"] = Newer(latest, hub.Version);
    } catch (Exception e) { o["ok"] = false; o["err"] = "could not reach GitHub: " + e.Message; o["current"] = hub.Version; }
    return XCrazy.Js().Serialize(o);
  }
  static bool Newer(string a, string b) {
    try { return new Version(a) > new Version(b); } catch { return a != b; }
  }

  // download the new bat, keep the old one as .prev.bat, restart (and flash if the firmware changed)
  public static void Apply(XHub hub, bool flash) {
    if (string.IsNullOrEmpty(hub.SelfPath) || !File.Exists(hub.SelfPath)) throw new Exception("cannot find the running bat file");
    byte[] b = Fetch("XIAO-CAM-STUDIO.bat");
    string head = Encoding.ASCII.GetString(b, 0, Math.Min(b.Length, 200));
    if (b.Length < 50000 || !head.StartsWith("<# : XIAO-CAM Studio")) throw new Exception("the downloaded file does not look right - not updated");
    var mv = Regex.Match(Encoding.ASCII.GetString(b), "\\$StudioVersion\\s*=\\s*'([^']+)'");
    if (!mv.Success || !Newer(mv.Groups[1].Value, hub.Version)) throw new Exception("GitHub is still updating - try again in a few minutes");
    string dir = Path.GetDirectoryName(hub.SelfPath);
    string tmp = hub.SelfPath + ".new", prev = Path.Combine(dir, "XIAO-CAM-STUDIO.prev.bat");
    File.WriteAllBytes(tmp, b);
    File.Copy(hub.SelfPath, prev, true);
    File.Copy(tmp, hub.SelfPath, true);
    File.Delete(tmp);
    Relaunch(hub, flash ? "flash" : "view");
  }

  // close this Studio for good: its cmd window too (it would keep reading the replaced bat file).
  // Environment.Exit from a worker thread can hang inside PowerShell, so kill instead (shutdown already ran).
  public static void ExitNow() {
    var me = Process.GetCurrentProcess();
    try {
      using (var q = new ManagementObjectSearcher("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" + me.Id))
        foreach (ManagementObject o in q.Get()) {
          var parent = Process.GetProcessById(Convert.ToInt32(o["ParentProcessId"]));
          if (parent.ProcessName.Equals("cmd", StringComparison.OrdinalIgnoreCase)) parent.Kill();
        }
    } catch { }
    me.Kill();
  }

  // start the bat again in a new window, then close this one (the camera port must be free for flashing)
  public static void Relaunch(XHub hub, string mode) {
    // ShellExecute = new window and NO inherited handles (an inherited socket would keep the port busy)
    var psi = new ProcessStartInfo(hub.SelfPath, mode + " nobrowser");   // the open browser tab reconnects by itself
    psi.UseShellExecute = true;
    psi.WorkingDirectory = Path.GetDirectoryName(hub.SelfPath);
    var t = new Thread(delegate() {
      Thread.Sleep(400);
      hub.Shutdown();
      XWeb web = hub.Web; if (web != null) web.Stop();
      Thread.Sleep(300);
      Process.Start(psi);
      ExitNow();
    });
    t.IsBackground = true; t.Start();
  }
}
