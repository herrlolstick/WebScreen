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
- **Video auto** (default): hardware HEVC or H.264 with a steady frame rate – about 30–60 ms from Mac to browser on plain `http://`, with nothing to set up on the device or router
- **Real-time** streaming via WebRTC as an option for weak Wi-Fi: recovers from lost packets without stalling
- Alternatively **JPEG**, **H.264**, **HEVC** or **Video auto** (HEVC where the device supports it, H.264 otherwise – per screen, switching without a restart)
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
- Xcode (Xcode 26 or later for Liquid Glass) – a free Apple ID is enough to build and run it yourself

## Download

The easiest way – no Xcode, no Terminal:

1. Download the latest `WebScreen-<version>.dmg` from the [Releases page](https://github.com/herrlolstick/WebScreen/releases/latest).
2. Open the DMG and drag **WebScreen** onto the **Applications** folder.
3. Start WebScreen from Launchpad or the Applications folder. The app is signed and notarized by Apple, so it opens without a security warning.
4. On first launch macOS asks for the **Screen & System Audio Recording** permission – allow it in *System Settings → Privacy & Security* and restart WebScreen once.

To update, download the new DMG and replace the app in the Applications folder; the permission stays.

## Installation

To build WebScreen yourself from source:

```bash
git clone https://github.com/herrlolstick/WebScreen.git
cd WebScreen
./build.sh
```

The script builds the Xcode project, copies the app to `/Applications` and launches it. Alternatively open `WebScreen.xcodeproj` in Xcode and press ⌘R – set your own team under *Signing & Capabilities* first. The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`) and committed, so XcodeGen is only needed when you change the project structure. On first launch macOS asks for the **Screen & System Audio Recording** permission – allow it and restart WebScreen once.

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
| Real-time | WebRTC ([libwebrtc](https://github.com/stasel/WebRTC)), hardware H.264 via VideoToolbox, peer-to-peer over UDP in the local network |
| H.264/HEVC encoding | VideoToolbox (hardware, low-latency rate control), custom fMP4 muxer (avc1/hvc1) |
| Transport | WebSocket (Network.framework), port 8788 – also carries the WebRTC signaling |
| Receiver | HTTP, port 8787 – WebRTC `<video>`, JPEG via `createImageBitmap` + canvas, other video via Media Source Extensions |
| Auto quality | AIMD control based on skipped packets per device |

Measured on a Mac (time from a change on the virtual screen until the browser shows it): H.264 via Media Source Extensions about 30–60 ms, Real-time (WebRTC) about 75 ms. WebRTC's browser-side playout buffer is the difference – so **Video auto** (HEVC, or H.264 where HEVC isn't supported) is the default, and Real-time is meant for weak Wi-Fi, where it recovers from lost packets without stalling.

### Expert: HTTPS with WebCodecs

Under *Streaming → Expert* you can additionally serve the page over HTTPS using the public `*.local-ip.sh` certificate (ports 8789/8790). Devices then decode H.264/HEVC with WebCodecs. This requires a router that resolves `local-ip.sh` names to local addresses – a FRITZ!Box, for example, needs an exception in its DNS rebind protection. The certificate's private key is public by design, so this only gives browsers a secure context, not extra privacy.

## Publishing a release (maintainers)

`./release.sh` builds a signed, notarized and stapled `WebScreen-<version>.dmg` plus `.zip` in `~/Library/Caches/WebScreen-build/release/`. It needs a paid Apple Developer membership and two one-time steps:

1. **Apple ID in Xcode:** Add the account with the paid membership under Xcode → *Settings → Accounts*. Xcode then signs the app with the team's cloud-managed Developer ID certificate. A local *Developer ID Application* certificate (*Manage Certificates… → +*) is optional and is only used to also sign the DMG.
2. **Notarization credentials:** create an app-specific password at [account.apple.com](https://account.apple.com) (*Sign-In and Security → App-Specific Passwords*), then store it in the keychain – the command asks for the password:

   ```bash
   xcrun notarytool store-credentials WebScreen-notary --apple-id <your Apple ID> --team-id 566V5MVR96
   ```

Then bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` (and run `xcodegen generate`), run `./release.sh`, and upload the DMG to a GitHub release. The script checks the result with `spctl` and `stapler validate` itself.

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
