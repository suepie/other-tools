#!/usr/bin/env bash
#
# CSV を入力に、テナント用 GCP プロジェクトを一括で払い出す。
#
#   validate : CSV と設定・権限の事前チェックのみ
#   plan     : 実行予定の gcloud コマンドを表示（変更しない）
#   apply    : 作成（project → sa → firewall → gce の順）
#   export   : フェーズ別の実行スクリプトを生成する（レビュー・手動実行向け）
#   evidence : 実状態を取得して CSV の期待値と突き合わせ、証跡として保存する
#   destroy  : 削除（gce → firewall → project の順）
#
# 使い方は README.md を参照。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "bash 4 以降が必要です (現在: $BASH_VERSION)。Cloud Shell か devcontainer で実行してください" >&2
  exit 1
fi

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/csv.sh
source "$SCRIPT_DIR/lib/csv.sh"
# shellcheck source=lib/gcp.sh
source "$SCRIPT_DIR/lib/gcp.sh"
# shellcheck source=lib/export.sh
source "$SCRIPT_DIR/lib/export.sh"
# shellcheck source=lib/evidence.sh
source "$SCRIPT_DIR/lib/evidence.sh"

usage() {
  cat >&2 <<'USAGE'
使い方:
  provision.sh <validate|plan|apply|export|evidence|destroy> <input.csv> [オプション]

オプション:
  --config FILE   設定ファイル (既定: スクリプトと同じ場所の config.env)
  --phase NAME    指定フェーズのみ実行: project | sa | firewall | gce
  --out-dir DIR   結果 CSV・ログ・生成スクリプト・証跡の出力先 (既定: ./out)
  --yes           destroy の確認プロンプトを省略する
  -h, --help      このヘルプ

例:
  ./provision.sh validate input.csv
  ./provision.sh plan     input.csv
  ./provision.sh apply    input.csv
  ./provision.sh apply    input.csv --phase gce
  ./provision.sh export   input.csv            # out/export_<日時>/ にスクリプト生成
  ./provision.sh evidence input.csv            # out/evidence_<日時>/ に証跡保存
  ./provision.sh destroy  input.csv
USAGE
  exit 2
}

# ---- 引数 ------------------------------------------------------------------

[ $# -ge 1 ] || usage
COMMAND="$1"
shift
case "$COMMAND" in
  validate|plan|apply|export|evidence|destroy) ;;
  -h|--help) usage ;;
  *) err "不明なサブコマンド: $COMMAND"; usage ;;
esac

[ $# -ge 1 ] || usage
CSV_FILE="$1"
shift

CONFIG_FILE="$SCRIPT_DIR/config.env"
ONLY_PHASE=""
OUT_DIR="$SCRIPT_DIR/out"
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --phase)   ONLY_PHASE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) err "不明なオプション: $1"; usage ;;
  esac
done

case "$ONLY_PHASE" in
  ""|project|sa|firewall|gce) ;;
  *) die "--phase は project | sa | firewall | gce のいずれかです: $ONLY_PHASE" ;;
esac

# ---- 設定 ------------------------------------------------------------------

[ -f "$CONFIG_FILE" ] || die "設定ファイルがありません: $CONFIG_FILE  (config.env.example をコピーして作成してください)"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${PARENT_FOLDER_ID:=}"
: "${PARENT_ORG_ID:=}"
: "${BILLING_ACCOUNT_ID:?config.env に BILLING_ACCOUNT_ID が必要です}"
: "${ENABLE_APIS:=compute.googleapis.com,iam.googleapis.com}"
: "${FW_PROJECT_ID:?config.env に FW_PROJECT_ID が必要です}"
: "${FW_NETWORK:?config.env に FW_NETWORK が必要です}"
: "${FW_RULE_PREFIX:=egress}"
: "${FW_PRIORITY:=1000}"
: "${GCE_PROJECT_ID:?config.env に GCE_PROJECT_ID が必要です}"
: "${SA_SCOPES:=cloud-platform}"
: "${GCE_RESTORE_SA:=}"
: "${WAIT_SECONDS:=60}"
: "${RETRY_MAX:=3}"

if [ -n "$PARENT_FOLDER_ID" ] && [ -n "$PARENT_ORG_ID" ]; then
  die "PARENT_FOLDER_ID と PARENT_ORG_ID はどちらか一方だけ指定してください"
