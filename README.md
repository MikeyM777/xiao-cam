# XIAO CAM Studio

Seeed XIAO ESP32S3 Sense camera: one double-click file that installs the tools, flashes the camera
and opens a studio in the browser (video over the USB cable).

- **Get it:** download `SETUP-XIAO-CAM.bat` and `XIAO-CAM-STUDIO.bat`, run the setup (puts everything in `C:\XiaoCam`).
- **First time:** choose 1 (install + flash). After that: 2. Demo without a camera: 3.
- **Updates:** Studio -> Board tab -> Check for updates / Update now.

Studio: all camera settings, WiFi control, recording (AVI + sound), timelapse, snapshots, focus helper,
crazy mode (nonstop settings sweep with scored photos) and Compare.

Source: `src/` (firmware, C#, web UI), build the bat with `scripts/assemble.ps1`, test with `tests/test-crazy.ps1`.
