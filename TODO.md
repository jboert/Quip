# VoiceCode TODO

## Features
- [ ] Live speech-to-text overlay on Mac screen — show transcription as it comes in as a floating overlay while the user is speaking into the iPhone
- [ ] Make cloudflared tunnel start automatically from the Mac app (currently must be started manually from CLI)
- [ ] Show tunnel URL as QR code in Mac app for easy iPhone scanning
- [ ] Action Button support on iPhone 15+ for PTT (if Apple provides API access)
- [ ] Terminal background color changes based on Claude Code state (neutral/waiting/STT active)
- [ ] Save/load named layout presets
- [ ] Auto-reconnect on tunnel URL change

## Bugs / Polish
- [ ] Volume button cycling needs hidden MPVolumeView to properly reset system volume
- [ ] Accessibility permission prompt loop on ad-hoc signed Mac builds (works when properly signed or run from /Applications)
- [ ] Mac app should auto-start cloudflared on launch and display URL in bottom bar