fi
if [ -z "$PARENT_FOLDER_ID" ] && [ -z "$PARENT_ORG_ID" ]; then
  die "PARENT_FOLDER_ID か PARENT_ORG_ID のどちらかが必要です"
fi
[[ "$FW_RULE_PREFIX" =~ ^[a-z][a-z0-9-]*$ ]] || die "FW_RULE_PREFIX は英小文字始まりの英小文字/数字/ハイフンにしてください: $FW_RULE_PREFIX"

# ---- 出力先 ----------------------------------------------------------------

DRY_RUN=0
[ "$COMMAND" = "plan" ] && DRY_RUN=1

RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
case "$COMMAND" in
  validate) ;;
  export)
    EXPORT_DIR="$OUT_DIR/export_$RUN_ID"
    mkdir -p "$EXPORT_DIR"
    LOG_FILE="$EXPORT_DIR/export.log" ;;
  evidence)
    EVIDENCE_DIR="$OUT_DIR/evidence_$RUN_ID"
    mkdir -p "$EVIDENCE_DIR"
    LOG_FILE="$EVIDENCE_DIR/evidence.log"
    RESULT_FILE="$EVIDENCE_DIR/summary.csv"
    printf 'timestamp,line,project_id,item,target,expected,actual,result\n' >"$RESULT_FILE" ;;
  *)
    mkdir -p "$OUT_DIR"
    LOG_FILE="$OUT_DIR/${COMMAND}_${RUN_ID}.log"
    RESULT_FILE="$OUT_DIR/result_${COMMAND}_${RUN_ID}.csv"
    printf 'timestamp,line,project_id,phase,target,status,detail\n' >"$RESULT_FILE" ;;
esac

declare -A STAT=()

csv_q() {
  local s="${1//\"/\"\"}"
  s="${s//$'\n'/ }"
  printf '"%s"' "$s"
}

# 結果 1 件を記録する。 record <line> <project_id> <phase> <target> <status> <detail>
record() {
  local line="$1" pid="$2" phase="$3" target="$4" status="$5" detail="${6:-}"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$line" "$pid" "$phase" "$target" "$status" "$(csv_q "$detail")" >>"$RESULT_FILE"
  STAT[$status]=$(( ${STAT[$status]:-0} + 1 ))
  case "$status" in
    FAILED) err  "line=$line $pid $phase/$target $status $detail" ;;
    *)      info "line=$line $pid $phase/$target $status${detail:+ $detail}" ;;
  esac
}

# ---- CSV 読み込みと検証 -----------------------------------------------------

info "CSV を読み込み: $CSV_FILE"
csv_load "$CSV_FILE"
if ! csv_validate; then
  die "CSV に誤りがあります。上のエラーを修正してください"
fi
info "CSV: ${N_ROWS} 行"

# project_id ごとにまとめる（同じ project_id が複数行ある場合は GCE だけ複数）
declare -a UNIQ_PIDS=()
declare -A PID_ROW=()       # project_id → 代表行 (project/sa/fw の値を取る行)
declare -A PID_FAILED=()    # project_id → 1 なら後続フェーズをスキップ
declare -A PID_PLANNED=()   # plan 時、まだ存在しない（作成予定）プロジェクト
for ((i = 1; i <= N_ROWS; i++)); do
  pid="${R_PROJECT_ID[$i]}"
  if [ -z "${PID_ROW[$pid]:-}" ]; then
    PID_ROW[$pid]=$i
    UNIQ_PIDS+=("$pid")
  fi
done
info "プロジェクト: ${#UNIQ_PIDS[@]} 件"

sa_email_of() {
  local i="${PID_ROW[$1]}"
  printf '%s@%s.iam.gserviceaccount.com' "${R_SA_NAME[$i]}" "$1"
}

fw_rule_of() {
  printf '%s-%s' "$FW_RULE_PREFIX" "$1"
}

parent_flag() {
  if [ -n "$PARENT_FOLDER_ID" ]; then printf -- '--folder=%s' "$PARENT_FOLDER_ID"
  else printf -- '--organization=%s' "$PARENT_ORG_ID"; fi
}

compute_agent_of_gce_project() {
  printf 'serviceAccount:service-%s@compute-system.iam.gserviceaccount.com' "$GCE_PROJECT_NUMBER"
}

