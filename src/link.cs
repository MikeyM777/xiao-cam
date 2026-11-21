// ============================================================================
//  Link: where the video comes from - USB cable or WiFi (board's :81/stream).
//  On WiFi the board can stay on USB (settings + clock over the cable) or run
//  on a battery (settings, status and clock over WiFi: /cmd /status /ping).
// ============================================================================
public class XLink {
  readonly XHub hub; Thread th; volatile bool run;
  XWifi wifi; string wifiUrl = "";
  public volatile string Mode = "usb";     // "usb" | "wifi"
  public volatile string Host = "";        // manual camera address for WiFi ("" = automatic)
  public volatile string Status = "";
  public volatile bool OverWifi;           // board settings/status come over WiFi (no USB)
  DateTime lastPing = DateTime.MinValue, lastStatus = DateTime.MinValue, lastUsbFix = DateTime.MinValue, lastResolve = DateTime.MinValue, lastClockReset = DateTime.Now;
  public XLink(XHub h) { hub = h; }
  public void Start() { run = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { run = false; StopWifi(); }
  public string Url { get { return wifiUrl; } }
  public long WifiFrames { get { XWifi w = wifi; return w == null ? 0 : w.Frames; } }

  public void SetMode(string m) {
    m = m == "wifi" ? "wifi" : "usb";
    if (m == Mode) return;
    Mode = m;
    StopWifi();
    hub.ResetClock(); lastPing = DateTime.MinValue; lastUsbFix = DateTime.MinValue;
    if (hub.Source != null && hub.Source.Connected) hub.Source.Send(m == "wifi" ? "set usb 0" : "set usb 1");
  }
  public void SetHost(string h) { Host = h; StopWifi(); lastResolve = DateTime.MinValue; }

  bool UsbUp { get { IXSource s = hub.Source; return s != null && s.Connected; } }

  string BoardStr(string k) {
    try {
      var d = XCrazy.Js().DeserializeObject(hub.BoardJson) as Dictionary<string, object>;
      return d != null && d.ContainsKey(k) ? Convert.ToString(d[k]) : "";
    } catch { return ""; }
  }

  // camera address: manual, else what the board says (demo: stream_url), else the hotspot default
  public string Resolve() {
    string h = (Host ?? "").Trim();
    if (h.Length > 0) return "http://" + h.Replace("http://", "").TrimEnd('/') + ":81/stream";
    string su = BoardStr("stream_url"); if (su.Length > 0) return su;
    string sta = BoardStr("sta_ip"), ap = BoardStr("ap_ip");
    var c = new List<string>();
    if (sta.Length > 0) c.Add("http://" + sta + ":81/stream");
    if (ap.Length > 0) c.Add("http://" + ap + ":81/stream");
    if (c.Count == 0) c.Add("http://192.168.4.1:81/stream");
    if (c.Count > 1) foreach (string u in c) if (XWifi.Reachable(u, 700)) return u;
    return c[0];
  }
  public string BaseUrl { get { try { var u = new Uri(wifiUrl.Length > 0 ? wifiUrl : Resolve()); return "http://" + u.Host + (u.Port == 81 ? "" : ":" + u.Port); } catch { return "http://192.168.4.1"; } } }

  static string Get(string url, int ms) {
    var rq = (HttpWebRequest)WebRequest.Create(url);
    rq.Timeout = ms; rq.ReadWriteTimeout = ms; rq.KeepAlive = false; rq.Proxy = null;
    using (var r = rq.GetResponse()) using (var sr = new StreamReader(r.GetResponseStream())) return sr.ReadToEnd();
  }
  // a command over WiFi (board on battery)
  public bool SendWifi(string line) {
    if (Mode != "wifi") return false;
    try { return Get(BaseUrl + "/cmd?c=" + Uri.EscapeDataString(line), 2500).IndexOf("true", StringComparison.Ordinal) >= 0; }
    catch (Exception e) { hub.SendErr = "WiFi: " + e.Message; return false; }
  }

  // several pings, the fastest round trip wins (USB or WiFi)
  public void PingBurst() {
    hub.ResetClock();
    for (int i = 0; i < 8; i++) { Ping(); Thread.Sleep(60); }
    lastPing = DateTime.Now; lastClockReset = DateTime.Now;
  }
  void Ping() {
    string t = ((long)XHub.NowMs).ToString();
    if (UsbUp) { hub.Source.Send("ping " + t); return; }
    if (Mode == "wifi") { try { hub.OnPong(Get(BaseUrl + "/ping?t=" + t, 1500)); } catch { } }
  }

  void StopWifi() { XWifi w = wifi; wifi = null; if (w != null) w.Stop(); }

  void Loop() {
    while (run) {
      try { Tick(); } catch (Exception e) { Status = "link error: " + e.Message; }
      Thread.Sleep(250);
    }
  }
  void Tick() {
    XCrazy cz = hub.Crazy;
    if (cz != null && cz.Running) { StopWifi(); Status = "paused (crazy mode)"; return; }
    DateTime now = DateTime.Now;
    OverWifi = Mode == "wifi" && !UsbUp;
    // the board clock drifts a little: re-sync every minute
    if ((now - lastClockReset).TotalSeconds > 60 && (hub.Test == null || !hub.Test.Running)) { hub.ResetClock(); lastClockReset = now; }
    if ((now - lastPing).TotalSeconds > 2) { lastPing = now; Ping(); }
    if (Mode == "usb") {
      StopWifi();
      Status = UsbUp ? "USB cable" : "waiting for the USB cable";
      if (UsbUp && BoardStr("usb") == "0" && (now - lastUsbFix).TotalSeconds > 3) { lastUsbFix = now; hub.Source.Send("set usb 1"); }
      return;
    }
    // ---- WiFi ----
    if (UsbUp && BoardStr("usb") == "1" && (now - lastUsbFix).TotalSeconds > 3) { lastUsbFix = now; hub.Source.Send("set usb 0"); }
    if (OverWifi && (now - lastStatus).TotalSeconds >= 1) {
      lastStatus = now;
      try { string j = Get(BaseUrl + "/status", 2000); if (j.StartsWith("{")) hub.OnCfg(j); } catch { }
    }
    if (wifi == null || ((now - lastResolve).TotalSeconds > 8 && !hub.IsLive)) {
      lastResolve = now;
      string u = Resolve();
      if (wifi == null || u != wifiUrl) { StopWifi(); wifiUrl = u; var w = new XWifi(hub, u); w.Start(); wifi = w; }
    }
    XWifi cur = wifi;
    string ws = cur == null ? "" : cur.Status;
    Status = hub.IsLive ? "WiFi " + new Uri(wifiUrl).Host : "connecting to " + new Uri(wifiUrl).Host + (ws.Length > 0 && ws != "connected" ? " - " + ws : "");
  }

  public string StateJson() {
    var o = new Dictionary<string, object>();
    o["mode"] = Mode; o["host"] = Host; o["url"] = wifiUrl; o["status"] = Status; o["overWifi"] = OverWifi;
    o["clock"] = double.IsNaN(hub.ClockOffset) ? -1 : Math.Round(hub.ClockRtt, 1);
    return XCrazy.Js().Serialize(o);
  }
}

// ============================================================================
//  Link test: record N seconds of exactly what arrives on the PC, measure it,
//  keep the AVI (real timing - freezes stay visible) + a result row
// ============================================================================
public class XTest {
  readonly XHub hub; Thread th; volatile bool running, stopNow;
  public string Dir = "";
  public volatile string Phase = "idle", Err = "";
  public double Seconds; public DateTime Started;
  readonly object fl = new object();
  public XTest(XHub h) { hub = h; }
  public bool Running { get { return running; } }
  string ResultsPath { get { return Path.Combine(Dir, "results.json"); } }

