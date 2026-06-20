# Changelog

## v0.7.0: Guided setup, simpler permissions, smarter speech gate

### Added
- **Guided first-run onboarding.** A welcome window walks you through your
  language and the permissions one at a time, flips each switch on with you,
  advances on its own the moment access lands, and finishes with a live
  "try it" so you know it works before you start.
- **Silero VAD as the speech gate.** A tiny on-device voice-activity model now
  decides whether you actually spoke before anything is delivered. It catches
  pulsed noise and quiet speech that pure energy detection missed (RMS stays as
  an automatic fallback), so the hallucination guard is sharper still.

### Changed
- **One permission instead of two for push-to-talk.** Talkink now uses
  Accessibility (which also enables auto-paste) rather than Input Monitoring.
  It shows up in the list on its own, you just switch it on, and it takes
  effect live: no more dragging the app in, no more quitting and reopening.

### Fixed
- **Long status messages no longer get cut off.** The floating pill wraps and
  resizes to fit, so disk-space and memory notices read in full.
- **Sturdier disk pre-flight** before a model download, with real headroom so a
  "there's room" verdict is honest.

## v0.6.1 — Hallucination guard

### Fixed
- **Silence can no longer paste invented text.** With a forced language
  (e.g. French), the models hallucinate plausible sentences on silence or
  room noise — reproduced on pure digital silence, where Qwen3 + French
  answers “Oui.”. Talkink now measures speech energy and discards any model
  output for audio that contains no speech: you get “No speech detected”,
  never a ghost sentence in your document. The auto-detect rescue also no
  longer runs on no-speech audio (it only handed the model a second chance
  to hallucinate). Discards are visible in Settings → Support (count and
  audio stats only — never text).

## v0.6.0 — Your words, your way

Production hardening (nothing fails silently anymore) + the most-wanted
dictation features: custom vocabulary, hands-free, URL automation, stats.

### Added
- **Vocabulary** (Settings → Vocabulary) — names and jargon, written your
  way. Add a word like “Talkink” with the forms it gets misheard as
  (“Talking”) and every transcription is fixed on this Mac, right after the
  model runs. Unknown words close to one of yours are corrected
  automatically — real words of your language are never touched (system
  spell-checker guard).
- **Hands-free dictation** — double-tap the push-to-talk key to lock
  recording on (the pill shows “Speak — tap to stop”), tap once to finish.
  Toggle in Settings → Dictation.
- **URL automation** — `talkink://toggle`, `record`, `stop`, `history`,
  `settings`, `report` for Raycast/Alfred/Shortcuts/terminal workflows.
  Dictation commands are off by default (Settings → Behaviour) so no other
  app can trigger the microphone without your explicit opt-in.
- **Dictation stats** — the History tab now shows total words, minutes
  spoken and your words-per-minute, computed from your kept history (local,
  like everything else).
- **Honest result pills** — every way a dictation can end now says what
  actually happened. Real silence reads "No speech detected"; clear speech
  that the model couldn't transcribe in your configured language reads
  "Heard speech — but nothing in French. Try Auto?" (the app now measures
  speech energy to tell the two apart); a skipped auto-paste explains itself
  ("secure field, paste with ⌘V" / "allow Accessibility to auto-paste").
- **Memory pre-flight** — before loading a model, Talkink checks it fits this
  Mac's unified memory (Metal working-set limit + current pressure) and
  refuses with a concrete suggestion instead of letting the load take the app
  down. Picking a too-big model keeps your current one running.
- **Disk pre-flight** — a download that can't fit fails instantly with the
  numbers ("needs ~3.1 GB, 1.2 GB free"), not at 97% twenty minutes in.
- **Report a Problem…** (menu + Settings → Support) — a transparent report
  (environment + recent error journal, never your transcripts or audio) you
  review first, then copy or open as a prefilled GitHub issue.
- **Error journal** — recent issues are visible in Settings → Support,
  persisted on disk, attached to problem reports, and written to the system
  log (subsystem `io.github.hasso5703.soyle`). Unclean exits (crash, force
  quit) are detected at the next launch and journaled too.
- **Updates you can't miss** — when a new version is found, the menu grows a
  first-class "⬆️ Update to X — Install…" item and the update alert comes to
  the front. After updating, the window opens once with an "updated" badge.
- **Unit tests + CI** — 52 tests pin the model catalog, per-engine language
  mappings, speech detection, memory verdicts, history persistence, download
  failure wording and hotkey logic; CI runs them on every pull request.

