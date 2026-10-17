#!/usr/bin/env bash
#
# evidence サブコマンド: 実状態を取得して CSV の期待値と突き合わせ、証跡として保存する。
#
# 出力 (EVIDENCE_DIR):
#   run-info.txt        いつ・誰が・何を対象に取ったか、config の値
#   input.csv           入力 CSV のコピー
#   summary.csv         項目ごとの 期待値 / 実際 / OK・NG
#   summary.md          同じ内容を人が読む表にしたもの
#   <project_id>/       gcloud describe の生出力 (yaml)
#
# 参照系しか実行しない。
#

ev_q() { local s="${1//\"/\"\"}"; printf '"%s"' "${s//$'\n'/ }"; }

# ev_record <line> <project_id> <item> <target> <expected> <actual> <OK|NG|INFO>
ev_record() {
  local line="$1" pid="$2" item="$3" target="$4" expected="$5" actual="$6" result="$7"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$line" "$pid" "$item" \
    "$(ev_q "$target")" "$(ev_q "$expected")" "$(ev_q "$actual")" "$result" >>"$RESULT_FILE"
  printf '| %s | %s | %s | %s | %s | %s | **%s** |\n' "$line" "$pid" "$item" "$target" "${expected//|/\\|}" "${actual//|/\\|}" "$result" >>"$EV_MD_ROWS"
  STAT[$result]=$(( ${STAT[$result]:-0} + 1 ))
  case "$result" in
    NG) err  "line=$line $pid $item/$target NG  expected=[$expected] actual=[$actual]" ;;
    *)  info "line=$line $pid $item/$target $result $actual" ;;
  esac
}

# 比較して記録する。 ev_check <line> <pid> <item> <target> <expected> <actual>
ev_check() {
  if [ "$5" = "$6" ]; then ev_record "$@" OK; else ev_record "$@" NG; fi
}

# ; 区切りの集合を正規化（ソート）
ev_sorted_set() { printf '%s' "$1" | tr ';,' '\n\n' | grep -v '^$' | sort -u | paste -sd';' -; }

# describe の生出力を保存。成功なら 0
ev_save() { # file gcloud-args...
  local file="$1"; shift
  gcloud "$@" >"$file" 2>>"$LOG_FILE" || { rm -f "$file"; return 1; }
}

evidence_project() {
  local pid="$1" i="${PID_ROW[$1]}" line="${R_LINE[${PID_ROW[$1]}]}" d="$EVIDENCE_DIR/$1"
  mkdir -p "$d"

  local state parent
  if ev_save "$d/project.yaml" projects describe "$pid" --format=yaml; then
    state="$(project_state "$pid")"
    ev_check "$line" "$pid" project lifecycleState ACTIVE "$state"
    parent="$(gq projects describe "$pid" --format='value(parent.id)' || true)"
    ev_check "$line" "$pid" project parent "${PARENT_FOLDER_ID:-$PARENT_ORG_ID}" "$parent"
  else
    ev_record "$line" "$pid" project lifecycleState ACTIVE "(not found)" NG
    return 1
  fi

  ev_save "$d/billing.yaml" billing projects describe "$pid" --format=yaml || true
  ev_check "$line" "$pid" billing billingAccountName "billingAccounts/$BILLING_ACCOUNT_ID" "$(project_billing "$pid")"

  local enabled api
  enabled="$(project_enabled_apis "$pid")"
  printf '%s\n' "$enabled" >"$d/services.txt"
  local -a apis
  IFS=',' read -r -a apis <<<"$ENABLE_APIS"
  for api in "${apis[@]}"; do
    if printf '%s\n' "$enabled" | grep -qx "$api"; then ev_record "$line" "$pid" apis "$api" enabled enabled OK
    else ev_record "$line" "$pid" apis "$api" enabled "(not enabled)" NG; fi
  done
}

