# 推奨 devcontainer / prod 構成例

dev container には LLM エージェントが常駐するため信頼しない。prod container は人間が明示的に起動し、prod の秘匿情報は broker → stdin → コンテナ内 tmpfs の経路だけを流れる（設計の全体像は `docs/prod-secret-isolation-design.md`）。

本ディレクトリのファイルとコピー先の対応:

| 本ディレクトリ | コピー先 | 役割 |
| --- | --- | --- |
| `Dockerfile` | `<repo>/.devcontainer/Dockerfile` | dev イメージ（devcontainer-base + egress-guard 設定） |
| `docker-compose.yaml` | `<repo>/.devcontainer/docker-compose.yaml` | dev container の定義 |
| `docker-compose.prod.yaml` | `~/.config/<project>/compose.prod.yaml` | prod container の定義（配布テンプレートのコピー） |

## 推奨配置

配布テンプレート（`images/runtime-base/templates/`）は置き場所で二つに分かれている。
`templates/host/` はホストの固定パスへ置くもの、`templates/project/` はプロジェクトの
リポジトリへ置くもの。`compose.prod.yaml` は名前だけ見るとプロジェクトの
リポジトリに置くものに見えるが、`host/` にある。`prod-run.sh` の `PROD_COMPOSE_FILE` が
指す先であり、下記のとおりホストの固定パス（`~/.config/<project>/`）に置く。

`host/` 側はファイルを個別にコピーせず、karakuri をタグ指定で clone してそのまま使う
（詳細は [`images/runtime-base/README.md`](../images/runtime-base/README.md) の
「ホスト側ツールを入手する」）。コピーが増えるほど「手元のものが正本と同じか」を確かめる
手段が無くなるためで、clone なら手を加えれば `git status` に出る。

```
~/.config/karakuri/            # dev workspace の外（ホスト固定パス）。タグ指定で clone
  images/runtime-base/templates/host/
    prod-run.sh
    dev-inject.sh
    broker-bitwarden.sh          # broker 標準実装
    broker-macos-keychain.sh     # 代替: macOS Keychain broker（登録ツール broker-macos-keychain-set.sh と対）
    karakuri.sh                  # 呼び出し規約。.zshrc / .bashrc から source する
~/.local/bin/                  # 上記を解決するための symlink（または PATH に直接足してもよい）
~/.dev-broker/                 # PATH の外。broker が名指しするバイナリを置く専用の場所
  bw                            # Bitwarden CLI（native ビルドを SHA-256 照合の上配置。karakuri の配布物ではない）
~/.config/prod-compose/        # ホスト上の git リポジトリ。どの devcontainer にも mount しない
  app.yaml                     # templates/host/compose.prod.yaml のコピーを <repo>.yaml で置く。
                                # image の digest を実在のものへ差し替える
  <other-repo>.yaml            # プロジェクトごとに 1 枚
<project repo>/                # dev container にマウントされる（git 管理）
  env-guard.conf                 # templates/project/env-guard.conf のコピー
  .devcontainer/
    Dockerfile
    docker-compose.yaml
```

karakuri の clone・broker・compose.prod.yaml を workspace の外に置くのは必須。workspace は
ホストへ bind mount されており、リポジトリ内に置くと dev container 内のエージェントがこれらを
書き換えられる（正規 broker の前後に鍵を複製するコードを仕込む、compose から `read_only` /
tmpfs を外す等）。禁じているのは置き場所であって、git リポジトリの中にあること自体ではない —
`~/.config/karakuri` は bind mount されない別の clone なので、そこから実行してよい。

compose.prod.yaml はプロジェクト固有値を含まない設計なので、全プロジェクトで 1 枚を共有することもできる（`KARAKURI_PROD_COMPOSE` に単一ファイルを指す）。ただしその場合は runtime-base の digest pin も全プロジェクトで共通になり、イメージ更新が一斉適用になる。既定は上のようにプロジェクトごとに分ける形とする。

**この置き場所は git リポジトリにしてよい。ただしどの devcontainer にも mount しないこと。** compose.prod.yaml は prod の防御（`read_only`・tmpfs の記法・`cap_drop`・`init: true`）を宣言している当のもので、エージェントが到達できる場所に置けば防御そのものが書き換え対象になる。git 管理の目的は改竄検知ではなく、digest をいつ上げたかの履歴を残すことにある — 到達不能なら検知は要らない。

逆に言えば、**mount した時点でこの構成は「書き換えられないもの」から「書き換えられたら diff に出るもの」へ落ちる。** `git diff` は後から見れば分かるという性質であって、書き換えを止めはしない。エージェントが書き換えて commit すれば、人間がレビューしない限り正当な変更に見える。

