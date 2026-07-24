# Changelog — modernization fork

All notable changes made in this fork on top of
[`pranav-prakash/HardwareGrowler-NC`](https://github.com/pranav-prakash/HardwareGrowler-NC).
Target: **macOS 13+**, developed/tested on **macOS 26 (Tahoe), Apple Silicon (M-series)**.

## 2026-07-19

### New: colored "before → after" highlight in notification banners
- The custom notification banner (`GrowlApplicationBridge.m`) now automatically highlights,
  in an accent color (blue in light mode, teal in dark mode) and bold, the "new" half of any
  description line written as `"Label:\told → new"` — the reader's eye lands on what actually
  changed instead of having to re-read the whole line.
- This is a single change in the shared banner-rendering code, so any current or future
  notification that uses that line format benefits automatically, with no per-plugin banner
  work needed.
- Adopted by three monitors so far: Thermal (state transitions), Display (resolution/refresh
  rate/rotation/role changes), and Power (AC/battery source changes). Not adopted by
  Volume/USB/Thunderbolt/Bluetooth, whose connect/disconnect events are binary rather than
  "a value that had a previous value."

### New: Display Monitor — detects changes on an already-connected display
- Two new notifications, both independently toggleable in Preferences and both firing
  without requiring a disconnect/reconnect:
  - **Resolution / refresh rate / rotation changed** — e.g. picking a different resolution
    in System Settings, a TV renegotiating a lower refresh rate, or physically rotating a
    monitor. Shown as separate "old → new" lines per field that actually changed.
  - **Role changed** (Main / Extended / Mirrored) — e.g. switching a display from Extended to
    Mirrored (or back), or moving the menu bar to a different display. Switching to Mirrored
    commonly changes BOTH resolution and role in the same reconfiguration event (macOS
    renegotiates a shared resolution across both displays) — the two are reported as two
    separate, distinct notifications on purpose, each with its own toggle, rather than merged
    into one.
- Confirmed as expected behavior, not a bug: switching between "Entire Screen" / "Window or
  App" / "Extended Display" on an *already-connected* display does not fire a notification,
  because the physical link never actually drops across that transition (see "Known
  limitations" below for the full explanation).

### New: Power Monitor — "Check Now" and a minutes option for the Battery Health reminder
- Added a "Check Now" button next to "Check every" that reports Battery Health (cycle
  count / battery health %) immediately, without waiting for the configured interval (up to
  a month by default).
- The optional "Notify every" reminder can now be set in **minutes** as well as hours (a new
  unit dropdown), for anyone who wants a tighter reminder cadence than the 1–24 hour range
  allowed.
- The Battery Health Check notification's icon now reflects the Mac's actual current power
  status (charging level, battery level, or plugged-in) instead of a fixed "plugged in" icon.

### Improved: Thermal Monitor transition wording + a way to preview any state
- The "old → new" thermal-state line now uses short state names in the arrow (e.g.
  "Critical → Nominal") and only attaches the descriptive phrase ("performance significantly
  reduced", etc.) to the CURRENT state — previously the old state's description was shown
  too, which could misleadingly read as if the old, worse condition still applied right
  after the arrow said otherwise.
- Added an explicit "↓ Cooling down (improving)" / "↑ Warming up (worsening)" tag so the
  direction of a transition is unambiguous at a glance.
- Added a "Simulate Test Notification" control (Preferences → Thermal Monitor): two dropdowns
  (From/To) plus a button, letting any state-to-state transition be previewed on demand.
  Useful because many Macs (this one included, under sustained CPU stress) rarely or never
  reach Serious/Critical under normal/moderate load, so those notifications/icons would
  otherwise be very hard to ever actually see and verify.

## 2026-07-18

### New: experimental early physical-link detection for Display Monitor (off by default)
- Added an opt-in, off-by-default feature in Display Monitor's preferences: "Early
  physical-link detection (Experimental)", with a 1–10 second polling interval slider.
- Reads the macOS unified log via the public `OSLogStore` API (macOS 10.15+, no special
  entitlement needed — confirmed with a standalone unprivileged test binary) for the
  kernel's `DCPAVFamilyProxy`/`IOAVFamily` HDCP handshake messages, whose `ReceiverConnected`
  entry marks the moment a physical HDMI/DisplayPort link is established — before macOS
  assigns the display an arrangement (Extended/Mirror), which is where the normal
  `CGGetOnlineDisplayList`-based detection starts.
- Fires as its own separate notification ("Video Link Detected (Experimental)", note name
  `DisplayLinkDetected`), not merged into or confused with the authoritative "Display
  Connected" notification.
- Deliberately NOT the default detection path: this scrapes free-form kernel debug log text
  with no API stability contract (can silently break on any macOS update), requires
  continuous polling since `OSLogStore` has no live-streaming callback (real, ongoing
  CPU/battery cost while enabled), and only applies to Apple Silicon (`DCPAVFamilyProxy` is
  the M-series Display Co-Processor proxy). All of this is spelled out in-app (preferences
  pane warning text) and in README under "Experimental: early physical-link detection".
- Both the app-facing GUI text and README document every trade-off in detail per explicit
  request, since this is expected to need re-verification/re-tuning against future macOS
  releases if it's ever kept enabled long-term.

### New: Display Monitor (8th monitor plugin)
- Added `DisplayMonitor`, a new plugin reporting external display connect/disconnect,
  wired into the Xcode project the same way as the other 7 monitors (own `.hwgrowlmonitor`
  bundle target, `com.jensyleo.hg4mac.DisplayMonitor` bundle id).
- Detection deliberately uses `CGGetOnlineDisplayList` + `CGDisplayRegisterReconfigurationCallback`
  (CoreGraphics), **not** `NSScreen`/`NSApplicationDidChangeScreenParametersNotification`.
  Empirically verified that `NSScreen` only exposes displays AppKit can address a window to:
  a display connected while macOS puts it in Mirror mode does not get its own `NSScreen`
  entry at all (confirmed live — the AppKit notification fired, but `[NSScreen screens]`
  never changed size), while `CGGetOnlineDisplayList` correctly reflects it in both Mirror
  and Extended arrangements.
- Notification includes the display's name (`NSScreen.localizedName`) plus three
  individually toggleable fields (F33 pattern, same as USB/Thermal, all default on):
  resolution (with a Retina/scale-factor note when applicable), refresh rate, and role
  (Main / Extended / Mirrored).
- New icons: `Display-On`/`Display-Off` (notification) and `HWGPrefsDisplay` (sidebar),
  matching the existing flat icon style and exact system colors used by USB Monitor.
- Live-tested end to end with a real HDMI display through a USB hub: connect/disconnect
  detected correctly once macOS assigns the display an arrangement (Extended or Mirror).
  One edge case observed and closed: if the user dismisses macOS's own "how do you want to
  use this display" prompt without choosing an arrangement, the display has no
  `CGDirectDisplayID` yet and nothing is detectable — not an app or hub defect, just the
  normal state before macOS finishes negotiating the display.
- **Known limitation** (see README): the physical connection type (HDMI/DisplayPort/USB-C/
  Thunderbolt) and vendor/model via EDID are not obtainable through any public API on
  Apple Silicon — documented rather than worked around with a private/undocumented API.

### New: dedicated per-level notification icons for Thermal Monitor
- Replaced the "Device-Unstable" generic placeholder (previously reused for
  Serious/Critical, with Nominal/Fair falling back to the app icon) with 4 dedicated icons,
  one per `NSProcessInfoThermalState` level — `Thermal-Nominal`, `Thermal-Fair`,
  `Thermal-Serious`, `Thermal-Critical`. Each is the same thermometer glyph with a fill
  level proportional to severity (Nominal ~18% → Critical 100%, mirroring Power Monitor's
  charge-level ramp convention), plus a badge in the top-right corner that escalates in
  meaning: Nominal = green checkmark ("all good"), Fair = blue dash ("steady, still
  normal" — deliberately left neutral/undecorated in an earlier iteration, then given a
  blue accent per the user's request to visually associate it with "normal" rather than a
  warning), Serious = the same warning triangle already used for "Unstable device" bounce
  alerts, Critical = the same radioactive icon already used for "Disk Not Readable" — reuse
  chosen deliberately so severity reads consistently across the whole app, not just within
  this one monitor. Iterated live with the user via several published preview rounds before
  landing on the final set. Build 0 warnings, verified the 4 renditions compiled into the
  asset catalog and the app launches cleanly; forcing a real thermal-state transition to
  see the notification fire remains a pending manual test (see `TODO.md`).

### New: dedicated Thermal Monitor sidebar icon
- Replaced the temporary placeholder (no dedicated icon, sidebar row previously showed no
  image) with a proper flat icon matching the app's existing style: a thermometer with the
  same silhouette language as Power Monitor's battery icon (flat gray outline, no
  gradients/shadows), a solid red bulb, 4 stacked red segments in the tube (kept as 4
  distinct sections — one per thermal level — but all the same red, per the user's final
  design choice), and tick marks for readability as a thermometer. Iterated live with the
  user via published previews (taller tube, smaller bulb, single-color segments) before
  landing on the final version. New `HWGPrefsThermal.imageset`. Verified live in the
  Preferences sidebar alongside the other 6 monitor icons.

### Changed: Power Monitor icon color order
- Reordered the battery icon's 4 blocks from green→yellow→orange→red (low-to-high, left to
  right) to red→orange→yellow→green (high-to-low, left to right), per the user's request.

### New: configurable notification fields for Volume Monitor (F33)
- Volume Monitor's "Volume Mounted" notification can now show, each independently
  toggleable from Preferences → Modules → Volume Monitor (all default on): the mount path,
  the file system type, and the volume's total size. Completes the F33 per-field pattern
  already applied to Network/Power/USB/Bluetooth/Thunderbolt — Volume was the only
  remaining monitor without it.
- File system type and size are read via a plain `statfs()` syscall (the same mechanism
  already used elsewhere in this file for readable-sibling detection) — never
  `NSFileManager`/`NSWorkspace`, so this doesn't touch TCC-gated file access. Mount-only:
  an unmounted path has no live filesystem left to stat.
- The new checkboxes appear ABOVE the existing "Ignored Drives" ignore-list picker (a real
  nib, unlike the other monitors' plain programmatic panes), using the same frame-based
  layout approach as Power Monitor — verified this xib's own content has no baked-in blank
  space (unlike PowerMonitorPrefs.xib), so no extra care was needed there.
- Verified live end-to-end: created and mounted a real disk image, confirmed the
  notification banner shows "Click to open" / mount path / "File system: apfs" /
  "Size: 10,4 MB" exactly as configured.

### Fix: checkboxes silently hidden behind the "Ignored Drives" list (Volume Monitor prefs pane)
- After moving "Ignored Drives" below the new checkboxes, the checkboxes stopped rendering
  entirely — confirmed via Accessibility introspection that they still existed (right
  element count, right approximate position) but were completely covered. Root cause: the
  ignore-list's nib-authored NSTableView/NSScrollView is pinned to its container's edges via
  Auto Layout, and that content silently grows taller than the nib's declared 195pt at
  runtime. With the list positioned at the TOP of the pane (its original position) any
  overflow simply extended above the pane's own bounds and got clipped away by the
  surrounding container — invisible, never a problem. With the list moved to the BOTTOM,
  that same overflow grows UPWARD from its fixed bottom edge and silently covers whatever
  sits above it. Fixed by wrapping the ignore-list view in a fixed-size container with
  `wantsLayer = YES` / `layer.masksToBounds = YES`, hard-clipping it to its intended
  202×195 box regardless of what its internal Auto Layout wants to do — decouples the
  checkbox layout math from the list's internal content growth entirely.

### Fix: Volume Monitor prefs pane floating with a gap above it (same root cause as the historical Bluetooth bug)
- Same failure mode documented earlier for Bluetooth's "gap above Notification fields on
  first open": AppDelegate force-resizes whatever `preferencePane` returns to match the
  container's real frame (`[newView setFrameSize:...]`, via `containerViewFrameDidChange:`).
  First fix attempt wrapped the content in a plain `NSScrollView` (matching Power Monitor's
  pattern) — this stopped the pane from floating/overflowing, but a **second**, related
  symptom remained: a non-flipped document view, when shorter than the scroll view's
  visible clip area, gets anchored to the BOTTOM of the clip by AppKit's default behavior,
  leaving the slack as a gap ABOVE the content instead of below it — exactly what the user
  reported ("Notification fields debe aparecer más arriba"). Final fix: made the document
  view a FLIPPED `NSView` subclass (`HWGVolumeFlippedContentView`, same pattern as
  NetworkMonitor's existing `HWGFlippedContentView`) and rebuilt the layout top-down
  (cursor starts at 0, grows downward) instead of the previous bottom-up/pre-computed-height
  approach — a flipped document is anchored to the TOP of the clip by default, and as a
  bonus this also removes the whole class of "hand-computed total height drifts from the
  real content extent" bugs (height is simply wherever the cursor ends up). Verified live:
  content flush at the top on first open AND after switching away and back to the tab, no
  unnecessary scrollbar.

### New: Battery health check (Power Monitor, candidate #8)
- Power Monitor now reads `CycleCount` and computes battery health % (`AppleRawMaxCapacity`
  ÷ `DesignCapacity`) straight from the IOKit `AppleSmartBattery` registry — `IOPowerSources`
  (used elsewhere in this file) doesn't expose either. Verified against real `ioreg -c
  AppleSmartBattery -r` output; the top-level `MaxCapacity` key is a self-calibrating 0–100
  value that resets near 100 after recalibration events, so it's not used for long-term
  health — the raw mAh figures are. When present, `DesignCycleCount9C` (the manufacturer's
  rated cycle budget) is shown alongside the cycle count for context.
- Reported as its own periodic notification ("Battery Health Check"), separate from the
  existing minutes-based status refire — health/cycles change on a days/weeks/months
  timescale, not a minutes one. New Preferences → Modules → Power Monitor section:
  - Two independent checkboxes ("Cycle count", "Battery health %") — if both are off, the
    check is skipped entirely (nothing to report).
  - A slider (1–12) + unit popup (Days/Weeks/Months) controlling how often it fires;
    default 1 month. Persisted as a last-checked timestamp (not a running timer), so the
    configured interval is honored correctly across app relaunches/sleep, and a desktop Mac
    with no battery simply never fires (checked once per hour internally, cheaply, but only
    acts once the real interval has elapsed).
  - A child "Notify every" control (checkbox + hours slider, 1–24h, off by default):
    an optional, more frequent reminder of the same cached numbers while waiting for the
    next full check — independent cadence from "Check every" above, in hours instead of
    days/weeks/months.

### Fix: unit popup button's arrow/chevron not clickable (Power Monitor prefs pane)
- The "Days/Weeks/Months" popup (added for the battery health check above) silently
  extended past the right edge of its containing view — a subview whose frame exceeds its
  superview's bounds is only clickable in the portion still within those bounds, so only
  the popup's text (further left, in-bounds) responded to clicks; the arrow/chevron at its
  far right edge did not. Fixed by widening the prefs pane's internal layout width (380 →
  460) so every control in the "Check every"/"Notify every" rows fits fully within bounds.

### Fix: phantom scroll space in Power Monitor prefs pane
- `totalHeight` (the hand-computed height reserved for the pane's scrollable content) was
  over-reserving space: it counted `PowerMonitorPrefs.xib`'s full declared height (204pt)
  even though the very next line already skips ~97pt of that xib's own baked-in blank space
  and resumes from its real content bottom (a documented, intentional trick — see the
  comment above `xibContentBottomLocal`). Since content is anchored top-down, that
  unaccounted-for surplus always landed as dead space at the very BOTTOM of the pane, which
  in turn made the scroll view believe there was more content to scroll to — an empty,
  unnecessary scrollbar with nothing under it. Fixed by reserving exactly the amount of
  space the xib section actually consumes (`xibContentBottomLocal + 16`) instead of its full
  declared height, so the pane's real content ends flush with its bottom padding and no
  scrollbar appears.

### New: Thermal Monitor — 7th monitor plugin (F34 candidate #3)
- New loadable plugin `ThermalMonitor.hwgrowlmonitor`, separate from Power Monitor by
  design (battery state and thermal/throttling state shown independently to the user),
  though it reads from the same system power/process-info APIs (`NSProcessInfo`) as Power
  Monitor.
- Detects the Mac's thermal state via the public `NSProcessInfo.thermalState` API (4
  levels: Nominal/Fair/Serious/Critical) and `NSProcessInfoThermalStateDidChangeNotification`
  — no polling, no private APIs.
- Per-level notification toggles in Preferences → Modules → Thermal Monitor: notify when
  **entering** Nominal/Fair/Serious/Critical, each independently switchable. Defaults:
  Serious and Critical **on** (actionable — performance is being reduced), Nominal and Fair
  **off** (avoid noise on "back to normal"). The level is tracked internally regardless of
  the toggles, so enabling one later doesn't miss the next real transition.
- Icon: **temporary** — reuses the existing "Device-Unstable" warning triangle for
  Serious/Critical, no dedicated icon yet for Nominal/Fair (falls back to the app icon).
  Real per-level icons are pending from the user (4 PNGs).
- Considered alongside 2 other F34 candidates and **deferred instead of implemented**:
  Sleep/Wake and Screen Lock/Unlock — both decided to not fit the app's philosophy of
  reporting hardware changes while the Mac is in active use; Screen Lock additionally has
  no public/documented API. See `CHANGELOG`/project notes for the full F34 candidate list.


### Fixed: Wi-Fi signal-change detection appeared delayed by up to 2 poll cycles
- Confirmed via user testing (walking between two known-different signal spots, once and
  waiting): a real signal-bar change was only reported after the poll timer fired *twice*,
  regardless of the configured poll interval (12s → 2 cycles = 24s; 5s → 3-4 cycles =
  15-20s) — the constant factor pointed at a fixed ~20s delay rather than the interval
  itself.
- Root cause: `pollWifiSignal:`'s hardcoded 20-second cooldown between two
  "Wi-Fi Signal Changed" notifications (meant to stop a value hovering at a bar threshold
  from spamming) was also blocking a legitimate second, real change that followed shortly
  after a first one — exactly the test pattern above (settle at 100% → notified → move to
  a weaker spot within the next 20s → blocked until the cooldown expired).
- Also baselines the signal bar level the moment Wi-Fi connects (using the RSSI already
  available at that point) instead of waiting for the poll timer's first tick to do it —
  minor secondary fix, doesn't apply if Wi-Fi was already connected before the app started
  polling.
- Made the cooldown user-configurable: a new slider in Preferences → Modules →
  Network Monitor → Wi-Fi ("Minimum time between signal-change notices"), 0–60 s, default
  **10 s** (down from the prior hardcoded 20 s), 0 = disabled.

## 2026-07-17

### New: per-field notification settings for USB, Bluetooth, and Thunderbolt
- Extends the per-field toggle pattern already used by Network/Power Monitor to the three
  monitors below. Every field is independently switchable from Preferences → Modules → the
  relevant monitor, all on by default:
  - **USB**: manufacturer/product name, vendor/product ID, speed, device class.
  - **Bluetooth**: device type, paired state, MAC address.
  - **Thunderbolt**: vendor/product ID, device class.
- Fixed a layout bug hit while building this: the first-ever time the Preferences window is
  opened in a session, the pane for whichever monitor is selected by default (Bluetooth,
  alphabetically first) showed its "Notification fields" controls displaced far below where
  they belonged, with a large empty gap above them. Root cause, found via Accessibility
  introspection of the live app (comparing real on-screen element positions in the broken
  vs. self-corrected state): the pane is sized to match its container's frame at the moment
  it's first inserted, but the container itself is *not* at its final on-screen size yet at
  that point — it grows once the window's sidebar/detail split actually resolves. Every
  other monitor's pane only ever gets built after the user manually clicks its row, by which
  time the container is already at its real size, so they never hit this. Fixed by observing
  `NSViewFrameDidChangeNotification` on the container and re-syncing the currently-displayed
  pane's frame whenever it actually changes, instead of assuming the frame at insertion time
  is final.

### New: richer notification detail for USB, Bluetooth, and Thunderbolt
- These three monitors previously showed only the device name. Added, using public/
  documented APIs only:
  - **USB**: manufacturer and product name, vendor/product ID, USB generation/speed
    (1.0/1.1/2.0/3.x), and a human-readable device class (Mass Storage, HID, Hub, Audio,
    etc. — from the USB-IF's published base class table), all read via
    `IORegistryEntryCreateCFProperty` the same way the existing hub detection already
    reads `bDeviceClass`.
  - **Bluetooth**: a device type label (Keyboard, Mouse/Trackpad, Headphones, Hands-Free,
    etc. — from `IOBluetoothDevice`'s public `deviceClassMajor`/`deviceClassMinor`), paired
    state, and MAC address. Battery level remains intentionally excluded — no public,
    documented API exposes it for an arbitrary paired accessory.
  - **Thunderbolt**: vendor/device ID and a device type label (Storage Controller, Display
    Controller, Bridge/Dock, etc. — from the PCI-SIG's published class-code table), read
    from the same `IOPCIDevice` registry entry as the existing device name. True
    Thunderbolt-generation/link-speed info (TB3/TB4/USB4) has no public API and was
    deliberately left out.
  - None of this extra detail is shown on disconnect — registry properties are frequently
    unreadable from an already-terminating device by the time that callback fires.
- Confirmed working: USB flash drive and a multi-chip USB-C hub/dock (each internal chip —
  LAN, card reader, USB 2.0/3.0 hub controllers — correctly reported separately with its
  own manufacturer/VID:PID/speed/type, which is expected since each enumerates as its own
  USB device), and a Bluetooth keyboard (showed "Keyboard" type correctly). Thunderbolt
  untested — no genuine Thunderbolt hardware available.

### New: per-field notification settings for Power Monitor
- Every field in the power/battery notification body is now independently toggleable from
  Preferences → Modules → Power Monitor: power source type (Battery/UPS/Unknown), charge
  state (Charging/Finishing/Charged), battery percentage, and time remaining/to-charge. All
  default on, matching prior always-on behavior. Added as a new "Notification fields"
  section below the existing refire-settings panel (that nib was left untouched) rather
  than converting the whole pane to a programmatic layout.
- Fixed a layout bug hit while building this: `PowerMonitorPrefs.xib`'s own content only
  occupies the top half of its declared frame (its lowest control's bottom edge sits well
  above the frame's actual bottom, with unused space baked in below it) — stacking new
  content from the frame's full height left a large gap. Found via Accessibility
  introspection of the live running app (queried real on-screen element positions rather
  than guessing from screenshots) and fixed by resuming the layout from the xib's actual
  content bottom instead.

## 2026-07-16

### New: Wi-Fi band, generation, and security in the connect notice
- "AirPort Connected" now also shows the channel band (2.4/5/6 GHz), the Wi-Fi generation
  (Wi-Fi 4/5/6/6E/7, derived from the active 802.11 PHY mode — 6GHz-band 802.11ax is
  labeled "Wi-Fi 6E" per the consumer naming, not plain "Wi-Fi 6"), and the network's
  security type (Open, WEP, WPA/WPA2/WPA3 Personal or Enterprise, OWE) via CoreWLAN
  (`CWInterface.wlanChannel`/`activePHYMode`/`security`) — none of which require Location
  permission (unlike SSID/BSSID). Configurable: a new checkbox in Preferences → Modules →
  Network Monitor ("Show band, generation, and security in the Wi-Fi connect notice"),
  on by default. Label formatting uses a single tab after each field for consistent
  left alignment.

### Fixed: Ethernet link detection reverted from NWPathMonitor back to raw link state
- A recent "proactive modernization" had switched wired-link detection from the legacy
  `SCDynamicStore` `.../Link` key to `NWPathMonitor`. This introduced real regressions:
  an interface with a cable plugged in but no DHCP-assigned IP never reported "Network
  Link Up" at all (NWPathMonitor only lists an interface once it has a usable network
  path — not just carrier/link), and even with a static IP, reporting could lag by many
  minutes waiting for the path to be judged "satisfied" — vs. instant reporting in System
  Settings, which reads the raw link state directly. Reverted: wired Link Up/Down is now
  detected via the same raw `.../Link` `SCDynamicStore` key (watched via a pattern across
  every interface, not a fixed literal key), independent of DHCP/IP/routing — confirmed
  by log to fire instantly in both the no-DHCP and reconnect scenarios that previously
  failed or lagged. `NWPathMonitor`/`Network.framework` usage and its now-unused framework
  reference were removed from the project entirely.
- Watching every interface's link key also picked up `en0` (WiFi on Apple Silicon — already
  reported separately via "AirPort Connected") and `awdl0` (AWDL, used by AirDrop/Handoff/
  Continuity — flaps constantly in the background). Filtered to interfaces `SCNetworkInterface`
  itself classifies as Ethernet (the same registry System Settings' Network pane reads),
  which correctly includes USB/Thunderbolt-Ethernet adapters without hardcoding interface
  name prefixes.
- **Investigated but NOT a bug**: a report that the app never distinguishes full- vs.
  half-duplex, and always reports "full-duplex" even when a switch is known to force
  half-duplex. Confirmed via raw `ifconfig <if> | grep media` (the same OS-level data our
  code reads via `SIOCGIFMEDIA`, no app code involved) that **macOS itself** also reports
  "full-duplex" in this situation, while the switch's own management console reported
  half-duplex — a mismatch between the actual PHY negotiation and what the network
  adapter's driver surfaces to the OS, outside this app's reach. The app's duplex-reading
  code is confirmed correct (matches `ifconfig` exactly); this needs testing across other
  adapters/switches to see if it's specific to one driver/chipset.

### New: per-field notification settings for Network Monitor, in Wi-Fi / Ethernet / IP tabs
- Every individual piece of information Network Monitor can show is now independently
  toggleable from Preferences → Modules → Network Monitor, organized into 3 tabs:
  - **Wi-Fi**: SSID, BSSID, band, generation, security type (all default on), plus the
    existing signal-check-interval slider.
  - **Ethernet**: interface name, speed, mode/duplex (all default on), and a new toggle to
    also report Wi-Fi's own link and AWDL/AirDrop events (default off — these are normally
    filtered out as noise, see the link-detection fix above).
  - **IP**: IPv4 address, IPv6 address, gateway, the "(non-routable)" tag, and whether to
    use friendly interface names instead of raw BSD names (all default on).
  All defaults match prior always-on behavior, so no existing notification content changes
  unless a box is unchecked. The "released" transition in "IP Addresses Updated" is now
  decided from actual address presence rather than the (now potentially empty, depending on
  toggles) displayed text, so hiding every IP field doesn't misreport a live connection as
  disconnected.
- Fixed a related, longer-standing cosmetic bug while adding this panel: the Preferences
  window's "Modules" box didn't grow when the window was resized, for any monitor — two
  `autoresizesSubviews="NO"` flags in `MainMenu.xib` (on the General/Modules tab switcher
  and the per-monitor settings box) were blocking the resize from propagating down.

### Repository cleanup
- Removed `NOTICE.md` (content was already duplicated in the README's Credits & license
  section) and `SFSymbols-Migration-Notes.md` (unimplemented internal planning notes) —
  only `README.md` and `CHANGELOG.md` remain as markdown files.
- Stopped tracking `xcuserdata/` (Xcode's local user state), which had been committed
  before `.gitignore` excluded it.
- Corrected two stale README claims: the menu-bar icon is a colored image (not a
  template), and the project builds with 0 warnings (not 1). Added a Known Limitations
  section documenting the full/half-duplex discrepancy above.
