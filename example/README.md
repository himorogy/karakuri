# 推奨 devcontainer / prod 構成例

dev container には LLM エージェントが常駐するため信頼しない。prod container は人間が明示的に起動し、prod の秘匿情報は broker → stdin → コンテナ内 tmpfs の経路だけを流れる（設計の全体像は `docs/prod-secret-isolation-design.md`）。

本ディレクトリのファイルとコピー先の対応:

| 本ディレクトリ | コピー先 | 役割 |
| --- | --- | --- |
| `Dockerfile` | `<repo>/.devcontainer/Dockerfile` | dev イメージ（devcontainer-base + egress-guard 設定） |
| `docker-compose.yaml` | `<repo>/.devcontainer/docker-compose.yaml` | dev container の定義 |
| `docker-compose.prod.yaml` | `~/.config/<project>/compose.prod.yaml` | prod container の定義（配布テンプレートのコピー） |

## 推奨配置

```
~/.local/bin/                  # dev workspace の外（ホスト固定パス）
  bw                           # Bitwarden CLI（native ビルドを SHA-256 照合の上配置）
  prod-run.sh                  # images/runtime-base/templates/prod-run.sh のコピー
  dev-inject.sh                # images/runtime-base/templates/dev-inject.sh のコピー
  broker-bitwarden.sh          # broker 標準実装（templates/ のコピー）
  prj1-broker                  # prod 鍵束のラッパー（下記）
  broker-macos-keychain.sh     # 代替: macOS Keychain broker（登録ツール broker-macos-keychain-set.sh と対）
~/.config/prj1/
  compose.prod.yaml            # templates/compose.prod.yaml のコピー。image の digest を実在のものへ差し替える
<project repo>/                # dev container にマウントされる（git 管理）
  env-guard.conf
  .devcontainer/
    Dockerfile
    docker-compose.yaml
```

prod-run.sh・broker・compose.prod.yaml を workspace の外に置くのは必須。workspace はホストへ bind mount されており、リポジトリ内に置くと dev container 内のエージェントがこれらを書き換えられる（正規 broker の前後に鍵を複製するコードを仕込む、compose から `read_only` / tmpfs を外す等）。

compose.prod.yaml はプロジェクト固有値を含まない設計なので、全プロジェクトで 1 枚を共有することもできる。その場合は runtime-base の digest pin も全プロジェクトで共通になり、イメージ更新が一斉適用になる。プロジェクトごとに更新タイミングを分けたい場合は `~/.config/<project>/` に分置する。

## prod の起動

`.zshrc`:

```sh
export PROD_COMPOSE_FILE=~/.config/prj1/compose.prod.yaml

alias prj1-prod-deploy='PROD_BROKER=$HOME/.local/bin/prj1-broker \
  GIT_REPO=https://github.com/acme/app.git \
  GIT_REF=1234567890abcdef1234567890abcdef12345678 \
  prod-run.sh sh -c "pnpm install --frozen-lockfile && dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy"'
```

`pnpm install` を毎回連結するのは `/src` が tmpfs だから — 一発コマンドは常に clone 直後の素の working tree で走り、node_modules は存在しない。プロジェクト側に `"release:prod": "pnpm i --frozen-lockfile && pnpm deploy:prod"` のような script を切って `prod-run.sh pnpm release:prod` とする方が読みやすい。

broker の標準は Bitwarden CLI（`templates/broker-bitwarden.sh`）。bw 本体は native ビルドを GitHub Releases から取得し、SHA-256 照合の上 `~/.local/bin/bw` に固定配置する（手順はテンプレート冒頭）。鍵束は Secure Note に dotenv 全文で格納し、チーム共有分（DOTENV_PRIVATE_KEY_PROD 等）は共有コレクションの項目、個人分（fine-scoped GH_TOKEN 等）は個人の項目に分ける。

`~/.local/bin/prj1-broker`（PROD_BROKER は引数を取れないため、項目名はラッパーで固定する。カンマ区切りで複数項目をマージでき、同名キーは後勝ちなので共有を先・個人を後に）:

