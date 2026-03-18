# n8n × Claude Code ローカル自動PRレビュー

GitHub の Pull Request を Claude Code が自動レビューし、結果を Slack にスレッド形式で投稿するシステム。
再レビュー時は Slack チャンネルから既存スレッドを検索して追記する。レビュー詳細は Markdown ファイルとしてスレッドに添付される。

## アーキテクチャ

```
┌────────── ローカルのみ（外部公開なし） ──────────┐
│                                                   │
│  n8n（ポーリング）                                 │
│    ├── GitHub API でPR一覧取得                     │
│    ├── Draft スキップ                              │
│    ├── レビュアー/チームフィルタ（tracked で追跡）   │
│    ├── head.sha で重複防止（同一SHA永久スキップ）    │
│    ├── inProgress で二重実行防止                    │
│    ├── base64 エンコードで安全に引数渡し            │
│    ├── 失敗時 → Slack にエラー通知（最大3回リトライ） │
│    ├── 同時実行中 → スキップ                        │
│    │                                              │
│    ▼                                              │
│  claude-runner（git worktree でPRごとに隔離）      │
│    ├── SSH URL → HTTPS URL 自動変換               │
│    ├── CLAUDE.md / .claude/ 自動読み込み           │
│    ├── node_modules → シンボリックリンク            │
│    ├── 関連リポのマージ先ブランチも確認             │
│    ├── flock でリポ単位の排他制御                   │
│    ├── 🔒 security-reviewer（並列）                │
│    ├── 🐛 bug-detector（並列）                    │
│    ├── 🔗 compatibility-checker（並列）            │
│    └── ⚡ performance-reviewer（並列）             │
│                                                   │
│  n8n → Slack API で直接投稿                        │
│    ├── CheckThread: チャンネルの直近50件を検索       │
│    │   （PR番号 + リポ名で既存スレッドを特定）       │
│    └── PostToSlack: スレッド投稿 + Markdown添付     │
│        ├── 既存スレッドあり → スレッドに追記         │
│        └── なし → 新規親スレッド作成                │
└───────────────────────────────────────────────────┘
```

**ワークフロー (n8n ノード構成):**

```
Schedule(1分間隔) → RepoList → GitHubAPI(PR取得) → Filter(重複・レビュアー判定)
→ PrepareInput → Review(docker exec) → ParseResult → SkipCheck
→ CheckThread(Slack検索) → PostToSlack(投稿 + Markdown添付)
```

分岐なし。全ノードが直列に接続。Credential 設定不要（全て .env の環境変数で動作）。

---

## 前提条件

- **Docker** および **Docker Compose** がインストール済み
- **GitHub Personal Access Token** (classic) — `repo` スコープが必要
- **Claude 認証トークン** (OAuth Token) — Claude Max/Pro サブスクリプションが必要（追加料金なし）
- **Slack Bot Token** — Slack App を作成して取得
- **監視対象リポジトリがローカルに clone 済み**

---

## ディレクトリ構成

```
claude-pr-review/
├── docker-compose.yml
├── Dockerfile.n8n           ← n8n + Docker CLI
├── Dockerfile.claude        ← Claude Code ネイティブインストーラー
├── .env                     ← 環境変数（各自で設定）
├── n8n/
│   └── workflow.json        ← n8n にインポートするワークフロー定義
├── scripts/
│   └── review.sh            ← レビュー実行スクリプト（base64入力、flock排他、worktree隔離）
├── prompts/
│   └── review-prompt.md     ← レビュー指示プロンプト（カスタマイズ可）
├── reviews/                 ← レビューログ出力先（自動作成）
└── .gitignore
```

---

## STEP 1: `.env` を設定する

```bash
cp .env.example .env
vim .env
```

