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
TIMEOUT_SECONDS=900
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

# --- サブエージェント（$BASE_BRANCH を動的に注入） ---
DIFF_GATE="【最重要ルール】報告する全ての issue は git diff origin/${BASE_BRANCH}...HEAD の追加/変更行（+行）に直接関係するもののみ。変更ファイル内であっても diff に含まれない行の問題は報告禁止。「既存バグ（PR外）」「既存問題」カテゴリは使用禁止。severity は Critical と Warning のみ使用（Info は廃止）。"

AGENTS=$(cat <<AGENTEOF
{
  "security-reviewer": {
    "description": "セキュリティ脆弱性の専門家。コードのセキュリティ問題を検出する。",
    "prompt": "${DIFF_GATE} あなたはセキュリティの専門家です。まず git diff origin/${BASE_BRANCH}...HEAD で差分を確認し、追加/変更された行のみを対象に以下の観点でレビューしてください：SQLインジェクション、XSS、認証・認可の漏れ、機密情報のハードコード、CSRF、安全でない依存パッケージ。内部API（内部gRPC等）には外部公開APIレベルの対策を要求しない。各問題にファイル名・行番号・修正案を付けてください。確実な脆弱性のみ報告し、可能性レベルの懸念は報告しない。問題がなければ「セキュリティ問題なし」と報告してください。",
    "tools": ["Read","Grep","Glob"],
    "model": "sonnet"
  },
  "bug-detector": {
    "description": "バグ・ロジックエラー・デグレの検出専門家。",
    "prompt": "${DIFF_GATE} あなたはバグ検出とデグレ防止の専門家です。まず git diff origin/${BASE_BRANCH}...HEAD で差分を確認してください。差分の追加/変更行を対象に以下の観点でレビューしてください：論理ミス、エッジケースの未処理、null/undefinedの未チェック、Off-by-oneエラー、非同期処理のエラー。さらに変更された関数の呼び出し元をGrepで特定し、デグレがないか確認してください。【検証ルール】型の不一致を報告する前にランタイムの型変換仕様を確認する（例: Intl.NumberFormat.format() は string を受け付ける）。typecheckが通る問題は報告しない。デフォルト引数の問題を指摘する前に他の引数（maximumSignificantDigits等）との相互作用を確認する。「〜の可能性がある」レベルの懸念は報告しない。呼び出し元でバリデーション済みなら重複チェックを要求しない。import先の型定義や実際のコードを必ず確認してから報告する。",
    "tools": ["Read","Grep","Glob","Bash"],
    "model": "sonnet"
  },
  "compatibility-checker": {
    "description": "既存コードおよび関連リポジトリとの互換性・整合性チェックの専門家。",
    "prompt": "${DIFF_GATE} あなたは既存コードとの互換性チェックの専門家です。まず git diff origin/${BASE_BRANCH}...HEAD で差分を確認してください。変更されたファイルのimport先、呼び出し元をGrepで調査し、以下を確認してください：既存の関数シグネチャとの互換性、インターフェース・型定義との整合性、変更された関数の呼び出し元が正しく動作するか。【重要】PRは挙動を変更するために作られる。PRタイトル・説明の意図に沿った挙動変更は問題として報告しない。報告すべきは「PRの意図から外れた意図しない副作用」のみ。既存パターンは尊重し問題として指摘しない。モック生成等CIで自動実行されるものは手動確認を要求しない。関連リポジトリが指定されている場合は git show で確認し、互換性もチェックしてください。",
    "tools": ["Read","Grep","Glob","Bash"],
    "model": "sonnet"
  },
  "performance-reviewer": {
    "description": "パフォーマンスとコード品質の専門家。",
    "prompt": "${DIFF_GATE} あなたはパフォーマンスの専門家です。まず git diff origin/${BASE_BRANCH}...HEAD で差分を確認してください。差分の追加/変更行のみを対象に以下の観点でレビューしてください：N+1クエリ、不要なループや再計算、メモリリーク、不要なリレンダリング。【報告しないもの】差分外の改善提案、既存パターンと一貫している実装、「大量データの場合に〜」という仮定に基づく懸念（実測データがない場合）、DOM構造の理論的な問題、スタイル・命名の提案。テストカバレッジは全レイヤーで確認し、いずれかで検証済みであれば不足と指摘しない。",
    "tools": ["Read","Grep","Glob"],
    "model": "sonnet"
  }
}
AGENTEOF
)

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

# レビュー指示（オーケストレーター用）
# NOTE: INSTREOF は変数展開なし（シングルクォート）で安全
cat >> "$PROMPT_FILE" << 'INSTREOF'

## 指示

4つの専門サブエージェントを並列で起動してレビューしてください：
1. security-reviewer: セキュリティ脆弱性の検出
2. bug-detector: バグ・ロジックエラーの検出
3. compatibility-checker: 既存コード＋関連リポとの互換性チェック
4. performance-reviewer: パフォーマンス・コード品質チェック

