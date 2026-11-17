// ============================================================================
//  Crazy mode: nonstop settings sweep -> organized, scored photos
// ============================================================================
public class XStopEx : Exception { }

public class XShot {
  public string Group, Label, Phase, Mix;
  public Dictionary<string, int> Set = new Dictionary<string, int>();
  public List<string> From = new List<string>();
  public XShot(string phase, string group, string label) { Phase = phase; Group = group; Label = label; }
  public XShot S(string k, int v) { Set[k] = v; return this; }
}

public class XScores {
  public double Sharp, Noise, Mean, Clip, Cast, Kb, Fps; public int W, H;
  public Dictionary<string, object> ToDict() {
    var d = new Dictionary<string, object>();
    d["sharp"] = Math.Round(Sharp, 2); d["noise"] = Math.Round(Noise, 3); d["mean"] = Math.Round(Mean, 4);
    d["clip"] = Math.Round(Clip, 4); d["cast"] = Math.Round(Cast, 4); d["kb"] = Math.Round(Kb, 1);
    d["fps"] = Math.Round(Fps, 1); d["w"] = W; d["h"] = H;
    return d;
  }
}

public static class XScore {
  // decodes the JPEG once: scores on a 640 px copy, plus a 320 px thumbnail
  public static XScores Compute(byte[] jpg, out byte[] thumb) {
    var s = new XScores(); s.Kb = jpg.Length / 1024.0;
    using (var ms = new MemoryStream(jpg))
    using (var src = Image.FromStream(ms)) {
      s.W = src.Width; s.H = src.Height;
      int W = Math.Min(640, src.Width), H = Math.Max(1, (int)Math.Round((double)src.Height * W / src.Width));
      using (var bmp = new Bitmap(W, H, PixelFormat.Format24bppRgb)) {
        using (var g = Graphics.FromImage(bmp)) { g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.DrawImage(src, 0, 0, W, H); }
        Analyse(bmp, s);
        int tw = Math.Min(320, W), th = Math.Max(1, H * tw / W);
        using (var tb = new Bitmap(tw, th, PixelFormat.Format24bppRgb)) {
          using (var g = Graphics.FromImage(tb)) { g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.DrawImage(bmp, 0, 0, tw, th); }
          using (var to = new MemoryStream()) { tb.Save(to, ImageFormat.Jpeg); thumb = to.ToArray(); }
        }
      }
    }
    return s;
  }

  static void Analyse(Bitmap bmp, XScores s) {
    int W = bmp.Width, H = bmp.Height;
    var data = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
    byte[] px = new byte[data.Stride * H];
    Marshal.Copy(data.Scan0, px, 0, px.Length);
    bmp.UnlockBits(data);
    float[] gy = new float[W * H];
    double sr = 0, sg = 0, sb = 0, sum = 0; long clip = 0;
    for (int y = 0; y < H; y++) {
      int row = y * data.Stride;
      for (int x = 0; x < W; x++) {
        int i = row + x * 3; byte b = px[i], g = px[i + 1], r = px[i + 2];
        float v = (r * 77 + g * 150 + b * 29) / 256f;
        gy[y * W + x] = v; sum += v; sr += r; sg += g; sb += b;
        if (v < 5 || v > 250) clip++;
      }
    }
    double n = (double)W * H;
    s.Mean = sum / n / 255.0; s.Clip = clip / n;
    s.Cast = (Math.Abs(sr - sg) + Math.Abs(sb - sg)) / n / 255.0;
    // sharpness: variance of the laplacian in the middle third
    double l1 = 0, l2 = 0; long c = 0;
    for (int y = Math.Max(1, H / 3); y < Math.Min(H - 1, 2 * H / 3); y++)
      for (int x = Math.Max(1, W / 3); x < Math.Min(W - 1, 2 * W / 3); x++) {
        int i = y * W + x; double L = 4 * gy[i] - gy[i - 1] - gy[i + 1] - gy[i - W] - gy[i + W];
        l1 += L; l2 += L * L; c++;
      }
    s.Sharp = c > 0 ? Math.Sqrt(Math.Max(0, l2 / c - (l1 / c) * (l1 / c))) : 0;
    // noise: mean |laplacian| in the flattest 20% of 16x16 blocks
    var blocks = new List<double>();
    for (int by = 1; by + 16 < H; by += 16)
      for (int bx = 1; bx + 16 < W; bx += 16) {
        double a = 0;
        for (int y = by; y < by + 16; y++)
          for (int x = bx; x < bx + 16; x++) { int i = y * W + x; a += Math.Abs(4 * gy[i] - gy[i - 1] - gy[i + 1] - gy[i - W] - gy[i + W]); }
        blocks.Add(a / 256.0);
      }
    blocks.Sort();
    int k = Math.Max(1, blocks.Count / 5); double ns = 0;
    for (int i = 0; i < k && i < blocks.Count; i++) ns += blocks[i];
    s.Noise = blocks.Count > 0 ? ns / k : 0;
  }

