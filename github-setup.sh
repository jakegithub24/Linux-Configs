#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 your-email@example.com"
  exit 1
fi

EMAIL="$1"
KEY_TYPE="ed25519"
KEY_PATH="$HOME/.ssh/id_${KEY_TYPE}"
PUB_KEY_PATH="${KEY_PATH}.pub"

echo "1) Checking for existing SSH keys in ~/.ssh..."
if [ -d "$HOME/.ssh" ] && ls "$HOME/.ssh" 2>/dev/null | grep -E 'id_(ed25519|rsa)(\.pub)?' >/dev/null; then
  echo "Existing SSH key files found in ~/.ssh:"
  ls -1 ~/.ssh | sed -n 's/^/  - /p'
  read -rp "Do you want to generate a new ${KEY_TYPE} key anyway? (y/N): " yn
  yn=${yn:-N}
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    echo "Skipping key generation."
    GENERATED="no"
  else
    GENERATED="yes"
  fi
else
  GENERATED="yes"
fi

if [ "$GENERATED" = "yes" ]; then
  mkdir -p "$HOME/.ssh"
  echo "2) Generating new ${KEY_TYPE} key at ${KEY_PATH}..."
  if [ -f "$KEY_PATH" ]; then
    BACKUP="${KEY_PATH}.$(date +%s).bak"
    echo "Backing up existing key to $BACKUP"
    mv "$KEY_PATH" "$BACKUP"
    mv "${KEY_PATH}.pub" "${BACKUP}.pub" 2>/dev/null || true
  fi
  ssh-keygen -t "$KEY_TYPE" -C "$EMAIL" -f "$KEY_PATH"
fi

echo "3) Starting ssh-agent and adding the key..."
# Start agent in a way that works in scripts
eval "$(ssh-agent -s)" >/dev/null
ssh-add "$KEY_PATH"

echo "4) Copying public key to clipboard (if xclip available) or printing to screen..."
if command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard < "$PUB_KEY_PATH"
  echo "Public key copied to clipboard."
else
  echo "xclip not found. Install with: sudo apt install xclip"
  echo "Public key:"
  echo "--------------------------------------------------"
  cat "$PUB_KEY_PATH"
  echo "--------------------------------------------------"
fi

echo "5) Testing SSH connection to GitHub..."
echo "Note: this will ask to confirm the host fingerprint on first connect."
ssh -T git@github.com || true

echo ""
echo "Next steps:"
echo " - If you haven't already, add the printed/copied public key to GitHub (Settings → SSH and GPG keys → New SSH key)."
echo " - Configure Git user if needed:"
echo "     git config --global user.name \"Your Name\""
echo "     git config --global user.email \"$EMAIL\""
echo " - To clone with SSH:"
echo "     git clone git@github.com:owner/repo.git"

echo "Done."

