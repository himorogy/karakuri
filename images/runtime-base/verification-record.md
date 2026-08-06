# runtime-base 検証記録

設計書 §10「検証項目」の消化状況。**未実施の項目を空欄のまま放置しない**ために、
実施済み・未実施・実施できない理由を全て明示する。

実施日と環境:

- 2026-08-05 / karakuri monorepo（`feat-new-prodshell`）/ dev container 内（Node 24、linux-arm64）
- **この環境には docker が無い**（dev container は Docker socket を持たない。これは設計の前提条件
  そのものであり、崩してはならない）。docker を要する項目は CI（ubuntu-latest）で実行する。
- 2026-08-05 / CI 1 回目 — Docker Engine 28.0.4 / Docker Compose v2.38.2 / linux/amd64。
  ハーネスのバグ（bare repo をコンテナに bind mount していなかった）により大半が未取得。
  取れた 3 件はいずれも決着がついた（下記「CI 実測で決着した項目」）。

凡例: ✅ 実施・合格 / ⬜ 未実施 / ⛔ この環境では実施不能

---

## 0. CI 実測で決着した項目（2026-08-05、1 回目）

### tmpfs の所有権 — 素の短縮形では起動しない（項目 32 に決着）

```
docker run --tmpfs /run （素の形）                     → 755 root:root
  uid 1000 の mkdir /run/secrets                       → Permission denied
docker run --tmpfs /run:uid=1000,gid=1000,mode=0755    → 755 node:node
docker compose （素の短縮形 tmpfs: ["/run"]）           → Permission denied
docker compose （uid=1000,gid=1000,mode=0755 形）       → 受理される
```

tmpfs の既定 mode は 1777 ではなく **755 root:root** だった（`/home/node` でも同じ）。
設計書 §4.2 の素の短縮形では `USER node` の entrypoint が `/run/secrets` を作れず起動に失敗する。
`uid=`/`gid=` 形が必要で、Docker 28.0.4 / compose v2.38.2 のいずれも受理する。
**実装（`uid=1000,gid=1000` 形）が正しい。設計書 §4.2 を rev.5 で差し替える。**

### dotenvx 2.x の環境変数注入 — 効く（項目 40 に決着）

```
dotenvx get -f .env.test FOO              → bar
dotenvx run -f .env.test -- printenv FOO  → bar
```

2.0.0 の resolver 刷新は `DOTENV_PRIVATE_KEY_*` 経路を壊していない。shim 機構は成立する。
1.75.1 へ戻す必要はない。

### dotenvx 1.x で暗号化したファイルの 2.x による復号 — できる（項目 41 に決着）

1.75.1 で暗号化した `.env.legacy` を 2.19.2 が復号できた。既存 4 repo の移行に障害はない。

### shim 経由の鍵注入と鍵の選択 — 正しく動く（2 回目、項目 41b の一部）

```
/run/secrets/DOTENV_PRIVATE_KEY_TEST 経由の dotenvx get -f .env.test FOO → bar
ls -la 前後で差分なし（ファイルを作らない）
_LOCAL と _TEST を同時に置いた状態で
  -f .env.test  → from-test
  -f .env.local → from-local
```

複数鍵が同居してもファイル名規約で正しい鍵が選ばれる。`dotenvx get` はファイルを作らない。

### dotenvx を最上位に置けば内側のローカル dotenvx にも鍵が届く（項目 41b に決着）

```
ケース A: pnpm deploy を直接    → rc=0、FOO=encrypted:BAZG/... （下記 0.1）
ケース B: dotenvx run -f .env.test -- pnpm deploy → rc=0、FOO=bar
```

ケース B では外側の dotenvx が shim に解決され、export された鍵を内側が継承する
（内側は `injected env (0)` — 既存の環境変数が優先されるため再注入しないだけで、値は正しい）。
README / migration に反映済みの運用規約は正しい。

### 匿名 volume は `compose run --rm` で削除される（項目 39 の関連）

run 中に作られた匿名 volume を特定し、run 後に消えていることを確認した。
`/src` は tmpfs にする方針なので直接は使わないが、記録として残す。

---

## 0.1 CI 実測で見つかった新しい穴 — dotenvx の復号失敗が rc=0（I6 違反）

鍵が無い状態で `dotenvx run -f .env.test -- ...` を実行した実測:

```
rc=0
☠ [DECRYPTION_FAILED] could not decrypt FOO
⟐ injected env (2) from .env.test
encrypted:BCPs3nYvfTmgwPuAtSPwucWaifAAJet7fw4j3ZN5qI2CVRSxyevY4dyvnMNh3/oET...
```

**dotenvx は復号に失敗しても非ゼロ終了せず、暗号文をそのまま値として注入する。**
アプリは `FOO=encrypted:BCPs3n...` で起動し、deploy は成功したと報告される。

これは I6（secret の欠落が沈黙した成功にならない）に真っ向から反する。「dotenvx を最上位に
置く」という運用規約では塞げない — 規約を守り損ねたときの失敗が**静か**なままだからである。

**対処は測定で確定した（2 回目、M8）。**

```
dotenvx run --help  →  --strict   process.exit(1) on any errors (default: false)

鍵なし dotenvx run --strict -f .env.test -- printenv FOO  → rc=1
鍵なし dotenvx get -f .env.test FOO                       → rc=1（ただし暗号文は stdout に出る）
注入値の encrypted: 接頭辞を呼び出し側で検査                → rc=1（検出できる）
```

- **`--strict` が正解。** 存在し、復号失敗で `process.exit(1)` する。**prod で `dotenvx run` を
  使うときは必須**とし、rev.5 で設計書へ入れる（運用規約ではなく、欠けたら壊れる要件として）。
- `dotenvx get` は既定で rc=1 を返す。緩いのは `run` だけ。ただし `get` は失敗時も暗号文を
  stdout に出すので、パイプで受ける側は rc を見ること。
- `encrypted:` 接頭辞の検査は第二の防波堤として機能する。`--strict` が将来変わった場合の保険。

### 併せて判明: dotenvx 2.x は既定で外部サービスへ手を伸ばす

`dotenvx run --help` に以下がある（いずれも既定で**有効**、無効化フラグの側が用意されている）。

```
--no-armor        disable Dotenvx Armor features
--no-native       disable OS secret store features
--no-1password    disable 1Password secret reference resolution
--no-bitwarden    disable Bitwarden secret reference resolution
```

Armor は Dotenvx のホスト型サービスであり、`.env` 内の参照や token の解決でネットワークへ出る
経路になりうる。prod container は「変わらないこと」と決定性に価値がある層なので、
**prod では `--no-armor` を付ける**方向で rev.5 に入れる。`--no-native` はコンテナに OS
キーチェーンが無いので実害はないが、意図を明示する意味で併記を検討する。1Password /
Bitwarden も同様。設計書 §11 の「prod への egress-guard 適用」とも関係する。

なお 1.x にはこれらのフラグが無い（機能自体が無い）。2.x へ上げたことで新しく増えた面である。

---

## 0.2 CI 1 回目で判明したハーネスの欠陥（修正済み・再測定待ち）

- **bare repo をコンテナに bind mount していなかった。** `GIT_REPO=file://$SCRATCH/...` を
  渡していたが `$SCRATCH` はランナー上にしか無く、コンテナ内の git から見えない。
  M2 の全項目、M6 の全項目、ASSERT の A5 / A6 / A10 / A16 がこれで落ちた。**実装の欠陥ではない。**
- **A7 / A8 / A9 が誤った理由で通っていた。** これらのコンテナには `/run` の tmpfs が無く、
  entrypoint が stdin をパースする前の `mkdir -p /run/secrets` で権限エラーになっていた。
  非ゼロ終了を assert していたため、意図した経路（空 stdin / 空値 / 入力の非反射）を一度も
  通らずに緑になっていた。**偽の合格**であり、今回の実測が無ければ気付けなかった。
- M3 の shim 経由ケースと M5 のケース B も、素の tmpfs 形を使っていたため同じ理由で死んだ。
- M7 は compose run 自体が失敗していたため、匿名 volume が「作られなかった」のか
  「作られて消えた」のか判別できない出力になっていた。

いずれも修正済み。ハーネスは前提のセットアップを測定前に検査し、失敗時は `HARNESS ERROR` を
1 度だけ出して依存ケースを `SKIPPED (harness setup failed)` にするようにした。

## 0.3 CI 2 回目（2026-08-06）— bind mount は効いたが `safe.directory` のスコープで止まった

bind mount は正しく効き、git は bare repo に到達した。次の壁はこれ。

```
fatal: detected dubious ownership in repository at '/tmp/.../test-bare.git'
```

`$SCRATCH` はランナーのユーザー所有、コンテナは uid 1000 で走るため必ず踏む。

