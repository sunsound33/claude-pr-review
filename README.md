# n8n × Claude Code ローカル自動PRレビュー

GitHub の Pull Request を Claude Code が自動レビューし、結果を Slack にスレッド形式で投稿するシステム。

## アーキテクチャ

```
┌────────── ローカルのみ（外部公開なし） ──────────┐
│                                                   │
│  n8n（ポーリング）                                 │
│    ├── GitHub API でPR一覧取得                     │
│    ├── Draft スキップ                              │
│    ├── レビュアー/チームフィルタ（tracked で追跡）   │
│    ├── head.sha + TTL(2h) で重複防止               │
│    ├── base64 エンコードで安全に引数渡し            │
│    ├── 失敗時 → Slack にエラー通知、次回再実行       │
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
│  n8n → Slack にスレッド形式で投稿                   │
│    ├── SlackParent: 親メッセージ（スコア概要）      │
│    └── SlackThread: スレッド返信（詳細・issue別）   │
└───────────────────────────────────────────────────┘
```

**ワークフロー (n8n ノード構成):**

```
Schedule(1分間隔) → RepoList → GitHubAPI(PR取得) → Filter(重複・レビュアー判定)
→ PrepareInput → Review(docker exec) → ParseResult → SkipCheck
→ SlackParent(親メッセージ) → ThreadMessages → SlackThread(スレッド返信)
```

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
# 自分のDMに投稿する場合: Slack Member ID を指定
#   調べ方: Slack → 自分のプロフィール →「⋮」→「メンバーIDをコピー」
#   例: "U05ABCDE12F"
SLACK_CHANNEL="U01ABCDEF"

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

# GitHub Personal Access Token（git fetch に必要。n8n の GitHubAPI ノードでも使用）
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
SLACK_CHANNEL="#code-review"
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
6. ページ上部の **「Install to Workspace」** → **「許可する」**
7. **Bot User OAuth Token** (`xoxb-` で始まる) をコピー → 後で n8n に設定

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

### 6-3. GitHubAPI ノードの Credential 設定

1. キャンバス上の **「GitHubAPI」** ノードをダブルクリック
2. **「Credential for Header Auth」** → **「Create New Credential」**
3. 以下を入力:
   - **Name**: `Authorization`
   - **Value**: `token ghp_xxxxxxxxxxxx`

   > **重要**: `token ` の後にスペースが1つ必要。`Bearer` ではなく **`token`** を使う（GitHub API の仕様）

4. **「Save」** で保存

### 6-4. SlackParent ノードの設定

1. **「SlackParent」** ノードをダブルクリック
2. **「Credential for Slack API」** → **「Create New Credential」**
3. **「Access Token」** に Bot Token (`xoxb-...`) を貼り付けて **「Save」**
4. 各フィールドを確認:

| フィールド | 値 | 設定方法 |
|-----------|------|---------|
| Resource | Message | Fixed |
| Operation | Send | Fixed |
| Send Message To | Channel | Fixed |
| Channel | By ID → `{{ $json.slackChannel }}` | By ID を選択し、右の入力欄を **Expression** にする |
| Message Type | Simple Text Message | **Fixed** ⚠️ |
| Message Text | `{{ $json.parentText }}` | **Expression** |

> **⚠️ 重要**: **Message Type は必ず Fixed** で「Simple Text Message」を選択すること。Expression にすると `invalid_arguments` エラーになる。

### 6-5. SlackThread ノードの設定

1. **「SlackThread」** ノードをダブルクリック
2. Credential で先ほど作成した **「Slack API」** を選択
3. 各フィールドを確認:

| フィールド | 値 | 設定方法 |
|-----------|------|---------|
| Resource | Message | Fixed |
| Operation | Send | Fixed |
| Send Message To | Channel | Fixed |
| Channel | By ID → `{{ $json.channel }}` | By ID を選択し、右の入力欄を **Expression** にする |
| Message Type | Simple Text Message | **Fixed** ⚠️ |
| Message Text | `{{ $json.text }}` | **Expression** |
| **Reply to a Message** | **ON** | Options の「Add option」から追加してトグルを ON にする |
| Thread Timestamp | `{{ $json.ts }}` | **Expression** |
| Also Send to Channel | **OFF** | そのまま（スレッド内にだけ返信する） |

> **⚠️ 重要**: **「Reply to a Message」** は Options セクションの「Add option」から追加する。ON にすると「Thread Timestamp」フィールドが表示される。これにより SlackParent の親メッセージにスレッド返信される。

### 6-6. SlackThread の「Reply to a Message」設定

1. SlackThread ノードの Options セクションで **「Add option」** をクリック
2. **「Reply to a Message」** を選択して追加
3. トグルを **ON** にする
4. 表示された **「Thread Timestamp」** に Expression で `{{ $json.ts }}` を設定
5. **「Also Send to Channel」** トグルも表示されるが、**OFF のまま**でよい（ON にするとスレッド返信がチャンネルにも表示される）

