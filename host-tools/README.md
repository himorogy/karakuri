# host-tools

## これは何か

karakuri のうち、ホスト側で使用できる utility。
担うのは 2 つで、broker から鍵を取り出してコンテナの stdin へ流す搬送路と、dev / prod のコンテナへ入る入口である。
コンテナの中身（イメージ・entrypoint・コンテナ側の shim）は別の配布物が持ち、こちらはそれを起動する側だけを持つ。

利用側へは `host-tools-v*` タグの clone として渡る。
ファイルを個別にコピーせず clone で受け取るのは、コピーが増えるほど手元のものが正本と同じかを確かめる手段が無くなるからで、clone なら書き換えは `git status` に出る。

**置き場所**
clone は dev container へ bind mount される workspace の外——ホストの固定パス——へ置く。
workspace の中に置くと、そこに常駐する LLM エージェントがこれらを書き換えられ、正規の broker を呼ぶ前後で鍵を複製する経路や、別のイメージで prod を起動する経路が成立する。

## 同梱されているコマンド

`karakuri.sh` は source して使う関数ファイルで、下の `karakuri-*` はすべてここが定義する。
一覧と、環境変数の説明・現在値は `karakuri-help` が出す。

**鍵を出す**

- `karakuri-broker-command` / `karakuri-broker-env` — broker の実行ファイルと、それへ渡す環境変数を決める差し替え点
- `broker-bitwarden.sh` — Bitwarden CLI を呼ぶ標準の broker

**鍵を渡す**

- `karakuri-dev-inject` — 起動済みの dev container へ鍵を注入する（注入先が tmpfs なので、コンテナを起動するたびに 1 回要る）
- `karakuri-run` — コンテナを経由せず、ホストで実行するコマンドへ鍵を渡す
- `karakuri-prod-run` / `karakuri-prod-exec` — 使い捨ての prod コンテナで、指定した commit sha へ復元したコードを実行する（前者は依存の install を挟み、後者は渡したコマンドをそのまま走らせる）
- `karakuri-prod-base` / `karakuri-prod-shell` — 対話 prod 作業の土台を起動し、別の端末からそこへ入る

**コンテナへ入る**

- `karakuri-dock` — dev container を使える状態にしてから入る
- `dock.sh` — `karakuri-dock` の実行ファイル版で、シェル関数を見ない ssh の `ProxyCommand` からは絶対パスでこちらを呼ぶ

**転送と名前解決**

- `karakuri-port-forward` — ssh の転送を張り直す
- `karakuri-loopback` — `/etc/hosts` と loopback 別名を設定する

**イメージの digest**

- `karakuri-image-digest` — タグから digest を引き、compose へ貼れる `image:` 行を出す
- `karakuri-check-image` — compose に書かれた digest と、タグの現在の digest を照合する

このほかに `shims/_dotenvx`（ホスト側の dotenvx shim）と `compose.prod.yaml`（prod コンテナの定義のひな形）が入っている。
`dev-inject.sh` / `prod-run.sh` / `host-run.sh` / `loopback-setup.sh` は上の関数が呼ぶ下位スクリプトで、直接打つ必要はない。

## 推奨の使い方

### 初回インストール

対象のホストは macOS と Windows(Git Bash / MSYS2) の 2 つで、Linux はホストとしては対象にしない。
clone と `.zshrc` への追記の手順は [`DEVCONTAINER.md`](../DEVCONTAINER.md) の「共通セットアップ」にある。

タグは `host-tools-v*` の系列で、イメージのリリースタグ（`runtime-base-v*`）とはリンクしていない。

`~/.config/karakuri/host-tools` を `PATH` へ足すか、そこから `~/.local/bin/` へ symlink を張る。
Windows(Git Bash) の `~` は `git clone` を打った Git Bash 上のホームで、パスは Unix 形式（`/c/Users/<name>/...`）になる。

Windows(Git Bash) では `karakuri.sh` の source を `~/.bash_profile` に書く。
Git Bash は login shell として起動し、`ssh <host> bash -lc` の経路も login shell なので、`~/.bashrc` にしか書いていないとリモート実行だけ関数が見つからない。

### 更新

更新は明示的に行う。
`git pull` で追随させない——未リリースの状態が prod の経路に入りうる。

```sh
git -C ~/.config/karakuri fetch --tags
git -C ~/.config/karakuri log --oneline HEAD..origin/main -- host-tools/
git -C ~/.config/karakuri checkout host-tools-v<new>
```

### alias と設定の例

短い名前は利用者の側で付ける。
alias は関数にも効き、引数もそのまま渡るので、下をそのまま `.zshrc` / `.bashrc` へ写せばよい。

```sh
alias pf='karakuri-port-forward'
alias dev-inject='karakuri-dev-inject'
alias prod-run='karakuri-prod-run'
alias prod-exec='karakuri-prod-exec'
alias prod-base='karakuri-prod-base'
alias prod-shell='karakuri-prod-shell'
```

