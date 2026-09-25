# karakuri devcontainer

@himorogy の共通 devcontainer の使用方法をまとめます。
この devcontainer を活用することで、下記が可能になります。

- 安全なシークレットの共有および注入
- LLM の暴走を抑制する Firewall （egress 規制）
- postCreate にて個人用開発ツールを導入可能
- プロジェクトごとにドメインを分けることにより、プロジェクト間の port 競合を抑制

主に3つの環境で動くことを確認済みです。併用も可能です。

1. Terminal
2. VSCode
3. Orca ADE

この手順は macOS 向けです。
Windows(Git Bash) は [host-tools/README.md](./host-tools/README.md) の `~/.bash_profile` の記述を参照してください。

**制約事項**

プロジェクト間の port 競合を抑制する都合上、 VSCode の自動ポート転送機能は非推奨となります。
VSCode の devcontainer 拡張を使用した場合、 127.0.0.1:<port> に自動転送される機能は動き続けますが、原則的には後述する loopback アドレス (ex. 127.0.1.1:4588)、またはそのホスト名 (ex. <project>.test:4588)を利用し、明示的にポートフォワーディングの設定を行なってください。

---

## A. 共通セットアップ

一度ホスト側でセットアップすれば、他のプロジェクトで使い回すことができます。
ここでは bitwarden を使用した運用を想定しています。


### A-1. ホスト側に bitwarden cli を導入

Secret を守る重要なツールなので、 Github Release から安定しているバージョンを取得する。

```sh
# bitwarden/clients の Releases（cli-v* タグ）から取得する
VER=<version>
curl -LO "https://github.com/bitwarden/clients/releases/download/cli-v${VER}/bw-oss-macos-${VER}.zip"

# Releases ページに併記されている値と突き合わせる
shasum -a 256 "bw-oss-macos-${VER}.zip"

# PATH の外へ置く
mkdir -p ~/.dev-broker
unzip "bw-oss-macos-${VER}.zip" && mv bw ~/.dev-broker/bw && chmod +x ~/.dev-broker/bw

# 初回実行が隔離属性で止まる場合
xattr -d com.apple.quarantine ~/.dev-broker/bw

# アカウントへのログイン
~/.dev-broker/bw login
```


### A-2. ホスト側に karakuri cli を導入

- git 経由で取得
  - `git clone --depth 1 --branch host-tools-v1.0.0 https://github.com/himorogy/karakuri.git ~/.config/karakuri`
- 下記を `.zshrc` に追加

```zsh
export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
. ~/.config/karakuri/host-tools/karakuri.sh

function dock() {
  karakuri-dock -p "$1-dev" -b "$1" -H "devc-$1" -w "/workspaces/$1" "${@:2}"
}
```

- 初回 1 回だけ `karakuri-loopback install` を実行する
  - `/etc/hosts` の管理ブロックと、loopback 別名を再起動を跨いで張り直す LaunchDaemon を置く
  - sudo のパスワードを聞かれる


### A-3. SSH 接続用鍵ペアの作成

- devcontainer 接続専用の鍵ペアを作成する
  - 一度使ったら使い回し可能
  - ex. `mkdir -p ~/.ssh/keys/devc && ssh-keygen -t ed25519 -f ~/.ssh/keys/devc/id_ed25519 -N ""`


### A-4. bitwarden に共通のセキュアメモを追加

**env/_common/dev**: 全プロジェクト共通で使用する情報を格納

```dotenv
SSH_AUTHORIZED_KEYS=<A-3 で生成した id_ed25519.pub の全文> # 必須
```

---

## B. セットアップ

以下の <project> は各プロジェクトの名称に読み替えてください。


### B-1. プロジェクトのクローン

コンテナには、ホスト側レポジトリの1階層上のフォルダがマウントされます。
下記の構造にすることで、 git worktree を使った開発を行う場合でも worktree がホスト側に同期され、コンテナリビルドで消失することを防ぎます。

```sh
mkdir <project>-workspaces && cd "$_"
git clone https://github.com/<org>/<project>.git
```

### B-2. SSH Config の追加 と loopback の設定

- 本プロジェクトで使用する loopback アドレス（ex. 127.0.1.1）とホスト（ex. <project>.test）を決める
  - 他プロジェクトと重複しないものを選択すること。設定済みの値は `karakuri-loopback list` で確認できる
- `karakuri-loopback` コマンドを使用して `/etc/hosts` にエントリを追加
  - ex. `karakuri-loopback add 127.0.1.1 <project>.test`
- SSH Config に下記を追加
  - 使用するポートを明示的に指定する
  - 下記例はプロジェクト共通で使用できるレビューツール crit の設定。ポートフォワーディングをすることにより `http://127.0.1.1:4588` および `http://<project>.test:4588` で crit にアクセスできるようになる

```ssh-config
Host devc-<project>
    HostName <project>-dev
    LocalForward <loopback アドレス>:4588 localhost:4588 # crit

Host devc-*
    User node
    IdentityFile <A-3 で生成した id_ed25519 のパス>
    IdentitiesOnly yes
    ProxyCommand ~/.config/karakuri/host-tools/dock.sh -p %h --stdio
    ControlMaster auto
    ControlPath ~/.ssh/cm-%n
    ControlPersist no
    ExitOnForwardFailure yes
    # コンテナは作り直す度にホスト鍵が変わる。経路は docker exec で完結し
    # ネットワーク上を通らないため、ホスト鍵の検証は行わない。
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

### B-3. bitwarden に下記のセキュアメモを追加

**env/<project>/dev**: 当プロジェクトで使用する個人秘密情報を格納（ex. 個人の GH_TOKEN）

```dotenv
GH_TOKEN=<個人の GH_TOKEN> # 必須：本レポジトリに限定した Fine-grained token にし、必要最低限の permission を設定すること
```

**env/<project>/shared/dev**: 当プロジェクトで使用する共有秘密情報を格納。格納するキーは管理者が指定します。管理者から共有されるので、**原則的に更新しないこと**。


### B-4. コンテナの立ち上げ

- Terminal で開発を行う場合: `dock <project>`
- VSCode / Orca ADE で開発を行う場合: `dock <project> up` でコンテナを立ち上げてから接続する

いずれも bitwarden のパスワードを入力するとコンテナが立ち上がります。

---

## devcontainer への個人用開発ツールの導入

ホスト側の `~/.config/devc-personal/setup.sh` が postCreateCommand で発火します。
個人で使いたいツールはここでインストールしてください。

下記は starship を入れるサンプルです。

```bash
#!/usr/bin/env bash

set -euo pipefail

STARSHIP_VERSION="v1.26.0"

BIN="$HOME/.local/bin"
ARCH="$(uname -m)"

warn() {
  printf 'warn: %s\n' "$*" >&2
}

install_starship() {
  # 作業ユーザは node であり apt は使えないため、配布元の tarball から$HOME/.local/bin へ実行ファイルを置く形を取る
  local url="https://github.com/starship/starship/releases/download/${STARSHIP_VERSION}/starship-${ARCH}-unknown-linux-musl.tar.gz"
  local tmp

  command -v starship >/dev/null 2>&1 && return 0

  tmp="$(mktemp -d)"

  if curl -fsSL --retry 2 --max-time 300 "$url" | tar -xzf - -C "$tmp"; then
    install -D -m 755 "$tmp/starship" "$BIN/starship"
  else
    warn "starship の取得に失敗: ${url}"
  fi

  rm -rf "$tmp"
}

case "$ARCH" in
  aarch64 | x86_64) install_starship ;;
  *) warn "未対応のアーキテクチャ: ${ARCH}" ;;
esac
```