### 6-7. ワークフローを有効化

1. 右上の **「Publish」** ボタンの **「v」** をクリック
2. **「Publish」** を選択

> Publish するとSchedule ノードが有効になり、1分間隔でポーリングが開始される。
> 停止したい場合は同じメニューから **「Unpublish」** を選択する。

---

## 動作確認

### 手動テスト

1. n8n UI でワークフローを開く
2. 右上の **「Test Workflow」** ボタンをクリック
3. 各ノードの実行結果を確認

### 確認ポイント

| ノード | 確認すること |
|--------|-------------|
| GitHubAPI | PR の一覧が JSON で返っているか |
| Filter | レビュー対象の PR が抽出されているか（レビュアーがアサインされた PR のみ通過） |
| Review | Claude Code のレビュー結果が返っているか（**数分かかる**） |
| SlackParent | 親メッセージが Slack に投稿されているか |
| SlackThread | 親メッセージのスレッドに詳細が投稿されているか |

### レビュー実行条件

| 条件 | レビュー |
|------|---------|
| Draft PR | しない |
| Ready + 自分/チームがレビュアー | **する** |
| Ready + 自分が作成したPR | **する**（`GITHUB_REVIEWERS` のユーザーが author の場合） |
| Ready + レビュー提出後に追加コミット | **する**（tracked で追跡継続） |
| Ready + コメント/ラベル/CI のみ | しない |
| 同じPRが既にレビュー実行中 | しない（flock で排他） |
| レビュー済み（同じ SHA、2時間以内） | しない（TTL で自動クリア） |
| レビュー失敗/タイムアウト | Slack にエラー通知、次回**再実行** |

---

## Slack での表示

### 正常時（スレッド形式）

```
#code-review
┌───────────────────────────────────────┐
│ 🔍 PR #42 ユーザー検索APIの追加 📊 C  🔴2 🟡1 │
└───────────────────────────────────────┘
  │ スレッド
  ├─ 🔗 https://github.com/org/repo/pull/42
  │  👤 yamada-taro → develop
  │  📝 SQLインジェクションと認証漏れが見つかった
  ├─ 🔴 *セキュリティ*  `src/api/users.ts:45` ...
  ├─ 🟡 *パフォーマンス*  `src/api/users.ts:52-58` ...
  └─ ✅ 良い点 ...
```

### 失敗時

```
┌───────────────────────────────────────┐
│ ❌ PR #42 ユーザー検索APIの追加  レビュー失敗 │
└───────────────────────────────────────┘
  │ スレッド
  └─ 🔗 https://github.com/...
     エラー: タイムアウトまたは実行失敗
     次のポーリングで再実行されます。
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
docker compose up -d --build      # 再ビルド（Dockerfile 変更時）
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
| Slack に投稿されない | Credential の紐付けと Bot Token を確認。チャンネル投稿の場合はボットを `/invite` しているか確認 |
| Slack に「undefined」が投稿される | n8n がキャッシュした古いコードを実行している。ワークフローを削除して再インポートする（下記参照） |
| SlackThread で `invalid_arguments` | **Message Type** が Expression になっていないか確認（Fixed で「Simple Text Message」にする）。**Reply to a Message** が ON か確認。**Thread Timestamp** に `{{ $json.ts }}` が設定されているか確認 |

### レビュー済み PR が再レビューされない / 再レビューしたい

レビュー済みPRは **同じ SHA に対して 2 時間の TTL** で自動的に再レビュー可能になる。
新しいコミットが push されれば SHA が変わるので即座に再レビューされる。

**即座に再レビューしたい場合（staticData のリセット）:**

1. n8n UI でワークフローを **非アクティブ（OFF）** にする
2. ワークフローを**削除**する
3. `n8n/workflow.json` を**再インポート**する
4. Credential を再設定して有効化する

> staticData はワークフローに紐づくため、削除→再インポートでリセットされる。

### ワークフロー再インポート手順（コード修正時にも必要）

`n8n/workflow.json` を編集した場合、n8n 上のワークフローは自動更新されない。以下の手順で反映する:

1. n8n UI でワークフローを **非アクティブ（OFF）** にする
2. ワークフローを**削除**する
3. **「Import from File」** で `n8n/workflow.json` を再インポート
4. **Credential を再設定する**（GitHubAPI, SlackParent, SlackThread）
5. **Slack ノードの設定を確認する**（特に Message Type, Reply to a Message, Thread Timestamp）
6. 保存して有効化する

> **注意**: Credential と Slack ノードの手動設定は再インポートのたびに必要。workflow.json にはプレースホルダー ID が入っているため。

### その他

| 問題 | 対策 |
|------|------|
| Code ノードがタイムアウト | `docker-compose.yml` の `EXECUTIONS_TIMEOUT` / `N8N_RUNNERS_TASK_TIMEOUT` を増やす（デフォルト 900秒） |
| レビューが二重実行される | `docker exec claude-review-runner ls /tmp/claude-review-locks/` でロック確認 |
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
