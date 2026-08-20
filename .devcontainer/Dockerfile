# syntax=docker/dockerfile:1

# karakuri 自身の devcontainer。
#
# devcontainer-base を参照するが、他プロジェクト（浮動タグ）とは規律を変え、
# **1 つ前の実証済みリリースへ完全版指定で pin する**（bootstrap 規律。根拠は
# images/devcontainer-base/README.md の「判断済み」）。base は egress-guard を
# 焼き込んでおり、その開発環境がこのリポジトリにある。最新リリースが壊れたときに
# 直す環境が最新リリース自身に依存しないよう、このリポジトリだけは自分の最新版を
# 参照しない。pin を上げるのは、その版が base を利用する別のリポジトリで実運用に
# 耐えたことを確認してから。
#
FROM ghcr.io/himorogy/devcontainer-base:2.2.0@sha256:9be4c259d7fc7da470709ed203dd56ae4480d76a166c9e89960b4470a5a6a617

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
