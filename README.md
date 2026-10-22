# VoZ

<img src="Resources/AppIcon.png" width="96" alt="VoZ icon">

*Formerly Murmur.* The app is now called VoZ; the repository, the
`~/.config/murmur` settings folder and the bundle ID (`com.murmur.dictation`,
which your macOS permissions are tied to) keep the old name.

System-wide push-to-talk dictation for macOS. Hold a key, talk, release — your
words land at the cursor in whatever app is focused, cleaned up and punctuated.

No accounts. No telemetry. No network at all when you use the local model.

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

## Setting up on another Mac

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

Then grant Microphone, Accessibility, and Input Monitoring (see below), and
quit/reopen the app once.

**Your API keys are deliberately not in this repo.** On first run the app
creates `~/.config/murmur/.env` with empty placeholders — fill them in by hand
on the new machine, or copy the file across over something private (AirDrop, a
password manager, `scp`). Never commit it. Without keys the app still works
fully offline; you just don't get the LLM cleanup pass.

Settings live in `~/.config/murmur/config.json` and are also not in the repo, so
each machine can have its own hotkey and provider. Copy that file too if you
want identical behaviour on both.

## Everyday use

| Do this | What happens |
|---|---|
| **Hold the key**, talk, release | Text is cleaned and pasted where the cursor is |
| **Double-tap the key** | Hands-free: keeps recording until you tap once more (a small dot shows in the pill) |
| Select text, **hold the key + ⇧**, say an instruction | Command mode: "más formal", "tradúcelo al inglés", "hazlo una lista", "más corto"… rewrites the selection in place (needs a cleanup API key) |
| Menu ▸ **Deshacer último dictado** | ⌘Z in the app you dictated into |
| Menu ▸ **Pegar otra vez el último dictado** | Re-inserts it, e.g. after it landed in the wrong field |
| Menu ▸ **Ajustes…** | Settings window: key, model, cleanup, vocabulary, hands-free, command mode |

**Formatting follows the app you're in.** Code editors and terminals get exactly
what you said (no AI rewrite); Slack, WhatsApp, Telegram and Messages get a
casual chat message; Mail and Outlook get email paragraphs; Notion, Notes and
Obsidian may organize enumerated points into a title + list. Everything else
uses the default format. Edit `app_styles` in the JSON to change the mapping
(bundle IDs; a key ending in `*` matches a prefix; styles `auto`, `clean`,
`structured`, `casual`, `email`, `raw`).

**Vocabulary.** Names and terms in `vocabulary` (editable in Ajustes) are given
to whisper as its prompt and to the cleanup model as a spelling list, so
"Zentio" stops coming back as "sentio".

**Short phrases skip the AI.** Under `cleanup.min_words` (8) words, whisper's own
punctuation is kept and only filler words are dropped — no network round trip.

**Live transcription.** Long dictations are transcribed in pieces at your pauses
while you talk, so on release only the last few seconds are left. If any piece
fails, the whole recording is transcribed as before. `live_transcription: false`
turns it off.

**Better model.** Menu ▸ Modelo de voz ▸ *Descargar large-v3-turbo* fetches the
5-bit large-v3-turbo (~550 MB) and switches to it: noticeably better on accents,
names and mixed Spanish/English. Switch back to `small` from the same menu if
the `timing:` lines in the log show it's too slow on your Mac.

## Updating

Once installed, Murmur updates itself from its menu: it checks GitHub's `main`
at launch and every 6 hours, and when there is something new the menu shows
**⬆︎ Actualizar VoZ (N cambios)…**. Clicking it pulls `main` into the
checkout the app was built from and runs `./build.sh --install` (1–2 minutes);
Murmur quits and reopens on the new version. **Buscar actualizaciones…** checks
on demand. Output goes to `~/.config/murmur/update.log`.

It rebuilds on your Mac rather than downloading a binary, so the app keeps your
own signing identity. Run `./setup-signing.sh` once, or every update will need
Accessibility granted again.

