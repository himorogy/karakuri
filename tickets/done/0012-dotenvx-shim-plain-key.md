---
status: close
type: fix
base: main
targets:
  - images/runtime-base/shims/dotenvx
  - images/runtime-base/tests/shim.test.sh
  - images/runtime-base/README.md
  - images/runtime-base/Dockerfile
  - docs/prod-secret-isolation-design.md
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# dotenvx shim がサフィックスの無い `DOTENV_PRIVATE_KEY` を取り込めるようにする

## 内容

`images/runtime-base/shims/dotenvx` の鍵取り込みループは
`for f in /run/secrets/DOTENV_PRIVATE_KEY_*` という glob を使っている。この glob は末尾に
1 文字以上を要求するため、サフィックスの無い `/run/secrets/DOTENV_PRIVATE_KEY` に
マッチしない。

dotenvx の命名規約では、素の `.env` に対応する秘密鍵の変数名はサフィックスの無い
`DOTENV_PRIVATE_KEY` である（`.env.production` → `DOTENV_PRIVATE_KEY_PRODUCTION`、
`.env` → `DOTENV_PRIVATE_KEY`）。そのため素の `.env` を使うプロジェクトでは、
`/run/secrets/DOTENV_PRIVATE_KEY` を正しく注入しても shim が素通りし、dotenvx が
`.env.keys` へフォールバックする。`env-guard` は `.env.keys` の存在を無条件で拒否するため、
「注入は効いているのに commit できない」という状態になる。注入側にこの名前を拒む制約は無く
（`images/runtime-base/bin/secrets-ingest.sh` の鍵名検査は `[A-Za-z_][A-Za-z0-9_]*` のみ）、
実在する経路で再現する。

`docs/prod-secret-isolation-design.md` を調べたところ、サフィックスの無い
`DOTENV_PRIVATE_KEY` への言及はファイル全体で一度も無く、「素の `.env` を使わせない」
という規約も書かれていない。§4.3 のサンプルコードは shim と同じ glob を持つだけで、
サフィックスを必須とする意味論的な根拠は示されていない。よってこれは意図的な制限では
なく見落としと判断し、glob を広げる方向で直す。

### やること

1. **glob を `DOTENV_PRIVATE_KEY*` に広げる。** 既存の `_PROD` / `_DEVELOPMENT` / `_LOCAL`
   は上位集合として引き続きマッチする。新たに拾うのは
   `/run/secrets/DOTENV_PRIVATE_KEY` ちょうど 1 件だけである
2. **三値の判定はループ内でファイル 1 本ごとに効く構造を変えない。** 対象集合が 1 件増える
   だけで、存在→注入 / 空→エラー / 不在→素通し の意味論は不変であること。空を不在と同じ
   扱いにしないのは、不在が「その鍵は要らない」の表明であるのに対し、空は「要るはずのものが
   届いていない」の表明だからである。空のまま実体を呼ぶと、dotenvx は復号に失敗しても
   rc=0 で暗号文を値として注入するため（実測済み）、秘密の欠落が沈黙した成功になる
3. **`--strict` 警告の prod 鍵判定（`DOTENV_PRIVATE_KEY_PROD*` の glob）は変更しない。**
   ここは接頭辞で意図的に絞っており、広げると `_LOCAL` などで誤発火する。結果として
   サフィックスの無い鍵は prod 鍵とみなされず警告の対象にならないが、素の `.env` は
   dev 用という前提と整合するので、これでよい
4. **ファイル冒頭のコメントを書き直す。** 現在の「鍵変数名は環境ごとに異なり
   (`_PROD` / `_DEVELOPMENT` / `_LOCAL`)」という説明はサフィックスがあることを前提に
   している。素の `.env` に対応する `DOTENV_PRIVATE_KEY` を含む形に直す
5. **`images/runtime-base/tests/shim.test.sh` にテストを足す。** 下記「保証」の各行に対応する
   ケースを追加する。既存のテストと同じ流儀で書く（`make_shim()` が `sed` で
   `/run/secrets` を tmpdir へ置換する方式、`ok` / `ng` 関数）。加えて否定対照を 1 本置く
   ——サフィックスの無い鍵だけが注入された状態で `run` を `--strict` 無しで呼んでも
   prod 鍵の警告は出ないこと。これは prod 判定を広げていないことの裏取りであって約束では
   ないので、下記「保証」には載せない。`_dotenvx` の呼び名についてはテストを足さない。
   呼び名の分岐（`case "${0##*/}"`）は実体の解決先を切り替えるだけで鍵取り込みループより
   前段にあり、glob の変更と直交する。既存の `_dotenvx` / `_wrangler` のケースが呼び名の
   分岐と三値意味論の維持を既に押さえている
