// ============================================================================
//  5-second clip: frames with their real arrival time -> AVI + index + stats
// ============================================================================
public class XClip {
  readonly object l = new object();
  readonly int[] want;
  public readonly List<byte[]> Jpgs = new List<byte[]>();
  public readonly List<double> T = new List<double>(), Lat = new List<double>();
  double t0 = -1, dur;
  bool open = true;
  public XClip(int[] wantSize) { want = wantSize; }
  public int Count { get { lock (l) return Jpgs.Count; } }
  public void Add(byte[] jpg, int w, int h, double pcMs, double lat) {
    lock (l) {
      if (!open) return;
      if (t0 < 0) t0 = pcMs;
      if (want != null && (w != want[0] || h != want[1])) return;   // old size still in flight
      Jpgs.Add(jpg); T.Add(pcMs); Lat.Add(lat);
    }
  }
  public void Done(double seconds) { lock (l) { open = false; dur = seconds; } }
  public byte[] Middle { get { lock (l) return Jpgs.Count == 0 ? null : Jpgs[Jpgs.Count / 2]; } }

  static double Pct(List<double> v, double p) {
    if (v.Count == 0) return -1;
    var s = new List<double>(v); s.Sort();
    return s[Math.Min(s.Count - 1, (int)Math.Floor(p * (s.Count - 1) + 0.5))];
  }
  public void FillStats(XScores r) {
    lock (l) {
      int n = Jpgs.Count; r.Frames = n; r.Dur = dur;
      long bytes = 0; foreach (var j in Jpgs) bytes += j.Length;
      r.Fps = dur > 0 ? n / dur : 0;
      r.Kbps = dur > 0 ? bytes / 1024.0 / dur : 0;
      var gaps = new List<double>();
      for (int i = 1; i < n; i++) gaps.Add(T[i] - T[i - 1]);
      double med = gaps.Count > 0 ? Pct(gaps, 0.5) : dur * 1000;
      double thr = Math.Max(3 * med, 250);
      int stalls = 0; double mg = 0, s1 = 0, s2 = 0;
      foreach (double g in gaps) { if (g > thr) stalls++; mg = Math.Max(mg, g); s1 += g; s2 += g * g; }
      if (n < 2) { stalls = 1; mg = dur * 1000; }
      r.Stalls = stalls; r.MaxGap = mg;
      r.Jitter = gaps.Count > 1 ? Math.Sqrt(Math.Max(0, s2 / gaps.Count - (s1 / gaps.Count) * (s1 / gaps.Count))) : 0;
      var lat = new List<double>(); foreach (double x in Lat) if (x >= 0 && x < 10000) lat.Add(x);
      r.LatMed = lat.Count > 0 ? Pct(lat, 0.5) : -1; r.LatP90 = lat.Count > 0 ? Pct(lat, 0.9) : -1;
    }
  }

  // AVI MJPEG at a nominal 30 fps; empty chunks keep the real timing (freezes stay visible)
  public Dictionary<string, object> WriteAvi(string path) {
    lock (l) {
      const int F = 30;
      int n = Jpgs.Count;
      int W = 0, H = 0; if (n > 0) XJpeg.Size(Jpgs[0], out W, out H);
      double start = n > 0 ? T[0] : 0;
      var frames = new List<object>();
      using (var f = new FileStream(path, FileMode.Create, FileAccess.ReadWrite))
      using (var w = new BinaryWriter(f)) {
        Action<string> fcc = s => { w.Write((byte)s[0]); w.Write((byte)s[1]); w.Write((byte)s[2]); w.Write((byte)s[3]); };
        Action<long, uint> at = (pos, v) => { long e = f.Position; f.Seek(pos, SeekOrigin.Begin); w.Write(v); f.Seek(e, SeekOrigin.Begin); };
        fcc("RIFF"); w.Write(0u); fcc("AVI ");
        fcc("LIST"); long hdrl = f.Position; w.Write(0u); fcc("hdrl");
        fcc("avih"); w.Write(56u); w.Write((uint)(1000000 / F)); w.Write(0u); w.Write(0u); w.Write(0x10u);
        long totPos = f.Position; w.Write(0u); w.Write(0u); w.Write(1u); w.Write(1u << 20);
        w.Write((uint)W); w.Write((uint)H); w.Write(0u); w.Write(0u); w.Write(0u); w.Write(0u);
        fcc("LIST"); long strl = f.Position; w.Write(0u); fcc("strl");
        fcc("strh"); w.Write(56u); fcc("vids"); fcc("MJPG"); w.Write(0u); w.Write((ushort)0); w.Write((ushort)0); w.Write(0u);
        w.Write(1u); w.Write((uint)F); w.Write(0u); long lenPos = f.Position; w.Write(0u);
        w.Write(1u << 20); w.Write(0xFFFFFFFFu); w.Write(0u); w.Write((short)0); w.Write((short)0); w.Write((short)W); w.Write((short)H);
        fcc("strf"); w.Write(40u); w.Write(40u); w.Write(W); w.Write(H); w.Write((ushort)1); w.Write((ushort)24); fcc("MJPG");
        w.Write((uint)(W * H * 3)); w.Write(0); w.Write(0); w.Write(0u); w.Write(0u);
        at(strl, (uint)(f.Position - strl - 4)); at(hdrl, (uint)(f.Position - hdrl - 4));
        fcc("LIST"); long movi = f.Position; w.Write(0u); long moviData = f.Position; fcc("movi");
        var idx = new List<uint>(); int slot = -1;
        Action<byte[]> chunk = d => {
          uint rel = (uint)(f.Position - moviData); int len = d == null ? 0 : d.Length;
          fcc("00dc"); w.Write((uint)len); if (len > 0) { w.Write(d); if ((len & 1) == 1) w.Write((byte)0); }
          idx.Add(0x63643030u); idx.Add(len > 0 ? 0x10u : 0u); idx.Add(rel); idx.Add((uint)len);
        };
        for (int i = 0; i < n; i++) {
          int s = (int)Math.Round((T[i] - start) / 1000.0 * F);
          if (s <= slot) continue;                       // two frames in one 1/30 s: keep the first
          while (slot < s - 1) { chunk(null); slot++; }  // freeze: repeat the previous frame
          long dataOff = f.Position + 8;
          chunk(Jpgs[i]); slot++;
          frames.Add(new object[] { Math.Round(T[i] - start, 1), dataOff, Jpgs[i].Length, Math.Round(Lat[i]) });
        }
        long endSlots = (long)Math.Round(dur * F);
        while (slot < endSlots - 1 && slot >= 0) { chunk(null); slot++; }
        at(movi, (uint)(f.Position - movi - 4));
        fcc("idx1"); w.Write((uint)(idx.Count * 4)); foreach (uint u in idx) w.Write(u);
        at(4, (uint)(f.Position - 8)); at(totPos, (uint)(slot + 1)); at(lenPos, (uint)(slot + 1));
      }
      var o = new Dictionary<string, object>();
      o["w"] = W; o["h"] = H; o["dur"] = Math.Round(dur * 1000); o["frames"] = frames;   // [t ms, byte offset in the avi, length, latency]
      return o;
    }
  }
}