## prod の起動

`.zshrc`:

```sh
export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
export KARAKURI_PROD_COMPOSE_DIR="$HOME/.config/prod-compose"

# 任意。扱う org が一つに定まる場合だけ設定する
export KARAKURI_ORG=acme

. ~/.config/karakuri/images/runtime-base/templates/host/karakuri.sh
```

`KARAKURI_PROD_COMPOSE_DIR` には、プロジェクトごとの compose ファイルを `<repo>.yaml` の名前で
並べる。全プロジェクトで 1 枚を共有する運用（`KARAKURI_PROD_COMPOSE` に単一ファイルを指す）も
残してあるが、prod のイメージを一斉に更新することになるので、分けるほうを既定とする。

環境変数の並べ方（`BROKER_BW_ITEM` の項目名、`COMPOSE_PROJECT_NAME` の付け方）は
`karakuri.sh` が引き受けるので、`.zshrc` に残るのは環境そのもの（bw の在処・compose
ファイルの配置先）だけになる。起動は関数呼び出しになる。

`KARAKURI_ORG` は必須ではない。**複数の org を扱っていて一つに定まらないなら、設定しない方がよい。**
リポジトリは `<org>/<repo>` の 1 引数で渡せるので、org を毎回明示すれば済む。設定するのは
「ほとんどの場合これ」という org がある場合だけで、その場合もスラッシュ付きで渡せば上書きできる。

```sh
karakuri-prod-exec app 1234567890abcdef1234567890abcdef12345678 \
  sh -c 'pnpm install --frozen-lockfile && dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy'
```

`karakuri-prod-exec` はタスクランナーを挟まず、渡した引数をそのまま prod へ渡す。install と
dotenvx をまとめて 1 コマンドにしているのは、`dotenvx` を `pnpm` の外側に置く必要があるため
（下記「挙動と制約」を参照 — `pnpm <task>` は `node_modules/.bin` を PATH の先頭に積むため、
その内側で dotenvx を呼ぶと shim が素通りされる）。install をタスクランナー任せにしてよい
（dotenvx を挟まない）タスクなら `karakuri-prod-run app <sha> <task>` が
`pnpm install --frozen-lockfile && pnpm <task>` を組み立てる（既定のタスクランナーは pnpm、
`KARAKURI_PROD_INSTALL` / `KARAKURI_PROD_RUN` で上書きできる）。

broker の標準は Bitwarden CLI（`templates/host/broker-bitwarden.sh`）。bw 本体は native ビルドを GitHub Releases から取得し、SHA-256 照合の上 `~/.dev-broker/bw` のような PATH の外の固定パスに配置する（手順は [`images/runtime-base/README.md`](../images/runtime-base/README.md) の「broker 本体（bw）を用意する」。これは karakuri の配布物ではないので clone には含まれない）。鍵束は Secure Note に dotenv 全文で格納し、チーム共有分（DOTENV_PRIVATE_KEY_PROD 等）は共有コレクションの項目、個人分（fine-scoped GH_TOKEN 等）は個人の項目に分ける。

項目名は `env/<project>/shared/prod,env/<project>/prod`（共有 → 個人の順、カンマ区切りで複数項目をマージでき、同名キーは後勝ち）という規約で、以前はこれをプロジェクトごとのラッパースクリプトへ手で書いていたが、いまは `karakuri.sh` 内の `karakuri-broker-env` 関数がこの項目名を組み立てる。プロジェクトごとのラッパーはもう要らない。

broker は差し替え可能というのが契約（各テンプレート冒頭に記載）で、`karakuri.sh` もこれを引き継いでいる。標準の Bitwarden 実装から差し替えるには `karakuri-broker-command` / `karakuri-broker-env` の 2 関数を（`source` した後で）再定義すればよい — broker 固有の知識はこの 2 関数だけに閉じ込められているので、他の関数はここが返すものしか見ない。macOS Keychain を使う代替もある（`broker-macos-keychain.sh`。登録・更新は対になる `broker-macos-keychain-set.sh` で行う — Keychain のプロンプトが 1 行しか受けないため base64 で畳む等の面倒をツールが見る）。1Password 等も、dotenv 全文を stdout に出すラッパーを書けば同じ契約を満たす。

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
karakuri-prod-base app 1234567890abcdef1234567890abcdef12345678

