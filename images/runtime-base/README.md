# runtime-base

prod container と devcontainer の**共通土台**になるイメージ。

```
ghcr.io/himorogy/runtime-base:1
```

`images/devcontainer-base` はこのイメージを `FROM` で継承する。二層にしている理由は、prod
のレイヤ集合が dev のレイヤ集合の**真部分集合**になるからで、これにより prod のサプライ
チェーン面積が構造的に dev を超えないことが保証される。共通の第三のベースを両者が継承する
構成ではこの性質は得られない。

設計の全体像・脅威モデル・判断根拠は [`.local/prod-secret-isolation-design.md`](../../.local/prod-secret-isolation-design.md)
にある。本 README は収録物と運用手順を扱う。

---

## 何が入っているか

| 種別 | 中身 |
|---|---|
| 実行系 | Node 24、pnpm、dotenvx、wrangler、git、gh |
| secret 注入 | `wrangler` / `gh` / `dotenvx` の shim、`prod-entrypoint.sh`、`git-askpass` |
| 制約 | `core.hooksPath` + pre-commit hook、egress-guard 本体と sudoers |

入っていないもの（= devcontainer-base 側に積む）: crit、エージェント類、zsh / less / man-db /
ripgrep / fd / vim-tiny 等の対話系、シェル履歴の永続化設定、`/workspaces`。

### 配置規約 — 能力は最小に、制約は最大に

| 種別 | 例 | 配置 |
|---|---|---|
| **能力** — できることを増やすもの | エージェント、crit、対話ツール | prod で使わないなら runtime-base に**入れない** |
| **制約** — できることを減らすもの | git hook、`core.hooksPath`、egress ポリシー | **全層に入れる**（= runtime-base に置く） |

真部分集合の関係が守っているのは攻撃面であり、制約を足しても攻撃面は増えない。したがって
「prod で実行しないものは入れない」は**能力にのみ**適用する。

制約を下層に置く積極的な理由は、「prod で実行しない運用であるはずだが、実行できてしまう」
経路を塞ぐことにある。運用上コミットが prod で起きない前提であっても、起きた場合に検査が
効く状態にしておく。

---

## secret の受け渡し

環境変数を一切経由しない。

```
broker（ホストの OS キーチェーン等）
  → stdout
  → パイプ
  → docker compose run -T の stdin
  → prod-entrypoint.sh
  → /run/secrets/<変数名>（コンテナ内 tmpfs、mode 600）
  → shim が実行時にだけ環境変数として注入
```

この経路の結果、平文はホストシェルの environ にも、compose プロセスの environ にも、
`docker inspect` の `Config.Env` にも現れない。

### なぜ compose の `secrets:` を使わないのか

使えないから。compose の `environment` / `content` ソース secrets は bind mount では**なく**、
コンテナ作成後・起動前に Docker API（CopyToContainer）で**コンテナの writable layer へ書き込まれる**。
writable layer は `/var/lib/docker/overlay2`、すなわちホスト（Docker Desktop では VM）の不揮発
ディスクである。さらに `read_only: true` と併用すると書き込み先が read-only になり**起動そのものが
失敗する**（docker/compose#12031、#12303）。`tmpfs: ["/run/secrets"]` を足しても効かない。

公式ドキュメントの「`/run/secrets/<name>` に bind mount される」という記述は `file:` ソースにのみ
当てはまる。

---

## shim の仕組み

`wrangler` / `gh` / `dotenvx` は、実行のたびに `/run/secrets/<変数名>` の有無を見て secret を
注入する薄いラッパーに差し替えてある。

意味論は**三値**で、環境の判別は一切しない。

| `/run/secrets/<VAR>` | ふるまい |
|---|---|
| 存在する（非空） | その値を環境変数として注入し、実体を exec する |
| 存在するが空 / 読めない | 非ゼロ終了する |
| 存在しない | プロセス環境をそのまま引き継いで実体を exec する（素通し） |

prod では entrypoint が prod secret を書き、dev では dev 向けのトークンが別機構で与えられる。
どちらでも同じ shim が同じように振る舞う。

