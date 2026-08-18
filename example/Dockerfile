# プロジェクト側 Dockerfile の雛形。
# .devcontainer/Dockerfile としてコピーし、<your-project> と firewall.json を差し替える。

# 浮動タグ :2 を参照する。メジャー内の改善は再ビルドで自動的に取り込まれる。
# 再現性の要求が強いプロジェクト（規制対応など）だけ digest pin に切り替える。
#   FROM ghcr.io/himorogy/devcontainer-base@sha256:...
FROM ghcr.io/himorogy/devcontainer-base:2

# --- egress-guard ---------------------------------------------------------------
# OS パッケージ・スクリプト本体 (/usr/local/bin/init-project-firewall.sh)・sudoers は
# base に入っている。プロジェクト側で要るのは実効設定だけ。
#
# 実効設定は /etc/egress-guard 固定。探索は行わない。
# firewall.json は .devcontainer/ に置き、ビルドコンテキストに合わせてパスを調整する。
#
# base は USER=node で終わっているため、root 作業の前後で明示的に切り替える。
# COPY したファイルは root 所有で入るが、node が書き換えられる状態だと
# {"mode":"audit"} への差し替えで防御を無効化できてしまうため、権限を明示する。
USER root

COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard \
    && chmod 755 /etc/egress-guard \
    && chmod 644 /etc/egress-guard/firewall.json

# --- プロジェクト固有のパッケージ ------------------------------------------------
# 例: Neon / Postgres を使うプロジェクト
# RUN apt-get update && apt-get install -y --no-install-recommends \
#       postgresql-client \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

USER node

# npm で入るもの（Biome, dprint 等）はここに書かず、プロジェクトの
# devDependency として package.json で管理する。イメージ側に焼くと
# バージョンがローカルと CI で乖離し、フォーマット差分の原因になる。
