# Changelog

All notable changes to candor-swift are recorded here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); candor is pre-1.0, so minor versions may include
behavioural changes (always in the soundness-increasing direction — see the §4 trust contract).
A **⚠** heading marks a report- or verdict-affecting change: it changes report bytes or gate
verdicts, so an engine upgrade across it is baseline-invalidating (regenerate any saved baseline
with the new build — the AS-EFF-005 guard refuses a cross-build baseline by design).

## Unreleased

- **⚠ The κ coverage ledger named modules the scan had just ANALYZED — and the first fix for it was a
  CARDINAL SIN.** On a `--target`-scoped NetNewsWire scan the ledger listed 31 uncovered modules
  including `RSCore` (20 analyzed files in that very report), `Account` (53) and `NewsBlur` (7), saying
  their effects were "INVISIBLE to the scan" and advising work that was already done. A false disclosure
  spends the reader's trust in the ledger that carries the REAL blind spots.

  The first repair took any analyzed path segment `Sources/<X>/` as proof module X had been read. **It
  proves a DIRECTORY named X was read.** `internalModules` gates BOTH disclosure channels — the ledger
  and the per-function `invisible` set, which is the only thing between an unresolved call into a blind
  module and a purity claim — so the fixture is one directory name: `App/Sources/Stripe/Shim.swift`
  importing `Stripe` and calling `StripeClient()` reported **zero effectful functions, no ledger, no
  `invisible`**, while `App/Sources/StripeIntegration/` disclosed both. Naming an integration folder
  after the SDK it wraps is ordinary in the `.xcodeproj` trees `--target` serves. Caught by a go/no-go
  re-review, reproduced on the shipped binary before believing it.

  The sound rule: a `Sources/<X>/` counts only when it IS an SPM target root — an ancestor
  `Package.swift` directly above that `Sources/` declaring a target named X. NetNewsWire's
  `Modules/Account/Package.swift` declares `Account`, so the win is unchanged at 31 → 14; the Stripe
  fixture's root manifest declares `App`, so nothing is silenced. It also drops the flat-layout artefact
  where `Sources/main.swift` inserted a FILENAME as a module.
- **A labelled `for:` now wins over an unlabelled positional in the capture media type.** Reading the
  first argument that could be a media type found `.builtInWideAngleCamera` in
  `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` — the commonest setup
  call in AVFoundation — judged the medium undetermined, and charged Mic to a camera-only function. The
  exact complaint the deferral was built to kill, returning through a different overload. The unlabelled
  arm still matters (`devices(.audio)`) and stays, as the fallback it should always have been.
- **⚠ CARDINAL SIN, found by a go/no-go review of THIS release's own fabrication fix: a computed media
  type was settled by an unrelated sibling call.** A function opening `AVCaptureDevice.default(for:
  .video)` and, two lines later, `AVCaptureDevice.default(for: kind)` reported `[Camera]` — the possible
  Mic reach absent from `functions`, no `Unknown`, nothing in the coverage ledger, and
  `privacy-manifest --verify` telling the developer to declare only the camera key for a function that
  opens a microphone at runtime. Confirmed by running the shipped binary before fixing.

  One flag was doing two jobs. Deferring the ambiguous case to whole-body resolution is right for a call
  with NO media argument (a bare `AVCaptureSession()` — the medium comes from the devices added beside
  it, so a sibling `.video` genuinely does settle it) and wrong for a call whose media argument IS
  present and computed: that is an independent capture source nothing else in the function speaks for.
  `mediaTypeArgKind` is now three-valued — determined / undetermined / absent — and only `absent` defers.
  The fabrication this deferral was introduced to kill (Bitwarden's camera-only QR scanner charged Mic)
  stays killed, pinned as the floor beside the new test. **This is the measured shape this project keeps
  hitting: the silent under-report introduced BY the over-report fix, invisible to the fixture that
  proved the over-report closed.**
- **⚠ …and a second silent under-report in the platform prune: `os(OSX)` is LIVE Swift.** It is the
  legacy spelling of `os(macOS)` and Swift 6.3 still compiles its body on macOS — verified with
  `swiftc`, not assumed. Comparing the condition token to the platform name alone judged such a file to
  compile to nothing on a macOS target, dropped it from the scope, and left its functions absent from
  `functions` — a ⟨0.21⟩ purity claim over live code, with the stderr count asserting a justification
  false for that file. Legacy Mac codebases are where the spelling survives, and where the Apple-events
  reach lives. One-line alias, with a control proving the condition is still correctly inactive on iOS.
- **`SPEC-EXTENSION-privacy.md` contradicted itself and the code in four places**, all found by the same
  review: "two keys stay unmodelled" (it is one — `NSCriticalMessagingUsageDescription` is modelled on
  the entitlement basis, and the count that drifted sits directly under the paragraph explaining that
  the printed figure is the authority BECAUSE hand-maintained counts drift); "`LocalNetwork` is
  deliberately absent" (it is modelled now, on the constant basis — decided by the host literal, not the
  type, which is what made it earnable rather than a guess); "per-target scoping is a future refinement"
  (it shipped); and a `privacy/3` wire id in prose while every report emits `privacy/2` — the `### N-th
  wave` headings are drafting labels, and the doc now says so rather than inviting the misreading again.

- **⚠ The scan's SCOPE now travels with the report (`scope`, SPEC-EXTENSION-privacy.md).** `--target`
  scopes the SCAN; the `privacy-manifest --verify` that follows reads a REPORT and a plist, so
  everything the scan learned about which binary this is had to be in the artifact or it was lost — and
  it was lost. The verify re-discovered `.entitlements` by walking the plist's directory, found several
  on exactly the multi-target repos `--target` exists for, refused to guess, and left the
  entitlement-sourced keys unchecked. Measured on NetNewsWire: eight `.entitlements` in the tree, one
  key never checked, on both the iOS and the Mac answer.

  Narrowing that SEARCH would still be a search. `CODE_SIGN_ENTITLEMENTS` NAMES the file, per target,
  which is the answer the question was always asking for. The `.xcodeproj` resolver reads it from the
  target's build settings — its own `XCBuildConfiguration` dictionaries and its `baseConfigurationReference`
  xcconfig chain, `#include`s followed, the Xcode 16 synchronized-folder spelling included — and the
  report carries `scope: {target, project, entitlements}`. The verify prefers it and states the
  provenance on a pass as well as a finding, because an entitlements check that silently read the wrong
  target's file is the failure this removes.

  **An undefined build variable expands to the empty string**, which is Xcode's rule and the thing that
  makes this exact rather than a guess: NetNewsWire writes
  `iOS/Resources/NetNewsWire$(DEVELOPER_ENTITLEMENTS).entitlements`, and `DEVELOPER_ENTITLEMENTS` lives
  only in a personal file outside the checkout, so a clone resolves the release entitlements — which is
  what that checkout builds. The iOS and Mac targets resolve files with the SAME basename in different
  directories; discovery could never have told them apart. One shared settings walker now serves this
  and the platform prune, so there is no second copy of the xcconfig-chain reader.

  Fail-safe throughout: `entitlements` is emitted only when the resolved path names a file that EXISTS,
  a recorded path that has since gone falls back to discovery rather than checking nothing, and the key
  is omitted entirely when no scope was applied — so an unscoped report is byte-unchanged.

- **A `--target` refusal on a GENERATED-project repo was a dead end.** bitwarden/ios builds its Xcode
  project with XcodeGen, so a fresh clone has no `.xcodeproj` at all and the refusal said only "needs a
  Package.swift or an .xcodeproj … neither found" — accurate, and useless to a user whose repo is
  perfectly ordinary. The spec file is sitting in the same directory; the refusal now names it and the
  command that turns it into a project, then says to re-run the same `--target`. It names EVERY spec
  rather than picking one — bitwarden has five and the alphabetically-first builds the Authenticator,
  not the app, so suggesting one command is the same guess this resolver refuses to make everywhere
  else. `project.yml`/`Project.swift`/`Tuist.swift` are recognised too. Pinned with its control: a repo
  with Swift sources and no generator still gets the plain message and no advice it cannot act on.

- **⚠ `--target` on an `.xcodeproj` resolved the local-package closure ONE HOP SHORT — found by running
  it on NetNewsWire.** `Modules/` holds **17** local packages; the scope resolved **14**. The three
  missing were exactly those no app TARGET names directly — `CloudKitSync`, `FeedFinder`, `NewsBlur` —
  reachable only through `Account`. `NewsBlurAPICaller` is the app's sync layer, so the scoped scan
  analyzed the app minus its network client.

  The cause was one spelling. The walk followed `.product(name:package:)` edges, which is what its own
  comment claimed, and Account writes every dependency as a **bare string** (`.package(path:
  "../NewsBlur")` beside a plain `"NewsBlur"` in the target) — SwiftPM resolves a bare name against a
  dependency package's products, and `targetClosure` drops a name its own package does not declare.
  That drop is right on the SPM `--target` path, where "not declared here" does mean "no sources in this
  tree", and wrong on the `.xcodeproj` path, where the sibling package is three directories away. Bare
  names that match no in-package target now go through the same local-product index the `.product(…)`
  edges use.

  **Not a purity claim** — the import ledger still disclosed all three as uncovered modules, so nothing
  read as pure. The scope was simply smaller than the product. And the fix is disclosure-positive in the
  other direction too: a bare name matching no local product now reaches the REMOTE counter instead of
  being dropped at closure level, where it reached no counter at all. Measured after: NetNewsWire iOS
  422 → 441 files (17 packages, 2 remote), Mac 449 → 468; the only file now in neither app's scope is
  `buildscripts/VerifyNoBS.swift`, which is a build script. The A/B that motivated `--target` is
  unchanged — whole-repo verify against the iOS plist still reports the false AppleEvents
  under-declaration, the scoped one still passes. Both new tests were run against the pre-fix code and
  fail there.

- **⚠ Flip #18: the `#include` chain was followed ONE LEVEL.** A three-deep split config —
  `App.xcconfig` → `Configs/mid.xcconfig` (declares) → `deep.xcconfig` (undeclares) — resolves EMPTY at
  build time, because a later include wins. Reading one level saw the declaration and never the
  undeclare, so the key counted as declared and the verify passed. The consistency rule would have
  caught it had the file been read at all; the defect was purely the depth bound, and three-deep
  xcconfig chains are an ordinary layout. Now followed to the end, cycle-safe and depth-capped, with the
  containment check on every hop.
- **⚠ Sensor use reachable only from Objective-C was invisible with NO caveat.** A target with one
  trivial `.swift` file beside a `.m` calling `AVCaptureDevice` verified `✓ (0 effects)`, exit 0, against
  an empty plist — and nothing said that non-Swift sources had not been read. The uncovered-MODULE
  ledger could not fire, because nothing Swift imported anything uncovered: the code simply was not
  Swift. Mixed-language apps are most mature iOS apps. Now counted and disclosed as a conditionality,
  bounded by the same project-root walk the build-settings reader uses. Measured: 0 on IceCubesApp and
  duckduckgo (pure Swift), 129 on WordPress-iOS.
- **…and THREE walks anchored on the plist searched trees that are not the app's — one of them at 72
  seconds a call.** Each looked for a project root above the plist and then read whatever it was pointed
  at, so a plist handed to `--verify` from a directory that is not a checkout — a temp directory,
  `/tmp`, an extracted archive — searched somebody else's: the non-Swift source count at **21 minutes
  for one `swift test` case**, the `.entitlements` discovery at **233 seconds**, and the build-settings
  reader's ancestor walk at **72 seconds per verify**. Together that is most of why this suite ran for
  an hour instead of ten minutes.
  - **The rule, applied three times: no checkout ⇒ the ancestors are not this app's directories.** One
    shared `projectRootAbove` now gates all three. The count is not taken and says so
    (`nonSwiftSourcesCounted: false` on the JSON channel, its own ⚠ on the console, printed even when
    nothing else is conditional — a clean verify with no caveat is exactly the case it exists for);
    "beside" reverts to literally beside for the entitlements file; and the build-settings walk reads
    the plist's own directory only. Falling back to the plist's directory fixes nothing on its own,
    because that directory IS `$TMPDIR` in the case that produced the 21 minutes, and a depth cap would
    trade the cost for an under-count — the wrong currency, since the count is a DISCLOSURE and a quiet
    `0` is a "nothing unread here" the run has no grounds for. Direction check on the build-settings
    half: what is lost is an `.xcconfig` above a plist in a tree with NONE of the five markers, which
    then reads as undeclared — an over-report, not a silent under-report. Where a root IS found nothing
    changes, verified end to end.
  - **`contentsOfDirectory(at:)` vs `(atPath:)` was worth 70 of those 72 seconds.** The URL variant
    builds a `URL` and stats every entry; sampling one `--verify` put every second inside
    `_FSURLCreateWithPathAndExtendedAttributes`. The marker test only needs names. (The directory it was
    listing had 185,000 entries — 130,000 of them candor's own leaked test fixtures, which is a
    separate housekeeping item now recorded.)
- **⚠ The over-report round, continued — the two remaining rows that asserted keys Apple does not
  require.** Both settled by fetching Apple's own pages, both verified on the corpus:
  - **`NSAppleEventDescriptor` charged the SEND-only key to RECEIVE-side code.** Apple's key page:
    *"This key is required if your app uses APIs that send Apple events"* — and the descriptor is the
    wrapper BOTH sides touch. Measured on NetNewsWire: the evidence candor printed for
    `NSAppleEventsUsageDescription` was `AppDelegate.getURL`, the kAEGetURL receive handler every Mac
    app with a custom URL scheme installs. The type is out of the flat table; the effect now rides the
    one member that transmits (`sendEvent(options:timeout:)` — member-gated like `GKLocalPlayer`), the
    C send route (`AESendMessage`, a new kappaFree row), and the send-by-design types (`NSAppleScript`
    kept — a script body is invisible to static analysis — plus `SBApplication`, whose class page says
    "send Apple events" in terms, previously unmodelled). NetNewsWire's genuine send
    (`SendToBlogEditorApp.send`) still charges; its receive-only half no longer does.
  - **EventKit UI's key requirement changed with the OS, and candor asserted the old half
    unconditionally.** Apple, "Accessing the event store": *"EventKitUI presents chooser and editor UI
    outside of your app's process on iOS 17 and later. Your app can use EventKitUI without requesting
    write-only or full calendar access."* Below iOS 17 the key IS required, and candor cannot see a
    deployment target — so `EKEventEditViewController`/`EKCalendarChooser` are now a SPLIT effect,
    `CalendarUI` (parent `Calendar`, same acceptable keys, `EFFECT_SPLIT_PARENT` disclosure), and the
    verify raises an undeclared key as a NAMED CONDITION: a ⚠ carrying "required only when the
    deployment target is below iOS 17…", exit code unchanged, `conditionallyUnderDeclared` on the JSON
    channel, and a verdict line that says "no MODELLED capability is provably missing" rather than
    over-claiming. Not keyless (the ContactsPicker shape needs an UNCONDITIONAL Apple statement; this
    one is version-fenced, and keyless would silently under-report every pre-17 app), not a hard ✗ (a
    false misconfiguration claim against every 17+-only app). The reader holds the one fact that
    settles it, so the verify hands them exactly that question.

- **`--target` now resolves `.xcodeproj` targets — the audience privacy-manifest is promoted to.**
  It resolved only against a `Package.swift` and exited 2 on every Xcode-project repo, so those scans
  stayed whole-repo and charged each shipped product with every other one's sensors: NetNewsWire's iOS
  plist was charged `NSAppleEventsUsageDescription` from Mac-only code, Focus's plist was charged
  Speech reached from firefox's QuickAnswers code in a sibling project (both measured, both false, both
  gone under scoping — and the IceCubes/DuckDuckGo/WordPress app targets keep their full
  Camera/Photos/Mic/Speech reach under scoping, measured, because the fix that loses real reach is
  worse than the false alarm). The pbxproj is parsed by a hand-written OpenStep reader sharing the
  build-settings evaluator's comment stripper — no `plutil`, so the Linux leg behaves identically.
  Resolution covers the classic Sources-phase/group-tree form and Xcode 16 synchronized folders with
  both halves of their per-target membership exceptions, plus the in-project dependency closure.
  SwiftPM keeps priority whenever the manifest declares the name; the fallback states which resolver
  answered. Every failure REFUSES (exit 2) — unparseable project, unknown name (listing the real
  targets, applications first), dangling reference, missing synchronized folder — because a scope
  silently resolved short is a purity claim over the files it dropped.

  **Which package dependencies resolve, and which are disclosed.** LOCAL Swift packages — drag-in
  `wrapper` file references, `XCLocalSwiftPackageReference`s, and packages sitting in a synchronized
  folder's subdirectories (NetNewsWire's `Modules/`) — resolve INTO the scope: the product's targets,
  their in-package closure, and `.product(…)` edges between local packages, transitively. This was a
  stated boundary first and the measurement killed it: IceCubesApp's app target is a thin shell over
  `Packages/*`, and scoping analyzed `[Notify]` while the app's real Camera/Photos reach sat beside a
  green tick as a conditionality footnote. REMOTE packages (and cross-project target dependencies)
  stay outside — counted in the scope note and κ-disclosed as uncovered, never silently pure. A local
  product that cannot be resolved soundly REFUSES rather than narrowing the scan; a manifest that
  builds its lists in code (WordPress's `XcodeSupport.products`) is read by
  `swift package dump-package` — SwiftPM itself — and that execution is disclosed in the scope note.
  When the target's build settings name its platform (SDKROOT/SUPPORTED_PLATFORMS, xcconfig
  `#include` chains followed), files whose every top-level declaration sits in `#if os(…)` clauses
  provably false for it are excluded — RSCore's Apple-events code is a member of the package but
  compiles to nothing on iOS, and without this the false finding returned through the packages the
  scoping had just resolved. Undecidable conditions (`canImport`, custom flags) always keep the file.

- **⟨0.27⟩ `zeroMatch` on the verdict document (SPEC §4, conformance PART 36).** The zero-match list —
  a rule whose scope bound no function — now rides the `--gate-json` document on BOTH routes (scan and
  `gate --report`), code-point sorted via the UTF-8 view (Swift's default String `<` is canonical order,
  and a Swift String cannot hold a lone surrogate, so the UTF-8 comparison is not lossy), deduplicated,
  omitted when empty; it was stderr-only in all five engines. Never on the refusal document: the stash
  is written by the one `evaluateGate` a run performs, and a refused run never evaluates.

- **⟨0.27⟩ …and the SCAN route's COMPOSED document now carries `unevaluated` too (SPEC §3.1, PART 36
  row (a4), no longer waived).** A certain AS-EFF-005 beside a refused policy exited 1 with the
  violation and NOTHING saying the policy had never run — so a consumer reading `violations` with no
  `unevaluated` beside it takes the document as *the policy ran and this is all it found*. Every rule of
  the refused policy is now listed, raw line verbatim, the unhonourable one(s) with their specific cause
  and the rest with a `why` naming the whole-policy refusal; an unreadable file gets one entry for the
  whole policy, because an exit-1 document with an EMPTY list makes the same false claim in a quieter
  way. This engine's composed document was already right about the other half (no `refused`/`reason`
  beside `violations`), and a sole refusal is unchanged: exit 2, refusal document, its own list.
- **⚠ Flip #17: a Debug-only build setting counted as DECLARED, and the App Store archive is Release.**
  Verified end to end — `✓ every MODELLED capability is declared`, exit 0, on a project whose Release
  configuration ships no camera key. It is one click in Xcode's per-config editor, and it was invisible
  because the statement splitter threw `{`/`}` away, taking the block structure and the `name = Debug;`
  line with it. Configuration blocks are now parsed and attributed by name; a key absent from Release is
  disclosed, not counted. Only fires when the file HAS a Release configuration, so a project using
  custom names is not told its keys are missing.
- **⚠ ARKit and VisionKit were absent from the classifier entirely** — every AR app and document scanner
  verified clean with "0 effects" against an empty plist, and ARKit does not merely get rejected, it
  TRAPS at runtime without `NSCameraUsageDescription`.
- **⚠ A non-string plist value counted as a declaration.** `<key>NSCameraUsageDescription</key><false/>`
  verified green; Apple does not accept it. Only a non-empty string is a usage description.
- **THE OVER-REPORT ROUND — six ways candor told a shipping app it was broken.** All found by running
  the verb on apps it had NOT been developed against, which is the only way an over-report surfaces:
  - the system **contacts and photo pickers** were charged usage keys. Apple, on the contacts picker:
    *"The app using contact picker view does not need access to the user's contacts."* PHPicker is the
    same out-of-process design. Both are now keyless effects — the reach is still reported.
  - **`GKLocalPlayer` authentication** — the first line of every Game Center game — was charged the
    friend-list key. Member-gated to the friends APIs, like `HKObjectType.clinicalType`.
  - **`CLGeocoder`** was charged Location though it converts coordinates the CALLER supplies, and
    **`INVoiceShortcutCenter`** was charged Siri though managing an app's own shortcuts sends Siri no
    user data. Two shipping browsers were told their manifests were wrong on the latter.
  - **a labelled `mediaType:` argument went unread**, so `DiscoverySession(deviceTypes:mediaType:…)`
    fell through to "ambiguous" and fabricated Mic on a camera-only QR scanner.
  - **`AVCaptureSession` is a coordinator, not a capture.** It captures nothing until an input built
    from an `AVCaptureDevice` is added, and that call carries the media type — so the session
    contributed no information the device call does not, while over-disclosing Mic on every function
    that merely touched one, including pure teardown. A member denylist did not hold (`.forEach` on
    `session.outputs` is a member call like any other), which was the signal that the TYPE was the wrong
    place to ask. Capture ambiguity is now resolved per FUNCTION: a determinate device call in the same
    body settles it, and only a genuinely undetermined capture still over-discloses both.
  - **test code sitting beside its sources** was cited as evidence a shipping manifest was wrong. Now
    excluded by `import XCTest`/`import Testing` — deliberately NOT by filename, because `ABTests.swift`
    is production code and dropping it would be the cardinal sin this filter exists to avoid.
- **A same-file build variable read as a missing key.** `INFOPLIST_KEY_… = $(SHARED_TEXT)` with
  `SHARED_TEXT` defined two lines above is a real declaration; it was discarded with NO disclosure at
  all — silence in the false-alarm direction. Same-file variables are now substituted, one level.
- **The over-declaration warning no longer reads as "delete this key."** Several keys are required by
  framework-mediated access with no call site — a web view's geolocation, a share sheet's Save Image —
  and acting on the old phrasing crashes the app at the share sheet.

## [0.27.0] — 2026-08-07

- **CI-only: the plutil differential ran on Linux and reported 38 false disagreements.** Its skip asked
  whether `/usr/bin/plutil` EXISTS — and the Linux CI image has one (libplist's) that does not accept
  Apple's `-convert json`. So the test ran, every generated case "failed to parse", and the battery
  claimed 38 disagreements that were one missing tool. Asking whether the binary is there is not the same
  question as whether it can answer. The skip is now a platform guard AND a capability probe (convert a
  trivial old-style plist and check the value comes back), as one condition so neither platform compiles
  unreachable code. The `checked` assertion — 0 cells compared, 38 claimed — is what caught it.

- **The sink guard now uses the engine's own discovery and loader** (`discoverConfigFile` +
  `loadCandorConfig`) rather than re-deriving the walk and the parse. The hand-written copy anchored an
  out-of-tree `CANDOR_CONFIG` one level too high and split `deps` on `:` alone; a second parser is a
  second set of holes.
- **⚠ `gate --report` enumerated the config channel from the REPORT's directory** while this verb's
  policy ladder discovers it from the CWD — a different question, so a config-declared policy was
  destroyed at exit 0.

- **A split narrows every policy that named the parent, silently — now disclosed.** `MotionRaw` was
  split out of `Motion` because Apple requires no usage key for the raw CoreMotion stream, which is
  correct and means an existing `deny Motion` — written by an operator who meant "no CoreMotion in this
  layer" — now PASSES a `CMMotionManager` reach while still binding, still evaluating, and still
  reporting nothing. That is a guard the operator believes is on, which is the ⟨0.24⟩ zero-match shape
  one level up, so it gets the same remedy: a stderr note naming the functions that reach the split-off
  effect and the rule to add. Verdict and exit code untouched; silent when both are denied, when neither
  is, or when nothing reaches it.
- **⚠ Flip #15 in the build-settings evaluator: the comment strippers and the statement splitter each
  tracked quotes SEPARATELY**, so any one desynchronising corrupted everything after it. A stray quote in
  a line comment — `// the "shared config` — made the block stripper read the following `/* … */` as
  string content, so a COMMENTED-OUT key was reported as declared: verified end to end through the
  shipped binary as "every MODELLED capability is declared", exit 0, on an app whose plist has none. That
  is the flip the file's own docstring records as already closed, back through a different door. The
  mirror reproduced too (`// see the note /* about camera` lost every declaration after it), as did a
  multi-line quoted value swallowing a later undeclare. Now ONE state machine, which cannot disagree with
  itself, and which handles multi-line string literals for free.
- **⚠ Flip #16: an `#include` line could not open a block comment.** The `#include` branch copied its
  whole line VERBATIM — to preserve the directive — so a `/*` sitting on that line never registered and
  the commented-out key after it was reported as DECLARED. The identical file without the include line
  answered correctly, which is what makes it diagnostic. Only the DIRECTIVE is a directive now: the token
  is emitted and the scan continues in normal mode, so quotes, `//` and `/*` after an include behave as
  they do anywhere else. A bare `hasPrefix` also matched `#includes` and `#include_foo`, which are not
  the directive; xcconfig's optional `#include?` still is. Identical answers on 129 real build-settings
  files, and the plutil differential stays green.
- **⚠ The collision guard keyed on the FLAG**, so a policy declared by `.candor/config` — the checked-in
  form CI uses — was invisible to it: `--gate-json <that policy>` destroyed it and exited 0 with
  `"ok": true`, in all four engines. It now enumerates every channel, including the `gate` verb's
  `--report`, which §3.3.1 names as an input.
- **An unreadable config was silently "no config" on the QUERY route**, dropping whatever it declared —
  a policy, a baseline, an engine pin. The scan route already refused; §3.4's posture does not vary by
  verb.
