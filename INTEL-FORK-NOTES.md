# Intel fork notes

This file documents everything specific to **this** fork (`HG4MAC-INTEL`, x86_64-only)
that does **not** apply to the upstream Apple Silicon build
([`jensyleo/HG4MAC`](https://github.com/jensyleo/HG4MAC)). Kept in its own file (not
`README.md`/`CHANGELOG.md`) so that merging upstream changes doesn't create conflicts here.

## Download / update

Prebuilt `.zip`: see [Releases](https://github.com/jensyleo/HG4MAC-INTEL/releases/latest)
— download it, unzip, drag `HG4MAC.app` into `/Applications` (replacing the old one if
updating). Ad-hoc signed, not notarized: right-click → **Open** on first launch to bypass
Gatekeeper's "unidentified developer" warning.

**If "Start at Login" was on:** after updating to a new build, check System Settings →
General → Login Items & Extensions — you may see a duplicate `HG4MAC.app` entry left over
from the previous build. See "Known limitation: Start at Login" below for why, and the
confirmed step-by-step fix (remove all duplicates, relaunch, reboot to verify).

**Every release from here on should ship the same way** — Debug builds during development,
but the artifact actually handed to a user (including "future me on this same Mac") should
always be a Release-configuration build packaged as a GitHub Release, same as upstream does
it. To cut one:

```sh
# 1. Build Release (the NetworkMonitor SDK workaround from README's "Sandbox build
#    caveat" still applies on this machine's older Xcode/SDK — patch, build, revert)
xcodebuild -project HardwareGrowler.xcodeproj -scheme HardwareGrowler \
           -configuration Release -arch x86_64 clean build

# 2. Package (adjust the DerivedData path / version tag)
ditto -c -k --sequesterRsrc --keepParent \
      "$(xcodebuild -showBuildSettings -configuration Release 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/HG4MAC.app" \
      HG4MAC-INTEL-vX.Y.Z.zip

# 3. Tag and publish
git tag -a vX.Y.Z-intel -m "..."
git push origin vX.Y.Z-intel
gh release create vX.Y.Z-intel HG4MAC-INTEL-vX.Y.Z.zip \
  --repo jensyleo/HG4MAC-INTEL --title "..." --notes-file notes.md
```

## Build

- `xcconfig/Common.xcconfig`: `ARCHS`/`VALID_ARCHS` forced to `x86_64` (upstream ships
  `arm64 x86_64` universal).
- `CODE_SIGN_IDENTITY = "-"` (ad-hoc) on every target — see "Start at Login" below for why
  this matters beyond just letting local builds run.

## Known limitation: "Start at Login" and duplicate Login Items entries

**Symptom observed:** toggling "Start HG4MAC at Login" ON worked, but after quitting and
relaunching the app (in practice: after rebuilding and reinstalling to `/Applications`
during development), the toggle would silently read back OFF — and System Settings →
Login Items would accumulate a new, separate "HG4MAC.app" entry each time, never
replacing the old one.

**Root cause:** this build has no stable code-signing identity. Ad-hoc signing
(`CODE_SIGN_IDENTITY = "-"`) has no Developer ID / Team Identifier — every rebuilt binary
gets a **different code hash (cdhash)**. `SMAppService`/Background Task Management
identifies a login item by that hash when there's no stable Team ID to key off instead, so
each rebuild is indistinguishable from "a completely different app" to the system —
confirmed via `sfltool dumpbtm`, which showed two `com.jensyleo.hg4mac` entries with two
different cdhash values after normal iterative rebuild+reinstall cycles.

This also explains the "reads back OFF" half of the symptom:
`SMAppService.mainAppService.status` reflects the state for the **currently running
binary's own identity** — not "is there any registered entry anywhere for this bundle
ID." A fresh rebuild's binary is, as far as the system is concerned, a login item that
was simply never registered, regardless of what the previous build's entry says.

**Fixes applied (`HardwareGrowler/AppDelegate.m`):**

1. `-setStartAtLogin:` checks `SMAppService.mainAppService.status` before calling
   `register`/`unregister`, and skips the call if already in the desired state. This stops
   the app from adding a second entry for the *same* running binary (e.g. re-opening
   Preferences, or the auto-heal below re-confirming a state that's already correct)
   — it cannot by itself prevent a **genuinely new rebuild** from registering as a new
   entry, since that new binary really is unregistered from the system's point of view.

2. **Auto-heal, in both `-awakeFromNib` (Preferences) and
   `-applicationDidFinishLaunching:` (every launch):** the user's actual intent — "I
   turned this on" — is tracked via the persisted `OnLogin` default, independently of
   whatever `-isRegisteredAtLogin` currently reports for this specific binary. If intent
   says ON but the current binary's status isn't Enabled (exactly the post-rebuild
   scenario above), the app silently re-registers itself right then, instead of leaving
   the toggle looking OFF until the user notices and re-clicks it. Verified live via
   `log stream`: a rebuilt-and-relaunched binary re-asserted its registration
   (`HWG setStartAtLogin: YES` → `Register ... error: 0`) with no user interaction.

**What this does NOT fix:** the auto-heal keeps the *current* binary's registration
correct automatically, but it has no way to find or remove an *orphaned* entry left by a
previous, differently-hashed build — there is no public API to enumerate or delete other
apps' (or other cdhash's) Background Task Management entries; that database is only
inspectable via `sfltool dumpbtm` (read-only, needs no special privilege) and editable by
the user through **System Settings → General → Login Items & Extensions** (select the
stale entry, press `–`).

**The actual root-cause fix** — a stable signing identity — needs either:
- A free Xcode "Personal Team" (sign in with any Apple ID under Xcode → Settings →
  Accounts, then set `CODE_SIGN_IDENTITY` to `Apple Development` and pick that team) — this
  gives a consistent Team Identifier across rebuilds without paying for the Apple Developer
  Program, though the resulting signature still isn't suitable for distributing outside
  this Mac (no notarization).
- A real paid Developer ID certificate, if the app is ever meant to be distributed/
  notarized for other users' Macs.

Neither has been set up for this fork as of this writing — builds remain ad-hoc-signed,
so a genuinely new rebuild can still leave one orphaned Login Items entry behind for the
user to clean up manually. The auto-heal above only guarantees the toggle stays honest and
functional across that; it doesn't do the cleanup.

**⚠️ TODO — open problem, not just a known quirk to live with:** installing a new version
**without first uninstalling the previous one** currently requires the user to manually
remove the duplicate Login Items entry every time (see recovery procedure below). This is
a real gap in the update experience — left unfixed intentionally for now (2026-07-29), but
tracked here for whoever picks this up next.

**Root cause, found by digging through this fork's own history (not a guess):** this app
used to handle "Start at Login" completely differently, and it never duplicated. Commit
`f0d865e` ("Modernize HardwareGrowler into HG4MAC for macOS Tahoe / Apple Silicon") replaced:

```objc
SMLoginItemSetEnabled(CFSTR("com.growl.HardwareGrowlerLauncher"), enabled)
```

with `SMAppService.mainAppService`. The old API identifies the login item by a **constant
bundle identifier** (`com.growl.HardwareGrowlerLauncher`, a tiny helper app embedded at
`Contents/Library/LoginItems/` — the `HardwareGrowlerLauncher` Xcode target still exists in
this project, just unused for this purpose now) that just launches the main app. Since that
identity never depends on the main app's binary at all, rebuilding it was never able to
duplicate anything. `SMAppService.mainAppService` registers the main app directly — no
helper — which is simpler, but without a stable signing identity it falls back to
identifying the login item by **code hash (cdhash)**, which is exactly what changes on
every ad-hoc rebuild. That's the actual mechanism behind the duplicate.

**Three ways to actually fix this** (not yet decided/implemented as of 2026-07-29):

- **(A) Revert to `SMLoginItemSetEnabled` + the launcher helper** — literally the code this
  fork used to have (see `f0d865e` above for the exact diff to reverse), confirmed to never
  duplicate regardless of signing. Deprecated since macOS 13
  (`__OSX_DEPRECATED(10.6, 13.0, "Please use SMAppService instead")`, confirmed present and
  functional in the current SDK — Tahoe 26 — as of this writing), so this carries some risk
  Apple removes it outright in some future macOS, with no announced date. Lowest effort of
  the three.
- **(B) Stable signing identity** (free Xcode Personal Team or paid Developer ID, both
  described above) — keeps the modern `SMAppService` API Apple actually recommends, no
  deprecation risk. Requires signing in with an Apple ID in Xcode once, and never changing
  signing identity across future builds.
- **(C) Manual `LaunchAgent` plist** (`~/Library/LaunchAgents/com.jensyleo.hg4mac.plist`,
  `launchctl bootstrap`/`launchctl load`, `Label` as the stable identity) — this app's own
  code already has a near-identical fallback for pre-macOS-13 in the same `f0d865e` diff, so
  the pattern is already proven to exist here. Doesn't need a helper app or code signing at
  all, but may not surface as a user-manageable entry in System Settings → Login Items &
  Extensions the way `SMAppService`-registered items do on modern macOS — needs live
  verification before relying on it.

(A) is the closest match to "this used to just work" — it's a revert, not new design — but
carries the deprecation risk. (B) is the Apple-recommended long-term answer. Pick based on
how much you trust "deprecated but present in Tahoe" to keep holding.

**Confirmed manual recovery procedure (2026-07-29), needed once per NEW rebuild that
replaces the running app:**

1. Open **System Settings → General → Login Items & Extensions**.
2. Under "Open at Login," remove **every** `HG4MAC.app` entry you see (there may be 2+ —
   select each, press `–`). The System Settings list can also show a stale/duplicate entry
   that doesn't reflect `sfltool dumpbtm`'s actual state until the pane is closed and
   reopened — always re-check the list fresh (quit System Settings, reopen it) before
   concluding there are still duplicates, rather than trusting a pane left open from before.
3. Relaunch `HG4MAC.app`. The auto-heal (see above) re-registers it automatically — no
   need to touch the "Start at Login" toggle by hand.
4. Quit and reopen the app a few times to confirm no new duplicate reappears.
5. Reboot the Mac as a final check — the single registration should survive a real login,
   not just an app relaunch.

Confirmed working end-to-end by the user after a real reboot. Do this after installing
**any** new build (a fresh compile, or a `.zip` from a new Release) that replaces an
already-registered `HG4MAC.app` — not just once ever. Since each rebuild's code hash
differs (see root cause above), the stale-entry step is expected to recur per rebuild
until a stable signing identity is set up.

## Other Intel-specific fixes

- **DisplayMonitor** — "Early physical-link detection (Experimental)" reads
  `DCPAVFamilyProxy`/`IOAVFamily` kernel log subsystems that only exist on Apple Silicon's
  Display Co-Processor driver. The checkbox now detects the host architecture at runtime
  (`sysctlbyname("hw.optional.arm64", ...)`, not a compile-time check — this x86_64 binary
  could still run under Rosetta on an Apple Silicon Mac, where the feature would actually
  work) and disables itself with an explanatory notice on Intel hardware, instead of
  silently doing nothing when toggled on.
- **AudioMonitor** — the three CoreAudio property-listener blocks (devices, default
  output, default input) weren't being removed on `dealloc` (a `nil` block was passed to
  `AudioObjectRemovePropertyListenerBlock` instead of the original block references) —
  fixed by retaining each block in a property and passing that same reference to both add
  and remove.
- **BluetoothMonitor** — the per-device disconnect notification returned by
  `registerForDisconnectNotification:selector:` wasn't retained anywhere, so ARC could
  deallocate it before the disconnect ever fired — fixed by keeping a
  address-string-keyed dictionary of them, unregistered both on disconnect and in
  `dealloc`. Also switched a `dispatch_after` block from capturing `self` strongly to
  `weakSelf`, matching the pattern used elsewhere in the same file.
- **GrowlApplicationBridge** (`GrowlStub/`) — `_useCustomBanner` (a static BOOL read from
  `-notifyWithTitle:...:`, which hardware monitors can call from IOKit/CoreAudio/
  CoreBluetooth callback threads) was written from an authorization completion handler
  with no guaranteed thread — both the read and the write are now dispatched onto main.
- **AppDelegate** — `-requestAllPermissions` created a `CBCentralManager` with
  `delegate:nil` to trigger the Bluetooth permission prompt; without a real delegate,
  `-centralManagerDidUpdateState:` (which much of `CBCentralManager`'s behavior depends on)
  isn't guaranteed to fire, so the prompt wasn't reliable. `AppDelegate` now conforms to
  `CBCentralManagerDelegate` and is its own delegate (no-op implementation).
- **HWGrowlPluginController** — every read/mutation of the shared `plugins`/`notifiers`/
  `monitors` arrays is now wrapped in `@synchronized(self)` (with snapshot copies where the
  enumerated block calls back into arbitrary plugin code, so the lock is never held across
  a call of unknown duration). This wasn't an observed live crash — all 12 monitors
  currently dispatch their callbacks to the main thread explicitly — but nothing enforces
  that for monitors added in the future, and this is the array `notifyWithName:...:`
  enumerates from whatever thread a plugin calls it from.

## eGPU detection — untested opportunity, not a bug

`ThunderboltMonitor`'s eGPU detection (PCI Display Controller class code heuristic) could
never be tested with real hardware by the upstream author, because **Apple Silicon Macs
don't support eGPUs at all**. This Intel Mac is the first place this feature can actually
be exercised end-to-end. The upstream README already documents that *disconnect* detection
often fails (an IOKit registry-timing limitation, not a code bug) — if you have a real
eGPU, testing connect/disconnect here would be genuinely new information, not just
re-confirming something already known to work.
