# syntax=docker/dockerfile:1

# =============================================================================
# crit builder
#
# TARGETARCH 向けにクロスコンパイルする。ビルドは常に BUILDPLATFORM 上で行い、
# arm64 ビルド時の QEMU エミュレーションを回避する。
# =============================================================================
ARG CRIT_VERSION=v0.19.1

# 下段の `FROM ghcr.io/himorogy/runtime-base:${RUNTIME_BASE_VERSION}` が使う。
# **ここから動かさないこと。** FROM の中で参照する ARG は、最初の FROM より前
# (グローバルスコープ) で宣言されていなければならない。ステージの中で宣言した
# ものは、その次の FROM からは見えない。見えないまま空文字に展開されると
# `ghcr.io/himorogy/runtime-base:` という壊れた参照になり、pull を試みる前に
# 「invalid reference format」で落ちる。イメージが取得できないのとは別の失敗で、
# エラーだけを読むと取り違えやすい。
ARG RUNTIME_BASE_VERSION=1

FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS crit-builder

ARG CRIT_VERSION
ARG TARGETOS
ARG TARGETARCH

# GOBIN はクロスコンパイル時に使えないため、go install の出力先が
#   ネイティブ:       /go/bin/crit
#   クロスコンパイル: /go/bin/${GOOS}_${GOARCH}/crit
# と変わる。両方を吸収して /out/crit に正規化する。
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
      go install github.com/tomasz-tomczyk/crit/cmd/crit@${CRIT_VERSION} \
    && mkdir -p /out \
    && cp "$(find /go/bin -type f -name crit | head -n 1)" /out/crit


# =============================================================================
# devcontainer base
#
# images/runtime-base を土台とし、そこに「能力」だけを積み増す。runtime-base
# には node / pnpm / dotenvx / wrangler / git / gh、secret shim、
# prod-entrypoint.sh、egress-guard 本体、git hook (core.hooksPath) が
# 既に入っている。ここでの収録方針:
#   入れる  … npm で入らないもの、または エージェントが直接使うもの
#   入れない… 人間の対話体験にしか効かないもの   -> 個人フック (/personal/setup.sh)
#             npm で入るもの (Biome, dprint 等) -> プロジェクトの devDependency
#             プロジェクト固有のもの (psql 等)  -> プロジェクトの Dockerfile
#             prod container でも使うもの       -> images/runtime-base 側
#               (設計書 docs/prod-secret-isolation-design.md §4.5)
# =============================================================================
# RUNTIME_BASE_VERSION はファイル冒頭のグローバルスコープで宣言してある。
FROM ghcr.io/himorogy/runtime-base:${RUNTIME_BASE_VERSION}

ARG USERNAME=node

# TZ / LANG / LC_ALL は images/runtime-base の ENV としてこの層にも
# 引き継がれているため、ここで ARG TZ を再宣言する必要はない。

# runtime-base は USER=node で終わっているため、apt-get や /etc 配下への
# 書き込みなど root 権限が要る作業のために切り替える。
USER root

ENV DEVCONTAINER=true

# --- OS パッケージ (devcontainer 固有) -----------------------------------------
# vim-tiny は git commit / rebase -i がエディタ不在で失敗しないための最小保険。
# 実際に使うエディタ (micro 等) は個人フックが入れて EDITOR を上書きする。
#
# git / gh / sudo / jq / iptables / ipset / iproute2 / dnsutils / aggregate は
# prod container でも使うため images/runtime-base 側で既に入っている。ここで
# 追加するのは対話体験・エージェント運用にしか効かないものだけ。
RUN apt-get update && apt-get install -y --no-install-recommends \
      zsh \
      less \
      procps \
      man-db \
      unzip \
      gnupg2 \
      ripgrep \
      fd-find \
      vim-tiny \
      openssh-server \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -f /etc/ssh/ssh_host_* \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- sshd (inetd モード専用) ----------------------------------------------------