**シェル関数ではなく PATH 上の実行ファイルにしてある。** `pnpm run` / Makefile / `xargs` は
`sh -c` を起動して rc を読まないため、関数はスコープ外になって素のバイナリが呼ばれる。
PATH 上の実行ファイルであればこれらの経路でも効く。

### ただし `pnpm run` の内側では効かない

`pnpm run <script>` は `node_modules/.bin` を PATH の**先頭**に積む。プロジェクトが
`@dotenvx/dotenvx` をローカル依存に持っていると、script 内の `dotenvx` はそちらへ解決され、
**shim は素通りされる**。既存の 4 リポジトリはいずれもローカルに dotenvx を持つ。

したがって **prod では dotenvx を最上位に置く**。

```sh
# 効く — 最上位の dotenvx が shim に解決され、export した鍵を子プロセスが継承する
prod-run.sh dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy

# 効かない — pnpm が node_modules/.bin を先頭に積み、ローカルの dotenvx が呼ばれる
prod-run.sh pnpm deploy
```

後者は鍵が無い状態で復号を試みるが、**`--strict` が無いと沈黙する** — dotenvx は復号に失敗
しても非ゼロ終了せず、暗号文をそのまま値として注入して rc=0 を返す（実測: `FOO=encrypted:...`
のままアプリが起動し、deploy は成功と報告される）。`--strict` を付ければ確実に rc=1 になる。
規約として最上位に置き、かつ `--strict` を必須とする理由がこれである。

この制約は shim 一般の性質であって dotenvx 固有ではない。`wrangler` / `gh` をローカル依存に
持つプロジェクトでも同じことが起きる。

### 実体は `/opt/tools/bin` にある

PATH は `${PNPM_HOME}/bin:${NPM_CONFIG_PREFIX}/bin:${PATH}` の順で、**npm global bin が
`/usr/local/bin` より先に来る**。したがって shim を `/usr/local/bin` に置くだけでは、npm global
直下に残った実体に PATH 解決で負けて素通りされる。

対処として、実体は `/opt/tools/bin`（PATH には載せない）へ退避し、`/usr/local/bin` に shim を置く。
npm がグローバル領域に張るシンボリックリンクは相対パスなので、単純な `mv` ではリンク切れになる。
`readlink -f` で絶対パスの実体を解決してから新しいリンクを張っている。

この関係が壊れると shim が黙って素通りするだけで、失敗が表面化しない。Dockerfile に
`command -v` による**ビルド時検証**を焼いてあり、PATH 順や配置が変わった時点でビルドが落ちる。
push されたイメージに対しても CI の smoke test が同じ検証を行う。

### 素通しは fail-open ではない

prod container は `/home/node` が tmpfs で毎回空であり、`~/.wrangler` / `~/.config/gh` 等の
fallback 資格情報が存在しえない。したがって必要な secret を欠いたコマンドは、下流の認証失敗
として顕在化する。加えて entrypoint が取込件数 ≥ 1 と各値の非空を検証している。

---

## prod-entrypoint.sh

`/usr/local/bin/prod-entrypoint.sh`。secret の取り込みと workspace の復元を一体で行う。

1. stdin（dotenv 形式）を EOF まで読み、`/run/secrets/<変数名>` へ書く（umask 077）
2. 空値・`=` を含まない行・不正な鍵名は**即座に非ゼロ終了**する。取込件数が 0 でも落とす
3. `GIT_ASKPASS` を設定し、`/src`（tmpfs）を `git init` + `fetch` で用意する
4. `GIT_REF` が commit として解決できることを `rev-parse --verify` で確認する
5. `checkout --detach --force` → `reset --hard` → `clean -xdff` の順で `GIT_REF` の状態へ復元する
6. `pnpm config set store-dir /src/.pnpm-store` で store を node_modules と同一 tmpfs へ向ける
7. `rm -f /run/secrets/GH_TOKEN` と `unset GIT_ASKPASS` で clone 用トークンを破棄する
8. `exec "$@"`（引数が無ければ非ゼロ終了）

