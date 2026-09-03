# =============================================================================
# runtime base
#
# prod container と devcontainer-base の共通土台。ここに入れるのは
#   ・prod container でも動かす実行系 (node, pnpm, dotenvx, wrangler, git, gh)
#   ・「制約」(secret shim, git hook, egress-guard 本体, sudoers)
# だけである。エージェントや対話体験にしか効かない「能力」は
# devcontainer-base 側に積む。prod のレイヤ集合が dev のレイヤ集合の
# 真部分集合になることで、prod のサプライチェーン面積が構造的に dev を
# 超えないようにする (設計書 docs/prod-secret-isolation-design.md §4.5
# の配置規約 「能力は最小に、制約は最大に」)。
# =============================================================================
FROM node:24

ARG USERNAME=node
ARG TZ=Asia/Tokyo
ARG PNPM_VERSION=11.20.0
# 復号ランナーをアプリ依存グラフから切り離すのが本層の存在理由であり
# (§4.5)、prod container 内での動的インストールは禁止しているため、
# ここで固定した版だけが使われる。
#
# 2.x 系を採る。2.0.0 の BREAKING は全て lib/main のライブラリ API
# (set / get の async 化、doctor / keypair / genexample の export 削除、
# rotate コマンドの削除) で、本設計が使う CLI の run / get / set /
# encrypt / decrypt / precommit はいずれも存続している。
#
# 未実測の前提がひとつある: 2.0.0 は keyring 対応の導入にあわせて
# run / config / get を @dotenvx/primitives 由来の共有 resolver 経由に
# 付け替えている。本設計は shim で DOTENV_PRIVATE_KEY* を環境変数と
# して注入する経路に依存しており (§4.3)、この経路が 2.x でも従来通り
# 効くことは docker が使える環境で実測して確認すること (§10)。
#
# なお既存の 4 repo は dotenvx 1.x 系 (^1.63.0) で運用している。本イメージの
# dotenvx をアプリの依存グラフとは別系統に置くのが §4.5 の主旨なので、
# ここでは揃えていない。1.x で暗号化した .env.* を 2.x が復号できることも
# §10 の実測項目に含める。
ARG DOTENVX_VERSION=2.19.2
ARG WRANGLER_VERSION=4.119.0
ARG EGRESS_GUARD_VERSION=0.2.0

# --- ロケール / タイムゾーン --------------------------------------------------
# LANG 未設定だと locale=POSIX になり、日本語の入出力とソート順が不安定に
# なる。エージェント運用ではソート順の決定性を優先して C.UTF-8 を採用する。
# ja_JP.UTF-8 が必要になったら locales パッケージ + locale-gen を追加する
# こと。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ="${TZ}"

RUN ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone

# --- OS パッケージ ------------------------------------------------------------
# ここに置くのは prod container でも使う、または init-project-firewall.sh
# (packages/egress-guard) が要求するものだけ。zsh / less / man-db 等の
# 対話体験専用パッケージは devcontainer-base 側に積む。
#
# init-project-firewall.sh の require_commands() が要求するのは iptables /
# iptables-restore / ipset / jq / curl / dig / ip。curl は node:24 に同梱の
# ため並べていない (上流が外したら追加すること)。dig は dnsutils が、ip は
# iproute2 が提供する。aggregate は必須ではなく欠けても警告に留まるが
# (GitHub meta API の CIDR を圧縮しないまま ipset へ積むだけになる)、常に
# 入れておく。
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      gh \
      sudo \
      jq \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      aggregate \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- pnpm ----------------------------------------------------------------------
ENV PNPM_HOME=/usr/local/share/pnpm \
    NPM_CONFIG_PREFIX=/usr/local/share/npm-global
# PATH に載せるのは ${PNPM_HOME}/bin であって ${PNPM_HOME} ではない。
# pnpm 10 は PNPM_HOME 直下に global bin を置いていたが、11 は bin/ の下に
# 置く。古いレイアウトのままだと pnpm add -g したものが PATH に載らず、
# pnpm bin -g が "global bin directory is not in PATH" で失敗する。
#
# 注意: ${NPM_CONFIG_PREFIX}/bin は PATH 上で /usr/local/bin より先に
# 来る。dotenvx / wrangler の shim を /usr/local/bin に置くだけでは、
# npm global 直下に残った実体に PATH 解決で負けて素通りされる。この
# 罠への対処は下の shim セクション (実体を /opt/tools/bin へ退避する)
# を参照。
ENV PATH="${PNPM_HOME}/bin:${NPM_CONFIG_PREFIX}/bin:${PATH}"