restore_sa() {
  if [ -n "$GCE_RESTORE_SA" ]; then printf '%s' "$GCE_RESTORE_SA"
  else printf '%s-compute@developer.gserviceaccount.com' "$GCE_PROJECT_NUMBER"; fi
}

# ---- gcloud コマンドの組み立て（apply と export で共通） -----------------------
# 各関数はグローバル配列 CMD に gcloud 以降の引数を入れる。

cmd_project_create() { CMD=(projects create "$1" --name="$2" "$(parent_flag)"); }
cmd_billing_link()   { CMD=(billing projects link "$1" --billing-account="$BILLING_ACCOUNT_ID"); }
cmd_services_enable() {
  local pid="$1"; shift
  CMD=(services enable "$@" --project="$pid")
}
cmd_sa_create()      { CMD=(iam service-accounts create "$2" --project="$1" --display-name="$2"); }
# $1=rule $2=email $3=ranges(,区切り) $4=rules(,区切り) $5=pid
cmd_fw_create() {
  CMD=(compute firewall-rules create "$1" --project="$FW_PROJECT_ID" --network="$FW_NETWORK"
       --direction=EGRESS --action=ALLOW --rules="$4" --destination-ranges="$3"
       --target-service-accounts="$2" --priority="$FW_PRIORITY" --description="tenant=$5 (provision.sh)")
}
cmd_fw_update() {
  CMD=(compute firewall-rules update "$1" --project="$FW_PROJECT_ID"
       --rules="$4" --destination-ranges="$3" --target-service-accounts="$2" --priority="$FW_PRIORITY")
}
cmd_fw_delete()      { CMD=(compute firewall-rules delete "$1" --project="$FW_PROJECT_ID" --quiet); }
# $1=instance $2=zone $3=sa_email
cmd_gce_set_sa() {
  CMD=(compute instances set-service-account "$1" --zone="$2" --project="$GCE_PROJECT_ID"
       --service-account="$3" --scopes="$SA_SCOPES")
}
cmd_project_delete() { CMD=(projects delete "$1" --quiet); }

# ---- 事前チェック -----------------------------------------------------------

preflight() {
  local ok=1
  command -v gcloud >/dev/null 2>&1 || die "gcloud が見つかりません"

  ACTIVE_ACCOUNT="$(gq auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
  [ -n "$ACTIVE_ACCOUNT" ] || die "gcloud にログインしていません: gcloud auth login"
  info "実行アカウント: $ACTIVE_ACCOUNT"

  if [ -n "$PARENT_FOLDER_ID" ]; then
    if gq resource-manager folders describe "$PARENT_FOLDER_ID" --format='value(displayName)' >/dev/null; then
      info "親フォルダ OK: $PARENT_FOLDER_ID"
    else
      err "親フォルダにアクセスできません: $PARENT_FOLDER_ID"; ok=0
    fi
  else
    if gq organizations describe "$PARENT_ORG_ID" --format='value(displayName)' >/dev/null; then
      info "親組織 OK: $PARENT_ORG_ID"
    else
      err "親組織にアクセスできません: $PARENT_ORG_ID"; ok=0
    fi
  fi

  if gq billing accounts describe "$BILLING_ACCOUNT_ID" --format='value(open)' | grep -q True; then
    info "課金アカウント OK: $BILLING_ACCOUNT_ID"
  else
    err "課金アカウントにアクセスできないか閉じています: $BILLING_ACCOUNT_ID"; ok=0
  fi

  if [ "$(project_state "$FW_PROJECT_ID")" = "ACTIVE" ]; then
    info "FW プロジェクト OK: $FW_PROJECT_ID"
    if gq compute networks describe "$FW_NETWORK" --project="$FW_PROJECT_ID" --format='value(name)' >/dev/null; then
      info "VPC OK: $FW_NETWORK"
    else
      err "VPC が見つかりません: $FW_NETWORK (project=$FW_PROJECT_ID)"; ok=0
    fi
  else
    err "FW プロジェクトにアクセスできません: $FW_PROJECT_ID"; ok=0
  fi

  if [ "$(project_state "$GCE_PROJECT_ID")" = "ACTIVE" ]; then
    info "GCE プロジェクト OK: $GCE_PROJECT_ID"
    GCE_PROJECT_NUMBER="$(project_number "$GCE_PROJECT_ID")"
  else
    err "GCE プロジェクトにアクセスできません: $GCE_PROJECT_ID"; ok=0
    GCE_PROJECT_NUMBER=""
  fi

  # 組織ポリシー（前提条件）。取れなければ警告のみ
  local parent_type parent_id enforced
  if [ -n "$PARENT_FOLDER_ID" ]; then parent_type=folder; parent_id="$PARENT_FOLDER_ID"; else parent_type=organization; parent_id="$PARENT_ORG_ID"; fi
  enforced="$(gq org-policies describe iam.disableCrossProjectServiceAccountUsage "--${parent_type}=${parent_id}" --effective --format='value(spec.rules[0].enforce)' || true)"
  case "$enforced" in
    True|true)
      warn "組織ポリシー iam.disableCrossProjectServiceAccountUsage が ${parent_type}=${parent_id} で有効です。GCE への SA 紐づけが失敗します。README の前提条件を確認してください" ;;
    False|false)
      info "組織ポリシー iam.disableCrossProjectServiceAccountUsage: 解除済み" ;;
    *)
      warn "組織ポリシー iam.disableCrossProjectServiceAccountUsage を確認できませんでした（権限不足の可能性）。解除済みであることを別途確認してください" ;;
  esac

  [ "$ok" = 1 ] || die "事前チェックに失敗しました"
}