各エージェントは git diff の差分と、関連する既存ファイル・依存パッケージを参照してレビューしてください。

## 統合時のフィルタリングルール（厳守）

全エージェントの結果を受け取った後、以下の基準で各 issue をフィルタリングしてください：

### 除外する issue（最終出力に含めない）
1. **diff外の issue**: file と line が git diff の追加/変更行に該当しない issue
2. **「既存バグ（PR外）」カテゴリ**: PRスコープ外の既存コードの指摘
3. **理論的・推測的な問題**: 「〜の可能性がある」「〜かもしれない」レベルの懸念
4. **typecheckが検出すべき型問題**: ランタイムで暗黙の型変換が行われ実害がない場合
5. **既存パターンへの問題提起**: コードベースで広く使われている手法への指摘
6. **スタイル・命名・リファクタ提案**: コード改善の提案は全て除外
7. **Info severity の issue**: Info は廃止。従来 Info だった内容は全て除外

### severity の再評価
- sub-agent が Critical とした issue でも、再現手順を具体的に示せない場合は除外するか Warning に降格する
- 複数エージェントが矛盾する指摘をした場合（例: bug-detector が「バグ」、compatibility-checker が「正常」）、より深くコードを調査したエージェントの結論を採用する
- 意図的な挙動変更（PRタイトル・説明と整合する変更）は Warning にしない

### 検証ステップ（フィルタリング後、出力前に必ず実行）

フィルタリングで残った各 issue に対して、以下の検証を**あなた自身で**実行してください：

1. **呼び出しパスの実証**: 指摘した問題が実際に到達可能か、呼び出し元を Grep で辿り、エントリポイントからの具体的な実行パスを確認する。上位レイヤーにバリデーション・ガードがある場合、そのガードを通過して問題箇所に到達するケースが実在するか検証する
2. **条件の網羅確認**: 「この条件でバグが起きる」と指摘する場合、その条件で実際にコードが実行されるか（呼び出し元のバリデーション、前段の分岐、型制約等で到達不能でないか）を確認する
3. **検証結果の反映**:
   - 到達不能と判明 → issue を除外
   - 到達可能だが上位でガード済み → severity を Warning に降格し、description に「現在は○○でガードされているが」と明記
   - 確実に到達可能で問題が再現する → Critical を維持し、具体的な再現パスを description に記載

この検証には Read, Grep, Glob, Bash ツールを使ってください。推測ではなく、コードを実際に読んで判断してください。

## 出力フォーマット

以下のJSON形式で出力してください：

{
  "summary": "PRの概要と全体的な評価（1〜2文）",
  "score": "A / B / C / D（Aが最良）",
  "change_impact": {
    "description": "この変更がランタイムで実際に何を変えるかの説明",
    "affected_components": ["影響を受けるコンポーネント/関数"],
    "behavioral_changes": [
      {"before": "変更前の挙動", "after": "変更後の挙動", "intentional": true}
    ]
  },
  "issues": [
    {
      "severity": "Critical / Warning",
      "category": "カテゴリ名",
      "file": "ファイルパス",
      "line": "行番号または範囲",
      "description": "問題の説明（Critical の場合は再現手順を含む）",
      "suggestion": "修正案"
    }
  ],
  "good_points": ["良い点1", "良い点2"],
  "needs_manual_review": true/false,
  "manual_review_reason": "手動レビューが必要な理由（該当する場合）"
}
INSTREOF

# --- Claude Code 実行（プロンプトはファイルから読み込み） ---
echo "[$(date)] Claude Code 実行開始 PR#${PR_NUMBER}" >> "$ERROR_LOG"
set +e
REVIEW_RESULT=$(timeout "$TIMEOUT_SECONDS" claude -p "$(cat "$PROMPT_FILE")" \
  $PROMPT_FLAG \
  --agents "$AGENTS" \
  --output-format json \
  --allowedTools "Read,Grep,Glob,Bash" \
  2>>"$ERROR_LOG")
CLAUDE_EXIT=$?
set -e
echo "[$(date)] Claude Code 終了 exit_code=${CLAUDE_EXIT}" >> "$ERROR_LOG"

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  # CLI stdout にエラー詳細が含まれる場合があるのでログに記録
  echo "[$(date)] Claude CLI stdout (先頭500文字): ${REVIEW_RESULT:0:500}" >> "$ERROR_LOG"
  if [ "$CLAUDE_EXIT" -eq 124 ]; then
    ERROR_MSG="タイムアウト（${TIMEOUT_SECONDS}秒超過）"
  else
    ERROR_MSG="Claude CLI実行失敗（exit_code=${CLAUDE_EXIT}）"
  fi
  echo "{\"error\": \"${ERROR_MSG}\", \"failed\": true, \"exit_code\": ${CLAUDE_EXIT}}"
  exit 1
fi

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