**`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` による `safe.directory` は効かない。**
git は `safe.directory` を protected configuration（system / global）からしか読まない。`-c` と
`GIT_CONFIG_*` はコマンドライン相当のスコープとして扱われ、**意図的に無視される** — そうしないと
信頼できないリポジトリ自身がこの検査を無効化できてしまうため。

対処は `GIT_CONFIG_GLOBAL` に差し替えた。これは global スコープの config ファイルの場所を
置き換えるので `safe.directory` が読まれる。修正済み・3 回目で確認する。

この dubious ownership 自体は**ハーネス固有の事情**である。実運用の `GIT_REPO` は https URL で、
ローカルの所有者検査は関与しない。

2 回目で新たに正しい経路を通ったもの: A7 / A8 / A9（`/run` の tmpfs を uid 形にしたことで、
entrypoint が `mkdir` で死なずに stdin のパースまで到達するようになった）。

依然として未測定: M1 の compose 経由分、M2 の全項目、M6 の全項目、A5 / A6 / A10 / A16。

---

## 0.5 CI 4 回目（2026-08-06）— ASSERT 18/18 が緑。実装の欠陥を 1 件検出

**A1〜A18 が全て通った。** A6 の前回の FAIL はハーネス側（`docker create` の `-i` 欠落）で、
実装の問題ではなかったことが確認できた。

### `/src` の tmpfs 化は成立する（項目 33 の一部）

`read_only: true` + tmpfs `/src` で `git init` / `fetch` / `checkout` / `clean` が完走した。
tmpfs の既定サイズは **7.9G**（ホスト RAM の 50%）。ホストの RAM 量に比例するため、
実行ホストを決める際の判断材料になる（設計書 §11「実行ホストの一本化」）。

### entrypoint の ref 検証が効いた

```
2nd run (tmpfs、GIT_REF=v9.9.9): rc=1
  GIT_REF does not resolve to a commit in the fetched repository: v9.9.9
```

前回の `fatal: git checkout: --detach does not take a path argument 'v9.9.9'` から、
原因が読み取れるメッセージになった。

### `core.hooksPath` は repo 側から上書きできる（実測）

```
effective (git -C /src config --get core.hooksPath): /tmp/local-hooks

git -C /src config --show-origin --get-all core.hooksPath
  file:/etc/gitconfig   /usr/local/share/git-hooks
  file:.git/config      /tmp/local-hooks
```

git の設定優先順位は local > global > system。イメージが書くのは system なので、
**リポジトリの `.git/config` が勝つ**。hook を強制装置として扱えないことの実証であり、
設計書が T6 に不変条件を置かず緩和策として扱っている判断（§3）と整合する。
README の「イメージ側にあるので repo 側は無視される」という記述は不正確だったので修正した。

---

## 0.6 実装の欠陥 — `read_only` 下で `pnpm install` が落ちる（項目 33 は未達）

```
M2  pnpm install --frozen-lockfile : FAILED (rc=254)
    [ENOENT] ENOENT: no such file or directory, mkdir '/usr/local/share/pnpm/store'
```

イメージが `ENV PNPM_HOME=/usr/local/share/pnpm` を設定しており、pnpm の store は既定で
`$PNPM_HOME/store`。`read_only: true` 下では作れない。**このままでは prod の deploy が動かない。**

設計書 §4.5 が pnpm を runtime-base に入れると決めている以上、イメージ側で store を書ける
場所（tmpfs）へ向ける必要がある。ただし置き場所で RAM 消費が変わる。

- **案 A** `$HOME` 配下（`/home/node/.local/share/pnpm/store`）— `/src` とは別の tmpfs
  マウントになる。pnpm は store から node_modules へハードリンクを張るが、マウントを跨ぐと
  張れず copy にフォールバックするはずで、RAM を二重に食う可能性がある
- **案 B** `/src` 配下（`/src/.pnpm-store`）— node_modules と同一 tmpfs なのでハードリンクが
  効くはず。ただし repo の working tree の中に store を置くことになる

どちらも tmpfs なので run をまたいだキャッシュは無く、毎回全依存を再ダウンロードする。
**測定項目 M9 として両方を測る**（RAM 合計・ハードリンクの成否・所要時間、および
`npm_config_store_dir` でイメージに焼けるかの確認）。

## 0.65 CI 5 回目（2026-08-06）— pnpm store は案 B で決定。tmpfs の `noexec` を検出

### store の置き場所 — 案 B（`/src` 配下）が RAM ちょうど半分

```
A（別 tmpfs、store=/home/node/...）  store 130M + /src 132M = 合計 260M   hardlink 0/3546
B（同 tmpfs、store=/src/.pnpm-store）合計 131M（store は /src の内数）    hardlink 3491/3546
```

pnpm 自身が出力で機構を明言している。

```
A: Packages are copied      from the content-addressable store to the virtual store.
B: Packages are hard linked from the content-addressable store to the virtual store.
```

ハードリンクはマウントを跨げないため、案 A は全パッケージを RAM に二重に持つ。
これは karakuri 自身（依存 174、130M）での数字で、実プロジェクトなら差は 1G 級になる。
**案 B を採る。** `/src` は毎回 `git clean -xdff` の後に `pnpm install` するので、
store が working tree の中にあっても同一 run 内では消えない。

`--store-dir` フラグが効くことは確認できた。**イメージへ焼く方法は未確定**（M9-c は下記の
理由で測定失敗）。

### tmpfs の `noexec` で node_modules のバイナリが動かない（新しい欠陥）

M9-a / M9-b とも `rc=126`。依存の解決とリンクは成功（`added 174, done`）していて、
落ちたのはその後である。

```
packages/enclave-env prepare$ pnpm run build
packages/enclave-env prepare: $ tsup
packages/enclave-env prepare: sh: 1: tsup: Permission denied
[ELIFECYCLE] Command failed with exit code 126.
```

store の場所と無関係に両ケースで同一の症状。docker の tmpfs マウントは既定で
`rw,nosuid,nodev,noexec` が付き、noexec マウント上の実行ファイルを exec すると EACCES に
なってシェルは "Permission denied" と報告する。症状が一致する。

**影響は致命的で、`node_modules/.bin` の実行ファイルが一切動かない。** `pnpm run build` も
deploy も成立しない。M2 で git 操作が通ったのは git が `/usr/bin`（noexec でない）にあるため。

`/src` は信頼しないコードを**実行するための場所**なので、そこを noexec にする意味は元々ない。
`/run`（secrets）と `/out`（成果物）は noexec のままでよい。tmpfs に `exec` を明示する形で
M9-d（`mount` の直接確認と自作スクリプトの実行）と M9-e（`exec` 付きでの `pnpm install` 再測定）
を追加した。**ユーザーがオプションを渡したとき docker の既定 `noexec` が残るか置き換わるかは
未確認**なので、M9-d で直接測る。

### M9-c は測定失敗

```
素の pnpm store path              → [EACCES] permission denied, open '/_tmp_8_...'
npm_config_store_dir を与えた場合 → 同じ EACCES
M9_C_CHANGED=YES   ← 両方エラーなので誤判定
```

`pnpm store path` が cwd（`read_only` の `/`）にプローブ用の一時ファイルを作ろうとして落ちた。
`-w /tmp` を付け、両方の rc が 0 のときだけ比較する形へ直した（片方でもエラーなら
`UNKNOWN` と出す）。

## 0.68 CI 6 回目（2026-08-06）— `noexec` 確定、`exec` で解決、prod は成立する

### tmpfs は `noexec` でマウントされる（M9-d、実測）

```
exec 明示なし: tmpfs on /src type tmpfs (rw,nosuid,nodev,noexec,relatime,mode=755,uid=1000,gid=1000)
               /src/t.sh → Permission denied、rc=126
exec 明示あり: tmpfs on /src type tmpfs (rw,nosuid,nodev,relatime,mode=755,uid=1000,gid=1000)
               /src/t.sh → EXEC_OK、rc=0
```

推測どおりだった。**`uid=`/`gid=`/`mode=` を渡しても docker の既定 `noexec` は残る**。
消すには `exec` の明示が要る。`/run` `/tmp` `/out` `/home/node` も全て `noexec` で
マウントされていた。

- `/src` … **`exec` が必須**。信頼しないコードを実行するための場所であり、noexec にする
  意味は元々ない
- `/run`（secrets）と `/out`（成果物）… noexec のままが正しい
- `/tmp` … 一時ファイルを実行する種類のツール（node-gyp 等）が踏む可能性がある。
  実際に踏むまでは noexec のままにする

### 案 B + `exec` で prod は成立する（M9-e、項目 33 に決着）

```
rc=0
packages/enclave-env prepare: CLI tsup v8.5.1
packages/enclave-env prepare: ESM dist/cli.js 7.58 KB
packages/enclave-env prepare: ESM ⚡️ Build success in 11ms
M9_E_BUILD_RAN=YES
hardlink 3491/3547   合計 131M
```

