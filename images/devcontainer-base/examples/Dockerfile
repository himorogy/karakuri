# プロジェクト側 Dockerfile の雛形。
# .devcontainer/Dockerfile としてコピーし、<your-project> と firewall.json を差し替える。

# 浮動タグ :1 を参照する。メジャー内の改善は再ビルドで自動的に取り込まれる。
# 再現性の要求が強いプロジェクト（規制対応など）だけ digest pin に切り替える。
#   FROM ghcr.io/himorogy/devcontainer-base@sha256:...
FROM ghcr.io/himorogy/devcontainer-base:1

# --- egress-guard ---------------------------------------------------------------
# 実行に必要な OS パッケージは base に入っている。ここではスクリプト本体と
# プロジェクト固有の実効設定だけを入れる。
#
# npm のグローバル領域 (/usr/local/share/npm-global) は node 所有のため、
# install は node のまま実行する。root で入れると root 所有のファイルが混ざり、
# 以後 node での -g install が権限で失敗しうる。
#
# バージョンは必ず固定する。このパッケージのスクリプトは下で root 所有の
# /usr/local/bin に置かれ、パスワードなし sudo の対象になる。dist-tag のまま
# 追従させると、パッケージ側の更新がそのままコンテナ内 root でのコード実行になる。
RUN npm install -g @himorogy/egress-guard@<VERSION>

# base は USER=node で終わっているため、root 作業の前後で明示的に切り替える。
USER root

RUN cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
         /usr/local/bin/init-project-firewall.sh \
    && chown root:root /usr/local/bin/init-project-firewall.sh \
    && chmod 755 /usr/local/bin/init-project-firewall.sh

# 実効設定は /etc/egress-guard 固定。探索は行わない。
# firewall.json は .devcontainer/ に置き、ビルドコンテキストに合わせてパスを調整する。
COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard \
    && chmod 755 /etc/egress-guard \
    && chmod 644 /etc/egress-guard/firewall.json

# 末尾の "" は「引数を取らない実行のみ許可」の意。
# 実効設定を /etc/egress-guard に固定した設計意図を、引数経由での設定差し替えを
# 塞ぐことで sudoers 側でも担保する。この "" を落とすと防御が無効になる。
#
# visudo -c は構文検証。この行を編集して引用符や改行を壊すと、ビルドは通るのに
# 起動時の postStartCommand で初めて失敗する。ビルド時に落とす。
RUN printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
      > /etc/sudoers.d/node-firewall \
    && chmod 0440 /etc/sudoers.d/node-firewall \
    && visudo -cf /etc/sudoers.d/node-firewall

# --- プロジェクト固有のパッケージ ------------------------------------------------
# 例: Neon / Postgres を使うプロジェクト
# RUN apt-get update && apt-get install -y --no-install-recommends \
#       postgresql-client \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

USER node

# npm で入るもの（Biome, dprint 等）はここに書かず、プロジェクトの
# devDependency として package.json で管理する。イメージ側に焼くと
# バージョンがローカルと CI で乖離し、フォーマット差分の原因になる。
