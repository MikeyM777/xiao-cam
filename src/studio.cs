using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Ports;
using System.Management;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public interface IXSource {
  void Start(); void Stop(); bool Send(string line);
  bool Connected { get; } string PortLabel { get; }
}

// ============================================================================
//  Hub: newest frame, stats, recorder, board settings
// ============================================================================
public class XHub {
  public string Html = "", PicturesDir = "", VideosDir = "";
  public volatile string Status = "starting";
  public volatile string BoardJson = "";
  public volatile string LastMsg = "";
  public volatile bool Demo;
  public string WantPort = "auto";
  public IXSource Source;
  public XAvi Rec;
  public volatile float Level;
  public DateTime LastCfgAt = DateTime.MinValue, LastFrameAt = DateTime.MinValue;
  readonly object fl = new object(), sl = new object(), rl = new object();
  byte[] frame; long seq; int fw, fh; DateTime frameAt;
  public XCrazy Crazy;
  public bool IsLive { get { return (DateTime.Now - LastFrameAt).TotalSeconds < 2; } }
  public long TotalFrames { get { return Interlocked.Read(ref totalFrames); } }
  public byte[] LatestWithTime(out DateTime at, out int w, out int h) { lock (fl) { at = frameAt; w = fw; h = fh; return frame; } }
  int winFrames; long winBytes; double fps, kbps;
  float peak; int peakN;
  long totalFrames;
  volatile bool shutdown;

  public void StartAll(string crazyDefault) {
    Crazy = new XCrazy(this);
    Crazy.LoadDir(crazyDefault);
    StartSource();
    var t = new Thread(TickLoop); t.IsBackground = true; t.Start();
  }
  public void StartSource() {
    IXSource old = Source;
    if (old != null) old.Stop();
    BoardJson = "";
    Source = Demo ? (IXSource)new XDemo(this) : new XSerial(this, WantPort);
    Source.Start();
  }
  void TickLoop() {
    int n = 0;
    while (!shutdown) {
      Thread.Sleep(1000); n++;
      lock (sl) { fps = winFrames; kbps = winBytes * 8.0 / 1000.0; winFrames = 0; winBytes = 0; }
      XAvi r = Rec;
      if (r != null && n % 2 == 0) { try { r.Tick(); } catch (Exception e) { LastMsg = "recording error: " + e.Message; } }
    }
  }
  public void OnFrame(byte[] jpg) {
    int w, h;
    XJpeg.Size(jpg, out w, out h);
    DateTime now = DateTime.Now;
    lock (fl) { frame = jpg; seq++; fw = w; fh = h; frameAt = now; Monitor.PulseAll(fl); }
    LastFrameAt = now; Interlocked.Increment(ref totalFrames);
    lock (sl) { winFrames++; winBytes += jpg.Length; }
    XAvi r = Rec;
    if (r != null) { try { r.AddVideo(jpg, w, h); } catch (Exception e) { LastMsg = "recording error: " + e.Message; StopRec(); } }
  }
  public void OnAudio(byte[] b, int off, int n) {
    for (int i = off; i + 1 < off + n; i += 2) {
      int s = (short)(b[i] | (b[i + 1] << 8));
      if (s < 0) s = -s;
      if (s > peak) peak = s;
      if (++peakN >= 1600) { Level = peak / 32768f; peak = 0; peakN = 0; }
    }
    XAvi r = Rec;
    if (r != null) { try { r.AddAudio(b, off, n); } catch (Exception e) { LastMsg = "recording error: " + e.Message; StopRec(); } }
  }
  public void OnCfg(string json) { BoardJson = json; LastCfgAt = DateTime.Now; }
  public void OnMsg(string m) { LastMsg = m; }
  public byte[] Latest() { lock (fl) { return frame; } }
  public byte[] WaitFrame(ref long last, int ms) {
    lock (fl) {
      if (seq == last) Monitor.Wait(fl, ms);
      if (seq == last || frame == null) return null;
      last = seq; return frame;
    }
  }
  public bool Cmd(string line) { IXSource s = Source; return s != null && s.Send(line); }

  public string Snapshot() {
    byte[] f = Latest();
    if (f == null) throw new Exception("no picture yet");
    Directory.CreateDirectory(PicturesDir);
    string p = Path.Combine(PicturesDir, "xiao-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".jpg");
    File.WriteAllBytes(p, f);
    LastMsg = "saved " + p;
    return p;
  }
  public string StartRec(double fpsReq, bool audio, double tl, double play) {
    lock (rl) {
      if (Rec != null) return Rec.FilePath;
      double f = fpsReq;
      if (f <= 0) { f = Math.Round(fps); if (f < 1) f = 10; }
      bool aud = audio && tl <= 0;
      if (aud && BoardJson.IndexOf("\"mic\":1", StringComparison.Ordinal) < 0) Cmd("set mic 1");
      string name = "xiao-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + (tl > 0 ? "-timelapse" : "");
      Rec = new XAvi(VideosDir, name, f, aud, tl, play <= 0 ? 30 : play, 16000);
      LastMsg = "recording " + name;
      return name;
    }
  }
  public void StopRec() {
    lock (rl) {
      XAvi r = Rec; Rec = null;
      if (r == null) return;
      try { r.Close(); LastMsg = r.Frames > 0 ? "saved " + r.FilePath : "nothing recorded (no frames arrived)"; }
      catch (Exception e) { LastMsg = "could not finish the file: " + e.Message; }
    }
  }
  public void Shutdown() {
    shutdown = true;
    XCrazy cz = Crazy; if (cz != null) cz.StopAndWait(8000);
    StopRec();
    IXSource s = Source; if (s != null) s.Stop();
  }

  public static string Esc(string s) {
    if (s == null) return "";
    var sb = new StringBuilder();
    foreach (char c in s) {
      if (c == '"' || c == '\\') { sb.Append('\\'); sb.Append(c); }
      else if (c < 32) sb.Append(' ');
      else sb.Append(c);
    }
    return sb.ToString();
  }
  static string N(double d) { return d.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture); }

