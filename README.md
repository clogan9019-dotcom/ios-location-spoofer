# LocationSpoofer

A kernel exploit-based iOS location spoofing app. Gains kernel read/write access via the Darksword exploit, then patches `locationd`'s in-memory coordinates and rewrites the system location plist — no jailbreak required.

---

## How It Works

### 1. Kernel Exploit (Darksword)
The app runs the **Darksword** exploit to obtain direct kernel read/write access. This gives it the ability to manipulate any process's memory on the device, including the system location daemon (`locationd`).

The exploit is protected by a **signal-based crash guard** (`CrashGuard`) — if the exploit triggers a fatal signal (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGABRT`, etc.) the app catches it via `sigsetjmp`/`siglongjmp`, logs the crash reason to a file, and returns gracefully instead of hard-crashing.

### 2. VFS Plist Write
Once kernel access is established, the app uses the kernel's virtual file system access (`vfs_write`) to overwrite:

```
/private/var/mobile/Library/Preferences/com.apple.locationd.plist
```

with a plist containing `SimulatedLatitude`, `SimulatedLongitude`, and `SimulationEnabled = true`.

### 3. In-Memory Heap Patch
The app then scans `locationd`'s virtual memory regions for any RW-mapped pages containing coordinate-shaped double pairs (values in `[-90,90]` × `[-180,180]`). Every matching pair is overwritten with the target coordinates using kernel write primitives.

### 4. RemoteCall Reload
After patching, the app uses **RemoteCall** (TaskRop-based remote code execution inside `locationd`'s process) to post `com.apple.locationd.preferencesChanged` from within `locationd` itself, causing it to re-read the plist without needing a respring or daemon restart.

---

## App Tabs

### Exploit Tab
- **Run Exploit** button — launches the Darksword kernel exploit
- **Animated progress ring** — shows real-time exploit progress (0–100%)
- **Status card** — displays the current stage or any error message
- **Force Stop** button — appears while the exploit is running; cancels cleanly
- **Logs button** (top-right) — opens a scrolling sheet of all runtime log messages
- State persists across app backgrounding — if the exploit was running when the app was backgrounded, it resumes on return to foreground

### Tools Tab
- **Interactive map** — tap anywhere to pick a spoofed location; search bar to find addresses
- Locked behind a **"Kernel Ready"** gate — the map is only accessible after the exploit completes successfully
- Once a location is chosen, tapping **Spoof Location** writes the coordinates via VFS + heap patch + RemoteCall
- **Disconnect** stops spoofing and clears the saved coordinates

### Settings Tab
- **t1sz_boot override** — chip-specific kernel offset required by the exploit:
  - A16+ / M-series chips: `0x11`
  - A12 / A13 chips: `0x19`
  - Custom hex entry for other chips
  - **Reset to Auto** clears any override
- Current override value is shown and persisted to `UserDefaults`

---

## Crash & Debug Logging

Every session writes a timestamped log to two locations on the device:

| Path | How to access |
|------|--------------|
| `/private/var/mobile/Documents/LocationSpooferLogs/logs.txt` | Any jailbroken file manager, AFC, or `filza` |
| `Files app → On My iPhone → LocationSpoofer → SpooferLogs/logs.txt` | Files app (no jailbreak needed) |

Each log session starts with a **device info header**:

```
========== SESSION START ==========
Device : iPhone14,2
iOS    : 17.4.1
Kernel : 23.4.0
Log    : /private/var/mobile/Documents/...
===================================
```

Logged events include:
- t1sz_boot value applied
- Exploit start / per-step progress
- `ds_run()` return code
- Signal caught (if crash) — e.g. `CAUGHT SIGNAL 11 (SIGSEGV — bad memory access)`
- `vfs_init()` and `vfs_write()` return codes
- `locationd` proc pointer address
- Number of coordinate pairs patched in memory
- RemoteCall reload result

**To send logs for debugging:** Open Files app → On My iPhone → LocationSpoofer → SpooferLogs → `logs.txt` → share via AirDrop, Notes, or Messages.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| iOS version | 15.0 – 17.x (kernel exploit targets these kernels) |
| Architecture | arm64 (A-series / M-series) |
| Jailbreak | Not required |
| Developer account | Free Apple ID works for 7-day sideload; paid ($99/yr) for 1-year signing |
| Sideload tool | [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io), or [TrollStore](https://github.com/opa334/TrollStore) (if supported) |

### Chip / t1sz_boot Reference

| Chip | Devices | t1sz_boot |
|------|---------|-----------|
| A12 | iPhone XS, XR, iPad (8th gen) | `0x19` |
| A13 | iPhone 11 series | `0x19` |
| A14 | iPhone 12 series | `0x11` (auto) |
| A15 | iPhone 13 / 14 series | `0x11` (auto) |
| A16 | iPhone 14 Pro / 15 series | `0x11` (auto) |
| A17 | iPhone 15 Pro series | `0x11` (auto) |
| M1 / M2 | iPad Pro / Air | `0x11` (auto) |

If the exploit fails or crashes on first run, try setting the t1sz_boot manually in the **Settings** tab before running again.

---

## Getting the IPA

The repo uses **GitHub Actions** to build an unsigned IPA on every push to `main` and on manual trigger.

1. Go to the [Actions tab](../../actions)
2. Click the latest successful **Build IPA** workflow run
3. Scroll to **Artifacts** and download `LocationSpoofer-unsigned`
4. Sideload with Sideloadly or AltStore using your Apple ID

---

## Build from Source

```bash
# Clone the repo
git clone https://github.com/clogan9019-dotcom/ios-location-spoofer.git
cd ios-location-spoofer

# Open in Xcode
open LocationSpoofer.xcodeproj
```

- Set your **Team** in *Signing & Capabilities* for the `LocationSpoofer` target
- Build for a connected device (not Simulator)
- No third-party package manager dependencies — all libraries are vendored under `LocationSpoofer/lib/`

---

## Project Structure

```
LocationSpoofer/
├── ContentView.swift              # Full SwiftUI UI (3 tabs)
├── KernelLocationManager.swift    # Core manager — exploit, VFS, heap patch, RC
├── LocationSpooferApp.swift       # App entry point, foreground-restore observer
├── CrashGuard.h / .m             # Signal-based crash protection for ds_run()
├── FileLogger.h / .m             # File + NSLog logging to device Documents/
├── LocationSpoofer-Bridging-Header.h
├── kexploit/
│   ├── darksword.h / .m          # Darksword kernel exploit
│   ├── offsets.h / .m            # Kernel offsets (auto-detect + t1sz_boot)
│   ├── utils.h / .m              # Kernel R/W helpers
│   ├── persistence.h / .m        # Credential persistence
│   ├── pe/
│   │   ├── vfs.h / .m            # VFS file read/write
│   │   ├── locationd.h / .m      # RemoteCall locationd plist reload
│   │   └── ...
│   └── TaskRop/
│       ├── RemoteCall.h / .m     # Remote code execution in target process
│       └── ...
├── headers/                      # libgrabkernel2, xpf, ChOma headers
└── lib/                          # libgrabkernel2.dylib, libxpf.dylib
```

---

## Disclaimer

This project is for **personal research and educational purposes only**. Using it to spoof location in apps that prohibit it may violate those apps' terms of service. The kernel exploit targets specific iOS versions — running it on unsupported firmware may cause instability.
