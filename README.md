# LocationSpoofer

A personal iOS app to spoof device location using an on-device VPN packet tunnel.

## How it works

- Uses Apple's `NetworkExtension` framework (`NEPacketTunnelProvider`)
- Creates an on-device VPN that routes traffic from Apple's WiFi location servers through a local proxy
- The proxy intercepts responses and replaces coordinate data with your chosen fake location
- No external servers involved — everything runs on-device

## Requirements

- **Paid Apple Developer account** ($99/yr) — required for the `packet-tunnel-provider` entitlement
- iOS 16.0 or later
- Sideload using **AltStore** or **Sideloadly** after signing with your developer certificate

## Setup

1. Download the `.ipa` from GitHub Actions artifacts (see Actions tab)
2. Open Xcode, set your Team ID in both target signing settings
3. Sign and install with your developer certificate
4. On first run, approve the VPN configuration when prompted in Settings

## Usage

1. Open the app
2. Tap anywhere on the map or search for a location
3. Toggle the switch to activate spoofing
4. All apps using WiFi-based location will see your fake coordinates

## Important Notes

- GPS-based location (outdoors with clear sky) is determined by the GPS chip and cannot be spoofed by this method
- This works best for WiFi-triangulated location (indoors, urban areas)
- Toggle off when done to restore normal location behavior
- Re-signing required every 7 days with a free Apple ID (1 year with paid developer account)

## Build

GitHub Actions automatically builds an unsigned `.ipa` on every push to `main`.
Download it from the **Actions** tab → latest workflow run → **LocationSpoofer-unsigned** artifact.
