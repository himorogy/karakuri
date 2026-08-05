# 既存プロジェクトの移行ガイド

`prod-shell.sh`（`docker run` + `--env-file` + workspace bind mount + dev/prod 相互排他チェック）
で運用しているプロジェクトを、runtime-base + `compose.prod.yaml` の構成へ移す手順。

対象は既存の 4 リポジトリ（Radwisp / acregis / biotechgrid / gachapin）。

**分けて進められる。** 1〜2 は prod の運用を変えずに単独で実施でき、3 以降とは独立している。
まとめてやると失敗したときにどこが原因か切り分けられなくなる。

---

## 前提

1. **runtime-base が GHCR に存在すること。** 未リリースなら先に
   `git tag runtime-base-v1.0.0 && git push origin runtime-base-v1.0.0` を実行する。
   リリース順は runtime-base → devcontainer-base。
2. **ホストの docker に空き容量があること。** マルチアーキイメージの pull と named volume の
   確保が要る。
3. **ディスク暗号化（FileVault / BitLocker）が有効であること。** 本設計の最後の砦であり、
   前提条件として扱う。

---

## 1. `dotenvx run --` に統一する

最小の変更で、prod 由来の平文が workspace 経由で dev に逐次流入する経路の大半が落ちる。

`package.json` から `decrypt-env` 系のスクリプトを外し、アプリの実行系を `dotenvx run --` で
くるむ。

```diff
   "scripts": {
-    "decrypt-env":      "enclave-env decrypt --env local",
-    "decrypt-env:prod": "enclave-env decrypt --env prod",
+    "dev":              "dotenvx run -f .env -- vite",
+    "deploy":           "dotenvx run -f .env.production -- wrangler deploy",
     "encrypt-env":      "enclave-env encrypt --env local",
     "encrypt-env:prod": "enclave-env encrypt --env prod",
   },
```

`decrypt` を禁止はしない。ファイルとしての平文を要求する外部ツールに食わせる用途は残る。
package.json に置かないのは、置くと in-place 復号が一手で呼べる既定の操作になり、平文ファイルが
日常的に生まれるため。

値の確認は `dotenvx get -f .env.production` で、ファイルを作らずに行える。

**この段階で既に平文の `.env*` がディスクに残っていないか確認すること。** 過去の
`decrypt-env` 運用で残置している可能性がある。

```sh
git status --porcelain --ignored | grep -E '\.env'
```

---

## 2. devcontainer を新しい base へ載せ替える

`.devcontainer/Dockerfile` の `FROM` を `ghcr.io/himorogy/devcontainer-base:1` に向ける。
devcontainer-base は runtime-base を継承しているので、この時点で shim・git hook・
`prod-entrypoint.sh` が dev container にも入る。

pnpm 10 → 11 の移行を同時に踏む場合は
[`images/devcontainer-base/migration.md`](../devcontainer-base/migration.md) を参照。

### 確認すること

- **shim が既存の dev 向けトークン注入と共存すること。** shim は「`/run/secrets/<VAR>` が
  存在しなければ素通し」なので、`containerEnv` や `.env.container` による既存の env var 注入は
  そのまま効く。`gh auth status` と `wrangler whoami` が通ることを確認する。
- **`core.hooksPath` が per-repo の hook を壊していないこと。** husky / lefthook を使っている
  なら、`.husky/pre-commit` / `.githooks/pre-commit` へチェーンされる。それ以外の場所に
  hook を置いているプロジェクトは、チェーン先に追加するか hook 側を移動する。
- **`.git/hooks/pre-commit` を掃除すること。** `core.hooksPath` を設定すると
  `.git/hooks/*` は完全に無視される。`dotenvx precommit --install` や simple-git-hooks が
  過去に書き込んだものが死んだまま残るので、「入っているつもりで効いていない」状態を避けるため
  削除する。

  ```sh
  rm -f .git/hooks/pre-commit
  ```

  ただし **ホスト側からコミットする運用がある場合は消してはいけない。** `core.hooksPath` は
  コンテナ内の `/etc/gitconfig` に書かれるので、ホストの git はこれを読まない。ホストの GUI
  クライアント（Fork 等）は従来通り `.git/hooks/pre-commit` を参照する。消すとホスト側だけが
  無防備になる。

---

## 3. 鍵束を OS キーチェーンへ移す

ここから prod 側の変更になる。

現行の `~/.config/<project>/.env.container`（恒久平文ファイル）を廃止し、中身を OS キーチェーンに
移す。

```sh
# 中身を確認して控えておく（dotenv 形式のテキスト全文）
cat ~/.config/<project>/.env.container

# 1 項目として Keychain に登録する。-w を付けると値の入力が対話プロンプトになり、
# シェル履歴に平文が残らない
security add-generic-password -s "<project>-prod-env" -a "$(whoami)" -w

# 登録できたことを確認してから、平文ファイルを消す
security find-generic-password -s "<project>-prod-env" -w
rm ~/.config/<project>/.env.container
```

登録後、Keychain Access.app でこの項目を開き「アクセス制御」タブから ACL を選ぶ。
**「常に許可」は避けること** — 同一ホストユーザーの権限で走る任意のプロセスが認証プロンプト
なしに秘密鍵を取り出せるようになる。都度確認または Touch ID を選ぶ。

> `rm` はビット列の消去ではない。CoW / ジャーナリング / ウェアレベリングにより削除後も残りうる
> （`shred` は現代のファイルシステムでは機能しない）。ここで頼っているのはディスク暗号化である。

broker を dev workspace の**外**へ置く。