  public string StateJson() {
    var sb = new StringBuilder();
    IXSource s = Source;
    bool conn = s != null && s.Connected;
    bool live = (DateTime.Now - LastFrameAt).TotalSeconds < 2;
    bool oldFw = conn && live && (DateTime.Now - LastCfgAt).TotalSeconds > 4;
    double f, k; lock (sl) { f = fps; k = kbps; }
    byte[] fr = Latest();
    int w, h; lock (fl) { w = fw; h = fh; }
    sb.Append("{\"pc\":{");
    sb.Append("\"connected\":").Append(conn ? "true" : "false");
    sb.Append(",\"live\":").Append(live ? "true" : "false");
    sb.Append(",\"oldfw\":").Append(oldFw ? "true" : "false");
    sb.Append(",\"demo\":").Append(Demo ? "true" : "false");
    sb.Append(",\"port\":\"").Append(Esc(s == null ? "" : s.PortLabel)).Append("\"");
    sb.Append(",\"want\":\"").Append(Esc(WantPort)).Append("\"");
    sb.Append(",\"status\":\"").Append(Esc(Status)).Append("\"");
    sb.Append(",\"msg\":\"").Append(Esc(LastMsg)).Append("\"");
    sb.Append(",\"fps\":").Append(N(f)).Append(",\"kbps\":").Append(N(k));
    sb.Append(",\"kb\":").Append(fr == null ? "0" : N(fr.Length / 1024.0));
    sb.Append(",\"w\":").Append(w).Append(",\"h\":").Append(h);
    sb.Append(",\"level\":").Append(N(Level));
    sb.Append(",\"frames\":").Append(totalFrames);
    sb.Append(",\"pictures\":\"").Append(Esc(PicturesDir)).Append("\"");
    sb.Append(",\"videos\":\"").Append(Esc(VideosDir)).Append("\"");
    XAvi r = Rec;
    if (r != null) {
      sb.Append(",\"rec\":{\"file\":\"").Append(Esc(Path.GetFileName(r.FilePath))).Append("\"");
      sb.Append(",\"secs\":").Append(N((DateTime.Now - r.Started).TotalSeconds));
      sb.Append(",\"frames\":").Append(r.TotalFrames);
      sb.Append(",\"mb\":").Append(N(r.TotalBytes / 1048576.0));
      sb.Append(",\"fps\":").Append(N(r.Fps));
      sb.Append(",\"audio\":").Append(r.Audio ? "true" : "false");
      sb.Append(",\"tl\":").Append(N(r.TlSec));
      sb.Append(",\"part\":").Append(r.Part).Append("}");
    } else sb.Append(",\"rec\":null");
    sb.Append("},\"crazy\":").Append(Crazy == null ? "null" : Crazy.StateJson());
    sb.Append(",\"board\":");
    string b = BoardJson;
    sb.Append(string.IsNullOrEmpty(b) ? "null" : b);
    sb.Append("}");
    return sb.ToString();
  }

  // finish the recording if the console window is closed with X
  public delegate bool CtrlHandler(int type);
  [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(CtrlHandler h, bool add);
  static CtrlHandler keep;
  public static void HookConsole(XHub hub) {
    keep = delegate(int t) { try { hub.Shutdown(); } catch { } return false; };
    try { SetConsoleCtrlHandler(keep, true); } catch { }
  }
}

// ============================================================================
public static class XJpeg {
  public static bool Size(byte[] b, out int w, out int h) {
    w = 0; h = 0; int i = 2;
    while (i + 9 < b.Length) {
      if (b[i] != 0xFF) { i++; continue; }
      byte m = b[i + 1];
      if (m == 0xFF) { i++; continue; }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
      int L = (b[i + 2] << 8) | b[i + 3];
      if (m >= 0xC0 && m <= 0xC3) { h = (b[i + 5] << 8) | b[i + 6]; w = (b[i + 7] << 8) | b[i + 8]; return true; }
      if (m == 0xDA) return false;
      i += 2 + L;
    }
    return false;
  }
}

// ============================================================================
//  USB serial source
// ============================================================================
public class XSerial : IXSource {
  readonly XHub hub; readonly string want; SerialPort sp; Thread th; volatile bool running;
  readonly object wl = new object(); volatile bool connected; volatile string label = "";
  public XSerial(XHub h, string port) { hub = h; want = string.IsNullOrEmpty(port) ? "auto" : port; }
  public bool Connected { get { return connected; } }
  public string PortLabel { get { return label; } }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { running = false; connected = false; try { if (sp != null) sp.Close(); } catch { } }
  public bool Send(string line) {
    SerialPort s = sp;
    if (s == null || !s.IsOpen) return false;
    try { byte[] b = Encoding.UTF8.GetBytes(line + "\n"); lock (wl) { s.BaseStream.Write(b, 0, b.Length); } return true; }
    catch { return false; }
  }

  public static string FindPort() {
    try {
      using (var q = new ManagementObjectSearcher("SELECT Name, PNPDeviceID FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'")) {
        foreach (ManagementObject o in q.Get()) {
          string id = Convert.ToString(o["PNPDeviceID"]), name = Convert.ToString(o["Name"]);
          if (id.IndexOf("VID_303A", StringComparison.OrdinalIgnoreCase) >= 0 || id.IndexOf("VID_2886", StringComparison.OrdinalIgnoreCase) >= 0) {
            Match m = Regex.Match(name, @"\((COM\d+)\)");
            if (m.Success) return m.Groups[1].Value;
          }
        }
      }
    } catch { }
    return null;
  }

