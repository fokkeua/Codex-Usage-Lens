#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$(zsh "$PROJECT_DIR/scripts/build-app.sh" release | tail -n 1)"
open "$APP_PATH"