  // profile score over a set of shots (each metric normalized min-max inside the set)
  public static readonly string[] Profiles = { "daylight", "night", "indoor", "fast" };
  public static double[] Rank(List<XScores> list, string profile) {
    int n = list.Count; var r = new double[n];
    if (n == 0) return r;
    Func<Func<XScores, double>, double[]> norm = f => {
      double mn = double.MaxValue, mx = double.MinValue;
      foreach (var x in list) { double v = f(x); mn = Math.Min(mn, v); mx = Math.Max(mx, v); }
      var o = new double[n];
      for (int i = 0; i < n; i++) o[i] = mx - mn < 1e-9 ? 0.5 : (f(list[i]) - mn) / (mx - mn);
      return o;
    };
    double[] sh = norm(x => x.Sharp), no = norm(x => x.Noise / Math.Max(x.Mean, 0.05)), cl = norm(x => x.Clip), ca = norm(x => x.Cast), fp = norm(x => x.Fps);
    for (int i = 0; i < n; i++) {
      double ex = Math.Max(0, 1 - Math.Abs(list[i].Mean - 0.45) / 0.45);
      switch (profile) {
        case "daylight": r[i] = .35 * sh[i] + .25 * ex + .15 * (1 - ca[i]) + .15 * (1 - no[i]) + .10 * (1 - cl[i]); break;
        case "night":    r[i] = .35 * ex + .30 * (1 - no[i]) + .20 * sh[i] + .15 * (1 - cl[i]); break;
        case "indoor":   r[i] = .30 * ex + .25 * (1 - ca[i]) + .25 * sh[i] + .20 * (1 - no[i]); break;
        default:         r[i] = .50 * fp[i] + .20 * sh[i] + .20 * ex + .10 * (1 - no[i]); break;
      }
      r[i] *= 0.4 + 0.6 * Math.Min(1, ex / 0.6);   // too dark / too bright is never "best"
    }
    return r;
  }
}

public class XCrazy {
  readonly XHub hub;
  public string OutDir = "";
  Thread th; volatile bool running;
  public volatile string Phase = "idle", Current = "", Err = "", Light = "", RoundName = "", LastShot = "";
  public int Round, ShotN, ShotTotal, RoundsDone;
  public bool Quick;                 // tests: tiny plan, short waits
  public int MaxRounds;              // 0 = nonstop
  public DateTime ShotStarted = DateTime.Now; public double AvgShotSec = 3.2;
  public string LastScoresJson = "null";
  Dictionary<string, int> baseSet, cur = new Dictionary<string, int>();
  List<int[]> sizes = new List<int[]>(); int maxSize;
  readonly object fileLock = new object();
  public static readonly string[] Keys = { "framesize", "quality", "xclk", "fps_limit", "brightness", "contrast", "saturation", "sharpness",
    "denoise", "effect", "aec", "aec_value", "aec2", "ae_level", "agc", "agc_gain", "gainceiling", "awb", "awb_gain", "wb_mode",
    "bpc", "wpc", "raw_gma", "lenc", "hmirror", "vflip", "dcw", "colorbar" };

  public XCrazy(XHub h) { hub = h; }
  public bool Running { get { return running; } }

