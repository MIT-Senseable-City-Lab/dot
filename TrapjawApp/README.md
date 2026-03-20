# TrapjawApp

iOS application for real-time insect detection and tracking using the trapjaw library. Designed for field deployment with automatic operation during daylight hours.

## Features

- **Real-time camera processing** at 30fps (4K capture, 1080p processing)
- **Async GPU-accelerated pipeline** via Metal compute shaders
- **4K crop extraction** for higher resolution insect identification
- **Automatic background model warmup** with configurable frame count
- **Multi-object tracking** with identity stitching across occlusion gaps
- **Crop extraction** with CoreImage (preserves color accuracy) and JPEG encoding
- **Network streaming** to Pi server via HTTP
- **Time-based operation** (5AM - 10PM local time)
- **Automatic pause/resume** at operating hours boundaries
- **Scheduled cool-down periods** to prevent thermal throttling
- **Memory pressure handling** with automatic buffer reduction
- **Screen always-on** (including overnight pause for connection maintenance)

## Architecture

### Pipeline

```
Camera (30fps, 4K, BGRA8)
    │
    ├─► FourKFrameBuffer (10 frames, ~330MB)
    │
    ▼
MetalDownscaler (async 4K→1080p)
    │
    ▼
TrapjawBridge (GPU detection, tracking at 1080p)
    │
    ├─► Crop callback ──► Scale bbox 2x (1080p → 4K)
    │                         │
    │                         ▼
    │                    Extract from 4K buffer (CoreImage)
    │                         │
    │                         ▼
    │                    JPEG conversion (100% quality)
    │                         │
    │                         ▼ (on termination)
    │                    Upload: telemetry + crops
    │
    └─► Debug callback ──► UI metrics update
```

### Key Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `CameraManager` | `Camera/CameraManager.swift` | AVCaptureSession, 4K capture, exposure/focus control |
| `FourKFrameBuffer` | `Processing/FourKFrameBuffer.swift` | Rolling 10-frame 4K buffer for crop extraction |
| `MetalDownscaler` | `Processing/MetalDownscaler.swift` | Async GPU 4K→1080p downscaling |
| `TrapjawBridge` | `Processing/TrapjawBridge.swift` | Swift wrapper for trapjaw C API |
| `TrapjawProcessor` | `Processing/TrapjawProcessor.swift` | Pipeline orchestrator, lifecycle |
| `TrackBuffer` | `Processing/TrackBuffer.swift` | Thread-safe in-memory crop buffering |
| `TimingMetrics` | `Processing/TimingMetrics.swift` | Stage-by-stage timing diagnostics |
| `TimeWindowManager` | `Processing/TimeWindowManager.swift` | Operating hours (5AM-10PM), power-efficient |
| `CoolDownManager` | `Processing/CoolDownManager.swift` | Thermal management, scheduled cool-down periods |
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
| Session preset | 4K @ 30fps | Capture at highest resolution for crops |
| Downscale | Async Metal (4K→1080p) | GPU-accelerated, non-blocking pipeline |
| Exposure duration | 1/1000 sec | Freeze insect motion |
| Focus mode | Continuous autofocus | Adapts to scene distance |
| HDR | Disabled | Consistent exposure |
| White balance | Continuous auto | Adapt to outdoor lighting |
| Crop extraction | CoreImage from 4K | Preserves camera color space, no artifacts |
| JPEG quality | 100% | No compression artifacts for identification |

### Track Upload

- **Buffer size**: Max 150 crops per track in memory
- **Upload trigger**: Track termination or buffer full
- **Retry**: 1 attempt (reduced for performance)
- **Crop format**: JPEG at 100% quality (4K resolution)
- **Sequential filenames**: `frame_000000.jpg`, `frame_000060.jpg`, etc.

## 4K Crop Pipeline

### Why 4K?

- **Higher resolution crops** for better insect identification
- **Trapjaw processes at 1080p** for performance
- **Crops extracted from 4K buffer** for maximum detail
- **Scalable bbox coordinates** (2x from 1080p detection)

### Pipeline Flow

1. **Camera captures 4K** (3840×2160) frame
2. **Frame stored** in rolling 4K buffer (10 frames, ~330MB)
3. **Async downscale** 4K → 1080p via Metal compute shaders
4. **Trapjaw processes** 1080p frame for detection
5. **Bounding box detected** at 1080p resolution
6. **Bbox scaled 2x** to 4K coordinates
7. **CoreImage extracts crop** from 4K buffer (preserves color)
8. **JPEG encoded at 100%** quality for upload

### Memory Management

- **4K buffer**: 10 frames × ~33MB = ~330MB
- **Pressure handling**: Reduces to 5 frames on iOS memory warning
- **Async processing**: Camera callback non-blocking (GPU executes independently)

## Data Flow

### Track Lifecycle

