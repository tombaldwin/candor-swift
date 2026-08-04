# candor spec extension: `privacy` — Apple privacy-sensor effects

**Extension `privacy/1`.** A candor **spec extension** (candor-spec SPEC.md §"Versioning policy",
the engine-extensions clause): an ecosystem-specific effect surface led by the motivated engine
(candor-swift), written spec-first with the same rigor as the main document. It MAY be promoted into
the main spec as a shared rung, or adopted verbatim by another engine (the Android/JVM and browser/ts
analogs are the obvious future adopters). It never holds the shared code-engine floor back, and a
floor claim never speaks for it.

## Why

Apple's **privacy manifests** (`NSPrivacyAccessedAPITypes`, the App-Store `PrivacyInfo.xcprivacy`
declaration) demand exactly what candor computes from code: which sensitive capabilities the code
actually reaches, *including transitively through dependencies*. Today a `CLLocationManager` call is
uncovered — DISCLOSED in the §7 ledger, invisible to the report. A real app's ledger already names the
demand (`UserNotifications`, `MapKit` in an uncovered list). Turning these into first-class effects
makes them **gate-able** (`deny Location outside services/`), **watchable** (a `gains`/`origin` alarm:
"a dependency bump added a `Camera` reach"), **tour-able** (a benign-named helper reaching `Location`
three hops down — the §3.1 surprising-reach shape), and enables the product surface: **generate or
verify a privacy manifest from code-level truth**.

## The effect vocabulary (`privacy/1`)

| effect | meaning | first-wave sources (Apple frameworks) |
|---|---|---|
| `Location` | device location | CoreLocation (`CLLocationManager`, `CLLocationUpdate`), MapKit user-tracking (`MKUserTrackingMode`) |
| `Camera` | camera capture | AVFoundation (`AVCaptureDevice` video, `AVCaptureSession`), `UIImagePickerController` camera source |
| `Mic` | microphone capture | AVFoundation (`AVCaptureDevice` audio, `AVAudioRecorder`, `AVAudioEngine.inputNode`) |
| `Contacts` | the address book | Contacts / ContactsUI (`CNContactStore`, `CNContactPickerViewController`) |
| `Photos` | the photo library | Photos / PhotosUI (`PHPhotoLibrary`, `PHAsset`, `PHPickerViewController`) |
| `Notify` | user-attention / notifications | UserNotifications (`UNUserNotificationCenter`) |

### Second wave (`privacy/2`, 2026-08-04)

The first wave covered six sensors, which was not enough to answer the question the product surface asks.
Measured on a real app: its `Info.plist` declares `NSMotionUsageDescription` and two HealthKit keys, and
`privacy-manifest --verify` said **nothing about them in either direction** — neither required nor flagged
as unused — because the effects did not exist. An `exit 0` meaning *"the six I model are declared"* reads
as *"your plist is right"*, which is the absence-is-a-claim shape the main spec closed at ⟨0.26⟩.

| effect | meaning | sources (Apple frameworks) |
|---|---|---|
| `Health` | HealthKit samples | `HKHealthStore`, the sample/observer/statistics/anchored queries, workout sessions and builders |
| `Motion` | motion & fitness sensors | CoreMotion (`CMMotionManager`, `CMPedometer`, `CMAltimeter`, `CMMotionActivityManager`, `CMHeadphoneMotionManager`, `CMSensorRecorder`) |
| `Calendar` | the user's calendars | EventKit (`EKEventStore` — ambiguous, see below; `EKEventEditViewController`, `EKCalendarChooser`) |
| `Reminders` | the user's reminders | EventKit (`EKEventStore` — ambiguous, see below) |
| `Bluetooth` | BLE scanning / advertising | CoreBluetooth (`CBCentralManager`, `CBPeripheralManager`) |
| `Speech` | speech recognition | Speech (`SFSpeechRecognizer`, the recognition requests) |
| `Biometrics` | Face ID / Touch ID | LocalAuthentication (`LAContext`) |
| `MediaLibrary` | the user's Apple Music / media library | MediaPlayer (`MPMediaLibrary`, `MPMediaQuery`, `MPMusicPlayerController`, `MPMediaPickerController`) |
| `HomeKit` | home accessories | HomeKit (`HMHomeManager`, `HMAccessoryBrowser`) |
| `Tracking` | App Tracking Transparency (IDFA) | AppTrackingTransparency (`ATTrackingManager`) |
| `NearbyInteraction` | UWB ranging | NearbyInteraction (`NISession`) |
| `Siri` | Siri authorization / donation | Intents (`INPreferences`, `INVoiceShortcutCenter`) |

