#!/usr/bin/env bash
#
# export サブコマンド: フェーズ別の実行スクリプトを生成する。
#
# 生成されるスクリプトは、生成時点と実行時点で状態が変わっていても動くように
# コマンド自体を冪等（存在確認 → なければ作成）にしてある。
# 実行すると同じ場所に <script>.<日時>.log を残す（実行証跡）。
#
# provision.sh から呼ばれる前提（CMD 組み立て関数、R_* 配列、config 変数を使う）。
#

# 表示用のシェルクォート。安全な文字だけなら素のまま、それ以外はシングルクォートで囲む
shq() {
  local a out=""
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+="$a "
    else
      out+="'${a//\'/\'\\\'\'}' "
    fi
  done
  printf '%s' "${out% }"
}

# CMD 配列を "gcloud ..." の 1 行にする
cmdline() { printf 'gcloud %s' "$(shq "${CMD[@]}")"; }

_export_header() {
  local file="$1" phase="$2" desc="$3"
  cat >"$file" <<HEADER
#!/usr/bin/env bash
#
# ${desc}
#
# 生成元 : ${CSV_FILE} (sha256 ${CSV_SHA256})
# 生成日時: ${EXPORT_AT}
# 生成者 : ${ACTIVE_ACCOUNT}
# フェーズ: ${phase}
#
# 実行すると、このファイルと同じ場所に <このファイル名>.<日時>.log を残します。
# 何度実行しても同じ結果になるように、存在するものは作りません。
#
set -uo pipefail
cd "\$(dirname "\$0")"
LOG="\${0##*/}"; LOG="\${LOG%.sh}.\$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "\$LOG") 2>&1
echo "=== start \$(date '+%F %T') account=\$(gcloud config get-value account 2>/dev/null) log=\$LOG"
FAILED=0
run()      { echo; echo "+ \$*"; "\$@" || { echo "!! FAILED rc=\$? : \$*"; FAILED=\$((FAILED+1)); return 1; }; }
exists()   { "\$@" >/dev/null 2>&1; }
wait_for() { local i=0; until "\$@" >/dev/null 2>&1; do i=\$((i+5)); if [ "\$i" -ge ${WAIT_SECONDS} ]; then echo "!! timeout: \$*"; FAILED=\$((FAILED+1)); return 1; fi; sleep 5; done; }
# GCE に SA を付けられる状態か: 存在する・まだ付いていない・停止中
vm_ready() { # instance zone project sa_email
  local s st sa
  s="\$(gcloud compute instances describe "\$1" --zone="\$2" --project="\$3" --format='value(status,serviceAccounts[0].email)' 2>/dev/null)"
  [ -n "\$s" ] || { echo "!! \$1: インスタンスが見つかりません (project=\$3)"; FAILED=\$((FAILED+1)); return 1; }
  IFS=\$'\\t' read -r st sa <<<"\$s"
  [ "\$sa" != "\$4" ] || { echo "skip: \$1 は既に \$4 です"; return 1; }
  [ "\$st" = TERMINATED ] || { echo "!! \$1: \$st です。停止してから再実行: gcloud compute instances stop \$1 --zone=\$2 --project=\$3"; FAILED=\$((FAILED+1)); return 1; }
}
finish()   { echo; echo "=== end \$(date '+%F %T') failed=\$FAILED"; [ "\$FAILED" -eq 0 ]; }

HEADER
}

_row_banner() { # file line pid [display_name]
  printf '\n# ---- CSV %s 行目: %s%s ----\n' "$2" "$3" "${4:+ ($4)}" >>"$1"
}

export_project() {
  local f="$EXPORT_DIR/01_project.sh" pid i
  _export_header "$f" project "プロジェクト作成 → 課金アカウント紐づけ → API 有効化"
  local -a apis
  IFS=',' read -r -a apis <<<"$ENABLE_APIS"
  for pid in "${UNIQ_PIDS[@]}"; do
    i="${PID_ROW[$pid]}"
    _row_banner "$f" "${R_LINE[$i]}" "$pid" "${R_DISPLAY_NAME[$i]}"
    cmd_project_create "$pid" "${R_DISPLAY_NAME[$i]}"
    {
      printf 'if { exists gcloud projects describe %s && echo "skip: project %s exists"; } \\\n' "$pid" "$pid"
      printf '   || { run %s && wait_for gcloud projects describe %s; }; then\n' "$(cmdline)" "$pid"
      cmd_billing_link "$pid";                 printf '  run %s\n' "$(cmdline)"
      cmd_services_enable "$pid" "${apis[@]}"; printf '  run %s\n' "$(cmdline)"
      printf 'else echo "!! %s: プロジェクト作成に失敗したため課金・API をスキップ"\nfi\n' "$pid"
    } >>"$f"
  done
  printf '\nfinish\n' >>"$f"
  chmod +x "$f"
  info "生成: $f"
}