# ホストからの SSH port forwarding 用。listen する sshd デーモンは起動しない。
# ホスト側 ~/.ssh/config の ProxyCommand が
#   docker exec -i -u root <container> /usr/local/sbin/sshd-inetd
# でこのラッパーを起動し、SSH セッションは docker exec のパイプ上を流れる。
# コンテナに TCP の口は開かない。詳細は PORT-FORWARDING.md。
#
# openssh-server の postinst はビルド時にホスト鍵を生成してしまう。上の RUN で
# 削除しているのは、鍵がイメージに焼かれて全コンテナ同一鍵になるのを防ぐため。
# ラッパーが初回接続時にコンテナごとの鍵を生成する。
#
# mkdir -p /run/sshd は privilege separation ディレクトリ。/run を tmpfs にする
# 構成 (examples/docker-compose.yaml) では起動のたびに消えるため、毎回作る。
RUN printf '%s\n' \
      '#!/bin/sh' \
      '# sshd を inetd モードで起動する。ProxyCommand (docker exec) 専用。' \
      'set -eu' \
      'mkdir -p /run/sshd' \
      'ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A' \
      'exec /usr/sbin/sshd -i -e "$@"' \
    > /usr/local/sbin/sshd-inetd \
    && chmod 0755 /usr/local/sbin/sshd-inetd \
    && printf '%s\n' \
         '# 認可鍵は dev-inject (broker) が /run/secrets へ注入したものを第一に読む。' \
         '# 専用の注入スクリプトを不要にするため。GH_TOKEN 等の secret と同じ 1 回の' \
         '# dev-inject で SSH も有効になる (公開鍵は秘密ではない。搬送の一本化が目的)。' \
         '# ~/.ssh/authorized_keys は broker を使わない導入形態向けに残す。' \
         'AuthorizedKeysFile /run/secrets/SSH_AUTHORIZED_KEYS .ssh/authorized_keys' \
       > /etc/ssh/sshd_config.d/60-authorized-keys.conf

# --- crit ---------------------------------------------------------------------
# Claude Code 連携がコンテナ内の crit CLI とローカル daemon を前提とするため、
# ホストではなくコンテナ側に置く。prod container はエージェントを含まないため
# (設計書 §2.1)、crit は devcontainer-base 側だけの「能力」である。
COPY --from=crit-builder /out/crit /usr/local/bin/crit

# CRIT_HOST は設定しない (crit の既定 127.0.0.1 に委ねる)。crit は認証を持たず、
# リポジトリのファイルを読め、設定された agent_cmd を起動しうるため、意図的に
# loopback のみへ bind する設計になっている。到達経路は VS Code の自動転送も
# SSH port forwarding もコンテナ内 loopback から接続するため、これで足りる。
# compose の ports: publish は egress-guard の INPUT DROP でそもそも届かない
# (PORT-FORWARDING.md)。旧来の 0.0.0.0 上書きは publish 前提の名残であり廃止した。
#
# CRIT_PORT: crit の既定はランダムポート。ホスト側 ~/.ssh/config の LocalForward
# を静的に書けるよう、イメージが既定値を固定する。プロジェクト側の上書き方法は
# PORT-FORWARDING.md (compose の environment: では SSH セッションに届かない)。
#
# 更新チェックは起動の決定性と egress の予測可能性のために無効化する。
#
# GIT_ASKPASS: git の認証を /run/secrets/GH_TOKEN から取る (注入されていなければ、
# 認証が要る操作が非ゼロ終了して顕在化する)。スクリプト本体は runtime-base が焼く。
ENV CRIT_PORT=4588 \
    CRIT_NO_UPDATE_CHECK=1 \
    GIT_ASKPASS=/usr/local/bin/git-askpass