### 復元の三段階は重複ではない

- `checkout --detach --force` … HEAD を移す
- `reset --hard` … tracked file の改変を戻す
- `clean -xdff` … untracked / ignored を消す

`checkout` は HEAD が既に同じ commit にあると working tree を復元せず、`clean` は untracked
しか消さない。この二つだけだと、`/src` を再利用したときに前回実行が書き換えた tracked file が
残る。`/src` は tmpfs で毎回捨てられるので現構成では起きないが、その前提が崩れても壊れない
ように三段構えを維持している（多重防御）。

### 存在しない ref は明示的に落とす

`git checkout --detach <ref>` は ref として解決できないと引数を**パス名**と解釈し、
`fatal: git checkout: --detach does not take a path argument 'v9.9.9'` という原因の読み取れない
エラーになる。fail-closed ではあるが、これを踏んだ人間は原因に辿り着けない。`fetch` の後に
`rev-parse --verify --quiet "${GIT_REF}^{commit}"` で検証し、`GIT_REF does not resolve to a
commit in the fetched repository: <ref>` として落とす。`GIT_REF` は秘匿情報ではない（通常の
環境変数で渡す設計）のでメッセージに含めてよい。

### pnpm の store

`read_only: true` の下では既定の `$PNPM_HOME/store`（`/usr/local/share/pnpm/store`）を作れず、
`pnpm install` が `ENOENT` で落ちる。store は **node_modules と同一の tmpfs マウント**に
置く必要がある。別マウント（`$HOME` 配下）に置くとハードリンクがマウントを跨げず copy に
フォールバックし、**RAM が倍**になる。

```
store を $HOME 配下（別 tmpfs）  合計 260M  リンク数 2 以上のファイル    0/3546
store を /src 配下（同一 tmpfs） 合計 131M  リンク数 2 以上のファイル 3491/3546
```

pnpm 自身が出力で機構を明言する — 前者は `Packages are copied ...`、後者は
`Packages are hard linked ...`。

設定は entrypoint が `pnpm config set store-dir /src/.pnpm-store` で行う。環境変数
`npm_config_store_dir` は効かない。書き込み先は `$HOME/.config/pnpm/config.yaml`（YAML の
`storeDir:`。`.npmrc` の `store-dir=` ではない）で、`$HOME` は tmpfs なので毎回新規に書かれる。

**イメージには焼かない。** dev container の store は `/workspaces/.pnpm-store` にあり `/src` は
存在しないので、runtime-base に焼くと devcontainer-base 側が壊れる。

store は `/src` の中にあるため `clean -xdff` の対象になる。entrypoint は checkout → clean →
`exec "$@"` の順で `pnpm install` はその後に走るため、同一 run 内で消えることはない。
**この順序を入れ替えてはならない。**

### なぜ `/src` を使い捨てるのか

`/src` は named volume ではなく **tmpfs** である。再利用する構成には、`checkout` +
`reset --hard` + `clean` の三段構えでも塞がらない穴が二つあり、いずれも実測で再現した。

**ref の汚染。** `git fetch --tags` は既存のローカルタグを clobber せず（`--force` が無い）、
ローカル branch は fetch の対象外である。前回実行の（信頼しない）コードが
`git tag v1.2.3 <別コミット>` を打てば、次回 `GIT_REF=v1.2.3` で `checkout` も `reset --hard` も
**攻撃者の ref を解決する**。三段構えは「汚染された ref へ正しく復元する」だけで、指定した
commit を実行する保証にはならない。実測では 2 回目の実行が別の commit の内容を checkout した。
安全なのは完全な commit sha だけで、これは content-addressed なので偽装できない。

**`.git/config` の持続。** 上記のとおり local が system に勝つため、`core.fsmonitor` のような
コマンドを実行する設定を仕込まれると、次回の entrypoint 自身の git 操作で発火する。実測では
8 回実行され、しかも `GH_TOKEN` を破棄する**前**だった。`credential.helper` を仕込めばトークン
そのものを受け取れる。`filter.*.smudge` + `.gitattributes` も同型で、**設定経由の実行経路を
列挙して潰すのは筋が悪い。**