export_sa() {
  local f="$EXPORT_DIR/02_sa.sh" pid i email
  _export_header "$f" sa "サービスアカウント作成"
  for pid in "${UNIQ_PIDS[@]}"; do
    i="${PID_ROW[$pid]}"
    email="$(sa_email_of "$pid")"
    _row_banner "$f" "${R_LINE[$i]}" "$pid"
    cmd_sa_create "$pid" "${R_SA_NAME[$i]}"
    {
      printf 'if exists gcloud iam service-accounts describe %s --project=%s; then echo "skip: %s exists"\n' "$email" "$pid" "$email"
      printf 'else run %s \\\n' "$(cmdline)"
      printf '  && wait_for gcloud iam service-accounts describe %s --project=%s\nfi\n' "$email" "$pid"
    } >>"$f"
  done
  printf '\nfinish\n' >>"$f"
  chmod +x "$f"
  info "生成: $f"
}

export_firewall() {
  local f="$EXPORT_DIR/03_firewall.sh" pid i email rule ranges rules
  _export_header "$f" firewall "Shared VPC ホスト (${FW_PROJECT_ID}) に EGRESS ルール作成"
  for pid in "${UNIQ_PIDS[@]}"; do
    i="${PID_ROW[$pid]}"
    email="$(sa_email_of "$pid")"
    rule="$(fw_rule_of "$pid")"
    ranges="${R_FW_DEST_RANGES[$i]//;/,}"
    rules="${R_FW_ALLOW[$i]//;/,}"
    _row_banner "$f" "${R_LINE[$i]}" "$pid"
    {
      printf 'if ! exists gcloud iam service-accounts describe %s --project=%s; then echo "!! %s: SA %s がありません。02_sa.sh を先に実行"; FAILED=$((FAILED+1))\n' "$email" "$pid" "$pid" "$email"
      printf 'elif exists gcloud compute firewall-rules describe %s --project=%s; then\n' "$rule" "$FW_PROJECT_ID"
      cmd_fw_update "$rule" "$email" "$ranges" "$rules" "$pid"; printf '  run %s\n' "$(cmdline)"
      printf 'else\n'
      cmd_fw_create "$rule" "$email" "$ranges" "$rules" "$pid"; printf '  run %s\n' "$(cmdline)"
      printf 'fi\n'
    } >>"$f"
  done
  printf '\nfinish\n' >>"$f"
  chmod +x "$f"
  info "生成: $f"
}

export_gce() {
  local f="$EXPORT_DIR/04_gce.sh" i pid email inst zone agent
  agent="$(compute_agent_of_gce_project)"
  _export_header "$f" gce "GCE (${GCE_PROJECT_ID}) に SA を紐づけ"
  cat >>"$f" <<NOTE
# 前提（このスクリプトは行いません）:
#   1. 各インスタンスが停止 (TERMINATED) していること。起動中の行はスキップして FAILED に数えます
#   2. GCE プロジェクトの Compute サービスエージェント
#        ${agent}
#      に、各 SA への roles/iam.serviceAccountTokenCreator が付与されていること
#      （未付与なら各行のコメントにあるコマンドを先に実行してください）
NOTE
  for ((i = 1; i <= N_ROWS; i++)); do
    [ -n "${R_GCE_INSTANCE[$i]}" ] || continue
    pid="${R_PROJECT_ID[$i]}"
    email="$(sa_email_of "$pid")"
    inst="${R_GCE_INSTANCE[$i]}"
    zone="${R_GCE_ZONE[$i]}"
    _row_banner "$f" "${R_LINE[$i]}" "$pid"
    cmd_gce_set_sa "$inst" "$zone" "$email"
    {
      printf '# 未付与なら: gcloud iam service-accounts add-iam-policy-binding %s --project=%s --member=%s --role=roles/iam.serviceAccountTokenCreator\n' "$email" "$pid" "$agent"
      printf 'if vm_ready %s %s %s %s; then\n' "$inst" "$zone" "$GCE_PROJECT_ID" "$email"
      printf '  run %s\n' "$(cmdline)"
      printf 'fi\n'
    } >>"$f"
  done
  printf '\nfinish\n' >>"$f"
  chmod +x "$f"
  info "生成: $f"
}