`karakuri-dock` だけは alias ではなく短い関数にする。
compose project 名・broker アイテムキー・ssh Host 別名・workspace を引数で受け取るだけで `<project>-dev` のような規約を組み立てないので、引数をそのまま渡す口しか持たない alias では足りない。

```sh
dock() { karakuri-dock -p "$1-dev" -b "$1" -H "devc-$1-dev" -w "/workspaces/$1" "${@:2}"; }
```

これを配布物に入れないのは、`dock` という汎用的な名前を利用者のシェルへ勝手に持ち込まないためである。
bash に貼る場合、閉じ括弧の前の `;` は省略できない（zsh は省略できる）。

環境変数はこの形で設定する。

```sh
export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
export KARAKURI_ORG=acme
export KARAKURI_PROD_COMPOSE_DIR="$HOME/.config/acme/compose"   # <repo>.yaml を並べる
```

### bw 本体を用意する

**何のために**
標準の broker は Bitwarden CLI を呼ぶ（採用の理由は下記「broker」）。
bw 本体は karakuri の配布物ではないので clone には含まれない。
取得の手順は [`DEVCONTAINER.md`](../DEVCONTAINER.md) の「ホスト側に bitwarden cli を導入」にある。

**native ビルドを取る。`npm install -g @bitwarden/cli` は使わない**
npm 版はインストール時に postinstall が走り、update で版が黙って動き、node の版ごとのインストールになるため node を切り替えた瞬間に消える。

Windows では、同じ Releases の `bw-oss-windows-<VER>.zip` を同じ手順で置く。

**`~/.dev-broker/` は PATH に入れない**
PATH 上のディレクトリへ置くと、バージョンマネージャの shim など PATH 順で先に来たものが勝ちうる。
broker が呼ぶ実体は `KARAKURI_BW_BIN` で絶対パスを名指しする（設定例は上記「alias と設定の例」）。

鍵束は Secure Note に dotenv 形式の全文で置き、チーム共有分と個人分を別の項目に分ける。
項目名は `karakuri-broker-env <dev|prod> <project>` が出す。

**`BW_SESSION` をシェルへ export して常駐させない**
常駐している間は、同一ユーザーで走る任意のプロセスが無認可で vault を読める。

### dev container に入る

**何のために**
dev container の `/run/secrets` は tmpfs で、コンテナを起動するたびに空になる。
起動のたびに broker から注入し直す経路を `karakuri-dev-inject` が、注入まで含めた入室を `karakuri-dock` が持つ。

**どう動くか**
SSH port forwarding（`karakuri-port-forward`）を使う場合は、`~/.ssh/config` の設定と、初回 1 回の `karakuri-loopback install` が要る。
設定の書き方と、`ProxyCommand` に `dock.sh` の絶対パスを書く理由は [`images/devcontainer-base/PORT-FORWARDING.md`](../images/devcontainer-base/PORT-FORWARDING.md) にある。

