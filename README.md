# Murmur

System-wide push-to-talk dictation for macOS. Hold a key, talk, release — your
words land at the cursor in whatever app is focused, cleaned up and punctuated.

No accounts. No telemetry. No network at all when you use the local model.

---

## What it actually does

Hold the push-to-talk key anywhere in macOS and say:

> um so like the thing is we should probably ship this on friday i think uh
> because the client demo is monday

Release the key, and about a second later this appears at your cursor:

> We should probably ship this on Friday, because the client demo is Monday.

Two things happened there. Whisper turned the audio into text, and a second
pass — a small LLM with a dictation-specific prompt — removed the fillers, added
the punctuation, and fixed the casing. That second pass is what separates this
from the dictation built into your OS, and it is optional and configurable.

It works in Slack, Notes, a terminal, a browser text field, your editor —
anywhere a caret blinks. There is no per-app integration: insertion is a
synthetic ⌘V (or synthesized keystrokes) into whatever holds focus, so an app
that accepts typing accepts Murmur.

**Where it's different from the hosted dictation apps:**

- **It can run fully offline.** whisper.cpp transcribes locally; point cleanup
  at Ollama and the audio and the text both stay on the machine. No account, no
  subscription, no update checks, no analytics.
- **You own the cleanup prompt.** `cleanup.prompt` in a JSON file, not a vendor's
  hidden model behaviour. Swap providers or models per taste and latency budget.
- **It's ~2,400 lines of Swift you compile yourself.** No installer, no signed
  binary from a stranger — which is also why the permissions dance below is a
  step you have to do consciously.
- **It's multilingual by default and never translates.** Speak Spanish, get
  Spanish. Switch languages mid-sentence and both survive (with the right model
  — see the table further down).

**What you need:** macOS 13 or later, Homebrew, Xcode Command Line Tools, and
about 500 MB of disk for the speech model. Apple Silicon is much faster, but
Intel works. API keys are optional; without them you get raw transcripts.

**What it is not:** a real-time captioner, a meeting transcriber, or a voice
assistant. It is a key you hold to type with your mouth.

---

## How it works

```
hold fn ──▶ record mic ──▶ release ──▶ whisper ──▶ LLM cleanup ──▶ paste at cursor
            (pill shows)              (local or API)  (optional)   (clipboard restored)
```

1. A `CGEventTap` watches for your push-to-talk key being held.
2. `AVAudioEngine` records the mic, downmixed to 16 kHz mono WAV.
3. Transcription runs through **whisper.cpp locally**, or the **Groq / OpenAI**
   Whisper endpoint if you'd rather.
4. The raw transcript goes through a small LLM that strips filler words
   ("um", "uh", "like"), fixes punctuation, and matches casing to written style.
5. The result is pasted at the caret via the pasteboard + ⌘V, and your previous
   clipboard contents are put back.

---

## Install

### The one-command way

```bash
git clone https://github.com/cancilleriluis/murmur.git ~/Murmur
cd ~/Murmur && ./bootstrap.sh
```

