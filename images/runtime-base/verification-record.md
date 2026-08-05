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

対処の候補は測定項目 M8 で測る（`dotenvx run --strict` の有無、鍵なし `get` の rc、注入値の
`encrypted:` 接頭辞による呼び出し側での検出）。設計は測定結果を見てから決め、rev.5 に入れる。

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
