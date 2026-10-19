# C1 Tune

A lightweight control app for the **Opal C1** webcam. Not affiliated with or endorsed by
Opal Camera.

C1 Tune runs the camera with Opal's own image tuning and gives you its real hardware
controls (focus, white balance, exposure, color, zoom) from the menu bar, with no virtual
camera, AI models or background services.

- One ~570 KB binary, built with just the Xcode command line tools (`make`). No dependencies.
- Takes the camera from plug-in to a 1080p30 webcam in about 5 seconds; reattaches to an
  already-running camera in under half a second. Idles at 0% CPU.
- If the app quits, the camera keeps working with your last settings.

## Hardware

| | |
|---|---|
| Camera | Opal C1 (USB-C webcam by Opal Camera) |
| Processor | Intel Movidius Myriad X, running Luxonis DepthAI firmware |
| Image sensor | Sony IMX378, 12 MP (as reported by the firmware), mounted upside down |
| Focus | Autofocus lens on a voice-coil motor (lens position 0–255) |
| Status light | RGB LED on GPIOs 34 (blue), 37 (green), 58 (red); white while streaming |
| Microphone | USB audio, "Opal C1 Audio Mic": 2 channels (front pair), 48 kHz |
| USB | `03e7:f63b` running, `03e7:f63c` bootloader, `03e7:2485` USB boot ROM; 5 Gbps |
| Video out | UVC, NV12 1920×1080 at 30 fps |

Opal Composer also ships tuning for an **IMX582** sensor (a later C1 revision). C1 Tune picks
the tuning file from the sensor the camera reports, but it has only been tested on an IMX378.

Tested on macOS 27 on Apple silicon, with Opal Composer 1.0.1.

## Controls

| | |
|---|---|
| Exposure | Auto with bias (−9…+9), or manual shutter (0.1–33 ms) and ISO (100–1600) |
| Focus | Continuous autofocus, or manual lens position |
| White balance | Auto, or manual 1000–12000 (the firmware's scale; see Tuning) |
| Image | Brightness, contrast, saturation, sharpness, denoise, color denoise |
| Anti-flicker | Auto / 50 Hz / 60 Hz / off |
| Zoom | 1×–2× in the 20 steps the camera's scaler supports (see below); never upscaled |
| Framing | Moves the zoomed window left–right and up–down (snaps to center) |
| Flip image | Turns off the default 180° rotation (for a camera mounted upside down) |
| Microphone | Turns on the camera's built-in mic (off by default; see Microphone) |
| Preview | Optional live view in the panel |

Every control is verified on the live picture.

Zoom, framing, flip, the microphone, and returning sharpness/denoise to default are fixed when the camera's
pipeline starts, so changing them restarts the camera (about 5 seconds, once per burst of
changes). Everything else applies instantly.

Settings are saved and re-applied whenever the camera connects or an app starts using it.
They can also be scripted:

```bash
/Applications/C1Tune.app/Contents/MacOS/C1Tune --set zoom=125 frameY=60 saturation=1
```

Keys: `autoExposure exposureUs iso exposureCompensation autoFocus lensPosition autoWhiteBalance
whiteBalanceK brightness contrast saturation sharpness noiseReduction colorNoiseReduction antiFlicker
zoom frameX frameY flipped microphone` (`default` clears sharpness/denoise back to the tuning's value).

### Tuning

Defaults were tuned on a live picture (a person at a desk, white wall behind, warm 3000 K
key light bounced off the wall, 3000 K high-CRI overhead LEDs), on top of Opal's IMX378 tuning:

| Setting | Default | Why |
|---|---|---|
| Exposure bias | −1 | At 0 the face washes out and a white wall nears clipping; −2 is too dark |
| Saturation | +1 | Slightly livelier skin without going orange |
| Sharpness | 3 | Crisper than the tuning's own (≈2) with no visible halos |
| White balance | Auto | Neutral, and keeps up if daylight changes the room |
| Contrast, brightness, denoise | Tuning's | Contrast is strong here (+2 already clips a white wall); denoise 4 erases detail |
| Manual shutter | 16.7 ms | 1/60 s avoids banding under 60 Hz lighting (only used with auto exposure off) |

### Zoom

The sensor always runs in its 4K mode. The on-camera ISP scales that image by a fraction
n/d, and a 1920×1080 window is cut from the result, so zoom = 2·n/d and no pixel is ever
upscaled. The scaler only accepts numerators up to 16 (larger ones make the firmware log
"cannot meet HW constraints MAX_N" and silently skip scaling), and the scaled size must stay
even. Every fraction that fits was boot-tested on the camera; all of them stream:

1×, 1.07×, 1.08×, 1.10×, 1.17×, 1.20×, 1.25×, 1.30×, 1.33×, 1.40×, 1.47×, 1.50×, 1.60×,
1.67×, 1.73×, 1.75×, 1.80×, 1.83×, 1.87×, 2×

1× is the 4K image scaled by ½ rather than the sensor's native 1080p mode: measured on the
same scene it had about half the noise on a flat wall and slightly more fine detail.

- **The white-balance scale isn't true color temperature.** Under 3000 K light, "2800" is
  strongly blue and neutral sits around "3800–4000". Around "4200" gives a warm look.

## Microphone

**Off by default.** The firmware always advertises the camera as a USB microphone, "Opal C1
Audio Mic", so it still appears in macOS and call apps when the switch is off. It just
records silence, because the pipeline has no audio nodes. Hiding it would mean changing
the firmware's USB descriptors, and both ways tried (cutting the audio interfaces out, or
marking them vendor-specific) stop the firmware's XLink link from coming up. The camera
then resets within seconds of enumerating.

**On**, it's a normal USB mic, configured the way Opal Composer sets it up (read from its
binary): the two front mics, a fixed 30 dB gain, and the firmware's experimental automatic
gain off.