```bash
# ============================================
# Slack 設定
# ============================================
# チャンネルに投稿する場合: チャンネルID（例: "C05ABCDE12F"）
#   調べ方: Slack チャンネルを右クリック →「チャンネル詳細を表示」→ 最下部にチャンネルID
# 自分のDMに投稿する場合: Slack Member ID を指定
#   調べ方: Slack → 自分のプロフィール →「⋮」→「メンバーIDをコピー」
SLACK_CHANNEL="U01ABCDEF"

# Slack Bot Token（メッセージ投稿 + 既存スレッド検索 + Markdown添付に使用）
SLACK_BOT_TOKEN=xoxb-xxxxxxxxxxxx-xxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxx

# レビュー通知のメンション先（Slack User ID、カンマ区切りで複数可）
#   調べ方: Slack → プロフィール →「⋮」→「メンバーIDをコピー」
#   例: SLACK_MENTION=U05ABCDE12F,U06XYZGH34J
#   未設定の場合、メンションなしで投稿される
SLACK_MENTION=

# ============================================
# GitHub 設定
# ============================================
# 自分の GitHub ユーザー名（カンマ区切りで複数指定可）
GITHUB_REVIEWERS=your-github-username

# レビュアーに追加されたチーム（カンマ区切り、チームslug）
GITHUB_TEAMS=your-team-slug

# 監視するリポジトリ（カンマ区切り、org/repo形式）
GITHUB_REPOS=your-org/repo1,your-org/repo2

# ============================================
# パス設定（絶対パスで指定。~ や ${HOME} は使えない）
# ============================================
# macOS: /Users/ユーザー名/...
# Linux: /home/ユーザー名/...
REPOS_BASE_PATH=/Users/yourname/Develop
CLAUDE_CONFIG_PATH=/Users/yourname/.claude

# GitHub Personal Access Token（PR取得 + git fetch に使用）
# 取得方法: https://github.com/settings/tokens → Generate new token (classic) → repo スコープ
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Claude 認証トークン（claude setup-token で取得、Max/Pro サブスク内・追加料金なし）
CLAUDE_TOKEN=sk-ant-oat01-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# ============================================
# 関連リポジトリ（API変更時にwebapp側も確認する等）
# ============================================
RELATED_REPOS=
FALLBACK_BRANCH=develop

# ============================================
# その他
# ============================================
POLL_INTERVAL_MINUTES=1

# Linux環境のみ: ホストユーザーのUID/GIDを指定（macOSでは不要）
# 確認方法: id -u && id -g
# USER_ID=1000
# GROUP_ID=1000
```

### パス設定の注意

- `REPOS_BASE_PATH`: clone 済みリポジトリの**親ディレクトリ**を指定
  - 例: `/Users/yourname/Develop` を指定すると、`/Users/yourname/Develop/repo-name` がコンテナ内で `/repos/repo-name` としてマウントされる
- `CLAUDE_CONFIG_PATH`: `~/.claude` ディレクトリの絶対パス
- **`~` や `${HOME}` は `.env` ファイル内で展開されない**。必ず絶対パスで記述すること
- **`#` を含む値**（チャンネル名など）は必ず `"` で囲む（`.env` で `#` 以降がコメント扱いされるため）

### Slack Member ID の調べ方（DMに投稿する場合）

1. Slack を開く
2. 左サイドバーで**自分の名前**をクリック
3. **「プロフィール」** をクリック
4. 右側にプロフィールが開く
5. **「⋮」（三点メニュー）** をクリック
6. **「メンバーIDをコピー」** をクリック
7. `U` で始まる文字列（例: `U01ABCDEF`）がコピーされる → `.env` の `SLACK_CHANNEL` に設定

テストが終わったらチャンネルに切り替え:
```bash
SLACK_CHANNEL="C05XXXXXXXX"
```

---

## STEP 2: Slack App を作成する（Bot Token の取得）

1. https://api.slack.com/apps を開く
2. **「Create New App」** → **「From scratch」**
3. App Name: `Claude Code Review`、ワークスペースを選択 → **「Create App」**
4. 左メニュー **「OAuth & Permissions」** をクリック
5. **「Bot Token Scopes」** セクションで以下を追加:
   - `chat:write` — メッセージ投稿
   - `chat:write.public` — 参加していないパブリックチャンネルにも投稿可能
   - `channels:history` — チャンネルの既存スレッド検索
   - `channels:read` — チャンネルID解決
   - `im:history` — DM の既存スレッド検索
   - `im:read` — DM ID 解決
   - `files:write` — レビュー詳細の Markdown ファイル添付
