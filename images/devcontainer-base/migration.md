# 既存プロジェクトの移行ガイド

pnpm 10 を使っている devcontainer を、この base image（pnpm 11）へ載せ替えるときの手順と
注意点。

**この文書は 2 つの移行を扱う。** 独立して進められるので、分けて実施することを勧める。

- **pnpm 10 → 11**。base image とは無関係に、現行の Dockerfile のままでも実施できる
- **プロジェクト固有の Dockerfile → base image**。`FROM` の差し替えと、base に入った分の削除

まとめてやると、失敗したときにどちらが原因か切り分けられなくなる。

---

## 前提

**base image はまだ GHCR に存在しない。** [`.github/workflows/devcontainer-base.yml`](../../.github/workflows/devcontainer-base.yml)
が一度も実行されていない。移行の第一歩は、このワークフローを走らせて
`ghcr.io/himorogy/devcontainer-base:1` を作ること。

以下、**実測済み**と**リリースノート由来（未実測）**を分けて記す。実測は 2026-08-04 に
karakuri monorepo（pnpm 11.20.0 / Node 24 / linux-arm64）で行ったもの。

---

## 1. 実測済み — 必ず踏む

### 1.1 `strictDepBuilds` の既定が `true` になった

`pnpm install` が `ERR_PNPM_IGNORED_BUILDS` で **exit 1** になる。判断が書かれていない
ビルドスクリプトが 1 つでも残っていると落ちる。

対処は `pnpm-workspace.yaml` の `allowBuilds` に、パッケージごとの可否を明示する。

```yaml
allowBuilds:
  esbuild: false
```

- **pnpm 10 の `onlyBuiltDependencies` / `ignoredBuiltDependencies` は効かない。**
  どちらも試したが `ERR_PNPM_IGNORED_BUILDS` は消えなかった
- pnpm 11 は install 時に `allowBuilds: <pkg>: set this to true or false` という
  プレースホルダを **`pnpm-workspace.yaml` に自動で書き込む**。埋めるまで失敗し続ける
- **この自動書き込みで作業ツリーが dirty になる。** ロックファイルや設定ファイルの差分を
  検査する CI を持っているなら、移行時に一度引っかかる
- `strictDepBuilds: false` でも通るが、それは判断を書かずに済ませているだけなので勧めない

`esbuild` / `sharp` / `better-sqlite3` / `puppeteer` などを持つプロジェクトは該当する。

**`false` を選んでよいかの判断。** そのパッケージがプラットフォーム別バイナリを
optional 依存（`@esbuild/<platform>` 形式）として配っているなら、postinstall を走らせ
なくても動く。pnpm 10 の時点で既に実行されていなかったのだから、`false` は挙動を
変えない選択でもある。判断がつかないものだけ `true` にする。

### 1.2 既存の `node_modules` を作り直す必要がある

content-addressable store が v10 と v11 で別物になる。pnpm 11 は `node_modules` の削除を
確認しようとし、TTY が無いと中断する。

```
[ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY] Aborted removal of modules directory due to no TTY
```

- **`postCreateCommand` / `postStartCommand` で install する構成は確実に踏む**
- **`node_modules` を named volume に載せている構成は特に注意。** イメージを差し替えても
  古い `node_modules` が残るため、再ビルドしただけでは解消しない
- 対処は、事前に `rm -rf node_modules packages/*/node_modules` するか、
  `CI=true` を渡すか、`confirmModulesPurge` を `false` にする
- 依存の再ダウンロードが走る。egress-guard の下で行うなら `registry.npmjs.org` が
  allowlist にあることを確認しておく（`npm` バンドルに含まれる）

### 1.3 `pnpm/action-setup` は v6 以上でなければならない

**v6.0.0 のリリースノートが "Added support for pnpm v11"。** v4 / v5 のままでは
`packageManager` を 11 に上げても動かない。

- `v4` タグは 2026-03-26 のコミットで止まっている。現在の最新は v6.0.10
- v6.0.6 に「`bin_dest` が self-update 後の pnpm ではなく bootstrap を指す」不具合の
  修正が入っている。これを踏むと **CI が意図したものと違う pnpm を走らせる**
- pnpm/pnpm#11513（pnpm 11 で OIDC 公開が 404 になる）で報告者が実際に解決したのも、
  この action の更新だった

### 1.4 ロックファイルは再生成不要