  // ---------- settings store ----------
  static string StorePath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XiaoCam\\studio.json"); } }
  public void LoadDir(string def) {
    OutDir = def;
    try {
      if (File.Exists(StorePath)) {
        var d = Js().DeserializeObject(File.ReadAllText(StorePath)) as Dictionary<string, object>;
        if (d != null && d.ContainsKey("crazyDir") && Convert.ToString(d["crazyDir"]).Length > 0) OutDir = Convert.ToString(d["crazyDir"]);
      }
    } catch { }
  }
  public string SetDir(string dir) {
    if (running) throw new Exception("stop crazy mode first");
    if (string.IsNullOrEmpty(dir) || !Path.IsPathRooted(dir)) throw new Exception("use a full folder path, like C:\\XiaoCam\\crazy");
    dir = Path.GetFullPath(dir);
    Directory.CreateDirectory(dir);
    OutDir = dir;
    try {
      Directory.CreateDirectory(Path.GetDirectoryName(StorePath));
      var d = new Dictionary<string, object>(); d["crazyDir"] = dir;
      File.WriteAllText(StorePath, Js().Serialize(d));
    } catch { }
    return dir;
  }
  public static string PickFolder(string start) {
    string res = null;
    var t = new Thread(delegate() {
      try {
        using (var owner = new System.Windows.Forms.Form()) {
          owner.TopMost = true; owner.ShowInTaskbar = false; owner.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;
          owner.Width = 1; owner.Height = 1; owner.Opacity = 0; owner.Show(); owner.Activate();
          using (var d = new System.Windows.Forms.FolderBrowserDialog()) {
            d.Description = "Choose where crazy mode saves the photos";
            d.ShowNewFolderButton = true;
            if (!string.IsNullOrEmpty(start) && Directory.Exists(start)) d.SelectedPath = start;
            if (d.ShowDialog(owner) == System.Windows.Forms.DialogResult.OK) res = d.SelectedPath;
          }
        }
      } catch { }
    });
    t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join();
    return res;
  }
  public static System.Web.Script.Serialization.JavaScriptSerializer Js() {
    var j = new System.Web.Script.Serialization.JavaScriptSerializer(); j.MaxJsonLength = int.MaxValue; return j;
  }