A build made before this feature existed has no updater; update it once by hand:

```bash
cd ~/Murmur && git checkout main && git pull && ./build.sh --install
```

## Install (same machine)

```bash
cd ~/Murmur
./build.sh --install
```

That compiles a release binary, wraps it in `Murmur.app`, ad-hoc signs it,
copies it to `/Applications`, and launches it. You'll get a waveform icon in
the menu bar.

To build without installing, run `./build.sh` — the bundle lands in `build/`.

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

Murmur auto-detects both `whisper-cli` and the model — no config needed. Any
`ggml-*.bin` in that directory counts, including `large-v3`, quantized `-q5_1`
builds and `distil-` builds; if several are present it picks the largest, and
ignores anything under 1 MB so a half-finished download never wins. Set
`whisper_model_path` to a file to pin one, or to a directory to search there
instead.

`whisper-cli` is looked for in the Homebrew prefixes (Apple Silicon and Intel),
MacPorts, `~/.local/bin`, and `$PATH`, under each of the names the formula has
used (`whisper-cli`, `whisper-cpp`, `whisper`). Run `--doctor` to see which one
it resolved — a miss here is otherwise invisible, and pushes every dictation
onto a hosted API.

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
  "whisper_server": true,            // keep the model loaded (see Speed below)
  "whisper_server_port": 8178,
  "whisper_threads": 0,              // 0 = performance cores only
  "whisper_beam_size": 1,            // 1 = greedy/fast; 5 = whisper.cpp default
  "whisper_flash_attn": "auto",      // auto | on | off
  "warm_up": true,                   // compile Metal shaders at launch
  "api_timeout_seconds": 25,         // before falling back to the next backend
  "language": "auto",                // "auto" detects; "es"/"en"/… pins it
                                     // pinning it also skips the retry decode
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
    "prompt": "",                    // empty = built-in dictation prompt
    "base_url": "",                  // empty = provider default; primary only
    "fallback_provider": "openai",   // retried when the primary fails
    "fallback_model": "gpt-4o",      // must not be a mini-tier model
    "timeout_seconds": 12            // before giving up on the primary
  },

  "insertion": "paste",              // paste (⌘V at the caret)
                                     // clipboard (copy only, no keypress)
                                     // type (synthesize keystrokes)
  "restore_clipboard": true,
  "min_recording_seconds": 0.3,      // ignore accidental taps
  "mic_warm_seconds": 0,             // keep the mic open after a take (see Speed)
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

**Transcription has its own chain**, and unlike cleanup a failure there is
fatal — no fallback means no text at all. The order depends on what you asked
for:

| `transcription_backend` | Order tried |
|---|---|
| `"auto"` (default) | local, if a model is installed — **and nothing else**. With no local model: Groq → OpenAI |
| `"local"` | local only |
| `"groq"` | Groq → local → OpenAI |
| `"openai"` | OpenAI → local → Groq |

A working local model is deliberately a chain of one. The privacy promise at the
top of this README is that a local setup makes no network calls, so Murmur will
not start uploading your audio because whisper.cpp had a bad day — it reports the
local failure instead. The chaining only kicks in for a hosted backend you
actually chose, and there local is the *first* fallback, because it is the one
thing a VPN, an expired key, or a provider outage cannot refuse.

The menu-bar status line shows the live plan (`groq → local whisper.cpp`), so a
silent fallback is visible before it costs you a dictation.

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

### Speed

What happens between pressing the key and seeing text, and what keeps each
step short:

- **Pressing the key.** The pill appears on the keypress itself; the mic spins
  up off the main thread, on one audio engine reused across dictations rather
  than rebuilt each time. You can start the next dictation while the previous
  one is still transcribing. They are inserted in the order you spoke them.