# chown の対象は ${PNPM_HOME} と ${NPM_CONFIG_PREFIX} の2つだけに絞る。
# node が書き込む必要があるのはこの2つで、親の /usr/local/share ごと node
# 所有にすると、下の git hook (/usr/local/share/git-hooks) の親ディレクトリ
# まで node 所有になる。hook ファイル自体が root:root 0755 でも、親が node
# 所有なら dev container 内のエージェントがディレクトリごと mv で差し替え
# られてしまい、「制約は改変されにくい場所に置く」という配置意図 (§4.5) と
# 食い違う。
RUN mkdir -p "${PNPM_HOME}/bin" "${NPM_CONFIG_PREFIX}" \
    && chown -R ${USERNAME}:${USERNAME} "${PNPM_HOME}" "${NPM_CONFIG_PREFIX}"

USER ${USERNAME}

# バージョンを固定しないとビルド日時で pnpm が変わり、
# 各プロジェクトの packageManager フィールドと乖離する。
RUN npm install -g pnpm@${PNPM_VERSION} \
    && pnpm --version

# --- dotenvx / wrangler ---------------------------------------------------------
# npm のグローバル領域 (NPM_CONFIG_PREFIX) は node 所有のため、install は
# node のまま実行する (pnpm と同じ理由)。実体を /opt/tools/bin へ退避して
# shim に差し替える作業は次のセクションでまとめて root が行う。
RUN npm install -g @dotenvx/dotenvx@${DOTENVX_VERSION} \
    && npm install -g wrangler@${WRANGLER_VERSION}

USER root

# --- shim: secret を常時環境変数化しないための PATH 差し替え -------------------
# wrangler / gh / dotenvx は、実行のたびに /run/secrets/<VAR> の有無を見て
# secret を注入する薄いラッパーに差し替える。意味論は三値 (存在→注入 /
# 空→エラー / 不在→素通し) で、環境の判別はしない。prod では entrypoint が
# prod secret を書き、dev では dev 向けトークンが別機構で与えられる、
# どちらでも同じ shim が使われる (設計書 §4.3 / D15)。
#
# 実体は /opt/tools/bin へ退避し、PATH には載せない。${NPM_CONFIG_PREFIX}/bin
# は PATH 上で /usr/local/bin より先に来るため、/usr/local/bin に shim を
# 置くだけでは npm global 直下に残った実体に PATH 解決で負けて素通りされる。
#
# npm がグローバル領域に張るシンボリックリンクは相対パスなので、
# `mv "${NPM_CONFIG_PREFIX}/bin/dotenvx" /opt/tools/bin/` のような単純な
# 移動ではリンク切れになる。readlink -f で絶対パスの実体を解決してから
# /opt/tools/bin に絶対パスの新しいシンボリックリンクを張り、元のリンクは
# 削除する。gh は apt パッケージの通常バイナリなので mv だけで足りる。
RUN mkdir -p /opt/tools/bin \
    && ln -s "$(readlink -f "${NPM_CONFIG_PREFIX}/bin/dotenvx")" /opt/tools/bin/dotenvx \
    && rm "${NPM_CONFIG_PREFIX}/bin/dotenvx" \
    && ln -s "$(readlink -f "${NPM_CONFIG_PREFIX}/bin/wrangler")" /opt/tools/bin/wrangler \
    && rm "${NPM_CONFIG_PREFIX}/bin/wrangler" \
    && mv /usr/bin/gh /opt/tools/bin/gh