**Value types that merely carry an already-taken reading are excluded**, on the `CLLocation` precedent —
`HKQuantity`, `CMDeviceMotion`, `CMAccelerometerData`, `EKEvent`, `CBUUID`. Holding a reading is not taking
one.

**`LocalNetwork` is deliberately absent.** `NSLocalNetworkUsageDescription` is real, but the reach cannot be
separated from ordinary `Net` by type: `NWBrowser`/`NWConnection` serve both, and the key travels with a
`NSBonjourServices` entitlement this engine does not read. Guessing it would fabricate on every networking
app. It stays uncovered and disclosed, like any other unmodelled surface.

**Speech is not Mic.** Capturing audio and recognising it are separate authorizations with separate keys,
and an app can do either without the other — so they are separate effects, not one.

**The version moved because the vocabulary did.** A consumer that understands `privacy/1` expects exactly
six effect names; emitting `Health` under that label would make the extension's own positive declaration
inaccurate. `extensions: ["privacy/2"]`.

### `EKEventStore` is ambiguous, exactly like `AVCaptureDevice`

One store type serves calendars *and* reminders, chosen per call by an `EKEntityType`. Resolved the same
way as the capture split: a statically-visible `.event`/`.reminder` refines, and anything else
over-discloses **both** — for a privacy manifest a missed sensor is the App-Store-rejection-shaped error.

**The consequence, stated rather than discovered later:** a *constructor* carries no entity type, so
`EKEventStore()` is ambiguous and a function that constructs a store declares both keys even if every call
on it is refined. The refinement therefore bites on stores that are not locally constructed
(`store.requestAccess(to: .event)` on a passed-in or property store). This is not new behaviour — measured,
`AVCaptureSession()` behaves identically — and it is the trade-off this extension already chose. Narrowing
it needs per-receiver refinement, which is tracked, not silently absent.

### Direction: `read` vs `write` (`privacy/2`)

Apple distinguishes reading from writing in three key families, and the first wave collapsed all three into
interchangeable alternatives:

| effect | read | write |
|---|---|---|
| `Health` | `NSHealthShareUsageDescription` | `NSHealthUpdateUsageDescription` |
| `Photos` | `NSPhotoLibraryUsageDescription` | `NSPhotoLibraryAddUsageDescription` \| `NSPhotoLibraryUsageDescription` |
| `Calendar` | `NSCalendarsUsageDescription` \| `…FullAccess…` | `…WriteOnlyAccess…` \| `…FullAccess…` \| `NSCalendarsUsageDescription` |

Treating a pair as alternatives means an app that both **reads and writes** HealthKit passes a verify while
declaring only Share — and is then rejected by Apple. `privacyKind(root:member:)` refines a call ALREADY
classified as a privacy effect with the direction its verb implies, on exactly the contract SPEC §2's `fs`
uses: `["read"]`, `["write"]`, `["read","write"]`, or `[]` when the verb does not say.

**The empty case is the whole safety property.** An unrecognised verb contributes nothing, and an effect
with no proved direction keeps the pre-`privacy/2` behaviour precisely — any acceptable key satisfies it.
So the refinement can only ever ADD a requirement where a verb said, never invent one where none did, and
a report predating the field verifies exactly as it did before.

Note the asymmetry with Add-only and write-only: `NSPhotoLibraryAddUsageDescription` satisfies a write and
**not** a read; `NSCalendarsWriteOnlyAccessUsageDescription` likewise. The full-access keys satisfy both.

`requestAuthorization(toShare:read:)` names both sides in one call and the discriminating argument is a Set
built at runtime, so it is genuinely ambiguous and declares **both** — the standing trade-off, since a
missed sensor is the App-Store-shaped error.