  static int Find(byte[] a, int from, int len) {
    for (int i = from; i + 3 < len; i++) {
      if (a[i] != 0x58) continue;
      byte b1 = a[i + 1], b2 = a[i + 2], b3 = a[i + 3];
      if ((b1 == 'C' && b2 == 'A' && b3 == 'M') || (b1 == 'A' && b2 == 'U' && b3 == 'D') ||
          (b1 == 'C' && b2 == 'F' && b3 == 'G') || (b1 == 'M' && b2 == 'S' && b3 == 'G')) return i;
    }
    return -1;
  }

  void Loop() {
    byte[] acc = new byte[8 << 20]; int len = 0; byte[] chunk = new byte[65536];
    while (running) {
      try {
        if (sp == null || !sp.IsOpen) {
          string p = want == "auto" ? FindPort() : want;
          if (p == null) { label = ""; connected = false; hub.Status = "XIAO not found - plug it in with a USB-C DATA cable"; Thread.Sleep(1000); continue; }
          label = p; hub.Status = "opening " + p;
          var s = new SerialPort(p, 921600);
          s.DtrEnable = true; s.RtsEnable = false;
          s.ReadTimeout = 3000; s.WriteTimeout = 1000; s.ReadBufferSize = 1 << 21;
          s.Open(); sp = s; len = 0; connected = true;
          hub.Status = "connected, waiting for pictures";
          Send("get");
        }
        int n = sp.BaseStream.Read(chunk, 0, chunk.Length);
        if (n <= 0) continue;
        if (len + n > acc.Length) len = 0;
        Buffer.BlockCopy(chunk, 0, acc, len, n); len += n;
        int pos = 0;
        while (true) {
          int m = Find(acc, pos, len);
          if (m < 0) { pos = Math.Max(pos, len - 3); break; }
          if (len - m < 8) { pos = m; break; }
          int L = acc[m + 4] | (acc[m + 5] << 8) | (acc[m + 6] << 16) | (acc[m + 7] << 24);
          char k = (char)acc[m + 1]; char k2 = (char)acc[m + 2];
          bool cam = k == 'C' && k2 == 'A', aud = k == 'A', cfg = k == 'C' && k2 == 'F', msg = k == 'M';
          int max = cam ? 3000000 : aud ? 65536 : cfg ? 16000 : 1000;
          int min = cam ? 100 : 1;
          if (L < min || L > max) { pos = m + 1; continue; }
          if (len - m - 8 < L) { pos = m; break; }
          int d = m + 8;
          if (cam) {
            if (acc[d] == 0xFF && acc[d + 1] == 0xD8) {
              var f = new byte[L]; Buffer.BlockCopy(acc, d, f, 0, L);
              hub.OnFrame(f); hub.Status = "live";
              pos = d + L;
            } else pos = m + 1;
          } else if (aud) { hub.OnAudio(acc, d, L); pos = d + L; }
          else if (cfg) {
            string j = Encoding.UTF8.GetString(acc, d, L);
            if (j.StartsWith("{") && j.EndsWith("}")) { hub.OnCfg(j); if (hub.Status != "live") hub.Status = "connected"; pos = d + L; }
            else pos = m + 1;
          } else { hub.OnMsg("camera says: " + Encoding.ASCII.GetString(acc, d, L)); pos = d + L; }
        }
        if (pos > 0) { Buffer.BlockCopy(acc, pos, acc, 0, len - pos); len -= pos; }
      } catch (TimeoutException) {
        hub.Status = "connected, but nothing arrives - flash the firmware (menu option 1)";
      } catch (Exception e) {
        connected = false;
        if (!running) break;
        hub.Status = "disconnected (" + e.Message.Trim() + ") - retrying";
        try { if (sp != null) sp.Close(); } catch { }
        sp = null; Thread.Sleep(1000);
      }
    }
    try { if (sp != null) sp.Close(); } catch { }
  }
}

// ============================================================================
//  Demo source (no board): fake camera with the same settings protocol
// ============================================================================
public class XDemo : IXSource {
  readonly XHub hub; Thread th; volatile bool running;
  readonly Dictionary<string, int> v = new Dictionary<string, int>();
  readonly Dictionary<string, string> s = new Dictionary<string, string>();
  readonly object l = new object();
  static readonly int[] SW = { 96, 160, 128, 176, 240, 240, 320, 320, 400, 480, 640, 800, 1024, 1280, 1280, 1600, 1920, 720, 864, 2048 };
  static readonly int[] SH = { 96, 120, 128, 144, 176, 240, 240, 320, 296, 320, 480, 600, 768, 720, 1024, 1200, 1080, 1280, 1536, 1536 };
  const int MAXS = 19;
  double fpsNow;
  public XDemo(XHub h) {
    hub = h;
    string init = "framesize=11,quality=10,brightness=0,contrast=0,saturation=0,sharpness=0,denoise=0,effect=0,awb=1,awb_gain=1,wb_mode=0," +
      "aec=1,aec2=0,ae_level=0,aec_value=300,agc=1,agc_gain=0,gainceiling=0,bpc=0,wpc=1,raw_gma=1,lenc=1,hmirror=0,vflip=1,dcw=1,colorbar=0," +
      "fps_limit=0,xclk=20,led=0,mic=0,usb=1,wifi=1,ap_ch=6,tx_power=78";
    foreach (string kv in init.Split(',')) { string[] p = kv.Split('='); v[p[0]] = int.Parse(p[1]); }
    s["ap_ssid"] = "XIAO-CAM"; s["ap_pass"] = "xiaocam123"; s["sta_ssid"] = ""; s["sta_pass"] = "";
  }
  public bool Connected { get { return running; } }
  public string PortLabel { get { return "DEMO"; } }
  public void Start() { running = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); hub.Status = "demo"; }
  public void Stop() { running = false; }
  int Get(string k) { lock (l) { int x; return v.TryGetValue(k, out x) ? x : 0; } }
  public bool Send(string line) {
    string[] p = line.Trim().Split(new[] { ' ' }, 3);
    lock (l) {
      if (p[0] == "set" && p.Length == 3) {
        int x; if (!int.TryParse(p[2], out x)) return false;
        if (p[1] == "framesize") x = Math.Max(0, Math.Min(MAXS, x));
        v[p[1]] = x;
      } else if (p[0] == "str" && p.Length >= 2) s[p[1]] = p.Length == 3 ? p[2] : "";
      else if (p[0] == "defaults") { v["framesize"] = 11; v["quality"] = 10; }
    }
    hub.OnCfg(Json());
    return true;
  }
  string Json() {
    var sb = new StringBuilder();
    sb.Append("{\"fw\":\"2.0-demo\",\"cam\":1,\"cam_err\":\"\",\"sensor\":\"DEMO (OV3660-like)\",\"max_size\":").Append(MAXS);
    sb.Append(",\"sizes\":[");
    for (int i = 0; i <= MAXS; i++) { if (i > 0) sb.Append(','); sb.Append('[').Append(SW[i]).Append(',').Append(SH[i]).Append(']'); }
    sb.Append(']');
    lock (l) {
      foreach (var kv in v) sb.Append(",\"").Append(kv.Key).Append("\":").Append(kv.Value);
      foreach (var kv in s) sb.Append(",\"").Append(kv.Key).Append("\":\"").Append(XHub.Esc(kv.Value)).Append('"');
      int wm = v["wifi"];
      sb.Append(",\"mic_rate\":16000,\"sta_status\":").Append((wm & 2) != 0 ? (s["sta_ssid"].Length > 0 ? 3 : 1) : -1);
      sb.Append(",\"ap_ip\":\"").Append((wm & 1) != 0 ? "192.168.4.1" : "").Append('"');
      sb.Append(",\"sta_ip\":\"").Append((wm & 2) != 0 && s["sta_ssid"].Length > 0 ? "192.168.1.77" : "").Append('"');
      sb.Append(",\"rssi\":").Append((wm & 2) != 0 ? -58 : 0);
      sb.Append(",\"ap_clients\":0,\"stream_clients\":0");
    }
    sb.Append(",\"cap_fps\":").Append(((int)fpsNow).ToString()).Append(",\"usb_fps\":").Append(((int)fpsNow).ToString());
    sb.Append(",\"temp\":41.5,\"heap\":231000,\"psram\":6800000,\"uptime\":").Append((int)(Environment.TickCount / 1000 % 100000));
    sb.Append(",\"saved\":1}");
    return sb.ToString();
  }
  void Loop() { try { Loop2(); } catch (Exception e) { hub.OnMsg("demo crashed: " + e.ToString()); } }
  void Loop2() {
    var sw = Stopwatch.StartNew();
    long audioDone = 0; double nextFrame = 0, nextCfg = 0, fpsT = 0; int fpsN = 0;
    ImageCodecInfo jpg = null;
    foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpg = c;
    while (running) {
      double t = sw.Elapsed.TotalSeconds;
      if (t >= nextCfg) { hub.OnCfg(Json()); nextCfg = t + 1; }
      if (t - fpsT >= 1) { fpsNow = fpsN / (t - fpsT); fpsN = 0; fpsT = t; }
      if (Get("mic") == 1) {
        long due = (long)(t * 16000);
        int n = (int)Math.Min(due - audioDone, 8000);
        if (n >= 320) {
          byte[] a = new byte[n * 2];
          for (int i = 0; i < n; i++) {
            double tt = (audioDone + i) / 16000.0;
            double amp = 0.25 * (0.5 + 0.5 * Math.Sin(tt * 3));
            short x = (short)(Math.Sin(2 * Math.PI * 440 * tt) * amp * 32767);
            a[2 * i] = (byte)x; a[2 * i + 1] = (byte)(x >> 8);
          }
          audioDone += n; hub.OnAudio(a, 0, a.Length);
        }
      } else audioDone = (long)(t * 16000);
      int fl = Get("fps_limit");
      int dfs = Get("framesize");
      double dfps = 25 * Math.Pow(480000.0 / (SW[dfs] * SH[dfs]), 0.7) * Math.Pow(Math.Max(4, Get("quality")) / 10.0, 0.3) * Get("xclk") / 20.0;
      dfps = Math.Max(2, Math.Min(25, dfps));
      if (fl > 0) dfps = Math.Min(dfps, fl);
      double period = 1.0 / dfps;
      if (t >= nextFrame && Get("usb") == 1) {
        nextFrame = t + period;
        try { hub.OnFrame(Render(t, jpg)); fpsN++; } catch (Exception e) { hub.OnMsg("demo: " + e.Message); }
      }
      Thread.Sleep(4);
    }
  }
  public byte[] Render(double t, ImageCodecInfo codec) {
    int fs = Get("framesize"); int w = SW[fs], h = SH[fs];
    int br = 0, sat = 0;
    using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb))
    using (var g = Graphics.FromImage(bmp)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      int b0 = 30 + br * 20;
      using (var bg = new LinearGradientBrush(new Rectangle(0, 0, w, h), Color.FromArgb(b0, b0 + 10, b0 + 25 + sat * 10), Color.FromArgb(b0 + 40, b0 + 20, b0), 35f))
        g.FillRectangle(bg, 0, 0, w, h);
      if (Get("colorbar") == 1) {
        Color[] cols = { Color.White, Color.Yellow, Color.Cyan, Color.Lime, Color.Magenta, Color.Red, Color.Blue, Color.Black };
        for (int i = 0; i < 8; i++) using (var cb = new SolidBrush(cols[i])) g.FillRectangle(cb, i * w / 8, 0, w / 8 + 1, h);
      } else {
        using (var pen = new Pen(Color.FromArgb(60, 255, 255, 255), Math.Max(1, w / 400f)))
          for (int i = 1; i < 12; i++) { g.DrawLine(pen, i * w / 12, 0, i * w / 12, h); g.DrawLine(pen, 0, i * h / 12, w, i * h / 12); }
        float r = Math.Min(w, h) * 0.12f;
        float cx = (float)(w / 2 + Math.Cos(t * 0.9) * w * 0.3), cy = (float)(h / 2 + Math.Sin(t * 1.3) * h * 0.25);
        using (var cb = new SolidBrush(Color.FromArgb(220, 59, 130, 246))) g.FillEllipse(cb, cx - r, cy - r, 2 * r, 2 * r);
        using (var cb = new SolidBrush(Color.FromArgb(200, 239, 68, 68))) g.FillRectangle(cb, w * 0.1f, h * 0.65f, w * 0.15f, h * 0.2f);
        // fine detail target, for the focus meter
        using (var pen = new Pen(Color.White, 1)) for (int i = 0; i < 40; i++) g.DrawLine(pen, w * 0.7f + i * 3, h * 0.65f, w * 0.7f + i * 3, h * 0.85f);
      }
      float fsz = Math.Max(8, h / 18f);
      using (var font = new Font("Segoe UI", fsz, FontStyle.Bold))
      using (var tb = new SolidBrush(Color.White)) {
        g.DrawString("DEMO  " + w + "x" + h + "  q" + Get("quality"), font, tb, w * 0.03f, h * 0.04f);
        g.DrawString(DateTime.Now.ToString("HH:mm:ss.f"), font, tb, w * 0.03f, h * 0.04f + fsz * 1.6f);
      }
      // camera model: exposure, gain, noise, color
      double lum;
      if (Get("aec") == 1) lum = 0.45 + Get("ae_level") * 0.08 + (Get("aec2") == 1 ? 0.03 : 0);
      else lum = 0.55 * Get("aec_value") / 400.0 * (Get("agc") == 1 ? 1 + Get("gainceiling") * 0.3 : Get("agc_gain") + 1);
      lum += Get("brightness") * 0.05;
      float k = (float)(lum / 0.45), ct = 1 + Get("contrast") * 0.15f, st = Get("effect") == 2 ? 0 : 1 + Get("saturation") * 0.25f;
      float tr = 0, tbl = 0; int wm = Get("wb_mode");
      if (Get("awb") == 0) tbl = 0.08f; else if (Get("awb_gain") == 1) { if (wm == 1) tr = 0.05f; else if (wm == 2) tr = 0.08f; else if (wm == 3) tbl = 0.05f; else if (wm == 4) tr = 0.1f; }
      float lr = 0.299f, lg = 0.587f, lb = 0.114f;
      float a = (1 - st) * lr, b2 = (1 - st) * lg, c2 = (1 - st) * lb;
      var cm = new ColorMatrix(new float[][] {
        new float[] { (a + st) * k * ct, a * k * ct, a * k * ct, 0, 0 },
        new float[] { b2 * k * ct, (b2 + st) * k * ct, b2 * k * ct, 0, 0 },
        new float[] { c2 * k * ct, c2 * k * ct, (c2 + st) * k * ct, 0, 0 },
        new float[] { 0, 0, 0, 1, 0 },
        new float[] { 0.5f * (1 - ct) + tr, 0.5f * (1 - ct), 0.5f * (1 - ct) + tbl, 0, 1 } });
      using (var src = (Bitmap)bmp.Clone())
      using (var ia = new ImageAttributes()) {
        ia.SetColorMatrix(cm);
        g.DrawImage(src, new Rectangle(0, 0, w, h), 0, 0, w, h, GraphicsUnit.Pixel, ia);
      }
      double noise = (Get("agc") == 1 ? Get("gainceiling") * 0.02 : Get("agc_gain") * 0.015) * (1 - Get("denoise") / 10.0);
      if (noise > 0) {
        var rnd = new Random();
        int nd = (int)(noise * w * h / 6);
        using (var nb = new SolidBrush(Color.Black))
          for (int i = 0; i < nd; i++) { int gv = rnd.Next(256); nb.Color = Color.FromArgb(150, gv, gv, gv); g.FillRectangle(nb, rnd.Next(w), rnd.Next(h), 2, 2); }
      }
      if (Get("hmirror") == 1) bmp.RotateFlip(RotateFlipType.RotateNoneFlipX);
      if (Get("vflip") == 0) bmp.RotateFlip(RotateFlipType.RotateNoneFlipY);
      var ms = new MemoryStream();
      var ep = new EncoderParameters(1);
      long q = Math.Max(10, Math.Min(95, 100 - (Get("quality") - 4) * 3 / 2));
      ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, q);
      bmp.Save(ms, codec, ep);
      return ms.ToArray();
    }
  }
}

