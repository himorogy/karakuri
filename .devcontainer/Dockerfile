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
# **2.4.0 を選ぶ理由。** egress-guard 0.3.0（`.devcontainer/firewall.json` の
# `version: 2` を受理する版）を焼いた公開済みの base は 2.4.0 が最初で、
# それより前の版はどれも `unsupported schema version` で拒否する。L7 を選んだ
# この devcontainer が起動できる正式版は 2.4.0 だけである。
#
# **N-1 規律との関係。** 上の「1 つ前の実証済みリリースへ pin する」規律は
# この時点では適用できない（1 つ前の版では起動しない）。2.4.0 の実証は、
# 公開前に同じ内容を :edge で焼いて別のリポジトリで L7 を通したことと、
# このリポジトリの検収が担う。規律が再び効くのは 2.5.0 以降で、そのとき
# karakuri は 2.4.0 に留まる。
FROM ghcr.io/himorogy/devcontainer-base:2.4.0@sha256:4fb802e8baa98dc7e28e22a1d7e24f688c5368a699cdd790916c4a2e06275947

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