  public void Start(double sec, string antenna, string note) {
    if (running) throw new Exception("a test is already running");
    XCrazy cz = hub.Crazy; if (cz != null && cz.Running) throw new Exception("stop crazy mode first");
    if (!hub.IsLive) throw new Exception(hub.LinkMgr.Mode == "wifi" ? "no WiFi video yet - is this PC on the camera's WiFi?" : "no picture from the camera");
    if (hub.Rec != null) throw new Exception("stop the recording first");
    Seconds = Math.Max(3, Math.Min(600, sec));
    Err = ""; stopNow = false; running = true; Phase = "preparing";
    string ant = antenna == "yes" || antenna == "no" ? antenna : "";
    string nt = (note ?? "").Replace("\r", " ").Replace("\n", " ");
    if (nt.Length > 80) nt = nt.Substring(0, 80);
    th = new Thread(delegate() { Run(ant, nt); }); th.IsBackground = true; th.Start();
  }
  public void Stop() { stopNow = true; }

  static double Num(Dictionary<string, object> d, string k) {
    object v; if (d == null || !d.TryGetValue(k, out v) || v == null) return double.NaN;
    try { return Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture); } catch { return double.NaN; }
  }
  Dictionary<string, object> Board() { try { return XCrazy.Js().DeserializeObject(hub.BoardJson) as Dictionary<string, object>; } catch { return null; } }

