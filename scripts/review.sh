#!/bin/bash
set -euo pipefail

# =========================================
# 入力: base64エンコードされたJSON（#1,#6対策: シェルインジェクション防止）
# =========================================
if [ -z "${1:-}" ]; then
  echo '{"error": "引数が必要です（base64エンコードされたJSON）", "failed": true}'
  exit 1
fi

PR_JSON=$(echo "$1" | base64 -d 2>/dev/null) || {
  echo '{"error": "base64デコードに失敗", "failed": true}'
  exit 1
}

REPO_NAME=$(echo "$PR_JSON" | jq -r '.repo_name // empty')
PR_BRANCH=$(echo "$PR_JSON" | jq -r '.head_ref // empty')
BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.base_ref // empty')
PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // empty')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // empty')
PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number // empty')

if [ -z "$REPO_NAME" ] || [ -z "$PR_BRANCH" ] || [ -z "$BASE_BRANCH" ]; then
  echo '{"error": "必須フィールドが不足しています", "failed": true}'
  exit 1
fi

# --- #10対策: コンテナ内UIDとホスト側UIDが異なるためGitが拒否する問題を回避 ---
git config --global --add safe.directory '*' 2>/dev/null || true

# --- HTTPS認証: GITHUB_TOKEN があれば git credential に設定 ---
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > ~/.git-credentials
  chmod 600 ~/.git-credentials
fi

REPO_PATH="/repos/${REPO_NAME}"
LOG_DIR="/home/reviewer/claude-reviews"
TIMEOUT_SECONDS=600
WORKTREE_BASE="/tmp/claude-review"
LOCK_DIR="/tmp/claude-review-locks"
FALLBACK="${FALLBACK_BRANCH:-develop}"

mkdir -p "$LOG_DIR" "$WORKTREE_BASE" "$LOCK_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_REPO=$(echo "$REPO_NAME" | tr '/' '_')
LOG_FILE="$LOG_DIR/review_${SAFE_REPO}_PR${PR_NUMBER:-unknown}_${TIMESTAMP}.json"
ERROR_LOG="$LOG_DIR/error_${SAFE_REPO}_PR${PR_NUMBER:-unknown}_${TIMESTAMP}.log"

# --- #7対策: 30日以上前のログを削除 ---
find "$LOG_DIR" -name "review_*.json" -mtime +30 -delete 2>/dev/null || true
find "$LOG_DIR" -name "error_*.log" -mtime +30 -delete 2>/dev/null || true
find "$LOG_DIR" -name "meta_*.json" -mtime +30 -delete 2>/dev/null || true

output_error() {
  local msg="$1"
  echo "{\"error\": \"${msg}\", \"failed\": true}"
  echo "[$(date)] ERROR: ${msg}" >> "$ERROR_LOG"
  exit 1
}

if [ ! -d "$REPO_PATH/.git" ]; then
  output_error "Gitリポジトリが見つかりません: $REPO_PATH"
fi

# --- #5対策: 同じPRの二重実行防止 ---
PR_LOCK="$LOCK_DIR/${SAFE_REPO}_PR${PR_NUMBER:-unknown}.lock"
exec 201>"$PR_LOCK"
if ! flock -n 201; then
  echo '{"error": "このPRは既にレビュー中です", "failed": true, "concurrent": true}'
  exit 0
fi

# --- SSH URL → HTTPS URL 自動変換（コンテナにSSHキーがないため） ---
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURRENT_URL=$(cd "$REPO_PATH" && git remote get-url origin 2>/dev/null || true)
  if echo "$CURRENT_URL" | grep -q '^git@github\.com:'; then
    HTTPS_URL=$(echo "$CURRENT_URL" | sed 's|^git@github\.com:|https://github.com/|' | sed 's|\.git$||').git
    (cd "$REPO_PATH" && git remote set-url origin "$HTTPS_URL") 2>>"$ERROR_LOG" || true
  fi
fi

# --- #5対策: git fetch をリポジトリ単位でロック ---
FETCH_LOCK="$LOCK_DIR/${SAFE_REPO}_fetch.lock"
(
  flock -w 60 200 || output_error "git fetch のロック取得に失敗"
  cd "$REPO_PATH"
  git fetch origin 2>>"$ERROR_LOG" || output_error "git fetch に失敗"
  git worktree prune 2>/dev/null || true
) 200>"$FETCH_LOCK"