- **Transcribing.** With local whisper.cpp, Murmur keeps one `whisper-server`
  (installed with `brew install whisper-cpp`) running on `127.0.0.1` with the
  model loaded. Before this, every dictation launched `whisper-cli` from
  scratch and reloaded the ~0.5 GB model and Metal state, often adding a
  second or more. The server stays warm, at the cost of keeping the model in
  RAM. Set `"whisper_server": false` to go back to one process per dictation.
  If the server fails, Murmur falls back to `whisper-cli` automatically. Its
  output goes to `~/.config/murmur/whisper-server.log`.
- **Decoding.** `whisper_beam_size: 1` (greedy) is several times faster than
  whisper.cpp's default 5-beam search and barely differs on dictation. Set it
  to `5` if you'd rather trade speed for accuracy on hard audio.
- **Cleanup.** While you talk, Murmur opens the connection to the cleanup
  provider, so the request after release skips the TLS handshake. A stalled
  primary provider is abandoned after 10 s in favour of the fallback, instead
  of after 30 s.
- **Bluetooth mics / AirPods.** These take a second or two to switch into
  microphone mode on every press. `"mic_warm_seconds": 60` keeps the mic open
  for a minute after each dictation, so presses in that window start
  instantly and include the quarter-second before you pressed. The downside is
  that the orange mic indicator stays on for that long.

Every dictation logs where the time went, e.g.
`timing: release → text 0.84s (transcribe 0.41s, cleanup 0.38s)`, and
`recording started (mic ready in 35 ms)`.

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
- **Run Diagnostics…** — the full `--doctor` report, opened in TextEdit

The icon becomes a filled capsule while recording, so you always know if it's hot.
The status line under the toggle shows `· model loaded` once the local
whisper-server is warm.

---

## Troubleshooting

**Start here: `--doctor`.**

```bash
/Applications/VoZ.app/Contents/MacOS/VoZ --doctor
```

Or **Run Diagnostics…** from the menu-bar icon, which writes the same report to
`~/.config/murmur/diagnostics.txt` and opens it. It walks the whole pipeline in
order and prints what it actually found at each step: whether `config.json`
parsed, which `whisper-cli` and which model were resolved (and what else is
sitting in the models directory), which keys are present — masked, with their
length, which is what catches a truncated paste — the transcription plan in
order, a **live request to every provider that has a key**, and the state of
each permission. It exits non-zero when it finds something blocking.

The network check is two requests per provider on purpose. Listing models proves
the host is reachable and the key is valid; a real one-token completion is what a
blocked IP actually gets refused on. Groq is why: its `/v1/models` answers from
any address while `/chat/completions` returns 403, so a check that only did the
first would call a completely unusable setup healthy.

**"API unreachable" / "API error" in the pill.**
The pill has room for about four words; the sentence that names the fix is in
`~/.config/murmur/murmur.log`. The two are different problems:

| Pill | Means | Look at |
|---|---|---|
| `API unreachable` | The request never got an HTTP response, or the provider refused the *network* | VPN, proxy, DNS, corporate TLS interception, provider outage |
| `API error` | The provider answered and said no | The key, the quota, the model name |

The log line spells out which: `cannot resolve api.groq.com — DNS is failing`,
`TLS to api.openai.com failed — something is intercepting HTTPS`, `Groq refused
this IP address (403)`, `rejected the API key (401)`, and so on.

If it says `API unreachable` and `--doctor` shows local whisper.cpp as
`unavailable`, that is the actual bug — every dictation is going over the
network because there is no local model to use. `./bootstrap.sh` fixes it, and
after that a blocked API cannot stop dictation at all.

**A key that looks right but gets rejected (401).**
`.env` values are parsed strictly enough to break on things you cannot see. All
of these now work, and all of them used to fail silently:

```bash
export GROQ_API_KEY=gsk_...      # the `export` prefix is stripped
OPENAI_API_KEY="sk-..."          # quotes are stripped
ANTHROPIC_API_KEY=sk-... # work  # trailing comments are stripped
```