  void Run(string antenna, string note) {
    try {
      string link = hub.LinkMgr.Mode;
      while (!stopNow && (DateTime.Now - hub.LastSetAt).TotalSeconds < 4) { Phase = "letting the picture settle"; Thread.Sleep(100); }
      Phase = "syncing clocks";
      hub.LinkMgr.PingBurst();
      Thread.Sleep(400);
      var b0 = Board();
      string pcWifi = link == "wifi" ? XWifi.PcSignal() : "";
      var clip = new XClip(null);
      var cam = new List<double>(); var rssi = new List<double>();
      Started = DateTime.Now; Phase = "recording";
      hub.Tap = clip.Add;
      double secs;
      try {
        DateTime next = DateTime.Now.AddSeconds(1);
        while (!stopNow && (DateTime.Now - Started).TotalSeconds < Seconds) {
          Thread.Sleep(50);
          if (DateTime.Now >= next) {
            next = next.AddSeconds(1);
            var b = Board();
            double cf = Num(b, "cap_fps"); if (!double.IsNaN(cf) && cf > 0) cam.Add(cf);
            double rs = Num(b, "rssi"); if (double.IsNaN(rs) || rs == 0) rs = Num(b, "ap_rssi");
            if (!double.IsNaN(rs) && rs != 0) rssi.Add(rs);
          }
        }
      } finally { hub.Tap = null; }
      secs = Math.Min(Seconds, (DateTime.Now - Started).TotalSeconds);
      clip.Done(secs);
      Phase = "saving";
      var r = new XScores();
      clip.FillStats(r);
      if (clip.Count > 0) {
        byte[] th2; var pic = XScore.Compute(clip.Middle, out th2);
        r.Sharp = pic.Sharp; r.Noise = pic.Noise; r.W = pic.W; r.H = pic.H;
      }
      Directory.CreateDirectory(Dir);
      string id = DateTime.Now.ToString("yyyy-MM-dd_HHmmss") + "_" + (link == "wifi" ? "wifi" + (antenna == "yes" ? "-antenna" : antenna == "no" ? "-no-antenna" : "") : "usb");
      if (clip.Count > 0) {
        clip.WriteAvi(Path.Combine(Dir, id + ".avi"));
        File.WriteAllBytes(Path.Combine(Dir, id + ".jpg"), clip.Middle);
      }
      double camFps = cam.Count > 0 ? Avg(cam) : double.NaN;
      var d = new Dictionary<string, object>();
      d["id"] = id; d["time"] = DateTime.Now.ToString("s"); d["link"] = link; d["antenna"] = antenna; d["note"] = note;
      d["secs"] = Math.Round(secs, 1); d["frames"] = r.Frames; d["w"] = r.W; d["h"] = r.H;
      d["fps"] = Math.Round(r.Fps, 1); d["camFps"] = double.IsNaN(camFps) ? -1 : Math.Round(camFps, 1);
      d["delivered"] = double.IsNaN(camFps) || camFps <= 0 ? -1 : Math.Round(Math.Min(100, r.Fps / camFps * 100));
      d["kbps"] = Math.Round(r.Kbps); d["kbFrame"] = r.Frames > 0 ? Math.Round(r.Kbps / Math.Max(0.1, r.Fps), 1) : 0;
      d["freezes"] = r.Stalls; d["maxGap"] = Math.Round(r.MaxGap); d["jitter"] = Math.Round(r.Jitter, 1);
      d["lat"] = Math.Round(r.LatMed); d["lat90"] = Math.Round(r.LatP90);
      d["rssi"] = rssi.Count > 0 ? Math.Round(Avg(rssi)) : 0; d["rssiMin"] = rssi.Count > 0 ? Min(rssi) : 0;
      d["pcWifi"] = pcWifi;
      d["sharp"] = Math.Round(r.Sharp, 2);
      d["quality"] = Num(b0, "quality"); d["txPower"] = Num(b0, "tx_power"); d["wifiMode"] = Num(b0, "wifi");
      d["overWifi"] = hub.LinkMgr.OverWifi;
      d["video"] = clip.Count > 0;
      lock (fl) { var list = Load(); list.Insert(0, d); Save(list); }
      Phase = "done";
    } catch (Exception e) { Err = e.Message; Phase = "failed"; }
    finally { running = false; }
  }
  static double Avg(List<double> v) { double s = 0; foreach (double x in v) s += x; return s / v.Count; }
  static double Min(List<double> v) { double m = double.MaxValue; foreach (double x in v) m = Math.Min(m, x); return m; }