  // ---------- plans ----------
  static string Sg(int v) { return v > 0 ? "+" + v : v.ToString(); }
  public static List<XShot> SweepPlan(int maxSize, List<int[]> sizes) {
    var p = new List<XShot>();
    int[] res = { 6, 8, 9, 10, 11, 12, 13, 14, 15, 16, 19 };
    foreach (int r in res) if (r <= maxSize && r < sizes.Count) p.Add(new XShot("sweep", "resolution", sizes[r][0] + "x" + sizes[r][1]).S("framesize", r));
    foreach (int q in new[] { 4, 6, 8, 10, 12, 15, 20, 30, 45, 63 }) p.Add(new XShot("sweep", "quality", "q" + q.ToString("00")).S("quality", q));
    foreach (string k in new[] { "brightness", "contrast", "saturation", "sharpness" })
      for (int v = -2; v <= 2; v++) p.Add(new XShot("sweep", k, Sg(v)).S(k, v));
    foreach (int v in new[] { 0, 2, 4, 6, 8 }) p.Add(new XShot("sweep", "denoise", v.ToString()).S("denoise", v));
    for (int v = -2; v <= 2; v++) p.Add(new XShot("sweep", "exposure-comp", "ev" + Sg(v)).S("aec", 1).S("ae_level", v));
    foreach (int v in new[] { 25, 50, 100, 200, 400, 700, 1000, 1200 }) p.Add(new XShot("sweep", "manual-exposure", "exp" + v.ToString("0000")).S("aec", 0).S("aec_value", v));
    for (int v = 0; v <= 1; v++) p.Add(new XShot("sweep", "exposure-dsp", v == 1 ? "on" : "off").S("aec", 1).S("aec2", v));
    string[] gc = { "2x", "4x", "8x", "16x", "32x", "64x", "128x" };
    for (int v = 0; v <= 6; v++) p.Add(new XShot("sweep", "gain-ceiling", (v + 1) + "-" + gc[v]).S("agc", 1).S("gainceiling", v));
    foreach (int v in new[] { 0, 3, 6, 10, 15, 20, 30 }) p.Add(new XShot("sweep", "manual-gain", "gain" + (v + 1).ToString("00") + "x").S("agc", 0).S("agc_gain", v));
    string[] wb = { "auto", "sunny", "cloudy", "office", "home" };
    for (int v = 0; v <= 4; v++) p.Add(new XShot("sweep", "white-balance", v + "-" + wb[v]).S("awb", 1).S("awb_gain", 1).S("wb_mode", v));
    p.Add(new XShot("sweep", "white-balance", "5-awb-off").S("awb", 0));
    string[][] tg = { new[] { "lens-correction", "lenc" }, new[] { "gamma", "raw_gma" }, new[] { "black-pixel-fix", "bpc" }, new[] { "white-pixel-fix", "wpc" }, new[] { "downscale-dcw", "dcw" } };
    foreach (var t in tg) for (int v = 0; v <= 1; v++) p.Add(new XShot("sweep", t[0], v == 1 ? "on" : "off").S(t[1], v));
    foreach (int v in new[] { 10, 16, 20, 24 }) p.Add(new XShot("sweep", "clock", v + "MHz").S("xclk", v));
    return p;
  }
  public static List<XShot> QuickPlan(int maxSize, List<int[]> sizes) {
    var p = new List<XShot>();
    p.Add(new XShot("sweep", "resolution", sizes[10][0] + "x" + sizes[10][1]).S("framesize", 10));
    p.Add(new XShot("sweep", "resolution", sizes[13][0] + "x" + sizes[13][1]).S("framesize", 13));
    p.Add(new XShot("sweep", "quality", "q06").S("quality", 6));
    p.Add(new XShot("sweep", "quality", "q30").S("quality", 30));
    p.Add(new XShot("sweep", "manual-exposure", "exp0050").S("aec", 0).S("aec_value", 50));
    p.Add(new XShot("sweep", "manual-exposure", "exp1000").S("aec", 0).S("aec_value", 1000));
    p.Add(new XShot("sweep", "brightness", "-2").S("brightness", -2));
    p.Add(new XShot("sweep", "brightness", "+2").S("brightness", 2));
    return p;
  }
  // winners of the sweep, mixed: per profile, top 4 groups by score spread x top 2 values
  public static List<XShot> MixPlan(List<XShot> shots, List<XScores> scores, int groupsPer, int valuesPer) {
    var outp = new List<XShot>(); var seen = new HashSet<string>();
    foreach (string prof in XScore.Profiles) {
      double[] r = XScore.Rank(scores, prof);
      var byGroup = new Dictionary<string, List<int>>();
      for (int i = 0; i < shots.Count; i++) {
        if (!byGroup.ContainsKey(shots[i].Group)) byGroup[shots[i].Group] = new List<int>();
        byGroup[shots[i].Group].Add(i);
      }
      var spread = new List<KeyValuePair<string, double>>();
      foreach (var kv in byGroup) {
        if (kv.Value.Count < 2) continue;
        double mn = 1e9, mx = -1e9; foreach (int i in kv.Value) { mn = Math.Min(mn, r[i]); mx = Math.Max(mx, r[i]); }
        spread.Add(new KeyValuePair<string, double>(kv.Key, mx - mn));
      }
      spread.Sort((a, b) => b.Value.CompareTo(a.Value));
      var choices = new List<List<XShot>>();
      for (int g = 0; g < Math.Min(groupsPer, spread.Count); g++) {
        var idx = new List<int>(byGroup[spread[g].Key]);
        idx.Sort((a, b) => r[b].CompareTo(r[a]));
        var top = new List<XShot>();
        for (int j = 0; j < Math.Min(valuesPer, idx.Count); j++) top.Add(shots[idx[j]]);
        choices.Add(top);
      }
      int combos = 1; foreach (var c in choices) combos *= c.Count;
      int nn = 0;
      for (int m = 0; m < combos; m++) {
        var s = new XShot("mix", "mix-" + prof, ""); s.Mix = prof; int rest = m;
        foreach (var c in choices) {
          XShot pick = c[rest % c.Count]; rest /= c.Count;
          foreach (var kv in pick.Set) s.Set[kv.Key] = kv.Value;
          s.From.Add(pick.Group + "=" + pick.Label);
        }
        var keys = new List<string>(s.Set.Keys); keys.Sort();
        var sig = new StringBuilder(); foreach (string k in keys) sig.Append(k).Append('=').Append(s.Set[k]).Append(';');
        if (!seen.Add(sig.ToString())) continue;
        nn++; s.Label = prof + "_" + nn.ToString("00");
        outp.Add(s);
      }
    }
    return outp;
  }