evidence_sa() {
  local pid="$1" line="${R_LINE[${PID_ROW[$1]}]}" d="$EVIDENCE_DIR/$1" email
  email="$(sa_email_of "$pid")"
  if ev_save "$d/sa.yaml" iam service-accounts describe "$email" --project="$pid" --format=yaml; then
    ev_record "$line" "$pid" sa "$email" exists exists OK
  else
    ev_record "$line" "$pid" sa "$email" exists "(not found)" NG
    return 1
  fi
  ev_save "$d/sa-iam-policy.yaml" iam service-accounts get-iam-policy "$email" --project="$pid" --format=yaml || true

  # GCE に付ける行があるときだけ TokenCreator を確認する
  local i needs=0
  for ((i = 1; i <= N_ROWS; i++)); do
    [ "${R_PROJECT_ID[$i]}" = "$pid" ] && [ -n "${R_GCE_INSTANCE[$i]}" ] && needs=1
  done
  if [ "$needs" = 1 ]; then
    local agent
    agent="$(compute_agent_of_gce_project)"
    if sa_has_binding "$email" "$pid" "$agent" roles/iam.serviceAccountTokenCreator; then
      ev_record "$line" "$pid" sa-iam "tokenCreator:${agent#serviceAccount:}" granted granted OK
    else
      ev_record "$line" "$pid" sa-iam "tokenCreator:${agent#serviceAccount:}" granted "(not granted)" NG
    fi
  fi
}

# GCP の allowed[] を "tcp:443;tcp:8443;icmp" 形式に正規化
ev_fw_allowed() {
  local rule="$1" proto ports p
  local -a ps
  gq compute firewall-rules describe "$rule" --project="$FW_PROJECT_ID" \
    --flatten='allowed[]' --format='value(allowed.IPProtocol,allowed.ports)' 2>/dev/null |
  while IFS=$'\t' read -r proto ports; do
    [ -n "$proto" ] || continue
    if [ -z "$ports" ]; then printf '%s\n' "$proto"
    else IFS=';' read -r -a ps <<<"$ports"; for p in "${ps[@]}"; do printf '%s:%s\n' "$proto" "$p"; done; fi
  done | sort -u | paste -sd';' -
}

evidence_firewall() {
  local pid="$1" i="${PID_ROW[$1]}" line="${R_LINE[${PID_ROW[$1]}]}" d="$EVIDENCE_DIR/$1" email rule
  email="$(sa_email_of "$pid")"
  rule="$(fw_rule_of "$pid")"
  if ! ev_save "$d/firewall.yaml" compute firewall-rules describe "$rule" --project="$FW_PROJECT_ID" --format=yaml; then
    ev_record "$line" "$pid" firewall "$rule" exists "(not found)" NG
    return 1
  fi
  local v
  v() { gq compute firewall-rules describe "$rule" --project="$FW_PROJECT_ID" --format="value($1)" || true; }
  ev_check "$line" "$pid" firewall "$rule/direction" EGRESS "$(v direction)"
  ev_check "$line" "$pid" firewall "$rule/network" "$FW_NETWORK" "$(v 'network.basename()')"
  ev_check "$line" "$pid" firewall "$rule/disabled" False "$(v disabled)"
  ev_check "$line" "$pid" firewall "$rule/targetServiceAccounts" "$email" "$(v targetServiceAccounts)"
  ev_check "$line" "$pid" firewall "$rule/destinationRanges" "$(ev_sorted_set "${R_FW_DEST_RANGES[$i]}")" "$(ev_sorted_set "$(v destinationRanges)")"
  ev_check "$line" "$pid" firewall "$rule/allowed" "$(ev_sorted_set "${R_FW_ALLOW[$i]}")" "$(ev_fw_allowed "$rule")"
}