### Fixed
- **Clipboard writes are verified** — a failed copy says so and never
  auto-pastes (the old behaviour would have pasted the clipboard's *previous*
  content into your document). Transcripts always reach History first, so no
  words are ever lost.
- **History can't vanish silently** — save failures show up in the History
  tab; a corrupted history file is preserved as `history.corrupt-*` instead
  of being overwritten on the next dictation.
- **Permission state machine** — loading a model no longer masks the "Input
  Monitoring required" state, so the hotkey now re-arms the moment the
  permission is granted (previously it could show "Ready" with a dead hotkey
  until relaunch).
- **Stuck "Transcribing…"** — a watchdog resets dictation if inference ever
  stalls, instead of locking the hotkey out forever.
- **Dead capture is named** — holding the key while the input device delivers
  no audio now reports "No audio captured" instead of pretending you said
  nothing; a microphone yanked mid-recording stops the dictation with a
  message instead of recording silence.
- **Model load failures say why** (offline / disk full / rate-limited) with a
  Retry item in the menu — previously the menu claimed "Loading model…"
  forever after a failure.
- Failures that used to vanish into the void are now journaled and surfaced:
  download errors (with the actual reason under the model row), model
  deletion errors, "Launch at login" registration errors, update relauncher
  errors.

You're no longer married to one speech model: choose between seven, see
exactly what lives on your Mac, and download several at once.

### Added
- **Model catalog in Settings** — Qwen3-ASR 1.7B & 0.6B, NVIDIA Nemotron 3.5,
  Voxtral Mini 4B (8-bit / bf16 / 4-bit variants). Every row shows real size,
  quality and speed ratings from our own multilingual benchmark, and what's
  already on this Mac. The recommended default is **Qwen3-ASR 1.7B 8-bit**
  (best accuracy of everything we measured).
- **Resumable downloads** — models download with a live byte-accurate progress
  bar, several at a time, and an interrupted download (quit, crash, Wi-Fi
  drop) resumes exactly where it stopped ("Resume — 62% here").
- **Delete models** you no longer use, right from the picker.
- **27 dictation languages** (was 9) — every one verified against what the
  models actually support, passed to each engine in its own native format.
- **Wrong-language rescue** — if the configured language doesn't match what
  you spoke and the model returns nothing, Talkink silently retries in
  auto-detect, so your dictation lands anyway (then suggests Auto if it keeps
  happening).
- Re-opening the app (Dock, double-click in Applications) now brings up the
  window, as expected of a Mac app.

### Changed
- Switching models **frees the old one from memory** (verified: switching
  away from the 1.7B model releases ~1.6 GB). One model in RAM, never several.
- Footer and About now name the model you're actually using.

## v0.4.0 — Söyle becomes **Talkink**

Talk. Ink. New name, new home — same app, same privacy.

