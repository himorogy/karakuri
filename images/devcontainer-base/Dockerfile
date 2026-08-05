# syntax=docker/dockerfile:1

# =============================================================================
# crit builder
#
# TARGETARCH 向けにクロスコンパイルする。ビルドは常に BUILDPLATFORM 上で行い、
# arm64 ビルド時の QEMU エミュレーションを回避する。
# =============================================================================
ARG CRIT_VERSION=v0.18.0

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
#   入れない… 人間の対話体験にしか効かないもの   -> 後付けスクリプト
#             npm で入るもの (Biome, dprint 等) -> プロジェクトの devDependency
#             プロジェクト固有のもの (psql 等)  -> プロジェクトの Dockerfile
#             prod container でも使うもの       -> images/runtime-base 側
#               (設計書 .local/prod-secret-isolation-design.md §4.5)
# =============================================================================
ARG RUNTIME_BASE_VERSION=1
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
# 実際に使うエディタ (micro 等) は後付けスクリプトが入れて EDITOR を上書きする。
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
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- crit ---------------------------------------------------------------------
# Claude Code 連携がコンテナ内の crit CLI とローカル daemon を前提とするため、
# ホストではなくコンテナ側に置く。prod container はエージェントを含まないため
# (設計書 §2.1)、crit は devcontainer-base 側だけの「能力」である。
COPY --from=crit-builder /out/crit /usr/local/bin/crit

# 0.0.0.0 で待ち受けないと devcontainer.json の runArgs (-p) による転送が届かない。
# 更新チェックは起動の決定性と egress の予測可能性のために無効化する。
# プロジェクトごとの CRIT_PORT は devcontainer.json 側で設定する。
ENV CRIT_HOST=0.0.0.0 \
    CRIT_NO_UPDATE_CHECK=1

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
# プロンプト装飾 (starship) と fzf keybinding は後付けスクリプトが ~/.zshrc に置く。
RUN printf '%s\n' \
      'autoload -Uz compinit && compinit' \
      'HISTFILE=/commandhistory/.zsh_history' \
      'HISTSIZE=10000' \
      'SAVEHIST=10000' \
      'setopt SHARE_HISTORY APPEND_HISTORY' \
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
