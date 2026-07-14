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
{ "candor": { "version": "…", "toolchain": "swiftsyntax", "spec": "0.13" },
  "extensions": ["privacy/1"],
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

## Product surface (staged — after the effects land)

`candor-swift privacy-manifest [--verify <PrivacyInfo.xcprivacy>]` — GENERATE the accessed-API set from
the code-level effect reach, or VERIFY an existing manifest against it (a declared capability the code
never reaches → over-declaration; a reached capability the manifest omits → the App-Store-rejection-shaped
under-declaration). The marketing exhibit: run it on a real open-source iOS app and show a divergence.

## Versioning

`privacy/1` is the first version. Additive framework-source additions (more curated types) stay `privacy/1`
(a consumer tolerates a newly-covered call the same way it tolerates any new reach). A vocabulary change
(a new effect name, a removed one) bumps to `privacy/2`. Promotion into the main spec moves this text
there under a `⟨rung⟩` marker and the shared conformance suite picks it up.
