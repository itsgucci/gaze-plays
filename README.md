## pwyl — Play When You Look

A tiny macOS menu bar app that automatically pauses and resumes playback when you look away from the screen.

- **When you look at the screen**: it sends Play/Resume
- **When you look away**: it sends Pause

By default it uses the system media Play/Pause key, so it works with YouTube in most browsers and many media players.

### How it works
- Uses the built‑in camera via `AVCaptureSession` and Apple Vision (`VNDetectFaceRectanglesRequest`/`VNDetectFaceLandmarksRequest`) to detect your face and estimate head pose (pitch/yaw/roll).
- Applies lightweight smoothing and hysteresis so brief glances/blinks don’t constantly toggle playback.
- If your head is facing the screen and not pitched downward beyond a threshold, it considers you "looking" and sends a media Play/Resume. Otherwise it considers you "away" and sends Pause.
- Playback control is sent either by:
  - **System media key (default)**: posts the Play/Pause HID key event at the system level.
  - **Safari JavaScript mode (optional)**: executes `video.play()`/`video.pause()` in a YouTube tab via AppleScript. This requires enabling a developer setting in Safari and granting Automation permissions. The code currently defaults to system media key.

### Permissions
- **Camera**: required to process video frames for face/head pose.
- **Accessibility**: required to send the system media Play/Pause key (System Settings → Privacy & Security → Accessibility → enable `pwyl`).
- **Automation (optional)**: only if using Safari JavaScript mode to control a YouTube tab (System Settings → Privacy & Security → Automation → allow `pwyl` to control Safari).

### Build & run
1. Open `pwyl.xcodeproj` in Xcode (macOS app, Swift/SwiftUI).
2. Select a signing team if needed.
3. Build and run. On first launch, macOS will prompt for Camera and Accessibility permissions.

Minimums: recent macOS with Apple Vision support (macOS 12+ recommended) and Xcode that supports SwiftUI.

### Usage
- The app runs as a background **menu bar** app (no standard window). You’ll see an eye icon:
  - `eye.slash` = idle
  - `eye` = looking (will Play/Resume)
  - `eye.trianglebadge.exclamationmark` = away (will Pause)
- Click the menu bar icon for options:
  - **Enabled**: toggle the behavior on/off
  - **Show Debug**: open a live diagnostics window
  - **Quit**: exit the app
- Open YouTube (or any media app that listens to the system Play/Pause key). When you look at the screen, playback resumes; when you look away, it pauses.

### Example monitor setup
- A 32" external monitor is mounted above a MacBook Air on the desk directly below it.
- The MacBook’s built‑in camera (at the top of the laptop display) sits between the two screens.
- Because detection is relative to the camera, in this setup:
  - Looking down at the laptop (toward the camera) is treated as "looking" → playback resumes.
  - Looking up at the upper monitor (away from the camera) is treated as "away" → playback pauses.
- If your posture or mounting height differs, use the Debug window’s slider to fine‑tune sensitivity.

### Debug window
- Shows live diagnostic logs from the gaze detector and controller.
- Includes a slider to experiment with thresholds while running.

### Privacy
- Video is processed **on-device only**. Frames are not saved or transmitted.
- The app only posts a Play/Pause media key (or optional Safari tab script if you switch modes in code).

### Troubleshooting
- Nothing happens when I look away/back:
  - Ensure `pwyl` has been enabled under System Settings → Privacy & Security → Accessibility.
  - Confirm Camera permission is granted.
  - Make sure your media app/browser responds to the system Play/Pause key.
- Safari mode doesn’t control YouTube:
  - Safari JavaScript control is optional and off by default. To experiment, change `YouTubeController.mode` to `.safariJS` in code and rebuild.
  - Grant Automation permission to allow controlling Safari.
- It pauses a different player than YouTube:
  - System media key affects the current system media destination. Quit other players or switch to Safari mode for targeted YouTube control.

### Notes
- All heuristics are intentionally lightweight to keep CPU usage low and reduce camera/FPS load. 