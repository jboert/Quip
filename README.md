# <img src="QuipMac/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="40" height="40" align="top"> Quip

Talk to your Claude instances. All of them. From your couch.

Quip turns your iPhone into a voice remote for any number of [Claude Code](https://claude.ai/claude-code) sessions running on your Mac. Just speak your prompt and it lands in the right terminal.

![Quip Mac App](docs/screenshot-mac.png)

![Quip iOS App](docs/screenshot-ios.png)

## The idea

You're running 4 Claude sessions across different projects. You don't want to walk over to your keyboard every time you have a thought. You just want to say "refactor the auth middleware" and have it go to the right Claude.

That's Quip. Push-to-talk prompting from your phone.

- **Volume down** to start talking, **any volume button** to stop
- **Tap a window** on your phone to pick which Claude gets your prompt
- **See all your sessions** mirrored live on your phone's screen
- **Quick actions** — hit Return, Ctrl+C, restart Claude, all from context menus
- **Arrange windows** on your Mac with one tap

## Connecting

Just open both apps. Quip finds your Mac automatically over the local network via Bonjour.

For remote use, a Cloudflare tunnel is bundled — no install, no config, no account needed.

## Building

Requires macOS 14+, iOS 17+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd QuipMac && xcodegen generate && cd ..
cd QuipiOS && xcodegen generate && cd ..

xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac build
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'generic/platform=iOS' build
```

## How it works

Your iPhone records speech, transcribes it on-device, and sends the text over WebSocket to the Mac app. The Mac app injects the text into whichever terminal window you selected — iTerm2 or Terminal.app.

The Mac app also broadcasts your window layout to the phone in real-time, so you always see what's where.

```
  iPhone                              Mac
  +---------------+                   +------------------+
  | speak prompt  |    WebSocket      | inject into      |
  | pick window   | ===============> | correct terminal |
  | see layout    | <=============== | broadcast layout |
  +---------------+                   +------------------+
```

## License

GPLv3 — see [LICENSE](LICENSE)