tmpfs にすれば毎回まっさらな repo から始まるため、どちらも構造的に成立しない。同時に、prod で
走るコードが復号値・CLI キャッシュ・トークンを `/src` へ書いてもコンテナ削除後に Docker VM の
ディスクへ残らなくなる。**現在コンテナが書ける場所は全て tmpfs であり、悪意ある明示書き込みで
あっても不揮発媒体には届かない。**

代償は毎回の full clone と全依存の再ダウンロード、そして RAM 消費である。実測では karakuri 自身
（依存 174）で `/src` 合計 131M、tmpfs の既定サイズはホスト RAM の 50%（CI ランナーで 7.9G）
だった。依存の重いプロジェクトを載せるなら、実行ホストのメモリ量が直接の制約になる。

### 入力を反射しない

パース失敗時のエラーメッセージには入力行も鍵名も出さず、stdin の行番号だけを示す。broker の
出力が壊れて `KEY=value` の形になっていない場合、その行は secret 本体そのものでありうる。
`logging: none` が止められるのはホストのログファイルだけで、アタッチ先の端末表示とその
スクロールバックは止められない。

### clone 用トークンの破棄

`GH_TOKEN` は clone / fetch には要るが、その後 `exec "$@"` で走るのは**信頼しない checkout 済み
コード**である。fetch 完了直後に破棄することで、取得用と実行用の資格情報を同一セッションに
同居させない。deploy が別途 GitHub 資格情報を要するなら、clone 用とは別スコープ
（read-only・単一 repo・短寿命）を deploy 直前に注入する。

---

## git hook

`core.hooksPath` を `/usr/local/share/git-hooks` に**イメージへ焼き込んである**（`--system`、
すなわち `/etc/gitconfig`）。

- 全リポジトリ・全 clone・worktree に自動で効く。`dotenvx precommit --install` は不要
- 改善はイメージタグの更新で伝播する
- `core.hooksPath` は**全 hook を上書きする**ため、hook 側で `.husky/pre-commit` と
  `.githooks/pre-commit` へ明示的にチェーンしている
- この設定が効いている間、各リポジトリの `.git/hooks/*` は無視される。過去に `--install` で
  書き込んだ `pre-commit` が死んだまま残るので、移行時に掃除すること

hook の中身は、`.env.keys` が workspace 内に存在しないことの検査と `dotenvx precommit`。

### リポジトリ側から無効化できる（強制装置ではない）

git の設定優先順位は **local > global > system** である。イメージが書くのは system
（`/etc/gitconfig`）なので、リポジトリの `.git/config` に `core.hooksPath` を書けば**上書きできる**。
実測（`git config --show-origin --get-all core.hooksPath`）:

```
file:/etc/gitconfig   /usr/local/share/git-hooks
file:.git/config      /tmp/local-hooks        ← 実効値はこちら
```

`--no-verify` でも素通りするし、git CLI を経由しない書き込み（GitHub API、libgit2 系）にも
効かない。**この hook は予防ではなく早期検知**であり、設計上も不変条件ではなく緩和策として
位置づけている。本線は CI 側の検査に置く。

同じ性質が prod にも効く。`.git/config` は clone 後のコードが書き換えられるため、
`core.fsmonitor` のような**コマンドを実行する設定**を仕込まれると、次回の git 操作で走る。
実測では、named volume を再利用する構成で entrypoint 自身の fetch / checkout / reset / clean が
仕込まれたコマンドを 8 回実行した。しかも `/run/secrets/GH_TOKEN` を破棄する**前**である。

**だから `/src` は tmpfs で毎回捨てる。** 下記「なぜ `/src` を使い捨てるのか」を参照。

### ホスト側の git はこれを読まない