```sh
#!/usr/bin/env bash
export BROKER_BW_BIN="$HOME/.local/bin/bw"
export BROKER_BW_ITEM="env/prj1/shared/prod,env/prj1/prod"
exec "$HOME/.local/bin/broker-bitwarden.sh"
```

macOS Keychain を使う代替もある（`broker-macos-keychain.sh`。登録・更新は対になる `broker-macos-keychain-set.sh` で行う — Keychain のプロンプトが 1 行しか受けないため base64 で畳む等の面倒をツールが見る）。1Password 等も、dotenv 全文を stdout に出すラッパーを書けば broker 契約（各テンプレート冒頭に記載）を満たす。

### 挙動と制約

- `GIT_REF` は完全な 40 桁 commit sha が必須（ブランチ名・タグは既定で拒否。`PROD_ALLOW_MUTABLE_REF=1` で警告付き続行）。
- コンテナは `run --rm` で起動され、コマンド終了とともに削除される。名前付けや後始末は不要。
- dotenvx は `pnpm` の外側に置く。`prod-run.sh pnpm deploy` の形だと `pnpm run` が `node_modules/.bin` を PATH 先頭に積み、ローカルの dotenvx がイメージの shim に勝って鍵が注入されない。
- `--strict --no-armor` は必須（復号失敗の顕在化と、外部サービスへの経路の遮断）。
- GH_TOKEN は entrypoint が clone に使ったあと checkout 完了時点で破棄される。以降のコマンドから認証付きの git / gh 操作はできない（「決定した論点」3 参照）。
- `/src` は tmpfs で、起動のたびに `GIT_REF` から clone し直す。実行結果はコンテナ削除とともに消える（成果物は deploy 先か `/out` へ）。

### 対話作業（dryrun → 適用など）

stdin が secret の搬送路のため `run` の対話 TTY とは両立しない（`-T`）。対話が必要な場合は**二段構え（2 端末、土台は attached）**にする:

```sh
# 端末 1: 土台を前面で起動する。broker の認可プロンプトも entrypoint のログもここに出る
prod-run.sh sleep 8h        # PROD_BROKER / GIT_REPO / GIT_REF 等は一発コマンドと同じ

# 端末 2: entrypoint 完了（clone 済み・sleep 稼働）後に入る
docker exec -it -w /src "$(docker ps -q --filter name=prod-run | head -1)" bash
```

entrypoint 完了後に exec するため `/run/secrets` は注入済み。1 回の注入・clone でセッションを維持でき、その中で dryrun と適用を続けられる。退出後は端末 1 の Ctrl-C で終了・回収（`--rm`）。`sleep infinity` ではなく時間を切っておくと、stop 忘れがそのまま放置されない。

土台を `run -d`（detach）で起動してはならない。stdin パイプをコンテナへ中継しているのは compose クライアント自身なので、detach した瞬間に搬送路が消える — broker は Broken pipe で死に、entrypoint は EOF を待って取込の行で永久に停止する（実測）。また Ctrl-C / `docker stop` が効くのは compose の `init: true`（`docker-compose.prod.yaml` に設定済み）が前提 — 無いと pid 1 = `sleep` がシグナルを無視する。

## dev の起動

VSCode 等の devcontainer 拡張でそのまま起動してよい。prod-run.sh は使わない（prod-run.sh の経路は prod-entrypoint.sh 専用で、dev container の起動ライフサイクルとは別物）。

dev 鍵（`DOTENV_PRIVATE_KEY_LOCAL` / `_DEVELOPMENT`、dev 用の fine-scoped GH_TOKEN 等）も prod と同じ broker 方式で注入する。従来の `env_file`（`dev/.env.container`）はホスト不揮発ディスク上の恒久平文となるため廃止する。

