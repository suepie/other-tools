#!/usr/bin/env bash
#
# Excel から保存した CSV を読み込む。
#
# 吸収するもの:
#   - UTF-8 BOM
#   - CRLF
#   - ダブルクォートで囲まれたフィールド（中のカンマ・"" エスケープ）
#   - 各フィールド前後の半角/全角スペース・タブ
#   - 全列が空の行（Excel の末尾に残る「,,,,,,」の行）
#   - 列の並び順（ヘッダー名で対応づける）
#
# 読み込み結果は以下のグローバル配列に入る（添字 1..N_ROWS）:
#   R_PROJECT_ID R_DISPLAY_NAME R_SA_NAME R_FW_DEST_RANGES R_FW_ALLOW R_GCE_INSTANCE R_GCE_ZONE
#   R_LINE  (元ファイルの行番号。エラー表示用)
#

CSV_REQUIRED_COLUMNS=(project_id display_name sa_name fw_dest_ranges fw_allow gce_instance gce_zone)

# US (0x1F) をフィールド区切りにして awk から受け取る
CSV_SEP=$'\x1f'

csv_load() {
  local file="$1"

  [ -f "$file" ] || die "CSV が見つかりません: $file"

  # Shift-JIS など UTF-8 以外で保存されていると gcloud に渡す文字列が壊れるので先に弾く
  if ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
    die "CSV が UTF-8 ではありません。Excel では「CSV UTF-8 (コンマ区切り)」で保存してください: $file"
  fi

  local parsed
  parsed="$(
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$file" |
      awk -v SEP="$CSV_SEP" -v FW="　" '
        function trim(s,   n) {
          n = length(FW)
          while (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t" || substr(s, 1, n) == FW) {
            if (substr(s, 1, n) == FW) s = substr(s, n + 1); else s = substr(s, 2)
          }
          while (substr(s, length(s), 1) == " " || substr(s, length(s), 1) == "\t" || substr(s, length(s) - n + 1) == FW) {
            if (substr(s, length(s) - n + 1) == FW) s = substr(s, 1, length(s) - n); else s = substr(s, 1, length(s) - 1)
          }
          return s
        }
        function parse(line, out,   n, i, c, field, inq) {
          n = 0; field = ""; inq = 0
          for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inq) {
              if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                else inq = 0
              } else field = field c
            } else {
              if (c == "\"") inq = 1
              else if (c == ",") { out[++n] = trim(field); field = "" }
              else field = field c
            }
          }
          out[++n] = trim(field)
          return n
        }
        {
          n = parse($0, f)
          allempty = 1
          for (i = 1; i <= n; i++) if (f[i] != "") allempty = 0
          if (allempty) next
          printf "%d%s", NR, SEP
          for (i = 1; i <= n; i++) printf "%s%s", f[i], (i < n ? SEP : "")
          printf "\n"
        }
      '
  )"

  [ -n "$parsed" ] || die "CSV にデータがありません: $file"

  # ---- ヘッダー ----
  local header
  header="$(printf '%s\n' "$parsed" | head -1)"
  local -a hcols
  IFS="$CSV_SEP" read -r -a hcols <<<"$header"
  # hcols[0] は行番号

  declare -gA CSV_COL=()
  local i name
  for ((i = 1; i < ${#hcols[@]}; i++)); do
    name="$(printf '%s' "${hcols[$i]}" | tr '[:upper:]' '[:lower:]')"
    [ -n "$name" ] || continue
    [ -z "${CSV_COL[$name]:-}" ] || die "CSV のヘッダーに重複があります: $name"
    CSV_COL[$name]=$i
  done

  local missing=()
  for name in "${CSV_REQUIRED_COLUMNS[@]}"; do
    [ -n "${CSV_COL[$name]:-}" ] || missing+=("$name")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "CSV に必要な列がありません: ${missing[*]}  （ヘッダー: ${hcols[*]:1}）"
  fi
  local ncols=$(( ${#hcols[@]} - 1 ))

  # ---- データ行 ----
  declare -ga R_LINE=() R_PROJECT_ID=() R_DISPLAY_NAME=() R_SA_NAME=() R_FW_DEST_RANGES=() R_FW_ALLOW=() R_GCE_INSTANCE=() R_GCE_ZONE=()
  N_ROWS=0

  local line
  local -a cols
  while IFS= read -r line; do
    IFS="$CSV_SEP" read -r -a cols <<<"$line"
    local nf=$(( ${#cols[@]} - 1 ))
    if [ "$nf" -gt "$ncols" ]; then
      die "CSV ${cols[0]} 行目: 列数がヘッダーより多いです (${nf} > ${ncols})。カンマを含む値はダブルクォートで囲んでください"
    fi
    N_ROWS=$((N_ROWS + 1))
    R_LINE[$N_ROWS]="${cols[0]}"
    R_PROJECT_ID[$N_ROWS]="${cols[${CSV_COL[project_id]}]:-}"
    R_DISPLAY_NAME[$N_ROWS]="${cols[${CSV_COL[display_name]}]:-}"
    R_SA_NAME[$N_ROWS]="${cols[${CSV_COL[sa_name]}]:-}"
    R_FW_DEST_RANGES[$N_ROWS]="${cols[${CSV_COL[fw_dest_ranges]}]:-}"
    R_FW_ALLOW[$N_ROWS]="${cols[${CSV_COL[fw_allow]}]:-}"
    R_GCE_INSTANCE[$N_ROWS]="${cols[${CSV_COL[gce_instance]}]:-}"
    R_GCE_ZONE[$N_ROWS]="${cols[${CSV_COL[gce_zone]}]:-}"
  done < <(printf '%s\n' "$parsed" | tail -n +2)

  [ "$N_ROWS" -gt 0 ] || die "CSV にデータ行がありません（ヘッダーのみ）: $file"
}

# ---- 値の検証 ----------------------------------------------------------------

# GCP の ID 規則: 6〜30 文字、英小文字始まり、英小文字/数字/ハイフン、ハイフン終わり不可
_valid_gcp_id() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
}

# 10.0.0.0/8 形式（IPv4 CIDR）
_valid_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

# tcp:443 / tcp:8000-9000 / udp:53 / icmp / all
_valid_rule() {
  [[ "$1" =~ ^(tcp|udp|sctp)(:[0-9]{1,5}(-[0-9]{1,5})?)?$ ]] || [[ "$1" =~ ^(icmp|esp|ah|all)$ ]]
}

# 戻り値: エラー件数。エラーは err() で出す
csv_validate() {
  local errors=0
  local i
  declare -A seen_sa=() seen_dest=() seen_allow=() seen_name=() seen_gce=()

  _e() { err "CSV ${R_LINE[$i]} 行目 (project_id=${R_PROJECT_ID[$i]:-?}): $*"; errors=$((errors + 1)); }

  for ((i = 1; i <= N_ROWS; i++)); do
    local pid="${R_PROJECT_ID[$i]}"

    [ -n "$pid" ] || { _e "project_id が空です"; continue; }
    _valid_gcp_id "$pid" || _e "project_id が不正です (6〜30 文字、英小文字始まり、英小文字/数字/ハイフン、ハイフン終わり不可): $pid"

    [ -n "${R_DISPLAY_NAME[$i]}" ] || _e "display_name が空です"

    local sa="${R_SA_NAME[$i]}"
    [ -n "$sa" ] || _e "sa_name が空です"
    [ -z "$sa" ] || _valid_gcp_id "$sa" || _e "sa_name が不正です (6〜30 文字、英小文字始まり、英小文字/数字/ハイフン): $sa"

    local rule_name="${FW_RULE_PREFIX}-${pid}"
    [ ${#rule_name} -le 63 ] || _e "FW ルール名が 63 文字を超えます: $rule_name"

    local v item
    v="${R_FW_DEST_RANGES[$i]}"
    [ -n "$v" ] || _e "fw_dest_ranges が空です"
    IFS=';' read -r -a _items <<<"$v"
    for item in "${_items[@]}"; do
      [ -z "$item" ] || _valid_cidr "$item" || _e "fw_dest_ranges に不正な CIDR があります: $item"
    done

    v="${R_FW_ALLOW[$i]}"
    [ -n "$v" ] || _e "fw_allow が空です"
    IFS=';' read -r -a _items <<<"$v"
    for item in "${_items[@]}"; do
      [ -z "$item" ] || _valid_rule "$item" || _e "fw_allow に不正な指定があります (例: tcp:443, udp:53, icmp): $item"
    done

    local inst="${R_GCE_INSTANCE[$i]}" zone="${R_GCE_ZONE[$i]}"
    if [ -n "$inst" ]; then
      [ -n "$zone" ] || _e "gce_instance を指定する場合は gce_zone も必要です"
      [ -z "$zone" ] || [[ "$zone" =~ ^[a-z]+-[a-z0-9]+-[a-z]$ ]] || _e "gce_zone の形式が不正です (例: asia-northeast1-a): $zone"
      local key="${zone}/${inst}"
      if [ -n "${seen_gce[$key]:-}" ]; then
        _e "同じ GCE インスタンスが ${seen_gce[$key]} 行目にもあります: $key"
      fi
      seen_gce[$key]="${R_LINE[$i]}"
    elif [ -n "$zone" ]; then
      warn "CSV ${R_LINE[$i]} 行目: gce_instance が空なので gce_zone は無視します"
    fi

    # 同じ project_id の行が複数ある場合（1 プロジェクトに複数 GCE）は、
    # project/sa/fw の値が揃っていなければならない
    if [ -n "${seen_sa[$pid]:-}" ]; then
      [ "${seen_sa[$pid]}" = "$sa" ] || _e "同じ project_id なのに sa_name が他の行と違います"
      [ "${seen_name[$pid]}" = "${R_DISPLAY_NAME[$i]}" ] || _e "同じ project_id なのに display_name が他の行と違います"
      [ "${seen_dest[$pid]}" = "${R_FW_DEST_RANGES[$i]}" ] || _e "同じ project_id なのに fw_dest_ranges が他の行と違います"
      [ "${seen_allow[$pid]}" = "${R_FW_ALLOW[$i]}" ] || _e "同じ project_id なのに fw_allow が他の行と違います"
      [ -n "$inst" ] || _e "同じ project_id の行が複数あるのに gce_instance が空です"
    else
      seen_sa[$pid]="$sa"
      seen_name[$pid]="${R_DISPLAY_NAME[$i]}"
      seen_dest[$pid]="${R_FW_DEST_RANGES[$i]}"
      seen_allow[$pid]="${R_FW_ALLOW[$i]}"
    fi
  done

  return "$errors"
}