`read_only: true` + tmpfs `/src`（`exec` 付き）+ store 同居で、`pnpm install` から
`prepare` の tsup ビルドまで完走した。

#### 判定材料を差し替えて測り直した（2026-08-06）

上の測定は `packages/enclave-env/dist/cli.js` の有無を「`prepare` が走ったか」の判定材料に
していた。`dist/` は gitignore 対象なので、checkout 直後には無く、`prepare` の tsup ビルドが
完走して初めて現れる、という理屈である。

**そのパッケージを廃止したので、この判定材料は成立しなくなった。** workspace に
`build` / `prepare` を持つパッケージはもう 1 つも無く、放置すれば
`M9_E_BUILD_RAN=NO`（= prepare が走らなかった）を返し続ける。測定対象が消えたことを理由に
失敗を報告する測定は、測定が無いより悪い。見た目が「発見」になる。

間接的な問い（prepare が走ったか）をやめ、**直接聞く**形に変えた — `node_modules/.bin` の
実体を 1 つ実行し、終了コードを見る。0 なら動く、126 なら noexec の Permission denied、
それ以外は UNKNOWN（バイナリが自分の理由で失敗したものを、マウントの問題と取り違えない）。
`node_modules/.bin` が無い・空の場合も NO ではなく UNKNOWN とする（実行するものが無いのと、
実行して拒まれたのは別である）。

```
M9_E_EXEC=YES (biome)
M9_RC=0
M9_STORE_KB=78432   M9_SRC_KB=80712   M9_OUT_KB=4
M9_LINKED=1679      M9_TOTALF=1705
M9_ELAPSED=3
pnpm install 出力中の tsup / Permission denied 関連行: (該当行なし)
```

- **`M9_E_EXEC=YES`** — `/src` の tmpfs に `exec` を明示した効果が、パッケージ構成に依らない
  判定材料で確認できた。以前の判定材料が偶然そこにあったパッケージに依存していたのに対し、
  こちらはどのパッケージにも依存しない
- **ハードリンク 1679 / 1705（98.5%）** — store が `/src` と同一 tmpfs にあることの確認。
  別マウントだとリンクが跨げず copy にフォールバックし、この比率は 0 に近くなる（D19）
- **`/src` 合計 79M**（`M9_SRC_KB=80712`。store はその内数）。**以前の実測 131M から減っている** —
  enclave-env を廃止したことで tsup / esbuild / typescript が依存木から消えたため。
  イメージや構成の変更によるものではない
- 所要時間 3s。noexec の症状（`sh: 1: tsup: Permission denied`）は再現せず

この回の測定は、named build context 経由でスキャナと hook を焼き込む構成の**初回のビルド**でも
ある（`build-contexts: env-guard=packages/env-guard` + `COPY --from=env-guard`）。
`runtime-base` と `runtime-base-verify` の両方のビルドが通っており、ビルドコンテキストを
`images/runtime-base` のまま広げずに済むことが実測で確認できた。

### store-dir の固定手段（M9-c）

```
素の pnpm store path              → /usr/local/share/pnpm/store/v11
npm_config_store_dir を与えた場合  → /usr/local/share/pnpm/store/v11（変わらない）
M9_C_CHANGED=NO

pnpm config set store-dir --global → OK
pnpm config list --global          → "storeDir": "/home/node/.local/share/pnpm/store"
```

環境変数 `npm_config_store_dir` は**効かない**。`config set --global` は効く。

ただし **Dockerfile に焼くのは不適切**である。dev container の store は
`/workspaces/.pnpm-store`（実測で 320M 存在）にあり、prod の `/src/.pnpm-store` とは別物。
runtime-base に焼くと devcontainer-base 側が `/src/.pnpm-store` を作ろうとして壊れる
（dev に `/src` は無い）。**prod だけに効かせる手段**が要る。

`$HOME`（`/home/node`）が tmpfs で `read_only` 下でも書けることを使う案を M10 で測る。

- **M10-a** `$HOME/.npmrc` に `store-dir=` を書く（第一候補）
- **M10-b** `$HOME/.config/pnpm/rc` に書く
- **M10-c** `pnpm config set store-dir`（`--global` なし）が read_only 下で通るか、通るなら
  どこへ書かれるか
- **M10-d** 効いた方法で `--store-dir` フラグ**なし**の `pnpm install` が完走するか

いずれも効かない場合の代替は、`prod-run.sh` のコマンドに `--store-dir` を渡す運用にすること。
忘れると ENOENT で**明示的に落ちる**ので、M5 の dotenvx（rc=0 で沈黙）とは違い fail-loud であり、
I6 には抵触しない。

## 0.69 CI 7 回目（2026-08-06）と、その後の追加確認 — rev.5 の材料が揃った

### store-dir の固定手段（M10）

```
a  $HOME/.npmrc に store-dir=            → NO（効かない）
b  $HOME/.config/pnpm/rc に store-dir=   → NO（効かない）
c  pnpm config set store-dir（--global なし） → YES。store path が /src/.pnpm-store/v11 を指す
d  方法 c で --store-dir フラグなしの install → rc=0、Packages are hard linked、3491/3547
```

CI では c の**書き込み先が特定できなかった**（`$HOME/.npmrc` / `$HOME/.config/pnpm/rc` /
`/src/.npmrc` のいずれにも無い）が、その後この dev container 上で再現して確定した。

```
$ HOME=<tmp> pnpm config set store-dir /src/.pnpm-store
$ cat <tmp>/.config/pnpm/config.yaml
storeDir: /src/.pnpm-store
```

**`$HOME/.config/pnpm/config.yaml` に YAML で書く。** a / b が効かなかったのも、CI の探索が
外したのも、**ファイル名と形式の両方が違った**ためである（`store-dir=` ではなく `storeDir:`）。
prod では `/home/node` が tmpfs なので毎回新規に書かれ、entrypoint が毎回設定する形と整合する。

イメージに焼かない判断は変わらない — dev container の store は `/workspaces/.pnpm-store` に
あり `/src` は存在しないため、runtime-base に焼くと devcontainer-base 側が壊れる。

### 設計書 rev.5 と実装への反映（2026-08-06）

ここまでの実測を設計書 rev.5 として確定させ、実装を追従させた。

- `/src` を named volume → tmpfs（`exec,uid=1000,gid=1000,mode=0755`）。`volumes:` ブロック削除
- entrypoint に `pnpm config set store-dir /src/.pnpm-store` を追加
- prod のコマンド例を `dotenvx run --strict --no-armor -f ... -- ...` に統一
- 新しい設計判断 D18（`/src` tmpfs）/ D19（store を同一マウント）/ D20（`--strict` 必須）
- D5 の「全経路で効く」を訂正、§4.2 の tmpfs 記法・§4.6 の askpass・§4.7 の `core.hooksPath` を
  実測に合わせて修正、broker 契約に dotenv 方言を明文化、`sudo` の受容を明記

## 0.71 CI 8〜9 回目（2026-08-06）— 出荷 compose を検証対象に入れた

ここまでのハーネスは compose ファイルを**全て自前生成**しており、実際に配布する
`templates/compose.prod.yaml` 自身は一度も検証されていなかった。構造検査（A19〜A34）と
実挙動検査（B1〜B5）を追加した。

**B1〜B5 は 8 回目から通っている** — 出荷ファイルはそのまま起動し、`/src` は `exec` 付き、
`/run` は `noexec` かつ `node:node` 所有、`/src` に置いた実行ファイルが動く。

### `docker compose config` は ulimits の値 0 を落とす

構造検査で唯一落ちたのが `ulimits.core` で、9 回目に実際の値が出た。

```
実際の値 (.services.prod.ulimits): {"core":{}}
```

`core: 0` と書いてあるのに**空オブジェクト**になる。Go 側の `omitempty` がゼロ値を落として
いるとみられる（未確認）。結果として **`config` の出力では「core が 0」と「core が未設定」を
区別できない**。この経路での値の検査は原理的に不可能である。

対処:

- **A23** は「`core` キーが存在すること」= ulimits の指定がまるごと消えていないこと、に縮小した
- **B5** を新設し、出荷ファイル由来のコンテナを実際に起動して `ulimit -c` が 0 を返すことを
  確認する。値を見たいなら挙動を見るしかない

他の構造検査がこの罠を踏んでいないことも確認した。`read_only` は `true`、`user` /
`working_dir` / `logging.driver` は文字列、`entrypoint` / `tmpfs` は配列で、いずれもゼロ値では
ないため `omitempty` の対象にならない。

### 失敗が何も言わない検査は二度手間になる

8 回目の A23 は `jq -e ... >/dev/null` だけで書かれており、落ちた事実しか分からなかった。
正規化形を推測し直して直したが、9 回目もまた落ちた。**実際の値を出すようにしてから 1 回で
決着した。** 構造検査は全て、失敗時に該当部分の JSON を stderr へ出す共通ヘルパ経由にした。

