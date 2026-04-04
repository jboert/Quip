# Updating the Bundled cloudflared Binary

Quip bundles a `cloudflared` binary for macOS (`QuipMac/Resources/cloudflared`) and auto-downloads it on Linux (`~/.local/bin/cloudflared`). This document covers how to update the macOS bundled binary.

## When to Update

- When Cloudflare publishes security advisories for cloudflared
- Periodically (quarterly recommended) to stay current
- When new features are needed (e.g., protocol changes)

## Steps to Update (macOS)

### 1. Download the Latest Release

Go to the [cloudflared releases page](https://github.com/cloudflare/cloudflared/releases) and download the macOS binary for your architecture:

```bash
# For Apple Silicon (arm64):
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz
tar -xzf /tmp/cloudflared -C /tmp/

# For Intel (amd64):
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz
tar -xzf /tmp/cloudflared -C /tmp/
```

If the release provides a standalone binary instead of a tarball:

```bash
# Apple Silicon:
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64

# Intel:
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64
```

### 2. Verify the Checksum

Download the corresponding `.sha256` file and verify:

```bash
# Download checksum (adjust URL to match the binary you downloaded)
curl -fsSL -o /tmp/cloudflared.sha256 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.sha256

# Compute local hash
shasum -a 256 /tmp/cloudflared

# Compare against published hash
cat /tmp/cloudflared.sha256
```

The two hashes must match exactly. **Do not proceed if they differ.**

### 3. Replace the Bundled Binary

```bash
chmod +x /tmp/cloudflared
cp /tmp/cloudflared QuipMac/Resources/cloudflared
```

### 4. Test

1. Build and run QuipMac
2. Verify the tunnel starts successfully (check the status bar menu)
3. Connect from an iOS or Android client to confirm end-to-end functionality
4. Check the version: `QuipMac/Resources/cloudflared --version`

### 5. Commit

```bash
git add QuipMac/Resources/cloudflared
git commit -m "Update bundled cloudflared to $(QuipMac/Resources/cloudflared --version | head -1)"
```

## Linux Auto-Download

The Linux version (`QuipLinux`) auto-downloads cloudflared from the latest GitHub release at runtime if not already installed. It also verifies the SHA256 checksum before executing (see `QuipLinux/src/services/cloudflare_tunnel.rs`). No manual binary management is needed for Linux.

## Notes

- The macOS binary is architecture-specific. If you need to support both Intel and Apple Silicon, consider using a universal binary or distributing separate builds.
- Cloudflare's release artifacts are signed. For additional verification, check their [GPG signing keys](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).
- The `.sha256` file format is `<hash>  <filename>` — only the hash portion (first whitespace-delimited token) is needed for comparison.
