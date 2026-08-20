#!/usr/bin/env bash
#
# コンテナ作成後の初期化。
# このリポジトリには依存パッケージのインストールが必要なものがないので、
# 主にツールが揃っているかの確認をします。
#
set -uo pipefail

echo "=== other-tools devcontainer setup ==="

# Windows ホストからのバインドマウントだと所有者が食い違って git が警告を出すことがある
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true

check() {
  local name="$1"
  shift
  if command -v "$1" >/dev/null 2>&1; then
    printf '  %-24s %s\n' "$name" "$("$@" 2>&1 | head -1)"
  else
    printf '  %-24s NOT FOUND\n' "$name"
  fi
}

echo ""
echo "--- ツール ---"
check "Terraform"              terraform version
check "AWS CLI"                aws --version
check "Session Manager plugin" session-manager-plugin --version
check "PowerShell"             pwsh --version
check "uvx"                    uvx --version

# git-forge-aws は Terraform 1.11 以降が必要
if command -v terraform >/dev/null 2>&1; then
  tf_ver="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p')"
  if [ -n "$tf_ver" ]; then
    major="${tf_ver%%.*}"
    rest="${tf_ver#*.}"
    minor="${rest%%.*}"
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 11 ]; }; then
      echo ""
      echo "  WARNING: git-forge-aws は Terraform 1.11 以降が必要です (現在 $tf_ver)"
    fi
  fi
fi

echo ""
echo "--- AWS 認証 ---"
if [ -f "$HOME/.aws/config" ]; then
  # grep -c は 0 件のとき "0" を出力したうえで終了コード 1 を返すため、
  # `|| echo 0` を付けると 0 が二重に出てしまう
  profiles="$(grep -c '^\[profile ' "$HOME/.aws/config" 2>/dev/null || true)"
  [ -n "$profiles" ] || profiles=0
  echo "  ~/.aws/config が見つかりました（プロファイル $profiles 件）"
  echo "  使うときは: aws sso login --profile <name> && export AWS_PROFILE=<name>"
else
  echo "  ~/.aws/config がありません。まず 'aws configure sso' を実行してください。"
fi

echo ""
echo "=== 完了 ==="