evidence_gce_row() {
  local i="$1" pid="${R_PROJECT_ID[$1]}" line="${R_LINE[$1]}" d="$EVIDENCE_DIR/${R_PROJECT_ID[$1]}"
  local inst="${R_GCE_INSTANCE[$i]}" zone="${R_GCE_ZONE[$i]}" email
  email="$(sa_email_of "$pid")"
  mkdir -p "$d"
  if ! ev_save "$d/gce_${inst}.yaml" compute instances describe "$inst" --zone="$zone" --project="$GCE_PROJECT_ID" --format=yaml; then
    ev_record "$line" "$pid" gce "$zone/$inst" "$email" "(instance not found)" NG
    return 1
  fi
  local s status sa
  s="$(gce_status_and_sa "$inst" "$zone" "$GCE_PROJECT_ID")"
  status="${s%%$'\t'*}"; sa="${s#*$'\t'}"; [ "$sa" != "$s" ] || sa=""
  ev_check "$line" "$pid" gce "$zone/$inst/serviceAccount" "$email" "$sa"
  ev_record "$line" "$pid" gce "$zone/$inst/status" - "$status" INFO
}

evidence_all() {
  EV_MD_ROWS="$EVIDENCE_DIR/.rows.md"
  : >"$EV_MD_ROWS"
  local at
  at="$(date '+%Y-%m-%d %H:%M:%S')"
  local sha
  sha="$(sha256sum "$CSV_FILE" 2>/dev/null | cut -c1-64 || shasum -a 256 "$CSV_FILE" | cut -c1-64)"
  cp "$CSV_FILE" "$EVIDENCE_DIR/input.csv"

  {
    echo "取得日時 : $at"
    echo "取得者   : $ACTIVE_ACCOUNT"
    echo "gcloud   : $(gcloud --version 2>/dev/null | head -1)"
    echo "入力 CSV : $CSV_FILE (sha256 $sha)"
    echo "行数     : $N_ROWS 行 / プロジェクト ${#UNIQ_PIDS[@]} 件"
    echo "フェーズ : ${ONLY_PHASE:-all}"
    echo
    echo "config:"
    echo "  PARENT_FOLDER_ID   = $PARENT_FOLDER_ID"
    echo "  PARENT_ORG_ID      = $PARENT_ORG_ID"
    echo "  BILLING_ACCOUNT_ID = $BILLING_ACCOUNT_ID"
    echo "  ENABLE_APIS        = $ENABLE_APIS"
    echo "  FW_PROJECT_ID      = $FW_PROJECT_ID"
    echo "  FW_NETWORK         = $FW_NETWORK"
    echo "  FW_RULE_PREFIX     = $FW_RULE_PREFIX"
    echo "  GCE_PROJECT_ID     = $GCE_PROJECT_ID (番号 $GCE_PROJECT_NUMBER)"
  } >"$EVIDENCE_DIR/run-info.txt"

  local pid i
  for pid in "${UNIQ_PIDS[@]}"; do
    info "---- evidence: $pid ----"
    local ok=1
    if should_run project;  then evidence_project  "$pid" || ok=0; fi
    if should_run sa;       then evidence_sa       "$pid" || ok=0; fi
    if should_run firewall; then evidence_firewall "$pid" || true; fi
    if should_run gce; then
      for ((i = 1; i <= N_ROWS; i++)); do
        [ "${R_PROJECT_ID[$i]}" = "$pid" ] && [ -n "${R_GCE_INSTANCE[$i]}" ] || continue
        evidence_gce_row "$i" || true
      done
    fi
  done

  {
    echo "# 証跡: $CSV_FILE"
    echo
    sed 's/^/    /' "$EVIDENCE_DIR/run-info.txt"
    echo
    echo "## 集計"
    echo
    echo "| 結果 | 件数 |"
    echo "| --- | --- |"
    local k
    for k in OK NG INFO; do [ -z "${STAT[$k]:-}" ] || echo "| $k | ${STAT[$k]} |"; done
    echo
    echo "## 項目別"
    echo
    echo "| CSV行 | project_id | 項目 | 対象 | 期待値 | 実際 | 結果 |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    cat "$EV_MD_ROWS"
    echo
    echo "生の describe 出力は各 project_id のフォルダにあります。"
  } >"$EVIDENCE_DIR/summary.md"
  rm -f "$EV_MD_ROWS"
  info "証跡: $EVIDENCE_DIR (summary.md / summary.csv)"
}
