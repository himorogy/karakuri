# @himorogy/enclave-env

**LLM に本番用秘密情報を渡さない**ための env 管理 CLI ツールです。

[dotenvx](https://dotenvx.com/) による暗号化と実行時ガードを組み合わせ、LLM が動く devcontainer から prod キーを構造的に隔離します。

---

# 対応 OS

* Mac / Linux
* Windows の場合は Linux ツールのインストールが必要になります
  * Git Bash 付属の Unix ツールを推奨します
  * Git Bash をインストールして、システム環境変数に PATH を追加

---

# できること

## 平文 env のコミットをブロックする

ステージ済みの `.env*` ファイルに暗号化されていないものがあればコミットを中断します。

```json
{
  "simple-git-hooks": {
    "pre-commit": "sh node_modules/@himorogy/enclave-env/scripts/check.sh"
  }
}
```

使用する機能：`scripts/check.sh`（内部で `enclave-env check` を呼び出し）

## 暗号化した env を使う

**既定は `dotenvx run --` です。** 復号した値をプロセスの環境変数として直接注入し、平文ファイルをディスクに作りません。

```sh
dotenvx run -f .env.production -- pnpm deploy
dotenvx run -f .env -- pnpm dev
```

値の一覧・単体の確認も、ファイルを作らずに行えます。

```sh
dotenvx get -f .env.production                 # 全変数を表示
dotenvx get DATABASE_URL -f .env.production    # 単体を表示
```

## env ファイルを暗号化・復号する

```sh
enclave-env encrypt --env local   # .env を in-place 暗号化
enclave-env decrypt --env local   # .env を in-place 復号
```

`--env` に指定する名前は `enclave-env` 設定ファイルの `ENV_<NAME>_FILE` に対応します。

> **`decrypt` は既定の手段ではありません。** in-place 復号は平文をディスク上のファイルとして残すため、プロセスの異常終了・電源断・`trap` の取りこぼしで平文が残置します。上の `dotenvx run --` / `dotenvx get` で用の足りる場面ではそちらを使ってください。
>
> `decrypt` を禁止はしていません。ファイルとしての平文を要求する外部ツールに食わせる、といった用途は残ります。ただしその場合も、平文の残置を防いでいるのはコマンドの選択ではなく実行環境側の構成（コンテナの `read_only` + tmpfs）である、という前提で扱ってください。

## prod secrets を LLM から守る

### 単一変数を追加・更新する

`dotenvx set` を使えば private key 不要で暗号化したまま書き込めます：

```sh
dotenvx set DATABASE_URL "postgres://..." -f .env.production
```

- `.env.production` の public key だけで暗号化するため private key 不要
- 平文ファイルが一切ディスクに書き出されない
- dev コンテナ内でも実行可能（コマンドヒストリー経由で LLM が値を読み取れる点に留意）

### prod キーをワークスペース外に置く

| 環境 | キーの保管場所 |
|---|---|
| local / dev | `.devcontainer/dev/.env.container`（gitignore 対象） |
| prod | `~/.config/<your-project>/.env.container`（ワークスペース外） |

prod キーをワークスペース外に置くことで bind mount 経由で LLM に渡るリスクをなくします。`ENV_PROD_PROTECTED=true` を設定すると、`decrypt` 実行時に dev コンテナが稼働中かどうかを確認しブロックします。

## prod 操作環境を用意する（全復号・deploy・DB）

prod の private key を dev コンテナ外に置くと、コンテナ内から `.env.production` を復号できなくなります。これは意図した動作ですが、複数変数の編集や prod deploy には prod 専用環境が必要です。

### 選択肢 1：ホスト直実行

最もシンプル。dev コンテナを停止した状態でホストから実行します。ホストに Node.js と `dotenvx` のインストールが必要です。

```sh
# DOTENV_PRIVATE_KEY_PRODUCTION が使える状態で
dotenvx run -f .env.production -- pnpm deploy    # 実行
dotenvx get -f .env.production                   # 値の確認
```

いずれも平文ファイルを作りません。in-place 復号（`enclave-env decrypt --env prod`）は、ファイルとしての平文を要求するツールに食わせる場合に限って使ってください。

### 選択肢 2：prod-shell スクリプト（推奨）

相互排他チェック・コンテナ起動・prod キー注入を 1 コマンドで行います。コンテナ内で `enclave-env`・`dotenvx`・各種デプロイツールが使えます。

```sh
sh scripts/prod-shell.sh
```

テンプレート：[`templates/prod-shell.sh`](./templates/prod-shell.sh)

### 選択肢 3：2 層 devcontainer

VS Code の「Reopen in Container」で prod devcontainer に切り替える構成です。再現性が最も高く、チームでの運用に向いています。

設計の核心は **Dockerfile を dev / prod で共有し、Claude Code のインストールを `dev/devcontainer.json` の `postCreateCommand` で行う**点です。同じ Dockerfile から prod 環境をビルドしても Claude Code が含まれない状態が構造的に保証されます。

```
.devcontainer/
├── Dockerfile        # 共有ベース（Claude Code なし）
├── dev/
│   └── devcontainer.json   # postCreateCommand で Claude Code をインストール
│                           # initializeCommand: init-check-dev.sh
└── prod/
    └── devcontainer.json   # Claude Code 関連の設定を含まない
                            # initializeCommand: init-check-prod.sh
```

テンプレート：[`templates/devcontainer/`](./templates/devcontainer/)

## devcontainer 起動時に安全性を検証する

`initializeCommand` にシェルスクリプトを登録することで、コンテナ起動前に安全性を確認します。

| スクリプト | 登録先 | チェック内容 |
|---|---|---|
| `scripts/init-check-dev.sh` | dev コンテナの `initializeCommand` | prod コンテナ稼働中なら起動をブロック（2 層 devcontainer 使用時） |
| `scripts/init-check-prod.sh` | prod コンテナの `initializeCommand` | dev コンテナ稼働中なら起動をブロック |

```json
{
  "initializeCommand": "source enclave-env && sh node_modules/@himorogy/enclave-env/scripts/init-check-dev.sh"
}
```

> 実行時ガード（`protected` フラグ）と起動時ガードの 2 層で平文露出を防ぎます。詳細は「セキュリティ設計」を参照してください。

---

# インストール

```sh
pnpm add -D @himorogy/enclave-env @dotenvx/dotenvx simple-git-hooks
```

> `@dotenvx/dotenvx` は peer dependency です。プロジェクトに直接インストールしてください。

# セットアップ

## 1. `enclave-env` を作成する

プロジェクトルートに設定ファイルを置きます。シェルスクリプトから直接 `source` できる dotenv 形式です。

```sh
MODE=single

ENV_LOCAL_FILE=.env
ENV_PROD_FILE=.env.production
ENV_PROD_PROTECTED=true

DEV_CONTAINER_NAME=your-project-dev-devcontainer
PROD_CONTAINER_NAME=your-project-prod-devcontainer   # optional: prod-shell や 2層 devcontainer で使用
```

## 2. `package.json` にスクリプトと git hook を追加する

```json
{
  "scripts": {
    "dev":              "dotenvx run -f .env -- <実際の dev コマンド>",
    "deploy":           "dotenvx run -f .env.production -- <実際の deploy コマンド>",
    "encrypt-env":      "enclave-env encrypt --env local",
    "encrypt-env:prod": "enclave-env encrypt --env prod",
    "prepare":          "simple-git-hooks"
  },
  "simple-git-hooks": {
    "pre-commit": "sh node_modules/@himorogy/enclave-env/scripts/check.sh"
  }
}
```

`pnpm install` 実行時に `prepare` が走り、フックが自動登録されます。

アプリの実行系は `dotenvx run --` でくるみ、`decrypt-env` 系のスクリプトは**置きません**。package.json に置くと in-place 復号が一手で呼べる既定の操作になり、平文ファイルが日常的に生まれます。復号が必要になった場合は `enclave-env decrypt --env <name>` をその場で打ってください。

## 3. `.env` を dotenvx で暗号化する

```sh
pnpm encrypt-env
```

生成された `DOTENV_PUBLIC_KEY` はリポジトリにコミットします。`.env.keys` はコミットしないでください。

---

# セキュリティ設計

## 守るべき原則

prod 環境の実現手段は問いませんが、以下の 2 つを守ることがこのツールの前提です：

| 原則 | 目的 |
|---|---|
| **prod の private key は常にワークスペース外に置く** | bind mount 経由で LLM に渡らない |
| **prod 操作は dev コンテナが停止した状態で行う** | 復号した平文を LLM から守る |

## 2 層の防御

全復号フロー中は `.env.production` が平文でディスクに存在します。この間に dev コンテナが起動すると、bind mount 経由で LLM が平文にアクセスできてしまいます。

enclave-env はこれを 2 つのレイヤーで防ぎます：

| レイヤー | タイミング | 担う側 | 実装 |
|---|---|---|---|
| 起動時 | devcontainer 起動 | **プロジェクト** が `initializeCommand` に登録 | `scripts/init-check-dev.sh` / `scripts/init-check-prod.sh` |
| 実行時 | `decrypt` 実行時 | **ライブラリ** が自動で実行 | `protected` フラグが付いた環境で dev コンテナの稼働を確認しブロック |

実行時ガードは `DEVCONTAINER=true`（コンテナ内からの実行）の場合はスキップされます。起動時ガードで保証済みのためです。

---

# リファレンス

## CLI

```
enclave-env encrypt --env <environment>   # 指定環境の env ファイルを in-place 暗号化
enclave-env decrypt --env <environment>   # 指定環境の env ファイルを in-place 復号
enclave-env check                         # ステージ済み .env* ファイルの暗号化確認（git pre-commit hook 用）
```

`<environment>` は `enclave-env` の `ENV_<NAME>_FILE` キーの `<NAME>` を小文字にしたものと一致させてください。

devcontainer の `initializeCommand` 用チェックはシェルスクリプトで提供しています：

```
scripts/init-check-dev.sh    # dev コンテナ起動時（enclave-env を source して実行）
scripts/init-check-prod.sh   # prod コンテナ起動時（enclave-env を source して実行）
```

## `enclave-env` 設定キー

| キー | 説明 |
|---|---|
| `MODE` | `single` のみ実装済み |
| `ENV_<NAME>_FILE` | 環境 `<name>` の対象 env ファイルパス |
| `ENV_<NAME>_PROTECTED` | `true` の場合、`decrypt` 前に dev コンテナ稼働チェックを実行 |
| `DEV_CONTAINER_NAME` | `protected` チェックおよび `init-check-prod.sh` の対象コンテナ名 |
| `PROD_CONTAINER_NAME` | 設定すると 2 層 devcontainer モードで動作（`init-check-dev.sh` が起動チェックを実施） |

`<NAME>` は大文字・数字・アンダースコアで構成し、`--env` オプションでは小文字で参照します。例：`ENV_PROD_FILE` → `--env prod`

## Git 管理ポリシー（推奨）

| ファイル | Git 管理 |
|---|---|
| `.env`（local、暗号化済） | プロジェクトによる（未暗号化なら ❌ 推奨） |
| `.env.production`（暗号化済） | ✅ |
| `.env.keys*` | ❌ 必ず gitignore |
| `enclave-env` | ✅ |

---

# 機能一覧とテスト状況

| 機能 | 種別 | テスト |
|---|---|---|
| `enclave-env` ファイルの解析（`loadConfig`） | TypeScript | ✅ |
| env ファイルパスの解決（`resolveEnvFile`） | TypeScript | ✅ |
| ステージファイルの暗号化確認（`scripts/check.sh`） | シェル | ✅ |
| dev コンテナ起動時セキュリティチェック（`scripts/init-check-dev.sh`） | シェル | ✅ |
| prod コンテナ起動時相互排他チェック（`scripts/init-check-prod.sh`） | シェル | — |
| env ファイルの暗号化（`encrypt`） | TypeScript | — (dotenvx 依存) |
| env ファイルの復号（`decrypt`） | TypeScript | — (dotenvx 依存) |

```sh
pnpm test       # 全テスト
pnpm test:ts    # TypeScript のみ
pnpm test:sh    # シェルスクリプトのみ
```

# 開発・リリース

## CI/CD 構成

| ワークフロー | トリガー | 内容 |
|---|---|---|
| **CI** | PR・push | lint + test |
| **Registry Monitor** | 定期実行 | npm registry 監視 → Slack 通知 |

## リリース手順

```sh
# 1. 変更を記述（対話形式で bump type と説明を入力）
pnpm changeset add
git commit -m "chore: add changeset"
git push

# 2. バージョン更新・git tag・publish を一括実行
pnpm release
```

# ライセンス

MIT