// ============================================================================
//  AVI writer: MJPEG video (+ PCM16 mono audio), plays in VLC / Windows players
// ============================================================================
public class XAvi {
  readonly object l = new object();
  readonly string dir, baseName;
  FileStream f; BinaryWriter w;
  public string FilePath = "";
  public double Fps, TlSec, PlayFps; public bool Audio; public int Rate;
  public int Part = 1, W, H;
  public long Frames, AudioBytes, TotalFrames, TotalBytesClosed;
  public DateTime Started = DateTime.Now;
  DateTime t0, lastTl;
  long moviSizePos, moviPos, avihFramesPos, avihBufPos, vLenPos, aLenPos;
  List<uint> idx = new List<uint>();
  int maxChunk; bool closed;
  const long SplitBytes = 1800L * 1024 * 1024;

  public XAvi(string dir, string baseName, double fps, bool audio, double tlSec, double playFps, int rate) {
    this.dir = dir; this.baseName = baseName; Fps = fps; Audio = audio; TlSec = tlSec; PlayFps = playFps; Rate = rate;
  }
  public long TotalBytes { get { lock (l) { return TotalBytesClosed + (f == null ? 0 : f.Position); } } }

  void FCC(string s) { w.Write((byte)s[0]); w.Write((byte)s[1]); w.Write((byte)s[2]); w.Write((byte)s[3]); }
  static uint Code(string s) { return (uint)(s[0] | (s[1] << 8) | (s[2] << 16) | (s[3] << 24)); }
  void At(long pos, uint val) { long e = f.Position; f.Seek(pos, SeekOrigin.Begin); w.Write(val); f.Seek(e, SeekOrigin.Begin); }
  void SizeFrom(long pos) { At(pos, (uint)(f.Position - pos - 4)); }

