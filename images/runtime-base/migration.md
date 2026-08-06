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
2. **ホストの docker に空き容量があること。** マルチアーキイメージの pull に要る。
3. **実行ホストにメモリの余裕があること。** `/src` は tmpfs で、repo と `node_modules` と
   pnpm store が全て RAM に載る。tmpfs の既定サイズはホスト RAM の 50%（karakuri 自身での
   実測使用量は 131M）。
4. **ディスク暗号化（FileVault / BitLocker）が有効であること。** 本設計の最後の砦であり、
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

- **検査対象のファイル名がプロジェクトの実態と合っていること。** 既定で検査されるのは
  basename が `.env` で始まるファイル（`.env`、`.env.production`、`apps/api/.env` 等）と
  `secret.env.*` だけである。`production.env` や `config/dev.env` のような名前を使っている
  プロジェクトは、リポジトリルートに `env-guard.conf` を置いて明示する。

  ```
  pattern (^|/)production\.env$
  allow   *.env.container.example
  ```

  `pattern` / `allow` は指定した側の既定を**置き換える**（追加ではない）。この設定は hook と
  CI の両方が同じように読むので、片方にだけ効くことはない。移行時に一度、いま何が tracked に
  なっているかを見ておくとよい。

  ```sh
  git ls-files | grep -E '\.env'
  ```

- **検査内容が変わっている。** hook が呼んでいた `dotenvx precommit` は外れ、共有スキャナ
  `env-guard-scan` に一本化された。CI 側とまったく同じ 1 本のファイルが判定する。以前は
  「hook は通るが CI で落ちる」が起こりえたが、いまはスコープ（staged か tracked か）だけが
  違い、判定は同一である。

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
... prod-run.sh sh -c 'pnpm install --frozen-lockfile \
      && dotenvx run --strict --no-armor -f .env.production -- pnpm deploy'
```

### つまずきやすいところ

- **`dotenvx` は `pnpm` の外側に置く。** `pnpm run <script>` は `node_modules/.bin` を PATH の
  **先頭**に積むため、プロジェクトがローカルに `@dotenvx/dotenvx` を持っていると script 内の
  `dotenvx` はそちらへ解決され、**shim が素通りされて鍵が注入されない**。4 リポジトリはいずれも
  ローカルに dotenvx を持つので、必ず踏む。

  ```sh
  # 効く — 最上位の dotenvx が shim に解決され、export した鍵を子プロセスが継承する
  ... prod-run.sh dotenvx run --strict --no-armor -f .env.production -- pnpm deploy

  # 効かない — ローカルの dotenvx が呼ばれ、鍵が無いまま復号を試みて失敗する
  ... prod-run.sh pnpm deploy
  ```

  手順 1 で `package.json` の script を `dotenvx run --` でくるんだのは**ホスト / dev での実行**の
  ためで、そこでは鍵が `.env.keys` か環境変数から来る。prod では鍵が `/run/secrets` から shim
  経由で来るので、最上位の呼び出しが必要になる。二重に `dotenvx run` が走ることになるが、
  内側は継承した鍵で動くので害はない。
- **`GIT_REF` は完全な commit sha を渡す。** 40 桁 hex 以外は **entrypoint が拒否する**。
  ブランチ名や軽量タグは後から指す先を変えられ、「レビューした対象と流したもの」の一致が
  切れるため。危険を理解した上でブランチ運用を選ぶなら `PROD_ALLOW_MUTABLE_REF=1` を明示する。
  解決済みの sha は stderr と `/run/prod-ref` に必ず記録されるので、可変 ref を許した場合でも
  「何をデプロイしたか」は後から辿れる。
- **`--strict` と `--no-armor` はイメージが強制しない。** 付け忘れると dotenvx は復号失敗で
  rc=0 を返し、暗号文をそのまま値として注入する。強制しないのは、shim が dev にも継承され
  `--convention flow` のような正当な重ね掛けを壊すため（dotenvx の使い方の問題であって
  コンテナの責務ではない）。**コマンドを書くときに必ず付けること。**
- **対話 TTY は使えない。** stdin が secret の搬送路なので `-T` が必須で、`run` の pseudo-TTY と
  両立しない。対話シェルが要る場合は `run -dT --rm prod sleep infinity` で起動してから
  `docker exec -it` で入る。
- **`private` リポジトリなら `GH_TOKEN` を鍵束に含める。** clone / fetch に使われ、checkout 直後に
  破棄される。deploy が別途 GitHub 資格情報を要するなら、clone 用とは別スコープ
  （read-only・単一 repo・短寿命）を用意する。
- **ビルド成果物は `/out`（tmpfs）に出す。** prod 値を埋め込んだ `dist/` は secret そのものを
  保持する。`/src` も tmpfs なのでディスクには残らないが、`/out` に出す方が意図が明確になる。
- **`--strict` と `--no-armor` を付ける。** `--strict` が無いと dotenvx は復号失敗で rc=0 を返し、
  暗号文をそのまま値として注入する（`FOO=encrypted:...` でアプリが起動し deploy は成功と報告
  される）。`--no-armor` は dotenvx 2.x が既定で有効にしているホスト型サービスへの経路を切る。
- **`node_modules` は毎回作り直しになる。** `/src` が tmpfs なので run をまたいだ保持は成立
  しない。pnpm の store も同様に毎回空から始まる。

---

## 5. CI 側の検査を入れる

`.github/workflows/env-guard.yml` を置く。中身はこれだけで、検査ロジックは karakuri 側にある。

```yaml
on: [push, pull_request]
jobs:
  env-guard:
    uses: himorogy/karakuri/.github/workflows/env-guard.yml@v1
