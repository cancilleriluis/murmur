# Murmur

**System-wide push-to-talk dictation for macOS.** Hold a key, talk, release —
your words land at the cursor in whatever app is focused, cleaned up and
punctuated.

No accounts. No telemetry. No network at all when you run the local model.

```
hold fn ──▶ record mic ──▶ release ──▶ whisper ──▶ LLM cleanup ──▶ paste at cursor
            (pill shows)              (local or API)  (optional)   (clipboard restored)
```

- **Works offline.** whisper.cpp runs on your Mac; audio never leaves it.
- **Cleans as it types.** An optional LLM pass strips "um"/"eh"/"o sea", fixes
  punctuation and casing, and can organize spoken lists into numbered points.
- **Never translates.** Speak Spanish, get Spanish. Switch languages
  mid-sentence and both survive.
- **Menu-bar only.** No Dock icon, no window, no update checks.

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Manual install](#manual-install)
- [Permissions](#permissions)
- [Verify your setup](#verify-your-setup)
- [Which backend am I actually using?](#which-backend-am-i-actually-using)
- [Configuration](#configuration)
- [Speed and cost](#speed-and-cost)
- [Features in detail](#features-in-detail)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Uninstall](#uninstall)

---

## Requirements

| | |
|---|---|
| **OS** | macOS 13 Ventura or later |
| **Hardware** | Apple Silicon recommended (Intel works; local transcription is slower) |
| **Toolchain** | Xcode Command Line Tools — `xcode-select --install` |
| **Package manager** | [Homebrew](https://brew.sh) (for `whisper-cpp`) |
| **Disk** | ~500 MB for the default speech model |
| **API keys** | Optional. Only needed for hosted transcription or LLM cleanup. |

---

## Quick start

One command. It installs whisper.cpp, downloads the speech model, creates a
stable signing identity, builds the app, and installs it to `/Applications`.

```bash
git clone https://github.com/cancilleriluis/murmur.git ~/Murmur
cd ~/Murmur
./bootstrap.sh
```

Then [grant the three permissions](#permissions) and quit/reopen the app once.
That's it — hold **fn**, speak, release.

`bootstrap.sh` is safe to re-run: every step checks whether it's already done.

---

## Manual install

If you'd rather run the steps yourself:

```bash
git clone https://github.com/cancilleriluis/murmur.git ~/Murmur
cd ~/Murmur

# 1. Local transcription engine + model (~465 MB)
brew install whisper-cpp
mkdir -p ~/.config/murmur/models
curl -L -o ~/.config/murmur/models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# 2. Stable signing identity — run this BEFORE the first build, so you grant
#    permissions once instead of after every rebuild
./setup-signing.sh

# 3. Build and install
./build.sh --install
```

`./build.sh` alone builds into `build/` without installing. `--install` copies
the bundle to `/Applications` and launches it; you'll get a waveform icon in the
menu bar.

### Choosing a speech model

`small` is the sweet spot for dictation. `medium` is noticeably better on proper
nouns and accents but **~3× slower** — a real trade-off, not a free upgrade.

```bash
mkdir -p ~/.config/murmur/models && cd ~/.config/murmur/models

# small — ~466 MB, fast, good enough for most dictation
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# medium — ~1.5 GB, more accurate, slower
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
```

Murmur auto-detects both `whisper-cli` and the model — no config needed.

> **If several models are present, Murmur picks the largest.** Downloading
> `medium` "to try it" therefore makes every dictation slower until you delete
> it or pin `whisper_model_path` in the config.

> English-only variants (`ggml-small.en.bin`) are a bit sharper if you only ever
> dictate in English.

### API keys (optional)

On first run Murmur creates `~/.config/murmur/.env` with empty placeholders.
Fill in whichever you use:

```dotenv
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
XAI_API_KEY=xai-...
```

Keys are read from that file (or the process environment) and are never
committed — the file lives outside the repo, and `.gitignore` blocks `.env`
anyway. Without keys Murmur still works fully offline; you just don't get the
LLM cleanup pass.

Settings live in `~/.config/murmur/config.json`, also outside the repo, so each
machine keeps its own hotkey and provider.

---

## Permissions

macOS gates everything this app does. Open **System Settings ▸ Privacy &
Security** and enable Murmur under all three:

| Permission | Why Murmur needs it | Where |
|---|---|---|
| **Microphone** | To record your voice. | Privacy & Security ▸ Microphone |
| **Input Monitoring** | To detect the push-to-talk key being held *while another app is focused*. Without it the hotkey silently never fires. | Privacy & Security ▸ Input Monitoring |
| **Accessibility** | To post the synthetic ⌘V keystroke that inserts text into the focused app. Without it transcription works but nothing gets pasted. | Privacy & Security ▸ Accessibility |

**After granting any of these, quit and reopen Murmur.** macOS only hands the
new permission to a freshly launched process — this trips up everyone once.

Use **Check Permissions…** in the menu bar to see the live status of all three.

> **Rebuilding resets permissions — the single most confusing failure mode.**
> With ad-hoc signing the code signature changes on every rebuild, so macOS
> treats the new build as a different app. The checkbox in System Settings
> *stays enabled* while the app is actually denied, and the symptom is that
> transcription works but nothing is ever pasted — the log shows
> `accessibility=NOT GRANTED`.
>
> **Fix it permanently:**
> ```bash
> ./setup-signing.sh
> ```
> This creates one stable self-signed identity in your login keychain (macOS
> will ask for your password — that's the keychain prompt, nothing leaves your
> machine). `build.sh` picks it up automatically, and from then on permissions
> survive rebuilds. Grant them once more after the first signed build.

---

## Verify your setup

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --test-pipeline some.wav
```

Runs the real transcribe → cleanup path against a WAV file — no mic, no hotkey,
no clipboard — and prints which backend resolved, the raw transcript, the
cleaned text, and **the timing of each stage**:

```
backend      : auto
whisper-cli  : /opt/homebrew/bin/whisper-cli
model        : /Users/you/.config/murmur/models/ggml-small.bin
cleanup      : groq
---
RAW      (0.94s): eh bueno lo que quería decir es que...
CLEANED  (0.41s): Lo que quería decir es que...
```

This is the fastest way to tell whether a problem is in audio capture,
transcription, or cleanup — and the fastest way to see where your latency
actually goes.

---

## Which backend am I actually using?

Murmur has **two independent stages**, each with its own backend. They are
configured separately, and it's easy to assume one is hosted when it isn't.

| Stage | Setting | Default resolution |
|---|---|---|
| Transcription (audio → text) | `transcription_backend` | `auto` → **local whisper.cpp if installed** → Groq → OpenAI |
| Cleanup (text → text) | `cleanup.provider` | `auto` → Groq → OpenAI → Anthropic → xAI (first one with a key) |

> **The most common surprise:** with `transcription_backend: "auto"`, a local
> `whisper-cli` plus any model in `~/.config/murmur/models/` **always wins over
> Groq** — your `GROQ_API_KEY` is never used for audio. Since the setup above
> installs both, the default install transcribes locally even with Groq keys
> present. If you want Groq to handle audio, you must say so explicitly.

Three ways to check what's live:

1. **Menu bar.** The status line under the on/off toggle names the transcription
   backend directly: `Local whisper.cpp (auto)`, `Groq API (auto)`, or
   `⚠︎ No backend configured`.
2. **`--test-pipeline`** (above) prints both stages and their timings.
3. **The log** — `~/.config/murmur/murmur.log`, or **Show Log** in the menu.
   Every dictation records the backend, the provider, and per-stage timing:

   ```
   recorded 6.20s (peak 0.51, voiced 38%) — transcribing…
   transcribed in 0.87s via local whisper.cpp (ggml-small.bin) [es] (142 chars): …
   cleanup via groq/llama-3.3-70b-versatile
   cleanup 0.42s — 1.29s total from key release
   ```

   ```bash
   grep -E 'transcribed in|cleanup ' ~/.config/murmur/murmur.log | tail -20
   ```

### Forcing Groq for both stages

```jsonc
{
  "transcription_backend": "groq",
  "cleanup": { "provider": "groq" }
}
```

Then **Reload Settings** from the menu. Expect roughly 0.3–0.6 s per stage on
short clips — two sequential HTTP round trips, so budget under a second
end-to-end plus your own network latency.

Bear in mind what you trade away: audio now leaves your machine, and Groq
returns `Access denied. Please check your network settings.` from VPN and
datacenter IPs (see [the fallback chain](#the-fallback-chain)). Local whisper is
often the better default — `small` on an M-series Mac runs ~9× real-time.

---

## Configuration

`~/.config/murmur/config.json` — edit via **Edit Settings…**, then
**Reload Settings** (no restart needed).

```jsonc
{
  "hotkey": "fn",                    // fn | right_option | left_option |
                                     // right_command | right_control | right_shift …
  "transcription_backend": "auto",   // auto | local | groq | openai
  "whisper_cli_path": "",            // empty = autodetect
  "whisper_model_path": "",          // empty = autodetect from models/ (largest wins)
  "language": "auto",                // "auto" detects; "es"/"en"/… pins it
  "languages": ["es","en","it","pt"],// languages you actually speak

  "history": {
    "enabled": true,
    "retention_hours": 24,           // older entries are pruned automatically
    "max_entries": 200
  },

  "cleanup": {
    "enabled": true,
    "provider": "auto",              // auto | groq | openai | anthropic | xai | local
    "model": "",                     // empty = provider default
    "style": "auto",                 // auto | clean | structured
    "prompt": "",                    // empty = built-in dictation prompt
    "base_url": "",                  // empty = provider default; primary only
    "fallback_provider": "openai",   // retried when the primary fails
    "fallback_model": "gpt-4o"       // must not be a mini-tier model
  },

  "insertion": "paste",              // paste (⌘V at the caret)
                                     // clipboard (copy only, no keypress)
                                     // type (synthesize keystrokes)
  "restore_clipboard": true,
  "keep_in_clipboard": true,         // takes precedence over restore_clipboard
  "min_recording_seconds": 0.3,      // ignore accidental taps
  "min_peak_level": 0.22,            // silence gate — see Troubleshooting
  "min_voiced_fraction": 0.06,
  "filter_hallucinations": true,
  "play_sounds": false,
  "debug_hotkey": false
}
```

**Cleanup defaults** are fast models, because dictation is latency-critical and
de-umming is mechanical work: Groq `llama-3.3-70b-versatile`, OpenAI
`gpt-4o-mini`, Anthropic `claude-haiku-4-5`, xAI `grok-4.3`. Set `cleanup.model`
to something stronger if you want a better editor and can eat the extra latency.

Cleanup is **fail-safe**: if the key is missing, the API errors, or the model
returns something suspiciously longer/shorter than the input (a sign it
*answered* your text instead of cleaning it), Murmur keeps the raw transcript
rather than losing what you said. That last guard is real — if you dictate
"we should ship on Friday" and the model helpfully replies with a rollout
checklist, Murmur throws the reply away and logs the reason.

---

## Speed and cost

Transcription is **free** when it runs locally, so the only thing that can cost
money is the optional cleanup pass.

### Cleanup latency and price

Measured end-to-end on real dictations — three cases (Spanish enumerating
points, Spanish plain prose, English), scoring structure, language fidelity, and
round-trip latency. Prices assume ~63 words per dictation and a ~340-token
system prompt, at **68,000 words/month ≈ 1,080 dictations**.

> **These numbers are the cleanup stage only** — one HTTP round trip. They are
> *not* end-to-end dictation latency; add transcription (see below) and paste.

| Model | Cleanup latency | Per month | Verdict |
|---|---|---|---|
| **groq llama-3.3-70b** | **0.4 s** | **$0.28** | Default. Passed all three checks, 4× faster than anything else |
| gpt-4o-mini | 1.5 s | $0.08 | Cheapest that passes; solid fallback |
| groq llama-3.1-8b | 0.5 s | $0.03 | ❌ **Invented a third point that was never spoken** — disqualified |
| groq gpt-oss-20b | 1.5 s | $0.56 | Correct, but burns ~950 hidden reasoning tokens per dictation |
| claude-haiku-4-5 | 2.1 s | $0.89 | Best titles; equally good |
| grok-4.3 | 5.8 s | $0.91 | Correct, slow |
| grok-4.6 | 19.7 s | $1.49 | Slowest *and* priciest — avoid for dictation |
| Ollama / cleanup off | — | **$0** | — |

The `llama-3.1-8b` result is why this table exists: it is the cheapest and
nearly the fastest option, and it silently fabricated a point the speaker never
made. The length-ratio guard did not catch it (ratio 1.9, well inside the
limit). Benchmark before trusting a small model with this task.

**Latency decides this, not price.** Every model above passed all three quality
checks. The whole price spread is about $1.40/month, while the latency spread is
2 s versus 20 s. Twenty seconds staring at the pill after releasing the key makes
dictation unusable; a dollar a year does not. Pick on speed.

Input dominates the bill because the system prompt is re-sent on every
dictation; the transcripts themselves are tiny. Keep `cleanup.prompt` short if
you customize it. At ~340 tokens the prompt is below every provider's minimum
cacheable prefix, so prompt caching does not help here.

### Transcription latency

| Backend | Typical | Notes |
|---|---|---|
| local `small` | 0.85–1.1 s for 8 s of audio (~9× real-time) | Measured on an M4. **First run after a rebuild takes ~13 s** while Metal shaders compile and cache. |
| local `medium` | ~3× slower than `small` | More accurate on proper nouns and accents |
| Groq `whisper-large-v3-turbo` | ~0.3–0.6 s | Network-dependent; refuses VPN/datacenter IPs |
| OpenAI `whisper-1` | ~1–2 s | |

Hosted transcription at the volume above would add roughly $0.35/month (Groq) to
$3/month (OpenAI).

> **Two things quietly double transcription time.** A `medium` model picked up
> automatically because it's sitting in `models/`, and the language-retry path:
> with `language: "auto"`, a clip detected as a language outside `languages` is
> transcribed a *second* time in `languages[0]`. The log names both when they
> happen.

---

## Features in detail

### The fallback chain

Cleanup tries the primary provider, and on any failure retries once with
`fallback_provider` before giving up and returning the raw transcript. The log
records which one served each dictation.

This exists because Groq is both the fastest option and the one that refuses VPN
IPs: without it, toggling a VPN silently drops you back to unstructured raw text
with no visible error. With it, Groq serves you at 0.4 s when the VPN is off and
gpt-4o serves you at ~2.5 s when it's on, with no configuration change.

`base_url` applies to the **primary provider only** — the fallback always uses
its own host, since pointing it at the primary's unreachable host would just
fail the same way.

> If dictation suddenly feels sluggish, check the log for
> `cleanup fell back to openai/gpt-4o`. A failing primary costs you the failed
> attempt *plus* the slower fallback.

### Fully offline cleanup with Ollama

`base_url` points at any OpenAI-compatible server, so the cleanup stage can run
locally too — combined with local whisper.cpp, nothing ever leaves the machine:

```bash
brew install ollama && ollama serve
ollama pull llama3.2
```

```jsonc
"cleanup": {
  "enabled": true,
  "provider": "local",
  "model": "llama3.2",
  "base_url": "http://localhost:11434/v1"
}
```

The same field works for LM Studio, llama.cpp's server, or any proxy.

### Languages

`language: "auto"` transcribes in whatever language you speak — Spanish stays
Spanish, English stays English. Nothing is ever translated, at either stage.

`languages` is a safety net rather than a restriction. Whisper's detector is
unreliable on short or noisy clips and will happily label half a second of room
tone as Korean; when the detected language isn't one you listed, Murmur logs it
and re-transcribes in `languages[0]` instead of handing you nonsense.

Verified: English audio → English text, Italian audio → Italian text, and with
`en` removed from the list, English is caught and retried
(`detected 'en' outside ["es","it"] — retrying as 'es'`).

### Text formatting

`cleanup.style` controls how much shaping the LLM applies:

| Value | Behaviour |
|---|---|
| `auto` (default) | Plain prose normally; when you clearly enumerate points, it adds a short title and numbers them |
| `clean` | Only removes fillers and fixes punctuation — never restructures |
| `structured` | Always produces a title plus a numbered list |

Switchable from the **Formato del texto** menu. In every mode the model is told
never to translate, never to add content, and never to answer the dictated text.

### History

Every dictation is saved to `~/.config/murmur/history.json` and pruned to the
last `retention_hours` (24 by default). From the **Historial** menu you can click
any recent entry to copy it back, open the full history as readable text, or
clear it. Nothing is uploaded — it's a local file.

### Choosing a hotkey

`fn` is the default and the nicest to hold, but it also toggles the macOS
dictation/emoji panel depending on your keyboard settings. If that fights you,
set **System Settings ▸ Keyboard ▸ Press 🌐 to → Do Nothing**, or switch Murmur
to `right_option`.

### Menu bar

- **Dictation On/Off** — master switch, hotkey ignored when off
- **Backend status line** — which transcription backend is actually live
- **Push-to-Talk Key** — swap the hold key without editing JSON
- **Al terminar…** — paste at the caret, copy only, or synthesize keystrokes
- **AI Cleanup** / **Formato del texto** — toggle and shape post-processing
- **Historial** — recent dictations, click to re-copy
- **Launch at Login** — registers via `SMAppService`
- **Edit Settings… / Reload Settings / Show Log**
- **Check Permissions…** — live status of all three grants

The icon changes while recording, so you always know if it's hot.

---

## Troubleshooting

**Nothing happens when I hold the key.**
First check whether *another app already owns that key*. Wispr Flow, Raycast and
similar tools grab `fn` globally and consume it, so it never reaches Murmur —
every other modifier arrives fine, `fn` alone stays silent. Set
`"debug_hotkey": true`, press the key, and read `murmur.log`: if you see
`flags=…` lines for ⌘/⌥ but none for your hotkey, it's being intercepted. Switch
to another key from the menu.

Otherwise Input Monitoring isn't granted, or wasn't granted *before this launch*.
Run Check Permissions…, grant, then quit and reopen.

**Dictation feels slow.**
Read the log — every dictation now records where the time went:

```bash
grep -E 'transcribed in|cleanup ' ~/.config/murmur/murmur.log | tail -20
```

Then work through, in order of how often it's the cause:

| What the log shows | Cause | Fix |
|---|---|---|
| `via local whisper.cpp (ggml-medium.bin)` | `medium` auto-selected because it's in `models/` | Delete it, or pin `whisper_model_path` to `small` |
| `via local whisper.cpp …` but you expected Groq | `auto` prefers local whenever whisper.cpp is installed | Set `"transcription_backend": "groq"` |
| `cleanup fell back to openai/gpt-4o` | Groq rejected the call (usually a VPN) | Turn the VPN off, or accept the slower fallback |
| `detected 'xx' outside […] — retrying` | Language retry ran the model twice | Pin `language` to your usual one |
| One slow run, then fast | Metal shader compile, cached after | Nothing to fix |

**The first transcription takes ~10 seconds, then it's fast.** That's
whisper.cpp compiling its Metal GPU shaders once and caching them. Measured on
an M4 with `small`: first run 13 s, every run after 0.85–1.1 s for 8 s of audio.
Don't judge it on the first try.

**Groq returns "Access denied. Please check your network settings."**
Groq blocks VPN and datacenter IPs on `/chat/completions` — the `/v1/models`
endpoint still answers, which makes it look like a key problem when it isn't. No
header or retry gets past it. This is handled automatically by
[the fallback chain](#the-fallback-chain).

**It transcribes words I never said.**
Whisper invents speech from silence and room tone — a documented flaw in the
model, not a bug in Murmur. Three seconds of near-silence produced *"[Locución de
la Iglesia de Jesucristo de los Santos de los Últimos días]"* in testing, and
half a second of noise produced a Korean news headline.

Murmur defends against it in four layers, all on by default:

| Layer | Setting | What it stops |
|---|---|---|
| Duration floor | `min_recording_seconds` | Accidental taps |
| Silence gate | `min_peak_level`, `min_voiced_fraction` | A take that never reached speech level never reaches whisper |
| Language allowlist | `languages` | Noise detected as Korean/Chinese gets re-transcribed |
| Phrase filter | `filter_hallucinations` | Known stock hallucinations ("Gracias", "Thanks for watching", "you", subtitle credits) |

If real speech is being dropped, lower `min_peak_level` (try `0.15`). If silence
still produces text, raise it (try `0.30`). The log names which gate fired and
the measured peak, so tune against real numbers rather than guessing.

**Mid-sentence language switching, and why the fallback model is `gpt-4o`.**
If you switch languages mid-dictation ("…esto es lo que hago. Because I have to
be on a website from the United States…"), model choice stops being cosmetic.
Measured on exactly that transcript:

| Model | Kept both languages |
|---|---|
| groq llama-3.3-70b | ✅ |
| gpt-4o | ✅ |
| grok-4.3 | ✅ |
| gpt-4o-mini | ❌ translated the English into Spanish |
| gpt-4.1-mini | ❌ translated the English into Spanish |

The "mini" tier silently rewrites the foreign-language span, which is a worse
failure than not cleaning at all — you get fluent text that is not what you said.
Do not use a mini-tier model as the fallback.

**It records and transcribes, but no text appears.**
Accessibility isn't granted — that's the one that authorizes the ⌘V keystroke.
Check `~/.config/murmur/murmur.log` for the transcript to confirm it got that far.

**Text appears in the wrong app.**
Insertion goes to whatever holds focus on release. Don't click away while it's
transcribing.

**Some apps ignore the paste.** Switch `"insertion"` to `"type"`. Slower, but it
synthesizes real keystrokes and leaves the pasteboard alone entirely.

**Logs:** `~/.config/murmur/murmur.log`, or **Show Log** in the menu.

---

## Privacy

- **Local backend:** audio never leaves the machine. Works with WiFi off.
- **API backends:** the WAV goes to Groq/OpenAI, and the transcript goes to your
  cleanup provider. For a fully offline pipeline set
  `"transcription_backend": "local"` and either `"cleanup": {"enabled": false}`
  or [a local cleanup server](#fully-offline-cleanup-with-ollama).
- Audio files are written to a temp dir and deleted immediately after
  transcription.
- History is a plain local file you can clear from the menu.
- No analytics, no crash reporting, no accounts, no update checks.

---

## Uninstall

```bash
pkill -x Murmur
rm -rf /Applications/Murmur.app ~/.config/murmur ~/Murmur
```

Then remove Murmur from the three Privacy & Security lists.