  void Open() {
    Directory.CreateDirectory(dir);
    FilePath = Path.Combine(dir, baseName + (Part > 1 ? "_part" + Part : "") + ".avi");
    f = new FileStream(FilePath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 1 << 20);
    w = new BinaryWriter(f);
    idx = new List<uint>(); Frames = 0; AudioBytes = 0; maxChunk = 0; aLenPos = 0;
    double pf = TlSec > 0 ? PlayFps : Fps;
    int streams = Audio ? 2 : 1;
    FCC("RIFF"); w.Write(0u); FCC("AVI ");
    FCC("LIST"); long hdrl = f.Position; w.Write(0u); FCC("hdrl");
    FCC("avih"); w.Write(56u);
    w.Write((uint)Math.Round(1000000.0 / pf)); w.Write(0u); w.Write(0u); w.Write(0x10u);
    avihFramesPos = f.Position; w.Write(0u); w.Write(0u); w.Write((uint)streams);
    avihBufPos = f.Position; w.Write(1u << 20);
    w.Write((uint)W); w.Write((uint)H); w.Write(0u); w.Write(0u); w.Write(0u); w.Write(0u);
    // video stream
    FCC("LIST"); long s1 = f.Position; w.Write(0u); FCC("strl");
    FCC("strh"); w.Write(56u); FCC("vids"); FCC("MJPG"); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
    w.Write(1000u); w.Write((uint)Math.Round(pf * 1000)); w.Write(0u);
    vLenPos = f.Position; w.Write(0u);
    w.Write(1u << 20); w.Write(0xFFFFFFFFu); w.Write(0u);
    w.Write((short)0); w.Write((short)0); w.Write((short)W); w.Write((short)H);
    FCC("strf"); w.Write(40u); w.Write(40u); w.Write(W); w.Write(H); w.Write((ushort)1); w.Write((ushort)24); FCC("MJPG");
    w.Write((uint)(W * H * 3)); w.Write(0); w.Write(0); w.Write(0u); w.Write(0u);
    SizeFrom(s1);
    if (Audio) {
      FCC("LIST"); long s2 = f.Position; w.Write(0u); FCC("strl");
      FCC("strh"); w.Write(56u); FCC("auds"); w.Write(0u); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
      w.Write(2u); w.Write((uint)(Rate * 2)); w.Write(0u);
      aLenPos = f.Position; w.Write(0u);
      w.Write(16384u); w.Write(0xFFFFFFFFu); w.Write(2u);
      w.Write((short)0); w.Write((short)0); w.Write((short)0); w.Write((short)0);
      FCC("strf"); w.Write(18u); w.Write((ushort)1); w.Write((ushort)1); w.Write((uint)Rate); w.Write((uint)(Rate * 2));
      w.Write((ushort)2); w.Write((ushort)16); w.Write((ushort)0);
      SizeFrom(s2);
    }
    SizeFrom(hdrl);
    FCC("LIST"); moviSizePos = f.Position; w.Write(0u); moviPos = f.Position; FCC("movi");
    w.Flush();
  }