COPY shims/wrangler shims/gh shims/dotenvx /usr/local/bin/
RUN chown root:root /usr/local/bin/wrangler /usr/local/bin/gh /usr/local/bin/dotenvx \
    && chmod 0755 /usr/local/bin/wrangler /usr/local/bin/gh /usr/local/bin/dotenvx \
    # _ 付きの明示呼び名 (npm scripts 用)。pnpm/npm は scripts 実行時に
    # node_modules/.bin を PATH 先頭へ差し込むため、素の名前の shim は
    # プロジェクトローカルのバイナリに負けて迂回される。scripts には
    # _dotenvx / _wrangler / _gh と書くことで shim を確実に通す。実体は
    # 同一ファイルで、shim 側が呼び名 ($0) を見て解決先を切り替える
    # (shims/wrangler のコメント / docs §4.3 / D31)。
    && ln -s wrangler /usr/local/bin/_wrangler \
    && ln -s gh /usr/local/bin/_gh \
    && ln -s dotenvx /usr/local/bin/_dotenvx

# ビルド時に PATH 解決が shim に当たることを検証する。将来 PATH 順が
# 入れ替わったり、apt/npm の配置が変わったりして shim が再び素通りされる
# ようになったとき、ここが唯一の防波堤になる。docker を使わない
# tests/shim.test.sh は shim 単体の中身 (三値意味論) しか検証できず、
# 実際の PATH 解決の勝敗まではビルドしてみないと分からないため、この
# RUN でビルド自体を落として検出する。
RUN [ "$(command -v wrangler)" = /usr/local/bin/wrangler ] \
    && [ "$(command -v gh)" = /usr/local/bin/gh ] \
    && [ "$(command -v dotenvx)" = /usr/local/bin/dotenvx ]

USER ${USERNAME}

# --- egress-guard --------------------------------------------------------------
# スクリプト本体と sudoers は base に入れる。どちらも全プロジェクトで同一で、
# root 所有の場所に置く必要があり、npm では入らない領域を触るため。
#
# base に入らないのは実効設定 (firewall.json) だけ。プロジェクトごとに内容が
# 異なるうえ、COPY 元がプロジェクトのビルドコンテキストにあり base のビルド時
# には存在しない。プロジェクト側の Dockerfile で入れる (examples/Dockerfile)。
#
# バージョンは ARG で固定する。このスクリプトは下で root 所有の /usr/local/bin に
# 置かれ、パスワードなし sudo の対象になる。dist-tag のまま追従させると、
# パッケージ側の更新がそのままコンテナ内 root でのコード実行になる。
#
# npm のグローバル領域 (NPM_CONFIG_PREFIX) は node 所有のため、install は node の
# まま実行する。root で入れると root 所有のファイルが混ざり、以後 node での
# -g install が権限で失敗しうる。root が担当するのは配置と権限付与だけ。
RUN npm install -g @himorogy/egress-guard@${EGRESS_GUARD_VERSION}

USER root

# sudoers は固定パスを名指しする必要があるため、グローバル node_modules を参照
# させずにコピーする。NPM_CONFIG_PREFIX 配下は node が書き換えられるので、sudo で
# 実行を許したファイルそのものを node が差し替えられる状態にはできない。
#
# sudoers 末尾の "" は「引数を取らない実行のみ許可」の意。実効設定を
# /etc/egress-guard に固定し探索を廃止した設計意図を、引数経由での設定差し替えを
# 塞ぐことで sudoers 側でも担保する。この "" を落とすと防御が無効になる。
#
# visudo -c は構文検証。sudoers.d 配下に構文エラーがあると、その後の sudo 呼び出し
# 全体がパースエラーで失敗する。この行を編集して引用符や改行を壊すとビルドは通り、
# 派生プロジェクトの起動時に初めて表面化するため、base のビルド時に落とす。
RUN cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
         /usr/local/bin/init-project-firewall.sh \
    && chown root:root /usr/local/bin/init-project-firewall.sh \
    && chmod 755 /usr/local/bin/init-project-firewall.sh \
    && printf '%s ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
         "${USERNAME}" > /etc/sudoers.d/node-firewall \
    && chmod 0440 /etc/sudoers.d/node-firewall \
    && visudo -cf /etc/sudoers.d/node-firewall