## 0.72 CI 10 回目（2026-08-06）— 全て緑

```
41 measurements recorded, 39 assertions passed, 0 failed
```

SKIP なし。**docker が要る検証項目は全て消化した。** 出荷する `templates/compose.prod.yaml`
そのものについて、構造（A19〜A34）と実挙動（B1〜B5）の両方が確認できている。

以降、この一覧で「未実施」として残るのは §11 の未決事項に紐づくもの
（macOS ホスト固有の項目と、手順 4 以降の範囲）だけである。詳細は下記 §3 の表を参照。

## 0.8 dotenvx precommit は CI で「検査した風の緑」を返す（項目 48 に決着）

2026-08-06、この dev container 上で dotenvx **2.19.2** を使って実測した（docker は不要）。
設計書 §8.2 が「CI のクリーン checkout では no-op になる**疑い**」として残していた項目である。

```
クリーン checkout / 差分ゼロ / 平文 .env が tracked（2 件）  rc=0  ▣ encrypted/gitignored (2)
  ├ 同上 + 位置引数 apps/backend                            rc=0  ▣ encrypted/gitignored (1)
平文 .env を staged にした状態                              rc=1  ☠ .env not encrypted/gitignored
平文 .env を未 staged で編集した状態                        rc=1  ☠ 同上
平文 .env.new を untracked のまま置いた状態                 rc=0
  └ 同 .env.new を staged にした状態                        rc=1  ☠ .env.new not encrypted/gitignored
平文 .env が gitignore 済み・untracked（正常系）            rc=0
暗号化済み .env が tracked / 差分ゼロ（正常系）             rc=0
```

**疑いより悪かった。** 単に何も検査しないのではなく、平文の tracked `.env` を 2 件
**見つけたうえで**「encrypted/gitignored (2)」という件数付きの緑を返す。CI に置けば
「見ている」という誤った安心だけが残り、無いより悪い。

`precommit` が壊れているのではなく、**文脈が違う**。検査対象は `git diff HEAD` の差分で
あり、staged 差分がある hook の文脈では正しく効く（上の 2 行目・4 行目が実測）。CI は
クリーンな checkout なので、見るべきは差分ではなく **tracked なファイルの現在の状態**である。
同じ道具を両方の文脈に使い回そうとしたのが誤りだった。

設計書は当初案（CI で `dotenvx precommit` を呼ぶ）を破棄し、tracked ファイルの直接走査へ
差し替えた（rev.7 / D23）。

**さらにその先で hook 側も変わった（D24）。** CI を差し替えた結果、hook（`dotenvx precommit`）
と CI（独自走査）で**判定の実装が 2 つ**になり、「hook は通るが CI で落ちる」という新しい
分岐を作ってしまっていた。判定を共有スキャナ `bin/env-guard-scan` 1 本へ寄せ、hook は staged
の一覧を、CI は tracked の一覧を渡すだけにした。**スコープだけが違い、判定は同一**になる。
hook から `dotenvx precommit` は外れた — 自前のファイル名フィルタを持っていて上書きできず、
プロジェクトごとの検査対象の上書きを入れた時点で逆向きの分岐を作るためである。

### 併せて決着: `--convention flow --strict` は実際に壊れる

設計書 D20（`--strict` をイメージ側で強制しない）の最大の論拠が、rev.6 の時点では
`--ignore=MISSING_ENV_FILE` の存在**からの推論**だけに立っていた。レビューで
「未実測の推論だけで決めたのは不十分」と指摘された箇所である。同じ実測で潰した。

```
ファイル構成: .env, .env.local（存在）/ .env.development（不在）

--convention flow                                  rc=0  injected env (2) from .env.local, .env
--convention flow --strict                         rc=1  ☠ [MISSING_ENV_FILE] missing file (.env.development.local)
--convention flow --strict --ignore=MISSING_ENV_FILE  rc=0
-f .env（存在）--strict                            rc=0
-f .env.missing（不在）--strict                    rc=1
-f .env.missing（不在）strict なし                 rc=1
```

**壊れる。** `--strict` を焼き込めば `--convention flow` の正当な使い方が落ちる。D20 の
判断は維持され、根拠が推論から実測に変わった。

**副次的な発見**: 最後の 2 行が示すとおり、`-f` でファイルを明示した場合は不在ファイルが
`--strict` の有無に関わらず rc=1 になる。prod は `-f .env.prod` を明示する運用なので、
prod で `--strict` が追加で担うのは**復号失敗の顕在化だけ**である。

## 0.9 40 桁 hex を名前とする ref は現行 git では成立しない（項目 53）

レビューが「未確認」として挙げた攻撃経路 —
「dev が 40 桁 hex 文字列を名前とするブランチ／タグを push し、その hex に対応する
オブジェクトは存在しない状態を作ると、`git rev-parse --verify "<40hex>^{commit}"` が
`refs/remotes/origin/<40hex>` へフォールバックして解決に成功しうる」— を git **2.39.5**
で実測した。

**再現しない。** git はこのケースを意図的に無視する。

```
warning: refname '<40hex>' is ambiguous.
  Git normally never creates a ref that ends with 40 hex characters ...
  ... it will be ignored when you just specify 40-hex.
rc=1
```

ブランチ（`refs/remotes/origin/<40hex>`）とタグ（`refs/tags/<40hex>`）の両方で確認した。

それでも一致検査（解決結果が `GIT_REF` 自身と一致すること）は実装に入れてある。
`rev-parse` の DWIM 規則は git のバージョンと実装（libgit2 系、将来の変更）に属するもので、
本設計が管理できる範囲にない。3 行で済み、完全 sha の経路にしか走らない。
**現行 git に対しては多重防御である**ことを、ここに明示して記録する。

なお回帰テストが押さえているのは「非ゼロ終了し、実行 ref の記録が残らない」ことであり、
どちらの経路（新しい一致検査か、既存の "does not resolve" か）で落ちるかは git 版に依存する。

## 0.11 env-guard のテストが「検知能力を持つ」ことの否定対照（2026-08-06）

この記録が繰り返し学んできたのは、**検査が緑であることと、検査に検知能力があることは別**という
一点である（§0.2 の偽の合格、§0.71 の何も言わない検査、そして §0.8 の `dotenvx precommit`）。
新しく入れた env-guard のテスト自体が同じ罠に落ちていないことを、実際に壊して確認した。

**否定対照 1 — 判定ロジックを壊す。** スキャナの暗号化判定
（`^[A-Z0-9_]+="?encrypted:`）を `.*`（何にでも一致 = 常に「暗号化済み」と見なす）へ差し替えた。

```
68 passed, 0 failed   → 51 passed, 17 failed
```

落ちたものの中に、平文 fixture が rc=0 で通ってしまう形が含まれる:

```
expected rc=1, got rc=0
output: env-guard: inspected docs/.env.sample
        env-guard: OK — inspected 1 file(s), no unencrypted values.
```

**否定対照 2 — hook と CI を食い違わせる。** hook 側にだけ CI が持たない絞り込み
（`grep -v '\.env\.sample'`）を挟んだ。

```
68 passed, 0 failed   → 66 passed, 2 failed
```

落ちたのは「両方の入口から同じ終了コードが返る」と「両方の入口から出力がバイト単位で同一に
なる」の 2 件。**D24 の本題がテストで守られている**ことの直接の証拠になる。

どちらも元に戻して 68 passed / 0 failed に復帰することを確認済み。全スイート合計は
25（shim）+ 38（entrypoint）+ 15（prod-context）+ 68（env-guard）+ 5（hook）= **151 passed,
0 failed**、`shellcheck` は rc=0。

**GitHub Actions 上での実行は未実施。** reusable workflow の呼び出し規約（呼び出し側の
checkout、第二 checkout の ref 解決）はローカルでは動かせないため、次回 CI が初回になる。

## 0.10 tmpfs 自己検査を入れたことで、ハーネスの一部が entrypoint を迂回する

rev.7 で entrypoint に「`/src` と secret の置き場が tmpfs であること」の自己検査を入れた
結果、**named volume 構成を意図的に作って測っていた既存の測定が、測りたいところへ到達する
前に止まる**ようになった。該当は M6（N-1 の ref 汚染 / N-2 の `.git/config` 持続 /
credential.helper 経由の窃取）と M1 の `compose_uid_stat`。

これらは「named volume だと穴が残る」ことを実証した測定であり、tmpfs 化（D18）の根拠その
ものなので、消すわけにはいかない。

**採った手段**: setup 時に**イメージの中身**から entrypoint を取り出し
（`docker run --entrypoint cat "$IMG" /usr/local/bin/prod-entrypoint.sh`。作業ツリーの
`bin/` ではない）、自己検査のループ対象行だけを sed で番兵パスへ差し替えたコピーを作り、
該当測定にだけ `--entrypoint` で渡す。番兵はどのマウントとも一致しないため、検査は
「該当行なし → WARNING → 続行」に落ちる（迂回した痕跡が出力に残る形を選んでいる）。