6. ページ上部の **「Install to Workspace」** → **「許可する」**
7. **Bot User OAuth Token** (`xoxb-` で始まる) をコピー → `.env` の `SLACK_BOT_TOKEN` に設定

> **チーム共有可能:** Bot Token はワークスペースに紐づくので、1人が作れば OK。チームメンバーも同じトークンを使える。

### チャンネルに投稿する場合

対象チャンネルでボットを招待:
```
/invite @Claude Code Review
```

---

## STEP 3: GitHub Personal Access Token を作成する

1. https://github.com/settings/tokens を開く
2. **「Generate new token (classic)」** をクリック
3. Note: `claude-pr-review`、スコープは **`repo`** にチェック
4. **「Generate token」** → 表示された `ghp_...` トークンをコピー
   - ※ ページを離れると二度と表示されないので注意

---

## STEP 4: Claude トークンを取得する

```bash
claude setup-token
```

表示された `sk-ant-oat01-...` で始まるトークンを `.env` の `CLAUDE_TOKEN` に設定。

> Claude Max または Pro サブスクリプションが必要。サブスクリプション内で追加料金はかからない。

---

## STEP 5: Docker を起動する

```bash
cd ~/Develop/claude-pr-review
docker compose up -d --build    # 初回はビルドに数分かかる
```

起動確認:
```bash
docker compose ps               # 2つのコンテナが running であること
docker compose logs -f n8n      # n8n のログを確認
```

Claude Code の認証確認:
```bash
docker exec -it claude-review-runner claude --version
```

---

## STEP 6: n8n にワークフローをインポートする

### 6-1. n8n UI にアクセス

1. ブラウザで http://localhost:5678 を開く
2. 初回はオーナーアカウント作成画面が出る → 適当な名前・メール・パスワードで作成
   （n8n ローカル用。外部サービスへの登録ではない）

### 6-2. ワークフローをインポート

1. 左メニュー **「Workflows」** → 右上 **「⋮」** → **「Import from File」**
2. `n8n/workflow.json` を選択してインポート

### 6-3. ワークフローを有効化

1. 右上の **「Publish」** ボタンの **「v」** をクリック
2. **「Publish」** を選択

> Publish するとSchedule ノードが有効になり、1分間隔でポーリングが開始される。
> 停止したい場合は同じメニューから **「Unpublish」** を選択する。

> **Credential 設定は不要。** GitHub API と Slack API は全て `.env` の環境変数（`GITHUB_TOKEN`, `SLACK_BOT_TOKEN`）を使って Code ノード内から直接呼び出すため、n8n の Credential を設定する必要はない。

---

## 動作確認

### 手動テスト

1. n8n UI でワークフローを開く
2. 右上の **「Test Workflow」** ボタンをクリック
3. 各ノードの実行結果を確認

### 確認ポイント

| ノード | 確認すること |
|--------|-------------|
| GitHubAPI | PR の一覧が取得できているか |
| Filter | レビュー対象の PR が抽出されているか |
| Review | Claude Code のレビュー結果が返っているか（**数分かかる**） |
| CheckThread | Slack チャンネルから既存スレッドを検索できているか |
| PostToSlack | 親メッセージ + スレッド返信 + Markdown ファイルが投稿されているか |

### レビュー実行条件

| 条件 | レビュー |
|------|---------|
| Draft PR | しない |
| Ready + 自分/チームがレビュアー | **する** |
| Ready + 自分が作成したPR | **する**（`GITHUB_REVIEWERS` のユーザーが author の場合） |
| Ready + レビュー提出後に追加コミット | **する**（tracked で追跡継続） |
| Ready + コメント/ラベル/CI のみ | しない |
| 同じPRが既にレビュー実行中 | しない（flock + inProgress で排他） |
| レビュー済み（同じ SHA） | しない（SHA変更時のみ再レビュー。ベースブランチのマージでもSHAが変わるため再レビューされる） |
| Approve 済み + チーム追加 | しない（同一SHAのため） |
| レビュー失敗/タイムアウト | Slack にエラー通知、**最大3回リトライ**（新コミットでリセット） |