# --- worktree 作成 ---
WORKTREE_DIR="${WORKTREE_BASE}/${SAFE_REPO}_PR${PR_NUMBER:-unknown}_$$"

cd "$REPO_PATH"
git worktree add "$WORKTREE_DIR" "origin/$PR_BRANCH" >>"$ERROR_LOG" 2>&1 || {
  output_error "worktree の作成に失敗: $PR_BRANCH"
}

cleanup() {
  cd /tmp 2>/dev/null || true
  if [ -d "$WORKTREE_DIR" ]; then
    cd "$REPO_PATH" 2>/dev/null || true
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  fi
  # PRロック解放
  flock -u 201 2>/dev/null || true
}
trap cleanup EXIT

cd "$WORKTREE_DIR"

# --- #3対策: node_modules の整合性チェック ---
PKG_WARNING=""
for dep_dir in node_modules vendor .venv; do
  if [ -d "$REPO_PATH/$dep_dir" ] && [ ! -e "$WORKTREE_DIR/$dep_dir" ]; then
    ln -s "$REPO_PATH/$dep_dir" "$WORKTREE_DIR/$dep_dir" 2>/dev/null || true
  fi
done

PKG_CHANGED=$(git diff "origin/${BASE_BRANCH}...HEAD" --name-only 2>/dev/null \
  | grep -E "^package(-lock)?\.json$|^yarn\.lock$|^pnpm-lock\.yaml$" || true)
if [ -n "$PKG_CHANGED" ]; then
  PKG_WARNING="⚠️ 注意: パッケージ定義ファイル（${PKG_CHANGED}）が変更されています。node_modules はマージ先ブランチのものを参照しているため、新しい依存パッケージの型定義が正確でない可能性があります。"
fi

for dep_dir in __pycache__ .next .nuxt dist build; do
  if [ -d "$REPO_PATH/$dep_dir" ] && [ ! -e "$WORKTREE_DIR/$dep_dir" ]; then
    ln -s "$REPO_PATH/$dep_dir" "$WORKTREE_DIR/$dep_dir" 2>/dev/null || true
  fi
done

# --- 差分情報 ---
DIFF_STAT=$(git diff "origin/${BASE_BRANCH}...HEAD" --stat 2>/dev/null || echo "差分取得失敗")
CHANGED_FILES=$(git diff "origin/${BASE_BRANCH}...HEAD" --name-only 2>/dev/null || echo "")
FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c '.' || echo "0")

# --- 関連リポジトリのブランチ解決 ---
RELATED_INFO=""
if [ -n "${RELATED_REPOS:-}" ]; then
  IFS=',' read -ra REPOS <<< "$RELATED_REPOS"
  for related in "${REPOS[@]}"; do
    related=$(echo "$related" | tr -d ' ')
    [ -z "$related" ] && continue
    [ "$related" = "$REPO_NAME" ] && continue

    RELATED_PATH="/repos/${related}"
    [ ! -d "$RELATED_PATH/.git" ] && continue

    # SSH URL → HTTPS URL 自動変換
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      REL_URL=$(cd "$RELATED_PATH" && git remote get-url origin 2>/dev/null || true)
      if echo "$REL_URL" | grep -q '^git@github\.com:'; then
        REL_HTTPS=$(echo "$REL_URL" | sed 's|^git@github\.com:|https://github.com/|' | sed 's|\.git$||').git
        (cd "$RELATED_PATH" && git remote set-url origin "$REL_HTTPS") 2>/dev/null || true
      fi
    fi

    RELATED_LOCK="$LOCK_DIR/$(echo "$related" | tr '/' '_')_fetch.lock"
    (
      flock -w 60 200 || true
      cd "$RELATED_PATH"
      git fetch origin 2>/dev/null || true
    ) 200>"$RELATED_LOCK"

    cd "$RELATED_PATH"
    REF_BRANCH=""
    if git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
      REF_BRANCH="$BASE_BRANCH"
    elif git rev-parse --verify "origin/$FALLBACK" >/dev/null 2>&1; then
      REF_BRANCH="$FALLBACK"
    else
      # どちらのブランチも存在しない場合はデフォルトブランチ
      REF_BRANCH=$(cd "$RELATED_PATH" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo "main")
    fi

    RELATED_INFO="${RELATED_INFO}