**沈黙した迂回にしないための手当て**:

- sed が効かなかった場合（entrypoint の書き方が将来変わった場合）は素通りさせず、setup で
  `exit 1` する。素通りすると M6 が「自己検査で止まった rc=1」を N-1 / N-2 の結果として
  記録する**偽の測定**になる
- setup ログに `diff -u`（元 vs 番兵差し替え後）を出力し、何を無効化したかが記録に残る
- 自己検査そのものが効いていることは **A35** が別途 ASSERT する（下記）

**entrypoint を経由しない形は採らなかった。** N-2 が見たいのは「entrypoint 自身の
fetch / checkout / reset / clean が `core.fsmonitor` を起動させるか」であり、entrypoint を
外すと測定の意味が変わる。

### 新しく足した docker 依存の検証

- **A35（ASSERT）** — `/src` が named volume の構成で entrypoint が非ゼロ終了し、かつ
  **`/src` が tmpfs でないことを名指ししたメッセージが出る**こと。「落ちた」だけでは通さない
  （§0.71 の教訓: 失敗が何も言わない検査は二度手間になる）
- **A36（当初は M11 という MEASURE）** — secret の置き場（`/run`）を tmpfs から外した構成。
  `read_only: true` との併用可否も、uid 1000 が `mkdir -p /run/secrets` できるかも docker
  無しでは確認できなかったため、初回は**推測で ASSERT にせず**測定として書いた。どちらかで
  先に落ちるなら「自己検査までは届かない」が観測結果であって、自己検査が止めたわけではない
  ためである。昇格条件（出力に `is not a tmpfs` を含むこと）をハーネスのコメントに明記して
  おき、**CI 11 回目でそれが満たされたので ASSERT に変えた**（§0.12）
- **誤検知側の担保に新規 ASSERT は足していない。** B1〜B5 は出荷ファイル由来の全 tmpfs
  構成で entrypoint を完走させる ASSERT なので、自己検査が誤検知すれば軒並み FAIL する
  （`docker_prod_run` 経由の A5 / A10 / A16 も同じ性質）

## 0.12 CI 11 回目（2026-08-06）— rev.7 の docker 依存分が全て通り、M6 の腐りが 1 件出た

```
42 measurements recorded, 40 assertions passed, 0 failed
```

### A35 / A36 — tmpfs 自己検査は実際にドリフトを止める

**A35 が通った。** `/src` を named volume に戻した構成で entrypoint が非ゼロ終了し、
`/src is not a tmpfs` と名指しした。設計上の防壁が動くことが実測で確認できた。

**A36（旧 M11）は昇格した。** 未確認だった前提が両方とも肯定側で決着している。

```
prod-entrypoint: /run is not a tmpfs: fstype=ext4
prod-entrypoint:   mount line: /dev/root /run ext4 rw,relatime,discard,errors=remount-ro,commit=30 0 0
```

- `read_only: true` と `/run` への bind mount の併用は**受理される**
- uid 1000 は 0777 の bind mount 先に `mkdir -p /run/secrets` **できる**
- したがって自己検査まで到達し、そこで止まる

ハーネスに書いておいた昇格条件（出力に `is not a tmpfs` を含むこと）を満たしたので、測定から
ASSERT へ変えた。測定のままだと、この経路が壊れても記録に残るだけで CI は緑になる。

### 迂回は効いた — N-2 は健在

番兵パスへの差し替えは意図どおり動いた（`WARNING: cannot verify that
/verify-tmpfs-self-check-disabled is a tmpfs` が出力に残る）。N-2 の再現は無傷である。

```
named volume: FSMONITOR_RAN が 8 回
tmpfs:        0 (fresh .git/config)
```

### N-1 が D21 に食われていた（この回で見つけた腐り）

```
2nd run (同じ volume、GIT_REF=v9.9.9): rc=1
  prod-entrypoint: GIT_REF must be a full 40-character commit sha: v9.9.9
```

N-1 の再現はタグ（`v9.9.9`）を `GIT_REF` に渡すことで成立する測定だが、rev.6 で入れた D21 が
完全な commit sha 以外を既定で拒否するため、**ref 解決に一度も到達していなかった**。

named volume 側は「rc=1」だけが残って再現を示せず、**tmpfs 側はもっと質が悪い** —
期待していたのが「`v9.9.9` が存在せず fail-closed」なので、ゲートで落ちても rc=1 になり、
**期待値と一致しているように見える**。意図した経路を一度も通らずに期待どおりの結果が出る、
この記録が繰り返し踏んできた偽の合格そのものである。

D18 の歴史的な根拠（CI 3 回目、D21 が存在しなかった時点の実測）は有効なので設計判断は動かない。
ただし**この形のままでは N-1 の退行を検出できない**ため、2nd run に
`PROD_ALLOW_MUTABLE_REF=1` を渡してタグ経路を実際に通すよう直した。あわせて、出力の読み方
（何が出ていれば再現で、何が出ていたら測定が成立していないのか）を測定自身が出すようにした。
**次回の CI が初回の実行になる。**

教訓の追加: **不変条件を強化すると、その不変条件を破る前提で書かれた過去の測定が黙って
無効化される。** 検査を足したときは、その検査より前に書かれた測定が意図した経路を通り続けて
いるかを確認する必要がある。

**CI 12 回目（2026-08-06）で直りを確認した。** 両ケースとも意図した経路を通っている。

```
named volume: GIT_REF=v9.9.9 resolved to 82e97a9 → HEAD is now at 82e97a9 commit2 → file.txt=world
tmpfs:        GIT_REF does not resolve to a commit in the fetched repository: v9.9.9  (rc=1)
```

named volume では**前回実行が打ったタグが commit2 を指したまま解決され**、指定したはずの
ものとは別の内容が checkout された（N-1 の再現）。tmpfs ではタグが残らず fail-closed。
D18 の根拠が、D21 を入れた後の実装に対しても再度実測で立った。

この回の合計は **41 measurements, 41 assertions passed, 0 failed**（A36 の昇格で ASSERT が
1 件増えている）。

### `github.job_workflow_ref` は空だった（項目 63）

`ci.yml` からの env-guard 呼び出しは、スキャナを取りに行く前の ref 解決で止まった。

```
job_workflow_ref: <empty>
❌ env-guard: could not work out which karakuri commit this workflow came from.
```

**設計どおり fail-closed で止まった**という点では意図どおりである。「取れないときに main へ
倒す」を書いていたら、workflow とスキャナの版が食い違ったまま緑になっていた。

`github.job_workflow_ref` はドキュメント上 reusable workflow のジョブで使えることになって
いるが、**少なくともこの経路では値が来ない**。karakuri 自身の `ci.yml` は
`uses: ./.github/workflows/env-guard.yml` というローカルパス呼び出しなので、
**ローカルパス呼び出しに限った話である可能性**と、**`github` コンテキストでは常に空
（OIDC のクレームにしか無い）である可能性**の両方があり、区別できていない。他 org からの
`owner/repo/...@ref` 形式での呼び出しは未実測。

推測でどちらかに倒さず、次回の実行で候補フィールド（`job_workflow_ref` / `workflow_ref` /
`repository` / `ref` / `ref_name` / `sha`）を全部出す診断ステップを入れた。

**あわせて、推測ではない代替経路を 1 本足した。** ref が読み取れないとき、
**呼び出し側の作業ツリーにスキャナ自体が入っている**なら、それを使う。この状態が成立するのは
呼び出し側が karakuri のツリーを持っているときだけで、それはまさにローカルパス呼び出しの形で
ある。他 org のプロジェクトに `images/runtime-base/bin/env-guard-scan` は無いので、
見つからなければ従来どおり落ちる（fail-closed は維持）。

self-call ではこちらの方が**正しくもある** — タグが指すスキャナではなく、いま検査されている
その PR のスキャナが走るので、版の食い違いが原理的に起きない。

**CI 12 回目で in-tree 経路が通った。**

```
job_workflow_ref: <empty>
scanner source: the caller's own checkout (this workflow was called by path)
```

karakuri 自身の env-guard は緑になった。ただし**通ったのは self-call 専用の経路**であり、
**他 org から `@v1` で呼ぶ本来の伝播経路は一度も実行されていない**。

### 診断の全項目（CI 12〜13 回目）

```
job_workflow_ref: <empty>
workflow_ref:     himorogy/karakuri/.github/workflows/ci.yml@refs/pull/11/merge
repository:       himorogy/karakuri
ref:              refs/pull/11/merge
ref_name:         11/merge
sha:              ...
event_name:       pull_request
```