```sh
mkdir -p ~/.local/bin
cp images/runtime-base/templates/broker-macos-keychain.sh ~/.local/bin/<project>-broker
cp images/runtime-base/templates/prod-run.sh ~/.local/bin/prod-run.sh
chmod +x ~/.local/bin/<project>-broker ~/.local/bin/prod-run.sh
```

**リポジトリ内から実行してはいけない。** workspace はホストに bind mount されており、
リポジトリ内のラッパーを dev container の LLM エージェントが書き換えれば、人間がホストで実行する
際に正規 broker の前後で鍵を複製できる。Makefile や npm script から broker 起動を委譲するのも
同じ理由で不可。

---

## 4. `compose.prod.yaml` を配置する

```sh
mkdir -p ~/.config/<project>
cp images/runtime-base/templates/compose.prod.yaml ~/.config/<project>/compose.prod.yaml
```

`image:` のプレースホルダを実際の digest に置き換える。**タグではなく digest で pin する。**

```sh
docker buildx imagetools inspect ghcr.io/himorogy/runtime-base:1 --format '{{.Manifest.Digest}}'
```

compose ファイル自体もリポジトリの外に置く。プロジェクト固有の値は焼かれていないので、
`GIT_REPO` / `GIT_REF` と `COMPOSE_PROJECT_NAME` だけで複数プロジェクトに使い回せる。

### 動作確認

```sh
PROD_COMPOSE_FILE=~/.config/<project>/compose.prod.yaml \
PROD_BROKER=~/.local/bin/<project>-broker \
PROD_KEYCHAIN_SERVICE=<project>-prod-env \
GIT_REPO=https://github.com/<org>/<project>.git \
GIT_REF=$(git rev-parse HEAD) \
~/.local/bin/prod-run.sh dotenvx get -f .env.production
```

これが通れば、broker → パイプ → entrypoint → `/run/secrets` → shim の経路が全て動いている。

deploy まで通す場合、`clean -xdff` が `node_modules` も消すため依存インストールはコマンド側の
責務になる。

```sh
... prod-run.sh sh -c 'pnpm install --frozen-lockfile && pnpm deploy'
```

### つまずきやすいところ

- **`GIT_REF` は完全な commit sha を渡す。** ブランチ名や軽量タグは後から指す先を変えられる。
  40 桁 sha でない場合ラッパーは警告を出すが実行は続行する。
- **対話 TTY は使えない。** stdin が secret の搬送路なので `-T` が必須で、`run` の pseudo-TTY と
  両立しない。対話シェルが要る場合は `run -dT --rm prod sleep infinity` で起動してから
  `docker exec -it` で入る。
- **`private` リポジトリなら `GH_TOKEN` を鍵束に含める。** clone / fetch に使われ、checkout 直後に
  破棄される。deploy が別途 GitHub 資格情報を要するなら、clone 用とは別スコープ
  （read-only・単一 repo・短寿命）を用意する。
- **ビルド成果物は `/out`（tmpfs）に出す。** prod 値を埋め込んだ `dist/` は secret そのものを
  保持する。`/src`（named volume）に書くとコンテナ削除後も Docker VM のディスクに残る。

---

## 5. 旧構成を撤去する

4 が安定して動くことを確認してから。

- `scripts/prod-shell.sh` を削除
- dev/prod 相互排他チェック（`init-check-dev.sh` / `init-check-prod.sh` の
  `initializeCommand` 登録）を削除。共有 workspace が生んでいた制約であり、
  bind mount を廃止した時点で不要になる
- 2 層 devcontainer（`prod/devcontainer.json`）を使っていれば削除
- `~/.config/<project>/.env.container` が残っていないことを再確認

`@himorogy/enclave-env` 自体の去就は保留。検査は dotenvx 純正、配布は `core.hooksPath` に
移るため、package として残る中身は hook スクリプト程度になる。ホスト側で simple-git-hooks を
維持する場合は `check.sh` の配布先として残る可能性がある。

---

## ロールバック

3 以降は元に戻せる。鍵束を Keychain から取り出して `~/.config/<project>/.env.container` に
書き戻し、`prod-shell.sh` を復帰させればよい。

```sh
security find-generic-password -s "<project>-prod-env" -w > ~/.config/<project>/.env.container
chmod 600 ~/.config/<project>/.env.container
```

1 と 2 は prod の運用に触れないので、そのまま残して構わない。

---

## この移行で何が変わるか

| | 旧（prod-shell.sh） | 新 |
|---|---|---|
| prod 秘密鍵の保管 | ホスト上の恒久平文ファイル | OS キーチェーン（暗号化ストア） |
| 鍵の受け渡し | `--env-file`（`docker inspect` で読める） | stdin パイプ → コンテナ内 tmpfs |
| workspace | bind mount（dirty tree を持ち込む） | container 内 clone（明示 ref から復元） |
| 平文の残留 | `trap` によるクリーンアップ（SIGKILL / OOM / 再起動で飛ぶ） | tmpfs（電源断で消える） |
| 同時起動の防止 | 運用上の相互排他チェック | 不要になる（workspace を共有しない） |
| ログ / コアダンプ | 対処なし | `logging: none` / `ulimits core: 0` |
| コミット前検査 | 各 clone へ手動導入（伝播しない） | `core.hooksPath` をイメージに焼き込み |

守れていないもの（受容済みの残余リスク）:

- **dev が書いたコードを prod が実行する経路。** dev は `.env.production` へ書けるし
  （非対称暗号なので秘密鍵は不要）、prod が実行するコード・依存ツリー・package script も書ける。
  暗号化値の diff はキー名しか可視でなく、値のレビューはできない。本設計が守るのは機密性であり、
  この整合性の穴は **deploy 前の人間のレビューと完全 commit sha の pin** が唯一のゲートになる。
- **ホスト侵害。** 防御不能。ディスク暗号化を前提条件とする。