// ============================================================================
//  WiFi video reader: the camera's :81/stream, exactly as a phone would get it
// ============================================================================
public class XWifi {
  readonly XHub hub; readonly string url; Thread th; volatile bool run; WebResponse resp;
  public volatile string Status = "";
  public long Frames;
  public XWifi(XHub h, string u) { hub = h; url = u; }
  public void Start() { run = true; th = new Thread(Loop); th.IsBackground = true; th.Start(); }
  public void Stop() { run = false; try { if (resp != null) resp.Close(); } catch { } }

  public static bool Reachable(string u, int ms) {
    try {
      var uri = new Uri(u);
      using (var c = new TcpClient()) { var ar = c.BeginConnect(uri.Host, uri.Port, null, null); bool ok = ar.AsyncWaitHandle.WaitOne(ms) && c.Connected; return ok; }
    } catch { return false; }
  }
  // this PC's WiFi signal (netsh), for the round notes
  public static string PcSignal() {
    try {
      var psi = new ProcessStartInfo("netsh", "wlan show interfaces"); psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
      using (var p = Process.Start(psi)) {
        string o = p.StandardOutput.ReadToEnd(); p.WaitForExit(3000);
        var ss = Regex.Match(o, @"^\s*SSID\s*:\s*(.+)$", RegexOptions.Multiline); var sg = Regex.Match(o, @"^\s*Signal\s*:\s*(\d+)%", RegexOptions.Multiline);
        return (ss.Success ? ss.Groups[1].Value.Trim() : "?") + " " + (sg.Success ? sg.Groups[1].Value + "%" : "");
      }
    } catch { return ""; }
  }

  static string ReadLine(Stream s) {
    var sb = new StringBuilder(); int b;
    while ((b = s.ReadByte()) >= 0) { if (b == '\n') break; if (b != '\r') sb.Append((char)b); if (sb.Length > 400) break; }
    if (b < 0 && sb.Length == 0) throw new IOException("stream ended");
    return sb.ToString();
  }

  void Loop() {
    while (run) {
      try {
        var rq = (HttpWebRequest)WebRequest.Create(url);
        rq.Timeout = 4000; rq.ReadWriteTimeout = 3000; rq.KeepAlive = false; rq.Proxy = null;
        resp = rq.GetResponse();
        using (var bs = new BufferedStream(resp.GetResponseStream(), 65536)) {
          Status = "connected";
          int len = -1; double ts = -1;
          while (run) {
            string line = ReadLine(bs);
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) int.TryParse(line.Substring(15).Trim(), out len);
            else if (line.StartsWith("X-Timestamp:", StringComparison.OrdinalIgnoreCase)) double.TryParse(line.Substring(12).Trim(), out ts);
            else if (line.Length == 0 && len > 0) {
              var jpg = new byte[len]; int got = 0;
              while (got < len) { int r = bs.Read(jpg, got, len - got); if (r <= 0) throw new IOException("stream ended"); got += r; }
              double now = XHub.NowMs, off = hub.ClockOffset;
              double lat = (ts >= 0 && !double.IsNaN(off)) ? now - (ts - off) : -1;
              if (jpg.Length > 2 && jpg[0] == 0xFF && jpg[1] == 0xD8) { Frames++; hub.OnFrame(jpg, lat); }
              len = -1; ts = -1;
            }
          }
        }
      } catch (Exception e) {
        if (!run) break;
        Status = "reconnecting (" + e.Message + ")";
        Thread.Sleep(400);
      } finally { try { if (resp != null) resp.Close(); } catch { } }
    }
    Status = "";
  }
}