`bootstrap.sh` checks your prerequisites, installs whisper.cpp, downloads the
~465 MB speech model, creates a stable signing identity (macOS will ask for your
login password — that's the keychain, nothing leaves the machine), then builds
and installs `Murmur.app`. Every step checks whether it's already done, so it's
safe to re-run after a failure.

Two things it deliberately leaves to you: granting the three permissions, and
adding API keys. Both are covered below.

### Let an AI agent do it

If you use Claude Code, Cursor, Codex, or any other agent with terminal access,
paste this and it will handle the clone, the install, the verification, and
walking you through the permission dialogs. Copy the whole block:

```text
Set up Murmur, a macOS push-to-talk dictation app, on this Mac.

1. Clone https://github.com/cancilleriluis/murmur into ~/Murmur. If it's
   already there, git pull instead of re-cloning.
2. Read ~/Murmur/README.md and ~/Murmur/bootstrap.sh, then tell me in a few
   lines what the script is about to do before you run it.
3. Run ./bootstrap.sh and show me the output as it goes. It installs
   whisper-cpp via Homebrew, downloads a ~465 MB model into
   ~/.config/murmur/models, creates a self-signed code-signing identity, and
   builds and installs Murmur.app. It will ask for my login password once, for
   the keychain.
4. Verify the install without touching the mic. Generate a test WAV:
     say -o /tmp/murmur-test.aiff "This is a test of the dictation pipeline"
     afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/murmur-test.aiff /tmp/murmur-test.wav
   then run:
     /Applications/Murmur.app/Contents/MacOS/Murmur --test-pipeline /tmp/murmur-test.wav
   Report which backend resolved, the transcript, and the per-stage timings.
5. Walk me through granting Microphone, Input Monitoring and Accessibility in
   System Settings > Privacy & Security, one at a time, waiting for me to
   confirm each. Then remind me to quit Murmur from the menu bar and reopen it
   — macOS only hands new permissions to a freshly launched process.
6. Ask me whether I want the optional LLM cleanup pass. If yes, open
   ~/.config/murmur/.env so I can paste in a GROQ_API_KEY or OPENAI_API_KEY
   myself. Do not echo the key back, do not put it in any other file, and never
   commit it.

Ask me before anything destructive — deleting an existing ~/.config/murmur,
or overwriting a config.json I already have.
```

**Chat-only tools** (ChatGPT, Claude, Gemini in the browser) can't run the
install, but they're good at the parts that go wrong. This one turns the docs
into a checklist for your specific machine:

```text
Read https://github.com/cancilleriluis/murmur and its README.

I'm on macOS <your version> with <Apple Silicon / Intel>. Give me a numbered
setup checklist for exactly my machine, including which speech model size you'd
recommend and whether I need API keys at all for what I want (I mostly dictate
in <your languages>). Then explain, in plain terms, what each of the three macOS
permissions is for and what breaks if I skip it.
```

And when something misbehaves, this saves a lot of guessing:

```text
Murmur (github.com/cancilleriluis/murmur) isn't working: <describe the symptom>.
Here is the tail of ~/.config/murmur/murmur.log:

<paste the log>

Here is ~/.config/murmur/config.json (I've removed anything private):

<paste the config>

Using the repo's README troubleshooting section, tell me which stage is failing
— hotkey capture, audio, transcription, cleanup, or insertion — and the single
next thing to try.
```

### Manual install

If you'd rather run the steps yourself, or you already have whisper.cpp:

```bash
git clone https://github.com/cancilleriluis/murmur.git ~/Murmur
cd ~/Murmur

# 1. Local transcription engine + model (~465 MB)
brew install whisper-cpp
mkdir -p ~/.config/murmur/models
curl -L -o ~/.config/murmur/models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# 2. Stable signing identity — do this BEFORE the first build so you grant
#    permissions once instead of after every rebuild
./setup-signing.sh

# 3. Build and install
./build.sh --install
```

`build.sh --install` compiles a release binary, wraps it in `Murmur.app`, signs
it, copies it to `/Applications`, and launches it. You'll get a waveform icon in
the menu bar. To build without installing, run `./build.sh` — the bundle lands
in `build/`.

Rebuilding later is just `./build.sh --install` again.

### Keys and settings are not in this repo

On first run the app creates `~/.config/murmur/.env` with empty placeholders.
Fill them in by hand, or copy the file across from another machine over
something private (AirDrop, a password manager, `scp`). Never commit it. Without
keys the app still works fully offline; you just don't get the LLM cleanup pass.

Settings live in `~/.config/murmur/config.json`, also outside the repo, so each
machine can have its own hotkey and provider. Copy that file too if you want
identical behaviour on both.

### Local transcription (offline)

```bash
brew install whisper-cpp
```

Then grab a model. `small` is the sweet spot for dictation on Apple Silicon;
`medium` is noticeably more accurate on proper nouns and accents but ~3× slower.

```bash
mkdir -p ~/.config/murmur/models
cd ~/.config/murmur/models

# small — ~466 MB, fast, good enough for most dictation
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# medium — ~1.5 GB, more accurate
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
```

Murmur auto-detects both `whisper-cli` and the model — no config needed. If
several models are present it picks the largest.

> English-only variants (`ggml-small.en.bin`) are a bit sharper if you only ever
> dictate in English.

### API transcription (optional)

Put keys in `~/.config/murmur/.env` (created for you on first run):

```dotenv
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

Groq's `whisper-large-v3-turbo` is dramatically faster than local `medium` and
usually more accurate. It is, of course, not offline.

---

## Permissions you must grant

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

> **Rebuilding resets permissions — and this is the single most confusing
> failure mode.** With ad-hoc signing the code signature changes on every
> rebuild, so macOS treats the new build as a different app. The checkbox in
> System Settings *stays enabled* while the app is actually denied, and the
> symptom is that transcription works but nothing is ever pasted — the log
> shows `accessibility=NOT GRANTED`.
>
> **Fix it permanently:**
> ```bash
> ./setup-signing.sh
> ```
> This creates one stable self-signed identity in your login keychain (macOS
> will ask for your password — that's the keychain prompt, nothing leaves your
> machine). `build.sh` picks it up automatically, and from then on permissions
> survive rebuilds. Grant them once more after the first signed build.
>
> Without it, after each `./build.sh --install` you must toggle Murmur off and
> on in each permission list — or remove it with `−` and re-add with `+`.

---

## Settings

`~/.config/murmur/config.json` — edit via **Edit Settings…**, then
**Reload Settings** (no restart needed).

```jsonc
{
  "hotkey": "fn",                    // fn | right_option | left_option |
                                     // right_command | right_control | right_shift …
  "transcription_backend": "auto",   // auto | local | groq | openai
  "whisper_cli_path": "",            // empty = autodetect
  "whisper_model_path": "",          // empty = autodetect from models/
  "language": "auto",                // "auto" detects; "es"/"en"/… pins it
  "languages": ["es","en","it","pt"],// languages you actually speak

  "history": {
    "enabled": true,
    "retention_hours": 24,           // older entries are pruned automatically
    "max_entries": 200
  },

  "cleanup": {
    "enabled": true,
    "provider": "auto",              // auto | groq | openai | anthropic | local
    "model": "",                     // empty = provider default
    "style": "auto",                 // auto | clean | structured (see below)
    "prompt": "",                    // empty = built-in dictation prompt
    "base_url": "",                  // empty = provider default; primary only
    "fallback_provider": "openai",   // retried when the primary fails
    "fallback_model": "gpt-4o"       // must not be a mini-tier model
  },

  "insertion": "paste",              // paste (⌘V at the caret)
                                     // clipboard (copy only, no keypress)
                                     // type (synthesize keystrokes)
  "restore_clipboard": true,
  "min_recording_seconds": 0.3,      // ignore accidental taps
  "play_sounds": false
}
```

**`transcription_backend: "auto"`** resolves in this order: local whisper.cpp
(if binary + model are present) → Groq → OpenAI. The menu bar shows which one
is actually live.

**Cleanup defaults** are small, fast models, because dictation is
latency-critical and de-umming is mechanical work: Groq `llama-3.3-70b-versatile`,
OpenAI `gpt-4o-mini`, Anthropic `claude-haiku-4-5-20251001`. Set
`cleanup.model` to `claude-sonnet-5` (or similar) if you want a stronger editor
and can eat the extra latency.

Cleanup is **fail-safe**: if the key is missing, the API errors, or the model
returns something suspiciously longer/shorter than the input (a sign it
*answered* your text instead of cleaning it), Murmur keeps the raw transcript
rather than losing what you said. That last guard is real — if you dictate
"we should ship on Friday" and the model helpfully replies with a rollout
checklist, Murmur throws the reply away and logs the reason.

### What it costs

Transcription is **free** — whisper.cpp runs locally, so the only thing that can
cost money is the optional LLM cleanup pass.

Measured against ~63 words per dictation (this project's own logged average) and
a ~340-token system prompt, **68,000 words/month ≈ 1,080 dictations**:

Measured end-to-end on real dictations — three cases (Spanish enumerating
points, Spanish plain prose, English), scoring structure, language fidelity, and
round-trip latency:

| Model | Latency | Per month | Verdict |
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
checks — each structured the enumerated case, left plain prose alone, and none
translated the English. But the whole price spread is about $1.40/month, while
the latency spread is 2 s versus 20 s. Twenty seconds staring at the pill after
releasing the key makes dictation unusable; a dollar a year does not. Pick on
speed.

Input dominates the bill because the system prompt is re-sent on every
dictation; the transcripts themselves are tiny. Bigger prompts cost more per
dictation, so keep `cleanup.prompt` short if you customize it. The prompt is
~340 tokens — below every provider's minimum cacheable prefix, so prompt
caching does not help here.

Sending audio to a hosted Whisper instead of running it locally would add
roughly $0.35/month (Groq) to $3/month (OpenAI) at this volume — the local
model makes that moot.

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

### Testing your setup

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --test-pipeline some.wav
```

Runs the real transcribe → cleanup path against a WAV file — no mic, no hotkey,
no clipboard — and prints which backend resolved, the raw transcript, the
cleaned text, and the timing of each stage. This is the fastest way to tell
whether a problem is in audio capture, transcription, or cleanup.

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

### History

Every dictation is saved to `~/.config/murmur/history.json` and pruned to the
last `retention_hours` (24 by default). From the **Historial** menu you can
click any recent entry to copy it back, open the full history as readable text,
or clear it. Nothing is uploaded — it's a local file.

### Text formatting

`cleanup.style` controls how much shaping the LLM applies:

| Value | Behaviour |
|---|---|
| `auto` (default) | Plain prose normally; when you clearly enumerate points, it adds a short title and numbers them |
| `clean` | Only removes fillers and fixes punctuation — never restructures |
| `structured` | Always produces a title plus a numbered list |

Switchable from the **Formato del texto** menu. In every mode the model is told
never to translate, never to add content, and never to answer the dictated
text.

### Choosing a hotkey

`fn` is the default and the nicest to hold, but note it also toggles the macOS
dictation/emoji panel depending on your keyboard settings. If that fights you,
set **System Settings ▸ Keyboard ▸ Press 🌐 to → Do Nothing**, or switch Murmur
to `right_option`.

---

## Menu bar

- **Dictation On/Off** — master switch, hotkey ignored when off
- **Push-to-Talk Key** — swap the hold key without editing JSON
- **AI Cleanup** — toggle LLM post-processing
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
`flags=…` lines for ⌘/⌥ but none for your hotkey, it's being intercepted.
Switch to another key from the menu.

Otherwise Input Monitoring isn't granted, or wasn't granted *before this
launch*. Run Check Permissions…, grant, then quit and reopen.

**It transcribes words I never said.**
Whisper invents speech from silence and room tone — this is a documented flaw in
the model, not a bug in Murmur. Three seconds of near-silence produced
*"[Locución de la Iglesia de Jesucristo de los Santos de los Últimos días]"* in
testing, and half a second of noise produced a Korean news headline.

Murmur defends against it in four layers, all on by default:

| Layer | Setting | What it stops |
|---|---|---|
| Duration floor | `min_recording_seconds` | Accidental taps |
| Silence gate | `min_peak_level`, `min_voiced_fraction` | A take that never reached speech level never reaches whisper |
| Language allowlist | `languages` | Noise detected as Korean/Chinese gets re-transcribed |
| Phrase filter | `filter_hallucinations` | Known stock hallucinations ("Gracias", "Thanks for watching", "you", subtitle credits) |

If real speech is being dropped, lower `min_peak_level` (try `0.15`). If silence
still produces text, raise it (try `0.30`). The log tells you which gate fired
and the measured peak, so tune against real numbers rather than guessing.

**Groq returns "Access denied. Please check your network settings."**
Groq blocks VPN and datacenter IPs on `/chat/completions` — the `/v1/models`
endpoint still answers, which makes it look like a key problem when it isn't.
No header or retry gets past it. This is handled automatically: see the fallback
chain below.

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
failure than not cleaning at all — you get fluent text that is not what you
said. Do not use a mini-tier model as the fallback.

**`"debug_hotkey": true`** logs every modifier event with its raw flag bits.
It's the fastest way to tell "no permission" apart from "another app stole the
key" apart from "wrong key configured".

**It records and transcribes, but no text appears.**
Accessibility isn't granted — that's the one that authorizes the ⌘V keystroke.
Check `~/.config/murmur/murmur.log` for the transcript to confirm it got that far.

**Text appears in the wrong app.**
Insertion goes to whatever holds focus on release. Don't click away while it's
transcribing.

**Some apps ignore the paste.** Switch `"insertion"` to `"type"`. Slower, but it
synthesizes real keystrokes and leaves the pasteboard alone entirely.

**The first transcription takes ~10 seconds, then it's fast.** That's
whisper.cpp compiling its Metal GPU shaders once and caching them. Measured on
an M4 with `small`: first run 13 s, every run after 0.85–1.1 s for 8 s of audio
(~9× real-time). Nothing to fix — just don't judge it on the first try.

**Local transcription is slow.** `medium` is ~3× slower than `small`. Drop down
a size, or point the backend at Groq.

**Logs:** `~/.config/murmur/murmur.log`, or **Show Log** in the menu.

---

## Privacy

- Local backend: audio never leaves the machine. Works with WiFi off.
- API backends: the WAV goes to Groq/OpenAI, and the transcript goes to your
  cleanup provider. Set `cleanup.enabled: false` and
  `transcription_backend: "local"` for a fully offline pipeline.
- Audio files are written to a temp dir and deleted immediately after
  transcription.
- No analytics, no crash reporting, no accounts, no update checks.

---

## Uninstall

```bash
pkill -x Murmur
rm -rf /Applications/Murmur.app ~/.config/murmur ~/Murmur
```

Then remove Murmur from the three Privacy & Security lists.