  void Chunk(string fcc, byte[] d, int off, int n) {
    uint rel = (uint)(f.Position - moviPos);
    FCC(fcc); w.Write((uint)n); w.Write(d, off, n);
    if ((n & 1) == 1) w.Write((byte)0);
    idx.Add(Code(fcc)); idx.Add(0x10u); idx.Add(rel); idx.Add((uint)n);
    if (n > maxChunk) maxChunk = n;
  }

  void Patch() {
    At(4, (uint)(f.Position - 8));
    At(moviSizePos, (uint)(f.Position - moviSizePos - 4));
    At(avihFramesPos, (uint)Frames); At(vLenPos, (uint)Frames);
    At(avihBufPos, (uint)(maxChunk + 8));
    if (aLenPos > 0) At(aLenPos, (uint)(AudioBytes / 2));
  }

  void Finish() {
    if (f == null) return;
    At(moviSizePos, (uint)(f.Position - moviSizePos - 4));
    FCC("idx1"); w.Write((uint)(idx.Count * 4));
    foreach (uint u in idx) w.Write(u);
    Patch();
    w.Flush(); TotalBytesClosed += f.Length; f.Close();
    f = null; w = null;
  }

  public void AddVideo(byte[] jpg, int jw, int jh) {
    lock (l) {
      if (closed || jw <= 0 || jh <= 0) return;
      DateTime now = DateTime.Now;
      if (f == null) { W = jw; H = jh; t0 = now; Open(); }
      else if (jw != W || jh != H || f.Position > SplitBytes) {
        // resolution changed (or file too big): continue in a new part file
        Finish(); Part++; W = jw; H = jh; t0 = now; Open();
      }
      if (TlSec > 0) {
        if (Frames == 0 || (now - lastTl).TotalSeconds >= TlSec) { Chunk("00dc", jpg, 0, jpg.Length); Frames++; TotalFrames++; lastTl = now; }
        return;
      }
      long target = (long)Math.Floor((now - t0).TotalSeconds * Fps) + 1;
      long n = target - Frames;
      if (n <= 0) return;
      if (n > Fps + 2) { t0 = now - TimeSpan.FromSeconds(Frames / Fps); n = 1; }  // long gap (unplugged): cut instead of freezing
      for (long i = 0; i < n; i++) { Chunk("00dc", jpg, 0, jpg.Length); Frames++; TotalFrames++; }
    }
  }
  public void AddAudio(byte[] d, int off, int n) {
    lock (l) {
      if (closed || f == null || !Audio || TlSec > 0) return;
      Chunk("01wb", d, off, n & ~1); AudioBytes += n & ~1;
    }
  }
  public void Tick() { lock (l) { if (f != null && !closed) { Patch(); w.Flush(); f.Flush(); } } }
  public void Close() { lock (l) { if (closed) return; closed = true; Finish(); } }
}