**保証**
[`tests/dev-inject.test.sh`](./tests/dev-inject.test.sh)、[`tests/dock.test.sh`](./tests/dock.test.sh)、[`tests/loopback-setup.test.sh`](./tests/loopback-setup.test.sh)、[`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

### prod でコマンドを実行する

**何のために**
prod のコマンドは、明示した commit sha から復元した使い捨てのコンテナの中で走らせる。
dev が書いたコードを prod が実行する経路の唯一のゲートは deploy 前の人間のレビューで、その前提は「レビューした対象と流したものが一致する」ことにある。
ブランチ名はその一致を切るので、完全な commit sha 以外は既定で拒否する（正本は [`compose.prod.yaml`](./compose.prod.yaml) の `GIT_REF` のコメント）。

先に compose ファイルを置く（下記「compose ファイルの置き場所と digest」）。

```sh
karakuri-prod-exec acme/app <sha> dotenvx get -f .env.prod
```

`dotenvx` は `pnpm` の外側に置く（理由は `prod-run.sh` の usage）。

**対話シェルが要る場合**
stdin が secret の搬送路なので、`docker compose run` の対話 TTY とは両立しない。
二段構えにする。

```sh
karakuri-prod-base acme/app <sha>   # 端末 1。前面で動かす
karakuri-prod-shell app             # 端末 2
```

**保証**
[`tests/prod-run.test.sh`](./tests/prod-run.test.sh) と [`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## 仕組みと応用

### broker

**何のために**
秘密鍵を保管し、認可を経て dotenv 形式で stdout に出すコマンド。
鍵を環境変数にもファイルにも置かずに prod と dev へ渡すための、唯一の供給元である。

標準に Bitwarden CLI を採用しているのは、下の契約を素の状態で満たしたうえで、対象ホストの 2 つで同じ broker が動き、チーム共有の鍵束と個人の鍵束を項目の並びだけで扱えるからである。
契約をどう満たしているかの内訳は `broker-bitwarden.sh` の冒頭にある。

**どう動くか**
契約さえ満たせば実装は問わない。

1. dotenv 形式（`KEY=value` 行）を stdout に出力する
2. 保管中の実体が不揮発ストレージ上で平文でない
3. 取得時に認可（マスターパスワード等のプロンプト）が働く
4. 非対話環境で認可を得られない場合は非ゼロ終了する
5. stdout 以外へ secret を出さない

鍵束は git 管理しない。
中身は運用者ごとの個人資格情報であり、git 管理する暗号化物はプロジェクト共有の `.env.prod` だけである。

**保証**
[`tests/broker-bitwarden.test.sh`](./tests/broker-bitwarden.test.sh)。

### ホストで実行するコマンドへ鍵を渡す（`karakuri-run` と `_dotenvx`）

**何のために**
Electron やネイティブ拡張を持つプロジェクトなど、ホストでしかビルドできないものにも鍵が要る。
`karakuri-run` が broker から取り出した鍵を environ に置いてコマンドを起動し、`_dotenvx` がその鍵の有無を関門にする。

```sh
karakuri-run -b <broker-key> [-e dev|prod] -- <cmd> [args...]

karakuri-run -b acme -- dotenvx run -f .env -- pnpm build
```

**どう動くか**
`pnpm run` は `node_modules/.bin` を PATH の先頭に積むため、素の `dotenvx` という名前ではプロジェクトのローカル版に必ず負ける。
`package.json` の呼び出しを `_dotenvx` へ揃えておけば、ローカル版が勝てるのは `dotenvx` という名前の解決だけなので、関門が迂回されない。

Windows 用の `_dotenvx.cmd` も同梱する。
`pnpm` の run-script は Windows で cmd.exe から起動するため、拡張子の無いスクリプトは PATH に置いても解決されない。

`-e prod` を選ぶと、本番の私鍵がホストのビルド木に入り、その木で走る依存・postinstall・ビルドツールの子プロセス全部から読める。
`prod-run.sh` が持つ隔離（tmpfs のコンテナで走り、workspace を mount しない）はホストのビルドでは構造的に取れないので、既定は `dev` で、`prod` は明示的に打たせる。

#### CI から `_dotenvx` を解決する

`_dotenvx` へ揃えた `package.json` のスクリプトは CI からも呼ばれるが、runner には shim が無い。

```sh
git clone --depth 1 --branch host-tools-v1.0.0 https://github.com/himorogy/karakuri.git "$RUNNER_TEMP/karakuri"
export PATH="$RUNNER_TEMP/karakuri/host-tools/shims:$PATH"
```

鍵は secrets から環境変数で渡せばそのまま通る。
Windows runner でも同じレシピが成立する——パスは runner のテンポラリディレクトリを使い、POSIX 固定のパスは書かない。

移行の直後は CI が赤くなりうる。
落ちるのは鍵が供給されていないジョブで、それまで dotenvx が暗号文を値として注入したまま成功に見えていたものが顕在化しただけである。

利用側が受け入れのために行う作業:

- `package.json` の dotenvx 呼び出しを `_dotenvx` へ揃える
- ホスト実行の入口を `karakuri-run` 経由にする
- ワークツリーに置いていた dotenvx の私鍵ファイルを消す
- CI に shim ディレクトリの `PATH` を足す（上記レシピ）

**保証**
[`tests/host-run.test.sh`](./tests/host-run.test.sh)、[`tests/host-shim.test.sh`](./tests/host-shim.test.sh)、[`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

### compose ファイルの置き場所と digest

**何のために**
`compose.prod.yaml` は prod の防御（`read_only`・tmpfs の記法・`cap_drop`・`init: true`）を宣言している当のものなので、エージェントが到達できる場所へは置かない。

**この置き場所は git リポジトリにしてよい。ただしどの devcontainer にも mount しない**
mount した時点で、この構成は「書き換えられないもの」から「書き換えられたら diff に出るもの」へ落ちる。

**どう動くか**
`compose.prod.yaml` はプロジェクトごとに 1 枚持つ。
置き場所をまとめて `KARAKURI_PROD_COMPOSE_DIR` に指すと、prod 系の関数が repo 名から `<repo>.yaml` を引く。

```
~/.config/prod-compose/
  <repo>.yaml
```

[`compose.prod.yaml`](./compose.prod.yaml) をこの名前でコピーし、`image:` の digest を実在のものへ差し替える。
`karakuri-image-digest <tag>` が貼り付け用の行を出す。

全プロジェクトで 1 枚を共有する `KARAKURI_PROD_COMPOSE` も残してあるが、その場合はイメージの更新が全プロジェクトへ一斉に適用される。

**保証**
[`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## リリース

`host-tools-v*` のタグを打つ。

```sh
git tag host-tools-v1.0.0 && git push origin host-tools-v1.0.0
```

このタグはどのワークフローのトリガにも一致しないので CI は動かず、リポジトリのある時点に名前が付くだけである。
