#!/usr/bin/env bash
#
# gcloud のラッパ。
#
#   gq   ... 参照系。失敗しても空を返すだけ（存在確認に使う）
#   run  ... 更新系。DRY_RUN=1 なら表示のみ。一時的なエラーはリトライする
#
# 更新系の最後のエラーメッセージは LAST_ERR に入る。
#

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

LAST_ERR=""

# 参照系。stderr はログに落とし、失敗時は空出力・非ゼロ終了
gq() {
  gcloud "$@" 2>>"$LOG_FILE"
}

# 「時間を置けば通る」種類のエラーか
_is_transient() {
  printf '%s' "$1" | grep -Eqi \
    'RESOURCE_EXHAUSTED|rateLimitExceeded|quota exceeded for quota metric .*per minute|UNAVAILABLE|DEADLINE_EXCEEDED|INTERNAL|backend error|HTTPError 5[0-9][0-9]|HTTPError 429|not ready|is not found|was not found|does not exist|try again'
}

# エラー出力から人が読む 1 行を取り出す
_pick_error_line() {
  local picked
  picked="$(printf '%s\n' "$1" | grep -E '^ERROR' | head -1)"
  [ -n "$picked" ] || picked="$(printf '%s\n' "$1" | grep -v '^\s*$' | tail -1)"
  picked="${picked//$'\n'/ }"
  printf '%s' "${picked:0:400}"
}

# 更新系
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[plan] gcloud $*"
    return 0
  fi

  info "gcloud $*"
  local out rc attempt=1 delay=5
  while :; do
    out="$(gcloud "$@" 2>&1)"
    rc=$?
    [ -z "$out" ] || printf '%s\n' "$out" >>"$LOG_FILE"
    if [ "$rc" -eq 0 ]; then
      LAST_ERR=""
      return 0
    fi
    LAST_ERR="$(_pick_error_line "$out")"
    if [ "$attempt" -ge "${RETRY_MAX:-3}" ] || ! _is_transient "$out"; then
      return "$rc"
    fi
    warn "一時的なエラーのため ${delay} 秒後に再試行 (${attempt}/${RETRY_MAX:-3}): $LAST_ERR"
    sleep "$delay"
    delay=$((delay * 3))
    attempt=$((attempt + 1))
  done
}

# ---- 存在確認 ---------------------------------------------------------------

# 出力: ACTIVE / DELETE_REQUESTED / (空=存在しないか権限なし)
project_state() {
  gq projects describe "$1" --format='value(lifecycleState)' || true
}

project_number() {
  gq projects describe "$1" --format='value(projectNumber)' || true
}

# 出力: billingAccounts/XXXXXX-... / (空)
project_billing() {
  gq billing projects describe "$1" --format='value(billingAccountName)' || true
}

# 有効な API の一覧（改行区切り）
project_enabled_apis() {
  gq services list --enabled --project="$1" --format='value(config.name)' || true
}

sa_exists() {
  gq iam service-accounts describe "$1" --project="$2" --format='value(email)' >/dev/null
}

fw_rule_exists() {
  gq compute firewall-rules describe "$1" --project="$2" --format='value(name)' >/dev/null
}

# 出力: "STATUS<TAB>SA_EMAIL" / (空=存在しない)
gce_status_and_sa() {
  gq compute instances describe "$1" --zone="$2" --project="$3" \
    --format='csv[no-heading,separator="	"](status,serviceAccounts[0].email)' || true
}

# SA の IAM ポリシーに、指定メンバーが指定ロールで入っているか
sa_has_binding() {
  local sa_email="$1" project="$2" member="$3" role="$4"
  gq iam service-accounts get-iam-policy "$sa_email" --project="$project" \
    --flatten='bindings[].members' \
    --filter="bindings.role=${role} AND bindings.members=${member}" \
    --format='value(bindings.role)' 2>/dev/null | grep -q .
}

# ---- 待機 -------------------------------------------------------------------

wait_project_active() {
  local pid="$1" waited=0
  while [ "$waited" -lt "${WAIT_SECONDS:-60}" ]; do
    [ "$(project_state "$pid")" = "ACTIVE" ] && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# SA は作成直後に describe が 404 を返すことがあるため、見えるまで待つ
wait_sa_visible() {
  local email="$1" pid="$2" waited=0
  while [ "$waited" -lt "${WAIT_SECONDS:-60}" ]; do
    sa_exists "$email" "$pid" && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}