// ============================================================================
//  Tiny local web server (127.0.0.1 only)
// ============================================================================
public class XWeb {
  readonly XHub hub; TcpListener lst; public int Port;
  public XWeb(XHub h) { hub = h; }
  public int Start(int port) {
    for (int i = 0; i < 30; i++) {
      try {
        lst = new TcpListener(IPAddress.Loopback, port + i); lst.Start(); Port = port + i;
        var t = new Thread(Accept); t.IsBackground = true; t.Start();
        return Port;
      } catch (SocketException) { }
    }
    throw new Exception("no free local port for the studio");
  }
  void Accept() {
    while (true) {
      TcpClient c;
      try { c = lst.AcceptTcpClient(); } catch { return; }
      var t = new Thread(Handle); t.IsBackground = true; t.Start(c);
    }
  }
  static string ReadHead(NetworkStream ns) {
    var buf = new List<byte>(); int b;
    while (buf.Count < 16384 && (b = ns.ReadByte()) >= 0) {
      buf.Add((byte)b);
      int n = buf.Count;
      if (n >= 4 && buf[n - 1] == 10 && buf[n - 2] == 13 && buf[n - 3] == 10 && buf[n - 4] == 13) return Encoding.ASCII.GetString(buf.ToArray());
    }
    return null;
  }
  static Dictionary<string, string> Query(string q) {
    var d = new Dictionary<string, string>();
    foreach (string part in q.Split('&')) {
      if (part.Length == 0) continue;
      int e = part.IndexOf('=');
      string k = e < 0 ? part : part.Substring(0, e), v = e < 0 ? "" : part.Substring(e + 1);
      d[Uri.UnescapeDataString(k.Replace('+', ' '))] = Uri.UnescapeDataString(v.Replace('+', ' '));
    }
    return d;
  }
  static void Send(NetworkStream ns, string code, string type, byte[] body) {
    string h = "HTTP/1.1 " + code + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    byte[] hb = Encoding.ASCII.GetBytes(h);
    ns.Write(hb, 0, hb.Length); ns.Write(body, 0, body.Length);
  }
  static void Json(NetworkStream ns, string j) { Send(ns, "200 OK", "application/json", Encoding.UTF8.GetBytes(j)); }
  static string Ok(bool ok, string extra) { return "{\"ok\":" + (ok ? "true" : "false") + (extra == null ? "" : "," + extra) + "}"; }
  static string G(Dictionary<string, string> q, string k) { string v; return q.TryGetValue(k, out v) ? v : ""; }
  static double D(Dictionary<string, string> q, string k, double def) {
    double d; return double.TryParse(G(q, k), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d) ? d : def;
  }
  static readonly Regex KeyRx = new Regex("^[a-z0-9_]{1,20}$");
  static readonly string[] Cmds = { "get", "save", "defaults", "reboot", "wifi_apply" };

  void Handle(object o) {
    var c = (TcpClient)o;
    try {
      c.NoDelay = true;
      NetworkStream ns = c.GetStream(); ns.ReadTimeout = 10000;
      string head = ReadHead(ns);
      if (head == null) return;
      string[] first = head.Split('\n')[0].Trim().Split(' ');
      if (first.Length < 2) return;
      string url = first[1], path = url, qs = "";
      int qi = url.IndexOf('?');
      if (qi >= 0) { path = url.Substring(0, qi); qs = url.Substring(qi + 1); }
      var q = Query(qs);
      ns.ReadTimeout = Timeout.Infinite;
      Route(c, ns, path, q);
    } catch { }
    finally { try { c.Close(); } catch { } }
  }

