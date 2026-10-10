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
# **2.7.0 を選ぶ理由。** dev を internal ネットワークだけに載せる構成
# （docs/conventions.md「発見しにくい事実」）で動く最初の版——anchor を DNS で
# 引けないことを `init-project-firewall.sh` が panic ではなく情報として扱う
# 変更を含む。
#
# **N-1 規律との関係。** 規律の趣旨は「最新リリースが壊れたときに、直す環境が
# 最新リリース自身に依存しない」であり、karakuri の開発環境が動かなくなるのを
# 防ぐためのものである。dev を internal に移すと、2.6.0 の
# `init-project-firewall.sh` はこの変更を含まず anchor を DNS で引けずに panic
# テーブルへ落ちるため、2.6.0 に留まったまま移せない。規律の趣旨は、2.6.0 の
# ときと同じ型（動くことを rebuild で確かめた版へ上げる）で満たす——
# `pnpm verify:l7` を含む検収の rebuild を実証とする。
FROM ghcr.io/himorogy/devcontainer-base:2.7.0@sha256:dfc941a184b85546aed7fcecf26b857c9787f6b950046bf3ea517b339f6ff3e3

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