# --- prod entrypoint / secrets-ingest / git-askpass -----------------------------
# 秘密鍵 (dotenv 形式) を stdin から受け取り /run/secrets (tmpfs) へ書き出し、
# 明示された git ref へ /src (tmpfs) を復元してから "$@" を exec する。
# stdin の取込部は secrets-ingest.sh に分かれており、prod では entrypoint が、
# dev ではホスト側の注入スクリプトが `docker exec -i` 経由で同じファイルを
# 呼ぶ (方言パーサを 1 実装に保つ)。
# GH_TOKEN は checkout 直後に破棄するため、git-askpass は clone/fetch の間
# だけ使われる (設計書 §4.6)。
COPY bin/prod-entrypoint.sh bin/secrets-ingest.sh bin/git-askpass bin/git-auth-check bin/git-credential-gh-token /usr/local/bin/
RUN chown root:root /usr/local/bin/prod-entrypoint.sh /usr/local/bin/secrets-ingest.sh /usr/local/bin/git-askpass /usr/local/bin/git-auth-check /usr/local/bin/git-credential-gh-token \
    && chmod 0755 /usr/local/bin/prod-entrypoint.sh /usr/local/bin/secrets-ingest.sh /usr/local/bin/git-askpass /usr/local/bin/git-auth-check /usr/local/bin/git-credential-gh-token

# --- git: github.com の認証を自前 helper 経由へ固定する -------------------------
# ここは打ち消しである。相手は VS Code の Dev Containers 拡張で、接続のたびに
# global の gitconfig へ credential helper を書き込み、統合ターミナルの environ へ
# GIT_ASKPASS を注入する。どちらもホスト側の認証セッションへ繋がるため、放って
# おくと github.com への https 認証が /run/secrets/GH_TOKEN ではなくホスト側の
# 資格情報で通る。**認証は成功するので、失敗としては現れない。**
# 観測は 2026-08-16 / git 2.39.5 (Debian)。経路の切り分けと否定対照は
# images/runtime-base/verification-record.md の 0.14 にある。
#
# 打ち消しを環境変数でやる理由。git は credential helper を設定順 (system ->
# global -> local -> 環境変数) に呼び、最初に資格情報を返した helper で解決を
# 確定する。GIT_ASKPASS はどの helper も答えなかった場合のフォールバックでしか
# ない。全ての設定ファイルの後に適用されるのは GIT_CONFIG_COUNT 系だけなので、
# gitconfig の記述順にも environ の注入にも左右されずに認証先を固定できるのは
# こちらだけである。system (/etc/gitconfig) へ書くと global の helper が後から
# 積み直されて負ける (この「守れない」側の事実は台帳とテストが固定している)。
#
# スロット 0 の空文字は「それまでに積まれた helper を捨てる」git の作法で、
# スロット 1 で自前を積み直す。一覧が自前 1 本になることで得られる性質は 3 つ:
#   - 認証が helper で確定し askpass へ到達しない。environ の注入が無関係になる
#   - 認証成功後の store は設定されている **全ての** helper へ配られるため、一覧を
#     1 本にすることでホストの資格情報ストアへの書き戻り経路も消える (実測)
#   - checkout 済みの信頼しないコードが .git/config へ仕込んだ helper も、環境変数
#     が local の後に適用されるため github.com については閉じる (実測)
#
# VALUE_1 が絶対パスなのは意図的。helper 名を裸で書くと git は PATH から
# git-credential-<name> を探すが、このイメージの PATH は
# ${NPM_CONFIG_PREFIX}/bin が /usr/local/bin より先に来るため、そこへ同名の
# ものを置かれると乗っ取られる (上の shims セクションと同じ罠)。
#
# 打ち消しは URL 限定 (https://github.com) なので、他ホストの helper はそのまま
# 残る。GIT_ASKPASS を消していないのも同じ理由で、他ホストへの https 認証と、
# prod の entrypoint 経路 (clone/fetch の間だけ使う) で使う。
#
# 留意: GIT_CONFIG_COUNT は git が持つ唯一のカウンタである。イメージが 0 と 1 の
# 2 番を占有するので、同じ仕組みで設定を足したい利用側と衝突しうる。占有が黙って
# 外れることだけは避けたいので、git-auth-check が対話シェルの起動時に生死を
# 確認する。
#
# sshd 経由のセッションには Dockerfile の ENV が届かない。devcontainer-base が
# /etc/environment へ同じ内容を転記する (値の原本はここ)。
ENV GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=credential.https://github.com.helper \
    GIT_CONFIG_VALUE_0="" \
    GIT_CONFIG_KEY_1=credential.https://github.com.helper \
    GIT_CONFIG_VALUE_1=/usr/local/bin/git-credential-gh-token

