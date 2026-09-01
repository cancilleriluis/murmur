#!/bin/bash
# Murmur — one-command setup for a new Mac.
#
#   git clone https://github.com/cancilleriluis/murmur.git ~/Murmur
#   cd ~/Murmur && ./bootstrap.sh
#
# Safe to re-run: every step checks whether it is already done.
set -uo pipefail

cd "$(dirname "$0")"
MODEL_DIR="$HOME/.config/murmur/models"
MODEL="$MODEL_DIR/ggml-small.bin"
step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$1"; }

step "Checking prerequisites"
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Command Line Tools missing — a dialog will open. Rerun this once it finishes."
  xcode-select --install 2>/dev/null || true
  exit 1
fi
ok "Xcode Command Line Tools"

if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not found. Install from https://brew.sh, then rerun."
  exit 1
fi
ok "Homebrew"

step "Installing whisper.cpp"
# Look in the Homebrew prefixes as well as $PATH: Murmur resolves the binary by
# absolute path, so "on $PATH" and "installed" are not the same question, and
# answering the wrong one here means the app falls back to a hosted API.
find_whisper() {
  local d n
  for d in "$(brew --prefix 2>/dev/null)/bin" /opt/homebrew/bin /usr/local/bin; do
    for n in whisper-cli whisper-cpp whisper; do
      [[ -x "$d/$n" ]] && { echo "$d/$n"; return 0; }
    done
  done
  command -v whisper-cli 2>/dev/null && return 0
  return 1
}

WHISPER_BIN="$(find_whisper || true)"
if [[ -n "$WHISPER_BIN" ]]; then
  ok "already installed ($WHISPER_BIN)"
else
  brew install whisper-cpp || { warn "brew install failed"; exit 1; }
  WHISPER_BIN="$(find_whisper || true)"
  [[ -n "$WHISPER_BIN" ]] || { warn "brew reported success but no whisper binary was found"; exit 1; }
  ok "installed ($WHISPER_BIN)"
fi

step "Downloading the speech model (~465 MB, once)"
mkdir -p "$MODEL_DIR"

# A real whisper model starts with magic 0x67676d6c written as a native-endian
# uint32, so the bytes on disk are "lmgg" — NOT "ggml". Checking that, rather
# than only the size, is what tells a model apart from an error page saved under
# a .bin name: `curl` without -f writes the server's error body to the output
# file and still exits 0, so every later run reports "model already present".
model_magic_ok() {
  local m
  m=$(head -c 4 "$1" 2>/dev/null)
  [[ "$m" == "lmgg" || "$m" == "GGUF" ]]
}

model_is_big_enough() {
  [[ $(stat -f%z "$1" 2>/dev/null || echo 0) -gt 400000000 ]]
}

model_is_valid() {
  [[ -f "$1" ]] && model_is_big_enough "$1" && model_magic_ok "$1"
}

if model_is_valid "$MODEL"; then
  ok "model already present"
else
  if [[ -f "$MODEL" ]]; then
    # Only ever delete a file that is obviously a failed download. A large file
    # whose magic looks wrong gets a warning and a stop: half a gigabyte the
    # user waited for is not something to throw away on a heuristic.
    if model_is_big_enough "$MODEL"; then
      warn "$MODEL is $(stat -f%z "$MODEL") bytes but its header doesn't look like a model."
      warn "NOT deleting it — check it by hand:  head -c 4 \"$MODEL\"   (expected: lmgg)"
      warn "If it really is broken, delete it yourself and rerun this script."
      exit 1
    fi
    warn "existing $MODEL is only $(stat -f%z "$MODEL" 2>/dev/null || echo 0) bytes — a failed download. Removing it."
    rm -f "$MODEL"
  fi
  # -f so an HTTP error is an error instead of a file full of HTML.
  # -C - resumes a partial download instead of restarting the 465 MB.
  curl -fL --progress-bar --retry 3 --retry-delay 2 -C - -o "$MODEL" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
    || { warn "download failed — rerun to resume where it stopped"; exit 1; }

  if ! model_is_valid "$MODEL"; then
    warn "the downloaded file is not a valid model. Leaving it in place for inspection:"
    warn "  ls -la \"$MODEL\"  &&  head -c 4 \"$MODEL\"    (expected: lmgg)"
    warn "Download it by hand if this keeps happening:"
    warn "  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
    exit 1
  fi
  ok "downloaded and verified"
fi

step "Setting up a stable signing identity"
# Doing this BEFORE the first build means permissions are granted once instead
# of after every rebuild — the single most annoying failure mode of this app.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Murmur Self-Signed"; then
  ok "signing identity already exists"
else
  warn "macOS will ask for your login password (keychain only — nothing leaves this Mac)."
  ./setup-signing.sh || warn "skipped — you can run ./setup-signing.sh later"
fi

step "Building and installing Murmur.app"
./build.sh --install || { warn "build failed"; exit 1; }

step "Done — two things left, both manual"
cat <<'EOF'

  1. GRANT PERMISSIONS
     System Settings ▸ Privacy & Security — add Murmur under all three:
       · Microphone         (to hear you)
       · Accessibility      (to paste at the cursor)
       · Input Monitoring   (to see the push-to-talk key)
     Then quit Murmur from its menu-bar icon and open it again.
     macOS only hands new permissions to a freshly launched process.

  2. API KEYS (optional — it works offline without them)
     Edit ~/.config/murmur/.env and fill in the keys you use.
     Without them you get raw transcripts; with them you get filler removal,
     punctuation, and enumerated points. Copy the file from your other Mac
     over AirDrop, or paste the values from your password manager.
     Never commit that file.

  Hold the push-to-talk key (Left Option by default), speak, release.

  If anything misbehaves, this prints exactly which step is broken —
  config, local model, keys, live network, permissions:
     /Applications/Murmur.app/Contents/MacOS/Murmur --doctor

  Or run the transcribe -> cleanup path against a file, no mic or hotkey needed:
     /Applications/Murmur.app/Contents/MacOS/Murmur --test-pipeline some.wav

EOF
