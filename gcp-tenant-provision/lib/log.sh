#!/usr/bin/env bash
#
# ログ出力。stderr と LOG_FILE の両方に書く。
# LOG_FILE が未設定のとき（validate 時など）は stderr のみ。
#

: "${LOG_FILE:=/dev/null}"

_log() {
  local level="$1"
  shift
  local line
  line="$(printf '%s [%-5s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*")"
  printf '%s\n' "$line" >&2
  if [ "$LOG_FILE" != "/dev/null" ]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

info() { _log INFO "$@"; }
warn() { _log WARN "$@"; }
err()  { _log ERROR "$@"; }
die()  { err "$@"; exit 1; }