`workflow_ref` は正しく埋まっている（指しているのは**呼び出し側**の `ci.yml`）。コンテキストの
取得自体は機能していて、`job_workflow_ref` だけが空である。

**`workflow_ref` は代用にならない。** 指すのは呼び出し側の workflow なので、他 org から
呼ばれれば他 org のリポジトリを指す。karakuri が自分を呼ぶときだけ動いて他所では壊れる、
という使える中で最悪の形になる。

同一リポジトリを指す**完全参照形**（`himorogy/karakuri/.github/workflows/env-guard.yml@<branch>`）
でも `job_workflow_ref` は空だった。参照自体は解決している（その呼び出しの診断出力が取れている）
ので、「デフォルトブランチに無いと参照できない」という話ではない。

### ここまでで言えること・言えないこと（重要）

- **言える**: ローカルパス呼び出しでも、同一リポジトリを指す完全参照呼び出しでも、
  `job_workflow_ref` は空である
- **言えない**: 「`github` コンテキストでは常に空」。測ったのは**呼び出し元と呼び出し先が
  同じリポジトリ**の場合だけで、GitHub がその条件を内部的にローカル呼び出し扱いして値を
  埋めない可能性を排除できていない。**他 org からの本当の cross-repo 呼び出しでは埋まる
  かもしれない**

したがって「reusable workflow による伝播は成立しない」と結論するのは早い。**他 org の
リポジトリからの呼び出しを一度実行するまで、この点は未決**である（項目 49 と同じ制約）。

### この先は §8 の範囲であって手順 4 ではない

手順 4 は「reusable workflow の設置とスタブ配布（precommit の CI 実効性を先に実測）」であり、
karakuri 自身が検査を通していること（ローカルパス呼び出しで緑）まででその範囲は満たしている。

一方、**他 org へどう届けるか**は設計書 §8 の範囲で、§8 自身が「本節は方向性の記録であり、
詳細設計は §4 の実装完了後に別途行う」「当面の 4 repo への展開は手動コピーで開始してよい」と
明記している。上記の未決はそちらで扱う。

**未確認の可能性への先回りで配布方式を作り直しかけたが、戻した。** 実測で言えることと言えない
ことの線を引き直した結果、作り直しの前提そのものが立っていなかった。§8 に着手するときの
出発点として、ここまでの実測と未決を記録に残すに留める。

### 設計書の記号がそのまま運用の出力に出ている

```
prod-entrypoint:   意図する場合は PROD_ALLOW_MUTABLE_REF=1 を設定する（設計書 D21）
```

設計書は git 管理外にあり、イメージは他 org へ配布する前提なので、受け取った側に `D21` の
参照先は存在しない。§4.8 の規約どおり、PR 前に一括で棚卸しする。

## 0.7 原理上この方法では測れないもの

- **`credential.helper` 経由の `GH_TOKEN` 窃取。** `file://` はホスト上のパスへの直接アクセスで
  認証を要求しないため、git が credential helper を呼ばない。https の remote と実トークンが
  要る。ただし `core.fsmonitor` で同じ経路（`.git/config` に書かれた設定が entrypoint の
  git 操作で発火し、それが `GH_TOKEN` 破棄より前に起きる）が実証されているので、
  **対処は同じ**であり、この 1 項目が未確定でも判断は変わらない。

---

## 0.4 CI 3 回目（2026-08-06）— N-1 / N-2 が実証され、`/src` の tmpfs 化に裏付けがついた

preflight を通過し、M6 が取れた。**この設計変更の根拠が推論から実測になった。**

### N-1 ref 汚染 — named volume で再現する

```
1st run  commit1 を checkout 後、ローカルタグ v9.9.9 を commit2 に打つ  → rc=0
2nd run  同じ volume、GIT_REF=v9.9.9                                   → rc=0
         HEAD is now at fe2ef9c commit2
         file.txt = world          ← commit2（攻撃者が指した先）の内容
```

前回実行の（信頼しない）コードが打ったローカルタグが解決され、**指定したはずのものとは別の
commit が checkout された**。`git fetch --tags` は既存ローカルタグを clobber せず、ローカル
branch は fetch の対象外。rev.4 で足した `reset --hard` は tracked file の改変には効くが、
**ref そのものが汚染されている場合は「汚染された ref へ正しく復元する」だけ**で I7 を守らない。

tmpfs 側では 2nd run が rc=128 で失敗した。毎回まっさらなので `v9.9.9` が存在せず、
汚染 ref を拾いようがない（fail-closed）。

### N-2 `.git/config` 持続 — named volume で再現する

```
1st run  core.fsmonitor に目印コマンドを仕込む  → rc=0
2nd run  同じ volume、同じ GIT_REF              → rc=0
         FSMONITOR_RAN が 8 回
```

仕込んだコマンドが **entrypoint 自身の fetch / checkout / reset / clean で 8 回実行された**。
git の設計優先順位は local > system なので、イメージの `/etc/gitconfig` は repo の
`.git/config` に上書きされる。しかも実行位置は `rm -f /run/secrets/GH_TOKEN` の**前**であり、
**トークンがまだ存在する状態で任意コードが走る**。機密性の穴である。

tmpfs 側では `0 / 0 (fresh .git/config)`。仕込みが残らない。

`credential.helper` 経由の窃取は `NOT_PRESENT` で再現しなかった。`file://` は認証を要求せず
git がヘルパを呼ばないため。**https でないと測れないので未確定のまま残る**（原理上は
`core.fsmonitor` と同じ経路が成立するため、対処は同じ）。

### tmpfs 化で両方が構造的に消える

named volume を捨てて `/src` を tmpfs にすれば、毎回まっさらな repo から始まるため
N-1 も N-2 も成立しない。R6（prod のコードが `/src` へ書いた復号値やトークンが Docker VM の
ディスクに残る）も同時に消える。設計書 D8 / §4.6 を rev.5 で差し替える。

### tmpfs の所有権 — compose 側でも確定（項目 32 完了）

```
compose 素の短縮形 tmpfs: ["/run"]        → Permission denied
compose uid=1000,gid=1000,mode=0755 形    → fetch/checkout 成功、755 node:node
```

`docker run` と `docker compose` で挙動が一致した。実装が正しい。

### ASSERT は 17/18

A5 / A10 / A16 が通った。A6 のみ FAIL だったが、原因は**ハーネスの不具合**である
（`docker create` に `-i` が無く、コンテナの STDIN が開かれないまま作られていたため、
stdin 経由の secret が entrypoint に届かず `no secrets received on stdin` で落ちていた。
`docker start -ai` の `-i` は既に開いている STDIN への attach を意味するだけで、create 時点で
閉じていれば効かない）。修正済み・4 回目で確認する。

### 実装側に見つかった改善点 — 存在しない ref のエラーが読み取れない

M6 の tmpfs ケースで観測:

```
fatal: git checkout: --detach does not take a path argument 'v9.9.9'
```

fail-closed ではあるので安全側だが、**「その ref は存在しない」ではなく「パス引数は取れない」**
と言う。git が ref 解決に失敗した結果、引数をパス名と解釈しているため。運用でこれを踏んだ人間は
原因に辿り着けない。I6（前提の欠落が読み取れる失敗になること）の趣旨に反する。

`fetch` の後・`checkout` の前に `git rev-parse --verify --quiet "${GIT_REF}^{commit}"` を入れ、
解決できなければ明示的なメッセージで落とすようにした（回帰テスト追加済み）。
`GIT_REF` は秘匿情報ではないのでメッセージに含めてよい。設計書 §4.6 へ rev.5 で反映する。

---

## 1. 自動テストで恒常的に確認しているもの