- ${related}: /repos/${related} の origin/${REF_BRANCH} を参照
  確認方法: cd /repos/${related} && git show origin/${REF_BRANCH}:ファイルパス"

    cd "$WORKTREE_DIR"
  done
fi

# --- プロンプト ---
PROMPT_FLAG=""
if [ -f "${WORKTREE_DIR}/.claude/review-prompt.md" ]; then
  PROMPT_FLAG="--append-system-prompt-file ${WORKTREE_DIR}/.claude/review-prompt.md"
elif [ -f "/prompts/review-prompt.md" ]; then
  PROMPT_FLAG="--append-system-prompt-file /prompts/review-prompt.md"
fi

# --- サブエージェント ---
AGENTS='{
  "security-reviewer": {
    "description": "セキュリティ脆弱性の専門家。コードのセキュリティ問題を検出する。",
    "prompt": "あなたはセキュリティの専門家です。以下の観点でコードをレビューしてください：SQLインジェクション、XSS、認証・認可の漏れ、機密情報のハードコード、CSRF、安全でない依存パッケージ。各問題にファイル名・行番号・修正案を付けてください。問題がなければ「セキュリティ問題なし」と報告してください。",
    "tools": ["Read","Grep","Glob"],
    "model": "sonnet"
  },
  "bug-detector": {
    "description": "バグとロジックエラーの検出専門家。",
    "prompt": "あなたはバグ検出の専門家です。以下の観点でコードをレビューしてください：論理ミス、エッジケースの未処理、null/undefinedの未チェック、Off-by-oneエラー、型の不一致、非同期処理のエラー。import先の型定義や実際のコードも確認してください。",
    "tools": ["Read","Grep","Glob","Bash"],
    "model": "sonnet"
  },
  "compatibility-checker": {
    "description": "既存コードおよび関連リポジトリとの互換性・整合性チェックの専門家。",
    "prompt": "あなたは既存コードとの互換性チェックの専門家です。変更されたファイルのimport先、呼び出し元を調査し、以下を確認してください：既存の関数シグネチャとの互換性、インターフェース・型定義との整合性、既存のユーティリティ関数との重複、既存コードと同じパターン・命名規則に従っているか。また、関連リポジトリが指定されている場合は、git show コマンドで関連リポの該当ブランチのコードを確認し、API型やインターフェースの互換性もチェックしてください。",
    "tools": ["Read","Grep","Glob","Bash"],
    "model": "sonnet"
  },
  "performance-reviewer": {
    "description": "パフォーマンスとコード品質の専門家。",
    "prompt": "あなたはパフォーマンスとコード品質の専門家です。以下の観点でコードをレビューしてください：N+1クエリ、不要なループや再計算、メモリリーク、不要なリレンダリング、エラーハンドリングの欠如、テストカバレッジの不足。",
    "tools": ["Read","Grep","Glob"],
    "model": "sonnet"
  }
}'

# --- #6対策: プロンプトを一時ファイルに書き出し（特殊文字対策） ---
# --- #3追加: heredocではなくprintfを使用（PRタイトル/本文にデリミタ文字列が含まれても安全）
PROMPT_FILE=$(mktemp /tmp/claude-review-prompt-XXXXXX.md)
trap 'rm -f "$PROMPT_FILE"; cleanup' EXIT

{
  printf '%s\n' "以下のPRをレビューしてください。"
  printf '\n'
  printf 'PR #%s: %s\n' "$PR_NUMBER" "$(echo "$PR_TITLE" | head -c 500)"
  printf '説明: %s\n' "$(echo "$PR_BODY" | head -c 2000)"
  printf '\n'
  printf 'マージ先: origin/%s\n' "$BASE_BRANCH"
  printf '\n'
  printf '変更ファイル一覧（%s件）:\n' "$FILE_COUNT"
  printf '%s\n' "$CHANGED_FILES"
  printf '\n'
  printf '変更の統計:\n'
  printf '%s\n' "$DIFF_STAT"
} > "$PROMPT_FILE"

