# syntax=docker/dockerfile:1

# karakuri 自身の devcontainer。
#
# devcontainer-base を参照するが、他プロジェクト（浮動タグ）とは規律を変え、
# **完全版指定（digest pin）で参照する**（bootstrap 規律。根拠は
# images/devcontainer-base/README.md の「判断済み」）。base は egress-guard を
# 焼き込んでおり、その開発環境がこのリポジトリにある。最新リリースが壊れたときに
# 直す環境が最新リリース自身に依存しないよう、このリポジトリだけは自分の最新版を
# 参照しない。通常は 1 つ前の実証済みリリースへ pin し、pin を上げるのはその版が
# base を利用する別のリポジトリで実運用に耐えたことを確認してから。
#
# **2.6.0 を選ぶ理由。** `node` が `proxy` グループに入っており（sshd 経由の
# ログインでも proxy のログが読める）、egress-guard 0.4.0 を焼いている
# （anthropic バンドルに `platform.claude.com`）最初の版である。
#
# **N-1 規律との関係。** 規律の趣旨は「最新リリースが壊れたときに、直す環境が
# 最新リリース自身に依存しない」であり、karakuri の開発環境が動かなくなるのを
# 防ぐためのものである。2.6.0 は同じソースから `:local` を焼いてこの devcontainer
# 自身で rebuild して確認済み（ssh 経由の `id -Gn` に `proxy`、
# `/var/log/egress-proxy/access.log` が読める、`platform.claude.com` が
# `TCP_TUNNEL/200`、`ab.chatgpt.com` が 403、`codex exec` が動く）で、動くことが
# 確認された版へ上げる判断は規律の趣旨に反しない。次に規律が効くのは 2.7.0
# 以降で、そのとき karakuri は 2.6.0 に留まる。
FROM ghcr.io/himorogy/devcontainer-base:2.6.0@sha256:379be607b3dd188a236fd4f7deccbeea9ea998e39687e682de8f24c4e8ed6379

# --- egress-guard 実効設定 -------------------------------------------------------
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
