#!/bin/bash
# コンテナ起動時に Claude の認証を自動設定

# CLAUDE_TOKEN が設定されていれば setup-token を実行（TTY が必要なため script で擬似TTY提供）
if [ -n "${CLAUDE_TOKEN:-}" ]; then
  printenv CLAUDE_TOKEN | script -qc "claude setup-token" /dev/null 2>/dev/null || true
  echo "Claude authentication configured."
fi

# メインプロセス（コンテナを生かしておく）
exec tail -f /dev/null