# 関連リポ情報
if [ -n "$RELATED_INFO" ]; then
  {
    printf '\n## 関連リポジトリ\n\n'
    printf 'このPRのマージ先は origin/%s です。\n' "$BASE_BRANCH"
    printf '以下の関連リポジトリのコードも確認してください。\n'
    printf '%s\n' "$RELATED_INFO"
    printf '\n特に以下を確認してください：\n'
    printf '%s\n' "- API型定義やインターフェースの変更が関連リポと互換性があるか"
    printf '%s\n' "- 関連リポ側で使っている関数やエンドポイントが壊れないか"
    printf '%s\n' "- 共有している型定義やconstantsに不整合がないか"
    printf '\n%s\n' "確認には cd /repos/{リポ名} && git show origin/{ブランチ}:ファイルパス を使ってください。"
  } >> "$PROMPT_FILE"
fi

# パッケージ変更警告
if [ -n "$PKG_WARNING" ]; then
  {
    printf '\n## 依存パッケージの変更検出\n'
    printf '%s\n' "$PKG_WARNING"
    printf '%s\n' "新しい依存パッケージに関する型の問題がある場合は、needs_manual_review を true にしてください。"
  } >> "$PROMPT_FILE"
fi

# レビュー指示
cat >> "$PROMPT_FILE" << 'INSTREOF'

## 指示

4つの専門サブエージェントを並列で起動してレビューしてください：
1. security-reviewer: セキュリティ脆弱性の検出
2. bug-detector: バグ・ロジックエラーの検出
3. compatibility-checker: 既存コード＋関連リポとの互換性チェック
4. performance-reviewer: パフォーマンス・コード品質チェック

各エージェントは git diff の差分と、関連する既存ファイル・依存パッケージを参照してレビューしてください。

全エージェントの結果を統合し、以下のJSON形式で出力してください：

{
  "summary": "PRの概要と全体的な評価（1〜2文）",
  "score": "A / B / C / D（Aが最良）",
  "issues": [
    {
      "severity": "Critical / Warning / Info",
      "category": "カテゴリ名",
      "file": "ファイルパス",
      "line": "行番号または範囲",
      "description": "問題の説明",
      "suggestion": "修正案"
    }
  ],
  "good_points": ["良い点1", "良い点2"],
  "needs_manual_review": true/false,
  "manual_review_reason": "手動レビューが必要な理由（該当する場合）"
}
INSTREOF

# --- Claude Code 実行（プロンプトはファイルから読み込み） ---
REVIEW_RESULT=$(timeout "$TIMEOUT_SECONDS" claude -p "$(cat "$PROMPT_FILE")" \
  $PROMPT_FLAG \
  --agents "$AGENTS" \
  --output-format json \
  --allowedTools "Read,Grep,Glob,Bash" \
  2>>"$ERROR_LOG") || {
    echo '{"error": "タイムアウトまたは実行失敗", "failed": true}'
    exit 1
  }

# --- ログ保存（Claude の生出力） ---
echo "$REVIEW_RESULT" > "$LOG_FILE"

# --- Claude の --output-format json ラッパーからレビュー JSON を抽出 ---
# Claude出力: {"type":"result","result":"...テキスト...\n```json\n{...}\n```"}
# ここから内側のレビューJSONだけを取り出してn8nに返す

CLEAN_RESULT=$(echo "$REVIEW_RESULT" | jq -r '.result // empty' 2>/dev/null)

if [ -z "$CLEAN_RESULT" ]; then
  # jq でパースできない場合はそのまま返す
  echo "$REVIEW_RESULT"
  exit 0
fi

# ```json ... ``` ブロックからJSONを抽出
REVIEW_JSON=$(echo "$CLEAN_RESULT" | sed -n '/^```json/,/^```/p' | sed '1d;$d')

if [ -z "$REVIEW_JSON" ]; then
  # ```json ブロックがない場合、{ から始まるJSONを探す
  REVIEW_JSON=$(echo "$CLEAN_RESULT" | sed -n '/^{/,/^}/p')
fi

if [ -n "$REVIEW_JSON" ] && echo "$REVIEW_JSON" | jq empty 2>/dev/null; then
  # 有効なJSONならそのまま出力
  echo "$REVIEW_JSON"
else
  # JSONが取り出せない場合はClaude生出力を返す
  echo "$REVIEW_RESULT"
fi
