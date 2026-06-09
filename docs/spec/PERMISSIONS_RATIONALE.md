# Recording Permissions Rationale

This document explains why Scribe requires specific macOS permissions and the technical trade-offs involved in its recording architecture.

## Overview

Scribe requires two primary permissions for its core recording functionality:
1. **Screen & System Audio Recording** (`NSScreenCaptureDescription`)
2. **Microphone Access** (`NSMicrophoneUsageDescription`)

## Technical Rationale: ScreenCaptureKit (SCK)

Scribe utilizes Apple's **ScreenCaptureKit** framework via the `SCStream` API to capture both system audio and microphone input.

### Why not "System Audio Recording Only"?

Newer macOS APIs (introduced in 14.4+) like `AudioHardwareCreateProcessTap` allow apps to request a more limited "System Audio Recording Only" permission. However, Scribe intentionally uses the more intrusive ScreenCaptureKit for the following reasons:

#### 1. Sample-Perfect Synchronization
High-quality transcription requires precise alignment between the user's voice (microphone) and other participants (system audio). ScreenCaptureKit provides a "Dual Output Stream" mechanism where both microphone and system audio samples are delivered with a **shared hardware clock**.

This ensures that the two tracks are sample-locked. Apps using independent process taps (like OpenOats) rely on wall-clock timestamps (`Date()`), which are subject to clock drift. Over long recordings, independent tracks can slide out of sync by dozens of milliseconds, making accurate speaker diarization and alignment impossible.

#### 2. Hardware-Backed AEC (Acoustic Echo Cancellation)
Because the microphone and system audio are captured on the same sync clock, Scribe can effectively perform echo cancellation. If the tracks were captured independently, the system audio bleeding into the microphone (e.g., from speakers) would be much harder to identify and "subtract," leading to poor transcription quality where other speakers are heard "twice" through the user's microphone.

## Why Separate Microphone Permission?

Even though the microphone is captured *through* the ScreenCaptureKit stream, macOS treats the microphone as a separate privacy domain.

1. **TCC Isolation:** Apple's security model (TCC) does not allow "Screen Recording" to act as a back-door to hardware sensors.
2. **Mandatory Requirement:** Setting `capturesMicrophone = true` in an `SCStreamConfiguration` strictly requires the `NSMicrophoneUsageDescription` in `Info.plist`. Without an explicit user grant to the microphone domain, the OS will "zero out" the microphone buffers in the SCK stream, even if screen recording is allowed.

## Comparison: Scribe vs. OpenOats

| Feature | Scribe | OpenOats |
| :--- | :--- | :--- |
| **Primary API** | `ScreenCaptureKit` (`SCStream`) | `Core Audio` (`CATap`) |
| **Primary Permission** | Screen & System Audio Recording | System Audio Recording Only |
| **Sync Method** | Shared Hardware Clock | Wall-clock Alignment |
| **Transcription Goal** | High-precision AEC & Alignment | Maximum Privacy / Minimal Prompts |

## Implementation References

- `SCKDualOutputStream.swift`: Manages the shared `SCStream` lifecycle.
- `SCKAudioCaptureSource.swift`: Adapts SCK buffers to the internal ingest path.
- `PermissionsService.swift`: Handles the verification and request flow for both TCC domains.
- `Info.plist`: Contains the required usage strings for both permissions.
