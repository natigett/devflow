#!/bin/bash

# DevFlow Installer — Run once to set up DevFlow on your machine
# Usage: ./install.sh

set -euo pipefail

DEVFLOW_DIR="$HOME/.devflow"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔧 Installing DevFlow..."

# Create config dir
mkdir -p "$DEVFLOW_DIR"

# Copy script
cp "$SCRIPT_DIR/devflow.sh" "$DEVFLOW_DIR/devflow.sh"
chmod +x "$DEVFLOW_DIR/devflow.sh"

# Create config from template (only if not exists — don't overwrite tokens)
if [[ ! -f "$DEVFLOW_DIR/config.json" ]]; then
  cp "$SCRIPT_DIR/config.template.json" "$DEVFLOW_DIR/config.json"
  echo "📝 Created ~/.devflow/config.json — fill in your tokens!"
else
  echo "⏭️  ~/.devflow/config.json already exists — skipping (won't overwrite your tokens)"
fi

# Add alias if not present
if ! grep -q 'alias devflow=' ~/.zshrc 2>/dev/null; then
  echo '\n# DevFlow — post-coding automation\nalias devflow="~/.devflow/devflow.sh"' >> ~/.zshrc
  echo "✅ Added 'devflow' alias to ~/.zshrc"
else
  echo "⏭️  Alias already exists in ~/.zshrc"
fi

echo ""
echo "🎉 DevFlow installed!"
echo "   1. Fill in your tokens: ~/.devflow/config.json"
echo "   2. Run: source ~/.zshrc"
echo "   3. Use: devflow -message:\"...\" -jira:\"...\" -reviewer:\"...\""
