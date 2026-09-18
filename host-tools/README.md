# host-tools

**何のために。**
この配布単位に入っているものは、dev container へ bind mount される workspace の外——ホストの固定パス——へ置くためにある。
workspace の中に置くと、そこに常駐する LLM エージェントがこれらを書き換えられ、正規の broker を呼ぶ前後で鍵を複製する経路や、別のイメージで prod を起動する経路が成立する。
ファイルを個別にコピーせず clone で受け取るのは、コピーが増えるほど手元のものが正本と同じかを確かめる手段が無くなるからで、clone なら書き換えは `git status` に出る。

## 入手

対象のホストは macOS と Windows(Git Bash / MSYS2) の 2 つで、Linux はホストとしては対象にしない。

```sh
git clone --depth 1 --branch host-tools-v1.0.0 https://github.com/himorogy/karakuri.git ~/.config/karakuri
```

タグは `host-tools-v*` の系列で、イメージのリリースタグ（`runtime-base-v*`）とは別の版を表す。

`~/.config/karakuri/host-tools` を `PATH` へ足すか、そこから `~/.local/bin/` へ symlink を張る。
Windows(Git Bash) の `~` は `git clone` を打った Git Bash 上のホームで、パスは Unix 形式（`/c/Users/<name>/...`）になる。

`.zshrc` / `.bashrc` から `karakuri.sh` を source する。

```sh
. ~/.config/karakuri/host-tools/karakuri.sh
```

関数の一覧と、環境変数の説明・現在値は `karakuri-help` が出す。
短い名前は利用者の側で alias を付ける（例は `karakuri.sh` の末尾にある）。

Windows(Git Bash) では `~/.bash_profile` に書く。
Git Bash は login shell として起動し、`ssh <host> bash -lc` の経路も login shell なので、`~/.bashrc` にしか書いていないとリモート実行だけ関数が見つからない。

更新は明示的に行う。
`git pull` で追随させない——未リリースの状態が prod の経路に入りうる。

```sh
git -C ~/.config/karakuri fetch --tags
git -C ~/.config/karakuri log --oneline HEAD..origin/main -- host-tools/
git -C ~/.config/karakuri checkout host-tools-v<new>
```

## broker

**何のために。**
秘密鍵を保管し、認可を経て dotenv 形式で stdout に出すコマンド。
鍵を環境変数にもファイルにも置かずに prod と dev へ渡すための唯一の供給元である。

契約さえ満たせば実装は問わない。

1. dotenv 形式（`KEY=value` 行）を stdout に出力する
2. 保管中の実体が不揮発ストレージ上で平文でない
3. 取得時に認可（マスターパスワード等のプロンプト）が働く
4. 非対話環境で認可を得られない場合は非ゼロ終了する
5. stdout 以外へ secret を出さない

鍵束は git 管理しない。
中身は運用者ごとの個人資格情報であり、git 管理する暗号化物はプロジェクト共有の `.env.prod` だけである。

### bw 本体を用意する

**何のために。**
標準の broker は Bitwarden CLI を呼ぶが、bw 本体は karakuri の配布物ではないので clone には含まれない。

**native ビルドを取る。`npm install -g @bitwarden/cli` は使わない。**
npm 版はインストール時に postinstall が走り、update で版が黙って動き、node の版ごとのインストールになるため node を切り替えた瞬間に消える。

```sh
# bitwarden/clients の Releases（cli-v* タグ）から取得する
VER=<version>
curl -LO "https://github.com/bitwarden/clients/releases/download/cli-v${VER}/bw-macos-${VER}.zip"

# Releases ページに併記されている値と突き合わせる
shasum -a 256 "bw-macos-${VER}.zip"

# PATH の外へ置く
mkdir -p ~/.dev-broker
unzip "bw-macos-${VER}.zip" && mv bw ~/.dev-broker/bw && chmod +x ~/.dev-broker/bw

# 初回実行が隔離属性で止まる場合
xattr -d com.apple.quarantine ~/.dev-broker/bw

~/.dev-broker/bw login
```

Windows なら `bw-windows-<VER>.zip` を同じ手順で。

**`~/.dev-broker/` は PATH に入れない。**
PATH 上のディレクトリへ置くと、バージョンマネージャの shim など PATH 順で先に来たものが勝ちうる。

```sh
export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
```

鍵束は Secure Note に dotenv 形式の全文で置き、チーム共有分と個人分を別の項目に分ける。
項目名は `karakuri-broker-env <dev|prod> <project>` が出す。

**`BW_SESSION` をシェルへ export して常駐させない。**
常駐している間は、同一ユーザーで走る任意のプロセスが無認可で vault を読める。

**保証。**
[`tests/broker-bitwarden.test.sh`](./tests/broker-bitwarden.test.sh)。

## `karakuri-run` — ホストで実行するコマンドへ鍵を渡す

**何のために。**
Electron やネイティブ拡張を持つプロジェクトなど、ホストでしかビルドできないもの向けの入口。
dev container も prod も経由しない。

```sh
karakuri-run -b <broker-key> [-e dev|prod] -- <cmd> [args...]

karakuri-run -b acme -- dotenvx run -f .env -- pnpm build
```

**どう動くか。**
`-e prod` を選ぶと、本番の私鍵がホストのビルド木に入り、その木で走る依存・postinstall・ビルドツールの子プロセス全部から読める。
`prod-run.sh` が持つ隔離（tmpfs のコンテナで走り、workspace を mount しない）はホストのビルドでは構造的に取れないので、既定は `dev` で、`prod` は明示的に打たせる。

