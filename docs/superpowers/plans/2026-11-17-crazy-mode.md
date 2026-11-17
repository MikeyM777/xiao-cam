# Crazy mode + Compare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nonstop automatic settings sweep that saves organized, scored photos, plus a Compare view to pick the best settings per need.

**Architecture:** C# `XCrazy` engine inside the existing Studio process drives the camera through the existing `set` protocol and writes `round.json` + JPGs; the existing tiny web server gets `/api/crazy/*` routes; the UI gets a "Crazy" sidebar tab and a "Compare" view. Spec: `docs/superpowers/specs/2026-11-17-crazy-mode-design.md`.

**Tech Stack:** C# 5 (Windows PowerShell Add-Type, .NET Framework 4, System.Drawing, System.Web.Extensions JavaScriptSerializer), vanilla JS/HTML, PowerShell assemble script.

---

## Files
- Create `src/crazy.cs` - XCrazy engine (plan, shots, scores, round.json, library, stars, settings store).
- Modify `src/studio.cs` - XHub: expose `Frames since t` helpers, board value parse, crazy instance; XWeb: crazy routes + safe file serving; XDemo: exposure/gain/noise simulation.
- Create `src/crazy.html` - Crazy tab + Compare view markup/CSS/JS, injected into ui.html at `<!--CRAZY-->`.
- Modify `src/ui.html` - Live/Compare switch, 7th tab, lock banner, include marker.
- Modify `scripts/assemble.ps1` - CS = studio.cs + crazy.cs; HTML include.
- Modify `src/main.ps1` - reference System.Web.Extensions, pass default crazy dir.
- Create `tests/test-crazy.ps1` - headless demo test: short round, json/files check, traversal refused, base restored.

## Tasks
### Task 1: Scores
- [ ] `XScore.Compute(byte[] jpg)` -> sharp, noise, mean, clip, cast, w, h (640 px copy, LockBits).
- [ ] Test: dark vs bright vs blurred synthetic JPEGs give ordered scores. Commit.

### Task 2: Plan builder
- [ ] `XCrazy.SweepPlan(int maxSize)` -> list of Shot{group,label,set dict} per spec values.
- [ ] `XCrazy.MixPlan(shots)` -> top-4 groups by spread x top-2 values per profile, dedup.
- [ ] Test: sweep count ~110 for maxSize 19; mix <= 64 and unique. Commit.

### Task 3: Engine run loop
- [ ] Start/Stop, base snapshot (from board JSON), apply diff, settle, fps measure, size match, save jpg+thumb, round.json rewrite, light probe, restore base, pause on disconnect.
- [ ] Test (demo): 1 round with `QuickPlan` (env XCAM_CRAZY_QUICK=1, 6 shots + mix) finishes; files exist; base restored. Commit.

### Task 4: Web routes + folder store
- [ ] /api/crazy/state|start|stop|folder|rounds|round|star, /crazy/file (path must stay inside output dir), STA folder picker.
- [ ] Test: `/crazy/file?p=..\..\x` -> 403. Commit.

### Task 5: Demo realism
- [ ] Demo honors aec/aec_value, agc/agc_gain, ae_level, contrast/saturation, effect gray, noise with gain, xclk/quality affecting fps.
- [ ] Test: manual exposure 25 vs 1200 mean brightness differ. Commit.

### Task 6: UI Crazy tab + Compare view
- [ ] Crazy tab (folder, start/stop, progress, last shot), lock banner, Live/Compare switch.
- [ ] Compare: best-per-need, filters, sort, grid, select up to 4, synced zoom, A/B wipe, settings diff, star, apply, save profile.
- [ ] Verify in browser (Playwright) on a demo round; no console errors. Commit.

### Task 7: Ship
- [ ] Assemble bat, firmware build still OK, send via Telegram.