`pnpm test` が回帰として毎回検証する。テストは docker 不要で、shim / entrypoint を一時
ディレクトリへ複製しパスを書き換えて実行する方式（実体はフェイクに差し替え）。

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 1 | 空値 secret（`KEY=""`）で entrypoint が非ゼロ終了 | ✅ | `tests/entrypoint.test.sh` |
| 2 | stdin 空でも非ゼロ終了 | ✅ | 同上 |
| 3 | 値に `=` を含む行が壊れない | ✅ | 同上（`postgres://u:p@h/db?a=b`） |
| 4 | CRLF 行で値末尾に `\r` が残らない | ✅ | 同上 |
| 5 | `=` 無し行 / 不正な鍵名で非ゼロ終了 | ✅ | 同上 |
| 6 | 生成された secret ファイルが mode 600 | ✅ | 同上 |
| 7 | clone 後に `/run/secrets/GH_TOKEN` が削除されている | ✅ | 同上 |
| 8 | 引数なし呼び出しで非ゼロ終了 | ✅ | 同上 |
| 9 | `/src` 非空・`.git` 無し（前回失敗の残骸）から復帰できる | ✅ | 同上 |
| 10 | named volume 再利用時に tracked file の改変が復元される | ✅ | 同上（rev.4 で追加。`reset --hard` の回帰） |
| 11 | パース失敗メッセージに入力行・鍵名が出ない | ✅ | 同上（rev.4 で追加） |
| 12 | shim: secret 存在時に注入される | ✅ | `tests/shim.test.sh` |
| 13 | shim: 空ファイルで非ゼロ終了 | ✅ | 同上 |
| 14 | shim: 不在時に素通しし、呼び出し元の環境変数を引き継ぐ | ✅ | 同上 |
| 15 | shim: 存在・非空だが読めない（mode 000）で非ゼロ終了 | ✅ | 同上（rev.4 で追加。root 実行時は skip） |
| 16 | shim: `NODE_OPTIONS` が両分岐で除去される | ✅ | 同上 |
| 17 | dotenvx shim: `DOTENV_PRIVATE_KEY_*` 複数注入で全て export される | ✅ | 同上（`_LOCAL` + `_DEVELOPMENT` 同居） |
| 18 | 起動ラッパー: broker 失敗 + docker 成功でパイプ全体が非ゼロ終了（`pipefail`） | ✅ | `templates/tests/prod-run.test.sh` |
| 19 | 起動ラッパー: docker 先行失敗 + broker SIGPIPE(141) で docker を原因として報告 | ✅ | 同上（rev.4 で追加） |
| 20 | 起動ラッパー: 必須環境変数の欠落を名指しで報告し非ゼロ終了 | ✅ | 同上 |
| 21 | 起動ラッパー: 非 40 桁 `GIT_REF` で警告を出しつつ続行 | ✅ | 同上 |
| 22 | 起動ラッパー: `-T` と引数が docker へ正しく渡り、stdin が素通しされる | ✅ | 同上 |

---

## 2. ビルド時 / CI で確認するもの

**2026-08-06 更新（rev.7）。** CI は 10 回イメージをビルドしており、「ビルド未実行」は
もはや事実ではない。§0 の実測と食い違ったままだった表を実態に合わせる。

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 23 | PATH 解決が shim に当たる（`/usr/local/bin/<name>`） | ✅ | Dockerfile の `command -v` 検証がビルドを通っており、さらに CI で **A1** が push 前のイメージに対して直接確認している |
| 24 | `core.hooksPath` が `/usr/local/share/git-hooks` に設定されている | ✅ | **A3**（`git config --system --get`）。あわせて **M6** で「repo の `.git/config` から上書きできる」ことも実測した（§0.5） |
| 25 | 両アーキ（amd64 / arm64）で起動する | ✅ | **2026-08-06、`runtime-base-v1.0.0` をリリースした**（下記 §0.13）。`linux/amd64,linux/arm64` のマルチアーキビルドが通り、GHCR へ push された |

---

## 3. 実機（docker のあるホスト）で確認が要るもの

**2026-08-06 更新（rev.7）。** この表は「全て未実施」の見出しのまま §0 の実測結果と
矛盾していた。設計書 §10 が「消化状況はこの記録を正とする」と宣言している以上、
表だけを読んだ読者が「一度も docker で検証されていない」と結論する状態は放置できない。

凡例: ✅ CI で消化済み（根拠の A/B/M は `tests/verify-docker.sh` のケース ID）/
⬜ 未実施・実施可能 / ⛔ この環境では実施不能（macOS ホスト等が要る）

### secret 搬送路

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 26 | entrypoint 実行後、`/run/secrets/<VAR>` が mode 600 で tmpfs 上にある | ✅ | **A5**（docker run 経由）+ **B1**（出荷 compose 由来） |
| 27 | `docker inspect` の `Config.Env` / `Mounts` に secret が一切現れない | ✅ | **A6** |
| 28 | broker 出力の形式（quoting / 改行）と entrypoint パーサの整合 | ⛔ | パーサ側は自動テスト 3〜5 と **A7 / A8 / A9** で消化済み。残るのは**実 broker（macOS `security`）の出力**との突き合わせで、これはホストが要る |
| 29 | broker が非対話環境で非ゼロ終了し、`pipefail` 下でパイプ全体が止まる | ⛔ | フェイク broker での `pipefail` 伝播は **A17** と自動テスト 18〜19 で消化済み。実 broker の非対話時の挙動はホストが要る |
| 30 | macOS `security` の ACL 設定（毎回確認 / Touch ID / 常時許可）ごとの挙動 | ⛔ | |
| 31 | 必要 secret を欠いた状態で下流コマンドが認証失敗として顕在化する | ⛔ | `$HOME` tmpfs により fallback 資格情報が存在しないことは **A18** で消化済み。「実際の認証失敗として現れる」ことの確認には実トークンと実サービスが要る |

### compose の実挙動

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 32 | `tmpfs: - /run:uid=...` の記法で node 所有の tmpfs が作られる | ✅ | §0 / §0.4（`docker run` と `docker compose` の双方で一致）+ **A31** / **B4** |
| 33 | `read_only: true` + tmpfs 構成で `git fetch` / `pnpm install` / ビルドが完走する | ✅ | §0.68 の **M9-e**。`exec` の明示が必須であることも同時に確定。2026-08-06 に判定材料を差し替えて再測定し `M9_E_EXEC=YES`（同節） |
| 34 | `GIT_REF` 未指定時に compose が失敗する | ✅ | **A11**（`compose run`）+ **A32 / A33**（`compose config`） |
| 35 | `logging: driver: none` でもアタッチ時に stdout が手元に表示される | ✅ | **A12** |
| 36 | ホストの `core_pattern` の内容と、`ulimits: core: 0` 下でコアが生成されないこと | ⛔ | `ulimit -c` が 0 を返すことは **A13** / **B5** で消化済み（`docker compose config` は値 0 を落とすため挙動でしか見られない。§0.71）。**ホストの `/proc/sys/kernel/core_pattern` の実際の内容**はホストでの確認が要る |
| 37 | 対話二段構え（`run -dT --rm` + `docker exec -it`）で TTY シェルが得られること | ⬜ | 未実施。設計書 §11 の「対話 prod shell の要否」が未決のため後回しにしている |
| 38 | `dotenvx get -f .env.prod` がファイルを生成しない | ✅ | **M3**（`ls -la` 前後で差分なし。§0） |
| 39 | ~~`git clean -xdff` と `node_modules` 保持のトレードオフ~~ | — | **消滅**。`/src` が tmpfs である以上、run をまたいだ `node_modules` の保持は元から成立しない（D18） |

### dotenvx 2.x への引き上げに伴う前提

runtime-base は dotenvx **2.19.2** を焼く（既存 4 repo は enclave-env の peer range `^1.63.0`
下で運用）。2.0.0 は keyring 対応の導入にあわせて `run` / `config` / `get` を
`@dotenvx/primitives` 由来の共有 resolver 経由へ付け替えている。**40 / 41 が落ちれば
1.75.1 へ戻す**という条件付きの前提だったが、どちらも通ったので 2.19.2 のまま進む。

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 40 | dotenvx 2.x で `DOTENV_PRIVATE_KEY_*` の環境変数注入が従来通り効く | ✅ | **M3**（§0。`get` / `run` の双方、shim 経由・複数鍵同居・`-f` による鍵選択を含む） |
| 41 | dotenvx 1.x で暗号化した `.env.*` を 2.x が復号できる | ✅ | **M4**（§0。1.75.1 で暗号化した `.env.legacy` を 2.19.2 が復号） |
| 41b | `pnpm run` の内側でローカル依存の dotenvx が呼ばれた場合に鍵が届く | ✅ | **M5**（§0）。**届かない**ことが確定し、最上位に `dotenvx run` を置く運用で回避する。設計書 D5 の「全経路で効く」は rev.5 で訂正済み |

### コミット前検査

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 42 | `core.hooksPath` 設定下で平文 `.env` のコミットが実際に拒否される | ✅ | **A14** |
| 43 | husky を使うプロジェクトでチェーン先の hook が引き続き実行される | ✅ | **A15** |
| 44 | prod container 内でも hook が有効である | ✅ | **A3 / A4 / A14 / A15** はいずれも runtime-base イメージ内で実行している |
| 45 | ホストの GUI クライアント（Fork）から平文 `.env` の commit が拒否される | ⛔ | 現行の simple-git-hooks 構成で今どうなっているかの確認を含む |
| 46 | `node_modules` が named volume か bind mount か | ⛔ | ホスト側 hook のパス解決に影響する |
| 47 | ホスト側 hook が依存バイナリを解決できない場合に非ゼロ終了する | ⛔ | |
| 48 | CI（クリーン checkout・差分ゼロ）で `dotenvx precommit` が検出能力を持つか | ✅ | **持たない**ことが確定（下記 §0.8）。設計書は当初案を破棄し、tracked ファイルの直接走査へ差し替えた（D23） |
| 49 | 他 org の private リポジトリから karakuri の reusable workflow が呼び出せる | ⛔ | 他 org の repo が要る。呼び出し側 org の Actions ポリシーが「選択した actions / reusable workflows のみ許可」の場合に allowlist 追加が要ることは文書化済み（プラン制限ではなく設定項目）。**2026-08-06 以降、これは配布方式を決めるための前提条件ではなくなった** — 項目 63 のとおり、workflow が自分の ref を知る必要が無くなったため。実際に届くかの確認としては残る |