`lockfileVersion: '9.0'` を pnpm 11 がそのまま受理する（"Lockfile is up to date,
resolution step is skipped"）。karakuri では差分ゼロを確認した。

`patchedDependencies` を使っているプロジェクトだけは形式が変わる（§2.5）。

---

## 2. リリースノート由来 — 未実測、プロジェクトごとに要確認

### 2.1 `.npmrc` が読まれない ← 最も危険

pnpm 11 は設定を `pnpm-workspace.yaml`（と `config.yaml`）から読む。`.npmrc` と、
`package.json` の `pnpm` フィールドは読まれない。

**エラーにならず、既定値に戻る。** `shamefully-hoist` / `node-linker` /
`auto-install-peers` / `public-hoist-pattern` などを `.npmrc` で設定しているプロジェクトは、
**気付かないまま依存の解決結果が変わる。** 移行前に全プロジェクトの `.npmrc` を洗い出し、
`pnpm-workspace.yaml` へ移すこと。

karakuri は `.npmrc` を持たないため無風だった。他のプロジェクトに同じ保証はない。

### 2.2 `minimumReleaseAge` の既定が 1440 分（1 日）になった

公開から 24 時間以内のバージョンを入れなくなる。

- `--frozen-lockfile` は解決を行わないため CI には影響しない
- `pnpm add` / `pnpm update` で「最新が入らない」という形で現れる
- **セキュリティ修正を急いで取り込みたいときに詰まる。** その場だけ緩める手順を
  あらかじめ決めておく

### 2.3 `blockExoticSubdeps` の既定が `true` になった

git / http / tarball URL の依存が subdep にあると落ちる。

### 2.4 認証まわり

- 認証トークンの保存先が `.npmrc` から `~/.config/pnpm/auth.ini` へ移った。
  `.npmrc` にトークンを置いてマウントしている構成は再設定が要る
- OTP の環境変数が `NPM_CONFIG_OTP` から `PNPM_CONFIG_OTP` へ改名された

### 2.5 `patchedDependencies` の形式変更

`Record<string, { path, hash }>` から `Record<string, string>` へ。既存のロックファイルは
自動移行されるが、差分が出る。

### 2.6 Node 22 以上が必須

base image は `node:24` なのでコンテナ側は問題ない。**CI の `setup-node` が 20 以下の
プロジェクトは落ちる。**

---

## 3. 公開経路（npm publish を行うプロジェクトのみ）

- **`actions/setup-node` に `registry-url` を指定しない。** 指定すると `.npmrc` に
  `_authToken=${NODE_AUTH_TOKEN}` が書き込まれる。pnpm 11.1.3 未満はこの未解決の
  プレースホルダをそのままレジストリへ送るため、OIDC trusted publishing が 404 になる
  （pnpm/pnpm#11513、修正は pnpm/pnpm#11526）。11.20.0 では修正済みだが、そもそも
  指定しないのが安全
- **`pnpm publish` が npm CLI に依存しなくなった。** provenance の生成経路が pnpm 10 と
  変わっている。移行後の初回公開では `npm view <pkg> --json` で provenance が付いている
  ことを確認すること

---

## 4. base image への切り替え

### 4.1 忘れると時間を溶かす設定

浮動タグ `:1` を参照する以上、pull を強制しないとローカルに残った古い base が使われる。
「更新したのに反映されない」の原因になる。**書く場所は構成で変わる。**

```yaml
# Docker Compose 構成（雛形はこちら）— docker-compose.yml
services:
  dev:
    build:
      pull: true
```

```jsonc
// Compose を使わない構成 — devcontainer.json
"build": { "options": ["--pull"] }
```

**`dockerComposeFile` を使うと `devcontainer.json` 側の `build` は使われない。**
上の `--pull` を書いても効かないので、Compose 構成では `build.pull` に書くこと。

### 4.2 プロジェクト側 Dockerfile から削るもの

**base に egress-guard 本体（`/usr/local/bin/init-project-firewall.sh` と
`/etc/sudoers.d/node-firewall`）が入っている。** プロジェクト側から次を削除する。

- `npm install -g @himorogy/egress-guard`
- スクリプトを `/usr/local/bin` へ `cp` する `RUN`
- sudoers を生成する `RUN`