### Changed
- **Renamed to Talkink** (talk → ink: you speak, it writes). Website:
  **[talkink.app](https://talkink.app)**. Your settings, history and
  permissions carry over (the internal identifiers are unchanged).
- Update feed now served from talkink.app (legacy feed kept for old installs).
- Release assets are now `Talkink.dmg` / `Talkink.zip`.

### For existing users
- The app file becomes `Talkink.app` after the update. If push-to-talk stops
  responding, remove the old *Söyle* entries in System Settings → Privacy &
  Security (*Input Monitoring*, *Accessibility*) and add **Talkink** — one time.

## v0.3.3

First-real-user release — every change below comes from watching a
non-technical person install and use Söyle.

### Changed
- **First launch now asks which language you'll speak** (changeable anytime):
  an explicit language transcribes noticeably better than auto-detect.
- **bf16 model is the default** (best quality; ~1.2 GB one-time download) —
  8-bit stays available in Settings for maximum speed.
- **The DMG teaches the install**: branded background, "Drag into
  Applications" with the icons positioned around an arrow.
- Input Monitoring onboarding now leads with the “+” instruction (macOS 26
  never lists apps by itself).

## v0.3.2

### Fixed
- The app now reliably relaunches after an in-app update. Sparkle's installer
  agent proved flaky at relaunching an app updated in place (verified on
  macOS 26; upstream Sparkle #273/#1717): Söyle now spawns its own detached
  relauncher that waits for the old instance to exit and opens the updated
  app. Updater errors are also logged for diagnosis.

## v0.3.1

### Fixed
- Worked around a macOS 26 (Tahoe) issue — also hitting Karabiner-Elements and
  others — where answering the Input Monitoring prompt does not add the app to
  the list: Söyle now opens the right Settings pane **and** reveals Söyle.app
  in the Finder so you can drag it straight into the list; onboarding hints
  explain the manual add.

### Changed
- Downloads now ship as a **drag-to-Applications DMG** (notarized + stapled),
  alongside the zip used by the in-app updater.

## v0.3.0

### Distribution
- **Signed & notarized by Apple** (Developer ID, hardened runtime) — download,
  drag to Applications, open. No Gatekeeper warning, no `xattr`, no "Open
  Anyway". One-time permission re-grant when coming from v0.1.0/v0.2.0 (the
  signing identity changed — it is stable from now on).
- **In-app auto-updates via Sparkle 2.9.3** (replaces the GitHub release
  notifier): "Check for Updates…" in the menu, automatic-checks toggle in
  Settings, EdDSA-signed update feed.
- Release tooling: `scripts/notarize.sh` (submit → staple → Gatekeeper-assess
  → package) and `scripts/make_appcast.sh`; `build_app.sh` prefers a
  Developer ID identity, signs nested code individually (no `--deep`).

### Changed
- First run shows "Downloading model (~756 MB, one-time)…" in the menu and the
  pill while the weights download, instead of a silent wait.
- New `--mictest` headless mode (capture pipeline + entitlement check).

## v0.2.0

### Fixed
- The recording pill now appears attached to the window you're dictating into
  (focused window via Accessibility, window-list fallback — no new permission)
  instead of a fixed spot at the bottom of the primary screen. It used to land
  on whatever window sat behind when the active window was small, and on the
  wrong display on multi-screen setups. Fullscreen Spaces verified unaffected.
- The microphone can no longer be left recording: switching models mid-hold
  orphaned the recorder (mic stayed hot, the next dictation shipped minutes of
  background audio to the model). Every exit path now stops it.
- The end of the last word is no longer clipped — capture continues 0.25s
  after the key is released and the resampler's buffered tail is drained.
- Releasing the push-to-talk key while the other key of the same modifier was
  also held (e.g. both Options) no longer leaves the recording stuck on.
- Switching models while a load is in flight can no longer install stale
  weights or show Ready with the wrong model; stale transcription completions
  can't clobber a newer dictation's UI.

### Privacy
- Text dictated into a secure (password) field stays out of the on-disk
  history — clipboard only.

### Changed
- The pill says "Pasted" when auto-paste actually inserted at the cursor,
  "Copied" otherwise.
- Permission status is polled only while the Söyle window is open.
- Input Monitoring guidance reflects the in-session re-arm (relaunch is a
  fallback); README documents the permission re-grant needed after updating
  a non-notarized build.
- `soyle-cli` accepts multiple audio files in a single run (one model load).

## v0.1.0

First release. Local push-to-talk dictation for Apple Silicon, powered by NVIDIA
Nemotron 3.5 ASR via MLX — 100% native Swift, no Python at runtime.

### Features
- **Push-to-talk** global hotkey (listen-only `CGEventTap` + Input Monitoring): hold a
  key, speak, release → transcribe → paste. Default key: Right Option ⌥; rebindable.
- **Auto-paste at the cursor** (synthetic ⌘V via Accessibility), with the transcript
  always placed on the clipboard as a fallback. Toggleable.
- **History** — every transcription is saved locally (up to 500, at
  `~/Library/Application Support/Soyle/history.json`), searchable and re-copyable in-app.
- **Native Nemotron 3.5 ASR** engine on `mlx-audio-swift`, warmed up at launch for an
  instant first transcription. ~30–40× real time on a MacBook Air M4 (8-bit).
- Menu-bar app (no Dock icon) with a floating recording overlay (live waveform, NVIDIA green).
- Settings: push-to-talk key, language (auto + 9 locales), model (**8-bit** default / **bf16**),
  auto-paste, feedback sounds, launch at login, check-for-updates.
- Update notifier: checks GitHub Releases and surfaces a "new version available" notice.
- `soyle-cli` for headless transcription/benchmarking; `--selftest` mode.

### Robustness
- In-session re-arm of the push-to-talk tap once Input Monitoring is granted (no relaunch).
- Recovers from a mid-recording microphone unplug / device or route change.
- Retries the model load on next activation if the first attempt fails (e.g. offline).
- Serialized MLX inference; guards against sub-0.1s audio.
- Stress-tested: silence, 0.15s, 44.1 kHz stereo (resample+downmix), noise, 55s (chunked).

### Distribution
- Open source (MIT). **Not notarized** — download builds need a one-time
  `xattr -dr com.apple.quarantine`, or build from source. Notarization + Sparkle
  auto-update are on the roadmap.
