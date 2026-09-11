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
# **一時的に :edge の digest を指している（0021-l7-verification-and-cutover）。**
# 公開済みの正式リリースはどれも egress-guard 0.2.0 以下を焼いており、
# `.devcontainer/firewall.json` の version 2 を `unsupported schema version` で
# 拒否する。egress-guard 0.3.0 とそれを焼いた base の正式版はこのブランチの
# マージ後にしか出せないため、先行検証で使った :edge のビルド（未公開の
# egress-guard 0.3.0 を焼いてある）を index digest で指す。プラットフォーム単体の
# manifest の digest ではなく index の digest を使うのは、単体だと他アーキで
# pull できないため。正式版への pin の戻しは別の作業単位で行う。
FROM ghcr.io/himorogy/devcontainer-base:edge@sha256:12dbdd8ed072f9e3bf34b1ef70d03aeb3b62d0d25e00dd09c0715deb1223bc1d

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