残すと二重に入る。プロジェクト側に残るのは `firewall.json` の `COPY` と権限付与だけ。
完成形は [`examples/Dockerfile`](./examples/Dockerfile) を参照。

同じく、base に入っている OS パッケージ（`iptables` / `ipset` / `iproute2` /
`dnsutils` / `jq` / `aggregate`、および `node:24` 由来の `curl`）の `apt-get` も削れる。
収録物の一覧は [README.md](./README.md) の「収録物」を参照。

### 4.3 プロジェクト側に残るもの

- `firewall.json`（実効設定。プロジェクトごとに異なるため base には入らない）
- `NET_ADMIN` / `NET_RAW`。**Compose 構成では `docker-compose.yml` の `cap_add` に書く。**
  `dockerComposeFile` を使うと `runArgs` は黙って無視されるため、`devcontainer.json` に
  書き戻しても効かず、egress-guard の適用だけが失敗する
- `postStartCommand` と `waitFor`
- プロジェクト固有の apt パッケージ（`postgresql-client` など）

### 4.4 Compose 構成へ移す場合に一緒に動かすもの

雛形は Compose 構成（[`examples/docker-compose.yml`](./examples/docker-compose.yml)）に
なっている。`runArgs` 方式から移すなら、次はすべて `docker-compose.yml` 側へ移す。
`devcontainer.json` に残しても効かない。

| `devcontainer.json`（効かなくなる） | `docker-compose.yml`（移す先） |
|---|---|
| `runArgs: ["--name=..."]` | `container_name` |
| `runArgs: ["--cap-add=..."]` | `cap_add` |
| `runArgs: ["-p", "..."]` | `ports` |
| `runArgs: ["--env-file", "..."]` | `env_file` |
| `runArgs: ["--network=..."]` + `initializeCommand` の network 作成 | 不要。Compose が `<name>_default` を自動で作る |
| `containerEnv` | `environment` |
| `workspaceMount` | `volumes` |
| `mounts` | `volumes` |
| `build.options: ["--pull"]` | `build.pull: true` |

**`${devcontainerId}` は Compose では使えない。** ボリュームは固定名になるため、
`runArgs` 方式で作られた既存ボリュームとは別物になる。**claude と codex の再ログインが
要る。** 引き継ぎたい場合は `docker volume ls` で実名を調べ、`external: true` で名前を
合わせる。

**`docker-compose.yml` のマウント先と `devcontainer.json` の `workspaceFolder` を
一致させること。** ずれると `postCreateCommand` が exit 127 で落ちる。エラーはコマンドの
側に出るため、原因がマウント先の不一致だと気づきにくい。

### 4.5 base の pnpm を上書きしたい場合

派生 Dockerfile で入れ直す（例外運用）。`devcontainer.json` の `build.args` は base
イメージには届かない。

---

## 5. 推奨する順序

1. **base image と無関係に**、現行の Dockerfile のまま `packageManager` を pnpm 11 へ上げ、
   CI を通す
2. `.npmrc` の設定を `pnpm-workspace.yaml` へ移す（§2.1。静かに壊れるので先にやる）
3. `allowBuilds` を埋める（§1.1）
4. `pnpm/action-setup` を v6 へ（§1.3）
5. `FROM` を base image へ切り替え、Dockerfile から重複分を削る（§4）
6. `node_modules` と named volume を捨ててから再ビルドする（§1.2）

1〜4 は base image を使わずに検証できる。5 で初めて base に依存する。

---

## 6. 移行後の確認

```sh
# pnpm が packageManager と一致しているか
docker exec <ctn> pnpm --version

# install が通るか（allowBuilds を埋め忘れているとここで落ちる）
docker exec <ctn> pnpm install --frozen-lockfile

# egress-guard が二重に入っていないか。base 由来の 1 つだけであること
docker exec <ctn> sh -c 'ls -l /usr/local/bin/init-project-firewall.sh; cat /etc/sudoers.d/node-firewall'

# sudoers の引数制限が効いているか（後者は sudo に拒否されること）
docker exec <ctn> sudo /usr/local/bin/init-project-firewall.sh
docker exec <ctn> sudo /usr/local/bin/init-project-firewall.sh --config /tmp/x

# 実際に遮断されているか（到達できたら firewall が適用されていない）
docker exec <ctn> curl --connect-timeout 5 https://example.com
```

base image 自体の検証項目は [README.md](./README.md) の「検証」を参照。
