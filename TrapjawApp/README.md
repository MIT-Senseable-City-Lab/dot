# TrapjawApp

iOS application for real-time insect detection and tracking using the trapjaw library. Designed for field deployment with automatic operation during daylight hours.

## Features

- **Real-time camera processing** at 30fps (1080p)
- **GPU-accelerated detection** via Metal compute shaders
- **Automatic background model warmup** with configurable frame count
- **Multi-object tracking** with identity stitching across occlusion gaps
- **Crop extraction** with JPEG conversion and buffering
- **Network streaming** to Pi server via HTTP
- **Time-based operation** (5AM - 10PM local time)
- **Automatic pause/resume** at operating hours boundaries
- **Retry logic** for failed uploads with exponential backoff
- **Screen always-on** during processing

## Architecture

### Pipeline

```
Camera (30fps, 1080p, BGRA8)
    │
    ▼
TrapjawBridge (GPU detection, tracking)
    │
    ├─► Crop callback ──► JPEG conversion (concurrent queue)
    │                         │
    │                         ▼
    │                    TrackBuffer (in-memory)
    │                         │
    │                         ▼ (on termination)
    │                    Upload: telemetry + crops
    │
    └─► Debug callback ──► UI metrics update
```

### Key Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `CameraManager` | `Camera/CameraManager.swift` | AVCaptureSession, frame delivery |
| `TrapjawBridge` | `Processing/TrapjawBridge.swift` | Swift wrapper for trapjaw C API |
| `TrapjawProcessor` | `Processing/TrapjawProcessor.swift` | Pipeline orchestrator, lifecycle |
| `TrackBuffer` | `Processing/TrackBuffer.swift` | Thread-safe in-memory crop buffering |
| `TimeWindowManager` | `Processing/TimeWindowManager.swift` | Operating hours (5AM-10PM), power-efficient |
| `NetworkConfig` | `Networking/NetworkConfig.swift` | Server URL, device ID, DOT session |
| `DataStreamer` | `Networking/DataStreamer.swift` | Heartbeat (10s), telemetry POST |
| `HTTPUploader` | `Networking/HTTPUploader.swift` | Multipart JPEG upload with retry |
| `PerformanceMetrics` | `Processing/PerformanceMetrics.swift` | FPS, timing stats for UI |

## Configuration

### Operating Hours

The app only processes during daylight hours (**5:00 AM - 10:00 PM** local time):

- **Outside hours**: Shows "PAUSED" status, waits at boundary
- **At 10 PM**: Gracefully stops, uploads remaining tracks, pauses
- **At 5 AM**: Automatically resumes processing

Power-efficient implementation: Single timer scheduled for next boundary, no polling.

### Server Configuration

Edit `Networking/NetworkConfig.swift`:

```swift
static let serverBaseURL = "http://192.168.1.150:5001"
```

### Camera Settings

Configured for consistent field deployment:

| Setting | Value | Purpose |
|---------|-------|---------|
| Session preset | 1080p @ 30fps | Match trapjaw config |
| Exposure duration | 1/1000 sec | Freeze insect motion |
| Focus mode | Locked at 0.5 | Prevent autofocus hunting |
| HDR | Disabled | Consistent exposure |
| White balance | Continuous auto | Adapt to outdoor lighting |

### Track Upload

- **Buffer size**: Max 150 crops per track in memory
- **Upload trigger**: Track termination or buffer full
- **Retry**: 3 attempts with exponential backoff (1s, 2s, 4s)
- **Crop format**: JPEG at 70% quality

## Data Flow

### Track Lifecycle

```
Detection → Tracking → Termination → Upload
     │           │                        │
     ▼           ▼                        ▼
   Crops      Buffer crops         POST telemetry
              (max 150)            POST crops (multipart)
```

### Network Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/heartbeat` | POST | Device status (every 10s) |
| `/api/track` | POST | Track telemetry (on termination) |
| `/upload_track` | POST | Multipart JPEG upload |

### Telemetry Payload

```json
{
  "type": "track",
  "trackId": "42",
  "status": "completed",
  "resolution": { "width": 1920, "height": 1080 },
  "points": [
    { "timestamp": "2024-01-15T10:30:00Z", "x": 100.5, "y": 200.3, "width": 50.0, "height": 30.0, "frameIndex": 900 }
  ],
  "deviceId": "uuid",
  "deviceName": "iPhone"
}
```

## File Structure

