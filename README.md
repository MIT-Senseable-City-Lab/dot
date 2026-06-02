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