1. dev 鍵束を Bitwarden に用意する。個人分は `env/<project>/dev`、チーム共有分は共有コレクションの `env/<project>/shared/dev`
2. コンテナ起動後、ホストで `dev-inject.sh` を実行する。broker の出力を `docker exec -i` 経由でコンテナ内の取込スクリプトへパイプし、鍵を `/run/secrets/<VAR 名>`（tmpfs、umask 077）へ書く。`.zshrc` に関数を置くと 1 コマンドになる:

   ```sh
   # 共有 note を先・個人 note を後（同名キーは後勝ち = 個人が上書き）
   dev-inject-bw() {
     BROKER_BW_BIN="$HOME/.local/bin/bw" \
     BROKER_BW_ITEM="env/$1/shared/dev,env/$1/dev" \
     DEV_BROKER="$HOME/.local/bin/broker-bitwarden.sh" \
     DEV_COMPOSE_PROJECT="$1-dev" \
     dev-inject.sh
   }
   # 使い方: dev-inject-bw dotfiles
   ```

   `DEV_COMPOSE_PROJECT` は `.devcontainer/docker-compose.yaml` の `name:` の値。サービス名が `dev` 以外なら `DEV_SERVICE` で指定する

   注入した鍵を npm scripts から使うツール（dotenvx / wrangler / gh）は、scripts 内では **`_` 付きの名前**で書く。pnpm/npm は scripts 実行時に `node_modules/.bin` を PATH 先頭へ差し込むため、素の名前はプロジェクトローカルのバイナリに解決されて shim（鍵注入）が迂回される。`_dotenvx` 等はコンテナ側が用意する明示呼び名で、鍵を注入したうえでローカル版（あればそれ、なければイメージ同梱版）を実行する:

   ```json
   "scripts": {
     "dev": "_dotenvx run -f .env.dev --strict -- next dev"
   }
   ```
3. 以降は shim（dotenvx / gh / wrangler）が実行のたびに対象プロセスへだけ注入する。plain git の fetch / push は `GIT_ASKPASS`（compose の `environment:` で設定済み）が `/run/secrets/GH_TOKEN` を読む（dev では entrypoint を通らないため破棄されない）

dev compose 側の前提（本ディレクトリの `docker-compose.yaml` に反映済み）:

- `/run` が tmpfs（`tmpfs: ["/run:uid=1000,gid=1000,mode=0755"]`）。**これが無いと `/run/secrets` はコンテナの writable layer = ホスト側の不揮発ディスクへ書かれ、平文廃止の意味が消える。** オプション無しの短縮形は root:root 所有になり node ユーザーが `/run/secrets` を作れない点も prod と同じ
- `environment:` に `GIT_ASKPASS: /usr/local/bin/git-askpass`（パスは秘匿情報ではない）
- `env_file` 節は使わない

注入を忘れた場合は下流の認証失敗として顕在化する（shim は不在なら素通し。ただし dotenvx だけは `--strict` が無いと復号失敗が沈黙する）。`/run` は tmpfs なので、コンテナの再作成だけでなく停止 → 再起動でも消える。**コンテナを起動するたびに、起動後 dev-inject を 1 回**が運用になる（dev-inject は起動ラッパーではない — 起動は従来どおり IDE が行う）。

この方式は dev container 内のエージェントから鍵を隠すためのものではない。エージェントは同一 UID で動くため `/run/secrets` を直接読めるし、shim 経由でツールも使える — 原理的に隠せない。守れるのは、ホスト上の保管状態（恒久平文の廃止）と、environ 常駐に伴う意図しない書き出し面（`docker inspect` の `Config.Env`・コアダンプ・Node diagnostic report・全子プロセスへの無差別継承）である。

## 決定した論点（2026-08-06）

1. **dev 鍵の注入方式** — broker 方式へ移行する（上記「dev の起動」）。ホスト恒久平文 `dev/.env.container` は廃止。
2. **対話 prod 作業** — 二段構えを標準手順とする。`/src` の tmpfs（毎回 clone）は維持する。named volume 化は、前回実行のコードが打ったローカル ref の汚染と `.git/config` 経由のコード実行（いずれも実測で再現済み）を復活させるため行わない。
3. **GH_TOKEN の checkout 後破棄** — 維持する。破棄は prod-entrypoint.sh 内の処理であり、dev は entrypoint を通らないため dev の git 操作には影響しない。

いずれも設計書（`docs/prod-secret-isolation-design.md`）rev.9 に反映済み。