```
TrapjawApp/
├── App/
│   └── TrapjawApp.swift              # Entry point, auto-start, time monitoring
├── Camera/
│   ├── CameraManager.swift           # AVCaptureSession configuration
│   └── CameraPreviewView.swift       # Preview layer
├── Processing/
│   ├── TrapjawBridge.swift           # C API wrapper, crop handling
│   ├── TrapjawProcessor.swift        # Pipeline orchestrator, pause/resume
│   ├── TrackBuffer.swift             # Thread-safe crop buffering
│   ├── TimeWindowManager.swift       # Operating hours (5AM-10PM)
│   └── PerformanceMetrics.swift      # FPS, timing stats
├── Networking/
│   ├── NetworkConfig.swift           # Server URL, device ID
│   ├── DataStreamer.swift            # Heartbeat, telemetry POST
│   └── HTTPUploader.swift            # Multipart JPEG upload with retry
├── Models/
│   ├── TrackNode.swift               # Trajectory point
│   ├── StreamResolution.swift        # Resolution struct
│   └── InsectTelemetryPayload.swift   # Full telemetry package
├── Bridge/
│   └── TrapjawApp-Bridging-Header.h  # C header bridge
├── ContentView.swift                 # SwiftUI dashboard
└── Info.plist                        # App configuration
```

## Building

### Prerequisites

- Xcode 15.2+
- iOS 18.0+ device
- Metal-capable GPU

### Steps

1. **Build trapjaw library** (one-time):

```bash
./build-trapjaw.sh
```

This cross-compiles `libtrapjaw.a` and `trapjaw.metallib` for iOS device and simulator.

2. **Open project**:

```bash
open TrapjawApp.xcodeproj
```

3. **Select destination**: Your iPhone (device required for camera)

4. **Build and run**: Cmd+R

## UI Dashboard

The app displays a minimal heads-up dashboard:

```
┌─────────────────────────────────────┐
│ ● Processing    PAUSED  ● CONNECTED │
├─────────────────────────────────────┤
│           TRAPJAW                    │
│                                      │
│   CAM FPS: 30.0    PROC FPS: 28.5    │
│   AVG MS: 12.50    PEAK MS: 18.30    │
│   GPU MS: 8.20     CPU MS: 4.30      │
│                                      │
│   TRACKS: 3        TOTAL: 42        │
│   CROPS: 127       FRAMES: 900       │
│                                      │
│   SENT: 5          PENDING: 2        │
│   FAILED: 0        BUFFERED: 127     │
└─────────────────────────────────────┘
```

- **Status bar**: Processing state, PAUSED indicator (outside hours), connection status
- **Metrics**: FPS, pipeline timing, track counts
- **Network**: Uploads sent, pending, failed, buffered

## Operating Hours Behavior

### App Launch

```
┌──────────────────────────────────┐
│         Check Time               │
│              │                    │
│   ┌──────────┴──────────┐        │
│   │                     │        │
│ 5AM-10PM            Outside       │
│   │                     │        │
│   ▼                     ▼        │
│ Start processing    Show PAUSED   │
│ Schedule 10PM       Schedule 5AM │
│ timer               timer         │
└──────────────────────────────────┘
```

### At Boundary (10PM)

1. TimeWindowManager fires timer
2. `isInOperatingHours` becomes false
3. Processor.pause() called:
   - Stops camera
   - Flushes remaining tracks (uploads crops)
   - Releases Metal resources
   - Sets state to `.paused`

### At Boundary (5AM)

1. TimeWindowManager fires timer
2. `isInOperatingHours` becomes true
3. Processor.resume() called:
   - Reinitializes trapjaw context
   - Starts camera
   - Resumes processing

## Dependencies

### External

- **trapjaw** (submodule): C library for insect detection
- **Apple frameworks**: Metal, AVFoundation, CoreVideo, UIKit, Foundation

### No External Package Managers

All dependencies are Apple system frameworks. The trapjaw submodule is built as a static library.

## Performance

| Metric | Typical Value |
|--------|---------------|
| Camera FPS | 30 fps |
| Processing FPS | 28-30 fps |
| Pipeline latency | 10-15 ms |
| GPU time | 6-10 ms |
| CPU time | 3-5 ms |
| Memory per track | ~7.5 MB (150 crops) |

## Troubleshooting

### App shows "PAUSED" during daytime

- Check device time and timezone settings
- Operating hours are 5:00 AM - 10:00 PM local time
- Verify in `TimeWindowManager.swift`: `startHour = 5`, `endHour = 22`

### Uploads failing

- Check server URL in `NetworkConfig.swift`
- Verify Pi server is running at `http://192.168.1.150:5001`
- Check device is on same network as Pi
- Review logs for HTTP error codes

### Camera not starting

- Grant camera permission in iOS Settings
- Camera requires physical device (not simulator)
- Check `Info.plist` includes `NSCameraUsageDescription`

### High memory usage

- Tracks accumulate until termination
- Max 150 crops per track (~7.5 MB)
- Max 64 concurrent tracks (~480 MB worst case)
- Memory pressure handled by early upload at 150 crops

## License

MIT