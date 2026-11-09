# syntax=docker/dockerfile:1

# karakuri 自身の devcontainer。
#
# devcontainer-base を参照するが、他プロジェクト（浮動タグ）とは規律を変え、
# **完全版指定（digest pin）で参照する**（bootstrap 規律。根拠は images/devcontainer-base/README.md の「判断済み」）。
# base は egress-guard を焼き込んでおり、その開発環境がこのリポジトリにある。
# 最新リリースが壊れたときに直す環境が最新リリース自身に依存しないよう、自分の最新版を参照しない。
# 通常は 1 つ前の実証済みリリースへ pin し、pin を上げるのはその版が
# base を利用する別のリポジトリで実運用に耐えたことを確認してから。
#
# 3.1.0 を選ぶ理由。trixie 化（3.0.x）と pnpm の self-switch 停止を取り込む最初の版で、
# 別のリポジトリで動作を確認済み。
# 3.1.0 は pin 時点の最新版なので N-1 の字面には合わない。規律の趣旨は
# 「直す環境が最新リリース自身に依存しない」ことで、実運用に耐えた版へ上げるなら満たせる。
# 3.2.0 が出れば 3.1.0 は 1 つ前の版になる。
FROM ghcr.io/himorogy/devcontainer-base:3.1.0@sha256:17218234c064c69d829553993b56e42679b86662f1776a26f67706567d68ca6b

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

# --- virtiofs 上の git の設定（暫定） ------------------------------------------------
# 0064 で base（3.2.0）に入る設定と同じ。所有者の揺れによる dubious ownership と、
# index の stat の食い違いを避ける。pin が 3.2.0 以降に上がったらこの RUN を外す。
RUN git config --system --add safe.directory '/workspaces/*' \
    && git config --system core.checkStat minimal

USER node
