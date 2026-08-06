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

| # | 項目 | 状態 | 根拠 |
|---|---|---|---|
| 23 | PATH 解決が shim に当たる（`/usr/local/bin/<name>`） | ⬜ | Dockerfile に `command -v` 検証を焼き込み済み。**ビルド未実行** |
| 24 | `core.hooksPath` が `/usr/local/share/git-hooks` に設定されている | ⬜ | CI smoke test に登録。**ビルド未実行** |
| 25 | 両アーキ（amd64 / arm64）で起動する | ⬜ | CI smoke test に登録。**ビルド未実行** |

イメージを一度も GHCR へ push していないため 23〜25 は未実施。最初のタグ push
（`runtime-base-v1.0.0`）で確認できる。

---

## 3. 実機（docker のあるホスト）で確認が要るもの — **全て未実施**

⛔ は dev container 内で原理的に実施できない項目。ホスト側で実施すること。

### secret 搬送路

| # | 項目 | 状態 |
|---|---|---|
| 26 | entrypoint 実行後、`/run/secrets/<VAR>` が mode 600 で tmpfs 上にある（`mount \| grep /run`） | ⛔ |
| 27 | `docker inspect` の `Config.Env` / `Mounts` に secret が一切現れない | ⛔ |
| 28 | broker 出力の形式（quoting / 改行）と entrypoint パーサの整合 | ⛔ |
| 29 | broker が非対話環境で非ゼロ終了し、`pipefail` 下でパイプ全体が止まる | ⛔ |
| 30 | macOS `security` の ACL 設定（毎回確認 / Touch ID / 常時許可）ごとの挙動 | ⛔ |
| 31 | 必要 secret を欠いた状態で下流コマンドが認証失敗として顕在化する（`$HOME` tmpfs により fallback 資格情報が拾われないことを含む） | ⛔ |

### compose の実挙動

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 32 | `tmpfs: - /run:uid=1000,gid=1000,mode=0755` の記法で実際に node 所有の tmpfs が作られる | ⛔ | **最優先。効かなければ起動直後に落ちる**（`USER node` が `/run/secrets` を作れない） |
| 33 | `read_only: true` + tmpfs 構成で `git fetch` / `pnpm install` / ビルドが完走する | ⛔ | `/home/node` の書き込み先、named volume `/src` の所有権を含む |
| 34 | `GIT_REF` 未指定時に compose が失敗する | ⛔ | |
| 35 | `logging: driver: none` でもアタッチ時に stdout が手元に表示される | ⛔ | |
| 36 | ホストの `/proc/sys/kernel/core_pattern` の内容と、`ulimits: core: 0` 下でコアが生成されないこと | ⛔ | |
| 37 | 対話二段構え（`run -dT --rm` + `docker exec -it`）で TTY シェルが得られ `/run/secrets` が注入済み。退出 + `docker stop` で消えること | ⛔ | |
| 38 | `dotenvx get -f .env.prod` がファイルを生成しない | ⛔ | |
| 39 | `git clean -xdff` と `node_modules` 保持のトレードオフ（`-e node_modules` 除外の可否） | ⛔ | 設計書 §11 の未決事項 |

### dotenvx 2.x への引き上げに伴う未検証の前提

runtime-base は dotenvx **2.19.2** を焼く（既存 4 repo は enclave-env の peer range `^1.63.0`
下で運用）。2.0.0 は keyring 対応の導入にあわせて `run` / `config` / `get` を
`@dotenvx/primitives` 由来の共有 resolver 経由へ付け替えている。

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 40 | dotenvx 2.x で `DOTENV_PRIVATE_KEY_*` の環境変数注入が従来通り効く | ⛔ | **本設計の shim はこの経路に全面的に依存する。落ちると shim 機構そのものが機能しない** |
| 41 | dotenvx 1.x で暗号化した `.env.*` を 2.x が復号できる | ⛔ | 既存 4 repo の移行可否に直結 |
| 41b | `pnpm run` の内側でローカル依存の dotenvx が呼ばれた場合に鍵が届く | ⛔ | `pnpm run` は `node_modules/.bin` を PATH 先頭に積むため shim が素通りされる。最上位に `dotenvx run -f ... -- pnpm ...` を置く運用で回避する（README / migration に反映済み）。**設計書 §4.3 / D5 の「全経路で効く」は誤りで rev.5 で訂正する** |

2.0.0 の BREAKING は全て `lib/main` のライブラリ API（`set` / `get` の async 化、
`doctor` / `keypair` / `genexample` の export 削除、`rotate` コマンドの削除）であり、
CLI の `run` / `get` / `set` / `encrypt` / `decrypt` / `precommit` は存続していることは
CHANGELOG で確認済み。40 / 41 が落ちた場合は 1.75.1 へ戻す。

### コミット前検査

| # | 項目 | 状態 | 備考 |
|---|---|---|---|
| 42 | `core.hooksPath` 設定下で平文 `.env` のコミットが実際に拒否される | ⛔ | |
| 43 | husky を使うプロジェクトでチェーン先の hook が引き続き実行される | ⛔ | |
| 44 | prod container 内でも hook が有効である | ⛔ | |
| 45 | ホストの GUI クライアント（Fork）から平文 `.env` の commit が拒否される | ⛔ | 現行の simple-git-hooks 構成で今どうなっているかの確認を含む |
| 46 | `node_modules` が named volume か bind mount か | ⛔ | ホスト側 hook のパス解決に影響する |
| 47 | ホスト側 hook が依存バイナリを解決できない場合に非ゼロ終了する（沈黙して通過しない） | ⛔ | |
| 48 | CI（クリーン checkout・差分ゼロ）で `dotenvx precommit` が実際に検出能力を持つか | ⬜ | no-op なら設計書 §8.2 の fallback へ差し替え。**§9 手順 4 の範囲** |
| 49 | 他 org の private リポジトリから karakuri の reusable workflow が呼び出せる | ⬜ | **§9 手順 4 の範囲** |

---

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
2. runtime-base を一度 GHCR へ push する（項目 23〜25 が消化される）。
3. docker のあるホストで項目 26〜47 を消化する。**32 と 40 を先に見ること** — どちらも
   落ちれば設計の作り直しが要る箇所で、他の項目はその後でよい。
4. 項目 48 / 49 は設計書 §9 の手順 4（reusable workflow の設置）の範囲。本セッションの
   スコープ外。
