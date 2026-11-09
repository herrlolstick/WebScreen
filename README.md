# WebScreen

Extend your Mac's display to any device with a browser – iPad, Android tablet, old laptop, smart TV.

WebScreen is a native Mac app in the Liquid Glass design of macOS 26. It creates a **real virtual monitor** (no dongle, no driver), captures it and streams it over your local network. On the other device you simply open the address shown in the app or scan the QR code – done. Nothing needs to be installed there.

## Features

- Any number of virtual screens at the same time
- Automatic assignment: **One screen for all** or **One screen per device** (at exactly that device's resolution, including Retina)
- Devices are recognized again; fixed per-device assignments for special cases
- Screens are only created when a device needs them
- Resolutions up to 4K UHD (and custom sizes up to 5120 points), Retina/HiDPI
- Several devices on the same screen (mirrored) via the screen's own code
- Works in any browser over plain HTTP – no certificate, no app
- Streaming as **JPEG** (lowest latency), **H.264**, **HEVC** or **Video auto** (HEVC where the device supports it, H.264 otherwise – per screen, switching without a restart)
- Optionally sends only the changed parts of the image (often saves more than 90 % during normal work)
- Automatic quality/bitrate adaptation on weak Wi-Fi
- Streaming settings apply instantly while devices stay connected
- Low latency through “latest frame wins”: slow devices skip frames instead of falling behind
- Multiple receivers at the same time
- QR code for quick connecting
- Live preview, device list with data rate, disconnect individual devices
- Launch at login, optional menu bar icon

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon or Intel – Liquid Glass on macOS 26 and later, classic materials below
- Xcode (Xcode 26 or later for Liquid Glass)

## Installation

```bash
git clone https://github.com/herrlolstick/WebScreen.git
cd WebScreen
./build.sh
```

The script compiles the app, signs it, copies it to `/Applications` and launches it. On first launch macOS asks for the **Screen & System Audio Recording** permission – allow it and restart WebScreen once.

> **Tip:** Add your Apple ID in Xcode under *Settings → Accounts* (free). `build.sh` then signs automatically with your development certificate, and macOS keeps the recording permission across updates.

## Usage

1. Open WebScreen and click **Start** (or press ⌘R)
2. Under **Assignment**, choose *One screen for all* or *One per device*
3. On the device, scan the QR code or open the address (e.g. `http://192.168.178.20:8787`)
4. Special cases: assign a fixed screen to a device under **Devices**, or use a screen's own code (`/?screen=2`)
5. Use **Arrange Displays** to decide in System Settings where the screens are placed

On the receiver, a tap shows a toolbar with **Fullscreen** and **Stats**. On an iPad, *Share → Add to Home Screen* is worth it: the page then opens without Safari's bars.

## How it works

| Step | Technology |
|---|---|
| Virtual monitor | `CGVirtualDisplay` (private CoreGraphics API, as used by DeskPad/BetterDisplay) |
| Capture | ScreenCaptureKit, only the virtual display |
| JPEG encoding | Core Image / ImageIO, optionally only changed 32×32 tiles |
| H.264/HEVC encoding | VideoToolbox (hardware), custom fMP4 muxer (avc1/hvc1) |
| Transport | WebSocket (Network.framework), port 8788 |
| Receiver | HTTP, port 8787 – JPEG via `createImageBitmap` + canvas, video via Media Source Extensions |
| Auto quality | AIMD control based on skipped packets per device |

Why Media Source Extensions instead of WebCodecs for video? WebCodecs is only available in “secure contexts” (HTTPS), so not over `http://` on a home network. MSE works without HTTPS but buffers a little – hence roughly 0.1–0.2 s more latency than JPEG mode.

## Notes

- Because of the private API, the app cannot be distributed through the Mac App Store. A macOS update could theoretically affect it.
- The data rate depends on how much is moving: a calm desktop needs almost nothing, scrolling in Full HD needs 20–60 Mbit/s depending on quality. 5 GHz Wi-Fi or Ethernet works best.
- Ports 8787/8788 must be reachable on your network. If the macOS firewall asks, allow incoming connections.
- After changing the port, open the new address on your devices once.

## Ideas for later

- Touch/mouse input from the receiver back to the Mac
- Automatically adapt the resolution when the receiving device rotates

## License

MIT – see [LICENSE](LICENSE).