export_destroy() {
  local f="$EXPORT_DIR/90_destroy.sh" i pid email inst zone rule restore
  restore="$(restore_sa)"
  _export_header "$f" destroy "後片付け: GCE の SA を既定に戻す → FW ルール削除 → プロジェクト削除"
  {
    printf 'echo "以下のプロジェクトを削除します（SA も一緒に消えます）:"\n'
    for pid in "${UNIQ_PIDS[@]}"; do printf 'echo "    %s"\n' "$pid"; done
    printf 'if [ "${1:-}" != "--yes" ]; then read -r -p "続行するには yes と入力: " a; [ "$a" = yes ] || { echo "中止"; exit 1; }; fi\n'
    printf '\n# ---- 1. GCE の SA を %s に戻す ----\n' "$restore"
    for ((i = 1; i <= N_ROWS; i++)); do
      [ -n "${R_GCE_INSTANCE[$i]}" ] || continue
      pid="${R_PROJECT_ID[$i]}"; email="$(sa_email_of "$pid")"; inst="${R_GCE_INSTANCE[$i]}"; zone="${R_GCE_ZONE[$i]}"
      cmd_gce_set_sa "$inst" "$zone" "$restore"
      printf '# CSV %s 行目: %s\n' "${R_LINE[$i]}" "$pid"
      printf 'if [ "$(gcloud compute instances describe %s --zone=%s --project=%s --format='"'"'value(serviceAccounts[0].email)'"'"' 2>/dev/null)" = %s ]; then\n' "$inst" "$zone" "$GCE_PROJECT_ID" "$email"
      printf '  if vm_ready %s %s %s %s; then run %s; fi\n' "$inst" "$zone" "$GCE_PROJECT_ID" "$restore" "$(cmdline)"
      printf 'else echo "skip: %s は %s ではない"; fi\n' "$inst" "$email"
    done
    printf '\n# ---- 2. FW ルール削除 ----\n'
    for pid in "${UNIQ_PIDS[@]}"; do
      rule="$(fw_rule_of "$pid")"
      cmd_fw_delete "$rule"
      printf 'if exists gcloud compute firewall-rules describe %s --project=%s; then run %s; else echo "skip: %s なし"; fi\n' "$rule" "$FW_PROJECT_ID" "$(cmdline)" "$rule"
    done
    printf '\n# ---- 3. プロジェクト削除（30 日間は復元可能） ----\n'
    for pid in "${UNIQ_PIDS[@]}"; do
      cmd_project_delete "$pid"
      printf 'if [ "$(gcloud projects describe %s --format='"'"'value(lifecycleState)'"'"' 2>/dev/null)" = ACTIVE ]; then run %s; else echo "skip: %s なし"; fi\n' "$pid" "$(cmdline)" "$pid"
    done
    printf '\nfinish\n'
  } >>"$f"
  chmod +x "$f"
  info "生成: $f"
}

export_all() {
  EXPORT_AT="$(date '+%Y-%m-%d %H:%M:%S')"
  CSV_SHA256="$(sha256sum "$CSV_FILE" 2>/dev/null | cut -c1-64 || shasum -a 256 "$CSV_FILE" | cut -c1-64)"
  cp "$CSV_FILE" "$EXPORT_DIR/input.csv"

  should_run project  && export_project
  should_run sa       && export_sa
  should_run firewall && export_firewall
  should_run gce      && export_gce
  [ -n "$ONLY_PHASE" ] || export_destroy

  cat >"$EXPORT_DIR/README.txt" <<README
provision.sh export で生成した実行スクリプト

生成日時 : ${EXPORT_AT}
生成者   : ${ACTIVE_ACCOUNT}
生成元   : ${CSV_FILE}
  sha256 : ${CSV_SHA256}
  コピー : input.csv（このフォルダ）
行数     : ${N_ROWS} 行 / プロジェクト ${#UNIQ_PIDS[@]} 件

設定 (config.env):
  PARENT_FOLDER_ID   = ${PARENT_FOLDER_ID}
  PARENT_ORG_ID      = ${PARENT_ORG_ID}
  BILLING_ACCOUNT_ID = ${BILLING_ACCOUNT_ID}
  ENABLE_APIS        = ${ENABLE_APIS}
  FW_PROJECT_ID      = ${FW_PROJECT_ID}
  FW_NETWORK         = ${FW_NETWORK}
  FW_RULE_PREFIX     = ${FW_RULE_PREFIX}
  FW_PRIORITY        = ${FW_PRIORITY}
  GCE_PROJECT_ID     = ${GCE_PROJECT_ID} (番号 ${GCE_PROJECT_NUMBER})
  SA_SCOPES          = ${SA_SCOPES}

実行順:
  bash 01_project.sh    プロジェクト作成・課金・API
  bash 02_sa.sh         SA 作成
  (手動) Compute サービスエージェントへの TokenCreator 付与  ※04 の各行コメント参照
  (手動) 対象 GCE の停止
  bash 03_firewall.sh   FW ルール
  bash 04_gce.sh        GCE への SA 紐づけ
  bash 90_destroy.sh    後片付け（検証終了後）

各スクリプトは実行のたびに <名前>.<日時>.log を同じ場所に残します。
実行後の状態確認と証跡は provision.sh evidence で取得してください:
  ./provision.sh evidence input.csv

CSV を直した場合はこのフォルダを使い回さず、export し直してください。
README
  info "生成: $EXPORT_DIR/README.txt"
  echo >&2
  info "==== export 完了: $EXPORT_DIR ===="
  ls -1 "$EXPORT_DIR" >&2
}
