#!/usr/bin/env bash
set -euo pipefail

# Simple installer for zsh and zsh-autosuggestions across common Linux distros and macOS.
# Installs zsh, installs plugin, and sets zsh as default shell for the current user.

# Detect OS / package manager
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "brew"
  else
    echo "unknown"
  fi
}

PKG_MGR=$(detect_pkg_mgr)
echo "Detected package manager: $PKG_MGR"

install_zsh() {
  case "$PKG_MGR" in
    apt)
      sudo apt-get update
      sudo apt-get install -y zsh git curl
      ;;
    dnf)
      sudo dnf install -y zsh git curl
      ;;
    yum)
      sudo yum install -y zsh git curl
      ;;
    pacman)
      sudo pacman -Sy --noconfirm zsh git curl
      ;;
    zypper)
      sudo zypper install -y zsh git curl
      ;;
    brew)
      brew update
      brew install zsh git curl
      ;;
    *)
      echo "Unsupported package manager. Please install zsh, git, and curl manually."
      exit 1
      ;;
  esac
}

install_autosuggestions() {
  local dest="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"

  # Prefer using Oh My Zsh custom plugin dir if present; otherwise use ~/.zsh_plugins
  if [[ -d "$dest" ]]; then
    echo "zsh-autosuggestions already installed at $dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  git clone https://github.com/zsh-users/zsh-autosuggestions.git "$dest"
  echo "Cloned zsh-autosuggestions to $dest"

  # Ensure plugin is listed in ~/.zshrc plugins line
  if [[ -f "$HOME/.zshrc" ]]; then
    if grep -q "plugins=.*zsh-autosuggestions" "$HOME/.zshrc"; then
      echo "zsh-autosuggestions already enabled in .zshrc"
    else
      # If plugins line exists, append plugin. Otherwise add plugins line.
      if grep -q "^plugins=" "$HOME/.zshrc"; then
        # insert zsh-autosuggestions into the first plugins line
        sed -i.bak '0,/^plugins=/ s/^plugins=(\(.*\))/plugins=(\1 zsh-autosuggestions)/' "$HOME/.zshrc" && echo "Enabled zsh-autosuggestions in .zshrc"
      else
        echo -e "\n# Enable zsh-autosuggestions\nplugins=(zsh-autosuggestions)\n" >> "$HOME/.zshrc"
        echo "Added plugins line to .zshrc"
      fi
    fi
  else
    # create minimal .zshrc enabling the plugin
    cat > "$HOME/.zshrc" <<'EOF'
# Minimal .zshrc
export ZSH="$HOME/.oh-my-zsh"
plugins=(zsh-autosuggestions)
source $ZSH/oh-my-zsh.sh 2>/dev/null || true
EOF
    echo "Created minimal .zshrc enabling zsh-autosuggestions"
  fi
}

change_default_shell() {
  if command -v zsh >/dev/null 2>&1; then
    local zsh_path
    zsh_path=$(command -v zsh)
    if ! grep -q "^$zsh_path$" /etc/shells 2>/dev/null; then
      echo "Adding $zsh_path to /etc/shells (requires sudo)"
      echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    fi
    if [[ "$SHELL" != "$zsh_path" ]]; then
      echo "Changing default shell to zsh for user $USER"
      chsh -s "$zsh_path" || echo "chsh failed; you may need to run: chsh -s $zsh_path"
    else
      echo "Default shell already zsh"
    fi
  else
    echo "zsh not found in PATH after install"
  fi
}

main() {
  install_zsh
  install_autosuggestions
  change_default_shell
  echo "Done. Start a new terminal session or run: exec zsh"
}

main