---

## Slack での表示

### 初回レビュー（スレッド形式）

```
#code-review
┌──────────────────────────────────────────┐
│ @yamada-taro                              │
│ 🔍 PR #42 ユーザー検索APIの追加           │
│ 📦 your-repo  📊 Score: C  🔴2 🟡1      │
└──────────────────────────────────────────┘
  │ スレッド
  ├─ 🔗 https://github.com/org/repo/pull/42
  │  👤 yamada-taro  📦 your-repo  🔀 `feature/user-search` → `develop`
  │  ```git checkout feature/user-search```
  │
  │  📝 *概要*
  │  SQLインジェクションと認証漏れが見つかった
  │
  │  📋 *変更の影響*
  │  ユーザー検索エンドポイントが追加される
  │  • 検索機能なし → キーワードでユーザー検索可能
  └─ 📎 review_PR42.md（レビュー詳細 — 指摘事項・良い点・手動レビュー推奨）
```

### 再レビュー（既存スレッドに追記）

```
  │ スレッド（既存の親メッセージの下に追記）
  ├─ ... (初回レビューの内容)
  ├─ 🔄 *再レビュー*
  │  @yamada-taro
  │  🔍 PR #42 ユーザー検索APIの追加
  │  📦 your-repo  📊 Score: B  🟡1
  ├─ 🔗 ... 📝 *概要* ...
  └─ 📎 review_PR42.md
```

### 再レビュー（既存スレッドが50件外 → 新規スレッド作成）

```
┌──────────────────────────────────────────┐
│ 🔄 *再レビュー*                           │
│ @yamada-taro                              │
│ 🔍 PR #42 ユーザー検索APIの追加           │
│ 📦 your-repo  📊 Score: B  🟡1           │
└──────────────────────────────────────────┘
  │ スレッド
  ├─ 🔗 ...
  └─ 📎 review_PR42.md
```

### 失敗時（最大3回リトライ）

```
┌─────────────────────────────────────────────────────────┐
│ @yamada-taro                                              │
│ ❌ PR #42 ユーザー検索APIの追加                           │
│ 📦 your-repo  レビュー失敗 （リトライ 1/3）               │
└─────────────────────────────────────────────────────────┘
  │ スレッド
  └─ 🔗 https://github.com/...
     エラー: タイムアウトまたは実行失敗

※ 新コミットが push されるとリトライカウントがリセットされる
```

---

## カスタマイズ

### レビュープロンプトの変更

`prompts/review-prompt.md` を編集してレビュー指示をカスタマイズできる。
`:ro`（読み取り専用）マウントなので、**コンテナの再起動なしで変更が即反映される**。

### リポジトリごとのプロンプト

対象リポジトリに `.claude/review-prompt.md` を配置すると、そちらが優先的に使用される。

### ポーリング間隔の変更

1. `.env` の `POLL_INTERVAL_MINUTES` を変更
2. **n8n UI の Schedule ノード** も手動で同じ値に変更する
   - n8n の Schedule ノードは環境変数を参照できないため、両方を合わせる必要がある

### 関連リポジトリの整合性チェック

```
your-api の PR（base: story/user-search）
  ▼ your-webapp のどのブランチを見る？
  ├─ origin/story/user-search ある？ → あればそれ
  └─ なければ → origin/develop（FALLBACK_BRANCH）
```

`.env` の `RELATED_REPOS` に指定したリポジトリの対応ブランチを自動解決し、API 型やインターフェースの互換性もチェックする。

---

## 運用コマンド

```bash
docker compose up -d              # 起動
docker compose down               # 停止（n8nデータは volume で保持）
docker compose up -d --build      # 再ビルド（docker-compose.yml 変更時）
docker compose logs -f n8n        # n8n ログ
cat reviews/review_*.json | jq .  # レビュー結果確認
```

### 手動で追加レビュー

```bash
cd ~/Develop/your-repo
git checkout feature-branch
claude
```

---

## トラブルシューティング

### 起動・設定系