  // ---------- run ----------
  public void Start() {
    if (running) return;
    if (string.IsNullOrEmpty(OutDir)) throw new Exception("choose an output folder first");
    if (ReadBoard() == null) throw new Exception("camera not connected (or old firmware - flash with option 1)");
    if (!hub.IsLive) throw new Exception("no picture coming from the camera");
    Directory.CreateDirectory(OutDir);
    Err = ""; RoundsDone = 0; running = true; Phase = "starting";
    th = new Thread(Loop); th.IsBackground = true; th.Start();
  }
  public void Stop() { running = false; }
  public void StopAndWait(int ms) { running = false; Thread t = th; if (t != null) t.Join(ms); }

  Dictionary<string, int> ReadBoard() {
    string j = hub.BoardJson;
    if (string.IsNullOrEmpty(j) || j.IndexOf("\"framesize\"", StringComparison.Ordinal) < 0) return null;
    try {
      var d = Js().DeserializeObject(j) as Dictionary<string, object>;
      if (d == null) return null;
      var o = new Dictionary<string, int>();
      foreach (string k in Keys) if (d.ContainsKey(k)) o[k] = Convert.ToInt32(d[k]);
      if (d.ContainsKey("max_size")) maxSize = Convert.ToInt32(d["max_size"]);
      if (d.ContainsKey("sizes")) {
        sizes = new List<int[]>();
        foreach (object z in (object[])d["sizes"]) { var a = (object[])z; sizes.Add(new[] { Convert.ToInt32(a[0]), Convert.ToInt32(a[1]) }); }
      }
      return o;
    } catch { return null; }
  }

  void Wait(int ms) {
    var until = DateTime.Now.AddMilliseconds(ms);
    while (DateTime.Now < until) { if (!running) throw new XStopEx(); Thread.Sleep(50); }
  }

  void Loop() {
    try {
      baseSet = ReadBoard();
      cur = new Dictionary<string, int>(baseSet);
      hub.Cmd("set autosave 0");      // do not wear the board's flash with thousands of changes
      while (running) {
        RunRound();
        RoundsDone++;
        if (MaxRounds > 0 && RoundsDone >= MaxRounds) break;
      }
    } catch (XStopEx) {
    } catch (Exception e) { Err = e.Message; hub.OnMsg("crazy mode stopped: " + e.Message); }
    finally {
      Phase = "restoring your settings";
      try { Apply(new Dictionary<string, int>(), false); } catch { }
      running = false;
      hub.Cmd("set autosave 1");
      Phase = "idle"; Current = "";
    }
  }

  // send only what differs from what the camera has now; base + overrides
  bool Apply(Dictionary<string, int> over, bool forceAll) {
    var full = new Dictionary<string, int>(baseSet);
    foreach (var kv in over) full[kv.Key] = kv.Value;
    bool resChange = false;
    foreach (string k in Keys) {
      if (!full.ContainsKey(k)) continue;
      int v = full[k], c;
      if (!forceAll && cur.TryGetValue(k, out c) && c == v) continue;
      if (k == "framesize" || k == "xclk") resChange = true;
      hub.Cmd("set " + k + " " + v);
      cur[k] = v;
    }
    return resChange;
  }

  int[] Expect(Dictionary<string, int> over) {
    int fs = over.ContainsKey("framesize") ? over["framesize"] : baseSet["framesize"];
    return fs >= 0 && fs < sizes.Count ? sizes[fs] : null;
  }

