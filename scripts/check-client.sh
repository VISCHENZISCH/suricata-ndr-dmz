#!/bin/sh
#Groupe 2 - Point d'entrée unique : délègue vers check-wsl.sh ou check-linux.sh
#Usage : ./scripts/check-client.sh [--linux|--wsl] [options...]

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET=""

case "${1:-}" in
    --linux) TARGET="check-linux.sh"; shift ;;
    --wsl)   TARGET="check-wsl.sh"; shift ;;
esac

if [ -z "$TARGET" ]; then
    if grep -qi microsoft /proc/version 2>/dev/null || [ -e /run/WSL ]; then
        TARGET="check-wsl.sh"
    else
        TARGET="check-linux.sh"
    fi
fi

exec "$SCRIPT_DIR/$TARGET" "$@"