6. **`images/runtime-base/README.md` の `## shim の仕組み` 節に、dotenvx の鍵ファイル名の
   対応を明記する。** 素の `.env` を使うプロジェクトの鍵ファイルが
   `/run/secrets/DOTENV_PRIVATE_KEY` であること、`.env.<環境名>` ならサフィックス付きに
   なること
7. **同じ README の既存の乖離を直す。** `### ただし黙ってはいない — shim が警告する` の
   条件が `/run/secrets/DOTENV_PRIVATE_KEY_PROD` という固定名で書かれているが、実装と
   設計書は既に `DOTENV_PRIVATE_KEY_PROD*` の glob である。実装に合わせる
8. **`docs/prod-secret-isolation-design.md` §4.3 を実装に追随させる。** サンプルコードの
   glob を直し、サフィックスの無い鍵が対象に含まれることを本文に書く
9. **`images/runtime-base/Dockerfile` のコメントの旧 glob 表記を直す。** 「shim で
   `DOTENV_PRIVATE_KEY_*` を環境変数として注入する経路に依存しており」が拡大前の表記で
   残っている。コメントのみの修正でイメージのビルド結果は変わらない（レビューで発見し、
   軽量裁可を経て targets に追加した）

### やらないこと

- `shims/gh` と `shims/wrangler` の変更。この 2 本は glob ではなく固定 1 ファイル
  （`/run/secrets/GH_TOKEN`、`/run/secrets/CLOUDFLARE_API_TOKEN`）を見ており、同種の
  取りこぼしは無い
- 注入側（`secrets-ingest.sh` / `templates/host/dev-inject.sh` / broker）の変更。
  サフィックスの無い名前は現状のまま注入できる
- `--strict` 警告の判定条件の変更（上記 3 のとおり）
- 保証台帳への行の追加。台帳 `docs/guarantees.md` に shim の節はまだ無く、起票済みの
  0008 が `§8` として載せる。サフィックスの無い鍵が対象に含まれることは
  0008 の該当行へ 1 句足す形で着地させる（このチケットの範囲外）

## 保証

### 新たに宣言する保証

- なし。台帳 `docs/guarantees.md` に shim の節がまだ無いため、載せる先が存在しない。
  shim の振る舞いは敷設中の束の 0008 が `§8` として載せる予定であり、その該当行
  「一致する鍵ファイルを全て同時に export する。一致が 0 件なら素通し、一致した中に
  1 つでも空ファイルがあれば非ゼロ終了する」は glob の具体形を含まないため、この変更の
  後も文言として成立する。サフィックスの無い鍵が「一致する鍵ファイル」に含まれることの
  明示は 0008 側で行う

このチケットで固定する振る舞いは、下記のテストとして `shim.test.sh` に置く。サフィックスの
有無で振る舞いは変わらないため、宣言も分けない。

- `/run/secrets/DOTENV_PRIVATE_KEY*` に一致する鍵ファイルが非空で存在するとき、ファイル名と
  同名の環境変数がその値で実体プロセスの環境に入る。一致が複数あれば全て同時に export される
  （テストケース: サフィックス無し単独 / サフィックス有り単独（回帰）/ 両者の混在）
- 一致する鍵ファイルが 1 件も無いとき、非ゼロ終了せず素通しで実体が呼ばれる
- 一致した鍵ファイルのうち 1 つでも中身が空のとき、非ゼロ終了し、空である旨と当該パスを
  stderr に出す。実体は呼ばれない。ここで言う空は `/run/secrets` 側の鍵ファイル、つまり
  注入された秘密鍵そのものが空である場合を指す（`.env` の中身とは無関係）
  （テストケース: 無サフィックスの空ファイル単独 / 非空と空の混在）

### 維持する保証

台帳に shim の節が無いため、指差し確認の対象は既存テストが固定している振る舞いになる。
今回の変更で壊れうるのは次の 2 つで、いずれも `shim.test.sh` の既存ケースが押さえている。

- shim の三値意味論（存在→注入 / 空→エラー / 不在→素通し、環境の判別はしない）。
  対象集合が 1 件増えるだけで、判定の構造は変えない
- `--strict` 警告の発火条件（`run` があり `--strict` が無く prod 鍵が観測されるとき）と、
  警告が引数列・終了コードを一切変えないこと

### 廃止する保証

- なし。取りこぼしていた鍵名を対象に含める変更であり、既存の約束を取り下げるものではない。
  glob の拡大は上位集合への拡大なので、これまで export されていた鍵が export されなく
  なることもない
