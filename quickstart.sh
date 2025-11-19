#!/usr/bin/env bash

set -euo pipefail

# ==========================
# Helper functions
# ==========================

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_shell_rc() {
  if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    echo "$HOME/.zshrc"
  elif [ -n "${BASH_VERSION:-}" ] || [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.zshrc"
  fi
}

append_env_if_missing() {
  local rc_file="$1"
  local key="$2"
  local value="$3"

  if [ -f "$rc_file" ] && grep -q "$key" "$rc_file" 2>/dev/null; then
    echo "  - $key already present in $rc_file (skipping)."
  else
    echo "export $key=\"$value\"" >> "$rc_file"
    echo "  - Added $key to $rc_file"
  fi
}

find_script_file() {
  local base="$1"
  local dir="$2"

  if [ -f "$dir/$base" ]; then
    echo "$dir/$base"
  elif [ -f "$dir/$base.sh" ]; then
    echo "$dir/$base.sh"
  else
    echo ""
  fi
}

# ==========================
# Start
# ==========================

echo "=== Smart Git Helpers Quickstart ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------
# Choose install directory
# --------------------------

default_install_dir="$HOME/.local/bin"
read -r -p "Install symlinks in [$default_install_dir]? (Y/n): " install_confirm
install_confirm="${install_confirm:-Y}"

if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
  INSTALL_DIR="$default_install_dir"
else
  read -r -p "Enter install directory (will be created if missing): " INSTALL_DIR
fi

mkdir -p "$INSTALL_DIR"
echo "Using install directory: $INSTALL_DIR"

# --------------------------
# Symlink scripts
# --------------------------

for cmd in gh-commit-template gh-create-pr; do
  src="$(find_script_file "$cmd" "$SCRIPT_DIR")"
  dst="$INSTALL_DIR/$cmd"

  if [ -z "$src" ]; then
    echo "WARNING: could not find script '$cmd' in $SCRIPT_DIR (tried '$cmd' and '$cmd.sh'). Skipping."
    continue
  fi

  if [ ! -x "$src" ]; then
    chmod +x "$src" || true
  fi

  if [ -L "$dst" ] || [ -f "$dst" ]; then
    echo "$dst already exists. Skipping."
  else
    ln -s "$src" "$dst"
    echo "Created symlink: $dst -> $src"
  fi
done

# --------------------------
# Ensure install dir in PATH
# --------------------------

RC_FILE="$(detect_shell_rc)"
echo "Using shell rc file: $RC_FILE"

if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
  if grep -q "$INSTALL_DIR" "$RC_FILE" 2>/dev/null; then
    echo "$INSTALL_DIR already referenced in $RC_FILE"
  else
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$RC_FILE"
    echo "Added $INSTALL_DIR to PATH in $RC_FILE"
  fi
else
  echo "$INSTALL_DIR is already in PATH"
fi

# --------------------------
# Check required tools
# --------------------------

echo
echo "Checking dependencies..."

missing=()

for bin in git gh jq curl; do
  if command_exists "$bin"; then
    echo "  - $bin: OK"
  else
    echo "  - $bin: MISSING"
    missing+=("$bin")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo
  echo "Missing: ${missing[*]}"

  if [[ "$OSTYPE" == darwin* ]] && command_exists brew; then
    read -r -p "Install missing tools with Homebrew? (Y/n): " brew_install
    brew_install="${brew_install:-Y}"
    if [[ "$brew_install" =~ ^[Yy]$ ]]; then
      brew install "${missing[@]}"
    else
      echo "Skipping automatic install."
    fi
  else
    echo "Install them manually via your package manager."
  fi
fi

# --------------------------
# OpenAI API key (optional)
# --------------------------

echo
echo "Configure OpenAI API? (Optional for AI commit/PR writing)"
read -r -p "Add OPENAI_API_KEY to your shell config? (Y/n): " openai_confirm
openai_confirm="${openai_confirm:-Y}"

if [[ "$openai_confirm" =~ ^[Yy]$ ]]; then
  echo "Enter your OpenAI API key (input hidden):"
  read -rs OPENAI_API_KEY
  echo
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    append_env_if_missing "$RC_FILE" "OPENAI_API_KEY" "$OPENAI_API_KEY"
  else
    echo "No key entered. Skipping OPENAI_API_KEY."
  fi
fi

# --------------------------
# Jira base URL
# --------------------------

default_jira_base="https://immediateco.atlassian.net"
echo
read -r -p "Jira base URL [${default_jira_base}]: " JIRA_BASE_URL
JIRA_BASE_URL="${JIRA_BASE_URL:-$default_jira_base}"

append_env_if_missing "$RC_FILE" "JIRA_BASE_URL" "$JIRA_BASE_URL"

# --------------------------
# GitHub CLI auth check
# --------------------------

echo
if command_exists gh; then
  echo "Checking GitHub auth..."
  if gh auth status >/dev/null 2>&1; then
    echo "gh is authenticated."
  else
    echo "gh is NOT authenticated. You should run:"
    echo "  gh auth login"
  fi
else
  echo "gh not installed, skipping auth check."
fi

# --------------------------
# Done
# --------------------------

echo
echo "Setup complete!"
echo "Reload your shell:"
echo "  exec \$SHELL -l"
echo
echo "Available commands:"
echo "  gh-commit-template   # AI-assisted commit & push"
echo "  gh-create-pr         # Create PR with optional AI summary/title"