```

雛形は `images/runtime-base/templates/env-guard.yml`。

hook（2 で入った）と**同じ 1 本のスキャナ**が判定するので、両者の間で結果が食い違うことはない。
違うのはスコープだけで、hook は staged なファイルを、CI は tracked なファイル全体を見る。
CI がクリーンな checkout（差分ゼロ）で走ることを踏まえた設計であり、**過去にコミット済みの
平文もここで初めて表面化する**。移行直後の 1 回目は、既存の平文を掘り起こして赤くなる可能性が
ある点に注意。

### 確認すること

- **出力に「何件検査したか」が出ること。** `0 file(s) were inspected` と出ているなら、
  それは「安全だった」ではなく「検査対象が 1 つも無かった」である。`env-guard.conf` の
  `pattern` がプロジェクトの実態と合っているかを疑う
- **呼び出し側 org の Actions ポリシー。** 「選択した actions / reusable workflows のみ許可」に
  している org では、`himorogy/karakuri/...` を allowlist へ明示的に追加する必要がある。
  これはプランの制限ではなく設定項目
- karakuri が public であること（他 org から reusable workflow を呼ぶ前提）

---

## 6. 旧構成を撤去する

4 と 5 が安定して動くことを確認してから。

- `scripts/prod-shell.sh` を削除
- dev/prod 相互排他チェック（`init-check-dev.sh` / `init-check-prod.sh` の
  `initializeCommand` 登録）を削除。共有 workspace が生んでいた制約であり、
  bind mount を廃止した時点で不要になる
- 2 層 devcontainer（`prod/devcontainer.json`）を使っていれば削除
- `~/.config/<project>/.env.container` が残っていないことを再確認

`@himorogy/enclave-env` 自体の去就は保留。ただし判断材料は増えた — 検査ロジックは
`env-guard-scan` としてイメージ側へ移り、配布は `core.hooksPath` と reusable workflow に
乗ったので、package として残る中身がほぼ無くなっている。`check.sh` の実質的な後継が
`env-guard-scan` であり、ホスト側で simple-git-hooks を維持する場合の配布先という用途だけが
残る。

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
| workspace | bind mount（dirty tree を持ち込む） | container 内の tmpfs へ clone（明示 ref から復元し、毎回捨てる） |
| 平文の残留 | `trap` によるクリーンアップ（SIGKILL / OOM / 再起動で飛ぶ） | tmpfs（電源断で消える） |
| 同時起動の防止 | 運用上の相互排他チェック | 不要になる（workspace を共有しない） |
| ログ / コアダンプ | 対処なし | `logging: none` / `ulimits core: 0` |
| 前回実行の残留 | workspace に残る | tmpfs なので毎回消える（ref の汚染と `.git/config` への仕込みが構造的に成立しない） |
| コミット前検査 | 各 clone へ手動導入（伝播しない） | `core.hooksPath` をイメージに焼き込み |

守れていないもの（受容済みの残余リスク）:

- **dev が書いたコードを prod が実行する経路。** dev は `.env.production` へ書けるし
  （非対称暗号なので秘密鍵は不要）、prod が実行するコード・依存ツリー・package script も書ける。
  暗号化値の diff はキー名しか可視でなく、値のレビューはできない。本設計が守るのは機密性であり、
  この整合性の穴は **deploy 前の人間のレビューと完全 commit sha の pin** が唯一のゲートになる。
- **ホスト侵害。** 防御不能。ディスク暗号化を前提条件とする。