**Wire:** the direction rides the report entry as `privacy: {"<effect>": ["read"|"write"]}`, direct-only
and omitted when empty, on the same rule as `fs`. It cannot be derived by a consumer — the verb that said
`save` rather than `execute` is gone by the time a report is read — so, like `netClass`, the producer's
answer has to travel.

**KNOWN LIMIT.** Direction resolves where the receiver's type does: a local, a parameter, a property with
a known type. A receiver whose type the syntactic engine cannot pin (a module-level `let` used across
files, in the case measured) yields no direction — which falls back to the any-key semantics, i.e. fails
SAFE. Measured on a real app: `Health` proved `read` and `write` on both targets.

### A modelled TYPE is not a covered MODULE

A scan that classifies `Health` on `HKHealthStore` will still report HealthKit in the coverage ledger as a
module the classifier does not cover — and that is correct, not a contradiction. This extension models a
curated handful of a framework's types; the rest of HealthKit is genuinely unmodelled, and marking the
whole module covered would convert a disclosed blind spot into a silent purity claim over every other type
in it. Both statements in the same report are true: *this* type was classified, and the rest of that module
was not looked at.

Each is an **outside-world surface** — a sensor, a personal-data store, or the user's attention — on the
same footing as `Clipboard` (main-spec §6.1). Abstract non-boundaries (crypto, memory, threading) stay
out — the boundary rule is what keeps the vocabulary coherent.

## Classification

Two rules, mirroring the main-spec `Db`/`Llm` machinery. A call is classified by the **framework TYPE**
it targets (the syntactic engine resolves types, not module owners): a call whose receiver/argument type
is a curated privacy-source type carries that effect. The curated per-effect type tables are a starter
set — the §7 coverage ledger discloses an uncovered privacy framework like any other. A project type of
the same name **shadows** the curated one (the `declaredTypes` anti-fabrication rule): a local
`CLLocationManager` in the analyzed code is not the framework's.

- **No fabrication over precision:** an ambiguous call (a variable of unknown type, a same-named local
  type) does NOT get a privacy effect — it stays `Unknown`/pure, disclosed, never guessed. A fabricated
  `Camera` on a QR-decode helper is the precision failure the per-engine fabrication probe fences.
- **Purpose is not required:** unlike a privacy manifest, candor charges the effect on the *reach*, not
  on a declared purpose string — the point is the code-level truth the manifest is checked against.

## Wire disclosure (REQUIRED when the extension is active)

An engine that classifies any `privacy/1` effect MUST disclose the extension in the report envelope:

```json
{ "candor": { "version": "…", "toolchain": "swiftsyntax", "spec": "0.27" },
  "extensions": ["privacy/2"],
  "functions": [ … ] }
```

`extensions` is a top-level array of `"<name>/<version>"` strings. A consumer that does not recognize an
extension effect name tolerates it (main-spec §2 forward-compatibility); `extensions` lets it tell an
extension effect from a typo, and lets a policy/manifest tool know the surface was computed. The field is
OMITTED when no extension effect is active (so a plain report is byte-unchanged).

## Effect-model membership

`privacy/1` effects are **boundary** effects (§6.1 containment — dispersion is the architecture signal;
they join the CONTAINED set) and score **high** in the §3.1 surprising-reach salience set (a benign fn
reaching `Location`/`Camera`/`Mic` is exactly a surprising reach). They are **injection-neutral** (no
caller-derived-argument injection surface — a sensor read takes no untrusted sink), so they are NOT in
the AS-EFF-007 taint set; they ARE ambient authorities (AS-EFF-004 — a peripheral layer reaching a
sensor invisibly is the ambient-authority smell). They gate through the normal §6.2 grammar
(`deny Location ui`, `allow …`), and `deny`/containment name them like any effect.

## Cross-engine posture

Server-side engines (candor-scan/candor-query, candor-java on the JVM, candor-ts on Node) have no native
analog for the cluster — **N/A by language model** (the `dispatch:`-frontier precedent: a structurally
absent effect is N/A, not a gap). Real analogs exist for future adopters — Android's
location/camera/contacts APIs (a JVM-Android target), the browser's geolocation / `getUserMedia` /
Notifications (a ts-web target) — staged, not first-wave. When an adopter implements the same table
against its ecosystem, the extension's own text is the differential oracle.