# --- karakuri-context: 注入済み鍵名の表示 (rev.6 / §4.3) ----------------------------
# 対話シェルの起動時に、/run/secrets の「ファイル名」(= 環境変数名) と
# /run/prod-ref を表示する。値は出さない。dev では「持っているべき鍵の
# 一覧」がプロジェクト固有で runtime-base には持てないため、注入済みの
# ものを列挙するだけに留め、無いものが映らないことで気づかせる。
#
# /etc/bash.bashrc から source する。profile.d はログインシェルでしか
# 読まれず、`docker exec -it <c> bash` は非ログインシェルなので取りこぼす。
# /etc/bash.bashrc は bash が対話シェルとして起動するたびに読む。
COPY bin/karakuri-context /usr/local/bin/karakuri-context
RUN chown root:root /usr/local/bin/karakuri-context \
    && chmod 0755 /usr/local/bin/karakuri-context \
    && printf '%s\n' '. /usr/local/bin/karakuri-context' >> /etc/bash.bashrc

# entrypoint が clone/fetch する先。/src は named volume ではなく tmpfs で
# ある (§4.6 / D18。named volume を再利用すると、前回実行のコードが打った
# ローカル ref が次回の指定 ref として解決される穴と、持ち越された
# .git/config が entrypoint 自身の git 操作で発火する穴が実測で再現した)。
#
# ここで作るのは mount point としてのディレクトリである。中身は起動のたびに
# tmpfs で覆われるため、イメージ内の /src に何が入っているかは影響しない。
# 所有権も compose 側の tmpfs オプション (uid=1000,gid=1000,mode=0755) が
# 決めるが、tmpfs を張らずにこのイメージを起動した場合 (テストや素の
# docker run) に entrypoint (node で実行される) が fetch/checkout で権限
# エラーにならないよう、イメージ側でも node 所有にしておく。
RUN mkdir -p /src && chown ${USERNAME}:${USERNAME} /src

# --- git hook: 平文 .env のコミットを防ぐ (T6 / 緩和策) -------------------------
# `dotenvx precommit --install` は .git/hooks に書くため clone ごとに再実行が
# 要る。core.hooksPath をイメージへ焼き込み、全リポジトリ・全 clone・
# worktree に自動で効かせる。同時に .husky / .githooks の pre-commit へ
# チェーンし、他の hook 管理ツールを黙って上書きしない (設計書 §4.7 / D11 /
# D12。git hook は「制約」なので runtime-base に置く)。
#
# 検査の実体は共有スキャナ env-guard-scan に置く。CI 側 (karakuri の
# reusable workflow .github/workflows/env-guard.yml) が第二 checkout で
# 取り出して実行するのと同じ 1 本のファイルであり、hook はこれに staged な
# ファイルの一覧を渡すだけ。判定の実装が 2 つあると、パターンを揃えても
# 「hook は通るのに CI で落ちる」が必ず残るため、実装ごと 1 本にしてある
# (設計書 §8.2)。hook は /usr/local/bin/env-guard-scan を絶対パスで解決する。
#
# スキャナと hook の実体は packages/env-guard にある。ビルドコンテキストは
# images/runtime-base のままなので、そこは named build context `env-guard`
# として別に供給する。ビルドする側は
# `--build-context env-guard=packages/env-guard` (GitHub Actions では
# docker/build-push-action の build-contexts 入力) を渡すこと。渡さなければ
# 以下の COPY で落ちる。
COPY --from=env-guard bin/env-guard-scan /usr/local/bin/env-guard-scan
RUN chown root:root /usr/local/bin/env-guard-scan \
    && chmod 0755 /usr/local/bin/env-guard-scan

COPY --from=env-guard hooks/pre-commit /usr/local/share/git-hooks/pre-commit
RUN chown root:root /usr/local/share/git-hooks/pre-commit \
    && chmod 0755 /usr/local/share/git-hooks/pre-commit \
    && git config --system core.hooksPath /usr/local/share/git-hooks

USER ${USERNAME}

# このイメージは USER=node で終わる。派生 Dockerfile で root 作業が要る場合は
# 明示的に USER root へ切り替え、最後に USER node へ戻すこと。
