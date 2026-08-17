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
| `Contacts` | the address book | Contacts (`CNContactStore`) — the ContactsUI PICKER is `ContactsPicker`, below |
| `Photos` | the photo library | Photos (`PHPhotoLibrary`, `PHAsset`) — the PhotosUI PICKER is `PhotosPicker`, below |
| `Notify` | user-attention / notifications | UserNotifications (`UNUserNotificationCenter`) |

### The last five, and the two that are not code

**56 of Apple's 57** — and the verify PRINTS that figure itself, derived from the tables rather than
maintained here, so the number a reader is given cannot drift from the number the engine models. (This
paragraph said 55 while the engine said 56, which is the drift the derived figure exists to prevent.)
The five that had no obvious type were resolved by reading the DocC
`references` block on Apple's own key pages rather than the prose — the linked symbols were there all
along:

| key | what Apple's page links | how it is modelled |
|---|---|---|
| `NSSystemAdministration` | `ODRecordSetValue` | OpenDirectory: `ODRecord`/`ODNode`/`ODSession` |
| `NSAudioCapture` | *Capturing system audio with Core Audio taps* | `CATapDescription`, `AudioHardwareCreateProcessTap` |
| `NSEnterpriseMCAM` | *Accessing the main camera* — the SAME article as `NSMainCamera` | an ALTERNATIVE key on the existing effect |
| `NSAppBundles` | nothing — because there is no API | a PATH class: `/Applications/*.app/` |
| `NSAppData` | nothing — because there is no API | a PATH class: `~/Library/Containers/` |

The last two are the interesting ones. Apple names no API because **there isn't one**: reading another
app's bundle or container is ordinary file I/O, and it is the *path* that makes it protected. That is
exactly what a path class is for, so two keys that looked like they needed a new mechanism needed none.

**ONE key stays unmodelled, and the reason is now accurate rather than a shrug.** Both previously read
"enterprise/managed surface; not modelled", which implied someone had simply not got to them:

- `NSCriticalMessagingUsageDescription` — Apple's page links **no symbol at all**. It gates an
  entitlement for emergency SMS, so the evidence is a `.entitlements` file, not a call site — which is
  why it IS modelled now, on the ENTITLEMENT basis (`ENTITLEMENT_REQUIRED_KEYS`), the one row in the
  breakdown whose evidence is a manifest rather than code. It was still counted as unmodelled here long
  after it stopped being: the paragraph two screens up says the printed figure is the authority
  precisely because a hand-maintained count drifts, and this is the count that drifted.
- `NSFileProviderPresenceUsageDescription` — links only sibling *keys*. A file provider's presence
  capability is declared, not called. This is the one the verify still says nothing about.

Neither is a gap in the model; both are outside what code analysis can see, and the disclosure now says
so in those words. Closing them means reading a second manifest, which is a different kind of evidence
and should be labelled as one.

> **All four waves below ship as ONE version, `privacy/2`.** `privacy/1` is the only id any release has
> carried (v0.25.0 and v0.26.0 both ship it), so the intermediate numbers never existed for a consumer,
> and publishing four of them would present our git history as somebody's upgrade path. The waves are
> kept as narrative because the *order* of discovery is the useful part — each one was found by measuring
> the previous one.

### The over-report round (2026-08-07) — three rows Apple does not require, and one it does conditionally

Running the verb against shipping apps it had never seen produced a wrong finding on **every** app in
that second group, and every one was an over-report. Each is recorded here because the reasoning is the
model for the next such row, not because the row itself is interesting.

| effect | keys | why it is not a plain sensor row |
|---|---|---|
| `ContactsPicker` | **none** | `CNContactPickerViewController` runs OUT OF PROCESS: the app never gains access to the library, only to what the user picked. Apple's statement is unconditional, so the effect is KEYLESS — the reach is still reported, and a `deny ContactsPicker` still binds. |
| `PhotosPicker` | **none** | `PHPickerViewController`, same shape and the same unconditional statement. |
| `CalendarUI` | `NSCalendars*`, **conditionally** | Apple, "Accessing the event store": *"EventKitUI presents chooser and editor UI outside of your app's process on iOS 17 and later. Your app can use EventKitUI without requesting write-only or full calendar access."* Below iOS 17 the key IS required, and this engine cannot see a deployment target. So the requirement is raised as a NAMED CONDITION (`PRIVACY_CONDITIONAL_REQUIREMENT`, ⚠, exit unchanged), never a hard ✗ and never silently: a ✗ is a false misconfiguration claim against every 17+-only app, and an empty key list is a silent under-report against every pre-17 one. The reader holds the one fact that settles it. |