Measured against the MacBook's built-in mic over the same seconds, the Opal mic reads
about 8–12 dB louder under C1 Tune, and about 4 dB louder in the camera's standalone mode,
so it's a few dB hotter than out of the box. Peaks reached about −1.5 dBFS in testing.

## Requirements

**Opal Composer 1.0.1 must be installed** (not running). C1 Tune reads three things from it:
the camera's DepthAI firmware and Opal's two tuning files. Nothing from Opal is
redistributed here. `mac-setup` installs that version.

Only one app can control the camera, so Opal Composer must not be running. If it has ever
been set up on this Mac, its login item and background helpers can start it again (for
example when the camera is plugged in). Switch them all off with:

```bash
make disable-opal    # or scripts/disable-opal.sh; asks for your password for Opal's root helpers
make enable-opal     # undo
```

This quits Opal Composer and disables its launchd jobs: the login items, the
start-on-USB-plug agent, the virtual-camera assistant, and the camera-extension, update
and uninstall helpers. Nothing is deleted. `scripts/disable-opal.sh --dry-run` shows what
it would do. Opal's virtual-camera system extension stays installed but idle; only Opal
Composer can remove it. If C1 Tune finds Opal Composer holding the camera, its panel says so.

## Not yet supported

- **Hiding the microphone.** Off, the mic is silent but still listed as an input (see Microphone).
- **Microphone gain.** The mic runs at Opal Composer's fixed 30 dB gain, and macOS doesn't
  show an input volume for it.
- **Live readout of auto values** (the exposure, ISO, focus and white balance auto picks).
- **Instant zoom.** Zoom is part of the pipeline the camera starts with, so changing it
  restarts the camera. Opal changes zoom live with an extra on-camera resize step, which
  upscales and softens the picture.

## Build and install

```bash
make install    # builds and copies to /Applications
make test       # offline protocol tests (no camera needed)
make uninstall  # removes the app, its login item and its settings
make disable-opal  # switches off Opal Composer's background services (see Requirements)
```

Turn on **Open at login** in the panel, or from a script:

