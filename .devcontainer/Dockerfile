# syntax=docker/dockerfile:1

# karakuri 自身の devcontainer。
#
# devcontainer-base を参照するが、他プロジェクト（浮動タグ :1）とは規律を変え、
# **1 つ前の実証済みリリースへ完全版指定で pin する**（bootstrap 規律。根拠は
# images/devcontainer-base/README.md の「判断済み」）。base は egress-guard を
# 焼き込んでおり、その開発環境がこのリポジトリにある。最新リリースが壊れたときに
# 直す環境が最新リリース自身に依存しないよう、このリポジトリだけは自分の最新版を
# 参照しない。pin を上げるのは、その版が base を利用する別のリポジトリで実運用に
# 耐えたことを確認してから。
#
# より厳密にするなら digest pin:
#   docker buildx imagetools inspect ghcr.io/himorogy/devcontainer-base:1.2.0
# で digest を取り、`:1.2.0@sha256:...` の形にする。
FROM ghcr.io/himorogy/devcontainer-base:1.2.0

# --- egress-guard 実効設定 -------------------------------------------------------
# スクリプト本体 (/usr/local/bin/init-project-firewall.sh) と sudoers は base
# （runtime-base 由来）に入っている。プロジェクト側で要るのは実効設定だけ。
#
# 実効設定は /etc/egress-guard 固定。node が書ける場所に置くと {"mode":"audit"}
# への差し替えで root を取らずに防御を無効化できてしまうため、root 所有・権限を
# 明示する。編集 = イメージの再ビルド（人間が行う操作）になる。
# packages/egress-guard/docs/spec.md §2.1。
USER root

COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard \
    && chmod 755 /etc/egress-guard \
    && chmod 644 /etc/egress-guard/firewall.json

# --- プロジェクト固有のパッケージ ------------------------------------------------
# shellcheck は `pnpm lint:sh` が使う。
RUN apt-get update && apt-get install -y --no-install-recommends \
      shellcheck \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER node

# 対話体験のツール (starship / delta / fzf / エディタ等) はここに書かない。
# ホスト側 ~/.config/devc-personal/setup.sh (postCreate が /personal:ro 経由で
# 実行する個人フック) に置く。images/devcontainer-base/README.md の層 C。