```
Detection → Tracking → Termination → Upload
     │           │                        │
     ▼           ▼                        ▼
   Crops      Buffer crops         POST telemetry
              (max 150)            POST crops (multipart)
                                     Sequential filenames
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
  "resolution": { "width": 3840, "height": 2160 },
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
│   ├── CameraManager.swift           # AVCaptureSession, 4K capture configuration
│   └── CameraPreviewView.swift       # Preview layer
├── Processing/
│   ├── TrapjawBridge.swift           # C API wrapper, crop handling
│   ├── TrapjawProcessor.swift        # Pipeline orchestrator, pause/resume
│   ├── FourKFrameBuffer.swift        # Rolling 4K buffer (10 frames)
│   ├── MetalDownscaler.swift         # Async GPU 4K→1080p downscaling
│   ├── TrackBuffer.swift             # Thread-safe crop buffering
│   ├── TimingMetrics.swift           # Stage-by-stage timing diagnostics
│   ├── TimeWindowManager.swift       # Operating hours (5AM-10PM)
│   ├── CoolDownManager.swift         # Thermal management, scheduled breaks
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
- trapjaw submodule initialized: `git submodule update --init --recursive`

### Steps

1. **Build trapjaw library** (one-time):

```bash
cd trapjaw
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
│ ● Processing    ● CONNECTED         │
├─────────────────────────────────────┤
│           TRAPJAW                   │
│                                      │
│   CAM FPS: 30.0    PROC FPS: 30.0   │
│   AVG MS: 12.00    GPU MS: 10.00    │
│                                      │
│   TRACKS: 1        CROPS: 45        │
│   PENDING: 0       BUFFERED: 45     │
└─────────────────────────────────────┘
```

- **Status bar**: Processing state, connection status
- **Metrics**: FPS, pipeline timing (AVG MS, GPU MS)
- **Detection**: Track count, total crops
- **Network**: Pending uploads, buffered crops

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

## Scheduled Cool-Down Periods

To prevent thermal throttling on iPhone models with limited GPU performance (e.g., iPhone XR), the app implements scheduled cool-down periods.

### Schedule

- **Duration**: 5 minutes every hour
- **Time window**: :55 to :00 (e.g., 12:55-13:00, 13:55-14:00)
- **Behavior**: Processing pauses, camera continues running
- **UI indicator**: "COOLING DOWN" appears in status bar (cyan color)

### What Happens During Cool-Down

```
Normal Processing          Cool-Down Period          Resume Processing
       │                          │                          │
       ▼                          ▼                          ▼
   ┌──────────┐              ┌──────────┐              ┌──────────┐
   │ Process  │    :55       │ Pause    │    :00       │ Process  │
   │ frames   │─────────────▶│ processing──────────────▶│ frames   │
   │ (30fps)  │              │ (0fps)   │              │ (30fps)  │
   └──────────┘              └──────────┘              └──────────┘
        │                         │                          │
        │                    ┌────┴────┐                     │
        │                    │         │                     │
        │                    ▼         ▼                     │
        │              Camera    Pending uploads              │
        │              continues   complete                   │
        │              running     in background              │
        │                    │         │                     │
        └────────────────────┴─────────┴─────────────────────┘
```

### Implementation

| Aspect | Details |
|--------|---------|
| Buffer behavior | 4K frame buffer continues accepting frames (10 frames) |
| Crop processing | Paused - no new crops extracted during cool-down |
| Network uploads | Continue in background (pending uploads complete) |
| Camera state | Running (ready for immediate resume) |
| State | `.coolingDown` with cyan status indicator |

### Manual Override

The cool-down manager supports manual control for testing or emergency situations:

```swift
// Skip current cool-down and resume immediately
CoolDownManager.shared.skipCurrentCoolDown()

// Force an immediate cool-down period
CoolDownManager.shared.forceCoolDown(duration: 300) // 5 minutes

// Disable cool-down scheduling entirely
CoolDownManager.shared.isEnabled = false
```

### Files

- `CoolDownManager.swift` - Schedule monitoring and state management
- `TrapjawProcessor.swift` - Skips frame processing during cool-down
- `ContentView.swift` - UI indicator for cool-down state

## Dependencies

### External

- **trapjaw** (submodule): C library for insect detection
- **Apple frameworks**: Metal, AVFoundation, CoreVideo, UIKit, Foundation, CoreImage

### No External Package Managers

All dependencies are Apple system frameworks. The trapjaw submodule is built as a static library.

## Performance

| Metric | Typical Value |
|--------|---------------|
| Camera FPS | 30 fps |
| Processing FPS | 30-31 fps |
| Downscale latency | 2-4 ms (async, GPU) |
| Trapjaw latency | 6-10 ms |
| Total pipeline | 10-15 ms |
| Memory | ~200-330 MB (4K buffer + processing) |
| Buffer size | 10 frames (configurable) |

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

- 4K buffer: 10 frames × ~33MB = ~330MB baseline
- On memory warning: Automatically reduces to 5 frames
- If consistently high: Reduce buffer size in `TrapjawProcessor.swift`: `FourKFrameBuffer(maxFrames: 8)`

### Crops have pink/purple color cast

This has been fixed by using CoreImage for crop extraction:
- CoreImage preserves camera's color space metadata
- Manual byte extraction loses color information
- JPEG quality set to 100% for accuracy

### Crops are blurry

Check camera configuration:
1. **Focus**: Ensure continuous autofocus is enabled (not locked)
2. **Exposure**: 1/1000s shutter should freeze motion
3. **ISO**: Check if ISO is too high (causes noise)
4. **Distance**: Camera should be 0.4-0.6m from insects for sharp focus
5. **Lighting**: Ensure adequate lighting to keep ISO low

To debug, add logging in `CameraManager.swift`:
```swift
print("ISO: \(device.iso), Focus: \(device.lensPosition), Exposure: \(CMTimeGetSeconds(device.exposureDuration))s")
```

### App frozen at "Warming Up"

This can happen if:
- `frames_processed` counter not incrementing (use `warmupFramesProcessed` instead)
- Camera callback blocked (fixed by async Metal downscaler)
- Thread safety issues with stats (fixed by passing captured values)

Check logs for `[FRAME]` messages - if missing, camera may not be delivering frames.

## License

MIT