Two more, without new effects. `GKLocalPlayer` authentication was charged the FRIEND-LIST key and is now
member-gated to the members that read friends. `CLGeocoder` was charged `Location` though it only converts
coordinates the caller already supplies — no authorization, no key — and is removed.

**`NSAppleEventDescriptor` was the same error in the other direction.** `NSAppleEventsUsageDescription`
gates *sending* ("required if your app uses APIs that send Apple events" — Apple's key page), and the
descriptor is the wrapper BOTH sides touch: every `kAEGetURL` receive handler takes two as parameters, so
type-level charging flagged the receive-only half of the world. The effect now rides the one member that
transmits (`sendEvent(options:timeout:)`), the C send route (`AESendMessage`) and the send-by-design types
(`NSAppleScript`, whose script body is invisible to static analysis, and `SBApplication`, whose class page
says "send Apple events" in terms). `NSAppleEventManager` is mapped nowhere, correctly: installing a
handler is pure receive.

**The pattern, stated because it will recur: an over-report is found only by running the tool on code you
did not write and then checking whether the app is actually wrong.** A fixture corpus cannot produce one,
because a fixture is written to the model the classifier already has.

### Fourth wave (`privacy/4`, 2026-08-05) — the rest of what a type can name

Seven more families, closing everything left that a TYPE or MEMBER can identify: Focus status
(`INFocusStatusCenter`), Wallet identity (`PKIdentityRequest`/`PKIdentityDocument`), FinanceKit
(`FinanceStore`), the three visionOS ARKit providers — hands (`HandTrackingProvider`), world-sensing
(`PlaneDetectionProvider`/`SceneReconstructionProvider`/`ImageTrackingProvider`) and the main camera
(`CameraFrameProvider`) — and temporary location accuracy.

**Every type name was verified against Apple's docs JSON before being mapped.** A wrong type→key mapping
does not merely miss; it fabricates a requirement on real apps, and this vocabulary is assembled from
knowledge that is easy to be confidently wrong about.

Temporary accuracy exposed an ordering bug worth recording: `requestTemporaryFullAccuracyAuthorization`
has its own key but sits on `CLLocationManager`, which is already modelled as `Location` — and the type
map was consulted BEFORE the member map, so the type always won and the temporary key could never be
emitted at all. Member-gated families now match first. A realistic location app correctly gets both
keys, which is what Apple requires.

**42 of Apple's 57 documented keys are now modelled.** The 15 that remain are the four path-triggered
macOS folder keys, LocalNetwork, the enterprise/MDM surfaces, and a handful of allow-once variants that
are not separable at a call site. All are derived, disclosed by every verify, and named with a reason.

### Third wave (`privacy/3`, 2026-08-05) — measured against Apple's own key list

The first two waves were assembled from what we knew Apple required. This one was assembled from what
Apple **documents**: the protected-resources list was fetched from developer.apple.com, and it names
**56 usage-description keys where candor modelled 26**. Nine families closed the commercially likeliest
part of that gap — NFC, fall detection, SensorKit, FileProvider, system extensions, Apple events, TV
provider, Game Center friends and clinical health records.

Every one landed only after a fixture in `tools/privacy-recall.py` measured the miss, and that battery
now runs as a gate: it fails when a family the vocabulary CLAIMS stops being caught, and merely reports
the families it does not claim. 34/39 fixtures caught, 0 broken promises.

The unmodelled set is now DERIVED (Apple's list minus `privacyKeyMap`) and printed by every verify, so
it cannot silently fall behind. The hand-written version of that disclosure named 14 keys when the real
number was 30 — **a warning about a gap that under-reported the gap**.

**What the wave really exposed:** the sensor vocabulary existed in SEVEN copies — the type table, the key
map, an ordered list, `PRIVACY_EFFECTS`, the policy's `EFFECTS`, the manifest CLI's own array, and an
`Effect` enum in the report writer. A family added to six of them and missing from the seventh is
computed and then silently discarded at serialisation: nothing fails, the effect just never reaches the
report. They now derive from one ordered source.

### Second wave (`privacy/2`, 2026-08-04)

The first wave covered six sensors, which was not enough to answer the question the product surface asks.
Measured on a real app: its `Info.plist` declares `NSMotionUsageDescription` and two HealthKit keys, and
`privacy-manifest --verify` said **nothing about them in either direction** — neither required nor flagged
as unused — because the effects did not exist. An `exit 0` meaning *"the six I model are declared"* reads
as *"your plist is right"*, which is the absence-is-a-claim shape the main spec closed at ⟨0.26⟩.

| effect | meaning | sources (Apple frameworks) |
|---|---|---|
| `Health` | HealthKit samples | `HKHealthStore`, the sample/observer/statistics/anchored queries, workout sessions and builders |
| `Motion` | motion & fitness sensors **that require the key** | CoreMotion (`CMPedometer`, `CMAltimeter`, `CMMotionActivityManager`, `CMHeadphoneMotionManager`, `CMSensorRecorder`, `CMMovementDisorderManager`) |
| `MotionRaw` | the raw accelerometer / gyroscope / magnetometer stream — **no Info.plist key** | CoreMotion (`CMMotionManager`) |
| `Calendar` | the user's calendars | EventKit (`EKEventStore` — ambiguous, see below). The EventKitUI classes are `CalendarUI`, below |
| `Reminders` | the user's reminders | EventKit (`EKEventStore` — ambiguous, see below) |
| `Bluetooth` | BLE scanning / advertising | CoreBluetooth (`CBCentralManager`, `CBPeripheralManager`) |
| `Speech` | speech recognition | Speech (`SFSpeechRecognizer`, the recognition requests) |
| `Biometrics` | Face ID / Touch ID | LocalAuthentication (`LAContext`) |
| `MediaLibrary` | the user's Apple Music / media library | MediaPlayer (`MPMediaLibrary`, `MPMediaQuery`, `MPMusicPlayerController`, `MPMediaPickerController`) |
| `HomeKit` | home accessories | HomeKit (`HMHomeManager`, `HMAccessoryBrowser`) |
| `Tracking` | App Tracking Transparency (IDFA) | AppTrackingTransparency (`ATTrackingManager`) |
| `NearbyInteraction` | UWB ranging | NearbyInteraction (`NISession`) |
| `Siri` | Siri authorization / donation | Intents (`INPreferences`) |

**`MotionRaw` is split from `Motion` because Apple splits it.** The documentation page for
`NSMotionUsageDescription` names exactly four APIs — `CMSensorRecorder`, `CMPedometer`,
`CMMotionActivityManager`, `CMMovementDisorderManager` — all of which read *stored or derived* motion.
`CMMotionManager`'s live accelerometer/gyroscope stream requires no key at all. Mapping every CoreMotion
class to the key made candor report a missing declaration against an app that needed none, so the reach
still has to be **reported** (it is a sensor, and a policy can `deny MotionRaw`) while requiring nothing
of the plist. Reporting it under a separate name is what keeps both halves true; dropping it from the
report instead would have traded the over-report for silence.

**Value types that merely carry an already-taken reading are excluded**, on the `CLLocation` precedent —
`HKQuantity`, `CMDeviceMotion`, `CMAccelerometerData`, `EKEvent`, `CBUUID`. Holding a reading is not taking
one.

**`LocalNetwork` was deliberately absent, and is now modelled on the CONSTANT basis.** The reach cannot
be separated from ordinary `Net` *by type* — `NWBrowser`/`NWConnection` serve both — and charging the key
to every networking app is the fabrication that kept it out. What made it modellable was the same move
the folder keys use: decide it by the HOST LITERAL, not the type. A destination ending `.local`, or a
link-local/private address, is local-network by construction; anything undetermined stays plain `Net`.
So the row is earned rather than guessed, and the guessing version stays rejected.

**Speech is not Mic.** Capturing audio and recognising it are separate authorizations with separate keys,
and an app can do either without the other — so they are separate effects, not one.

**The version moved because the vocabulary did.** A consumer that understands `privacy/1` expects exactly
six effect names; emitting `Health` under that label would make the extension's own positive declaration
inaccurate — so the wire id moved off `privacy/1` and has stayed put since. **What ships is
`extensions: ["privacy/2"]`**, for every wave including this one: see the note at the top of this section
and `PRIVACY_EXTENSION_ID`. The `### N-th wave (privacy/N …)` headings below are DRAFTING labels for when
each batch of rows was added — they are not wire ids, and reading them as such is what put a `privacy/3`
in this paragraph while every report said `privacy/2`.

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

`requestAuthorization(toShare:read:)` names both sides in one call, but the discriminating argument is not
always runtime: **`toShare: nil` is the canonical read-only spelling and is statically visible**, so it
resolves to `read` alone. A non-nil set, or an argument the engine cannot see, stays ambiguous and declares
both — the standing trade-off, since a missed sensor is the App-Store-shaped error.

Treating the call as *unconditionally* ambiguous was wrong and briefly shipped: it charged every read-only
HealthKit app with a write and demanded a key it does not need — a false under-declaration on the commonest
shape in the framework, which is the fabrication direction this extension exists to fence. The lesson is
narrower than "be careful": **before declaring an ambiguity, check whether the discriminating argument is
actually invisible.** Here it was in the source all along.

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

## The scan's SCOPE travels with the report (`scope`, OPTIONAL)

`--target` scopes the **scan**. The `privacy-manifest --verify` that follows reads a **report and a
plist** — so everything the scan learned about *which binary this is* has to be in the artifact or it is
lost. It was lost: the verify re-discovered `.entitlements` by walking the plist's directory, and a repo
with several shipped binaries has several, so it refused to guess and left the entitlement-sourced keys
unchecked — on exactly the multi-target repos `--target` exists for. Measured on NetNewsWire: eight
`.entitlements` in the tree, one key never checked.

Narrowing that *search* would still be a search. `CODE_SIGN_ENTITLEMENTS` **names** the file, per target,
which is the answer the question was always asking for. When `--target` resolves against an `.xcodeproj`
the report carries:

```json
"scope": { "target": "NetNewsWire-iOS",
           "project": "NetNewsWire.xcodeproj",
           "entitlements": "…/iOS/Resources/NetNewsWire.entitlements" }
```

OMITTED entirely when no scope was applied, so an unscoped report — and every other engine's — is
byte-unchanged. `entitlements` is present **only when the resolved path names a file that exists**:
absent means *not determined*, never *this target has none*, and the verify then keeps the discovery it
had, so the key can only ever be better informed than before.

**An undefined build variable expands to the empty string** — Xcode's rule, and the one that makes this
exact rather than a guess. NetNewsWire writes
`CODE_SIGN_ENTITLEMENTS = iOS/Resources/NetNewsWire$(DEVELOPER_ENTITLEMENTS).entitlements`, and
`DEVELOPER_ENTITLEMENTS` is defined only in a personal file outside the checkout (an optional `#include?`
of `../../SharedXcodeSettings/…`). In a clone it is undefined, so the path is `NetNewsWire.entitlements`
— precisely the file that checkout builds against, and the reason `NetNewsWire.entitlements` and
`NetNewsWire-dev.entitlements` sit beside each other. The iOS and Mac targets resolve files with the
SAME basename in different directories, which is the case discovery could never have disambiguated.

The verify states the provenance on a pass as well as a finding: *"entitlements read from
`NetNewsWire.entitlements`, named by the scanned target's CODE_SIGN_ENTITLEMENTS — not discovered by
searching."* An entitlements check that silently read the wrong target's file is the failure this
removes, so saying which file was read is part of the answer.

## Wire disclosure (REQUIRED when the extension is active)

An engine that classifies any `privacy/1` effect MUST disclose the extension in the report envelope:

```json
{ "candor": { "version": "…", "toolchain": "swiftsyntax", "spec": "0.29" },
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
membership violation is the reviewer's step. **Per-target scoping SHIPPED** — `--target` resolves against
a `Package.swift` or an `.xcodeproj`, and the scope travels with the report (see "The scan's SCOPE travels
with the report"), so the two halves can be named explicitly instead of reviewed by hand.

## Versioning

`privacy/1` is the first version. Additive framework-source additions (more curated types) stay `privacy/1`
(a consumer tolerates a newly-covered call the same way it tolerates any new reach). A vocabulary change
(a new effect name, a removed one) bumps to `privacy/2`. Promotion into the main spec moves this text
there under a `⟨rung⟩` marker and the shared conformance suite picks it up.