  // one shot: apply, settle, measure fps, grab a matching frame
  byte[] Take(Dictionary<string, int> over, out double fps) {
    for (int attempt = 0; ; attempt++) {
      while (!hub.IsLive) { Phase = "waiting for the camera (unplugged?)"; Wait(500); }
      Phase = "shooting";
      bool big = Apply(over, attempt > 0);
      Wait(Quick ? 400 : (1200 + (big ? 1500 : 0)));
      long f0 = hub.TotalFrames; var t0 = DateTime.Now;
      Wait(Quick ? 500 : 1500);
      fps = (hub.TotalFrames - f0) / (DateTime.Now - t0).TotalSeconds;
      int[] want = Expect(over);
      var deadline = DateTime.Now.AddSeconds(5);
      byte[] last = null;
      while (DateTime.Now < deadline) {
        DateTime at; int w, h;
        byte[] f = hub.LatestWithTime(out at, out w, out h);
        if (f != null && at > t0) {
          last = f;
          if (want == null || (w == want[0] && h == want[1])) return f;
        }
        Wait(60);
      }
      if (last != null) return last;          // camera ignored the size: keep what it sent
      if (attempt >= 2) throw new Exception("no pictures from the camera");
      cur.Clear();                           // after a reconnect, send everything again
    }
  }

  void RunRound() {
    ReadBoard();
    Round++; ShotN = 0;
    // 1. light probe
    Phase = "measuring the light"; Current = "light probe";
    var probe = new Dictionary<string, int>(); probe["aec"] = 0; probe["aec_value"] = 300; probe["agc"] = 0; probe["agc_gain"] = 0;
    double pf; byte[] pj = Take(probe, out pf);
    byte[] pth; XScores ps = XScore.Compute(pj, out pth);
    Light = ps.Mean > 0.35 ? "day" : ps.Mean > 0.10 ? "dim" : "night";
    int num = NextRoundNumber();
    RoundName = DateTime.Now.ToString("yyyy-MM-dd_HHmm") + "_R" + num.ToString("000") + "_" + Light;
    string rdir = Path.Combine(OutDir, RoundName);
    Directory.CreateDirectory(rdir);
    var round = new Dictionary<string, object>();
    round["round"] = num; round["name"] = RoundName; round["light"] = Light; round["lightMean"] = Math.Round(ps.Mean, 4);
    round["started"] = DateTime.Now.ToString("s"); round["base"] = baseSet; round["sizes"] = sizes; round["maxSize"] = maxSize;
    var shotList = new List<object>(); round["shots"] = shotList;
    File.WriteAllBytes(Path.Combine(rdir, "0-light-probe.jpg"), pj);

    List<XShot> plan = Quick ? QuickPlan(maxSize, sizes) : SweepPlan(maxSize, sizes);
    ShotTotal = plan.Count + (Quick ? 4 : 40);
    var done = new List<XShot>(); var sc = new List<XScores>();
    foreach (XShot s in plan) { XScores r = Shoot(s, rdir, round, shotList); if (r != null) { done.Add(s); sc.Add(r); } }
    List<XShot> mix = MixPlan(done, sc, Quick ? 2 : 4, 2);
    ShotTotal = ShotN + mix.Count;
    foreach (XShot s in mix) Shoot(s, rdir, round, shotList);
    round["finished"] = DateTime.Now.ToString("s");
    WriteRound(rdir, round);
  }

  int NextRoundNumber() {
    int mx = 0;
    foreach (string d in Directory.GetDirectories(OutDir)) {
      var m = Regex.Match(Path.GetFileName(d), "_R(\\d{3,})_");
      if (m.Success) mx = Math.Max(mx, int.Parse(m.Groups[1].Value));
    }
    return mx + 1;
  }

  static string Safe(string s) { return Regex.Replace(s, "[^A-Za-z0-9_+\\-.]", "_"); }