**Tolerance vs surfacing (conformance PART 4n).** Every code engine TOLERATES a `privacy/1` report:
it loads, `map`/`show`/`where` operate, and a known co-effect (`Net` on the same function) still
surfaces — the §2 forward-compatibility guarantee. The engines differ in whether they SURFACE the
extension effect itself: candor-scan/candor-ts keep an unrecognized effect name as an opaque string
(so `where Location` over a swift report answers even on the rust/ts engine), while candor-java's typed
loader drops it. Both are compliant — the spec requires toleration, not cross-engine surfacing. Making
extension effects fully cross-engine-QUERYABLE (a JVM CI gating `deny Location` over a swift privacy
report) is a **future enhancement**: an engine would preserve unknown effect names as opaque
pass-through strings in the entry's effect sets. Not first-wave — swift produces and queries privacy
reports; the privacy-manifest verb is swift's.

## Product surface — the `privacy-manifest` verb

`candor-swift privacy-manifest [--report <locator>] [--verify <Info.plist>] [--json]` — the code-level
truth behind an app's privacy declaration.

- **GENERATE** (no `--verify`): from the report's privacy-effect reach (the transitive `inferred` set),
  emit the set of Apple **Info.plist usage-description keys** the code's sensor access REQUIRES, each with
  the reaching functions. (A `PrivacyInfo.xcprivacy` NSPrivacyAccessedAPITypes generator is a later
  extension — the usage-description keys are the App-Store-gating declaration for the sensor cluster.)
- **VERIFY `<Info.plist>`**: read the plist's usage-description keys and diff against the reached effects:
  - a reached effect with NO satisfying key → **UNDER-declaration** — the App-Store-rejection-shaped
    finding (the app touches the capability, transitively through a dependency, but never declares it);
    exit 1.
  - a declared key with NO reached effect → **OVER-declaration** — an unused permission (a privacy-review
    smell, a warning, not a failure); exit 0 unless combined with an under-declaration.
  - clean (every reached effect declared) → exit 0.

**The effect → usage-description key mapping** (a reached effect is SATISFIED if ANY acceptable key is
present):

| effect | acceptable Info.plist keys |
|---|---|
| `Location` | `NSLocationWhenInUseUsageDescription` \| `NSLocationAlwaysAndWhenInUseUsageDescription` \| `NSLocationAlwaysUsageDescription` \| `NSLocationUsageDescription` |
| `Camera` | `NSCameraUsageDescription` |
| `Mic` | `NSMicrophoneUsageDescription` |
| `Contacts` | `NSContactsUsageDescription` |
| `Photos` | `NSPhotoLibraryUsageDescription` \| `NSPhotoLibraryAddUsageDescription` |
| `Notify` | (none — notifications gate via a runtime `requestAuthorization`, not an Info.plist key; reported as a declared capability with no manifest key required) |

The JSON shape: `{ "reached": ["Location", …], "required": { "Location": ["NSLocation…"], … },
"declared": ["NSLocation…"], "underDeclared": [ { "effect", "keys", "fns":[…] } ],
"overDeclared": ["NSCamera…"], "ok": bool }`. The marketing exhibit: run VERIFY on a real open-source iOS
app and show a divergence (or a clean pass that proves the manifest is complete against the *transitive*
code truth — which grep can't).

**Caveat (whole-tree scan):** candor-swift analyzes a source tree as ONE report, so `reached` is the
union across every target in the tree. A multi-target app (an iOS app + a macOS app + a widget) whose
targets have SEPARATE Info.plists should scan and verify each target's sources against its own plist —
verifying the whole-tree report against one target's plist can flag a capability another target reaches.
The verb reports the divergence for REVIEW (report-reach vs plist-declaration); confirming a target-
membership violation is the reviewer's step. (Per-target scoping is a future refinement.)

## Versioning

`privacy/1` is the first version. Additive framework-source additions (more curated types) stay `privacy/1`
(a consumer tolerates a newly-covered call the same way it tolerates any new reach). A vocabulary change
(a new effect name, a removed one) bumps to `privacy/2`. Promotion into the main spec moves this text
there under a `⟨rung⟩` marker and the shared conformance suite picks it up.