**保証。**
[`tests/host-run.test.sh`](./tests/host-run.test.sh) と [`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## `_dotenvx` — ホスト側の shim

**何のために。**
`pnpm run` は `node_modules/.bin` を PATH の先頭に積むため、素の `dotenvx` という名前ではプロジェクトのローカル版に必ず負ける。
`package.json` の呼び出しを `_dotenvx` へ揃えておけば、ローカル版が勝てるのは `dotenvx` という名前の解決だけなので、鍵の関門が迂回されない。

Windows 用の `_dotenvx.cmd` も同梱する。
`pnpm` の run-script は Windows で cmd.exe から起動するため、拡張子の無いスクリプトは PATH に置いても解決されない。

### CI から解決する

**何のために。**
`_dotenvx` へ揃えた `package.json` のスクリプトは CI からも呼ばれるが、runner には shim が無い。

```sh
git clone --depth 1 --branch host-tools-v1.0.0 https://github.com/himorogy/karakuri.git "$RUNNER_TEMP/karakuri"
export PATH="$RUNNER_TEMP/karakuri/host-tools/shims:$PATH"
```

鍵は secrets から環境変数で渡せばそのまま通る。
Windows runner でも同じレシピが成立する——パスは runner のテンポラリディレクトリを使い、POSIX 固定のパスは書かない。

**どう動くか。**
移行の直後は CI が赤くなりうる。
落ちるのは鍵が供給されていないジョブで、それまで dotenvx が暗号文を値として注入したまま成功に見えていたものが顕在化しただけである。

利用側が受け入れのために行う作業:

- `package.json` の dotenvx 呼び出しを `_dotenvx` へ揃える
- ホスト実行の入口を `karakuri-run` 経由にする
- ワークツリーに置いていた dotenvx の私鍵ファイルを消す
- CI に shim ディレクトリの `PATH` を足す（上記レシピ）

**保証。**
[`tests/host-shim.test.sh`](./tests/host-shim.test.sh) と [`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## prod

**何のために。**
prod のコマンドは、明示した commit sha から復元した使い捨てのコンテナの中で走らせる。
dev が書いたコードを prod が実行する経路の唯一のゲートは deploy 前の人間のレビューで、その前提は「レビューした対象と流したものが一致する」ことにある。
ブランチ名はその一致を切るので、完全な commit sha 以外は既定で拒否する（正本は [`compose.prod.yaml`](./compose.prod.yaml) の `GIT_REF` のコメント）。

### compose ファイルを置く

`compose.prod.yaml` はプロジェクトごとに 1 枚持つ。
置き場所をまとめて `KARAKURI_PROD_COMPOSE_DIR` に指すと、prod 系の関数が repo 名から `<repo>.yaml` を引く。

```
~/.config/prod-compose/
  <repo>.yaml
```

[`compose.prod.yaml`](./compose.prod.yaml) をこの名前でコピーし、`image:` の digest を実在のものへ差し替える。
`karakuri-image-digest <tag>` が貼り付け用の行を出す。

全プロジェクトで 1 枚を共有する `KARAKURI_PROD_COMPOSE` も残してあるが、その場合はイメージの更新が全プロジェクトへ一斉に適用される。

**この置き場所は git リポジトリにしてよい。ただしどの devcontainer にも mount しない。**
mount した時点で、この構成は「書き換えられないもの」から「書き換えられたら diff に出るもの」へ落ちる。

### 実行する（`karakuri-prod-run` / `karakuri-prod-exec`）

```sh
karakuri-prod-exec acme/app <sha> dotenvx get -f .env.prod
```

`dotenvx` は `pnpm` の外側に置く（理由は `prod-run.sh` の usage）。

### 対話シェルが要る場合

stdin が secret の搬送路なので、`docker compose run` の対話 TTY とは両立しない。
二段構えにする。

```sh
karakuri-prod-base acme/app <sha>   # 端末 1。前面で動かす
karakuri-prod-shell app             # 端末 2
```

**保証。**
[`tests/prod-run.test.sh`](./tests/prod-run.test.sh) と [`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## dev

**何のために。**
dev container の `/run/secrets` は tmpfs で、コンテナを起動するたびに空になる。
起動のたびに broker から注入し直す経路を `karakuri-dev-inject` が、注入まで含めた入室を `karakuri-dock` が持つ。

**どう動くか。**
SSH port forwarding（`karakuri-port-forward`）を使う場合は、`~/.ssh/config` の設定と、初回 1 回の `karakuri-loopback install` が要る。
設定の書き方と、`ProxyCommand` に `dock.sh` の絶対パスを書く理由は [`images/devcontainer-base/PORT-FORWARDING.md`](../images/devcontainer-base/PORT-FORWARDING.md) にある。

**保証。**
[`tests/dev-inject.test.sh`](./tests/dev-inject.test.sh)、[`tests/dock.test.sh`](./tests/dock.test.sh)、[`tests/loopback-setup.test.sh`](./tests/loopback-setup.test.sh)、[`tests/karakuri.test.sh`](./tests/karakuri.test.sh)。

## リリース

`host-tools-v*` のタグを打つ。

```sh
git tag host-tools-v1.0.0 && git push origin host-tools-v1.0.0
```

このタグはどのワークフローのトリガにも一致しないので CI は動かず、リポジトリのある時点に名前が付くだけである。