  XScores Shoot(XShot s, string rdir, Dictionary<string, object> round, List<object> shotList) {
    ShotN++; Current = s.Group + " = " + s.Label; ShotStarted = DateTime.Now;
    double fps; byte[] jpg = Take(s.Set, out fps);
    byte[] thumb; XScores r = XScore.Compute(jpg, out thumb); r.Fps = fps;
    string sub = s.Phase == "mix" ? "2-mix" : "1-sweep\\" + Safe(s.Group);
    string dir = Path.Combine(rdir, sub), tdir = Path.Combine(dir, "thumbs");
    Directory.CreateDirectory(tdir);
    string name = Safe(s.Label) + ".jpg";
    File.WriteAllBytes(Path.Combine(dir, name), jpg);
    File.WriteAllBytes(Path.Combine(tdir, name), thumb);
    // what the camera really took
    var now = ReadBoard() ?? new Dictionary<string, int>();
    var full = new Dictionary<string, int>(baseSet); foreach (var kv in s.Set) full[kv.Key] = kv.Value;
    var notApplied = new List<string>();
    foreach (var kv in s.Set) { int v; if (now.TryGetValue(kv.Key, out v) && v != kv.Value) notApplied.Add(kv.Key); }
    string rel = RoundName + "/" + sub.Replace('\\', '/') + "/" + name;
    var d = new Dictionary<string, object>();
    d["file"] = rel; d["thumb"] = RoundName + "/" + sub.Replace('\\', '/') + "/thumbs/" + name;
    d["phase"] = s.Phase; d["group"] = s.Group; d["label"] = s.Label; d["changed"] = s.Set; d["set"] = full;
    if (s.Mix != null) { d["mix"] = s.Mix; d["from"] = s.From; }
    d["notApplied"] = notApplied; d["scores"] = r.ToDict(); d["time"] = DateTime.Now.ToString("s");
    shotList.Add(d);
    WriteRound(rdir, round);
    LastShot = rel; LastScoresJson = Js().Serialize(r.ToDict());
    double took = (DateTime.Now - ShotStarted).TotalSeconds;
    AvgShotSec = AvgShotSec * 0.8 + took * 0.2;
    return r;
  }

  void WriteRound(string rdir, Dictionary<string, object> round) {
    lock (fileLock) {
      string p = Path.Combine(rdir, "round.json"), tmp = p + ".tmp";
      File.WriteAllText(tmp, Js().Serialize(round));
      if (File.Exists(p)) File.Delete(p);
      File.Move(tmp, p);
    }
  }

  // ---------- library for Compare ----------
  public string RoundsJson() {
    var list = new List<object>();
    if (Directory.Exists(OutDir)) {
      var dirs = Directory.GetDirectories(OutDir); Array.Sort(dirs);
      foreach (string d in dirs) {
        if (File.Exists(Path.Combine(d, "round.json"))) list.Add(Path.GetFileName(d));
      }
    }
    var o = new Dictionary<string, object>(); o["ok"] = true; o["dir"] = OutDir; o["rounds"] = list;
    return Js().Serialize(o);
  }
  public string RoundJson(string id) {
    if (!Regex.IsMatch(id ?? "", "^[A-Za-z0-9_\\-]+$")) return null;
    string p = Path.Combine(OutDir, id, "round.json");
    lock (fileLock) { return File.Exists(p) ? File.ReadAllText(p) : null; }
  }
  // only files inside the output folder
  public string SafeFile(string rel) {
    if (string.IsNullOrEmpty(rel) || string.IsNullOrEmpty(OutDir)) return null;
    string root = Path.GetFullPath(OutDir).TrimEnd('\\') + "\\";
    string full;
    try { full = Path.GetFullPath(Path.Combine(root, rel.Replace('/', '\\'))); } catch { return null; }
    if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return null;
    if (!full.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase)) return null;
    return File.Exists(full) ? full : null;
  }
  string StarsPath { get { return Path.Combine(OutDir, "stars.json"); } }
  public List<string> Stars() {
    try { if (File.Exists(StarsPath)) { var a = Js().DeserializeObject(File.ReadAllText(StarsPath)) as object[]; var l = new List<string>(); if (a != null) foreach (object x in a) l.Add(Convert.ToString(x)); return l; } } catch { }
    return new List<string>();
  }
  public void Star(string rel, bool on) {
    lock (fileLock) {
      var s = Stars(); s.Remove(rel); if (on) s.Add(rel);
      File.WriteAllText(StarsPath, Js().Serialize(s));
    }
  }

  public string StateJson() {
    var o = new Dictionary<string, object>();
    o["running"] = running; o["phase"] = Phase; o["current"] = Current; o["err"] = Err; o["dir"] = OutDir;
    o["round"] = RoundName; o["light"] = Light; o["shot"] = ShotN; o["total"] = ShotTotal; o["roundsDone"] = RoundsDone;
    o["eta"] = running ? Math.Round(Math.Max(0, ShotTotal - ShotN) * AvgShotSec) : 0;
    o["last"] = LastShot;
    return Js().Serialize(o).TrimEnd('}') + ",\"scores\":" + LastScoresJson + "}";
  }
}
