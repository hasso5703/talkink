<div align="center">

<img src="assets/hero.png" alt="Talkink, Say it. It's written." width="880"/>

# Talkink

Push-to-talk dictation for macOS, **100% on-device**. Hold a key, speak, release,
your text is transcribed locally and pasted right at your cursor. Pick your engine:
**Qwen3-ASR**, **NVIDIA Nemotron 3.5** or **Voxtral Mini**: all running via **MLX**.

![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black)
![License](https://img.shields.io/badge/license-MIT-76B900)

### 🌐 **[talkink.app](https://talkink.app)**: website & one-click download

<br/>

<img src="assets/demo.gif" alt="Dictating into Claude Code with Talkink: hold Right Option, speak, and the text is pasted at the cursor" width="760"/>

</div>

---

## Why Talkink

- 🔒 **Local & private**: your voice and text never leave your Mac. No cloud, no subscription.
- ⚡ **Fast**: your words land in about a second; the lightest models run 30–40× faster than real time on a MacBook Air M4.
- 🌍 **Multilingual**: 27 languages, picked once or auto-detected. Punctuation & capitalization included.
- ⌨️ **Paste anywhere**: auto-pastes at the cursor; always on the clipboard as a fallback.
- 📖 **Your vocabulary**: teach it your names and jargon (“Talkink”, “PostgreSQL”), fixed on-device right after transcription.
- 🙌 **Hands-free**: double-tap the key to keep recording, tap once to stop. Scriptable via `talkink://` URLs.
- 📜 **History & stats**: every transcription kept locally, searchable, with your words-per-minute.
- 🛟 **Nothing fails silently**: a visible error journal and one-click problem reports (never your transcripts).
- 🟢 **Open source** (MIT), 100% native Swift, no Python at runtime.

## How it works

1. Talkink lives in the menu bar (no Dock icon).
2. **Hold** the push-to-talk key (Right Option ⌥ by default) → recording starts.
   Prefer not to hold? **Double-tap** the key, recording locks on until you tap again.
3. **Speak.**
4. **Release** → local transcription in about a second → text is **pasted at your cursor** (if Accessibility is granted) and **copied to the clipboard**.
5. It's also saved to **History** in case you need it again.

A floating pill (NVIDIA green) shows the state: recording → transcribing → done.

## Screenshots

<p align="center">
  <img src="assets/screenshot-settings.png" width="380" alt="Settings & permissions"/>
  &nbsp;&nbsp;
  <img src="assets/screenshot-menu.png" width="300" alt="Menu bar"/>
</p>

<p align="center"><i>The recording pill, reacting to your voice:</i></p>
<p align="center"><img src="assets/pill.gif" width="420" alt="Recording pill"/></p>

## Install

**Requirements:** Apple Silicon Mac (M1–M5), macOS 14 or later.

### 1. Download & install

1. Download **`Talkink.dmg`** from the [**latest release**](https://github.com/hasso5703/talkink/releases/latest).
2. Open it and drag **Talkink** onto the **Applications** folder, then eject the disk image.
3. Launch Talkink from Applications. No security warning, Talkink is **signed and
   notarized by Apple** (since v0.3.0).

Or, with [Homebrew](https://brew.sh):

```bash
brew install --cask hasso5703/tap/talkink
```

> Homebrew 6+ asks you to trust third-party taps first:
> `brew trust hasso5703/tap`, then install.

> <a name="is-it-safe"></a>**Is it safe?** Yes, twice over: the download is notarized by Apple
> (scanned and ticketed), *and* Talkink is fully open source, you can read every line in this
> repo and [build it yourself](BUILDING.md).

> **Coming from Söyle (Talkink's former name, ≤ v0.3.3)?** Your settings and history carry
> over automatically. If push-to-talk stops responding, remove the old **Söyle** entry from
> System Settings → Privacy & Security → *Accessibility* (− button), then switch
> **Talkink** on, one time.

### 2. Grant permissions (the onboarding window guides you)

Two, and the onboarding flips them on with you, no “+” and no dragging:

| Permission | Why |
|---|---|
| **Microphone** | To hear you |
| **Accessibility** | Detect your push-to-talk key in any app, and paste the text at your cursor |

Talkink uses Accessibility (not Input Monitoring) for the key, so it appears in the list automatically: you just switch it on, and the grant is picked up live, with no quitting and reopening.

### 3. Use it

On the **first** transcription, Talkink downloads the model once (~2.5 GB for the
recommended Qwen3-ASR 1.7B) with a live progress bar, interrupted downloads resume where
they stopped. After that: **hold Right Option ⌥, speak, release** → your text appears at
the cursor and on the clipboard. That's it. 🎤

---

### Build from source (developers)

```bash
git clone https://github.com/hasso5703/talkink.git
cd talkink
scripts/build_app.sh Release
open dist/Talkink.app
```

Requires **full Xcode 16+** (the Metal compiler is needed, see [BUILDING.md](BUILDING.md)).
A locally built app is signed with your own (or an ad-hoc) identity and runs directly.

## Settings

Menu bar → **Open Talkink** → *Settings* tab:

- **Push-to-talk key**: Right Option (default), Left Option, Right Control, or Fn / 🌐.
  **Double-tap for hands-free** (on by default) locks recording until the next tap.
- **Language**: Auto (detect) or one of 27 languages.
- **Vocabulary**: your names and jargon, written your way, with the forms they get
  misheard as. Applied on-device after every transcription; real words are never touched.
- **Model**: a catalog of seven (Qwen3-ASR 1.7B & 0.6B, NVIDIA Nemotron 3.5, Voxtral
  Mini 4B; 8-bit / bf16 / 4-bit variants) with real size, quality and speed ratings.
  Download several, switch instantly, delete what you don't use.
- **Auto-paste at cursor**, feedback sounds, launch at login, check for updates,
  URL automation (off by default).
- **Support**: recent issues at a glance and a one-click, fully transparent
  **Report a Problem** (environment + error journal; never your transcripts).

## Automation

With **Allow URL automation** enabled (Settings → Behaviour), Raycast, Alfred,
Apple Shortcuts or any terminal can drive dictation:

```bash
open "talkink://toggle"      # start hands-free dictation / stop & paste
open "talkink://record"      # start (no-op while already recording)
open "talkink://stop"        # stop & paste
open "talkink://history"     # open the window on History
open "talkink://settings"    # open Settings
open "talkink://report"      # open a problem report
```

Dictation commands are **off by default**: any app could open a URL, and
starting the microphone stays your explicit choice. Window commands always
work. URL-started dictation is hands-free: tap your key (or `talkink://stop`)
to finish.

## Network activity

Talkink's transcription is 100% on-device. The only network calls are:

1. **First-run model download** (~2.5 GB for the recommended Qwen3-ASR 1.7B; other catalog options range from 760 MB to 4.1 GB) from Hugging Face into `~/.cache/huggingface`. Downloads are resumable, quit anytime, it continues where it stopped.
2. **Update check** (optional, toggle in Settings), Sparkle fetches `https://talkink.app/appcast.xml`. No usage telemetry is sent, there is nothing to send it to.

**Verify it yourself**: while dictating, list the app's open connections:

```bash
lsof -i -a -p "$(pgrep -x Soyle)"    # no output = no connections
```

Block both endpoints (`huggingface.co`, `talkink.app`) in `/etc/hosts` and
dictation keeps working, the models live on your disk. Problem reports open
as a GitHub issue you review first; nothing ever leaves your Mac on its own.

## Troubleshooting

- **Push-to-talk does nothing** → grant **Accessibility** (System Settings → Privacy & Security → Accessibility) and switch Talkink on. It re-arms itself within a few seconds; relaunch it if the key still does nothing.
- **After updating from an old version (Söyle ≤ v0.2.0), the key/auto-paste stopped working** (toggles look on but do nothing) → macOS ties permissions to the app's code signature, and early builds were signed differently. In System Settings → Privacy & Security, **remove** the old *Söyle* entry from *Accessibility* (− button), then switch **Talkink** on. One time, the identity has been stable since v0.3.0.
- **It stopped working after rebuilding from source** → ad-hoc signatures change each build; run `scripts/dev_sign_setup.sh` once to create a stable local signing identity so grants persist.
- **Using Fn / 🌐 as the key** → set System Settings → Keyboard → "Press 🌐 to" = **Do Nothing**.
- **Model download stalls** → check your connection and `~/.cache/huggingface`.

## Tech stack & credits

| Component | Role | License |
|---|---|---|
| [Qwen3-ASR](https://huggingface.co/Qwen) | Default model (1.7B / 0.6B, 30 languages) | Apache 2.0 |
| [NVIDIA Nemotron 3.5 ASR](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | Lightest/fastest option (cache-aware FastConformer-RNNT, 600M) | NVIDIA model license (OpenMDW-1.1), see model card |
| [Voxtral Mini](https://huggingface.co/mistralai) | Alternative engine (4B, 13 languages, auto-detect) | Apache 2.0 |
| [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | Native Swift/MLX STT implementations (Prince Canuma) | MIT |
| [mlx-community](https://huggingface.co/mlx-community) | MLX-converted weights (8-bit / bf16 / 4-bit) | per model license |
| [MLX](https://github.com/ml-explore/mlx-swift) | Compute on Apple Silicon (Apple) | MIT |

**Each downloaded model is governed by its own license** (see the model cards). By using Talkink you agree to the license of the model(s) you download.

## Roadmap

- [ ] Live text while you speak (streaming `generateStream`)
- [x] Notarized + [Sparkle](https://sparkle-project.org) in-app auto-update (v0.3.0)
- [x] Homebrew install via [our tap](https://github.com/hasso5703/homebrew-tap) (v0.5.0), homebrew-cask once notable enough
- [x] Custom dictionary (proper nouns, jargon), Settings → Vocabulary
- [x] Hands-free, double-tap the push-to-talk key, tap to stop

## License

Talkink's code is [MIT](LICENSE). See the table above for component and model licenses.