  void Route(TcpClient c, NetworkStream ns, string path, Dictionary<string, string> q) {
    switch (path) {
      case "/":
        Send(ns, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(hub.Html)); return;
      case "/stream": Stream(c, ns); return;
      case "/frame.jpg": {
        byte[] f = hub.Latest();
        if (f == null) Send(ns, "404 Not Found", "text/plain", Encoding.ASCII.GetBytes("no frame"));
        else Send(ns, "200 OK", "image/jpeg", f);
        return;
      }
      case "/api/state": Json(ns, hub.StateJson()); return;
      case "/api/set": {
        string k = G(q, "k"); int v;
        bool ok = KeyRx.IsMatch(k) && int.TryParse(G(q, "v"), out v) && hub.Cmd("set " + k + " " + v.ToString());
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/str": {
        string k = G(q, "k"), v = G(q, "v").Replace("\r", "").Replace("\n", "");
        bool ok = KeyRx.IsMatch(k) && v.Length <= 64 && hub.Cmd("str " + k + " " + v);
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/cmd": {
        string cmd = G(q, "c");
        bool ok = Array.IndexOf(Cmds, cmd) >= 0 && hub.Cmd(cmd);
        Json(ns, Ok(ok, null)); return;
      }
      case "/api/snap":
        try { string p = hub.Snapshot(); Json(ns, Ok(true, "\"file\":\"" + XHub.Esc(p) + "\"")); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/rec/start":
        try {
          string n = hub.StartRec(D(q, "fps", 0), G(q, "audio") == "1", D(q, "tl", 0), D(q, "play", 30));
          Json(ns, Ok(true, "\"file\":\"" + XHub.Esc(n) + "\""));
        } catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/rec/stop": hub.StopRec(); Json(ns, Ok(true, "\"msg\":\"" + XHub.Esc(hub.LastMsg) + "\"")); return;
      case "/api/open": {
        string d = G(q, "d") == "pictures" ? hub.PicturesDir : hub.VideosDir;
        try { Directory.CreateDirectory(d); Process.Start("explorer.exe", "\"" + d + "\""); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      }
      case "/api/ports": {
        var sb = new StringBuilder("{\"ok\":true,\"auto\":\"");
        sb.Append(XHub.Esc(XSerial.FindPort() ?? "")).Append("\",\"ports\":[");
        string[] ps = SerialPort.GetPortNames(); Array.Sort(ps);
        for (int i = 0; i < ps.Length; i++) { if (i > 0) sb.Append(','); sb.Append('"').Append(XHub.Esc(ps[i])).Append('"'); }
        sb.Append("]}");
        Json(ns, sb.ToString()); return;
      }
      case "/api/port": {
        string p = G(q, "p");
        if (p == "demo") { hub.Demo = true; }
        else if (p == "auto" || Regex.IsMatch(p, "^COM[0-9]{1,3}$")) { hub.Demo = false; hub.WantPort = p; }
        else { Json(ns, Ok(false, null)); return; }
        hub.StartSource(); Json(ns, Ok(true, null)); return;
      }
      case "/api/crazy/start":
        try { hub.Crazy.Quick = G(q, "quick") == "1"; hub.Crazy.MaxRounds = (int)D(q, "rounds", 0); hub.Crazy.Start(); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/stop": hub.Crazy.Stop(); Json(ns, Ok(true, null)); return;
      case "/api/crazy/folder":
        try {
          string d = G(q, "pick") == "1" ? XCrazy.PickFolder(hub.Crazy.OutDir) : G(q, "path");
          if (d == null) { Json(ns, Ok(false, "\"err\":\"cancelled\"")); return; }
          d = hub.Crazy.SetDir(d.Trim());
          Json(ns, Ok(true, "\"dir\":\"" + XHub.Esc(d) + "\""));
        } catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/open":
        try { Directory.CreateDirectory(hub.Crazy.OutDir); Process.Start("explorer.exe", "\"" + hub.Crazy.OutDir + "\""); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/api/crazy/rounds": Json(ns, hub.Crazy.RoundsJson()); return;
      case "/api/crazy/round": {
        string j = hub.Crazy.RoundJson(G(q, "id"));
        if (j == null) Send(ns, "404 Not Found", "application/json", Encoding.ASCII.GetBytes("{\"ok\":false}")); else Json(ns, j);
        return;
      }
      case "/api/crazy/stars": Json(ns, XCrazy.Js().Serialize(hub.Crazy.Stars())); return;
      case "/api/crazy/star":
        try { hub.Crazy.Star(G(q, "p"), G(q, "on") == "1"); Json(ns, Ok(true, null)); }
        catch (Exception e) { Json(ns, Ok(false, "\"err\":\"" + XHub.Esc(e.Message) + "\"")); }
        return;
      case "/crazy/file": {
        string f = hub.Crazy.SafeFile(G(q, "p"));
        if (f == null) Send(ns, "403 Forbidden", "text/plain", Encoding.ASCII.GetBytes("no"));
        else Send(ns, "200 OK", "image/jpeg", File.ReadAllBytes(f));
        return;
      }
      case "/api/quit": {
        Json(ns, Ok(true, null));
        var t = new Thread(delegate() { Thread.Sleep(300); hub.Shutdown(); Environment.Exit(0); });
        t.IsBackground = true; t.Start();
        return;
      }
      default:
        Send(ns, "404 Not Found", "text/plain", Encoding.ASCII.GetBytes("not found")); return;
    }
  }

  void Stream(TcpClient c, NetworkStream ns) {
    byte[] hb = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=xframe\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
    ns.Write(hb, 0, hb.Length);
    long last = -1;
    while (true) {
      byte[] f = hub.WaitFrame(ref last, 1000);
      if (f == null) {
        if (c.Client.Poll(0, SelectMode.SelectRead) && c.Client.Available == 0) return;  // browser went away
        continue;
      }
      byte[] ph = Encoding.ASCII.GetBytes("--xframe\r\nContent-Type: image/jpeg\r\nContent-Length: " + f.Length + "\r\n\r\n");
      ns.Write(ph, 0, ph.Length); ns.Write(f, 0, f.Length); ns.Write(new byte[] { 13, 10 }, 0, 2);
    }
  }
}