# 端末 2: entrypoint 完了（clone 済み・sleep 稼働）後に入る
karakuri-prod-shell app
```

**コンテナを名前で引いて `head -1` で選んではいけない。** compose.prod.yaml は全プロジェクトで 1 枚を共有できる設計なので、compose project 名を明示しないと、どのプロジェクトの prod を起動しても同じ名前になる。複数のプロジェクトの土台を同時に立てていると、名前で引くフィルタが全部に一致し、`head -1` がそのうち一つを黙って選ぶ。入った先には別プロジェクトの鍵が注入済みで、`/src` には別プロジェクトのコードが clone されている。選択が黙って行われるため、入った本人が気づけない。

`karakuri-prod-base` は `COMPOSE_PROJECT_NAME` をプロジェクトごとに振り、`karakuri-prod-shell` はそれを使って compose 経由でコンテナを引く。該当が 0 件でも複数件でも、推測せずに失敗する。

entrypoint 完了後に exec するため `/run/secrets` は注入済み。1 回の注入・clone でセッションを維持でき、その中で dryrun と適用を続けられる。退出後は端末 1 の Ctrl-C で終了・回収（`--rm`）。`sleep infinity` ではなく時間を切っておくと、stop 忘れがそのまま放置されない。

土台を `run -d`（detach）で起動してはならない。stdin パイプをコンテナへ中継しているのは compose クライアント自身なので、detach した瞬間に搬送路が消える — broker は Broken pipe で死に、entrypoint は EOF を待って取込の行で永久に停止する（実測）。また Ctrl-C / `docker stop` が効くのは compose の `init: true`（`docker-compose.prod.yaml` に設定済み）が前提 — 無いと pid 1 = `sleep` がシグナルを無視する。

## dev の起動

VSCode 等の devcontainer 拡張でそのまま起動してよい。prod-run.sh は使わない（prod-run.sh の経路は prod-entrypoint.sh 専用で、dev container の起動ライフサイクルとは別物）。

dev 鍵（`DOTENV_PRIVATE_KEY_LOCAL` / `_DEVELOPMENT`、dev 用の fine-scoped GH_TOKEN 等）も prod と同じ broker 方式で注入する。従来の `env_file`（`dev/.env.container`）はホスト不揮発ディスク上の恒久平文となるため廃止する。

1. dev 鍵束を Bitwarden に用意する。個人分は `env/<project>/dev`、チーム共有分は共有コレクションの `env/<project>/shared/dev`、**全プロジェクト共通の個人分は `env/_common/dev`**（`_` 接頭辞はプロジェクト名との衝突回避。プロジェクト slug は kebab-case とし、`_` 始まりのプロジェクトを作らない）

   `env/_common/dev` に置くものの代表が **`SSH_AUTHORIZED_KEYS`**（値 = 自分の SSH 公開鍵 1 行、`ssh-ed25519 AAAA... user@host` の形そのまま）。devcontainer-base v2 の sshd が `/run/secrets/SSH_AUTHORIZED_KEYS` を認可鍵として直接読むため、これだけで SSH port forwarding のログインが有効になる（[PORT-FORWARDING.md](../images/devcontainer-base/PORT-FORWARDING.md)）。受託案件などプロジェクト単位で別の鍵を使う場合は `env/<project>/dev` に同名キーを置けば後勝ちで上書きされる
2. コンテナ起動後、ホストで `karakuri-dev-inject` を実行する。broker の出力を `docker exec -i` 経由でコンテナ内の取込スクリプトへパイプし、鍵を `/run/secrets/<VAR 名>`（tmpfs、umask 077）へ書く。

   ```sh
   karakuri-dev-inject app
   ```

   項目名を「共有 → 共通個人 → プロジェクト個人」の順に並べるのも、compose project 名を `<project>-dev` にするのも `karakuri.sh` が引き受ける（同名キーは後勝ち = 右ほど強い。プロジェクト個人が共通個人を上書きする）。以前はこの組み立てを `.zshrc` の関数として手で書いていた

   渡す `<project>` は `.devcontainer/docker-compose.yaml` の `name:` から末尾の `-dev` を除いた値。サービス名が `dev` 以外なら `DEV_SERVICE` で指定する

   コンテナ内のサービスへホストのブラウザから到達するには、続けて `karakuri-pf <project>` で port forwarding を張る（VS Code の自動転送を使う場合は不要）。初回だけ `~/.ssh/config` の設定が要り、macOS では loopback エイリアスの用意（`karakuri-loopback install` を 1 回、プロジェクトごとに `karakuri-loopback add <addr> <hostname>`）も要る。ターミナルからコンテナへ入るのは `karakuri-dock <project>`。いずれも手順は [PORT-FORWARDING.md](../images/devcontainer-base/PORT-FORWARDING.md)

   注入した鍵を npm scripts から使うツール（dotenvx / wrangler / gh）は、scripts 内では **`_` 付きの名前**で書く。pnpm/npm は scripts 実行時に `node_modules/.bin` を PATH 先頭へ差し込むため、素の名前はプロジェクトローカルのバイナリに解決されて shim（鍵注入）が迂回される。`_dotenvx` 等はコンテナ側が用意する明示呼び名で、鍵を注入したうえでローカル版（あればそれ、なければイメージ同梱版）を実行する:

   ```json
   "scripts": {
     "dev": "_dotenvx run -f .env.dev --strict -- next dev"
   }
   ```
3. 以降は shim（dotenvx / gh / wrangler）が実行のたびに対象プロセスへだけ注入する。plain git の fetch / push は `GIT_ASKPASS`（devcontainer-base が ENV と `/etc/environment` の両方に焼き込み済み）が `/run/secrets/GH_TOKEN` を読む（dev では entrypoint を通らないため破棄されない）

   ただし github.com だけは askpass ではなく、イメージ自前の credential helper
   `git-credential-gh-token` が同じ `/run/secrets/GH_TOKEN` を読む（devcontainer-base 2.2.0 以降）。
   VS Code の Dev Containers 拡張は global gitconfig へ credential helper を書き込むうえ、統合
   ターミナルの environ へ `GIT_ASKPASS` を注入して上書きしてくる。helper は設定側なので、環境
   変数による設定で固定すればどちらにも勝てる。**この結果、`GH_TOKEN` を注入していないと private
   repo の https 操作は失敗する**（public repo の clone と ssh remote、github.com 以外のホストは
   影響しない）。狙いと外し方は
   [`images/runtime-base/README.md`](../images/runtime-base/README.md) の「git の認証（github.com）」

dev compose 側の前提（本ディレクトリの `docker-compose.yaml` に反映済み）:

- `/run` が tmpfs（`tmpfs: ["/run:uid=1000,gid=1000,mode=0755"]`）。**これが無いと `/run/secrets` はコンテナの writable layer = ホスト側の不揮発ディスクへ書かれ、平文廃止の意味が消える。** オプション無しの短縮形は root:root 所有になり node ユーザーが `/run/secrets` を作れない点も prod と同じ
- `GIT_ASKPASS` と `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` /
  `GIT_CONFIG_KEY_1` / `GIT_CONFIG_VALUE_1` は compose に書かない。devcontainer-base が焼き込み
  済みで、compose の `environment:` は SSH セッションに届かず経路間で値が食い違うため（base の
  PORT-FORWARDING.md）。base を使わないイメージでは従来どおり compose で設定する。
  `GIT_CONFIG_COUNT` を自分の設定にも使いたい場合は、base が置いている 5 つを引き継いだうえで
  2 番以降に足すこと（カウンタは 1 本しかない）
- `env_file` 節は使わない

注入を忘れた場合は下流の認証失敗として顕在化する（shim は不在なら素通し。ただし dotenvx だけは `--strict` が無いと復号失敗が沈黙する）。`/run` は tmpfs なので、コンテナの再作成だけでなく停止 → 再起動でも消える。**コンテナを起動するたびに、起動後 dev-inject を 1 回**が運用になる（dev-inject は起動ラッパーではない — 起動は従来どおり IDE が行う）。

この方式は dev container 内のエージェントから鍵を隠すためのものではない。エージェントは同一 UID で動くため `/run/secrets` を直接読めるし、shim 経由でツールも使える — 原理的に隠せない。守れるのは、ホスト上の保管状態（恒久平文の廃止）と、environ 常駐に伴う意図しない書き出し面（`docker inspect` の `Config.Env`・コアダンプ・Node diagnostic report・全子プロセスへの無差別継承）である。

## 決定した論点（2026-08-06）

1. **dev 鍵の注入方式** — broker 方式へ移行する（上記「dev の起動」）。ホスト恒久平文 `dev/.env.container` は廃止。
2. **対話 prod 作業** — 二段構えを標準手順とする。`/src` の tmpfs（毎回 clone）は維持する。named volume 化は、前回実行のコードが打ったローカル ref の汚染と `.git/config` 経由のコード実行（いずれも実測で再現済み）を復活させるため行わない。
3. **GH_TOKEN の checkout 後破棄** — 維持する。破棄は prod-entrypoint.sh 内の処理であり、dev は entrypoint を通らないため dev の git 操作には影響しない。

いずれも設計書（`docs/prod-secret-isolation-design.md`）rev.9 に反映済み。