# ---- apply: project -----------------------------------------------------------

phase_project() {
  local pid="$1" i="${PID_ROW[$1]}" line
  line="${R_LINE[$i]}"
  local name="${R_DISPLAY_NAME[$i]}"

  local state
  state="$(project_state "$pid")"
  case "$state" in
    ACTIVE)
      record "$line" "$pid" project project EXISTS ;;
    DELETE_REQUESTED)
      record "$line" "$pid" project project FAILED "削除保留中のプロジェクトです。復元するか別の project_id にしてください"
      PID_FAILED[$pid]=1; return ;;
    *)
      cmd_project_create "$pid" "$name"
      if [ "$DRY_RUN" = 1 ]; then
        run "${CMD[@]}"
        record "$line" "$pid" project project PLANNED "create"
        PID_PLANNED[$pid]=1
      else
        if run "${CMD[@]}"; then
          if wait_project_active "$pid"; then
            record "$line" "$pid" project project CREATED
          else
            record "$line" "$pid" project project FAILED "作成後 ${WAIT_SECONDS} 秒待っても ACTIVE になりません"
            PID_FAILED[$pid]=1; return
          fi
        else
          record "$line" "$pid" project project FAILED "$LAST_ERR"
          PID_FAILED[$pid]=1; return
        fi
      fi ;;
  esac

  # 課金
  cmd_billing_link "$pid"
  if [ -n "${PID_PLANNED[$pid]:-}" ]; then
    run "${CMD[@]}"
    record "$line" "$pid" project billing PLANNED "link $BILLING_ACCOUNT_ID"
  else
    local current
    current="$(project_billing "$pid")"
    if [ "$current" = "billingAccounts/$BILLING_ACCOUNT_ID" ]; then
      record "$line" "$pid" project billing EXISTS
    elif [ -n "$current" ] && [ "$DRY_RUN" = 0 ]; then
      record "$line" "$pid" project billing FAILED "別の課金アカウントに紐づいています: $current"
      PID_FAILED[$pid]=1; return
    elif run "${CMD[@]}"; then
      record "$line" "$pid" project billing "$([ "$DRY_RUN" = 1 ] && echo PLANNED || echo CREATED)"
    else
      record "$line" "$pid" project billing FAILED "$LAST_ERR"
      PID_FAILED[$pid]=1; return
    fi
  fi

  # API
  local -a apis
  IFS=',' read -r -a apis <<<"$ENABLE_APIS"
  if [ -n "${PID_PLANNED[$pid]:-}" ]; then
    cmd_services_enable "$pid" "${apis[@]}"
    run "${CMD[@]}"
    record "$line" "$pid" project apis PLANNED "$ENABLE_APIS"
  else
    local enabled api
    local -a missing=()
    enabled="$(project_enabled_apis "$pid")"
    for api in "${apis[@]}"; do
      printf '%s\n' "$enabled" | grep -qx "$api" || missing+=("$api")
    done
    if [ ${#missing[@]} -eq 0 ]; then
      record "$line" "$pid" project apis EXISTS
      return
    fi
    cmd_services_enable "$pid" "${missing[@]}"
    if run "${CMD[@]}"; then
      record "$line" "$pid" project apis "$([ "$DRY_RUN" = 1 ] && echo PLANNED || echo CREATED)" "${missing[*]}"
    else
      record "$line" "$pid" project apis FAILED "$LAST_ERR"
      PID_FAILED[$pid]=1; return
    fi
  fi
}

# ---- apply: sa ----------------------------------------------------------------

phase_sa() {
  local pid="$1" i="${PID_ROW[$1]}" line
  line="${R_LINE[$i]}"
  local sa_name="${R_SA_NAME[$i]}" email
  email="$(sa_email_of "$pid")"
  cmd_sa_create "$pid" "$sa_name"

  if [ -n "${PID_PLANNED[$pid]:-}" ]; then
    run "${CMD[@]}"
    record "$line" "$pid" sa "$email" PLANNED "create"
    return
  fi
  if [ "$DRY_RUN" = 0 ] && [ "$(project_state "$pid")" != "ACTIVE" ]; then
    record "$line" "$pid" sa "$email" FAILED "プロジェクトが存在しません。先に project フェーズを実行してください"
    PID_FAILED[$pid]=1; return
  fi

  if sa_exists "$email" "$pid"; then
    record "$line" "$pid" sa "$email" EXISTS
    return
  fi

  if run "${CMD[@]}"; then
    if [ "$DRY_RUN" = 1 ]; then
      record "$line" "$pid" sa "$email" PLANNED "create"
    elif wait_sa_visible "$email" "$pid"; then
      record "$line" "$pid" sa "$email" CREATED
    else
      record "$line" "$pid" sa "$email" FAILED "作成後 ${WAIT_SECONDS} 秒待っても参照できません"
      PID_FAILED[$pid]=1
    fi
  else
    record "$line" "$pid" sa "$email" FAILED "$LAST_ERR"
    PID_FAILED[$pid]=1
  fi
}

# ---- apply: firewall ----------------------------------------------------------

phase_firewall() {
  local pid="$1" i="${PID_ROW[$1]}" line
  line="${R_LINE[$i]}"
  local email rule ranges rules
  email="$(sa_email_of "$pid")"
  rule="$(fw_rule_of "$pid")"
  ranges="${R_FW_DEST_RANGES[$i]//;/,}"
  rules="${R_FW_ALLOW[$i]//;/,}"

  if [ "$DRY_RUN" = 0 ] && ! sa_exists "$email" "$pid"; then
    record "$line" "$pid" firewall "$rule" FAILED "SA が存在しません: $email。先に sa フェーズを実行してください"
    PID_FAILED[$pid]=1; return
  fi

  if fw_rule_exists "$rule" "$FW_PROJECT_ID"; then
    # CSV を正として既存ルールを更新する（宛先・ポートの変更を反映するため）
    cmd_fw_update "$rule" "$email" "$ranges" "$rules" "$pid"
    if run "${CMD[@]}"; then
      record "$line" "$pid" firewall "$rule" "$([ "$DRY_RUN" = 1 ] && echo PLANNED || echo UPDATED)" "to=$ranges allow=$rules"
    else
      record "$line" "$pid" firewall "$rule" FAILED "$LAST_ERR"
      PID_FAILED[$pid]=1
    fi
    return
  fi

  cmd_fw_create "$rule" "$email" "$ranges" "$rules" "$pid"
  if run "${CMD[@]}"; then
    record "$line" "$pid" firewall "$rule" "$([ "$DRY_RUN" = 1 ] && echo PLANNED || echo CREATED)" "to=$ranges allow=$rules"
  else
    record "$line" "$pid" firewall "$rule" FAILED "$LAST_ERR"
    PID_FAILED[$pid]=1
  fi
}

# ---- apply: gce ---------------------------------------------------------------

phase_gce_row() {
  local i="$1" pid="${R_PROJECT_ID[$1]}" line="${R_LINE[$1]}"
  local inst="${R_GCE_INSTANCE[$i]}" zone="${R_GCE_ZONE[$i]}" email target
  email="$(sa_email_of "$pid")"
  target="$zone/$inst"

  local info_line status current_sa
  info_line="$(gce_status_and_sa "$inst" "$zone" "$GCE_PROJECT_ID")"
  if [ -z "$info_line" ]; then
    record "$line" "$pid" gce "$target" FAILED "インスタンスが見つかりません (project=$GCE_PROJECT_ID)"
    return
  fi
  status="${info_line%%$'\t'*}"
  current_sa="${info_line#*$'\t'}"
  [ "$current_sa" != "$info_line" ] || current_sa=""

  if [ "$current_sa" = "$email" ]; then
    record "$line" "$pid" gce "$target" EXISTS "already $email"
    return
  fi

  if [ "$status" != "TERMINATED" ]; then
    record "$line" "$pid" gce "$target" FAILED "インスタンスが $status です。停止してから再実行してください: gcloud compute instances stop $inst --zone=$zone --project=$GCE_PROJECT_ID"
    return
  fi

  # 他プロジェクトの SA を付けるには、GCE プロジェクトの Compute サービスエージェントが
  # その SA の TokenCreator である必要がある（前提条件・手動付与）
  local agent
  agent="$(compute_agent_of_gce_project)"
  if [ -z "${PID_PLANNED[$pid]:-}" ]; then
    if ! sa_has_binding "$email" "$pid" "$agent" roles/iam.serviceAccountTokenCreator; then
      local hint="gcloud iam service-accounts add-iam-policy-binding $email --project=$pid --member=$agent --role=roles/iam.serviceAccountTokenCreator"
      if [ "$DRY_RUN" = 1 ]; then
        warn "line=$line $pid: Compute サービスエージェントに TokenCreator が付いていません。apply 前に実行してください: $hint"
      else
        record "$line" "$pid" gce "$target" FAILED "Compute サービスエージェントに TokenCreator がありません。実行してください: $hint"
        return
      fi
    fi
  fi

  cmd_gce_set_sa "$inst" "$zone" "$email"
  if run "${CMD[@]}"; then
    record "$line" "$pid" gce "$target" "$([ "$DRY_RUN" = 1 ] && echo PLANNED || echo ATTACHED)" "$email (was: ${current_sa:-none})"
  else
    record "$line" "$pid" gce "$target" FAILED "$LAST_ERR"
  fi
}

# ---- destroy ----------------------------------------------------------------

destroy_gce_row() {
  local i="$1" pid="${R_PROJECT_ID[$1]}" line="${R_LINE[$1]}"
  local inst="${R_GCE_INSTANCE[$i]}" zone="${R_GCE_ZONE[$i]}" email target
  email="$(sa_email_of "$pid")"
  target="$zone/$inst"

  local info_line status current_sa
  info_line="$(gce_status_and_sa "$inst" "$zone" "$GCE_PROJECT_ID")"
  if [ -z "$info_line" ]; then
    record "$line" "$pid" gce "$target" NOT_FOUND
    return
  fi
  status="${info_line%%$'\t'*}"
  current_sa="${info_line#*$'\t'}"
  [ "$current_sa" != "$info_line" ] || current_sa=""

  if [ "$current_sa" != "$email" ]; then
    record "$line" "$pid" gce "$target" SKIPPED "現在の SA は ${current_sa:-none} で対象外"
    return
  fi
  if [ "$status" != "TERMINATED" ]; then
    record "$line" "$pid" gce "$target" FAILED "インスタンスが $status です。停止してから再実行してください: gcloud compute instances stop $inst --zone=$zone --project=$GCE_PROJECT_ID"
    return
  fi

  local restore
  restore="$(restore_sa)"
  cmd_gce_set_sa "$inst" "$zone" "$restore"
  if run "${CMD[@]}"; then
    record "$line" "$pid" gce "$target" RESTORED "$restore"
  else
    record "$line" "$pid" gce "$target" FAILED "$LAST_ERR"
  fi
}

destroy_firewall() {
  local pid="$1" line="${R_LINE[${PID_ROW[$1]}]}" rule
  rule="$(fw_rule_of "$pid")"
  if ! fw_rule_exists "$rule" "$FW_PROJECT_ID"; then
    record "$line" "$pid" firewall "$rule" NOT_FOUND
    return
  fi
  cmd_fw_delete "$rule"
  if run "${CMD[@]}"; then
    record "$line" "$pid" firewall "$rule" DELETED
  else
    record "$line" "$pid" firewall "$rule" FAILED "$LAST_ERR"
  fi
}

destroy_project() {
  local pid="$1" line="${R_LINE[${PID_ROW[$1]}]}"
  case "$(project_state "$pid")" in
    ACTIVE) ;;
    DELETE_REQUESTED) record "$line" "$pid" project project SKIPPED "既に削除保留中"; return ;;
    *) record "$line" "$pid" project project NOT_FOUND; return ;;
  esac
  # SA はプロジェクトごと消える
  cmd_project_delete "$pid"
  if run "${CMD[@]}"; then
    record "$line" "$pid" project project DELETED "30 日間は復元可能"
  else
    record "$line" "$pid" project project FAILED "$LAST_ERR"
  fi
}