```bash
/Applications/C1Tune.app/Contents/MacOS/C1Tune --register-login-item
```

## How it works

Out of the box the Opal C1 runs a standalone app from flash: a plain webcam that accepts
standard webcam control requests but ignores them. Opal Composer gets real control by
booting the camera into DepthAI firmware uploaded over USB; C1 Tune does the same with a
minimal pipeline.

1. **Reboot to the bootloader**: USB vendor request `0xF5`/`0x0DA1`.
2. **Drop to the USB boot ROM**: one XLink command, `USB_ROM_BOOT`.
3. **Upload firmware to RAM**: a boot header carrying the board config (UVC on), then the
   firmware with its webcam formats patched to advertise only 1920×1080. Nothing is written
   to flash; unplugging the camera always restores factory behaviour.
4. **Start a pipeline over RPC**: camera (Opal's tuning file uploaded as an asset) → UVC
   webcam output, plus an XLinkIn `control` input, and (with the microphone on) `AudioMic` →
   USB audio output (`UAC`). The UVC node lights the status LED while streaming, as Opal does.
5. **Control**: every setting is a DepthAI `CameraControl` message written to `control`.
   The camera ignores them while no app is streaming, so they're re-sent when one starts.

Things the live testing established (and the code relies on):

- **Watchdog**: booting with `watchdogTimeoutMs = 0` makes the firmware reset the moment video
  starts. The firmware default is used, and the app feeds the watchdog from its own thread.
- **Frame size**: the firmware only streams when the frame *index* a client requests maps to
  the pipeline's output size, so the 4K/1440p/720p descriptors are rewritten to the 1080p
  entry. Every app gets 1080p; macOS scales it for apps that want less.
- **Sensor modes**: native 1080p works, and so does 4K with any ISP scale whose numerator is ≤ 16, down
  to ½ (see Zoom). An earlier "RGB postprocessing error" at ½ was the frame-index mismatch
  above, not the scaler.
- **The bootloader serves one session**: talk to it once, cleanly, then boot.
- **Fast restart**: the same `0xF5` request works on the running firmware, so restarting the
  pipeline takes ~5 s instead of waiting for the standalone app to boot.
- **Audio**: the USB mic only carries sound when an `AudioMic` node feeds a `UAC` node. Both
  exist only in Opal's fork of depthai-shared (`12dc4c5`); their IO names and queue sizes
  come from the node constructors in Opal's `libdepthai-core`. The firmware turns the mic on
  only while an app is recording ("UAC restart" in its log).
- **Reattach keeps the running pipeline**: when C1 Tune starts and the camera is already
  running a pipeline (e.g. after the app relaunches), it's reused as is, microphone setting
  included. A camera left running by an older C1 Tune keeps that version's audio setup until
  it restarts (any setting that restarts the camera, or a replug).

Protocol details come from Luxonis's open-source depthai-core, XLink and depthai-shared at
the versions matching Opal's firmware (device side `26f3d765`, depthai-shared `12dc4c5`).
The pipeline settings Opal uses (board socket, planar output, GPIOs, orientation, chunk
size, microphone setup) were read from its binary. `Tests/fixtures` holds reference messages generated by
compiling those headers, and `make test` checks the encoders against them byte for byte.

| File | |
|---|---|
| `Sources/USB.swift` | IOKit access to each boot stage |
| `Sources/XLink.swift` | XLink link protocol (84-byte headers, streams, watchdog keepalive) |
| `Sources/DepthAI.swift` | libnop/msgpack encoders, boot image + descriptor patch, pipeline schema, RPC, firmware extraction |
| `Sources/OpalSession.swift` | Boot/attach state machine and control delivery |
| `Sources/StreamWatcher.swift` | Notices when an app starts the webcam (CoreMediaIO) |
| `Sources/StatusIcon.swift` | Menu bar icon (the C1 drawn from the front) |
| `Sources/CameraSettings.swift` | Saved settings → camera commands, zoom/framing |