Also stripped: a UTF-8 BOM (TextEdit adds one, and it renames the *first* key in
the file so it is never found), and any whitespace, non-breaking space, or
zero-width character inside a value — the usual souvenir of copying a key out of
a web dashboard. `--doctor` prints each key's length; compare it against the
provider's dashboard if you suspect a truncated paste.

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

**Groq returns "Access denied. Please check your network settings." (403)**
Groq blocks VPN, datacenter and some regional IPs. No header, no retry and no
new key gets past it — the key was never the problem. It usually shows up on
`/chat/completions` while `/v1/models` still answers, which is what makes it
read like a key problem, but a hard block returns 403 on both.

**A 403 is not a 401.** 401 means the key is wrong; 403 means the provider knows
who you are and still won't serve this network. `--doctor` reads the response
body to tell them apart and says which one you have, because regenerating a
perfectly good key is the standard way to lose an hour here.

Handled automatically at both stages: cleanup retries with `fallback_provider`,
and transcription moves to the next backend in its plan. But if the only
transcription backend you have is a blocked provider, there is nothing to fall
back *to* — install the local model and the network stops being able to break
dictation at all.

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

**It's slow.**
Read the `timing:` line the log writes after every dictation:

```
timing: 3.80s audio -> transcribe 1.05s + cleanup 0.42s = 1.47s total (0.4x realtime)
```

That splits the wait into the two halves that look identical from the outside.
Then, in order of how much time they usually account for:

- **The first run after a reboot or rebuild** is whisper.cpp compiling its Metal
  shaders and caching them. Murmur now does this at launch on a silent clip
  (`warm_up`), so it lands where nobody is waiting instead of on your first
  dictation. The log says `warm-up: whisper ready in …`.
- **`transcribe` is high on every take.** Check `--doctor`: it prints the thread
  count, the beam size, and a measured `speed` figure for a real clip. The model
  matters most — `small` is about 1 s for 8 s of audio on an M4, plain
  `large-v3` is five to seven. Auto-selection already prefers the fast ones;
  `whisper_model_path` overrides it.
- **A doubled transcribe time** means the language allowlist fired: with
  `"language": "auto"`, a detection outside `languages` is re-run from scratch
  in your main language, so the take costs twice what it should. It is common
  for speech that sits near a neighbouring language — Spanish heard as Galician
  or Catalan. The log names it and tells you which of the two fixes you want.
  Pinning `"language": "es"` skips detection entirely and is the single biggest
  latency lever in the app.
- **`cleanup` is high.** A hosted LLM adds 0.4–2.5 s. If it is much more than
  that, the primary provider is timing out before the fallback gets its turn —
  `cleanup.timeout_seconds` (12 s) caps that, and `--doctor` shows which
  providers actually answer. Turning **AI Cleanup** off in the menu removes the
  stage entirely.

Measured on an M4 with `small`: first run 13 s, every run after 0.85–1.1 s for
8 s of audio.

### Speed settings

| Setting | Default | Effect |
|---|---|---|
| `language` | `"auto"` | Pinning it (`"es"`) skips detection **and** the double-decode retry |
| `whisper_beam_size` | `1` | Greedy. whisper-cli's own default is beam search at 5, roughly 2x the decode time |
| `whisper_threads` | `0` | Auto = performance cores only. Efficiency-core threads hold the whole batch back |
| `whisper_flash_attn` | `"auto"` | Passes `-fa` when the installed whisper-cli advertises it |
| `warm_up` | `true` | Compiles the Metal shaders at launch instead of on your first dictation |
| `api_timeout_seconds` | `25` | How long a hung transcription provider stalls before the fallback runs |
| `cleanup.timeout_seconds` | `12` | Same, for the cleanup stage |

The thread default is the one worth knowing about: it used to be
`activeProcessorCount - 2`, which on Apple Silicon puts threads on efficiency
cores. whisper splits work evenly, so the batch waits on its slowest worker and
adding those threads makes it slower, not faster.
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