# ---- 実行 -------------------------------------------------------------------

should_run() { [ -z "$ONLY_PHASE" ] || [ "$ONLY_PHASE" = "$1" ]; }

summary() {
  echo >&2
  info "==== 結果 ($COMMAND) ===="
  local k
  for k in CREATED UPDATED ATTACHED EXISTS PLANNED DELETED RESTORED SKIPPED NOT_FOUND OK NG FAILED; do
    [ -z "${STAT[$k]:-}" ] || printf '  %-10s %d\n' "$k" "${STAT[$k]}" >&2
  done
  info "結果 CSV: $RESULT_FILE"
  info "ログ    : $LOG_FILE"
  [ -z "${STAT[FAILED]:-}" ] && [ -z "${STAT[NG]:-}" ]
}

preflight

case "$COMMAND" in
  validate)
    info "validate OK: CSV と設定に問題はありません"
    exit 0
    ;;

  plan|apply)
    [ "$DRY_RUN" = 1 ] && info "==== plan: 何も変更しません ===="
    if should_run project; then
      info "---- phase: project ----"
      for pid in "${UNIQ_PIDS[@]}"; do phase_project "$pid"; done
    fi
    if should_run sa; then
      info "---- phase: sa ----"
      for pid in "${UNIQ_PIDS[@]}"; do
        [ -z "${PID_FAILED[$pid]:-}" ] || { record "${R_LINE[${PID_ROW[$pid]}]}" "$pid" sa - SKIPPED "前フェーズが失敗"; continue; }
        phase_sa "$pid"
      done
    fi
    if should_run firewall; then
      info "---- phase: firewall ----"
      for pid in "${UNIQ_PIDS[@]}"; do
        [ -z "${PID_FAILED[$pid]:-}" ] || { record "${R_LINE[${PID_ROW[$pid]}]}" "$pid" firewall - SKIPPED "前フェーズが失敗"; continue; }
        phase_firewall "$pid"
      done
    fi
    if should_run gce; then
      info "---- phase: gce ----"
      for ((i = 1; i <= N_ROWS; i++)); do
        pid="${R_PROJECT_ID[$i]}"
        [ -n "${R_GCE_INSTANCE[$i]}" ] || { record "${R_LINE[$i]}" "$pid" gce - SKIPPED "gce_instance が空"; continue; }
        [ -z "${PID_FAILED[$pid]:-}" ] || { record "${R_LINE[$i]}" "$pid" gce - SKIPPED "前フェーズが失敗"; continue; }
        phase_gce_row "$i"
      done
    fi
    summary
    ;;

  export)
    export_all
    ;;

  evidence)
    evidence_all
    summary
    ;;

  destroy)
    echo >&2
    warn "以下のプロジェクトを削除します（SA も一緒に消えます）。GCE の SA は既定に戻し、FW ルールも削除します:"
    for pid in "${UNIQ_PIDS[@]}"; do printf '    %s\n' "$pid" >&2; done
    echo >&2
    if [ "$ASSUME_YES" != 1 ]; then
      printf '続行するには yes と入力: ' >&2
      read -r answer
      [ "$answer" = "yes" ] || die "中止しました"
    fi
    if should_run gce; then
      info "---- phase: gce (restore) ----"
      for ((i = 1; i <= N_ROWS; i++)); do
        [ -n "${R_GCE_INSTANCE[$i]}" ] || continue
        destroy_gce_row "$i"
      done
    fi
    if should_run firewall; then
      info "---- phase: firewall (delete) ----"
      for pid in "${UNIQ_PIDS[@]}"; do destroy_firewall "$pid"; done
    fi
    if should_run project; then
      info "---- phase: project (delete) ----"
      for pid in "${UNIQ_PIDS[@]}"; do destroy_project "$pid"; done
    fi
    summary
    ;;
esac