# Dockerfile の ENV は docker exec 経由のシェル (VS Code 含む) にしか届かない。
# sshd はクライアント側の environ を引き継がず、セッションの環境は PAM (pam_env)
# が /etc/environment から組み立てる。SSH セッションにも同じ値を届けるため、
# ENV と /etc/environment の両方に書く (値の原本は上の ENV。ここは転記)。
#
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0 / GIT_CONFIG_KEY_1 /
# GIT_CONFIG_VALUE_1 は runtime-base が焼く。スロット 0 で github.com の
# credential helper を一旦すべて捨て、スロット 1 で自前の helper
# (/usr/local/bin/git-credential-gh-token) を積み直すためのもので、VS Code の
# Dev Containers 拡張が global gitconfig へ helper を書き込み、さらに統合
# ターミナルの environ へ GIT_ASKPASS を注入して上書きしてくる以上、dev で最も
# 効かせたい 5 つである。ここへ転記しないと SSH セッションだけ上書きが外れ、
# その経路の git だけがホスト側の資格情報で通る。
# 値の原本は runtime-base 側なので、名前が変わったら空を転記して黙って穴が開く。
# それを避けるため、転記の前に存在を確かめて落とす (VALUE_0 は空が正常値なので
# 対象にできない。KEY_0 が在れば VALUE_0 も在るという前提を取る。VALUE_1 は
# 自前 helper の絶対パスで非空が正常値のため、KEY_1 と併せて確認対象にする)。
RUN [ -n "${GIT_CONFIG_COUNT}" ] && [ -n "${GIT_CONFIG_KEY_0}" ] \
    && [ -n "${GIT_CONFIG_KEY_1}" ] && [ -n "${GIT_CONFIG_VALUE_1}" ]

RUN printf '%s\n' \
      "CRIT_PORT=\"${CRIT_PORT}\"" \
      "CRIT_NO_UPDATE_CHECK=\"${CRIT_NO_UPDATE_CHECK}\"" \
      "GIT_ASKPASS=\"${GIT_ASKPASS}\"" \
      "GIT_CONFIG_COUNT=\"${GIT_CONFIG_COUNT}\"" \
      "GIT_CONFIG_KEY_0=\"${GIT_CONFIG_KEY_0}\"" \
      "GIT_CONFIG_VALUE_0=\"${GIT_CONFIG_VALUE_0}\"" \
      "GIT_CONFIG_KEY_1=\"${GIT_CONFIG_KEY_1}\"" \
      "GIT_CONFIG_VALUE_1=\"${GIT_CONFIG_VALUE_1}\"" \
    >> /etc/environment

RUN crit --version

# --- シェル履歴の永続化 --------------------------------------------------------
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R ${USERNAME}:${USERNAME} /commandhistory \
    && printf '%s\n' \
         "export PROMPT_COMMAND='history -a'" \
         "export HISTFILE=/commandhistory/.bash_history" \
       >> /etc/bash.bashrc

# --- zsh 最小設定 --------------------------------------------------------------
# /etc/zsh/zshrc は interactive shell でのみ読まれる。
# プロンプト装飾 (starship) と fzf keybinding は個人フックが ~/.zshrc に置く。
#
# karakuri-context (images/runtime-base 由来) は /etc/bash.bashrc からは既に
# source されているが、zsh は devcontainer-base 側にしかない (prod
# container に zsh は無い) ため、ここで zshrc にも同じ source 行を足す。
# zsh は POSIX 互換モードで karakuri-context を解釈でき (対話判定の
# `case $- in *i*)` は zsh でも効き、/run/secrets の列挙は glob ではなく
# `ls -A` で行うため zsh の nomatch 既定でも落ちない)、bash 用に書き分ける
# 必要はない (設計書 §4.3 rev.6)。
RUN printf '%s\n' \
      'autoload -Uz compinit && compinit' \
      'HISTFILE=/commandhistory/.zsh_history' \
      'HISTSIZE=10000' \
      'SAVEHIST=10000' \
      'setopt SHARE_HISTORY APPEND_HISTORY' \
      '. /usr/local/bin/karakuri-context' \
    >> /etc/zsh/zshrc

# --- ディレクトリ --------------------------------------------------------------
# /workspaces は複数形。devcontainer の既定 (VS Code / Codespaces) が
# /workspaces/<リポジトリ名> にワークスペースを置くため、そこへ合わせる。
# 実際のリポジトリのディレクトリは bind mount で現れるので、ここでは親だけ作る。
RUN mkdir -p /workspaces /home/${USERNAME}/.claude /home/${USERNAME}/.codex \
    && chown -R ${USERNAME}:${USERNAME} \
         /workspaces /home/${USERNAME}/.claude /home/${USERNAME}/.codex

WORKDIR /workspaces

ENV SHELL=/bin/zsh

USER ${USERNAME}

# このイメージは USER=node で終わる。派生 Dockerfile で root 作業が要る場合は
# 明示的に USER root へ切り替え、最後に USER node へ戻すこと。