`core.hooksPath` はコンテナ内の `/etc/gitconfig` に書かれる。ホストの GUI クライアント（Fork 等）は
従来通り `.git/hooks/pre-commit` を参照するので、**イメージ焼き込みによってホスト側の hook が
無効化されることはない**。両者は独立に動作する。

実際のリスクは、イメージ焼き込みを理由に per-repo の hook 導入（simple-git-hooks 等）を撤去した
場合に、ホスト側だけが無防備になることにある。撤去する場合はホスト側の手当てを同時に行う。

`dotenvx prebuild` は焼いていない。runtime-base では app が存在しないので常に緑の no-op であり、
かつ本設計は app を実行時 clone するため `.env*` がイメージに焼かれる経路自体が無い。

---

## 使い方

### prod でコマンドを実行する

テンプレート一式は [`templates/`](./templates/) にある。**リポジトリの中から実行しない。**

```
templates/compose.prod.yaml            # プロジェクトごとにコピー
templates/prod-run.sh                  # ホストの ~/.local/bin/ 等へコピー
templates/broker-macos-keychain.sh     # 同上
```

dev workspace はホストに bind mount されており、リポジトリ内のラッパーを dev container の
LLM エージェントが書き換えれば、人間がホストで実行する際に正規 broker の前後で鍵を複製できる。
broker と起動スクリプトを dev から到達不能なホストの固定パスに置くことで、この経路を断つ。

```sh
PROD_COMPOSE_FILE=~/.config/acme/compose.prod.yaml \
PROD_BROKER="$HOME/.local/bin/acme-broker" \
PROD_KEYCHAIN_SERVICE=acme-prod-env \
GIT_REPO=https://github.com/acme/app.git \
GIT_REF=<40 桁の commit sha> \
~/.local/bin/prod-run.sh dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy
```

**`dotenvx` を最上位に置くこと。** `prod-run.sh pnpm deploy` の形にすると、`pnpm run` が
`node_modules/.bin` を PATH 先頭に積んでローカルの dotenvx が shim に勝ち、鍵が注入されない
（上の「`pnpm run` の内側では効かない」を参照）。

`GIT_REF` には**完全な commit sha** を渡す。ブランチ名や軽量タグは後から指す先を変えられる。
40 桁 sha でない場合、ラッパーは警告を出すが実行は続行する（署名タグの運用余地を残すため）。

依存インストールはコマンド側の責務になる。`clean -xdff` が `node_modules` も消すため。

```sh
... prod-run.sh sh -c 'pnpm install --frozen-lockfile \
      && dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy'
```

`sh -c` で複数コマンドを繋ぐ場合も、`dotenvx` は `pnpm` の外側に置く。

### 環境変数を確認する

```sh
... prod-run.sh dotenvx get -f .env.prod
... prod-run.sh sh -c 'dotenvx run --strict --no-armor -f .env.prod -- printenv | sort'
```

いずれもファイルを作らない。dev container からは書けるが読めない（値の追加は
`dotenvx set FOO bar -f .env.prod` で秘密鍵なしに行える）。

### 対話シェルが要る場合

stdin が secret の搬送路なので、`run` の対話 TTY とは両立しない。必要な場合は二段構えにする。

```sh
<broker> | docker compose -f compose.prod.yaml run -dT --rm prod sleep infinity
docker exec -it <container> bash
```

entrypoint 完了後なので `/run/secrets` は注入済み。退出後の `docker stop` 忘れが運用上の
唯一のリスクになる。

---

## broker

秘密鍵を保管し、認可を経て dotenv 形式で stdout に出すコマンド。**契約さえ満たせば実装は問わない。**

1. dotenv 形式（`KEY=value` 行）を stdout に出力する
2. 保管中の実体が不揮発ストレージ上で平文でない（OS キーチェーン等の暗号化ストアに置く）。
   **復号鍵そのものが平文でローカルに常駐する方式は契約違反**
3. 取得時に OS レベルの認可（パスワード / Touch ID プロンプト）が働く
4. 非対話環境で認可を得られない場合は非ゼロ終了する

