#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

read_env() {
  key=$1
  if [ -f .env ]; then
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' .env
  fi
}

WEB_PORT=${WEB_PORT:-$(read_env WEB_PORT)}
WEB_BIND=${WEB_BIND:-$(read_env WEB_BIND)}
WEB_PORT=${WEB_PORT:-8090}
WEB_BIND=${WEB_BIND:-127.0.0.1}

exec python3 -m http.server "$WEB_PORT" --bind "$WEB_BIND" --directory "$ROOT_DIR/web"
