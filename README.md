# Voxel Editor

Cross-platform Zig + sokol + Dear ImGui voxel editor.

## Features

- Native desktop renderer (sokol + ImGui)
- Web build: WASM + WebGL2 + WebAudio
- Mobile target outputs for Android and iOS
- Interactive voxel sphere that you can rotate and sculpt
- Per-light controls: add/remove lights, edit color, position, intensity
- Click/tap voxel erase on the 3D object

## Build

### Desktop (native)

```bash
zig build run
```

### Web (WASM/WebGL/WebAudio)

```bash
zig build web -Demsdk=/absolute/path/to/emsdk
```

Output: `zig-out/web/voxel-editor.html` (plus JS + WASM).

### Android (arm64 shared library)

```bash
zig build android -Dandroid_ndk=/absolute/path/to/android-ndk
```

Output: shared library in `zig-out/lib/` for packaging in an Android project.

### iOS (arm64 static library)

```bash
zig build ios -Dios_sdk=/absolute/path/to/iPhoneOS.sdk
```

Output: static library in `zig-out/lib/` for linking into an iOS app target.

## Controls

- Drag with mouse/finger: orbit camera
- Click or tap on the sphere: erase one voxel
- Mouse wheel: zoom
- UI:
  - `Reset Sphere`
  - `Reset Camera`
  - `Add Light`
  - `Remove Light`
  - Per-light `Enabled`, `Position`, `Color`, `Intensity`

Keyboard shortcuts (desktop):

- `Space`: reset sphere
- `R`: reset camera
- `L`: add light
- `Backspace`: remove light

## Notes

- `zig build android` requires Android NDK to resolve `EGL/GLES/aaudio` libs.
- `zig build ios` requires an iPhoneOS SDK path to resolve Apple frameworks.
- Scene input is unified through `sokol_app` mouse/touch events so rotate/erase works across desktop, mobile, and web.
