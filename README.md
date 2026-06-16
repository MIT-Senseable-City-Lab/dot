# SCL DOT

An iOS field-dashboard app for the [Trapjaw](https://github.com/aasehaa/trapjaw) real-time insect rotoscoping pipeline.

## What it does

SCL DOT runs the Trapjaw computer-vision engine directly on an iPhone, capturing live video and detecting, tracking, and cropping flying insects in real time using Apple Metal compute shaders. The app presents a minimal heads-up display of pipeline metrics so you can monitor performance in the field.

## Features

- **Live metrics dashboard** — camera FPS, processing FPS, average pipeline latency, GPU time, active track count, and pending uploads
- **Background capture** — manually trigger a background image capture for the segmentation model
- **Video clip recording** — record and upload short video clips on demand
- **Operating hours** — automatic start / pause based on a configurable time window
- **Cool-down & status indicators** — visual feedback for warmup, cooling, paused, and offline states
- **Settings sheet** — in-app configuration

## Architecture

- **SwiftUI** front end (`TrapjawApp`, `ContentView`, `SettingsView`)
- **`TrapjawProcessor`** (`Processing/TrapjawProcessor.swift`) — bridges the SwiftUI layer to the underlying Trapjaw C++ pipeline
- **Trapjaw submodule** (`trapjaw/`) — the core detection/tracking library
- **Pre-built libraries** (`lib/`) — `libtrapjaw.a` for iOS device and simulator, plus `trapjaw.metallib`

## Processing Pipeline

```
Camera (4K @ 30fps)
  │
  ▼
CameraManager.didOutput  ─── every other frame dropped → 15fps effective
  │
  processingQueue.async ──────────────────────────────────────────
  │                                                               │
  ▼                                                               ▼
FourKFrameBuffer.add()                                  MetalDownscaler
  (store 4K frame for                                     4K → 1080p GPU
   later crop extraction)                                     │
                                                              ▼
                                                     TrapjawBridge.processFrame()
                                                     (GMM background subtraction,
                                                      blob detection, tracking,
                                                      crop emission)
                                                              │
                                                              ├── onCrop callback
                                                              │     │
                                                              │     ├─ Scale bbox 1080p → 4K
                                                              │     ├─ FourKFrameBuffer.get() (lookup 4K frame)
                                                              │     ├─ extractCropFrom4K() (CoreImage + JPEG)
                                                              │     └─ TrackBuffer.addCrop() → upload at 15 crops
                                                              │
                                                              ├── onDebugFrame → PerformanceMetrics
                                                              │     (GPU ms, active tracks, status)
                                                              │
                                                              └── onTrackTerminated → finalized upload
                                                                     (polled every 60 frames)

  (every 30 frames) → updateStats() → warmup → state = .processing
  (every 60 frames) → checkTerminatedTracks() → upload
```

### Key design decisions

- **Dual-resolution pipeline** — Camera captures 4K; frames are downscaled to 1080p for CV processing while raw 4K frames are buffered in a ring buffer (`FourKFrameBuffer`) for high-resolution crop extraction. This avoids quality loss on output crops.
- **Frame skip** — 30 fps camera → 15 fps effective processing (every other frame dropped) since 4K format does not support 15 fps on iPhone.
- **Async downscale + serial pipeline** — Metal GPU downscale runs asynchronously; results dispatch back to a serial `processingQueue` so all downstream work (trapjaw inference, crop dispatch) stays ordered and `pause()` can drain in-flight frames safely.
- **Crop upload batching** — Every 15 crops per track triggers an intermediate upload. When trapjaw signals termination, remaining crops are finalized and uploaded with a `"completed"` status + done marker.
- **Thermal management** — Hourly 5-minute cool-down periods (:55–:00) pause processing to prevent overheating. A memory guard triggers an emergency 5-second pause if RSS exceeds 900 MB.
- **Operating hours** — Automatic start at 5 AM, pause at 10 PM, configurable via `TimeWindowManager`.
- **Luminance-based exposure release** — Monitors scene luminance; releases the locked 1/1000s shutter back to auto-exposure when sustained brightness exceeds a threshold (avoiding overexposed captures indoors).

## Requirements

- iOS 18.0+
- Xcode 16+
- CMake 3.20+ (for rebuilding the Trapjaw library)
- An iPhone with a Metal-capable GPU

## Building

1. Clone the repo and initialize submodules:
   ```bash
   git clone --recurse-submodules https://github.com/MIT-Senseable-City-Lab/dot.git
2. Build the Trapjaw library and Metal shaders:
./build-trapjaw.sh all
3. Open TrapjawApp.xcodeproj in Xcode and build for your target device.
License
MIT