参照実装は [`templates/broker-macos-keychain.sh`](./templates/broker-macos-keychain.sh)（macOS の
`security` CLI）。セットアップ手順はファイル冒頭のコメントにある。Windows 側の標準は未決で、
1Password / Bitwarden CLI への統一も候補に残っている。stdin 注入方式なので、broker はコマンド
1 個の差し替えで移行でき、compose と entrypoint は無変更で済む。

**鍵束は git 管理しない。** 束の中身（`GH_TOKEN` / `CLOUDFLARE_API_TOKEN` 等）は運用者ごとに
異なる個人資格情報であり、リポジトリ共有物ではない。git 管理する暗号化物は `.env.prod`
（dotenvx、プロジェクト共有）だけ。プロジェクト共有の `DOTENV_PRIVATE_KEY_PROD` は各運用者が
自分の鍵束に格納し、運用者間の受け渡しはチームのパスワードマネージャで行う。

> **Keychain の「常に許可」について。** 一度許可すると以降は無確認でアクセスできるようになるが、
> その状態では**同一ホストユーザーの権限で走る任意のプロセス**が認証プロンプトなしに秘密鍵を
> 取り出せる。dev container からは直接呼べない（Docker socket が無く、コンテナ内 UID もホスト
> ユーザーとは別）が、コンテナ脱獄・ホスト連携機能の突破・dev が書いたホスト側スクリプトの
> いずれかを越えれば決定的な穴になる。可能な限り「常に許可」は避け、都度確認または Touch ID
> を選ぶこと。

### `pipefail` は必須

broker が認可失敗で非ゼロ終了しても、パイプの最終要素（docker）が 0 を返せばパイプ全体が
成功扱いになる。secret が一切注入されないまま prod コマンドが走る、という最悪のケースを起動前に
止めるため、起動ラッパーは `set -o pipefail` を必須とする。`zsh` は既定で有効だが、`sh` / `bash`
では明示が要る。

原因の切り分けには SIGPIPE を考慮する必要がある。docker が先に失敗して stdin を閉じると broker
は書き込み中に SIGPIPE を受けて 141 で終了するため、素朴に「broker を先に見る」実装は真の原因を
隠して「broker failed」と誤報告する。`prod-run.sh` はこれを区別している。

---

## リリース

タグを push するとマルチアーキビルドが走り GHCR へ push される。

```sh
git tag runtime-base-v1.0.0 && git push origin runtime-base-v1.0.0
```

`:1.0.0` / `:1.0` / `:1` / `sha-xxxxxxx` が付く。

**リリース順は runtime-base → devcontainer-base。** devcontainer-base は
`FROM ghcr.io/himorogy/runtime-base:${RUNTIME_BASE_VERSION}` で載るため、runtime-base が
GHCR に存在しない段階では `FROM` の解決に失敗する。

参照の仕方は用途で分ける。

| 参照元 | 参照の仕方 | 理由 |
|---|---|---|
| `compose.prod.yaml` | `@sha256:<digest>` で digest pin | prod は「変わらないこと」に価値がある。タグは後から指す先を変えられる |
| `devcontainer-base` | `:1` を追随 | 改善を伝播させたい |

---

## 検証項目

このイメージが壊れていないことの確認は、CI の smoke test に加えて
[`tests/`](./tests/) が担う。

```sh
pnpm lint:sh    # shellcheck
pnpm test       # shim / entrypoint / prod-run の挙動
```

docker が要る項目（compose の実挙動、`read_only` 下の pnpm 完走、keychain ACL ごとの挙動、
core dump の抑止）は実機で確認する。結果は
[verification-record.md](./verification-record.md) に記録する。

### 恒常チェック

**dev container が Docker socket を持たないこと。** `.devcontainer/` に socket mount /
docker-in-docker / docker-outside-of-docker のいずれも無いこと。この前提が崩れると、
dev container から prod container への `docker exec` や任意 volume の mount が可能になり、
本設計の分離全体が無効化される。devcontainer 構成を変更するたびに確認すること。