### rev.7 で追加した項目

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 51 | `/src` が tmpfs でない構成（named volume へ戻す一行）で entrypoint が明示的に落ちる | ✅ | **A35**（CI 11 回目で通過）。secret の置き場側は **A36**（測定から昇格。`read_only` との併用が受理され uid 1000 も書けるため、自己検査まで到達して止まることを実測）。§0.10 / §0.12 参照 |
| 52 | `/proc/mounts` に該当行が無い場合に WARNING を出して続行する | ✅ | `tests/entrypoint.test.sh`（テスト環境そのものがこの経路） |
| 53 | 40 桁 hex を名前とする ref（オブジェクト不在）で非ゼロ終了し記録が残らない | ✅ | `tests/entrypoint.test.sh`。**現行 git ではそもそも成立しない**（下記 §0.9） |
| 54 | 大文字の完全 commit sha が誤って拒否されない | ✅ | `tests/entrypoint.test.sh` |
| 55 | `GIT_REPO` の資格情報埋め込みを拒否し、stderr にトークンが出ない | ✅ | `tests/entrypoint.test.sh`（ssh 形式を誤検知しないことも含む） |
| 56 | dotenvx shim が prod 鍵注入時の `--strict` 欠落だけを警告する | ✅ | `tests/shim.test.sh`（警告の有無で引数と rc が変わらないことを含む） |
| 57 | prod-context が空の `/run/secrets` で zsh でも完走する | ✅ | `tests/prod-context.test.sh`（zsh 実行込み。旧実装が実際に落ちることも確認済み） |
| 58 | pre-commit hook がサブディレクトリの `.env.keys` を検出する | ✅ | `tests/hook.test.sh`（`node_modules` 除外、`find` 自体の失敗時の fail-closed を含む） |
| 59 | env-guard が平文の tracked `.env` を実際に検出する | ✅ | `tests/env-guard.test.sh`。**GitHub Actions 上でも実行した**（2026-08-06、`ci` の env-guard job が緑。呼び出し側の作業ツリーのスキャナを使う経路）。下記 §0.11 の否定対照を参照 |
| 60 | hook と CI が同一 fixture に対して同一の判定を返す | ✅ | `tests/env-guard.test.sh`（終了コードだけでなく**出力がバイト単位で同一**であることまで見る）。D24 の本題 |
| 61 | `env-guard.conf` による上書きが hook と CI の両方に効く | ✅ | 同上（`pattern` / `allow` の双方） |
| 62 | 設定ファイルが `source` / `eval` されない | ✅ | スキャナは行単位のパースのみで、値をパターン文字列としてしか使わない |
| 63 | CI が使うスキャナが reusable workflow と同じ版である | ✅ | **問いの立て方を変えて解いた**（2026-08-06）。`github.job_workflow_ref` は実測で空であり（§0.12）、そこから karakuri の ref を割り出す方式は成立しなかった。スキャナを npm パッケージにしたことで、**版を workflow ファイル自身に書ける**ようになり、自分の ref を知る必要が消えた。取得物は SHA256 で照合してから実行する（版の固定だけでは改竄に対して無力。`npm pack` は取得物を検証しない）。karakuri 自身は npm 経由にせず作業ツリーのスキャナを使う — そうしないと、スキャナを変更する PR が変更前の公開済みスキャナで検査される |
| 65 | イメージが named build context 経由でスキャナと hook を焼き込める | ✅ | 2026-08-06、`runtime-base` と `runtime-base-verify` の**両方**のビルドが通った。`build-contexts: env-guard=packages/env-guard` + `COPY --from=env-guard`。ビルドコンテキストは `images/runtime-base` のまま広げていない。**片方の workflow にだけ足すともう片方が `COPY` で落ちる**ので、両方で通ったことに意味がある |
| 66 | npm から取得したスキャナの SHA256 照合が改竄を検知する | ⬜ | GitHub Actions 上では未実施（他リポジトリから呼ばれるまで走らない）。**照合ロジック自体は手元で否定対照を取ってある** — 正しいハッシュで通り、期待値を 1 文字変えると非ゼロ、取得物を 1 バイト書き換えても非ゼロ。いずれの失敗でも実行可能なファイルが残らない（照合前に `chmod +x` へ到達しない） |
| 64 | 検出時の出力に平文の値が含まれない | ✅ | `tests/env-guard.test.sh`（`=` を含まない行では鍵名すら出さない経路を含む） |

---

### 0.13 runtime-base 1.0.0 のリリース（2026-08-06）

初回リリース。`runtime-base-v1.0.0` タグの push でマルチアーキビルドが走り、GHCR へ入った。

```
ghcr.io/himorogy/runtime-base:1
sha256:33da300c1fb83499debf2af0d805674cd4fd69fee041be7d917d53a0a5db5651
platforms: linux/amd64, linux/arm64
```

- **両アーキのビルドが通った**（項目 25）。`runtime-base-verify` は amd64 の単一アーキ
  ローカルビルドしか行わないので、arm64 はここが初めての実証になる
- **パッケージは private で作られたため、Public へ切り替えた。** これを飛ばすと
  devcontainer-base のビルドは匿名 pull を拒否され、**「まだ push していない」ときと同じ
  403 で落ち続ける**。タグを打てば通る、ではない
- 切り替え後、**devcontainer-base のビルドが緑になった**。このジョブが成功したのは初めてである
  （それまで赤かった理由は GHCR ではなく `ARG RUNTIME_BASE_VERSION` のスコープ違反だった。
  下記）

#### 「赤いのは想定どおり」が実バグを隠していた

devcontainer-base のビルドは長く赤く、workflow のコメントにも移行ガイドにも
「runtime-base をまだ GHCR に push していないので `FROM` が解決できない」と書かれていた。
**実際の失敗は別だった。**

```
UndefinedArgInFrom: FROM argument 'RUNTIME_BASE_VERSION' is not declared
failed to parse stage name "ghcr.io/himorogy/runtime-base:": invalid reference format
```

`ARG RUNTIME_BASE_VERSION=1` が `crit-builder` ステージの中で宣言されていた。`FROM` で参照する
`ARG` は最初の `FROM` より前（グローバルスコープ）になければならず、ステージ内のものは次の
`FROM` からは見えない。空文字に展開され、レジストリに問い合わせる前に落ちていた。

**このビルドは一度も成功したことがないまま、タグ待ちとして扱われていた。** 但し書きが理由を
説明済みにしてしまい、誰もエラー本文を読まなかった。

対処として、期待するエラーの実物を workflow のコメントに書いた。「赤いのは想定どおり」を
確かめられる主張にするためである。

#### digest はテンプレートに焼かない

`templates/compose.prod.yaml` の `image:` はプレースホルダのままにしてある。差し替えは運用者が
自分の `~/.config/<project>/compose.prod.yaml` で行う。テンプレートに実 digest を書くと、
(a) 差し替え忘れが起動失敗として現れる設計が消え、(b) リリースのたびに古い digest がテンプレート
に残り、後からコピーした人が黙って古いイメージを pin することになる。

digest は次で取れる。

```sh
docker buildx imagetools inspect ghcr.io/himorogy/runtime-base:1 --format '{{.Manifest.Digest}}'
```

## 4. 恒常チェック

| # | 項目 | 状態 | 結果 |
|---|---|---|---|
| 50 | dev container に `/var/run/docker.sock` がマウントされていない | ✅ | `.devcontainer/` に socket mount / docker-in-docker / docker-outside-of-docker の参照なし。`/var/run/docker.sock` 不在。`docker` CLI 不在 |

**devcontainer 構成を変更するたびに再確認すること。** この前提が崩れると、dev container から
prod container への `docker exec` や任意 volume の mount が可能になり、本設計の分離全体が
無効化される。

---

## 5. 次にやること

1. **ホストで docker の空き容量を確保する。** 検証を始めた時点で dev container が載っている
   overlay は 95G 中 90G 使用（残り 15MB）で、イメージのビルドすらできない状態だった。
   ホスト側で `docker system prune` 等の整理が要る。
2. ~~runtime-base を一度 GHCR へ push する~~ → **2026-08-06 に完了**（§0.13）。
3. docker のあるホストで項目 26〜47 を消化する。**32 と 40 を先に見ること** — どちらも
   落ちれば設計の作り直しが要る箇所で、他の項目はその後でよい。
4. 項目 48 / 49 は設計書 §9 の手順 4（reusable workflow の設置）の範囲。本セッションの
   スコープ外。
