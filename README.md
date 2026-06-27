# <img src="QuipMac/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="40" height="40" align="top"> Quip

Talk to your Claude instances. All of them. From your couch. No keyboard needed.

Quip turns your phone into a voice remote for any number of [Claude Code](https://claude.ai/claude-code) sessions running on your Mac or Linux machine. Just speak your prompt and it lands in the right terminal.


### Desktop
![Quip Mac App — windows before arranging](docs/screenshot-mac.png)

### Mobile (standard desktop view)
![Quip on Android — windows mirrored from desktop](docs/screenshot-android.png)

### Mobile (arranged view)
![Quip on iOS — windows after arranging](docs/screenshot-ios.png)

## The idea

You're running 4 Claude sessions across different projects. You don't want to walk over to your keyboard every time you have a thought. You just want to say "refactor the auth middleware" and have it go to the right Claude.

That's Quip. Push-to-talk prompting from your phone.

- **Volume down** to start talking, **any volume button** to stop
- **Tap a window** on your phone to pick which Claude gets your prompt
- **See all your sessions** mirrored live on your phone's screen
- **Push notifications** — get pinged on your phone when a session needs your input or finishes
- **Quick actions & custom buttons** — Return, Ctrl+C, Esc, restart Claude, clear context, `/plan`, plus your own custom buttons
- **Accurate dictation** — on-device transcription, biased with your project's vocabulary and auto-correcting common mishearings
- **Prompt & button packs** — share and import reusable setups as `.quippack` files
- **View terminal output** — read the last 200 lines of any terminal from your phone
- **Arrange windows** on your Mac or Linux desktop with one tap
- **QA Mode** — pair a Simulator with a terminal for side-by-side iteration
- **QR code sharing** — scan a QR code from the desktop app to connect instantly
- **Works with iPhone and Android**

## Connecting

Just open both apps. Quip finds your Mac/Linux machine automatically over the local network via Bonjour/mDNS.

For remote use, a Cloudflare tunnel is bundled — no install, no config, no account needed.

## Building

### macOS + iOS

Requires macOS 14+, iOS 17+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd QuipMac && xcodegen generate && cd ..
cd QuipiOS && xcodegen generate && cd ..
```

**Build the Mac app:**

```bash
xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac build
```

The bundled `cloudflared` (for the remote tunnel) is **not** committed to the repo — a pre-build step (`tools/fetch-cloudflared.sh`) downloads the pinned Cloudflare release and verifies its SHA-256 the first time you build. It needs network on a clean build; run `tools/fetch-cloudflared.sh` by hand to pre-fetch (e.g. for offline builds). To update cloudflared, bump `VERSION` and both hashes in that script.

**Build and install the iPhone app over the air** on your paired device:

```bash
# Build (use the generic destination — see the notes on why, not id=<device>)
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'generic/platform=iOS' -derivedDataPath QuipiOS/build build

# List paired devices with `xcrun devicectl list devices`, then install:
xcrun devicectl device install app --device "<your-iphone>" \
  QuipiOS/build/Build/Products/Debug-iphoneos/Quip.app
```

For CI or a build-only run, just drop the install step (and `-derivedDataPath`).

**Notes**

- **First-trust gate (not a build defect):** a development-signed app installs to the home screen but won't launch until its certificate is trusted once. Until then the icon shows an "Untrusted Developer" prompt and `devicectl ... process launch` returns `invalid code signature ... not been explicitly trusted`. Clear it once by running the app from Xcode (▶ Run) or trusting the developer under **Settings → General → VPN & Device Management**; later installs don't need this repeated.
- **Use `generic/platform=iOS`, not `id=<device>`:** an `id=` Debug build emits a debugger-coupled `Quip.debug.dylib` / `__preview.dylib` pair that the app expects the debugger to inject, so it won't launch standalone from a home-screen tap.
- **Don't edit `Info.plist` directly:** `QuipMac/Info.plist` and `QuipiOS/Info.plist` are gitignored and regenerated from `project.yml` by `xcodegen generate`. (`.xcodeproj` files stay tracked so fresh clones open in Xcode without running `xcodegen` first.)

### Android

Requires Android SDK 34 and Java 17.

```bash
cd QuipAndroid && ./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

Or download the APK from the [latest release](https://github.com/jboert/Quip/releases).

### Linux

Requires Rust 1.75+, GTK4, and libadwaita. On openSUSE Tumbleweed:

```bash
sudo zypper install gtk4-devel libadwaita-devel gcc pkg-config
# For X11:
sudo zypper install xdotool wmctrl
# For Wayland (sway):
sudo zypper install ydotool wtype

cd QuipLinux && cargo build --release
```

The binary will be at `QuipLinux/target/release/quip-linux`.

**Supported display servers:**
- **X11** — full support (xdotool/wmctrl for window management)
- **Wayland (sway)** — full support via sway IPC
- **Wayland (Hyprland)** — window enumeration + arrangement
- **Wayland (KDE Plasma)** — full support via kdotool (install `kdotool`; uses ydotool/wtype for input)
- **Wayland (GNOME)** — full support via [Window Commander](https://extensions.gnome.org/extension/7302/window-commander/) extension (uses ydotool/wtype for input)

## How it works

Your phone records speech, transcribes it on-device, and sends the text over WebSocket to the Mac/Linux app. The app injects the text into whichever terminal window you selected.

The desktop app broadcasts your window layout to the phone in real-time, so you always see what's where.

```
  Phone                            Mac / Linux
  +---------------+                +------------------+
  | speak prompt  |   WebSocket    | inject into      |
  | pick window   | ============> | correct terminal |
  | see layout    | <============ | broadcast layout |
  +---------------+                +------------------+
```

## License

GPLv3 — see [LICENSE](LICENSE)
