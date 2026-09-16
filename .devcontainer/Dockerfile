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
# **2.5.0 を選ぶ理由。** 個人設定フックを proxy 変数を外して実行する
# `personal-setup` を焼いた最初の版である。2.4.0 では `postCreateCommand` の
# フックが sidecar の ACL に落ちて個人ツールの取得が 403 で失敗する。
#
# **N-1 規律との関係。** 規律の趣旨は「最新リリースが壊れたときに、直す環境が
# 最新リリース自身に依存しない」であり、karakuri の開発環境が動かなくなるのを
# 防ぐためのものである。2.5.0 は同じ内容を :edge で焼いてこの devcontainer
# 自身で検証済み（rebuild が通り、個人ツールの取得が成功し、enforce のまま
# proxy 経由の遮断が効いている）で、動くことが確認された版へ上げる判断は
# 規律の趣旨に反しない。次に規律が効くのは 2.6.0 以降で、そのとき karakuri は
# 2.5.0 に留まる。
FROM ghcr.io/himorogy/devcontainer-base:2.5.0@sha256:97a3f200e0ef5721b3c3b845037516a55072035f7d5580505e570c7b465490e2

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