  List<object> Load() {
    try { if (File.Exists(ResultsPath)) { var a = XCrazy.Js().DeserializeObject(File.ReadAllText(ResultsPath)) as object[]; if (a != null) return new List<object>(a); } } catch { }
    return new List<object>();
  }
  void Save(List<object> list) {
    Directory.CreateDirectory(Dir);
    string tmp = ResultsPath + ".tmp";
    File.WriteAllText(tmp, XCrazy.Js().Serialize(list));
    if (File.Exists(ResultsPath)) File.Delete(ResultsPath);
    File.Move(tmp, ResultsPath);
  }
  public string ListJson() { lock (fl) return XCrazy.Js().Serialize(Load()); }

  static readonly Regex IdRx = new Regex("^[0-9A-Za-z_-]{6,60}$");
  public string FileFor(string id, string ext) {
    if (id == null || !IdRx.IsMatch(id)) return null;
    string p = Path.Combine(Dir, id + ext);
    return File.Exists(p) ? p : null;
  }
  public void Delete(string id) {
    if (id == null || !IdRx.IsMatch(id)) throw new Exception("bad id");
    lock (fl) {
      var list = Load();
      list.RemoveAll(o => { var d = o as Dictionary<string, object>; return d != null && Convert.ToString(d["id"]) == id; });
      Save(list);
    }
    foreach (string e in new[] { ".avi", ".jpg" }) { string p = Path.Combine(Dir, id + e); if (File.Exists(p)) File.Delete(p); }
  }
  public void Rename(string id, string note) {
    if (id == null || !IdRx.IsMatch(id)) throw new Exception("bad id");
    note = (note ?? "").Replace("\r", " ").Replace("\n", " "); if (note.Length > 80) note = note.Substring(0, 80);
    lock (fl) {
      var list = Load();
      foreach (object o in list) { var d = o as Dictionary<string, object>; if (d != null && Convert.ToString(d["id"]) == id) d["note"] = note; }
      Save(list);
    }
  }

  public string StateJson() {
    var o = new Dictionary<string, object>();
    o["running"] = running; o["phase"] = Phase; o["err"] = Err; o["secs"] = Seconds;
    o["elapsed"] = running && Phase == "recording" ? Math.Round((DateTime.Now - Started).TotalSeconds, 1) : 0;
    o["dir"] = Dir;
    return XCrazy.Js().Serialize(o);
  }
}