| 問題 | 対策 |
|------|------|
| `REPOS_BASE_PATH must be set` | `.env` が正しく設定されているか確認 |
| `GITHUB_TOKEN が設定されていません` | `.env` に `GITHUB_TOKEN` が設定されているか確認。`docker compose up -d` で環境変数を反映 |
| `SLACK_BOT_TOKEN が設定されていません` | `.env` に `SLACK_BOT_TOKEN` が設定されているか確認 |
| PRが検出されない | Draft でないか / レビュアーがアサインされているか / リポジトリ名が `.env` に正しく設定されているか確認 |
| Claude Code の認証エラー | `docker exec -it claude-review-runner claude auth login` で再認証 |
| Linux で Permission Denied | `.env` に `USER_ID=（id -uの結果）` と `GROUP_ID=（id -gの結果）` を追加して `docker compose up -d --build` |

### SSH URL で git fetch が失敗する

コンテナ内には SSH キーがないため、リモート URL が `git@github.com:...` の場合に失敗する。
→ `review.sh` が自動的に HTTPS URL に変換するので、**通常は対処不要**。
手動で変換する場合:
```bash
cd /path/to/repo
git remote set-url origin https://github.com/org/repo.git
```

### Slack 関連

| 問題 | 対策 |
|------|------|
| Slack に投稿されない | `.env` の `SLACK_BOT_TOKEN` を確認。チャンネル投稿の場合はボットを `/invite` しているか確認 |
| `not_in_channel` エラー | 対象チャンネルで `/invite @Claude Code Review` を実行 |
| `missing_scope` エラー | Slack App の OAuth & Permissions で必要なスコープを追加し **Reinstall** する |
| 再レビューが常に新規スレッドになる | `SLACK_BOT_TOKEN` 未設定、または Bot に `channels:history` スコープがない |
| Markdown ファイルが添付されない | Bot に `files:write` スコープがあるか確認 |

### レビュー済み PR が再レビューされない / 再レビューしたい

レビュー済みPRは**同じ SHA の間はスキップ**される（永久）。
新しいコミットが push されれば SHA が変わるので再レビューされる。

**即座に再レビューしたい場合（staticData のリセット）:**

1. n8n UI でワークフローを **非アクティブ（OFF）** にする
2. ワークフローを**削除**する
3. `n8n/workflow.json` を**再インポート**して有効化する

> staticData はワークフローに紐づくため、削除→再インポートでリセットされる。
> スレッド情報は Slack チャンネルから直接検索するため、再インポート後も既存スレッドへの追記は継続される。

### ワークフロー再インポート手順（コード修正時にも必要）

`n8n/workflow.json` を編集した場合、n8n 上のワークフローは自動更新されない。以下の手順で反映する:

1. n8n UI でワークフローを **非アクティブ（OFF）** にする
2. ワークフローを**削除**する
3. **「Import from File」** で `n8n/workflow.json` を再インポート
4. 保存して有効化する

> Credential 設定は不要。再インポートするだけで動作する。

### その他

| 問題 | 対策 |
|------|------|
| Code ノードがタイムアウト | `docker-compose.yml` の `EXECUTIONS_TIMEOUT` / `N8N_RUNNERS_TASK_TIMEOUT` を増やす（デフォルト 900秒） |
| レビューが二重実行される | 通常は inProgress マーカーで防止される。`docker exec claude-review-runner ls /tmp/claude-review-locks/` でロック確認 |
| worktree の残骸が残る | `docker exec claude-review-runner bash -c "cd /repos/repo-name && git worktree prune"` |
| `fatal: detected dubious ownership` | 通常は自動対策済み。出た場合は `docker exec claude-review-runner git config --global --add safe.directory '*'` |
| ポーリング間隔を変えたい | `.env` **と** n8n UI の Schedule ノードの両方を変更 |
| マージ済みPRが再レビューされた | GitHub API が一時的にエラーだった可能性。一度きりなら問題なし |

### レビューログの確認

```bash
ls reviews/
# review_repo-name_PR123_20250311_120000.json  ← Claude 生出力
# error_repo-name_PR123_20250311_120000.log    ← エラーログ
```

30日以上前のログは自動削除される。
