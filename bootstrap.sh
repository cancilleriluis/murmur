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
if command -v whisper-cli >/dev/null 2>&1; then
  ok "already installed"
else
  brew install whisper-cpp || { warn "brew install failed"; exit 1; }
  ok "installed"
fi

step "Downloading the speech model (~465 MB, once)"
mkdir -p "$MODEL_DIR"
if [[ -f "$MODEL" ]] && [[ $(stat -f%z "$MODEL" 2>/dev/null || echo 0) -gt 400000000 ]]; then
  ok "model already present"
else
  curl -L --progress-bar -o "$MODEL" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
    || { warn "download failed — rerun to resume"; exit 1; }
  ok "downloaded"
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
  Verify anything without the mic or hotkey:
     /Applications/Murmur.app/Contents/MacOS/Murmur --test-pipeline some.wav

EOF
