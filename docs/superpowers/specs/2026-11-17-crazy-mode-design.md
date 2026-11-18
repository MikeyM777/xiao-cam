# Crazy mode + Compare - design (2026-11-17)

Goal: find the best camera settings for 4 needs (daylight, night, indoor, fast video) by shooting
the same scene with many settings, nonstop, and comparing the photos in the Studio.
Approved by the owner in chat ("go").

## Engine (PC side, no firmware change)
- New C# class `XCrazy` (src/crazy.cs), driven by `XHub`. Runs on its own thread.
- Per shot: send the `set` commands that differ from the current state -> wait to settle
  (1.2 s; +1.5 s after a resolution / clock change) -> measure USB fps for 1.5 s -> save the newest
  frame whose size matches the expected resolution -> compute scores -> write files.
- Before a run: remember the camera's current settings (the "base"). On Stop / error / quit:
  restore the base. All sweep variants are applied on top of the base.
- Unplugged mid-run: pause until frames come back, then redo the current shot.
- While running, the setting controls in the Studio are locked (banner); live view keeps working.

## Round = light probe + sweep + mix (repeats nonstop until Stop)
1. Light probe: manual exposure 300, manual gain 0 -> mean brightness = ambient light ->
   round label `day` (>0.35), `dim` (0.10-0.35), `night` (<0.10).
2. Sweep: one group at a time, every value (~110 shots):
   framesize (QVGA..max), quality 4/6/8/10/12/15/20/30/45/63, brightness/contrast/saturation/sharpness
   -2..2, denoise 0/2/4/6/8, ae_level -2..2, manual exposure (aec 0 + 25/50/100/200/400/700/1000/1200),
   aec2 0/1, gainceiling 0..6, manual gain (agc 0 + 0/3/6/10/15/20/30), white balance (awb_gain 1 +
   wb_mode 0..4, awb 0), lenc/raw_gma/bpc/wpc/dcw 0/1, xclk 10/16/20/24.
3. Mix: for each of the 4 profiles, the 4 groups with the biggest score spread, top 2 values each ->
   16 combos per profile, de-duplicated (<= 64 shots).

## Scores (raw, per photo, computed in C# on a 640 px wide copy)
sharpness (laplacian variance, center third), noise (high-pass std in the flattest 20% of 16x16 blocks),
brightness mean, clipped % (<5 or >250), color cast (|R-G|+|B-G|), file KB, fps, width/height.
Profiles (UI normalizes each metric min-max over the photos being compared):
- Daylight: .35 sharp + .25 exposure + .15 no-cast + .15 no-noise + .10 no-clip
- Night:    .35 exposure + .30 no-noise + .20 sharp + .15 no-clip
- Indoor:   .30 exposure + .25 no-cast + .25 sharp + .20 no-noise
- Fast:     .50 fps + .20 sharp + .20 exposure + .10 no-noise
exposure = 1 - |mean - 0.45| / 0.45. noise is used relative to brightness (noise / max(mean, 0.05)).
Every profile score is multiplied by 0.4 + 0.6 * min(1, exposure / 0.6), so badly exposed photos never win.
Firmware gets `set autosave 0|1` so the sweep does not wear the board flash (crazy mode turns it off while running).

## Files
```
<output>\2026-11-17_1430_R001_day\
   1-sweep\<group>\<value>.jpg (+ thumbs\...jpg 320 px)
   2-mix\<profile>_<nn>.jpg
   round.json   - rewritten after every shot: round info + every shot (path, group, label,
                  full settings, applied-check, scores, time)
<output>\stars.json  - starred shot paths
```
Output folder: chosen with a Windows folder picker (or typed), remembered in
%LOCALAPPDATA%\XiaoCam\studio.json. Default `<studio folder>\crazy`.

## Web API (all files served only from inside the output folder)
/api/crazy/state, /api/crazy/start, /api/crazy/stop, /api/crazy/folder?pick=1|path=,
/api/crazy/rounds, /api/crazy/round?id=, /crazy/file?p=<relative path>, /api/crazy/star?p=&on=

## UI
- Sidebar tab "Crazy": folder, Start/Stop, round / phase / shot n of N / current setting / ETA,
  last shot + its scores.
- Header switch "Live | Compare". Compare view replaces the viewer:
  - Best-per-need row: top photo per profile per light level.
  - Filters: round, light level, group, starred; sort: profile score or any metric.
  - Thumbnail grid (lazy). Click = select (max 4).
  - Compare: 2-4 photos side by side, synced zoom/pan, settings under each with differences
    highlighted; with 2 photos an A/B wipe slider. Star, "Apply to camera", "Save as profile".

## Tests
Demo source must honor all settings it can (resolution, quality, brightness, manual exposure/gain
darken/brighten + noise) so a demo crazy round produces different photos and scores. Verify: demo round
completes, folders/json written, compare page loads it, apply-to-camera sends the settings,
path traversal on /crazy/file is refused, base settings restored after Stop.

## Update 2026-11-18: clips + WiFi crazy mode (owner request)
- Every test is a 5-second clip saved on the PC (AVI MJPEG at nominal 30 fps, empty chunks keep the real
  arrival timing so freezes stay frozen) + `<name>.json` index (frame time, byte offset, length, delay) + thumb.
- Mode "WiFi": PC joins the camera hotspot, USB stays plugged in for control; USB video off during the round;
  the Studio reads `http://<ap_ip>:81/stream` like a phone. Firmware 2.2 adds `X-Timestamp` (capture time)
  per stream part and a `ping` command (XPNG reply) for clock sync -> delay = arrival - capture.
- WiFi plan: resolution x quality (7x5), fps limit 5..25, WiFi power 2..21 dBm, clock; mix per WiFi profile.
- Metrics per clip: fps, KB/s, freezes (gap > max(3x median, 250 ms)), longest gap, jitter, delay median/90%.
- WiFi profiles: smooth (.6 fps .25 no-freeze .15 no-long-gap), low delay (.6 delay .2 delay90 .2 fps),
  no freezes (.45 freezes .35 longest gap .2 jitter), best picture (sharp/exposure/noise x min(1,fps/10) x 0.7 if any freeze).
- Compare: USB/WiFi filter, synced clip player (play/pause/seek/frame step/speed) in side-by-side and A/B wipe.
- Disk guard: stops when less than 5 GB free.