- **The `deps` splitter became Unicode-aware and refused a working config** — a dep PATH containing a
  non-breaking space was split into two nonexistent ones and the run exited 2, where java and rust loaded
  it. It also disagreed with this engine's own `CANDOR_DEPS` splitter. Paths separate on ASCII whitespace;
  only the key/value split is Unicode-aware.
- **Every keyless effect printed `Notify`'s reason.** `MotionRaw → (no Info.plist key — notifications
  gate at runtime via requestAuthorization)` is a wrong explanation attached to a right answer, which is
  the shape a reader learns to distrust. One reason per effect now.

- **A version is ASCII digits, and `Character.isNumber` is not.** `engine ٣.٣` (Arabic-Indic) and
  `engine ².0` NORMALISED as versions, so they read as a MISMATCH rather than MALFORMED — and that
  difference is load-bearing, because the "an unreadable unqualified line is not hidden by a qualified
  pin" rule keys on the normaliser REFUSING. Beside a good qualified pin the junk line was handed over
  silently and the run passed at **exit 0** while three engines exited 2. Alone, every engine already
  refused, which is why it survived a review and a five-engine matrix: only the paired shape shows it.
  Found by writing the pin grammar's first UNIT test, which contradicted an end-to-end measurement I had
  read as a refutation. candor-agents had the same defect (`str.isdigit()`); both fixed, five-way now.
- **The pin grammar moves to CandorCore** (`EnginePin.swift`), for the reason two cardinal sins already
  gave today: it was in the executable target, which SwiftPM cannot `@testable import`, so the only
  instrument that could reach it was a forty-minute cross-engine suite with one row per rule.
  `EnginePinTests` carries the fifteen spellings that matrix covered by hand.

- **⚠ `MotionRaw` was classified, gated on, and then dropped before the report.** The CoreMotion split
  shipped without an `Effect` case, so `EffectSet.init`'s `compactMap` discarded it at serialisation and
  a function whose only effect was the raw accelerometer stream serialised as `inferred: []` — under
  ⟨0.21⟩ a positive purity claim about a function with a live sensor reach. The two gate routes
  DISAGREED on the same policy and the same code (live scan exit 1, `gate --report` exit 0), because one
  reads the in-process effect set and the other reads the report the effect never reached. Removing an
  over-report had replaced it with silence, which is the worse half. `Effect` and `EffectSet` move to
  CandorCore — they were in the executable target, which SwiftPM cannot `@testable import`, so the last
  and most consequential copy of the vocabulary was untestable by construction; that is why the same
  failure had already happened once, to nine families at `privacy/3`. `EffectVocabularyTests` now pins
  the round-trip in both directions.
- **The `--gate-json` sink could be armed over the gate's own inputs.** `--policy P --gate-json P` armed
  the fail-closed refusal over `P`, the now-JSON policy parsed as zero rules, and a run that exits 1 on
  the same code exited **0 with `"ok": true`** — a machine-readable all-clear produced by deleting the
  question. Introduced by the arming commit itself: before it the sink was written only on a refusal, so
  there was nothing to destroy. Aimed at `<target>/.candor/config` the same mechanism deleted the config
  that DECLARED the policy. Now refused (exit 2, nothing written), with sameness resolved as artifacts —
  symlinks and `./` spellings included — and `.candor/config` refused by shape wherever it is.
- **Arming moved ahead of every exit, including usage errors.** It ran after the flag loop, so
  `--gate-json G --frobnicate` wrote a refusal into `G` while `--frobnicate --gate-json G` left the
  previous run's green at `G`: the contract depended on argv ORDER. SPEC §3.3 names an unknown flag as a
  broken-gate-config exit-2 cause. The `gate` verb registered a sink but never armed at all — and its
  own comment explained why registering is not arming.
- **A `--gate-json -` consumer got zero bytes on two exit paths** (unknown flag, nonexistent target)
  while an unreadable policy on the same sink produced a proper refusal — same run, same sink, three
  different answers. All three now emit exactly one refusal document.
- **The build-settings reader is a real evaluator, not a substring scan.** Eight further cardinal-sin
  flips, all with one root: it asked "does this text appear on this line" when the question is "what
  does this assignment evaluate to". A key name inside another setting's quoted value declared the key;
  two settings on one line broke BOTH honesty halves at once (the empty one read as declared, the
  genuine one was never seen); only the first `[cond]` group was skipped; a `/*` inside a quoted search
  path opened a comment that swallowed a later undeclare; a commented-out `#include` was still followed;
  and a symlinked include escaped the project tree. It now strips comments with quote awareness, splits
  into statements, and parses `NAME[cond][cond] = VALUE` with quote and bracket depth tracked. **Moved
  to CandorCore** — like the effect vocabulary it was untestable by construction, which is why three
  rewrites produced fourteen flips with no test ever going red; `BuildSettingsTests` now carries every
  one. Verified against the previous evaluator on 129 real build-settings files: identical answers.
- **Last-assignment-wins is replaced by a consistency rule.** A key assigned a real value in one place
  and left empty in another is no longer declared by whichever file was read last — an App Store archive
  is Release, and the engine cannot tell which configuration ships without the build graph. It reports
  the key as not declared and DISCLOSES the disagreement, on stderr and in the verdict JSON, because an
  inconsistent declaration is a real finding about the project rather than a limit of the reader.
- **A NO-BREAK SPACE hid an engine pin.** Config lines split on ASCII space/tab only, so
  `engine\u00A00.26.0` — what you get pasting a config out of a rendered doc — became one token, was
  reported as an "unknown config key 'engine '", and the pin went silently unenforced while a MISMATCHED
  version passed at exit 0. A false disclosure over a fail-open. Now Unicode whitespace, matching the
  other four engines; pinned five-way by conformance PART 33.
- **A second positional silently replaced the scan target** — `candor-swift . rep.json` scanned
  `rep.json` and said nothing about `.`. Now a usage error naming both.


- **`CMMotionManager` requires no usage key, and candor said it did** — reporting a shipping app as
  under-declared. Apple's `NSMotionUsageDescription` page names four APIs (`CMSensorRecorder`,
  `CMPedometer`, `CMMotionActivityManager`, `CMMovementDisorderManager`); `CMMotionManager` references
  none. The raw stream now has its own effect with no key — the access is still reported, it just isn't
  a manifest requirement. Reading Apple's list also found `CMMovementDisorderManager` mapped nowhere.
- **The build-settings reader is a value evaluator now, not a substring scanner** — it flipped to the
  cardinal sin seven more ways, every one a way somebody turns a key off or splits a file: last-wins
  empty (the Debug-declares/Release-does-not shape, and an archive is Release), CRLF resurrecting both
  earlier fixes, a `[sdk=…]` condition swallowing the `=`, `${FOO}`/`$FOO`, an unclosed `/*`, and an
  unmarked tree searching shared ancestors. Also stopped treating `#`/`//` inside a quoted value as a
  comment, which had judged real declarations empty.
- **Arming, not sink-registration.** A kill mid-run and a bare `exit(2)` both left the previous verdict;
  registering a sink only covers refusals that route through it, and enumerating exits keeps missing one.

- **A refusal must never leave the last run's green: `--gate-json` is now armed FAIL-CLOSED at run
  start.** With a mismatched or unreadable `engine` pin this engine exited 2 and left the PREVIOUS run's
  verdict document on disk, so a CI wrapper reading the artifact rather than the exit code reported a
  **pass over a run that refused** — from the release's flagship guard. Arming at the start makes it a
  class fix rather than a branch fix: every exit path leaves a refusal unless the run got far enough to
  replace it. candor-java's `armGateJson` is the model.
- **The build-settings reader flipped to the cardinal sin twice**, both by *disabling* a key — the way
  a person actually turns one off. A commented-out `INFOPLIST_KEY_…` and `= $(inherited)` each counted
  as declared, silencing the App-Store-rejection finding the verb exists to raise. The directory walk
  also had no boundary, so a stray `.xcconfig` in a shared parent satisfied the verify. Fixed, along
  with the false-alarm direction: `sdk=` conditionals and `#include`d configs now count, and `--json`
  carries `declaredViaBuildSettings` so a machine consumer can tell a plist declaration from a build
  setting seen up the tree — those are not the same claim.

- **A bare `engine <impl>` still split the family five ways.** `engine swift` — an operator forgetting
  the version on a qualified line — was skipped by candor-java and treated by the other four as a
  WILDCARD pin whose version is the literal `swift`, so it exited 2 in every engine that is *not* swift:
  one typo, a family-wide outage, on the exact property PART 33 exists to pin. The cause was arm ORDER —
  arity was tested before ownership, so the one-token case was claimed by the wildcard arm before anyone
  asked whose line it was. **A known qualifier now decides ownership first**, per §3.4's "whatever
  follows it" — and nothing following it is a case of that too.
- **`privacy-manifest --verify` now reads `INFOPLIST_KEY_*` from `.xcodeproj` and `.xcconfig`.** Since
  Xcode 13 that is where usage descriptions live by default, and the source tree's `Info.plist` often has
  none of them. Measured before the fix on three shipping open-source apps: IceCubesApp produced THREE
  false "under-declared" findings against an App Store app whose keys are all in its `.pbxproj`;
  duckduckgo/iOS carries 8 such settings and WordPress-iOS 12. A false rejection warning is worse than no
  verb — it teaches the reader to distrust the tool. It can only ADD to the declared set, so an empty
  purpose string is still not a declaration and the provenance is reported rather than silently merged (a
  setting can belong to a different target). Verified it still catches a real gap, and it found a true
  positive in the wild: WordPress-iOS calls `startDeviceMotionUpdates()` with no `NSMotionUsageDescription`.

- **A baseline DECLARED in `.candor/config` but missing is now exit 2, not a green pass.** An adopter
  review measured this as the second-likeliest first-commit mistake (`.candor/` committed, the baseline
  not) and found every engine printing a note and exiting **0** — the gate quietly not gating. The split
  is by SOURCE, because the same absence means two different things: `CANDOR_BASELINE` is set
  unconditionally by the adopt workflow, so a path that is not there means "the ratchet is not adopted
  yet" and stays a note; a checked-in `baseline` line DECLARES that this repo has one, so an absent file
  was deleted or never committed. Verified four-way: config-declared → 2, env-named → 0.


- **Panel review: the pin grammar disagreed across engines on a shared config.** Three confirmed
  divergences, each a case conformance PART 33 had not thought of, all now fixed and pinned there:
  a junked line qualified for ANOTHER implementation (`engine swift 0.99.0 junk`) killed this engine's
  own run — SPEC §3.4 now rules the skip WHOLE-LINE, because a malformed line naming another engine is
  that engine's problem and it refuses on it, while refusing everywhere turns one typo into a
  family-wide outage; `vv0.27.0` was accepted as a version by engines that stripped every leading `v`;
  and a CRLF config broke a MATCHING pin where `\r` was not treated as whitespace.


- **⟨0.27⟩ SPEC §3.4 `engine` — the engine↔baseline coupling, enforced here too.** A build that is not
  the pinned one FAILS with exit 2 (UNEVALUABLE, never 1 — a machine consumer must not read "I could not
  trust this result" as "your code broke a rule"). Two of the five verdicts deliberately do NOT change
  the exit code: an absent pin (the key is opt-in by construction) and one this build cannot check,
  which is §3.1's unanswerable-condition rule — disclosed, never scored, *including* as satisfied. An
  unreadable pin (`engine latest`) exits 2 rather than being skipped: this is the one place §6.2's
  warn-and-skip inverts, because skipping a PIN hands the operator a guard they believe is on. A pin
  qualified for another implementation is ignored — one config serves the family, which versions as a
  ladder. Pinned four-way by conformance **PART 33**.


- **The Linux leg builds again.** `entitlementRequiredKeys` read the `.entitlements` plist with
  `NSDictionary(contentsOfFile:)`, which is deprecated on swift-corelibs-foundation — and this package
  compiles with `-warnings-as-errors`, so the macOS-green change failed CI on Linux. Now uses
  `PropertyListSerialization`, which `loadDeclaredKeys` forty lines above had been using all along.


### Constant provenance rungs 3–4: computed paths resolve

`CONSTANT-PROVENANCE-DESIGN.md`'s remaining rungs, and the same primitive the Android permission work
needs. The spellings real code uses now classify:

```
NSHomeDirectory() + "/Documents/y"                      → NSDocumentsFolderUsageDescription
"\(NSHomeDirectory())/Desktop/x"                        → NSDesktopFolderUsageDescription
let p = NSHomeDirectory() + "/Downloads/z"; use(p)      → NSDownloadsFolderUsageDescription
NSTemporaryDirectory() + "/cache"                       → nothing (app-scoped)
func f(_ p: String) { use(p) }                          → nothing, and DISCLOSED as undetermined
```

**Classes, not strings** — the resolver never reconstructs a path. It looks for a proved home-directory
anchor and takes the literal that follows; an unresolvable tail keeps the prefix, because the prefix is
what decides the class. Anything without that anchor returns nil rather than a guess, so an ordinary
computed path stays undetermined and is counted by `incomplete` instead of classified on a hunch.

**`NameKeyedStateTests` caught the fabrication this introduces**, which is the third time that guard has
paid for itself. `homeAnchoredLocals` is keyed by a BINDING NAME, so without clearing it on rebind,
`func a() { let p = NSHomeDirectory() + "/Desktop" }` charged a later `func b(_ p: String)`'s parameter
the Desktop key — a fabrication from a name collision.

**And then the clearing broke the feature**, in the way the file warns about six lines above the site:
`shadowName` runs before the initializer is walked, so recording the binding first meant the rebind
immediately wiped it and only the inline form still resolved. The value is now captured before
`shadowName` and applied after — the same carve-out `fnValueAlias` documents. The file said so and I
still had to measure it.

Recall battery 66/66 including an app-scoped guard. A/B: candor-swift 38 → 38 with no changed rows, real
app 4 effects and verify exit 0 — additive.

### §2 `incomplete` — the per-function direct signal, and the ⊤ count made real

The undetermined-path count read `paths`, which **propagates**: a function counted as determined when
anything it transitively reached named a literal. One logger writing `/tmp/app.log` zeroed the count for
a whole call graph, and every real app has one — so the "clean, and zero undetermined" state the design
asked for was manufactured by ordinary code. In the other direction it counted transitive callers that
perform no file I/O at all (52% of the number on candor's own source).

The report now carries a per-function `incomplete` list: the effects whose locator **this function
itself** could not determine. Omitted when empty, so a scan that determined everything is byte-identical
to one from before the field. `FixFn` carries it; the verify counts from it.

On the real app: **282 → 57 → 4**. The first cut was inflated, the second still masked, and 4 is the
number of functions whose own file destination is genuinely unknown. That number is small enough to act
on, which is the whole difference between a warning and noise.

`--verify --json` now carries the disclosure too — `keyCoverage`, `undeterminedPaths`,
`entitlementUnderDeclared`, and `ok` agreeing with the exit code. Every §6 mechanism had lived in the
human branch only, so CI — the intended consumer of `--json` — got a bare `"ok": true`. The field is
`keyCoverage` and not `coverage` because the verdict already had a `coverage` key (the ⟨0.15⟩ uncovered-
modules block) and the first version silently overwrote it: two different questions under one name.

### `--target` refuses an unreadable dependency list

`dependencies:` read only a literal array, so two ordinary manifest idioms — a hoisted
`let coreDeps: [Target.Dependency] = ["Core"]`, or `["Core"] + extra` — yielded `deps: []`. `--target App`
then scanned App alone and reported it performing **nothing**, while the truth was that it reaches `Fs`
through Core. An empty report is a purity claim over every function in the dropped targets, and the
"stays disclosed by the coverage ledger" promise is false for a target that was never scanned. It now
exits 2 naming the idiom.

### Two more copies of the sensor vocabulary — one of them predates today

The seven-copy problem was fixed for the copies that decide WHETHER an effect is reported. Two that
decide how it is PRESENTED were missed, and a review pass over my own claim found them.

- **The scan summary dropped effects it had computed.** `main.swift`'s effect breakdown is a
  `.filter` over a hardcoded list, so an effect absent from that list was computed, counted, written
  to the report — and silently omitted from the line a user reads first. Measured: a scan reaching NFC
  and HealthKit printed `Health 1` while the report carried `['Health', 'Nfc']`. Nothing was wrong with
  the artifact; the terminal was quieter than it.
- **`tour` could not rank any sensor added after `privacy/1`.** The salience switch scored only the
  original six at 5; Health, Motion, Calendar, Bluetooth and every family since fell to `default: 0`.
  An app quietly reaching HealthKit is the exact case `tour` exists to surface, and it was the case
  `tour` ranked last. **This one has been true since `privacy/2`**, not since today.

Both now derive from `PRIVACY_EFFECTS_ORDER`. The lesson is narrower than "there were seven copies": the
copies that gate reporting were obvious to check because a missing entry made a test fail loudly, and
the copies that gate PRESENTATION failed silently — a correct report, a quieter terminal, and no
assertion anywhere with an opinion about it.

### Entitlements: 56 of 57, and one key that is honestly out of reach

**`NSCriticalMessagingUsageDescription` has no call site — Apple's page for it links no symbol at all**,
because the capability is granted by an entitlement and the API it unlocks is ordinary messaging code.
No call-graph analysis will ever see it. So candor reads the `.entitlements` file:
`com.apple.developer.messages.critical-messaging` present ⇒ the key is required.

**This is a different kind of evidence and the output says so**, rather than folding it in:

```
✗ App.entitlements grants 1 entitlement(s) whose usage-description key is not declared: NS…
  (from the ENTITLEMENTS file, not from code — these capabilities have no call site for candor
   to find, so this is a manifest-to-manifest check.)
```

Everything else this extension reports comes from analysing code. Presenting a plist diff as a
call-graph result would misrepresent what was actually checked, so the finding is labelled at the point
of output and `entitlement` is its own determination basis in the §6 breakdown.

Same discovery discipline as the Info.plist: exactly one is read, **several REFUSE to guess** (an app
with several targets has several, and reading the wrong one answers about the wrong binary — the real
app hits exactly this and says so). An entitlement present but **false** demands nothing, which is a
cheap mistake to make when reading a plist and is pinned by a test.

**`NSFileProviderPresenceUsageDescription` stays unmodelled, and that is the honest answer.** Apple
documents no API and no entitlement for it — its page links only sibling *keys*. But it applies ONLY to
an app that ships a file provider, and candor can see that, so the verify raises it **conditionally**:

```
· this app reaches the FileProvider surface, so NSFileProviderPresenceUsageDescription MAY apply.
  Apple documents no API and no entitlement for it, so candor cannot tell — check it by hand…
```

A lead where the capability is even possible, silence everywhere else. Naming it on every app would be
noise; naming it nowhere would be the gap.

### 55 of Apple's 57 — the last five, found in the docs' `references` block

The five keys that named no type in their prose named one in their DocC **references**: Apple's own page
for `NSSystemAdministrationUsageDescription` links `ODRecordSetValue`, and `NSAudioCapture` links
*Capturing system audio with Core Audio taps*. Reading the wrong part of the JSON was the whole
obstacle.

- **SystemAdministration** → OpenDirectory (`ODRecord`, `ODNode`, `ODSession`)
- **AudioCapture** → Core Audio taps (`CATapDescription`, `AudioHardwareCreateProcessTap`)
- **EnterpriseMCAM** → the SAME visionOS camera API as `NSMainCamera`, under a managed entitlement, so
  it is an ALTERNATIVE key on the existing effect rather than a family. Which of the two applies is an
  entitlement fact this engine cannot read, and declaring either satisfies the requirement.
- **AppBundles** (`/Applications/*.app/`) and **AppData** (`~/Library/Containers/`) → **path classes**.
  Apple names no API for these because there isn't one: reading another app's bundle is ordinary file
  I/O and it is the PATH that makes it protected. Two keys that looked like they needed a new mechanism
  needed none.

**Two keys stay unmodelled, with an accurate reason instead of a shrug.** They used to read
"enterprise/managed surface; not modelled", which implies nobody got to them.
`NSCriticalMessagingUsageDescription` links no symbol at all (an entitlement for emergency SMS — the
evidence is a `.entitlements` file, not a call site) and `NSFileProviderPresenceUsageDescription` links
only sibling keys (a presence capability is declared, not called). Neither is a gap in the model; both
are outside what code analysis can see, and the verify now says that in those words.

Recall battery: **62/62, 0 broken promises.**

### LocalNetwork — and `NWBrowser` was not modelled at all

**50 of Apple's 57 keys.** The `.local` host, the RFC1918/link-local literals and the bonjour descriptor
each name the local network by definition, so the key is decided without a judgement call. A public host
gains nothing — asserted by a fixture, because charging every networking app is exactly the fabrication
that kept this key unmodelled.

**The more serious half is not the key.** `NWBrowser` — Bonjour/mDNS service discovery — was in no table
anywhere: `NWBrowser(for: .bonjour(…), using: .tcp)` produced **no effect at all**, so a
service-discovery app read pure. `NetService`/`NetServiceBrowser` likewise. That is a silent under-report
on the floor `Net` effect, found while chasing an extension key, and it is fixed independently of the
privacy vocabulary.

The bonjour descriptor is gated at the CONSTRUCTOR as well as the member, because
`NWBrowser(for: .bonjour(…))` is the spelling real code uses and the member arm only sees
`browser.start()`.

### All privacy waves ship as ONE version

Development ran through four increments in two days and each bumped the extension id. But `privacy/1` is
the only version any release has carried — v0.25.0 and v0.26.0 both ship it — so `privacy/2` … `/5` never
existed for a consumer, and publishing four of them would present our git history as somebody's upgrade
path. It ships as `privacy/2`. The increments survive as narrative here and in the extension spec, where
the *order* is the useful part: each wave was found by measuring the previous one.

### Path classes: the five folder keys, at the first two rungs

`CONSTANT-PROVENANCE-DESIGN.md` rungs 1–2, plus the two remaining type-nameable families. **47 of
Apple's 57 keys are now modelled**, up from 42.

- **rung 1 — literal paths.** `contents(atPath: "/Users/me/Desktop/x")` now also yields
  `NSDesktopFolderUsageDescription`. Classes, not strings: a proved PREFIX decides the class and the
  unknowable tail is irrelevant.
- **rung 2 — the canonical spelling.** `FileManager.default.urls(for: .desktopDirectory, in:)` — real
  code asks for the search-path constant far more often than it writes a path out, and unlike a literal
  it is always readable.
- `/Volumes/…` returns **both** removable and network-volume: macOS cannot tell a disk from a mounted
  share by path, and on a privacy manifest a false prompt costs a confused user while a false silence
  costs a rejection.
- **NearbyInteraction allow-once** needed no new family at all — `privacyKeyMap` is a list and the verify
  accepts any member, so it is a second acceptable spelling of an existing key.
- **AccessoryTracking** (`AccessoryTrackingProvider`, `AccessoryAnchor`), both verified against Apple.

**The asymmetry that keeps this safe.** An unreadable *media type* still means a capture is happening, so
that case over-discloses. An unreadable *search path* is overwhelmingly an app-scoped directory needing
no key, so it yields NOTHING — charging all three folders on every `urls(for:)` call would fabricate on
ordinary code. The miss is caught by §6's undetermined-path disclosure instead. A fixture asserts an
app-scoped write gains no folder key, and the real app's 282 file operations produced no new keys.

**The battery now models the basis distinction.** A `constant`-basis miss is checked against §6's ⊤
count: disclosed ⇒ a designed residue, silent ⇒ the cardinal sin and a hard failure. The computed
spelling (`NSHomeDirectory() + "/Documents"`, rung 4, unbuilt) is correctly reported as *"not determined,
but DISCLOSED"* rather than as a broken promise — which is the design working end to end, and is only
checkable because the basis is executable rather than documentation.

### The verify reports HOW COMPLETELY, not just which keys

§6 of `candor-spec/CONSTANT-PROVENANCE-DESIGN.md`, landed BEFORE the coverage work it exists to make
safe. Today the verify's value rests on one sentence — *"here are the keys I do not check"* — and the
moment every key is nominally modelled that sentence disappears, while coverage WITHIN several keys is
still partial. Full coverage without this would be a reduction in honesty bought with an increase in
the count.

So the disclosure changes axis. Each key now carries a **determination basis**, and the verify reports
per basis rather than as one number:

```
⚠ COVERAGE: 42 of Apple's 57 documented usage-description keys are modelled
  (7 by argument · 2 by member · 33 by type).
```

`type`, `argument` and `member` are recall-complete by construction — an unreadable argument
OVER-discloses rather than going quiet. `constant` (a path or URI class decides the key) is the only
lossy basis, and it is the one that must always report a count beside it.

**The ⊤ count.** The verify now names the file operations whose PATH it could not determine:

```
⚠ 282 function(s) perform file I/O whose PATH this scan could not determine (…).
  The folder keys above are decided by the path, so those functions are exactly where an
  NSDesktop/NSDocuments/NSDownloads/removable/network-volume requirement would hide. This is a
  LOWER BOUND: a function with one determined path and one undetermined counts as determined.
```

That is the concrete form of a caveat that used to be abstract: those keys are unmodelled **and** you
cannot rule them out by reading the report either — here is how much you cannot see. When constant
provenance lands the number becomes load-bearing; today it is honest context. It is a lower bound
because `paths` is per-function, and undercounting a disclosure is the dangerous direction, so the
output says so rather than presenting the number bare.

`FixFn` carries `paths` to make this possible — defaulted empty like `privacyKinds`, because empty is
meaningful (undetermined) rather than lossy, so a report predating the field reads as "nothing
determined", which is the honest answer for a producer that was not emitting it.

### `privacy/4` — seven more families, and 42 of Apple's 57 keys now modelled

Focus status, Wallet identity, FinanceKit, the three visionOS ARKit providers (hands, world-sensing,
main camera) and temporary location accuracy. **Every type name was verified against Apple's docs JSON
before being mapped** — a wrong type→key mapping does not merely miss, it fabricates a requirement on
real apps, and this is a vocabulary it is easy to be confidently wrong about.

Temporary accuracy exposed an ordering bug: `requestTemporaryFullAccuracyAuthorization` has its own key
but sits on `CLLocationManager`, already modelled as `Location`. The type map was consulted BEFORE the
member map, so the type always won and the temporary key could never be emitted. Member-gated families
now match first; a realistic location app gets both keys, which is what Apple requires.

The 15 keys still unmodelled are the four path-triggered macOS folder keys (the same `FileManager` call
needs a different key depending on a string — value provenance), LocalNetwork, the enterprise/MDM
surfaces, and allow-once variants that are not separable at a call site. All derived, all disclosed.

Recall battery: 44/48 caught, 0 broken promises.

### `--verify` finds the Info.plist itself

`candor privacy-manifest --verify` now takes an OPTIONAL path. Bare, it discovers the plist — so the
documented flow is two commands with nothing to look up:

```
brew install candor
candor privacy-manifest --verify
```

**It refuses when a repo ships several.** The real app this was built against has two (a macOS one and
an iOS one), and verifying the wrong one is a confident verdict about a binary the reader never asked
about — the exact artifact `--target` exists to remove, reintroduced through the back door. So more than
one candidate is exit 2 with all of them named, never a pick. Exactly one is used and SAID on stderr,
because a verdict is about a specific binary's manifest and the reader has to know which.

Build output is excluded (`.app`, `.appex`, `.framework`, `Build/`, `DerivedData`, `Pods`), and so are
test bundles: the first cut listed 22 plists for an app that has 2, because every built bundle carries a
copy of one already found. A refusal that buries the two real answers in twenty derived ones has
technically not guessed and has practically not helped.

### `privacy-manifest --xml`: a paste-ready Info.plist fragment, not a reading exercise

"Generate" printed a requirements list — `Contacts → NSContactsUsageDescription (reached by: …)`. A user
with an existing `Info.plist` then had to hand-write the XML, invent the description string, and merge it
themselves. The verb's name promised a manifest and delivered homework. (It never wrote anything, so
running it against an existing plist was safe — just unhelpful.)

`--xml` emits the fragment. On `--verify` it emits **only the missing keys**, so it pipes, and the exit
code stays the verdict — the output format does not move it:

```
$ candor-swift privacy-manifest --verify Apps/PolleniOS/Info.plist --xml
<!-- candor privacy-manifest — paste into your Info.plist <dict>.
     REPLACE each placeholder string: Apple reviews these, and this text is not a
     description of what your app does with the data. -->
<key>NSContactsUsageDescription</key>
<string>TODO: why this app needs Contacts access</string>
```

A FRAGMENT, deliberately, never a whole plist: every real app already has one, and emitting a complete
document invites overwriting it. The placeholder strings announce themselves because Apple reviews that
text — a plausible-looking generated sentence would be both wrong and, precisely because it reads well,
likely to ship.

### `--target`: scope a scan to one shipped binary

`candor-swift <dir>` scans every `.swift` file under it. For a package with several products sharing a
core that charges each product with every OTHER product's effects, and the privacy-manifest verify then
answers about code the product never compiles. On a real app, scanning the repo whole and verifying
against the macOS `Info.plist` reported

```
✗ code reaches Mic (via iOSBlowMonitor.actuallyStart, …) but Info.plist declares no NSMicrophoneUsageDescription
✗ code reaches Motion (via PolleniOSApp.init()#2, …) but Info.plist declares no NSMotionUsageDescription
```

for two sensors only the **iOS** target can reach. The analysis was right; the UNIT was not a shipped
binary. The documented remedy was to hand-build a separate `Package.swift` per product — a workaround
wearing methodology's clothes.

`--target <name>` resolves that target's in-package dependency closure from `Package.swift` and scans
exactly those sources. Same app, same command, one flag:

| scan | verified against | result |
|---|---|---|
| whole repo | `Resources/Info.plist` (macOS) | exit 1 — ✗ Mic, ✗ Motion · **artifact** |
| `--target Pollen` | `Resources/Info.plist` | **exit 0** — ✓ clean, 4 effects |
| `--target PolleniOS` | `Apps/PolleniOS/Info.plist` | **exit 1** — ✗ Contacts |

The last row is the finding that survives the correct methodology, and it survives because `Contacts`
reaches the iOS binary *through the shared core* — a reach no grep of that target's own sources can see.

**Every failure REFUSES.** This feature makes a scan see LESS, and under ⟨0.21⟩ absence from `functions`
is a positive purity claim — so an unknown target (exit 2, naming the targets that exist), a closure
member whose source directory is missing (exit 2, naming what was tried), and an empty result all stop
rather than scanning less and continuing. A scoped scan also DISCLOSES its scope on stderr: a clean
verdict over one target reads exactly like a clean verdict over the package otherwise.

`Package.swift` is parsed with SwiftSyntax, not by regex — `manifestPackageName` in `main.swift`
documents at length why the regex form is fragile. `.product(name:package:)` dependencies are external,
have no sources in this tree, and stay disclosed by the coverage ledger rather than silently joining the
closure.

**A soundness bug the tests caught on their first run:** `.target(name: "Core")` is *also* the in-package
form of a dependency reference, so descending into a target's `dependencies:` array parsed the inner call
as a second DECLARATION of `Core` — one carrying no dependencies. The two entries then raced in the
by-name lookup, and when the phantom won, the closure walk stopped at `Core` instead of continuing
through its own dependencies: sources dropped from the scan, i.e. a purity claim over every function in
them. Found by asserting on the FULL target list rather than on membership.

#### A scoped report does not claim the package's identity

Found by asking what a MACHINE consumer sees: a scoped report was byte-shaped exactly like a whole-package one — same `package`, same `hash` key
namespace, just fewer functions — and the stderr scope note is not in the artifact anyone chains. Under
⟨0.21⟩ absence from `functions` is a positive purity claim, so chaining a scoped report under the
package's name reads every function in the unscanned targets as pure. The cardinal sin, introduced by a
convenience flag.

The fix needs no format change: a scoped scan qualifies the key (`MultiTarget/MacApp#…`), so a consumer
looking for `MultiTarget#…` simply misses — and a miss is DISCLOSED, not silent.

The first attempt at that also put the target in the FILENAME, so a package's scoped reports could
coexist. That read as a feature until discovery had to choose between them: after `--target MacApp` the
privacy verb reported the microphone, which only the iOS target reaches. A silently wrong answer is worse
than the overwrite it replaced, so a scan writes ONE current report exactly as before, and `--out` is how
you keep several.

### fix: `toShare: nil` is read-only, and claiming otherwise failed every read-only HealthKit app

`privacyKind` treated `requestAuthorization(toShare:read:)` as unconditionally ambiguous and declared BOTH
directions. But `toShare: nil` is the canonical read-only spelling and is right there in the source — so a
read-only HealthKit app was charged with a WRITE and told it needed `NSHealthUpdateUsageDescription`.

That is a false under-declaration on the commonest shape in the framework, and it is the FABRICATION
direction this extension explicitly fences — not the over-disclosure the ambiguity rule is meant to buy.
Found reviewing my own privacy/2 work, not by a failing test.

Measured: a read-only app against a Share-only plist now exits 0; an app that also calls `save` against the
same plist still exits 1 naming the write. A non-nil `toShare:` set, or an argument the engine cannot see,
stays ambiguous and declares both — the invisible case must never resolve to the convenient side.

The durable lesson is narrower than "be careful": before declaring an ambiguity, check whether the
discriminating argument is actually invisible. Here it was in the source all along, exactly as the
media-type and entity-type discriminators already assume.

### `privacy/2` direction — the verify is no longer silent on read vs write

The privacy case study shipped with a stated limit: *"the verify is sound on PRESENCE and silent on
DIRECTION"*. Apple splits three key families — HealthKit Share/Update, Photos full/Add-only, Calendars
full/write-only — and treating each pair as interchangeable alternatives meant an app that both reads and
writes HealthKit passed while declaring only Share, then got rejected. That limit is now closed.

`privacyKind(root:member:)` refines a call ALREADY classified as a privacy effect with the direction its
verb implies, on exactly SPEC §2 `fs`'s contract: `["read"]`, `["write"]`, `["read","write"]`, or `[]`.

THE EMPTY CASE IS THE SAFETY PROPERTY, and it is why this could ship without re-auditing anything: an
unrecognised verb contributes nothing, and an effect with no proved direction keeps the pre-`privacy/2`
behaviour EXACTLY — any acceptable key satisfies it. The refinement can only ADD a requirement where a verb
said. A report predating the field verifies identically, so the upgrade cannot turn a passing project red
by itself.

Measured end to end: code that reads and writes HealthKit against a Share-only plist now exits 1 with
`✗ code reaches Health (write) … declares no NSHealthUpdateUsageDescription`, naming the writing functions;
with both keys it exits 0. On the real app both targets are PROVED to read and write Health and both plists
declare both keys — verdicts unchanged, which is the regression check that matters.

Asymmetry worth stating: Add-only satisfies a write and NOT a read, and write-only likewise. Tests assert
that directly, because getting it backwards is an App-Store-shaped wrong answer.

`requestAuthorization(toShare:read:)` names both sides in one call and its discriminating argument is a
runtime Set, so it is genuinely ambiguous and declares BOTH — the extension's standing trade-off.

The key tables moved to CandorCore beside `privacyKind`. The discriminator and the key families it selects
from are one concept, and splitting them across modules is how a pair drifts apart.

KNOWN LIMIT: direction resolves where the receiver's TYPE does. A module-level `let` used across files
yields none — which falls back to any-key, i.e. fails safe.

### SPEC §2 `fs` — candor-swift now emits the read/write refinement it never had

`fs` has been in SPEC §2 since long before this engine, and rust and java carry it. candor-swift did not:
its only `fs` was the effect-name enum case. So a consumer asking "does this function read the disk or
mutate it" got the answer from two engines and silence from a third.

It went unnoticed because the spec's own rule makes partial implementation HONEST — an absent `fs` means
"kind undetermined", never "read-only" — which is the design working, not an excuse. The gap is still a
gap.

**CORRECTED before release — the first version of this was direct-only and that was wrong.** I read
candor-java's `fsDirect` comment ("kind performed directly") and never followed it to `fsFixpoint()`, which
propagates over edges AND injects an `FS_UNKNOWN` poison that suppresses the whole field. So kinds DO
travel: a caller that transitively only writes is a writer, and saying so is the point of the field. What
must not travel is a PARTIAL answer — if any contributing `Fs` has no determined kind, the field is
suppressed entirely, because `["write"]` there would claim "writes but never reads" about a function that
may do both. Conformance PART 31 caught the divergence on its first run.

Measured: `copyItem` → `["read","write"]`, `contents` → `["read"]`, `createFile` → `["write"]`, a caller of
a writer → `["write"]`, and a function reaching one writer plus one undetermined-kind callee → omitted.

The verb table is deliberately the same shape and vocabulary as candor-java's `fsKind`. The surface is
spec'd four-way; two engines inventing two verb tables for one field is how a shared field stops meaning
one thing.

Tests assert what the classifier REFUSES to say as much as what it says — an unrecognised verb returns
nothing at all, and a bare `FileHandle(...)` reveals no direction. Both probed by breaking them.

### `privacy/2` — the sensor vocabulary goes from six to eighteen

Writing the privacy-manifest case study is what surfaced this. A real app's `Info.plist` declares
`NSMotionUsageDescription` and two HealthKit keys, and `privacy-manifest --verify` said **nothing about
them in either direction** — neither required nor flagged as unused — because the effects did not exist.
`exit 0` meant "the six I model are declared" while reading as "your plist is right", which is the
absence-is-a-claim shape ⟨0.26⟩ closed for sidecar keys.

Added: `Health`, `Motion`, `Calendar`, `Reminders`, `Bluetooth`, `Speech`, `Biometrics`, `MediaLibrary`,
`HomeKit`, `Tracking`, `NearbyInteraction`, `Siri` — with their Info.plist key families. Measured on the
same app: the macOS target now reports 4 effects where it reported 3, and Motion resolves on iOS.

DECISIONS WORTH THE INK:
· **The extension version moved with the vocabulary.** A consumer that understands `privacy/1` expects
  exactly six effect names; emitting `Health` under that label would make the extension's own positive
  declaration inaccurate. The envelope now discloses `privacy/2`.
· **`EKEventStore` is ambiguous exactly like `AVCaptureDevice`** — one type serving calendars AND reminders,
  chosen per call by an `EKEntityType` — so it gets the same treatment: a statically-visible
  `.event`/`.reminder` refines, anything else over-discloses both. Same code shape as `mediaTypeArg`
  DELIBERATELY, so the two cannot drift into different rules for one problem. Measured and documented: a
  local CONSTRUCTOR carries no entity type, so a function that builds a store declares both even when every
  call on it is refined — and `AVCaptureSession()` was verified to behave identically, so this is the
  trade-off already chosen rather than a new one.
· **Value types are excluded on the `CLLocation` precedent** — `HKQuantity`, `CMDeviceMotion`, `EKEvent`,
  `CBUUID`. Holding a reading is not taking one, and there is a test asserting they stay unclassified.
· **`LocalNetwork` is deliberately absent**, with a test asserting so. `NSLocalNetworkUsageDescription` is
  real, but the reach is not separable from ordinary `Net` by type (`NWBrowser`/`NWConnection` serve both)
  and the key travels with an entitlement this engine does not read. Guessing fabricates on every
  networking app.
· **`Speech` is not `Mic`** — capturing audio and recognising it are separate authorizations with separate
  keys, and an app can do either without the other.
· **A modelled TYPE is still not a covered MODULE, and the ledger keeps saying so.** A scan that charges
  `Health` on `HKHealthStore` still lists HealthKit as uncovered, because the rest of the framework is
  genuinely unmodelled. Marking the module covered would convert a disclosed blind spot into a silent
  purity claim over every other type in it — the cardinal sin, bought for a tidier-looking report.

KNOWN LIMIT, stated rather than left to be discovered: the verify is sound on PRESENCE and silent on
DIRECTION. HealthKit's two keys are not alternatives in Apple's model (Share gates reading, Update gates
writing) and this engine does not tell read from write at the call site, so an app declaring only Share
while also writing passes here and is rejected by Apple. Same for the EventKit pairs.

Tests: every new type asserted, the value-type exclusions asserted, the EventKit discriminator asserted
against all four inputs, and the LocalNetwork omission asserted. Each probed by breaking it.

## [0.26.0] — 2026-08-04 ⟨spec 0.26⟩

### ⟨0.26⟩ THE HIERARCHY SIDECAR'S KEY SET IS ITS MANIFEST — producer half, and PROTOCOLS WERE MISSING ENTIRELY

SPEC §2.2 `ea3de21`. This engine is a PRODUCER only (it ships no `callers` verb), and it had two gaps.
The sidecar inverted `conformers`, so only a type that HAS a supertype got a key at all. And protocols
were absent ALTOGETHER — they are held out of `conformers` by design (a protocol name there pollutes the
concrete-dispatch CHA and its `impls.count == conf.count` guard) and their `protocol Sub: Sup` edges live
in a separate map the sidecar never read:

    BEFORE   {"Impl": ["Mid"], "Sub": ["NSObject"]}
    AFTER    {"Base": [], "Impl": ["Mid"], "Loner": [], "Mid": ["Base"], "Sub": ["NSObject"]}

So `Impl <: Base` was unanswerable for a relation this pass actually knows. Writing them into the SIDECAR
cannot reach CHA — it is a separate output and `conformers` is untouched.

Keyed from `declaredTypes`, NOT `localTypes`: the latter also holds extension-only platform types, whose
supertypes this pass cannot see, so `[]` for them would be the false claim the rung exists to remove. Same
reason `NSObject` stays ABSENT while `Sub` keys `["NSObject"]`.

## [0.25.0] — 2026-08-02

⟨spec 0.25⟩ **Floor bump only — no behaviour change in this engine.** SPEC §2 chaining rule 1 now states
that an ambiguous join key is UNIONED rather than dropped; this engine already implemented the union
(conformance PARTs 25/26 pin it four-way), so 0.25 records the contract catching up with the code. See
candor-spec/CHANGELOG.md for the measurement and the reversal note.


### fixed — a per-entry reader of `unverified` could not see the refusal (2026-08-01)

The rung below put the unjudged function into `unverified` and its reason into the top-level
`unevaluated[]`. That is enough for a reader of the DOCUMENT and not enough for a reader of an ENTRY:
the two are joined only by the raw rule string, and nothing in the entry says the join exists. A lost
disclosure, not a fabrication — the information was in the document, one array away from where a
per-entry consumer looks.

MEASURED four-way over the conformance R11 report under `deny Net[unknown-host] app`, keys **per
entry** — not the union, because the two entry kinds differ and that is the finding:

| | ordinary hole (`app.nativeHole`) | unjudged (`app.noClass`) |
|---|---|---|
| rust | `fn, rule, unknownWhy, upgrade` | `fn, rule, why` |
| java | `fn, rule, unknownWhy, upgrade` | `fn, rule, unknownWhy, upgrade, why` |
| ts | `fn, rule, unknownWhy, upgrade` | `fn, rule, why` |
| swift **before** | `fn, rule, unknownWhy, upgrade` | `fn, rule, unknownWhy, upgrade` |
| swift **after** | unchanged | `fn, rule, unknownWhy, upgrade, why` |

- **`why` is NOT a universal key**, and the measurement is why. No engine puts one on an ordinary hole
  — that entry's reason is `unknownWhy`, and a gate-refusal field sitting beside it would invite a
  reader to take its absence as a statement. It is emitted exactly where a rule was WITHHELD, which is
  the one place a per-entry reader could not previously tell that anything had been withheld.
- **The reason-class arm is where swift lost the most**, and it is invisible in the `Net` column above.
  Under `deny Unknown[dispatch] app` over an inherited-`Unknown` report the function is BOTH an ordinary
  hole and unjudged. rust and ts emit two rows for that one (fn, rule); java merges; swift dedupes to
  one row and the refusal was dropped. So the fix could not be *"add `why` to the rows the answerability
  pass appends"* — the arm that needs it most has no such row. It attaches to the (fn, rule) PAIR,
  whichever pass emitted it: java's merged shape, and the only one of the three that leaves swift's
  one-row-per-pair rule intact.
- The three engines that carry it **do not agree with each other**, so this is not a majority vote. It
  is that a per-entry consumer written against ANY of the three found nothing in swift's entry.
- Same bytes as that entry's own `unevaluated[].why` (§3.2: inventing a second spelling is the mistake
  the document has already made four times) — but per (fn, rule) rather than per rule, since an entry is
  read about its own function while `unevaluated[]` names one exemplar per rule.
- Additive: no key repurposed or dropped, no row added or removed, ordinary holes untouched. Pinned by
  five rows in `AdvisoryBoundProcessTests` — two for the defect (both arms), one for the single
  spelling, and two mirrors: an ordinary hole must carry no `why` at all, and the row count and key sets
  must be otherwise unchanged. The over-report mirror passed before the change and is the load-bearing
  half: a blanket `why` would make the key's presence say nothing.

### fixed — ⟨0.24⟩ three advisory verbs answered a question the gate had refused (2026-08-01)

SPEC §3.2 (candor-spec `4fd140c`): **an advisory verb may be LESS certain than the gate, never more.**
Stated as a law after three local patches — a lenient manifest reader, a hole predicate ignoring the
class filter, and a fallback derivation — that differ in mechanism and share only the direction of the
error. This is the third instance, and its mechanism here is a fourth one again.

MEASURED on the conformance R11 report (`app.nativeHole` = an Unknown outside the policy's class filter;
`app.noClass` = `Net` + `hosts` and NO `netClass`; `app.writes` = a plain `Fs` violator) under
`deny Net[unknown-host] app`:

| | before | after |
|---|---|---|
| `gate --report` | exit **2** — it cannot judge `app.noClass` | unchanged |
| `unverified --json` | `ok:false`, names **only** `app.nativeHole` | names `app.noClass` too, + `unevaluated` |
| `unverified --strict` | exit **0** — green | exit **2**, `ok` omitted |
| `fix-gate --strict` | exit **0**, `ok:true` — green | exit **2**, `ok` omitted |
| `fix app.noClass Net` | `crossing:false, reason:"not-forbidden"` | `reason:"unanswerable"`, `crossing` OMITTED, + `unevaluated` |

`app.noClass` was CLEARED by the verb whose entire job is *"your green gate is not provably green"*,
while the gate declined to clear it over identical bytes. **The mechanism here is NOT the fallback
derivation §3.2 describes** — `matcherNetClasses` reads `netClass` verbatim and derives nothing — it is
that `unverified` only ever considered `Unknown`-carrying functions, so a function the gate could not
judge for a different reason had no channel and fell off the end. An assertion of the form *the verb
names SOMETHING* passed throughout, because the verb names a DIFFERENT hole; only the per-function form
catches it.

- The answerability predicate moved to `CandorCore/Answerability.swift` and `gate --report` now calls
  it. A law that is a COMPARISON cannot be checked from two implementations of the thing compared. The
  prose, iteration order and one-entry-per-rule granularity are unchanged, so the gate's bytes are the
  bytes it emitted before (conformance R6 pins that four-way).
- `unverified` names every (rule, function) the gate could not decide, with the **missing evidence** as
  the reason — carried in the gate's own `unevaluated: [{rule, why}]` (§3.1, `fc4b5f6`), not a second
  spelling — and the **evidence-free rule** as the `upgrade` (`deny Net[unknown-host] app` →
  `deny Net app`), which is what the gate's own refusal already recommends. Never a derived class.
- `fix`/`fix-gate` withhold any remedy whose anchor, pure span or hoist frontier contains a function the
  gate could not adjudicate FOR THAT EFFECT: *"a hoist plan for a boundary the gate could not adjudicate
  is a confident instruction resting on a guess."* Keyed on the effect, not on "some rule went
  unanswered" — the gate keeps charging the violations it is sure of (§3.1 precedence), and a verb that
  went quiet on an `Fs` crossing because a `Net` filter was unreadable would be LESS useful than the
  gate rather than merely less certain.
- `--class` does NOT filter these entries out. Excluding them would make the filter succeed BECAUSE THE
  EVIDENCE IS MISSING — this rung's defect one level down — and it is wrong on §6.2's own terms: the
  class set only grows, so an `Unknown` nobody classified could be `dispatch`.
- `fix`'s `does-not-perform` answer carries NO disclosure: it is read off the effect set, depends on no
  rule, and is not a claim the gate could contradict. Attaching it anyway fired on 141 of 195 sampled
  answers, which is how a disclosure stops being read.
- **AND THE DEFECT THIS CHANGE NEARLY INTRODUCED IN THE MIRROR DIRECTION**, caught in self-review before
  it shipped: the first cut withheld `fix`'s plan by answering `crossing: false`, which over a CERTAIN
  crossing whose only unadjudicable function is a hoist target would have turned a violation the gate
  CHARGES into a non-finding — a silent under-report arriving inside a fix for its opposite. `crossing`
  now says what is known and nothing else: **omitted** when the rule governing the queried function
  could not be read (undetermined, the same reasoning that omits `ok`), **`true`** when the crossing was
  decided and only the hoist plan was withheld. One new `reason` token, no new field.

**WHAT THE CORPORA EXERCISE: NOTHING, and that is the measurement.** `~/git/pollen` (1096 entries) and
this repo's `Sources` (184) carry **0** entries with `hosts` and no `netClass`, **0** `Net` entries
without `netClass`, and **0** `Unknown` entries with neither `unknownWhy` nor a `calls` edge — because
this producer floors `netClass` at `unknown-host` and records a reason beside every `Unknown` it raises.
A report THIS engine wrote cannot reach the defect; the reachable case is a report **another** producer
wrote, which is exactly what `gate --report` exists for. So the A/B is a no-regression control and the
value is measured on a DERIVED corpus:

- **A/B, both real corpora**: 288 paired `unverified`/`fix-gate` runs (12 policies × 4 flag sets) and
  7488 paired `fix` runs (12 policies × a 1-in-17 stride × 3 effects) — **0 differences, 0 functions
  lost**. Scan report bytes byte-identical.
- **DERIVED corpus** — the same pollen graph with `netClass` deleted from all 50 `Net` entries, i.e. a
  report from a producer that does not carry the ⟨0.20⟩ field. `gate --report` exits 2;
  `unverified --strict` went 1 → 2 and 459 → 460 holes (`AggregationClient.upload`, the one `Net`
  function not already named as an `Unknown` hole); `fix-gate --strict` went **0 (`ok:true`, green) → 2**.
- **DERIVED corpus 2** — `unknownWhy` + `calls` stripped (1356 fields). `unverified --strict` 1 → 2 with
  the same 459 holes: the containment already held here BY ACCIDENT, since those functions carry
  `Unknown` and the narrowed rule does not bite them. What was missing was the disclosure and the exit
  code — which is why every row of the new suite asserts a FUNCTION and an exit code, not a count.
- Across all four corpora: **0 functions lost, 1210 gained**, every gain on a derived corpus.

Conformance **R11 `swift advisory-bound` now OK** (it was FAIL and waived four-way); its baseline waiver
now reads stale, and that ratchet fires in candor-spec, not here. New `AdvisoryBoundProcessTests` (19
rows, 9 of them mirrors that pass on the unmodified build); 554 tests, smoke 108, fuzz 25 seeds,
fabrication-probe clean; PART 27 all-swift-OK and the four-way suite otherwise unchanged.

KNOWN RESIDUAL, stated rather than papered over: when `fix-gate` withholds a plan it drops the CROSSING
from `remedies` along with it — `remedies[]` has no shape for a crossing without a plan, where the
single-function `fix` does. The compensating channel is the one §3.2 names: `ok` is omitted,
`unevaluated` names the rule, and `--strict` exits 2, so no consumer can read it as clean. Not reached
on either real corpus (0 remedies withheld in 288 paired runs).

*(Amends the `conditional` note below: "there is no unanswerable narrowing to disclose" was true of the
HYPOTHETICAL surface candor-swift does not ship, and remains so — but the REPORT route does have one,
and `fix` now answers `unanswerable` rather than `not-forbidden` when it hits it.)*

### measured, no change — ⟨0.24⟩ `violations[].conditional` is N/A for candor-swift (2026-08-01)

SPEC §3.1 pins `violations[].conditional: "<the narrowing left unevaluated>"` (candor-spec `6f30540`,
corrected by `901f14d`), and it is rust-only. Measured here before building anything, because the pin is
a **`whatif` output** and candor-swift ships no `whatif`:

- Verified against rust's OUTPUT, not a description of it —
  `candor-query whatif cap_from_name Net --policy 'deny Net[unknown-host]' --json` emits
  `violations[0].conditional: "the \`Net\` you introduce reaches destination class unknown-host"`, a
  per-violation STRING, and the bare `deny Net` control emits the same document with the key absent.
- candor-swift's verb set is `path tour gains fix fix-gate unverified privacy-manifest gate parsepolicy`.
  `whatif` is not among them and exits 2 (AGENTS.md already points the general read-only queries at
  `candor-query`/`candor-ts-query`); SPEC §3.1 makes the query verbs SHOULD and names candor-swift's
  subset explicitly.
- **And no other surface here asks the question.** `conditional` exists because a hypothetical has no
  destination or reason class for a narrowing filter to quantify over, so the filter cannot be evaluated
  and the fail-closed verdict rests on an unevaluated condition. Every candor-swift verb reads a
  signature that EXISTS: `fix <fn> <Effect>` over an effect the function does not have answers
  `crossing: false, reason: does-not-perform` rather than charging a hypothetical, and after the
  `deny Net[…]` fix above a narrowed rule over a REAL `Net` is EVALUATED (`reason: not-forbidden`), not
  deferred. There is no unanswerable narrowing to disclose, and emitting the field anyway would assert a
  condition the analysis did not leave open.

No code change. Recorded so the next pass does not re-open it.

### fixed — and `deny Net[…]` was the same defect again, one field over (2026-08-01)

`DenyRule.netClasses` had the identical shape to the `unknownClasses` defect below: parsed, populated,
and read by neither `deniedLayer` nor `unverifiedHoleRule`. Same verb pair, same two directions.
MEASURED on `deny Net[unknown-host] app` over a report whose only Net reaches a `known-partner` host:

| verb | before | |
|---|---|---|
| `gate` | exit 0 | correct — the destination class is excluded |
| `fix-gate --strict` | exit 1 + a remedy naming `app.callPartner` | OVER-CHARGE: a hoist instruction for a boundary the policy does not deny |
| `unverified --strict` | exit 0, `ok: true` | UNDER-REPORT: an `Unknown`-carrying passer goes unnamed |

**What made this one different, and it was the whole of the work.** A reason class is DERIVED from
fields the records already carried (`unknownWhy` + `direct` + `calls`, §6.2's own resolution). A Net
destination class cannot be: it is a function of the host literal surface and the project's
`net-partner` set, and neither travels on a `FixFn`. So it is THREADED — the report's own ⟨0.20⟩
`netClass`, read verbatim the way `gate --report` reads it, on records where the field is
**non-defaulted** so no construction site can silently rebuild the bug. No second fixpoint: the
producer writes `netClass` from the already-accumulated host surface, so the transitive answer *is* the
field's value, and re-deriving it could only disagree with the gate.

An empty class set means NOT-forbidden, for destinations as for reasons — the disclosing direction for
both callers, and the same withholding `evaluateGate` performs. The unfloored/floored reason-class split
is untouched (the matcher takes the unfloored map, `--class` keeps the floored one).

MEASURED A/B, pollen and candor-swift's own `Sources`, 6 policies × 3 verbs × 2 corpora:

- **Gate verdicts moved: 0.** All 12 `gate` cells byte-identical, and all 4 scan-route `--policy` runs
  exit-identical. This changes what is disclosed, not what is decided.
- **Holes no longer named: 0.** Every A/B cell, both corpora.
- **Holes newly named: +49** on pollen under `deny Net[known-partner]` (410 → 459) — Unknown-carrying
  functions the narrowed rule PASSES, which `unverified` had been certifying clean. Same +49 on the
  scan-time note.
- **Remedies withdrawn: 6** (pollen, `deny Net[known-partner]`, exit 1 → 0), against a `gate` that exits
  0 on the same report and policy. Those were hoists proposed for a boundary the policy does not deny.
- **Unnarrowed policies byte-identical**: `deny Net`/`deny Exec`, `pure`, `deny Unknown[dispatch]`.

Reachable before this fix and much more so after it, so fixed with it: `ruleUpgrade` reconstructed a
rule from `effects` + `scope` alone, dropping every narrowing filter. Under `deny Net[unknown-host] app`
it told the operator their rule was `deny Net app` and offered `deny Net Unknown app` as the fix —
an edit that **silently widens the Net denial from one destination class to all of them** while
presenting itself as the addition of one token. 408–410 rows per pollen run carried that. Each term is
now spelled with its own filter and the upgrade widens the `Unknown` term alone, byte-for-byte the rust
reference's `rule_and_upgrade` (PART 12d pins the two against each other) — which subsumes and replaces
the raw-line source form the entry below introduced.

Pinned by `ScopedNetRemedyProcessTests` (14 rows: 2 gate controls, and every "must now be silent" paired
with a "must still fire", including the absent-`netClass` row where the gate's answer is a refusal).
Suite 535 passing (3 module-const rows still expected failures); smoke 108/108; fuzz 25/25;
fabrication-probe clean; conformance PART 27 green, 16 live swift cells OK.

### fixed — a class-scoped `deny Unknown[…]` meant something different to `fix-gate` and `unverified` than to the gate (2026-08-01)

`DenyRule.unknownClasses` was parsed and populated, and **neither `deniedLayer` (the `fix`/`fix-gate`
crossing predicate) nor `unverifiedHoleRule` (the provable-purity predicate) consulted it.** Both read a
narrowed rule as the bare `deny Unknown`, and off that one missing conjunct they broke in OPPOSITE
directions. MEASURED on `deny Unknown[reflect,unresolved] app` over a report whose only hole is
`native:dlopen`:

| verb | before | |
|---|---|---|
| `gate` | exit 0 | correct — the class is excluded |
| `fix-gate --strict` | exit 1 + a remedy naming `app.nativeHole` | OVER-CHARGE: a red CI check and a hoist instruction for a boundary the policy does not deny |
| `unverified --strict` | exit 0, `ok: true` | UNDER-REPORT, and the worse half |

The second is why both halves are one change. The layer PASSES the function while it still carries an
`Unknown` — that IS a pass-but-Unknown hole — and `unverified`, the verb whose entire job is to say a
green gate is not provably green, returned a green of its own. Fixing only the fabrication would have left
its silent mirror standing.

Both predicates now go through one `ruleForbids`, taking the function's TRANSITIVE reason classes
(`unknownWhy` now rides on `FixFn`, non-defaulted). An empty class set means NOT-forbidden — matching
`evaluateGate`, which withholds a scoped rule rather than charging on a default — and that is the
disclosing direction for both callers: `fix-gate` withholds a remedy the gate would not charge, and
`unverified` reads "not forbidden" as "this layer passes it" and names the hole. The map is UNFLOORED for
matching and stays FLOORED for `--class` filtering; each is the conservative choice for its own question.

MEASURED, pollen (`~/git/pollen`, 459 Unknown-bearing functions) and candor-swift's own `Sources` (54):

- **The partition is now exact.** Every Unknown-bearing function is either a gate violation or a disclosed
  hole. Before: up to **459** functions (pollen) and **54** (self) were NEITHER — silently certified.
  After: **0**, on all 7 narrowed policies tested.
- **Zero real disclosure loss.** Every function the gate charges is still covered by a remedy — uncovered
  = 0, before and after. The remedies that disappeared (up to 292 on pollen) were all for functions the
  gate does not charge.
- **Unnarrowed policies are byte-identical** — `pure`, `deny Exec`, `deny Net Exec Fs`, `deny Unknown`,
  and `deny Unknown[dynamic]` (which expands to every genuine class, so it is the convergence control).

Reachable only through this fix, and so fixed with it: `ruleUpgrade` reconstructed a narrowed rule with
its class filter dropped and appended a second token, offering the operator `deny Unknown Unknown app` as
the edit that fixes their gate. A narrowed rule's source form is now the raw line and its upgrade is that
rule UNNARROWED.

Pinned by `ScopedUnknownRemedyProcessTests` (12 rows: 2 gate controls so the comparison cannot go vacuous,
and every "must now fire" paired with a "must still be named"). Four-way conformance OK incl. PARTs 12b
and 27.

### fixed ⚠ — a rebound `Process` program reported BOTH commands (2026-08-01)

The command surface was a union of every locator write to a handle, with no notion of one write killing
another:

```swift
p.executableURL = URL(fileURLWithPath: "/bin/sh")
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
try? p.run()                                    // reported cmds: ["/bin/sh", "/bin/zsh"]
```

Only `/bin/zsh` can run, so `/bin/sh` sat on the surface for an execution that does not exist and
`allow Exec /bin/zsh` failed on it. FAIL-CLOSED — a spurious failure, never a missed one — so a false
positive rather than the cardinal sin.

It was worth fixing because the engine's two locator mechanisms disagreed about one shape: the
URL/URLRequest path WITHHOLDS on a straight-line rebind (`u = URL(…)` enters `movedNames`, no host is
claimed) while this path unioned. Withholding here instead would have cost every ordinary single-write
`Process` its command.

A write W now kills an earlier write V iff **W's enclosing statement list is V's list or an ancestor of
it** — "control reaching past W has passed through W and can no longer be carrying V". Deliberately NOT
collapsed, each pinned by its own test: a conditional second write (`if c { p.launchPath = … }`), a pair
inside a block read from outside it, and anything across a closure boundary. `execLocatorInvisible` is not
subject to the kill either — a literal that dominates an unreadable write does overwrite it, but that is
the one direction here that turns a refusal into a claim, and its only support would be the dominance
argument being introduced in the same change.

A/B: **zero field diffs** across pollen, swift-syntax and candor-swift's own sources (8.5k functions) — no
command, host, path or effect moved on any real code; the shape is rare, which is also why it survived.

### fixed ⚠ — ⟨0.24⟩ `unverified --strict` and `fix-gate --strict` certified an INCOMPLETE report (2026-08-01)

SPEC §3.2 ⟨0.24⟩ (candor-spec `0075987`). The gate has honoured the ⟨0.21⟩ completeness manifest for three
rungs — `ok` requires no violation AND a complete analysis, and an incomplete-but-clean report exits 2.
Nothing else did. candor-ts measured the same hole in its MCP `candor_gate`; this engine ships no MCP and
no LSP, so the equivalent surfaces are its other machine-output verbs, and two of them had it. Measured,
one report declaring one `unanalyzed` unit, one policy that finds nothing:

    gate --report R --policy P          exit 2    ok:false   incomplete:true + the manifest
    unverified --strict …               exit 0    ok:TRUE
    fix-gate   --strict …               exit 0    ok:TRUE

`--strict` is how CI consumes both, so a pipeline running `unverified --strict` over a partially-parsed
tree got a green from the verb whose whole job is "not PROVABLY clean".

**The shape is `whatif`'s, not the gate's: `ok` is OMITTED.** These verbs are advisory, and their
`ok: false` does not mean "did not certify" — it means "a hole/crossing EXISTS, here it is". A `false`
beside an empty `unverified`/`remedies` array would assert a finding the run never made, which is the
fabrication mirror and worse than the `true` it replaces; `true` over a knowingly partial universe is the
over-claim. So `incomplete: true` plus the manifest take the field's place, `if (r.ok)` reads falsy and
fails safe, and `--strict` exits **2** rather than the 1 that would claim a finding. The arrays still ship:
a partial answer that says it is partial beats a refusal. The gate keeps `ok: false`, unchanged — there the
`false` is a statement, not an invention.

A COMPLETE report is byte-identical to before, asserted in the same test.

### changed ⚠ — ⟨0.24⟩ `policyVocabulary.aliases` is an OBJECT, mapping each alias to its classes (2026-08-01)

SPEC §3.1 ⟨0.24⟩ (candor-spec `7f5b5ba`). This engine emitted `aliases: ["corp"]`, as did rust and java;
candor-ts emitted `{"corp": ["reflect"]}` and is right. The ruling did not go to the majority because it
was argued from §3.1's own sentence: `configSources: [path]` is rejected there because *a disclosure that
names the source but not the content leaves the reader knowing they were affected and not how* — and the
array of alias NAMES fails that same test one level down. Measured here, one unchanged policy line
`deny Unknown[corp] app` over one unchanged report whose only hole is `native:`:

    unknown-alias corp = reflect           exit 0      disclosed  aliases: ["corp"]
    unknown-alias corp = reflect,native    exit 1      disclosed  aliases: ["corp"]

Two different gates, one identical disclosure — so a reader diffing the two verdicts saw the exit flip with
nothing in the document accounting for it, and had to open the config file the disclosure exists to save
them opening. The value is now `{"corp": ["reflect"]}` / `{"corp": ["native","reflect"]}`.

A strict SUPERSET: the key set is exactly the array it replaces, so a consumer that only wanted the names
still has them. `config` is unchanged, and the block is still emitted only when a vocabulary was actually
consumed. Both gate routes build it from one shared function (`consumedAliasVocabulary`) — §3.1's
byte-equality between `scan --policy` and `gate --report` is a MUST, and this field's own history is what
two independent constructions of one disclosure cost.

### fixed ⚠ — a shadowed `Process` binder named the outer handle's program (2026-07-29)

The exec locator maps are keyed by NAME and body-wide. A `let p` inside a block SHADOWS an outer handle,
writes its literal under the same key, and the outer `p.launch()` below the block then reported a program
that handle was never given:

```swift
func spawn(make: () -> Process) {
    let p = make()                                          // locator unknown, never written here
    if true { let p = Process(); p.launchPath = "/bin/x" }  // a DIFFERENT binding
    p.launch()                                              // reported cmds: ["/bin/x"]
}
```

`allow Exec /bin/x` certified that call. Neither existing guard covers it: a shadow is not a reassignment,
so the move pre-pass records nothing, and the outer handle takes no write at all, so `execLocatorInvisible`
raises no refusal. The gate is now the binder COUNT — a name with more than one binder site in the unit
(the function's own parameters counted) is not a name a body-wide literal claim can be made about — and it
sits at the READ, so the suppressing half stays monotone.

`NameKeyedStateTests.disposition` said this map was safe because "a rebind of the handle is already
recorded in `movedNames`". True of a rebind, false of a shadow BINDER; the note is corrected in the same
commit, because the argument for keeping the map was resting on the premise that was wrong.

Measured cost: **zero rows** across pollen, applike, AppTarget, candor-swift and swift-syntax (8.6k
functions — no host, command, path or effect losses). The one shape it does cost is two DISJOINT bindings
sharing a name in sibling branches, where the per-function union would have been right — pinned as
`testKnownCostSiblingScopeHandlesShareANameAndBothAreRefused` so a future scope-aware refinement shows up
as a deliberate change rather than passing unnoticed.

### fixed ⚠ — the singleton FIELD had no type, so the call on it was silent-pure (2026-07-29)

Found by the A/B for the locator work, not looked for. A stored property's type came from its ANNOTATION,
or from a ctor CALL in its initializer. The dominant Apple-platform spelling is neither —
`private let session = URLSession.shared` is a member ACCESS — so the field stayed untyped, every call on
it missed κ and resolved to no unit, and the enclosing function read **silent-pure**. On a realistic
target, three network-performing methods were absent from the report altogether. No amount of host or
command extraction reaches this: the effect itself was never charged.

The same inference already existed for a LOCAL binding — `SINGLETON_ACCESSORS` is in the classifier and its
comment says `let d = UserDefaults.standard` carries the type. Only the field case was missing.

The inference is `Type.member : Type`, true for the canonical singleton accessors and NOT in general, so it
is guarded by that existing allowlist plus a bare-uppercase-identifier base. A `static let logger: Logger`
on a local type would otherwise type the field as its OWNER and resolve calls to the owner's methods,
fabricating whatever those do — the mirror fixture for exactly that was confirmed to FAIL when the
allowlist is removed, so it is not a vacuous control.

Measured A/B: pollen gained **5 new report entries and 29 enlarged effect sets, with zero losses**. Traced
to ground truth: a SwiftUI card holding `MedicationStore.shared` calls `store.log(…)`, which calls
`saveEntries()`, which writes to `UserDefaults` — a real disk write, reported as pure. `MedicationStore`
declares `public static let shared = MedicationStore()`, so the type premise holds exactly.

### fixed ⚠ — locator provenance 3/3: the property write that names the program (2026-07-29)

`Process()` takes no command. The program is named by a property WRITE (`p.launchPath = "/bin/sh"`,
`p.executableURL = URL(fileURLWithPath: …)`) and executed by `p.run()`/`p.launch()`, which take no argument
at all — so the direct-argument rule saw no literal anywhere on the Foundation subprocess surface. EVERY
`Process` form yielded no `cmds`: `allow Exec` failed closed over all of it, and the `classifyCommandHead`
cliff refinement (a visible `curl` reaching `Net`) never fired. The write is now carried forward to the
launching verb.

**The launching verb also marks `Exec` INCOMPLETE when it cannot read the program, and that half is not
optional.** Before this mechanism the surface was always empty and `allow Exec` failed closed *by accident*.
The moment a literal can be captured, a benign visible `/bin/sh` would otherwise COVER for a runtime
program spawned beside it and certify the whole function — the AS-EFF-008 masking evasion, and the precise
way this work could have made the gate quieter. Marking it changes nothing for the all-invisible case an
empty surface already refused. Pinned directly and transitively.

**The A/B found a fabrication in this mechanism that all 25 fixtures had passed.** A `SequenceExpr` is
FLAT — the parser gives `p.launchPath = "/usr/bin/" + tool` as `[lhs, =, "/usr/bin/", +, tool]` — so reading
the element after the `=` yielded the literal `"/usr/bin/"` and reported *that* as the program, which
`allow Exec /usr/bin/` would then have certified for an entirely runtime command. It surfaced on a negative
control written into the corpus, not in a unit fixture; the remainder is now re-wrapped and handed to the
resolver that already knows how to refuse it. Three fixtures were added from that one finding.

Measured A/B (4 corpora, 8 568 functions): **12 functions gained a command surface** — `/usr/bin/iconutil` in pollen's icon
tool, `/bin/sh` across candor's own soundness fixtures, `/usr/bin/git`/`curl`/`iconutil` in the app target —
`+1 Net` from a command-head refinement, and **zero losses of any kind**. swift-syntax's `ProcessRunner`
(`process.executableURL = executableURL`, a parameter) correctly gained nothing: a real-world negative
control. Conformance four-way OK; smoke 108/108; fuzz 25/25; fabrication-probe clean.

### fixed ⚠ — locator provenance 2/3: the local the locator was bound to (2026-07-29)

The other half of the URLSession surface: `let u = URL(string: "…")!` then `dataTask(with: u)`, and the
POST idiom `var req = URLRequest(url: …); req.httpMethod = "POST"`. rust/java/ts all extract from a local
binding as well as from an inline literal. The literal now travels through the SAME const-string index the
direct form uses, so the host refinement, the ⟨0.13⟩ `Llm` classification and the privacy manifest follow
without a second resolver.

Admitting `var` — which the `URLRequest` idiom forces, since a request cannot be configured any other way —
needs a claim the walk could not previously make, because the walk is flow-INSENSITIVE: it records a
binding at the declaration and reads it at the call, in SOURCE order. A rebind later in the text (or
earlier in TIME, because the pair sits in a loop) would leave a stale literal standing and the report would
name a destination the program never contacts. So a **pre-pass** now sweeps the whole body before a single
call is collected and records every name whose value can move: a whole-name or compound assignment, an
`inout` pass, or a property write outside an allowlist of spellings proven not to move the locator
(`httpMethod`/`httpBody`/headers/caching — `url` pointedly absent). A moved name carries no claim at all,
at EVERY use, including one lexically earlier than the move.

The two pre-pass maps are classified in `NameKeyedStateTests` as `deliberatelyKept`, and for the opposite
reason to the hedges beside them: every other row there asks what a rebind does to a fact, while these ARE
the record that a rebind happened — clearing one on a rebind would delete the evidence that suppresses the
claim and leave a fabricated host standing.

Measured A/B (4 corpora): +1 host, +1 `Llm` classification, +1 `unknown-host` → `known-partner`, zero
losses of any kind. Cumulative for 1+2: **13 hosts gained, 3 destination classes named, 0 effect sets
shrank, 0 literals lost, 0 entries dropped.**

### fixed ⚠ — locator provenance 1/3: the constructor between the literal and the call (2026-07-29)

swift captured a Net host only when the literal was a DIRECT string argument of the establishing call —
`NWConnection(host:port:)`, the single idiom conformance PART 4e pins. On Apple platforms almost nothing
is written that way: `URL(string:)` interposes, so **every `URLSession` form yielded no `hosts`** and read
`netClass: ["unknown-host"]`. Three live consequences, all on the released line: a narrowed
`deny Net[known-telemetry]` passed GREEN over a `URLSession` call to `api.segment.io`; a call to
`api.openai.com` never reached the §1 ⟨0.13⟩ `Llm` refinement or the privacy manifest; and `allow Net`
failed closed over essentially all Apple-platform code. rust/java/ts all unwrap their equivalents.

`URL(string:)` / `URL(fileURLWithPath:)` / `URL(filePath:)` / `URLRequest(url:)` (and the `NS` twins) now
resolve to the locator they carry, nested and bounded, through the same const-anchored resolver the direct
form already used — so `Llm`, `netClass` and the privacy manifest all follow with no new machinery.

This moves the gate in the RELAXING direction, so the guard is an **allowlist of companion arguments**,
the exact inverse of the denylist rule that governs narrowing an over-approximation: an unrecognised label
refuses. `relativeTo:` is why — `URL(string: "/v1/track", relativeTo: base)` keeps its authority in `base`,
and reading the `string:` argument would fabricate the host `/v1/track`. A locally-declared `URL` type or
free function shadows the unwrap, as every κ entry point in this engine does.

Measured A/B (4 corpora, 8 568 functions): 12 hosts gained, 2 `unknown-host` → `known-telemetry`,
**zero effect sets shrank, zero hosts/cmds/paths lost, zero entries dropped**.

### fixed ⚠ — ⟨0.24⟩ neither §3.1 rule has a carve-out, and both of ours did (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `1503368`). **Precedence binds `forbid`/`allow` too**: measured,
`deny Fs` + `forbid app.Domain -> app.Infra` in one policy exited 2 with the certain violation absent from
the document — the identical harm the precedence rung closed, surviving under a different rule KIND,
because those two refusals returned before the report was even opened. Now exit 1, the document names the
violation, and the unevaluated rule is disclosed beside it. The refused rules are still never evaluated
(the gate is handed a deny-only policy), so no `allow` can be certified off a wire that does not carry the
AS-EFF-008 surface-completeness marker.

**And the refusal document has no exempt cause**: an unreadable policy, a report that never loaded AS one,
a broken `.candor/config` and an invalid baseline now all write the same fail-closed document
(`ok:false`, `refused:true`, the reason, no `violations` key). A stale green on disk does not care why this
run declined to overwrite it. The one case that still writes nothing is a usage error inside the flag loop,
where `--gate-json`'s value is not yet resolved — asserted, not assumed.

### fixed ⚠ — ⟨0.24⟩ the precedence fix FABRICATED a violation, and this is the half that makes it safe (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `5a8cf48`), found by implementing `7271c69` rather than by reading it.
Removing the refusal's short-circuit made the evaluator reach code it had never reached: the reason-class
matcher floored an unknown class set at `unresolved`, so a scoped `deny Unknown[unresolved]` over an entry
whose `Unknown` is INHERITED and reasonless began emitting an actual violation RECORD — in the same run
whose stderr said that rule could not be evaluated over that function. A self-contradicting document,
reachable only THROUGH the soundness fix.

    entry `app.orphanU` (inferred [Unknown], direct [], no calls), deny Unknown[unresolved]
      after the precedence commit   exit 1, violations: [{fn: "app.orphanU"}]   <- FABRICATED
      now                           exit 2, the refusal document, no violations key

That floor is the right fail-closed default for a MATCHER — "could this rule apply?" — and the wrong basis
for a FIRING — "did it?". **A fail-closed default is not portable between a predicate that GUARDS and one
that CHARGES.** The `unresolved` default is still applied, at the ENTRY (both `gateInputFromScan` and
`gateInputFromReport`), gated on a DIRECT `Unknown` the function did not name — where it composes and where
it is evidenced. The matcher now WITHHOLDS instead, per (rule, function): the same rule fires on a function
whose match its own entry evidences and is withheld on one whose it does not, in the same run, with exit 1
for what fired and a disclosure for what could not be evaluated.

### changed ⚠ — ⟨0.24⟩ the gate verdict's `coverage` block spells its name list `packages` (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `aafa021`), which pins the verdict's coverage block as
`{ "uncovered": <n>, "packages": [ … ] }` for the first time. §2 defines the *report's* ledger —
`coverage.uncovered` as an array of `{name, calls}` — and that is a different shape from the *verdict's*,
so the verdict shape was never stated and the engines diverged unobserved: rust and ts emitted `packages`,
candor-swift emitted `modules`, and §3.1's single prose mention said `modules` too, because it was written
describing this engine's output. `packages` is correct, and not because it is three-to-one: the §2 envelope
names the very same objects `package`/`packages`, so a verdict that renames them mid-document is drift, and
`module` already means a different thing in two of the four implementation languages.

**A machine consumer reading `coverage.modules` from a candor-swift verdict must move to
`coverage.packages`.** Both swift routes go through one writer, so `scan --policy` and `gate --report`
change together and §3.1's byte-equality is unaffected. NOT renamed: the `privacy-manifest --verify --json`
document's own `coverage.modules` — that is the privacy/1 extension's surface, no clause and no conformance
PART pins it, and it is recorded as the second instance of the same hole rather than renamed unilaterally.

### fixed ⚠ — ⟨0.24⟩ policy VOCABULARY anchored at the target on a scan and at the policy on a gate (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `99eb4e9`). §3.1's MUST NOT names three channels an effect must never enter
a gate through; review found a FOURTH that no engine tested — `.candor/config`'s `unknown-alias`. The two
routes anchored config discovery DIFFERENTLY (gate verbs at the policy file's directory, scan routes at the
target), so with the policy filed OUTSIDE the scan target the same rule expanded differently and §3.1's
byte-equality MUST was breakable by a file that is neither the report nor the policy. Measured, one report
+ one policy `deny Unknown[corp]`, `unknown-alias corp = reflect` filed beside the POLICY:

    gate --report R --policy P    exit 0    alias found — narrows to [reflect], no match
    scan TARGET   --policy P      exit 1    alias NOT found — widened to a bare `deny Unknown`

Vocabulary now travels with the policy that uses it: `unknown-alias` resolves relative to the resolved
`--policy` file's directory on BOTH routes. Target-scoped keys (`deps`, `net-partner`, scan settings) keep
anchoring at the target, because they describe the thing being scanned.

**And the ambience is disclosed.** When a config file supplied vocabulary that PARTICIPATED in the verdict,
the `--gate-json` document names it under `policyVocabulary: {config, aliases}` — the file AND which aliases
it supplied. Discovery walks parent directories, so an alias
file anywhere above the policy participates; a verdict changed by a file the operator cannot see named is
the ambient-input failure this format exists to refuse. Named only when an alias was actually consumed — a
config defining aliases nobody asked for is not an input to this verdict.

### fixed ⚠ — ⟨0.24⟩ an unrecognised token silently REWROTE the rule — in EVERY policy value list (2026-07-28)

SPEC §6.2 ⟨0.24⟩ (candor-spec `382a7e0`), which withdraws its own asymmetry argument — "a dropped policy
token leaves a WIDER rule standing, so the failure is loud". Measured on this engine, over a signature
whose ONLY hole class is `indirect`:

    deny Unknown[dispatch,indirct]  typo BESIDE a valid token — dropped, the rule NARROWED to
                                    `[dispatch]` and stopped gating the `indirect` hole it was written
                                    for. EXIT 0 on BOTH routes. FAIL-OPEN, and the common case.
    deny Unknown[corp]              sole unrecognised token — "candor: ignoring policy rule (unknown
                                    reason-class/alias `corp`)" printed, and then the rule KEPT and
                                    WIDENED to a bare `deny Unknown`, exit 1. A FALSE DISCLOSURE, the
                                    `net-partner` class PART 13b exists for.
    after                           both exit 2 on BOTH routes, naming the token and the accepted set.

A policy that cannot be honoured as written is not silently rewritten into a different policy. The
narrowing direction is the common case, because a typo lands beside correct tokens far more often than
alone. `parsePolicy` now returns a `ParsedPolicy` carrying `errors`; the rules still parse, so the
ADVISORY readers (`parsepolicy`, `unverified`, `fix`, `fix-gate`) are unchanged — `parsepolicy` is the
conformance suite's four-way grammar witness and its battery deliberately contains a rule with an
unrecognised token. It is the GATE routes (`scan --policy` and `gate --report`) that refuse, before any
verdict is derived and with no `--gate-json` document, so §3.1's byte-equality holds on a broken policy by
there being nothing to disagree about. A `.candor/config` `unknown-alias` still resolves.

**EXTENDED TO ALL THREE VOCABULARIES** after candor-spec `be0b9a9` widened the ruling (it had said
"reason-class" only because a reason-class token was what the review measured, and the argument in it never
mentioned which vocabulary the token belonged to). Both siblings are live fail-opens:

    deny Net[known-partner,unknown-hosst]   narrows to [known-partner] — exit 0 where the correctly
                                            spelled rule exits 1
    unknown-alias house = dispatch,indirct  the DEFINITION becomes {dispatch}; the policy line
                                            `deny Unknown[house]` reads perfectly well and gates nothing

The second is the quietest of the three: the typo is in the vocabulary the policy is written AGAINST rather
than in the policy itself. Reserved-NAME rejection (`unknown-alias reflect = …`) is a different rule and
stays warn-and-skip, pinned four-way by conformance PART 4.

### fixed ⚠ — ⟨0.24⟩ a refusal wrote NO `--gate-json` document, so CI re-read yesterday's green (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `107755b`). The canonical CI wrapper is
`candor-swift gate … --gate-json v.json || true` then `jq .ok v.json`. Seed `v.json` with a green document
from a previous clean run, then refuse:

    before   exit 2, v.json UNTOUCHED — `jq .ok` returns the stale `true`
    after    v.json = {spec, ok:false, refused:true, reason:"…"} — `jq .ok` returns false

Deleting the path is not the fix: a consumer that treats a missing file as "nothing to report" fails open
by a different route. The naive read of a document this format emits has to be the safe one, because the
naive read is the one that ships. The document carries **no `violations` key**, and that absence is the
load-bearing part — the gate is making no claim about violations, and `[]` is precisely the claim it
cannot make. All three answerability refusals (`forbid`, `allow`, a scoped `deny` whose scoping datum is
absent) take it, on `--gate-json <path>` and on `--json`. A broken gate CONFIG or a report that never
loaded AS one still writes nothing (§3.3 cause (a)) — there the input to the verdict is unreadable, so
even `refused: true` would attribute a refusal to a policy nobody could parse.

### fixed ⚠ — ⟨0.24⟩ a refusal standing beside a FIRING rule DELETED the certain violation (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `7271c69`), which corrects its own ruling of an hour earlier. The
precedence is **violation (1) > refusal (2) > incomplete (2)**, and the first rung is forced by Lemma 2
rather than chosen: if a rule FIRES on evidence the report carries the policy is Rejected, and `Reject` is
upward-closed, so however an unanswerable rule would have resolved cannot un-reject it. Measured on a
two-entry report, one policy:

    deny Fs                                        exit 1   document names `app.writes`
    deny Net[unknown-host] app                     exit 2   no document (the entry has no netClass)
    BOTH IN ONE POLICY                             exit 2   NO DOCUMENT AT ALL          <- pre
    BOTH IN ONE POLICY                             exit 1   document names `app.writes` <- post

The harm was **in the document, not the exit code**: the refusal ran before the gate did, so the verdict
that would have named the certain violation was never computed, and the finding vanished from every
machine channel. Byte-identical in harm to the ⟨0.21⟩ incomplete-analysis path one rung down, and the
same fix — compute the verdict first, decide the exit from it. The refusal is **not swallowed**: every
unanswered rule is still named on stderr beside the verdict it is not part of. A refusal with no firing
rule beside it still exits 2, unchanged.

### fixed ⚠ — ⟨0.24⟩ a CORRUPT chained dep entry was skipped, so the calls it answered read PURE (2026-07-28)

The sibling of the `gate --report` rung below, one layer over, found while verifying it. This file's own
header already states the principle — a dep report that does not parse FAILS the run, because "silently
skipping either would make every call into that dep read pure" — and `(e[k] as? [Any]) ?? []` plus a
`continue` on a missing `fn` undid it one entry down. Measured on the two-tree fixture (dep `hit()` reads
`/etc/hosts`, app `go()` calls it, `deny Fs`), the dep's one entry doctored:

    intact dep report   go -> ['Fs']                     exit 1   the gate catches it
    unchained control   go -> invisible: ['RatesDep']    exit 0   the honest hedge
    `fn` key deleted    go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM
    `inferred: [1]`     go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM

Both corrupt arms are **strictly more confident than not chaining the package at all**, over a function
the dep report was trying to say was effectful. A dep entry with no readable `fn`, or with a §2 list key
that is present and is not a list of strings (`inferred`, `hosts`, `cmds`, `paths`, `tables`, `invisible`,
`incomplete`, `unknownWhy`), now FAILS the run (exit 2) naming the report — the posture the loader already
takes for a report that does not parse at all. An **absent** optional key still takes its default, pinned
by its own control: an entry carrying only `fn`, `hash` and `inferred` still joins.

### fixed ⚠ — ⟨0.24⟩ a `gate --report` key that is PRESENT but unparseable was coerced to its empty value (2026-07-28)

SPEC §2 ⟨0.24⟩ (candor-spec `38ba3e2`). The shape that generalises the count-0 and missing-`functions`
rungs is *a reader that recovers from a type mismatch by substituting the default* — and on every key in
this format that default is the PERMISSIVE value (`0`, `[]`, absent), so the coercion converts corrupt
input into a claim, and the claim is always the safe-looking one. Measured before, `deny Net` over a
one-entry report, all four binaries rebuilt at HEAD:

    entry with NO `fn` key, `inferred: ["Net"]`   rust 2   ts 2   java 2   swift 0   <- silently dropped
    entry with `inferred: [1]`                    rust 2   ts 0   java 0   swift 0   <- three fail open

The first row is the cardinal-sin shape exactly: a CORRUPT entry silently became an ABSENT one, and under
⟨0.21⟩ absent is a positive purity claim about a function the report was trying to tell you about. Now
each is a refusal (exit 2) naming what could not be read: `fn` must be a non-empty string; a §2 list key
that is PRESENT must be a list of strings (`inferred`, `direct`, `calls`, `hosts`, `cmds`, `paths`,
`tables`, `netClass`, `unknownWhy`); `unanalyzed` and `coverage` must parse.

`unanalyzed` is the sharpest of them, because its **non-emptiness IS the fail-closed trigger**: read as
empty, `NOT certified` (exit 2) becomes `policy ✓` (exit 0). Both spellings the spec measured now refuse —
a bare string list (`["src/broken.swift"]`, which all four engines dropped) and a non-list.

An **absent** key still takes its documented default, and that separation is pinned by its own control: a
minimal entry carrying only `fn` and `inferred` gates normally in both directions. Conflating absent with
present-but-unparseable would refuse every legitimate report.

### fixed ⚠ — ⟨0.24⟩ `gate --report`'s reason-class refusal was OVER-BROAD, and named the wrong function (2026-07-28)

SPEC §3.1 ⟨0.24⟩ names this engine's refusal by name. **The refusal is MINIMAL, and monotone denial is
what makes that safe**: a class-scoped `deny` is not unanswerable merely because some evidence is missing,
because the class set only ever GROWS (§6.2 — a reason is *contributed*, never retracted) and `Reject` is
upward-closed in it. When the classes determinable FROM THE ENTRY ALONE already intersect the filter, the
rule FIRES and no further evidence could change that.

A reasonless **DIRECT** `Unknown` contributes `unresolved` from the entry alone, with no transitive step —
so `deny Unknown[unresolved]` over it is answerable. Measured four-way on a one-entry report, all four
binaries rebuilt at HEAD:

    deny Unknown[unresolved]              rust 1   ts 1   java 1   swift 2   <- over-broad
    deny Unknown[unresolved] app.direct   rust 1   ts 1   java 1   swift 2   <- and with a scope

Exit 2 is not wrong in the fail-closed sense; it is a **worse answer than the correct one**, and a verb
whose value is being a pure function of its input should not decline questions it can answer.

**And the remedy pointed at the wrong function.** Over a report with three `Unknown` carriers — one direct
and reasonless, one inheriting through a `calls` edge to it, one inheriting from nowhere the report names
— `deny Unknown[dispatch,unresolved]` refused naming `app.inheritU` where rust, ts and java all name
`app.orphanU`. Same exit code, and the only actionable part of the message was wrong. Both halves are one
fix: `unresolved` is now contributed at the ENTRY, before the fixpoint, so `app.mystery` and (transitively)
`app.inheritU` both have non-empty class sets and the refusal falls through to the one entry whose reason
channel really is missing. The refusal predicate itself is unchanged.

Contributing at the ENTRY rather than at the join is what makes it COMPOSE: a caller of one reasonless
entry and one `dispatch:` entry accumulates `{unresolved, dispatch}` and is caught by both filters — the
§6.2 counterexample in which *adding* a call turned a red verdict green. It is gated on a **direct**
`Unknown` the entry did not name, never on the reason set being empty, because emptiness is also what an
inherited `Unknown` looks like and marking those is the mirror fabrication. Same shape as candor-rust
`gate.rs` and candor-java `Loader` (`82bf4d4`).

One pre-existing fixture moved with it: `testScopedUnknownDenyWithNoReachableReasonIsRefused` posed
`direct: ["Unknown"]` (the test helper defaults `direct` to `inferred`) while its prose said "an Unknown
with neither its own `unknownWhy` nor a `calls` edge". Those are two different states and ⟨0.24⟩ separates
them; the fixture had picked one spelling of two, and now poses the inherited one it meant.

### fixed — ⟨0.24⟩ `gate --report` over a count-0 report printed `policy ✓` and nothing else (2026-07-28)

SPEC §3.1 ⟨0.24⟩, as corrected in candor-spec `0744d29`. A report presented DIRECTLY to the gate with
`analyzed.count: 0` makes the same claim as a chained one — it judged nothing, so it licenses no purity
claim — and the verb MUST say so. Measured before, on a count-0 report with `deny Net`:

    exit 0, stdout empty, stderr exactly `candor-swift: policy ✓`

**The exit code and the verdict document are UNMOVED, deliberately.** §3.1 makes byte-equality with
`scan --policy`'s `--gate-json` the acceptance test and a scan of an empty facade package exits 0 with a
clean verdict, so diverging would split the verb this rung exists to keep single; §3.3 enumerates exactly
two exit-2 causes (a broken gate CONFIG, an INCOMPLETE analysis of the target's own code) and a
judged-nothing dependency is neither. And a verdict is an ASSERTION — the consumer has no evidence of any
effect here, so manufacturing one would be the fabrication mirror of the silent under-report. What was
missing was the human channel: `analyzed.count: 0` already rode the machine one. So a caveat now goes to
stderr naming the locator, and byte-equality is re-verified (12 policies).

The unreadable-manifest rows reach the same caveat, because a claim that cannot be READ is not a claim. And
they no longer reach the verdict: an unreadable `count` contributed to the document's own `analyzed.count`,
measured at **`count: true` -> `analyzed: {count: 1}`** and **`count: -1` -> `analyzed: {count: -1}`** — a
fabricated number in the machine channel, the mirror of the missing disclosure. Both are now `0`.

### fixed ⚠ — ⟨0.24⟩ `analyzed: {count: true}` read as JUDGED — a BOOLEAN is not an integer (2026-07-28)

SPEC §2 ⟨0.24⟩ names this engine for it. Foundation bridges a JSON `true` to `__NSCFBoolean`, and
`__NSCFBoolean as? Int` **succeeds with `1`** — so the manifest reader took `{count: true}` for "one unit
judged" and granted the package **full coverage, byte-identically to `count: 2`**. The caller into that
package then dropped out of `functions` entirely: a ⟨0.21⟩ **positive purity claim licensed by a manifest
that made no readable claim at all** — the fabrication mirror of the rung directly below, arriving through
a language's type bridge rather than through a logic error.

Measured on the two-tree fixture (dep report doctored to `functions: []`, app calls an API the dep never
listed), one row against its own control:

    count: 2                     goUnlisted -> ABSENT from `functions`   (correct: an all-pure claim)
    count: true   pre            goUnlisted -> ABSENT from `functions`   <- indistinguishable
    count: true   post           goUnlisted -> invisible: ['RatesDep']   + κ ledger + advisory

The rejection is made **before** the integer cast and on the number's own type tag (`objCType == "c"`,
which is the boolean spelling on Darwin Foundation *and* swift-corelibs-foundation), because no test on
the *value* could separate them — `count: 1` and `count: true` are the same number. `count` must be a
**non-negative integer**: a boolean, a fraction (`2.5`), a negative, a string or a missing `count` are all
**present-but-unreadable**, which is not a claim, so coverage is withheld. `2.0` is a legitimate JSON
spelling of `2` and is still believed — the anti-flood control for the numeric half.

The predicate is now **one function** (`claimsToHaveJudgedNothing`) shared by the chained-dep route and
`gate --report`, so the two cannot drift into two readings of one integer. Seven new rows in the shape
table, the boolean one verified to fail before the fix.

### fixed ⚠ — ⟨0.24⟩ a chained report that JUDGED NOTHING no longer reads as an all-clear (2026-07-28)

SPEC §2's three-row table. A chained dependency report carrying `functions: []` **and**
`analyzed.count: 0` bought a consumer **more confidence than not chaining the package at all**: every
call into it dropped out of `functions`, which under ⟨0.21⟩ is a positive purity claim, with no advisory
in either channel — while the same scan with **no dep report** correctly discloses `invisible` +
`coverage.uncovered` + the κ nudge. A silent under-report, and conformance PART 26 measured it in all
four engines (64 live cells ABSENT here).

Measured, two-tree fixture (dep `hit()` reads `/etc/hosts`, app `go()` calls it, `deny Fs`):

    unchained        go -> invisible: ['RatesDep'], coverage.uncovered, κ nudge   exit 0
    trusted          go -> ['Fs']                                                 exit 1
    count: 0   pre   go -> ABSENT from `functions`, no coverage, no advisory      exit 0
    count: 0   post  go -> invisible: ['RatesDep'], coverage.uncovered, κ nudge   exit 0

**The wire already distinguished the two cases and nothing read it.** A facade target scans to
`count: 0`; an all-pure target scans to `count: n` with the same empty `functions`. So `count: 0` now
registers into a new `unjudgedPkgs` — chained (its keys are still asked) but NOT covered, the same
treatment ⟨0.21⟩ `incompletePkgs` gets and for the same reason: coverage is the rule that turns a
report's SILENCE into a purity claim, and a report that judged nothing is all silence. Entries are
untouched; only coverage is withheld, so nothing is ever downgraded or dropped.

**The second row is the control, and a fix that hedged it too would have deleted chained coverage rather
than implemented the rule.** `count: n > 0` with an empty `functions` is a legitimate all-pure claim §2
rule 3 says a consumer SHOULD believe: unchanged, believed, no new hedge, no advisory. Both directions
are mutation-verified — forcing the count-0 arm covered turns the three FLOOR tests red and leaves the
control green; hedging both arms turns the control (and eight pre-existing coverage tests) red and
leaves the FLOOR test green.

Two reconciliations, running in **opposite** directions, because they follow what the second report
*says*. An INCOMPLETE report makes a specific negative claim about the package's source, so it beats a
complete sibling. A count-0 report makes no claim at all, so a package chained once judged and once not
**keeps** its coverage — letting an empty report withdraw an earned purity claim is the mirror sin.

Blast radius, real code: **1 report in 37** emits `count: 0` (swift-syntax's 21 modules + candor-swift's
2 + 14 soundness fixtures) — and it is swift-syntax's `SwiftSyntax-all`, a target whose only source file
is a comment saying "this is a fake target that depends on all targets". A rare facade, not half a dep
tree. PART 26 now prints `swift  SEPARATED on 24/80 cells — the engine distinguishes them`, where all
four engines printed INDISTINGUISHABLE.

### changed — ⟨0.24⟩ a `--class` value that cannot be honoured is REFUSED, not quietly narrowed (2026-07-27)

SPEC §6.2's **value grammar**, which conformance PART 27 found unimplemented in **all four** engines
rather than divergent between them — the suite's only `engine: "*"` waiver, and the last thing holding
the floor below 0.24. `--class <c>[,<c>…]` takes ONE comma-separated list of the six reason classes plus
the aliases `dynamic` and `*`. Two things that used to exit 0 on `unverified --class` (this engine's only
`--class` consumer — there is no `blindspots` or `callers` verb here) now exit **2**:

- **an unrecognised token.** `--class dyanmic` printed `--class ignores unknown reason-class …` and
  carried on with whatever was left of the list — for a one-token list, an EMPTY filter. It now names the
  token and lists the accepted set. `*` is also honoured only after the whole list is walked, so
  `--class *,dyanmic` reports the typo instead of short-circuiting past it.
- **a repeated `--class`.** It was last-wins, silently discarding the first list. A second occurrence is
  a usage error, not a union — and not last-wins either.

**Why the query side refuses what the policy side drops**, since the asymmetry reads as an inconsistency
until it is written down: a token dropped out of `deny E Unknown[reflect,dyanmic]` leaves the **wider**
rule standing, so the mistake is loud — the gate over-fires and somebody comes to look. The same token
dropped out of `--class` leaves a **narrower** filter, and a narrower filter on `unverified` comes back
as a **smaller number**, indistinguishable from a real all-clear in the one verb whose whole job is to
say "green, but not provably so". A refusal also emits **no answer document at all**; a narrower result
one exit code away from a refusal is the same fail-open in a different hat.

`parseClassFilter` now throws `ClassFilterUsageError` rather than warning, so the rule lives in one
place. Nothing changes for well-formed input — the new suite pins the unfiltered baseline and each
filter's exact selection alongside the refusals.

### added — ⟨0.24⟩ `ambiguous:` is a fifth §4 kind: candor-swift already conformed; the controls did not exist (2026-07-27)

SPEC §4's `unknownWhy` kind set gains **`ambiguous:`** — name resolution was ambiguous, so no owner could
be formed at all. §4 ⟨0.24⟩ warns that an engine holds this vocabulary **twice** (a prefix/string
classifier feeding §6.2's class table, and a typed/structural one) and that when §4 goes stale the string
half stays right while the typed half does not — measured on the reference JVM engine, where one token
classified `dispatch` on the string path and `unresolved` on the typed path, silently.

**candor-swift holds it ONCE.** `reasonClass(_:)` (Policy.swift) is the only representation: an
`unknownWhy` token is a raw `String` from its emission site to the JSON writer, with no `Kind` enum, no
union, no accepted-prefix set and no validator anywhere in `Sources/`. Its `dispatch` arm has covered
`ambiguous` since the ⟨0.19⟩ reason-scoped rung. So the JVM failure mode is structurally unreachable here
and **nothing in production changed** — no report byte, no gate verdict. `dep:<hash>`/`dep-stale:<pkg>`,
which §4 ⟨0.24⟩ registers as permanent kinds rather than migration ones, sit in no migration bucket
either: this repo has none, and they project to `unresolved` exactly as the spec prescribes. The two
places the kind set could have drifted in prose — `AGENTS.md` and `README.md` — never restate it; they
give two examples of a reason, which is not a set.

**What was missing is the control §4 ⟨0.24⟩ asks for**, and its absence is the whole point of the clause:
without it, "added a fifth kind" and "stopped checking the kind set" are the same diff. Added at both
levels, over the path this engine can actually meet the kind on — it EMITS no `ambiguous:` (its producers
are `dispatch:`, `callback:`, `dynamicMemberLookup:`, `contentsOf:` and the `dep:` pointers) but it
**RELAYS** one, since `loadDepIndex` carries a dependency's own tokens across the join. A fabricated
`banana:whatever` and a relayed `ambiguous:go` are driven through `scan --policy` and `unverified
--class`, the two verbs whose class sets are accumulated by two independent code paths
(`Gate.buildGateInput`, `Fix.reasonClassesTransitive`) — the divergence shape §4 describes.

Mutation-verified with four mutations, each caught by a **different** arm: the blanket catch-all →
`dispatch` fails both controls; dropping the `ambiguous` prefix fails the gate and both class paths;
recognising the token SHAPE (`contains(":")`) instead of the SET leaves every gate arm of the
`ambiguous:` test green and is caught only by the fabricated kind; and normalising the relayed token to
its class is caught only by the round-trip arms.

### added — ⟨0.24⟩ `gate --report`: the gate as a function of a GIVEN signature (2026-07-27)

    candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <f>]

SPEC §3.1's ⟨0.24⟩ verb: apply a policy to an EXISTING report, with **no scan**. Exit codes and verdict
shape are exactly `--policy`'s on a scan (0 / 1 / 2); the only difference is where `S` and `D` come from.
`--json` **is** `--gate-json -` — the verb's machine output is the verdict, and a second meaning for
`--json` would be the one place a consumer could tell the two routes apart. A query verb, so it inherits
§3.3.1 unchanged: the same three locator forms, the same discovery and `CANDOR_POLICY`/config fallbacks,
and no positionals (a stray one is a usage error — `gate` has no argument of its own, and a swallowed
token is how a gate runs green).

Two things this buys. It is the **supply-chain verb** — gating a dependency's published report is what an
adopter actually wants and could not express without re-analysing code they do not have. And it makes the
code-implements-spec direction **testable**: every other route recomputes the effect set from source, so a
defect in the gate and a defect in the classifier were indistinguishable from any test this repo could
write.

**THE SEAM.** `evaluateGate` now takes a `GateInput` — a record of already-accumulated maps — built either
by `gateInputFromScan` (the reason-class fixpoint and the per-fn `netClassesOf` derivation, moved out of
the gate body and off `main.swift`) or by `gateInputFromReport`. There is deliberately **no second copy of
the §6.2 matching**: the clause mandating this verb exists about exactly that mistake, an open-coded copy
of a classification rule drifting from the gate's, silently, because nothing compared them.

**REPORT-LOADING.** This engine ships no `callers`/`show`/`where` (it is the producer; the read-only
queries are candor-query's), so `gate` is its first verb that CONSUMES a report to reach a verdict. The
§3.3.1 locator machinery already existed and is reused (`resolveReportLocator`, `discoverReportPrefix`,
`discoverPolicy`); the reader itself is new, because it must read **strictly less** than the existing one.

**THE MUST NOT.** §3.1: an engine must not re-derive, widen or re-classify, and an ABSENT entry is absent
— the ⟨0.21⟩ purity claim — never back-filled from a callgraph sidecar or a chained dep. `loadGateReport`
opens the report file(s) and nothing else: no `.callgraph.json` (which `loadFixModel` does merge, for
fix/fix-gate/tour/path), no `.hierarchy.json`, no `loadDepReports` chaining, and `hosts`/`cmds`/`paths`/
`tables`/`netClass` taken verbatim rather than re-matched or re-mapped through this machine's
`net-partner` config. Proved with `app.Facade.load` ABSENT from a report while three baits sit beside it:
a sidecar naming it and edging it to a `Net` unit, a chained dep report giving it `Net` outright, and a
`.candor/config` `deps` key inside the one directory the verb does open a config from. Verdict clean; the
positive control beside it (same directory, same baits, a report that DOES carry the effect) exits 1.
Both halves mutation-verified — back-filling from either the sidecar or the dep flips the clean half to
exit 1. Separately measured: gating a report written WITH a `net-partner` config, from a process whose
config has none, still produces the verdict byte-for-byte — `netClass` came off the wire.

**ANSWERABILITY — three refusals, each fail-OPEN if approximated instead.** `forbid A -> B` is refused
whole-policy: a report carries an entry only for a function with an EFFECT, so a wholly pure unit has no
entry and no edges, while `forbid` matches on NAME. `allow <E> …` is refused whole-policy: the AS-EFF-008
surface-completeness marker does not ride the wire, and `netClass: unknown-host` is not it (that token
also names a merely unrecognised host). Whole-policy in both cases because enforcing the answerable half
and exiting 0 is gateless-green. The third is per-(rule, function): a class-scoped `deny` whose scoping
datum is ABSENT on a matched entry. **Measured on this engine with the check disabled:**

    report                                    deny Net[unknown-host]   deny Net
    Net-bearing entry, netClass ABSENT        exit 0  ← green          exit 1

    report                                    deny Unknown[dispatch]   deny Unknown
    Unknown, no unknownWhy and no calls edge  exit 0  ← green          exit 1

The narrowing succeeds *because the evidence is missing* — an absence-keyed relaxation of a fail-closed
gate. Per-(rule, function) so a scoped rule whose own matches carry their evidence still evaluates; the
message names the exact `deny` line, the function, and the remedy. None of the three fires on a report
this engine wrote.

**EQUIVALENCE, and it is byte-level.** 80 rows over four corpora — candor-swift's own `Sources` (526
analyzed fns, 20 policies, up to 95 violations), a reason-class fixture, a host-literal fixture with a
`net-partner`/`unknown-alias` config, and a tree with an unreadable file — every `--gate-json` document
BYTE-EQUAL between `scan --policy` and `gate --report`, and every exit code equal. `analyzed.count`,
`reasonClass`, `netClass`, the ⟨0.15⟩ coverage advisory and the ⟨0.21⟩ `incomplete`+`unanalyzed` manifest
(the exit-2 rows) all included. No divergence found.

**MODEL CROSS-CHECK** against `candor-spec/reference/policy_model.py`: 256 signatures × 5 verbs = 1280
rows. `deny Fs Unknown[reflect,unresolved]` and `pure` agree 256/256. All 100 disagreements are ONE
family — `Llm ∈ S` with `Net ∉ S` under a `deny Net`, where the model applies Definition 4's refinement
preorder (`Llm ⊑ₑ Net`) and the engine intersects the denied set with `inferred`; direction is uniform,
model REJECT / engine pass. That is the same model-versus-contract shape SPEC §6 pins for `Db` (since
amended out of the model, so the residual has MOVED rather than closed): §6.2's normative `deny` grammar
has no refinement clause. It is also unreachable from a scan — SPEC §1 ⟨0.13⟩ has the engines CO-EMIT
`Llm` and `Net`, and this one does at three sites in `CallCollector.swift`. Restricted to that
well-formed sub-lattice (`Llm ⇒ Net`), **0 disagreements**. Not patched here: making `deny Net` fire on
`Llm` alone is a family-wide contract change, not a candor-swift one.

Pinned by `GateReportVerbProcessTests` (15 process-level cases, each verified to FAIL under a targeted
mutation of the shipped binary) plus four `smoke.sh` cases. `swift test` 387 passed; `smoke.sh` 108/0.

### ⚠ soundness — a chained dependency's ACCESSOR read, and the UNBOUND factory call, were silent-pure (2026-07-27)

Two chained-boundary defects found by conformance PART 24 (split-invariance) on its first run, each
re-derived from a hand-written two-package fixture. Under ⟨0.21⟩ an absent-but-analysed function is a
positive purity claim, so both were false all-clears rather than gaps.

- **A property ACCESSOR on a dependency's type.** `l.v` where `L` is a chained dependency's type and `v`
  is a computed/lazy/static property that performs I/O. The dep's report already carried `L.v ['Fs']
  unitKind:accessor` — every reader-side branch in the property-read path was gated on
  `localTypes`/`localProtocols`, so the read fell off the end of the chain and was never recorded.
  Not lazy-specific: computed, lazy and static spellings were all silent. PART 19's fixture reads a
  module-level GLOBAL, which IS modelled, so the accessor spelling had never been asked.
- **A factory call with NO intermediate binding.** `build().fetch()` and `getDyn().run()` read
  silent-pure while `let c = build(); c.fetch()` resolved and `let t = getDyn(); t.run()` disclosed
  `Unknown[dispatch:untyped cross-package receiver]`. That is a hole in a SHIPPED guard: PART 21's
  ruling is that an unformable key must not read pure, and PART 21's fixture binds the result.

Both fixes emit the call shape the join already understands, so **neither needed a report-format
change**: the accessor read becomes a `propertyExternal` candidate joined against the sibling report
under `<Module>#<Type>.<member>` (the third member of the `stringifyExternal`/`deinitExternal` set), and
the unbound receiver recovers its provenance through `depFactoryCallee` — now a shared function, so the
bound and unbound spellings cannot drift apart again.

The mirror controls, each verified by mutating its guard out: a LOCAL type whose accessor is pure,
sharing a name with a dependency type whose same-named accessor is `Fs`, stays pure (it resolves to its
own unit — the reason this is a candidate set and not a `propertyEdges` entry); a dependency accessor
the report shows as pure, and a dependency STORED property, add nothing; `max(a,b).advanced(by:)` and a
call on a nested local `func`'s result acquire no hedge.

A/B over 8 real Swift targets: **unchained is byte-identical** (3082 entries, 0 changed) — with no dep
report loaded neither candidate set is consulted. Chained against per-module swift-syntax reports,
candor-swift's own scan gains 35 `Unknown`-only entries and 0 real effects, every one traceable to a
genuine SwiftSyntax accessor unit the dep's report itself marks `Unknown`. The A/B also caught the one
over-fire this join has had: `.map(String.init)` keyed swift-syntax's own `extension String`, so
`.init`/`.self`/`.Type`/`.Protocol` are now excluded as metatype spellings no accessor can answer.
`CANDOR_DEPMEMBER_DEBUG=1` prints each candidate and whether it hit, because a diff shows which
functions moved and never which key moved them.

### soundness — `unverified --class` read the direct `unknownWhy` as if it were the transitive one (2026-07-27)

`unverified` names the functions a `pure`/`deny E` layer PASSES without proving anything. Its ⟨0.20⟩
`--class` filter matched against the report's `unknownWhy` FIELD, which is the wrong quantity twice:

- SPEC §4 makes `unknownWhy` **direct-only**, so a function that INHERITS its `Unknown` records no
  reason of its own — and matched no class, so every inherited hole was dropped by every filter.
  44% of pollen's `Unknown`-bearing entries (192/435) and 67% of candor-swift's own (35/52) are that shape.
- SPEC §6.2 ⟨0.24⟩: a reasonless `Unknown` **CONTRIBUTES** `unresolved`. The site contributed nothing,
  so `--class unresolved` — the filter whose job is the holes nobody could classify — missed them.

The tell is that `--class dynamic` names every genuine class and so cannot exclude a hole, yet returned
strictly fewer. Measured, `deny Exec`, holes unfiltered → `--class dynamic`:

| target | unfiltered | dynamic BEFORE | dynamic AFTER |
|---|---|---|---|
| pollen | 387 | 230 (−41%) | **387** |
| candor-swift | 51 | 16 (−69%) | **51** |

Both halves are required and each is the other's guard: contributing on absence alone would give an
inherited `Unknown` `unresolved` when its callee classified it `dispatch` — the fail-open traded for its
fabrication mirror. So the contribution is gated on `direct` ∋ `Unknown` (the function introduced the
hole and named nothing), and inheritance is resolved by the same least-fixpoint over `calls` the gate
uses. The filter still discriminates after the change — pollen `--class unresolved` = 6 of 387,
`--class native` = 0 — which is the control that separates this from "everything matches everything".
`UnverifiedClassFilterTests` pins both directions; the mutation dropping the `direct` gate fails only the
control rows. No report-format change: `direct` and `calls` were already on every entry, unread.

The ⟨0.24⟩ projection change does **not** move any gate verdict here: candor-swift attaches a reason at
the SOURCE (`dep:<hash>` synthesized per dep entry exactly when the dependency classified nothing), so a
function's class set is never empty and the gate's empty-set default is unreachable — instrumented, 0
fires across 487 `Unknown`-bearing functions on two real targets, and the three-row counterexample
(reasonless dep, reasoned dep, both) is already rejected on the both row.

### soundness — ⚠ a binder that CAN type its new binding still has to invalidate the old one (2026-07-27)

A review found one site; the rename control that reproduced it found four more. `shadowName` drops the
four name-keyed FLAGS and `clearBindingTypeOnly` drops the TYPE indexes — and every branch that
succeeded in TYPING a rebound name called the first and wrote `vars` over the top, leaving `protoTyped`
describing a binding that is no longer there. The member-dispatch site consults `protoTyped` BEFORE the
`vars` root, so the fresh type does not mask the stale protocol, and the call dispatched over the
SHADOWED parameter's conformers:

| binder | reads | rename control |
|---|---|---|
| `switch e { case .active(let j): j.run() }` beside `j: Job` | `['Fs']` | ABSENT |
| `if let j = o { j.run() }` | `['Fs']` | ABSENT |
| `xs.forEach { (j: Ctx) in j.run() }` | `['Fs']` | ABSENT |
| `let (j, _) = (Ctx(), 1); j.run()` | `['Fs']` | ABSENT |
| `func inner(_ j: Ctx) { j.run() }` inside `f(_ j: Job)` | `['Fs']` | ABSENT |

**The clear is also a RECOVERY**: the stale entry was not only fabricating, it was masking the shadowing
binding's own type, so `if let j = o { j.go() }` and the closure form now resolve `Ctx.go` for the first
time. The ordering carve-out (`let u = u.asURL()` resolves THROUGH the entry being cleared) is a
denylist and is pinned by its own row — the mutant that clears unconditionally fails only that one.
A/B over 13 real Swift packages: 0 gains, 0 losses; the shape needs a stale `protoTyped` under a
shadowing binder, which no corpus site has (instrumented: 0 of 89 live-index hits at the payload site),
so the corpus is the fabrication control and the fixtures are the evidence.

`NameKeyedStateTests` was green through all five and correctly so — it derives the SET of name-keyed
maps and checks each map's classification, and what was violated is per-NAME and per-CONTROL-PATH,
which a parse tree cannot see. Both derivable strengthenings were priced and both would have PASSED on
the defective code; the limit is now stated in that file rather than left to be assumed away.

### deps — ⚠ completeness, and the identical-entry rule at every trust level (2026-07-27)

- **A complete report no longer cancels an incomplete sibling's hedge over the same package.** Coverage
  turns SILENCE into a purity claim (§2 rule 3), so a set of reports' silence is only as strong as the
  weakest completeness claim in it — **two reports covering one package do not cover the same SOURCE**.
  Measured: with A complete and B declaring `unanalyzed`, B alone hedges `invisible: ['RatesDep']` and
  A+B went ABSENT. The sharper form is candor-rust `63bbe87`'s argument on the completeness axis: two
  fresh reports disagreeing on a key withdraw it (§2 rule 1, correctly) and complete-wins turned that
  withdrawal into a positive purity claim over a function both reports call effectful. The cost is a
  hedge, never an effect — entries are untouched either way.
- **The identical-entry exemption now applies at every trust level.** Two byte-identical entries from
  two STALE reports were withdrawn as ambiguous, costing the §2.1 `Unknown` downgrade the stale arm
  exists to produce (`go` went from `['Unknown'] dep-stale:RatesDep` to a bare ledger hedge). 476 of
  8367 join keys already collide within a single real report, across 12 of the 13 corpus packages, so
  the population is not marginal. candor-rust `6f2210c` aligned.

### fix — `--workspace`'s cache sweep, twice more (2026-07-27)

- **It deleted a report a healthy sibling had just written.** The sweep skipped deps that SUCCEEDED,
  which is not the set of files THIS RUN PRODUCED: a workspace holding one package twice (a vendored
  fork beside the upstream checkout) has the FAILED copy owning exactly the file the healthy copy wrote,
  and the retry-plus-second-sweep deleted it twice. The consumer went from `['Fs']` with its literal
  surface to `invisible: ['Shared']`. The guard is the simplest one — never delete a file this run
  wrote — and the per-dep failure line no longer claims a removal that did not happen.
- **The sweep's manifest parse was not the writer's, and a comment said it was.** The sweep anchored
  after `Package(`; the writer takes the first `name:` in the whole file. A hoisted target or dependency
  array splits them, and both failure directions land at once: the stale report SURVIVES (a ⟨0.21⟩
  purity claim over a dependency that writes to disk) and a user-placed file under the invented name is
  DELETED. There is now one parse and one name transform, both the writer's, both called by the writer.

### soundness — ⚠ an enum-case payload binding is a LOCAL, and no shadow guard knew it (2026-07-27)

`typeEnumCaseBinding` typed `case .active(let c)` when the case name was unambiguous and carried exactly
one associated value. Everything else — the `case let .active(c)` spelling (the `let` outside the
parens, which parses to a bare `patternExpr > identifierPattern` with no `ValueBindingPattern` to
match), an ambiguous case name, and every multi-payload pattern the arity guard refuses to type — left
the bound name in NEITHER `vars` NOR `boundLocals`, i.e. invisible to every shadow guard in
`CallCollector`. Two fabrications followed, both measured on real code:

- **a BARE READ of the name charged the enclosing type's same-named property.** Alamofire's
  `AuthenticationInterceptor.adapt` was charged its own `credential` accessor; `WebSocketRequest.didClose`
  was charged the inherited `Request.error`; TCA's `TypeSyntax.identifier` was reported as its own
  caller.
- **PASSING it as an argument charged a same-named FREE FUNCTION**, because the fn-ref-as-argument rule
  (`xs.map(transform)`) can only skip arguments it can see are locals. `UploadRequest.task`'s
  `case let .data(data)` resolved to the unrelated `DataRequest.data`, and inherited an `Unknown` from it.

**AND THE SECOND FABRICATION MANUFACTURED A DISCLOSURE, which is why the previous round reverted.** A
phantom free-fn reference resolves to no local unit, and that is exactly the Driver's test for "this unit
reaches code the scan cannot see" — so vapor's `DecodingError.reason`, whose only unresolvable "call" was
the name of its own `case let .dataCorrupted(ctx)` binding, carried an `invisible: [HTTPTypes]` it had no
business carrying, and `DecodingError.description` inherited it through `self.reason`. Both units are in
the report ONLY because of that disclosure, so closing the fabrication removes the entries. A vanishing
report entry looked like the cardinal sin and was a fabricated disclosure being withdrawn.

A/B over 13 real Swift packages (11,924 report entries): **0 gains, 8 fabricated call edges removed, 13
manufactured `invisible` disclosures withdrawn and one fabricated `Unknown`** — every change traced to
source.

The payload names live in their own LEXICALLY SCOPED set rather than in `boundLocals`, and both halves of
that were forced by measurement. Folding them into the function-wide set drops the genuine property read
that FOLLOWS the block (swift-syntax's `IfConfigDiagnostic.asDiagnostic` binds `syntax` in three `if case`
blocks and then reads the real `self.syntax`) — a silent under-report manufactured by a fabrication fix.
Scoping `boundLocals` itself instead is worse: `Driver` reads it once, AFTER the walk, where a restored
set is empty, so `if c { let loadIt = { }; loadIt() }` starts edging to a same-named free function.
Both directions are pinned by fixtures, and five mutants each fail a named one.

### process — the set of name-keyed maps a rebind must invalidate is now DERIVED (2026-07-27)

One mechanism has produced **seven** defects in `CallCollector` across three days, every one the same
shape: a name-keyed fact outliving the binding that set it. `42093b6` removed the enumeration of binder
FORMS by binding to `IdentifierPatternSyntax`, which is where the language puts every pattern binding —
and it clears a LIST of maps, which is the same enumeration one level up. Two of the seven were maps
missing from that list.

`NameKeyedStateTests` makes the obligation derived rather than listed: it parses `CallCollector.swift`
with SwiftParser, enumerates the class's stored properties from the parse tree, and requires each one to
be classified — cleared (and whether scoped), deliberately kept as a hedge, a program-wide index, or not
per-binding at all. **Adding a map without that decision fails a test**; classifying one as cleared
without writing the clear fails another; classifying one as scoped without both saving AND restoring it
fails a third. All three verified by mutation, and the stale-entry direction caught a real one on its
first run. What is derived is the SET (nobody keeps it current, in either direction); what is authored
is the JUDGEMENT, which has to be — whether a `[String: X]` is keyed by a binding name or a type name is
a fact about meaning, not syntax, and the two hedging sets must NOT be cleared.

The classification is also where the two maps this pass did NOT fix are filed, with their measurement,
so the next audit inherits the numbers instead of the surprise.

### soundness — ⟨0.21⟩ a chained report that DECLARES ITSELF INCOMPLETE no longer grants coverage (2026-07-27)

⚠ **A dependency report carrying a non-empty `unanalyzed` was still registering full coverage for its
package** (`Deps.swift`). §2 rule 3 turns a report's SILENCE into a purity claim; a report with a
non-empty `unanalyzed` has just said it never read some of its own source, so its silence about that
source answers nothing. The same door `stalePkgs` closed, read one step earlier — staleness asks
whether to believe what a report SAYS, completeness asks whether its silence means anything.

Measured on the two-tree fixture: a call into a dep API the incomplete report has no entry for went
from `invisible: ['RatesDep']` unchained — the honest hedge — to **absent from `functions`**, a ⟨0.21⟩
positive purity claim, the moment the report was chained. candor-ts, which found this door in its own
sweep (`21277eb`) and whose treatment this ports, measured the single-tree control over the same
sources at exit 2 ("a gate cannot be green over unanalyzed code"), so chaining an incomplete report was
strictly WORSE than not chaining it.

The TREATMENT differs from staleness because the evidence does. A stale report's entries are assertions
from a build this engine will not repeat and are downgraded to `Unknown`; an incomplete report's
entries were derived from source it DID read and are kept **unchanged** — effects, literal surfaces and
all. Only the SILENCE hedges: strictly additive, no effect is ever removed. Staleness is checked FIRST
(a report we do not trust cannot be trusted about its own completeness), a package chained both
complete and incomplete keeps the complete report's coverage, and half 1's unanswerable-key `Unknown`
speaks BESIDE the ledger hedge rather than being replaced by it — the trade candor-ts measured going
the wrong way, where withholding coverage silently took `deny E Unknown[dispatch]` from exit 1 to
exit 0. Six guards, six mutants, each failing its named test and only it. ⚠ a chained consumer may
newly carry `invisible` where a dependency's report is incomplete; regenerate baselines.

Corpus: 0 of 34 real Swift packages produce a report declaring an `unanalyzed` unit, so the rung is
inert there — the corpus is the fabrication control and the fixtures are the evidence. It fires exactly
when a dependency ships source candor cannot read, which is precisely when its silence is worth least.

**A second, smaller repair fell out of the fixture**: two reports carrying an IDENTICAL entry for the
same key were withdrawing it as ambiguous. The header's canonical-path dedup catches the same FILE
loaded twice but not the same report present under two names — the ordinary shape once `--workspace`
prepends its scanned directory to a configured `CANDOR_DEPS`. §2 rule 1 forbids PICKING between
candidates; there is nothing to pick when they are equal.

### soundness — a stale report BESIDE a fresh one withdrew the fresh answer (2026-07-27)

⚠ **A package chained both FRESH and STALE read as a positive purity claim** (`Deps.swift`). Two
mechanisms met. §2 rule 1 withdraws a key two entries share, so the fresh `{Net}` entry and the stale
`{Unknown}` entry for the same dependency function cancelled each other and the key resolved to
NOTHING; `stalePkgs.subtract(coveredPkgs)` then — correctly — left the package COVERED on the fresh
report's authority, and §2 rule 3 turned that nothing into a claim. Measured on the two-report fixture:

    unchained          go -> invisible: ['RatesDep']          the honest hedge
    FRESH report only  go -> ['Net'] + the host literal
    STALE report only  go -> ['Unknown'], dep-stale:RatesDep
    FRESH *and* STALE  go -> ABSENT FROM `functions`           a ⟨0.21⟩ purity claim

Strictly worse than not chaining at all, and NON-MONOTONE: adding a report removed an answer that was
already there. A dep directory holding one package twice is the ordinary situation rather than a corner
— candor-rust, which found this and handed it over, measured it at 7/167 of its own dep reports, 9/259
on pgman and 30/378 on ebman — and in this engine `--workspace` reaches it by construction, since it
PREPENDS its own scanned directory to the configured `CANDOR_DEPS` spec.

Rule 1 exists because two DIFFERENT dependency functions can share a leaf/tail2 key with nothing to
tell them apart. That is not this case: §2.1 has already ranked the two producers, so preferring the
trusted one is the rule the engine spent rule 2 stating, not a guess. Trust now decides first and the
collision rule applies WITHIN a trust level — trusted vs trusted withdraws permanently (unchanged),
trusted vs stale keeps the trusted entry whichever order they load in, stale vs stale withdraws
recoverably so a trusted report can still claim the key. The invariant the test asserts: **adding an
untrusted report to a dep dir that already holds a trusted one changes the consumer's report by
nothing at all.** ⚠ a chained consumer may newly carry effects it was silently dropping.

### data loss — `--workspace`'s cache sweep deleted reports the user put there (2026-07-27)

**`--workspace` removed every `*.json` in `<root>/.candor/deps` that its own path-dependency scans had
not produced this run** (`main.swift`) — including a report the USER placed there, which SPEC §2 makes
the ordinary way to chain a BINARY dependency, a hand-produced report, or another engine's report in a
polyglot repo. Unrecoverable, and unrelated to the stale path-dep report the sweep was aimed at. Not an
analysis defect at all, which is why it is stated on its own: candor's contract is that it does not
destroy information, and a file the user chose to put there is information.

The sweep exists for a real reason (`43a0eaa` — a stale child report standing in for a failed rescan is
a ⟨0.21⟩ false all-clear), so the fix distinguishes reports the run OWNS from reports it merely FOUND,
rather than sweeping less. Ownership is DERIVED from `Package.swift` and needs no marker file: the
candidates are the discovered local path deps, and a failed dep's report file is found by the package
name an earlier round recorded, else its own manifest's `name:`, else the directory basename — the same
three sources, in the same order, that the writer uses. Anything else in the directory is **named on
stderr and left in place**; whether to trust it is §2.1's staleness call, not the sweep's. Residual,
stated rather than hidden: a report for a package that USED to be a path dep and no longer is now
lingers — information kept rather than destroyed, and disclosed.

Two guards, two mutants, each failing its named test and only it. The manifest-name row uses a dep
whose DIRECTORY name differs from its package name, because with `Dep0/` holding package `Dep0` the
basename fallback answers correctly too and the branch under test could be deleted with the row still
green.

### soundness — a fifth name-keyed map a rebind never invalidated, and this one edges to a BODY (2026-07-27)

⚠ **`fnValueAlias` outlived the binding that set it** (`CallCollector.swift`). It maps an inferred
fn-value local to a NAMED LOCAL FUNCTION (`let g = eff` → invoking `g()` edges to `eff`), and no clear
path touched it: not `clearBinding`, not `clearBindingTypeOnly`, not `shadowName`, and
`leaveShadowScope` neither saved nor restored it. So an alias established for a name answered for every
LATER and every INNER binding of that name. Measured with the rename control:
`func f(_ jobs: [() -> Void]) { let g = eff; for g in jobs { g() } }` reads `['Fs']` — `eff`'s effect
charged to an invocation of a loop element — while the identical body binding `h` is ABSENT; the same
for an inner `let g = { }`, a visibly pure closure that inherited `eff`'s body.

This is the **fifth** map in one mechanism and the widest of them: the other four are TYPE indexes, so
leaking one charges whatever some type's member happens to do, while this one charges a named
function's entire transitive effect set. It is now cleared by `shadowName` and saved/restored by the
enclosing scope, with the same self-referential-initializer carve-out `protoTyped` needs (`let g = g`
resolves through the binding it replaces). Three guards, three mutants, each failing its named
assertion and only it.

Measured on 34 real Swift packages: **0 gains, 0 losses, 0 entry delta** — and per the standing bar
that clean diff is the fabrication CONTROL, not the evidence. Instrumented, the rung is established
exactly ONCE across the corpus (console-kit's `let rpp = linux_readpassphrase`) and the fix's trigger
— a rebind dropping a live alias — fires **zero** times there. The fixtures are the evidence.

### soundness — the FULL-QUAL dep-index key, and the guard it makes provable (2026-07-27)

**A third dep-index key shape: `pkg#<full qual>`.** The `CANDOR_DEPS` index held exactly `pkg#leaf`
and `pkg#tail2`, so a consumer that knew its target PRECISELY had no key to ask on — `Conn.send` and
`Mock.Conn.send` are one tail2 string, and the ⟨0.23⟩ `typeSurface.returns` join, which forms
`<pkg>#<type qual>.<member>` from a fully qualified path, could only ever miss on a nested type.
Normalized rather than raw, so a report another engine wrote as `mod::Type::fn` is keyed the way a
Swift call site spells it. Additive by construction against every other entry (a leaf key carries no
`.`, a tail2 key exactly one), and the **DEDUP is the whole safety argument**: for a 1- or 2-segment
qual the "full qual" IS the string already pushed, so an undeduped third push self-collides and §2
rule 1 withdraws a key that already worked. Both directions are asserted by one test and both were
verified to catch — with the dedup deleted, a bare free call into the dependency goes ABSENT from the
report, which under the ⟨0.21⟩ manifest is a positive purity claim. Index grew 14 535 → 15 398 keys
over seven real repos split one package per target; keys present before and absent after: 0. Report
bytes unchanged: 11 targets unchained and 43 chained consumers, all byte-identical, 0 gains, 0 losses.

**The `typeSurface` exact type-path match is no longer an open question.** It shipped honestly marked
UNPROVEN, because relaxing it to a suffix match failed no test — a suffix match returns a path of two
or more segments, the consumer forms a three-segment key, and the old index missed it. With the third
key the wrong answer LANDS: a factory returning a type the package does not declare then publishes the
nested type that merely shares its leaf, and the caller is charged an effect it cannot reach while
losing its disclosure with it. Pinned by a fixture written with the key, mutation-verified, and paired
with the row that must still resolve.

### ⚠ soundness — the five-shape cross-engine sweep (2026-07-27)

Five defect shapes confirmed in one engine each the day before, swept here. Three were PRESENT, one
ABSENT with the line that prevents it named, and one — swift's own — was VERIFIED holding and then
found leaking through two maps its verification did not cover. Every fix carries both fixtures (the
case that must now work AND the case that must still work), every guard was mutated out with its
named failing test recorded, and every arm's binary was kept by content hash.

**⚠ An untrusted chained report no longer grants COVERAGE.** §2 rule 3 turns a report's silence into a
purity claim and §2.1 says a report from another engine build is not ours to repeat; the loader did
both at once, so the keys a stale report CARRIED read `Unknown` (right) while every key it did not
contain read PURE. A stale report is now CHAINED but not COVERED — the split matters in both
directions, since gating the join on coverage too would take rule 2's downgrade with it (four named
tests). Measured live: with console-kit's six dependency reports marked as another build, 29 functions
gain an `invisible` hedge and 18 that were absent from the report entirely come back, 0 effect losses.

**⚠ The report differed from itself under `CANDOR_WORKSPACE_CHAIN`.** Protocol-CHA union entries were
appended from two DICTIONARY iterations, so five runs of one binary over Alamofire gave five report
hashes carrying the same 879 entries in five orders. Sorted at the point of emission; content
bit-identical.

**⚠ `--workspace` kept a previous run's report when this run's scan of that dependency FAILED.** The
child's stderr went to `/dev/null` and the skip was silent, so `.candor/deps/` handed the analysis a
stale answer and §2 rule 3 made its silence a purity claim — a warm run and a cold run of identical
source disagreeing, one reading `invisible: ['DepLib']` and the other absent from `functions`. Reports
no successful scan produced are now swept, the failure is disclosed with the child's own reason, and
the fixpoint re-runs once so a sibling that chained the removed report is re-derived without it.

**⚠ The reason-scoped gate was inert twice over.** `reasonClass` tested `dynamicMemberLookup` for
EQUALITY while the engine emits `kind:detail`, so `Unknown[reflect]` was silently unsatisfiable even
single-tree; and a chained dependency's Unknown arrived carrying only `dep:<hash>`, so the class was
lost at the first hop. Both fixed with no format rung — the dependency's report already carries
`unknownWhy`. Over a three-package chain `deny Unknown[reflect]` now bites single-tree, one hop and two
hops alike, while `[native]` bites in none of them and `[unresolved]` no longer fires on a classified
hole.

**⚠ Two name-keyed maps a binder never invalidated, both fabricating.** `protoTyped` charged a local
protocol's conformers to a call on a loop binder that shadowed the protocol-typed parameter;
`localConstStrings` attributed a literal host to a `dataTask` whose address is a runtime value. Each
measured with the rename control that separates a leaked flag from an untyped binder. The obvious
placement cost Alamofire's `URLRequest.init` its disclosed `Unknown` — SwiftSyntax walks a binding's
pattern before its initializer, and that function is `let url = try url.asURL()` — so the clear lives
where a binder cannot type the new binding, plus one line guarded on the initializer not mentioning
the name.

**The `unresolved` marker does NOT fail open here** (candor-ts `e66f29e` swept): it is DERIVED from the
effect set at the single writer, and over 12 004 real entries — 10 539 carrying `Unknown` — 0 fail the
marker and 0 carry a direct `Unknown` without an `unknownWhy`. The dead parallel `unresolvedSet`, whose
only possible future was to disagree with that line, was removed and the invariant pinned by tests.

**Half 1's provenance conjunct no longer fires on the enclosing type's own methods.** Instrumented over
14 targets it bound 289 locals — led by `rootOf`, `classifyItems`, `createFunction`, all enclosing-type
methods, then `sin`/`cos`/`atan2`/`sqrt` — and not one was a dependency factory. Now 123. The exclusion
is scoped to the enclosing type and its local supertypes, never a flat leaf set, because widening it
drops a genuine disclosure.


### ⚠ soundness — three defects in the erasure/typeSurface gates, found by adversarial review

Three fixes, each with its own two-direction fixtures and each guard verified by mutating it out and
naming the test that fails. A/B over 14 real Swift targets / 12 004 entries (pollen, candor-swift,
swift-syntax, Alamofire, vapor, TCA, SQLite.swift, swift-argument-parser, console-kit, Files, swift-log,
Commander, ShellOut, swifter): 0 effect gains, 0 losses, Unknown unchanged.

**A ternary's opacity is a claim about BOTH arms.** `rootOf` composed `cond ? a : b`'s monomorphization
flags with `||`, so a receiver monomorphized on one arm and ERASED on the other was treated as fully
monomorphized: the local-conformer CHA was skipped for the erased arm too and the function went ABSENT
from `functions` — a positive purity claim, under the ⟨0.21⟩ manifest, about a body that performs the
conformer's effect. Opacity licenses suppression, so it composes by conjunction.

**A binder is an `IdentifierPattern`, not an entry on a list.** `patternNames` enumerated three of the
seven `PatternSyntax` kinds, so `for case let x?`, `for case .some(let x)`, `for case let x as T` and
`for var x` never reached the shadowing path at all and the enclosing signature's opacity /
dependency-provenance flags stayed attached to the loop's own unrelated binding — silent-pure in one
direction, a false `Unknown[dispatch:…]` for a purely local value in the other. Now a walk for every
`IdentifierPatternSyntax` in the pattern subtree (verified in both directions against SwiftParser: every
bound name reaches one, and no non-binding pattern produces one), plus a catch-all that CLEARS any binder
no specific visitor claimed — so an unenumerated form defaults to dropping a stale binding rather than
keeping one. Two forms are now typed as well, since scoping alone left them untyped and silent for a
second reason: `for case let x as T` (T is written in the source) and `for case let x?` (Optional sugar).
A loop binder's type no longer outlives its loop. Also fixed: `catch let e as MyError` matched a
`DeclReferenceExpr` where the parser puts a `patternExpr > identifierPattern`, so that branch never fired.

**The `typeSurface` ANSWER must be unambiguous, not just the entry.** The ⟨0.23⟩ consumer keys a BARE
callee name against every covered package the file imports and gated only on the entry lookup being
unambiguous. Two chained packages both exporting `build` — one returning a type with an effectful
`fetch`, the other a type whose `fetch` is pure and therefore absent — charged the first package's effect
AND its path literal to a caller that reaches only the second, with `unresolved` left false so nothing
disclosed it. SPEC §2 rule 1's never-guess rule now applies across the file's imports too, and refusing
falls back to half 1's disclosure. `CANDOR_TYPESURFACE_DEBUG` reports `AMBIGUOUS` as its own verdict.


### ⚠ ⟨0.23⟩ `typeSurface.returns` — the factory-bound receiver resolves, not just discloses

`let c = build(); c.fetch()` types `c` from `build`'s RETURN type, and a PURE `build` is ABSENT from the
dependency's report entirely (SPEC §2 rule 3), so no consumer could recover it from the entries. Half 1
made that disclose `Unknown` instead of reading silent-pure; this recovers the effect. `deny Fs` on
identical source goes one-package exit 1 -> split+chained exit 0 -> exit 1 again.

PRODUCER: a new optional envelope field `typeSurface.returns`, mapping `<pkg>#<fn qual>` to
`<pkg>#<type qual>`, both FULLY QUALIFIED in this package's own namespace. Omitted when empty, so a report
with nothing to say is byte-identical to a pre-rung one and a ⟨0.22⟩ consumer is unaffected. A wrapper
return (`-> Conn?`, `-> Result<Conn,E>`, `-> [Conn]`, `-> Box<Conn>`) publishes NOTHING: the binding holds
the wrapper, and keying its `map` against the payload would charge effects nobody runs. A PROTOCOL return
IS published — `func make() -> SomeProtocol` is the commonest Swift factory — and the key it forms is
answered by the producer's `interfaceUnion` entry, so the two mechanisms are layered.

CONSUMER: a miss on `returns`, or on the entry lookup that follows a `returns` hit, falls back to half 1's
disclosure and never to silence — the index deliberately drops keys two entries share, so a miss cannot
tell "no such method" from "I withdrew the answer". A STALE producer's surface is not read at all.

Measured: 11 real targets unchained, 0 effect gains/losses/entry deltas and the only envelope change is
the new field (3 564 entries published). 5 chained consumers, 0 gains, 0 losses; the consumer arm is
entered 20 times and misses every time — instrumented via `CANDOR_TYPESURFACE_DEBUG`, which prints the
producer counts and every consumer hit/miss.

Residuals, deliberate: a NESTED type's method is unreachable for the consumer (the key is three segments
and the dep index carries `pkg#leaf`/`pkg#tail2` only — it misses and discloses); `-> any P` / `-> some P`
returns are refused.

### soundness — one apply site for a chained dep entry; the chained-GLOBAL one had drifted

The engine carried three copies of "inherit a chained `DepEntry`", and the chained-global read applied
the effects, `hosts`, `cmds` and `paths` while silently dropping `tables`, `invisible` and `incomplete`.
A consumer reading a dependency's effectful lazy global therefore inherited the EFFECT and none of the
dependency's own honesty markers — turning a qualified claim (`Fs`, plus a blind spot inside the
dependency) into an unqualified one. Now one `applyDepEntry`. No corpus output changes; the fixture is
the evidence.

### soundness — two scope leaks in the erasure gate, both silent under-reports

Both are the standing-bar item 0 shape — a fabrication fix narrowing past a real reach — and both are
invisible in a corpus A/B because each needs a name collision no measured target contains.

- The ELEMENT-opacity set was written in lockstep with the element TYPE (the CLEAR half of the scope
  discipline) but was never added to the scope SAVE. An inner block binding an existing name from a
  monomorphized source (`if c { let ys = xs.filter { … } }`, `xs: [some P]`) marked `ys` monomorphized for
  the rest of the FUNCTION, so the ERASED `ys: [any P]` parameter it shadowed lost its dispatch and an
  Env-performing function read pure.
- A nested `func`'s PARAMETERS were not a scope. `func outer(_ s: some P) { func inner(_ s: any P) { … } }`
  suppressed the CHA on `inner`'s genuinely erased receiver because the enclosing parameter, a different
  variable, is spelled `some`. The nested signature's own opacity is re-applied, so the mirror
  fabrication does not open.

### ⚠ soundness — implicit stringification through a PROTOCOL-typed operand (Swift arm of the four-way vein)

Closes a silent under-report (cardinal sin): `"\(e)"` / `String(describing: e)` / `print(e)` runs the
operand's `description` (or `debugDescription`), and when the operand's static type is an EXISTENTIAL
(`any P`), a GENERIC bound (`<T: P>`), or a caught `error`, the witness belongs to a CONFORMER — so
nothing was edged and the function read PURE while its `description` performed I/O. The concrete-operand
form was already modeled (the implicit-conversion vectors in smoke.sh); only the dispatching form was
missing. This is the Swift arm of the common-mode vein recorded in
`candor-spec/SOUNDNESS-VEIN-implicit-stringify.md` (found on HikariCP through SLF4J parameterized
logging by the dynamic oracle, reproduced in all four engines).

A stringification site whose operand is a local protocol — or one of the stringify/error protocols whose
CONFORMANCE is declared in the analysed code (`CustomStringConvertible`, `CustomDebugStringConvertible`,
`Error`, `LocalizedError`) — now resolves by CHA over the conformers (and their subclasses), edging to
the `description`/`debugDescription` accessor units that exist and climbing to an INHERITED witness (a
protocol-extension default) when the conformer declares none. `catch` bindings are typed for this path
only: the implicit `error`, `catch let e`, and the concrete `catch let e as MyError`.

PRECISE-OR-NOTHING, deliberately: an unresolvable conformer set edges nothing rather than disclosing
`Unknown` (a conformer with no `description` stringifies through the stdlib's PURE reflective default,
and interpolation is pervasive enough in Swift that an Unknown here would flood every report). RESIDUAL,
recorded not repaired: a conformer declared outside the analysed code whose `description` is effectful is
still missed. No fabrication: a String/Int/library operand edges nothing, and the external-protocol list
is closed by NAME precisely because Swift's inheritance clause is overloaded — `enum Suit: String`
records String as a "conformed supertype", so an open rule would edge every `"\(someString)"` to that
enum's `description`.

A/B over 10 real packages (Alamofire, console-kit, Files, SQLite.swift, swift-argument-parser,
swift-composable-architecture, swift-log, vapor, pollen, candor-swift itself — 4360 reported functions):
3 gains, all explained, all transitive `Unknown` inherited from units that already carried it —
SQLite.swift `Context.set` (`String(describing: result)` on a `Binding?` → `Blob.description` →
`Blob.toHex`), and vapor `BodyStreamResult.description`/`.debugDescription` (`"error(\(error))"` on an
`any Error` payload → `DebuggableError`/`ValidationsError`/`MacroError` `description`). Zero fabricated
effects; every conformance fixture byte-identical (the four-way differential is untouched).

## [0.23.1] — 2026-07-20

### performance — quadratic per-function loop-invariant removed (no output change)

The per-function analysis loop rebuilt `Set(freeFnByName.keys)` at every `CallCollector` construction —
`freeFnByName` is fixed after decl-aggregation and never mutated in the loop, so this was O(freeFns) × N =
**O(N²)** on any function-heavy corpus (ms/function rose 0.07 → 0.40 across 500→10000 funcs). Hoisted to a
single build before the loop → flat ~0.05 ms/function, **8.4× faster at 10k functions**. Report output
verified byte-for-byte identical (this is a loop-invariant hoist, not a semantic change); `swift test` green.

### ⚠ soundness — sync callback-invoker opaque-arg (Swift arm of the four-way parity fix)

Fixes a silent under-report (cardinal sin): an OPAQUE closure passed to a SYNCHRONOUS higher-order
invoker — `Sequence/Collection.forEach/map/filter/compactMap/flatMap/reduce/first/contains/allSatisfy/
sorted/min/max/…` (and their bare-`self` forms in a `Collection` extension) — read PURE, when the
invoker CALLS its closure argument in-thread. `xs.forEach(cb)` where `cb` is a fn-typed param is the
exact sibling of the already-correct direct call `cb()` and must contribute `Unknown` (`callback:<arg>`).
INLINE closure literals (`xs.forEach { … }`) keep their analyzed effect (charged lexically to the
passer — never reach the guard) and RESOLVABLE named callables (`xs.forEach(namedFn)`) keep their
resolved effect via the fn-ref edge — only OPAQUE args disclose, so over-disclosure is low. Matches
candor-java's `SYNC_CALLBACK_INVOKERS` opaque-arg guard (c755acd). A/B on swift-argument-parser:
+2 direct sites (`InputOrigin.forEach`, `ErrorMessageGenerator.unknownOptionMessage`) + 3 honest
transitive reaches; zero fabrication, zero inline-closure flood; report bytes otherwise unchanged.

## [0.23.0] — 2026-07-20

Spec floor → **0.23**. Soundness-increasing, report-shape-neutral:
- **cross-package protocol dispatch** (interfaceUnion, the 0.23 rung): a chained consumer's protocol method
  resolves to the conformer's effect (gated behind `CANDOR_WORKSPACE_CHAIN`). PART 18 conformance.
- **⚠ opaque closure → synchronous invoker** (`arr.forEach(cb)`/`map`/`filter`/… with an opaque closure
  param) discloses `Unknown` — the four-way sync-callback rung (PART 1 `sync_callback_opaque`). Inline
  closure literals keep their analyzed effect (no over-disclosure).
- protocol-union emission guarded against same-tail-type name collision.

## [0.22.0] — 2026-07-18

Spec floor → **0.22** (the `verify` oracle rung, shipped on the java/ts arms). candor-swift declares `0.22`; the
report and verdict schema are unchanged from 0.21, so this engine's output is byte-identical across the bump. No
functional change to the Swift engine.

## [0.19.0] — 2026-07-17

Reason-scoped `Unknown` policies (SPEC §6.2): `deny E Unknown[reflect,dispatch,indirect,native,unresolved,setup]`
narrows the `Unknown` part of a deny to a fixed reason-class vocabulary, with the `dynamic`/`*` aliases and
config `.candor/config` `unknown-alias <name> = <class…>` names. Bare `deny E Unknown` is unchanged
(`Unknown[*]`); an unrecognized reason maps to `unresolved`; the class propagates transitively. An AS-EFF-006
`--gate-json` verdict whose `effects` include `Unknown` carries a **`reasonClass`** array. Report bytes
unchanged. Also: a scan-level **SETUP warning** — a `Package.swift` that declares dependencies but has no
fetched `.build/checkouts` prints a "run `swift build`" remediation (the analog of a missing node_modules).

## [0.18.0] — 2026-07-16

### spec 0.18 — the trust-trio

candor-swift now declares **spec `0.18`** (`specVersion`; engine `candor-swift-0.18.0`). A pinned-tool-surface
rung (no report/verdict change), pinned four-way in the conformance suite:

- **`--strict` advisory-verb CI gate**: `fix-gate`, `gains`, `unverified` are advisory (exit 0); `--strict`
  makes each a CI gate (exit 1 while a finding remains). `gains` rejects a `--policy` (exit 2), naming the
  scan-time `deny <E> gained` gate (`AS-EFF-005`).
- **mostly-Unknown disclosure**: the scan opener (`emitSurface`) + `tour` never say "nothing hidden" over a
  ≥⅓-Unknown graph; `tour --json` carries an additive `unknown: {count, total}`.
- Hardening from a Fable-model code review: the scan opener gained the ⅓-Unknown gate it was missing (only
  `tour` had it); `gains --strict` added.

## [0.16.0] — 2026-07-16

### ⚠ The callgraph-aware baseline guard + Unknown-only advisory ⟨0.16⟩

The AS-EFF-005 regression ratchet (`CANDOR_BASELINE`) now keys existence on the baseline CALLGRAPH
sidecar, not the report. The report OMITS pure functions, so the pre-⟨0.16⟩ guard read a formerly-
PURE function turning effectful as "new" (exempt) and let it escape — the sharpest supply-chain
shape. ⟨0.16⟩ the sidecar lists every analyzed function (pure ones included, SPEC §2.2), so a
pure→effectful transition is now caught: `[AS-EFF-005]`, exit 1.

- **Callgraph-keyed existence.** A function present in the baseline callgraph sidecar but absent from
  its report is a KNOWN-PURE function; gaining a real boundary effect against it is a violation. When
  no sidecar accompanies the baseline the guard degrades to report-only existence (a stderr note,
  exit unchanged) rather than failing; a corrupt sidecar fails closed (exit 2).
- **Unknown-only gain is advisory, not exit 1.** A corpus test found the guard, on real dependency
  bumps, firing only on gained-`Unknown` — resolution noise, not a capability gain. `Unknown` is the
  §4 trust marker (pure policies exclude it), so failing pure→Unknown broke CI on innocuous bumps.
  Now the ratchet (exit 1) fires only on gaining a REAL boundary effect; an Unknown-ONLY gain is
  disclosed as one advisory note, exit unchanged (`--gate-json` stays `ok: true`). A real+Unknown
  gain still fails and reports only the real effect. Pinned by conformance PART 15c.

**⚠ report/verdict-affecting** — an upgrade across 0.16 is baseline-invalidating (regenerate the
saved baseline, callgraph sidecar included, with the new build); and **⚠ the `spec` string changed**
to `0.16` — a consumer pinning `spec == "0.15"` must accept `0.16`.

## [0.15.0] — 2026-07-15

### ⚠ The coverage envelope + privacy-manifest conditionality ⟨0.15⟩ (candor-spec/COVERAGE-DESIGN.md)

The wikipedia-ios false-confidence find (a real-world corpus-testing find, SOUNDNESS-LOG 2026-07-15):
"what the scan couldn't see" — the κ ledger — now travels WITH the report and conditions the
verdicts, instead of evaporating on stderr. Before: `privacy-manifest --verify` answered `ok: true`
with no caveat over 19 invisible modules; after: `conditional: true` + `coverage: { uncovered: 19 }`,
exit code unchanged. Pinned by conformance PART 4s.

- **`coverage` envelope field.** The κ-coverage ledger (the stderr `classifier doesn't cover` line)
  as data: `"coverage": { "uncovered": [ { "name", "calls" }, … ] }` — same modules, same import
  counts, same order; OMITTED entirely when nothing is uncovered, so a fully-covered report keeps
  the exact pre-0.15 document shape (verified byte-identical against the prior release binary
  before the version bump; the shipped envelope differs only in its `version`/`spec` strings).
- **`privacy-manifest --verify` is coverage-conditional.** When the report's ledger is non-empty (or
  any fn carries `invisible`), the JSON verdict gains `conditional: true` +
  `coverage: { uncovered: N, modules: [...] }`, and the human output appends the
  `⚠ verdict is conditional on N uncovered modules…` line. Exit code UNCHANGED (disclosure, not a
  gate); both keys absent on a fully-covered report.
- **`--gate-json` advisory coverage note.** The structured verdict carries the same small
  `coverage` block when the ledger is non-empty — VERDICT-PRESERVING (ok/violations/exit computed
  exactly as before; the ⟨0.9⟩ provable-purity auto-disclosure precedent).
- **`gains --json` re-discloses coverage.** The CURRENT report's envelope `coverage` block rides the
  answer verbatim when present, plus `coverageDelta: { nowUncovered, noLongerUncovered }` when the
  baseline's uncovered NAME SET differs (names only). Human TSV unchanged (pinned surface).
- **Per-fn `invisible`, module-qualified precision.** A member call whose confidently-resolved
  receiver root IS a blind imported module (`SomeSDK.doThing()`) now attributes `invisible` with
  exactly that module — precise, not file-granular, so the sweep-[33]/[36] no-flooding guard for
  member calls on stdlib/κ-pure receivers is untouched. (Report bytes change only for that shape —
  an added disclosure, the sound direction.)

### Host-resolution recall — constant strings + literal heads

Two recall improvements to the §1 host-refinement path (`Llm`/`Db`/`Net` uniformly), matching
candor-java; both conservative — any ambiguity stays bare `Net`, no fabrication:

- **Constant-string resolution** (conformance **PART 4q**). A host built from a string constant —
  `let apiBase = "https://api.openai.com"; URL(string: "\(apiBase)/chat")` (interpolation, bare
  ref, or const-left concat) — now resolves through the host-refinement path exactly like an inline
  literal. A module/global/static or local `let NAME = "literal"` is indexed; a var, runtime value,
  or non-const first segment stays bare `Net`, and ambiguous same-name consts resolve to nil.
- **Literal-head extraction** (conformance **PART 4r**). An interpolation/concat whose FIRST literal
  segment itself completes `scheme://authority/` — `"https://api.openai.com/v1/\(path)"` — now
  extracts the host and fires the refinement (was bare `Net`). A split authority, interpolated
  port, or unterminated authority stays bare `Net`; a CDN-style head stays `Net` (no fabrication).

### spec 0.15 — the coverage-envelope rung (§2)

candor-swift now declares **spec `0.15`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.15 is another tier-2 (pinned-tool-surface) rung, additive over 0.14: it admits
the envelope `coverage` ledger and the coverage-conditional verdict surfaces into the pinned contract.
**⚠ report bytes change** — every envelope's `version`/`spec` strings, plus wherever a scan has
uncovered modules (the report gains the `coverage` field) or a newly-refined host shape (gains
`hosts`/`Llm`/`Db`) — so an upgrade across 0.15 is baseline-invalidating; and **⚠ the `spec` string
changed** — a consumer pinning `spec == "0.14"` must accept `0.15`.

## [0.14.1] — 2026-07-14

Patch — a soundness fix, still spec `0.14` (a false-pure hole closed; report bytes change for the fixed shapes).

- **Tuple-destructured global no longer dropped.** `let (a, b) = effectfulInit()` at file scope binds
  names (so it is not a `<main>` statement), but the identifier-pattern-only unit guard SILENTLY DROPPED
  its initializer effect — a `let (a, b) = readConfig()` global read pure (the cardinal sin, the top-level
  sibling). Each bound name now carries the shared initializer's effect (a sound first-touch
  over-approximation); the same fix covers a `static let (p, q) = …` type member. Found probing adjacent
  cases after the 0.14 top-level rung.

## [0.14.0] — 2026-07-14

### ⚠ FIXED — the top-level `<main>` initializer unit (a false-"pure" empty report — the cardinal sin)

A `main.swift` / script file whose **bare top-level executable statements** performed an effect was
SILENTLY DROPPED: those statements belong to no function, so the collector minted no unit for them and
the report came back a false-"pure" empty — the cardinal sin. A `deny Llm` / `deny Net` gate PASSED
such a file even though its top level opened a socket or called a model provider. The top level is now
synthesized as **one `<main>` unit per file**, carrying `unitKind: "initializer"`, with the file's
top-level effects and its transitive call edges — so the effect is disclosed and the gate now catches
it. The unit is minted **only when the top level carries or reaches an effect** — a pure top level mints
no unit (report bytes unchanged for pure files). Global-var initializers, computed properties, and
stored-property inits were already sound and are **unchanged**.

Conformance **PART 4p** pins the top-level-initializer unit four-way (java `<clinit>` / ts `<module>` /
swift `<main>`; rust N/A — no free top-level executable statements). **⚠ report bytes change** on any
file with an effectful top level (a previously empty/"pure" report gains the `<main>` unit), so an
upgrade across 0.14 is baseline-invalidating.

### spec 0.14 — the top-level-initializer rung (§3.1)

candor-swift now declares **spec `0.14`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.14 is another tier-2 (pinned-tool-surface) rung, additive over 0.13: it admits the
`<main>` top-level initializer unit (`unitKind: "initializer"`) into the pinned contract. **⚠ report
bytes change** where a file's effectful top level is now surfaced as a `<main>` unit (a report
previously seen as empty/"pure" gains the unit), so an upgrade across 0.14 is baseline-invalidating; and
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.13"` must accept `0.14`.

## [0.13.0] — 2026-07-14

### ✨ NEW `Llm` effect — a model-provider call (boundary effect refining Net)

candor-swift now classifies a call to an LLM/model provider as the **`Llm`** effect — a boundary
effect that refines `Net` (the Db precedent: a specialised network reach kept distinct so a policy can
name it), so an `Llm` call also carries `Net`. Two recognisers: the shared **model-host table**
(`MODEL_HOSTS` + `isModelHost`, verbatim from the family — the OpenAI/Anthropic/Bedrock/Ollama-style
endpoints, with Ollama pinned to the `:11434` loopback and Bedrock matched on the first service label,
not an S3-bucket substring); and a curated **Swift model-SDK TYPE list** (MacPaw/OpenAI,
AnthropicSwiftSDK, Bedrock, **plus Apple on-device FoundationModels** — `SystemLanguageModel` /
`LanguageModelSession`, so local inference counts). The SDK table is keyed by type NAME — the syntactic
engine can't resolve module owners — and a project's own same-named type SHADOWS it, so a local type is
never fabricated as an `Llm`. `Llm` joins the boundary/salience/allow sets, and an `allow Llm` rides
the `Net` host surface.

### ✨ NEW `privacy/1` SPEC EXTENSION — Apple privacy-sensor effects + the manifest verb

The first candor **spec extension** (SPEC.md §Versioning engine-extensions clause; contract in
**SPEC-EXTENSION-privacy.md**) — swift-led and ecosystem-specific. It adds **six Apple privacy-sensor
effects** — `Location` / `Camera` / `Mic` / `Contacts` / `Photos` / `Notify` — classified by the Apple
framework TYPE a call reaches (`CLLocationManager`, `AVAudioRecorder`, `CNContactStore`,
`PHPhotoLibrary`, `UNUserNotificationCenter`, `AVCaptureSession`), with the same declared-type shadow
as the `Llm` SDK types (a local same-named type is not the framework's — no fabrication). AVFoundation
capture reads the visible `.audio`/`.video` media-type (audio→`Mic`, video→`Camera`); an ambiguous
capture OVER-discloses `{Camera, Mic}` — the privacy asymmetry (never UNDER-declare a sensor, the
inverse of the never-fabricate rule) — and `AVAudioEngine` is member-gated to `.inputNode` so a
playback-only engine carries no `Mic`. The six are boundary effects (containment + the sharp
salience-5 set), gate-able by deny/containment but NOT allowlistable (no host literal, like
`Ipc`/`Clipboard`) and not injection-class. The envelope discloses `extensions: ["privacy/1"]` **only
when a privacy effect is active** — a plain report stays byte-unchanged.

- **NEW `privacy-manifest` verb** — `candor-swift privacy-manifest [--report <locator>] [--verify
  <Info.plist>] [--json]`. GENERATES the required Apple usage-description keys from the code's
  transitive sensor reach, or VERIFIES an existing `Info.plist` against it: a reached capability the
  manifest omits is the App-Store-rejection-shaped **under-declaration** (exit 1); a declared-but-unused
  key is an over-declaration (warning, exit 0). The effect→key mapping and JSON shape are in
  SPEC-EXTENSION-privacy.md; plist parse via `PropertyListSerialization` (XML + binary, fail-loud
  exit 2). It reuses the query-verb report-locator + loud-load machinery (one source of truth).

### `gains` loader loudness (follow-through on the 0.12 verb)

Per-entry drops among otherwise-good entries are now DISCLOSED with a count (Rust wording); the loud
loader mirrors the reference net rule per side — no files → exit 2, net-empty with any hard failure →
exit 2 (tightening the previous exit-0 empty answer over a clean-empty + corrupt sibling), a partial
merge tolerated with a "delta is computed over a PARTIAL side" summary.

### spec 0.13 — the Llm + privacy-extension rung (§3.1)

candor-swift now declares **spec `0.13`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.13 is another tier-2 (pinned-tool-surface) rung, additive over 0.12: it admits the
`Llm` boundary effect and the `privacy/1` extension surface into the pinned contract. The `privacy/1`
extension carries its OWN version (`"privacy/1"` in the envelope `extensions` array — independent of the
spec string). **⚠ report bytes change** where an `Llm` or a privacy sensor is now classified (a call
previously seen as plain `Net`, or unclassified, gains the refined effect), so an upgrade across 0.13 is
baseline-invalidating; and **⚠ the `spec` string changed** — a consumer pinning `spec == "0.12"` must
accept `0.13`.

## [0.12.0] — 2026-07-14

### ✨ NEW `gains` verb — the supply-chain alarm (this engine's first)

`candor-swift gains <current> <baseline> [--json]` lists every `fn\teffect` the surface **gained**
between two reports (current `inferred` minus baseline, per function, sorted) — the alarm a CI job
raises when a dependency update quietly grows a capability. Both positionals are report locators (the
family's two-positional comparative form, like `diff` — no discovery, no policy); the default output is
the byte-stable `fn\teffect` TSV, `--json` the `{baseline_version, byFunction, engine_version, gained}`
machine form. Each `byFunction` entry carries **`origin`**: `existing` (the function was there at the
baseline and now performs the effect — the supply-chain *attack* signal), `new` (a new function grew
the effect — a feature), or `unknown`. Existence is keyed on the **baseline callgraph sidecar**
(reports omit pure functions, so a baseline-pure function is a graph node with no report entry); a
**partial** graph — a matched sidecar that fails to read or parse — degrades the negative claim to
`unknown`, never a mislabel, while a node still in the partial graph stays `existing`. Mirrors the
Rust reference `candor-query gains`; pinned four-way by conformance PART 5b.

### Report acceptance + loudness on the comparative verb

- **Legacy bare-array reports accepted** — the v0.1 form, including the clean-empty `[]` the other
  three engines already answer on (was a four-way divergence: candor-swift alone exited 2).
- **All-junk reports fail loud** — a non-empty `functions` array in which every entry is unusable is
  corruption (exit 2 + a naming stderr line), never an empty `{byFunction:[],gained:[]}` all-clear at
  exit 0; a well-formed empty array stays a valid pure report.
- **Producing-build provenance** — `gains --json` carries the unconditional
  `baseline_version`/`engine_version` fields (`""` = unknown), and when both are known and differ a
  §2.1 stderr ⚠ discloses that a "gained capability" may be the engine reclassifying, not the
  dependency changing (the TSV stdout is unchanged — the disclosure is stderr-only).

### spec 0.12 — the gains-origin rung (§3.1)

candor-swift now declares **spec `0.12`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.12 is another tier-2 (pinned-tool-surface) rung, additive over 0.11 and
invocation-compatible with it: it promotes the §3.1 `gains` **`origin`** field and the provenance
fields into the pinned contract, four-way (conformance **PART 5b**, including the partial-sidecar and
no-baseline cases). No report-schema, classifier, or verdict change — a 0.11 report/verdict is
byte-identical under 0.12. **⚠ the `spec` string changed** — a consumer pinning `spec == "0.11"` must
accept `0.12`.

## [0.11.0] — 2026-07-13

### spec 0.11 — the surprising-reach surface rung (§3.1)

candor-swift now declares **spec `0.11`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.11 is another tier-2 (pinned-tool-surface) rung: it promotes the **§3.1
surprising-reach surface** into the pinned contract — the scan-time opener (the single most surprising
transitive reach, a mundane-named function inheriting a boundary effect from hops away, with a
ready-to-run `candor path` command) and the **`tour [N]`** verb (the same deterministic ranking on
demand, top-N default 10, plus a pinned `--json` shape). One shared heuristic across the four engines,
with a **salience floor** (`Clock`/`Log`/`Rand` never surface), **module-segment test exclusion**
(drops `*Tests`/`tests::`, never a production `test_connection`), and the plain "nothing hidden"
fallback over a manufactured surprise. Pinned four-way by conformance **PARTs 4f–4k**. No
report-schema, classifier, or verdict change — a 0.10 report/verdict is byte-identical under 0.11.
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.10"` must accept `0.11`.

### ✨ NEW `path` verb — the provenance chain to the nearest source

`candor-swift path <fn> <effect>` walks the saved callgraph (BFS, sorted frontier) from a function to
the **nearest source of an effect** and prints the human chain — byte-identical to the Rust
reference — plus a `--json` form. This is the command the scan opener suggests; before 0.11 the swift
engine printed the suggestion without having the verb, a dead end for cold readers.

### Corrupt-report loudness parity

A **located report that yields no trustworthy functions fails loudly** (exit 2) — found-but-corrupt is
never an empty all-clear, while a well-formed `functions: []` stays a valid pure report. A
missing/empty callgraph sidecar falls back to the report's inline `calls` (never a false "nothing
hidden"); a present-but-corrupt sidecar gets a stderr disclosure; `tour 0` exits 2 instead of a false
all-clear. Pinned by conformance PARTs 4h and 4k.

### Plural `packages` tour-header label

`reportPackage` honours the SPEC §2 plural `packages` envelope (the JVM shape): the tour header labels
a multi-package report by the list's longest common dotted prefix (one entry verbatim; none shared →
basename fallback), so a cross-engine query over a JVM report names the code, not the filename.
Pinned by the conformance 4g addendum.

### Coverage-ledger marker: `classifier doesn't cover`

The de-jargoned ledger marker ships in this release — the [0.10.0] entry below describes the rename,
but the κ retirement landed after the v0.10.0 tag, so 0.11.0 is the first release carrying it. A
consumer grepping the old `κ doesn't know` marker must update to `classifier doesn't cover`.

## [0.10.0] — 2026-07-12

### spec 0.10 — the canonical query grammar rung (§3.3.1)

candor-swift now declares **spec `0.10`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.10 ratchets the conformance floor onto the newly-landed **§3.3.1 canonical query
grammar**: report discovery + the canonical `--report`, `--json`, and `--policy` flag forms are the pinned
§3.3.1 contract, and the old positional argument forms are **deprecated-but-still-accepted** (a scan or gate
invoked the old way still works — the deprecation is documentation-level, no behaviour change). Pinned by
conformance **PART 17**. This is a **version bump only** — no report-schema, classifier, or verdict change: a
0.9 report/verdict is byte-identical under 0.10. **⚠ the `spec` string changed** — a consumer pinning
`spec == "0.9"` must accept `0.10`.

### coverage-ledger rename — drop the bare "κ" from user- and agent-facing surfaces

The coverage-ledger stderr line no longer opens with the Greek letter **κ** — the first thing a cold
user saw with no explanation. The line now reads `candor-swift: candor's classifier doesn't cover N
module(s) this code imports — their effects are INVISIBLE to the scan (absent from the report, NOT a
claim they're pure): …`, and the shared **machine marker every engine keys off is now `classifier
doesn't cover`** (was `κ doesn't know`). README, AGENTS.md (+ the generated `AgentsDoc.swift`), and the
internal ledger comment follow suit. κ survives only as internal maintainer vocabulary — code
identifiers (`KAPPA_MODULES`, the κ table) and this changelog's history. No report bytes or gate
verdicts change — this is a text/marker rename only.

## [0.9.0] — 2026-07-11

### spec 0.9 — the remedial-loop rung

candor-swift now declares **spec `0.9`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.9 is a **tier-2 (pinned-tool-surface) rung** (candor-spec §"Conformance tiers"): no
report-schema or verdict change — a 0.8 report/verdict is byte-identical under 0.9 — but the remedial loop
(`fix`/`fix-gate`, `unverified`, and the gate auto-disclosure below) is now the pinned §3.1/§3.3 contract.
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.8"` must accept `0.9`.

### ✨ Gate scans auto-disclose the provable-purity gap (no need to know to run `unverified`)

A policy scan now emits the `unverified` disclosure automatically as a stderr note: after the gate verdict,
any function in a `pure`/`deny <E>` scope that PASSES but is `Unknown` (an unresolvable call — the classic
fn/closure-injected "port") is named, with the `deny <E> Unknown <scope>` upgrade that makes the layer PROVABLY
clean. Closes the discovery gap — an author learns their "pure" layer isn't *provably* pure without knowing the
`unverified` command exists. **Advisory only**: a note, never a violation, so the exit code, gate verdict, and
`--gate-json` are untouched. Emitted from `main.swift` after `evaluateGate`. Mirrors candor-scan/java/ts
(four-engine parity). Existing tests unchanged (128 + smoke 94 pass). The gate note and `unverified` share ONE
predicate (`CandorCore.unverifiedHoleRule` + `ruleUpgrade`) — a single definition of a hole, so the two
disclosure paths cannot drift (PART 12d pins it).

## [0.8.15] — 2026-07-11

### ✨ `unverified` — the provable-purity disclosure ported here (four-engine parity)

Ports candor-query's `unverified` (candor-query 0.8.10): a `pure`/`deny <E>` layer PASSES a function that has
no such effect — but if that function is `Unknown` (an unresolvable call, e.g. a fn/closure-injected port), the
pass is UNVERIFIED. Discloses each such function in a governed layer + the `deny <E> Unknown <scope>` upgrade
that makes the layer PROVABLY clean. `--strict` → exit 1. JSON `{ok, unverified[]}`. Byte-for-byte the same
disclosure as the other engines, pinned four-way by conformance PART 12c. Read-only; gate verdict untouched.

## [0.8.14] — 2026-07-11

### `fix`: the sandwiched-layer case is now handled (last correctness gap closed)

When an ALLOWED layer is CALLED BY a forbidden one (`D1 → A → D2 → site`, deny on the D layer), hoisting the
effect to the nearest allowed frontier `A` would leave `D1` still inheriting it. `cleanHoist` is now `false`
in that case (a forbidden fn calls into the frontier), with a message that names the sandwich and offers the
port/relax options — instead of a misleading "hoist to A". Detected in the same upward climb that gathers
`hoistHigher`; identical across all four engines, pinned four-way by conformance PART 12b's sandwiched
sub-check. Read-only; additive.

## [0.8.13] — 2026-07-11

### `fix`: fail loud on a corrupt report (from a high-effort /code-review)

The `fix`/`fix-gate` loader set `foundReport = true` BEFORE parsing, so a present-but-unparseable report
(truncated / mid-write / missing `functions`) was treated as "found" and `fix-gate` emitted a silently-clean
`{ok:true, remedies:[]}` over a report that exists but couldn't be read. The flag is now set only after a
successful parse (and the corruption is disclosed on stderr), so a lone corrupt report fails loud (exit 2) —
the fail-loud contract the file comment promises. Also aligns start resolution with the family (prefer an
effect-performing match), already the case here — a regression test pins it.

## [0.8.12] — 2026-07-11

### `fix`/`fix-gate`: the higher-hoist trade-off (FIX-SPEC's last refinement)

Each remedy gains `hoistHigher` beside `hoistTo`: the allowed-layer transitive callers of the minimal
frontier that also route the effect — every place you could originate it *further up* (hoisting higher keeps
the frontier pure too, at the cost of threading through more signatures). `hoistTo` (the minimal fix) is
unchanged. Byte-for-byte identical to candor-query/java/ts, pinned four-way by conformance PART 12b. Read-
only, additive JSON field; not report- or verdict-affecting.

## [0.8.11] — 2026-07-11

### ✨ `fix` / `fix-gate` — the boundary fix reaches the fourth engine (FIX-SPEC P3)

candor-swift gains its first read-only query subcommands: `fix <report-prefix> <fn> <Effect> <policy>` and
`fix-gate <report-prefix> <policy>` (JSON), the remedial inverse of the policy gate (integrations/FIX-SPEC.md).
When a function performs an effect its architecture layer forbids, candor computes the *architectural remedy*
— the direct call **site** to hoist, the forbidden-layer functions that become pure and thread the value (the
**deniedSpan**), and the nearest allowed-layer caller (**hoistTo**) — plus the policy-relax alternative. The
cut is **site-anchored** (walks up from the site through the denied layer), so the pure span is root-
independent; `fix-gate` collapses the inheritors of one crossing to a single plan. Byte-for-byte the same
remedy as candor-query / candor-java / candor-ts, now pinned four-way by candor-spec conformance **PART 12b**.

The pure algorithm is `CandorCore/Fix.swift` (reusing the existing `scopeMatches` + deny/`pure` predicate); a
small on-disk report + callgraph loader in `Sources/candor-swift/FixCLI.swift` reads a report a scan already
wrote (candor-swift stays scan-first — read-only, no report/verdict change). A policy is required (the fix is
defined relative to the boundary it crosses); an unreadable policy or a missing report fails loud (exit 2).
Five `FixTests` pin the collapse, the single-function cut, the clean case, and the no-op branches. Not
report- or verdict-affecting.

## [0.8.10] — 2026-07-11

### ⚠ Conditional conformance on a stdlib collection now dispatches (soundness R28 — report-affecting)

`extension Array: Saveable where Element: Saveable { func persist() { forEach { $0.persist() } } }` reached
via `xs.persist()` (xs: [Item]) read silent-pure — two coupled gaps, both fixed:
- the **array-receiver edge**: `xs.persist()` now resolves to the local `Array.persist` extension unit (a
  soft `resolveQual` edge, so a std array method like `xs.forEach` drops silently — no spurious Unknown);
- the **self-element dispatch**: a bare `forEach { $0.persist() }` over `self` inside the extension now types
  `$0` as the extension's element bound (`where Element: Saveable`), so it dispatches to the conformers.

A pure conditional conformance stays pure (no fabrication); a std array method with a local Array extension
present charges precisely (no Unknown). Gated by
`DriverResolutionProcessTests.testConditionalConformanceOnArrayCollectionDispatches`. **This closes the last
FIXABLE silent-under-report residual — only the fundamental syntactic-limit residuals (R2–R8) remain open.**

## [0.8.9] — 2026-07-10

### ⚠ Property-wrapper `$`-projection and keypath reads charge their effects (soundness round — report-affecting)

Two more accessor access-paths where the effectful accessor unit existed but the ACCESS SITE didn't edge to
it, so the effect read silent-pure (register R24, R25):

- **`m.$name`** — a property wrapper's `projectedValue` (the `$`-projection) is now edged, mirroring the
  existing `wrappedValue` edging (an effectful projection was dropped while `wrappedValue` was charged).
- **`h[keyPath: \.data]`** — applying a keypath via subscript READS the property; the implicit-root keypath
  resolver only handled the element-iterator form (`xs.map(\.p)`), so a `[keyPath:]` subscript application —
  whose root is the receiver's OWN type — was missed. Now resolved to the member's accessor unit.

Both are the same class as R22/R23 (the accessor unit carried the effect; only the access edge was missing).
The element-map keypath keeps working (no regression); a pure member read via `$`/keypath stays pure (no
fabrication); `@dynamicMemberLookup` still discloses `Unknown` (sound — a member it can't pin to a name).
swift-specific accessor surface. Gated by
`DriverResolutionProcessTests.testProjectedValueAndKeyPathAccessorEffectsCharge`.

Also, **generic-constrained dispatch** (register R26, R27): the inline `<T: P>` bound already dispatched
`x.method()` to `P`'s conformers, but two forms were missed and read silent-pure — a **`where T: P`** clause
(now collected alongside the inline clause), and a **type-level bound** `struct Box<T: P> { let x: T }`
reaching `x.method()` (the field typed `T` now resolves to its bound `P`, so the existing protocol-typed-field
dispatch fires). An unconstrained generic, and a bounded generic with no dispatched call, stay pure (no
fabrication). Gated by `DriverResolutionProcessTests.testGenericConstrainedDispatchWhereClauseAndTypeLevelBounds`.

And **`@resultBuilder`** (register R29): a func annotated `@SomeBuilder` has its body compiler-transformed
into `SomeBuilder.buildBlock(...)` etc, so an effectful builder RUNS when the func is called — but that
transform is implicit (no call site), so it read silent-pure. The annotated func now edges to the builder
type's `build*` units. A pure builder adds nothing (no fabrication). Gated by
`DriverResolutionProcessTests.testResultBuilderTransformChargesBuilderEffects`. (Known low residual R28:
conditional conformance on a stdlib type — `extension Array: P where Element: P` reached via `xs.method()`
— stays silent for now; a compound resolution, tracked in SOUNDNESS.md.)

## [0.8.8] — 2026-07-10

### ⚠ Setter `newValue` is now typed — effects through it charge (soundness round — report-affecting)

An effect reached **through a setter's implicit value param** — `set { newValue.write(toFile: …) }` on a
computed property or subscript, or a `willSet` observer — read SILENT-PURE, because `newValue` was never
given a type, so a member call on it didn't resolve to the effectful method. Hit computed-property setters,
subscript setters, `willSet`, and renamed setter params (`set(v)`). Fixed by seeding the accessor unit's
`newValue` (or the named param) with the property/subscript element type (the same `params` typing regular
parameters get). Effects where `newValue` is merely an ARG to an already-resolved call
(`set { UserDefaults.standard.set(newValue, …) }`, `set { save(newValue) }`) already worked — this is the
narrower *receiver* case. A pure setter still stays pure (no fabrication). Found by an adversarial
operator/setter probe. The `==`/`+`/subscript-getter operator paths were probed and were already sound;
candor-ts/kotlin/rust use explicit typed setter params (no implicit `newValue`), so this is swift-specific.
Gated by `DriverResolutionProcessTests.testSetterNewValueIsTypedSoEffectsThroughItResolve`. Register: R23
(CLOSED).

## [0.8.7] — 2026-07-10

### ⚠ Inherited property accessors now charge their effects (soundness round — report-affecting)

An effectful **computed property**, **`didSet`/`willSet` observer**, or **subscript** whose body lives on a
**superclass** read SILENT-PURE when accessed through a subclass: `d.payload` (where `payload`'s getter is on
`Base`), `s.name = x` (an inherited observer), `l.payload` (two-level). Property-edge resolution matched only
the accessed type's own `Type.member` accessor unit and — unlike the method-call path, which already climbs
the type hierarchy — never consulted the supertypes. So a method inherited from a base was charged, but a
property accessor inherited from the same base was dropped (the cardinal sin: a silent under-report). The
fix mirrors the method climb for property edges (`supertypesOf`, transitive → two-level works); an override
on the subclass still wins (its own unit resolves first, so nothing is fabricated), and a pure inherited
property stays pure. Found by an adversarial soundness probe, not corpus/CI; gated by a twin regression
(`DriverResolutionProcessTests.testInheritedPropertyAccessorEffectsClimbTheHierarchy`). candor-ts/java were
checked and are sound (they climb) — swift-specific, not a shared blind spot. Register: R22 (CLOSED).

## [0.8.6] — 2026-07-10

- ⚠ **The AS-EFF-005 baseline guard** (SPEC §7 item 5): `CANDOR_BASELINE` / the config `baseline`
  key now gate — an existing fn gaining an effect vs a same-build baseline is a violation (exit 1);
  a stale/provenance-less/unparseable or configured-but-EMPTY baseline is invalid gate input
  (exit 2, no evaluation); an absent file is a note (guard inactive). Previously disclosed-inert.
- **`parsepolicy`** subcommand: the §6.2 grammar witness, java-parity verified (building it fixed
  a set-dedup parser gap — duplicate deny effects/allow values now dedupe like every other engine).
  The cross-engine grammar differential (conformance PART 4) is hard four-way with this.
- Docs: family framing (reference engine = candor-java), the payload-host and pure-vs-Unknown
  rules in standing docs, release-tag upgrade guidance, identity drift gates, the cardinal-sin
  comment ruling.

## [0.8.5] — 2026-07-09

### ⚠ Net hosts are captured at ESTABLISHING forms only (report-affecting)

A string arg at a USE verb on an already-established channel (`Channel.writeAndFlush("x")`) is a
PAYLOAD, not a destination — capturing it minted a bogus host that could trip `allow Net` on data.
Hosts are now recorded only at establishing forms (connect/ctor), matching candor-java and
candor-ts; the establishing ctor's `host:port` capture is unchanged (conformance [4e]).

### ⚠ `pure` no longer counts `Unknown` as a violation (family ruling — verdict-affecting)

An Unknown-only function no longer trips a `pure` rule: `Unknown` is the §4 trust marker, not an
effect — AS-EFF-003 owns the uncertainty residual, and `deny Unknown <scope>` is the explicit
strictness knob (it keeps firing, effects `["Unknown"]`). Aligns this engine's verdict with the
reference engine (candor-java) and the rust/ts engines; pinned four-way by conformance PART 16.

### Added — consumer-side report chaining (SPEC §2)

`CANDOR_DEPS=<report paths>` (or a checked-in `.candor/config` `deps` line) joins an unresolved
call into a covered package to that dep function's recorded effects AND literal surfaces. Trust
rules at the join: a stale/versionless producer downgrades to `Unknown`; an all-pure dep's empty
report is a purity claim; a bad token or unparseable report fails closed (exit 2).

### Internal — main.swift split + pure §6.2 helpers extracted (no behavior change)

The ~2,900-line main.swift is now Config/DeclCollector/CallCollector/Driver/ReportModel/Gate +
CandorCore/Policy.swift (the pure parser/matchers, now directly unit-tested); plus a test wave
(forbid-loop pins, table-driven κ pins + shadow twins, actor attribution, driver resolution,
CANDOR_DEPS fail-closed arms) and the shared process-test harness.

## [0.8.4] — 2026-07-09

### ⚠ κ covered-module sweep: UserDefaults / Keychain / Bundle resources → Fs (report-affecting)

`UserDefaults` reads/writes, Keychain `SecItem*` CRUD, and `Bundle` resource lookups
(`url/path(forResource:)`) lived inside covered platform modules unmodeled — the covered-module
silent-pure shape. All now classify Fs (family decision: UserDefaults is a file-backed store;
SecItem* is the system secure store, not Db; Bundle resource lookup is an on-disk stat); the pure
surface (`volatileDomainNames`, `bundleIdentifier`) stays pure, with anti-fabrication twins.

### Changed — config discovery is target-anchored only; config-relative paths

The `.candor/config` CWD fallback is deleted (it only ever applied an UNRELATED repo's config);
a relative `policy` value now resolves against the config's home dir, and the governing config is
named on stderr.

### Added — CI + release hardening

Linux lane (swift:6.1 container), pinned-spec + weekly HEAD-tracking conformance, release.yml
tag ⇔ engineVersion guard, the fabrication probe gated in CI; README/AGENTS speak spec 0.8 with
smoke-gated spec strings.

## [0.8.3] — 2026-07-02

### Fixed — startup hang on some toolchains (0.8.2 users should upgrade)

The `.candor/config` ancestor walk (new in 0.8.2) used `URL.deletingLastPathComponent`, whose
behavior at the filesystem root varies across Foundation versions — on toolchains where `/` →
`/..` the walk never terminated and every invocation hung. Now a string-based walk (stable root
semantics) with a hop cap; plus CI hang mitigations (TTY-wrapped `swift test`, job timeout,
superseded-run cancellation).

---

Older: see [GitHub releases](https://github.com/tombaldwin/candor-swift/releases).
