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
# 収録方針:
#   入れる  … npm で入らないもの、または エージェントが直接使うもの
#   入れない… 人間の対話体験にしか効かないもの   -> 後付けスクリプト
#             npm で入るもの (Biome, dprint 等) -> プロジェクトの devDependency
#             プロジェクト固有のもの (psql 等)  -> プロジェクトの Dockerfile
# =============================================================================
FROM node:24

ARG USERNAME=node
ARG TZ=Asia/Tokyo
ARG PNPM_VERSION=10.30.0

# --- ロケール / タイムゾーン --------------------------------------------------
# LANG 未設定だと locale=POSIX になり、日本語の入出力とソート順が不安定になる。
# エージェント運用ではソート順の決定性を優先して C.UTF-8 を採用する。
# ja_JP.UTF-8 が必要になったら locales パッケージ + locale-gen を追加すること。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ="${TZ}" \
    DEVCONTAINER=true

RUN ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone

# --- OS パッケージ ------------------------------------------------------------
# vim-tiny は git commit / rebase -i がエディタ不在で失敗しないための最小保険。
# 実際に使うエディタ (micro 等) は後付けスクリプトが入れて EDITOR を上書きする。
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      gh \
      sudo \
      zsh \
      less \
      procps \
      man-db \
      unzip \
      gnupg2 \
      jq \
      ripgrep \
      fd-find \
      vim-tiny \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      aggregate \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- crit ---------------------------------------------------------------------
# Claude Code 連携がコンテナ内の crit CLI とローカル daemon を前提とするため、
# ホストではなくコンテナ側に置く。
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
RUN mkdir -p /workspace /home/${USERNAME}/.claude /home/${USERNAME}/.codex \
    && chown -R ${USERNAME}:${USERNAME} \
         /workspace /home/${USERNAME}/.claude /home/${USERNAME}/.codex

WORKDIR /workspace

# --- egress-guard --------------------------------------------------------------
# 実行に必要な OS パッケージ (iptables / ipset / iproute2 / dnsutils / jq /
# aggregate) は上の apt-get で base に入れてある。
#
# 一方でスクリプト本体と設定は base に焼かない。実効設定 (firewall.json) が
# プロジェクトごとに異なり、base に含めると許可ドメインの差し替えが
# 「base の再ビルド」を要求してしまうため。
# → 層の分離でいう B 層。将来 devcontainer Feature 化する余地を残す。
#
# プロジェクト側の Dockerfile で以下を行う。
# npm のグローバル領域は node 所有のため、install は node のまま実行する
# (root で入れると root 所有のファイルが混ざり、以後 node での -g install が
#  権限で失敗しうる)。root が担当するのは配置と権限付与だけ。
#
#   RUN npm install -g @himorogy/egress-guard
#
#   USER root
#
#   RUN cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
#            /usr/local/bin/init-project-firewall.sh \
#       && chown root:root /usr/local/bin/init-project-firewall.sh \
#       && chmod 755 /usr/local/bin/init-project-firewall.sh
#
#   COPY firewall.json /etc/egress-guard/firewall.json
#   RUN chown -R root:root /etc/egress-guard \
#       && chmod 755 /etc/egress-guard \
#       && chmod 644 /etc/egress-guard/firewall.json
#
#   RUN printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
#         > /etc/sudoers.d/node-firewall \
#       && chmod 0440 /etc/sudoers.d/node-firewall
#
#   USER node
#
# sudoers 末尾の "" は「引数を取らない実行のみ許可」の意。実効設定を
# /etc/egress-guard に固定し探索を廃止した設計意図を、引数経由での設定差し替えを
# 塞ぐことで sudoers 側でも担保する。この "" を落とすと防御が無効になる。

# --- pnpm ----------------------------------------------------------------------
ENV PNPM_HOME=/usr/local/share/pnpm \
    NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH="${PNPM_HOME}:${NPM_CONFIG_PREFIX}/bin:${PATH}"

RUN mkdir -p "${PNPM_HOME}" "${NPM_CONFIG_PREFIX}" \
    && chown -R ${USERNAME}:${USERNAME} /usr/local/share

USER ${USERNAME}

# バージョンを固定しないとビルド日時で pnpm が変わり、
# 各プロジェクトの packageManager フィールドと乖離する。
RUN npm install -g pnpm@${PNPM_VERSION} \
    && pnpm --version

ENV SHELL=/bin/zsh

# このイメージは USER=node で終わる。派生 Dockerfile で root 作業が要る場合は
# 明示的に USER root へ切り替え、最後に USER node へ戻すこと。
