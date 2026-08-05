# devcontainer-base

`@himorogy` の各プロジェクトが共有する devcontainer ベースイメージ。

各プロジェクトが個別に Dockerfile を持つと、共通部分の改善（例: `ipset add` に
`-exist` を付ける）を全プロジェクトへ伝播させるのが辛い。共通部分を GHCR の
ベースイメージに集約し、各プロジェクトは `FROM` で参照する。

```
ghcr.io/himorogy/devcontainer-base:1
```

設計の経緯と判断根拠は [devcontainer-base-handoff.md](./devcontainer-base-handoff.md) にある。
本 README は運用手順を扱う。

---

## 層の分離

| 層 | 中身 | 手段 | 更新の伝播 |
|---|---|---|---|
| A | OS パッケージ、root 権限が要るもの、エージェントが直接使うもの | **この base image** | `FROM` の更新 |
| B | プロジェクト別の設定ファイル（egress-guard の `firewall.json` 等） | プロジェクトの Dockerfile | プロジェクト側で更新 |
| C | 個人の対話的体験にしか効かないもの | dotfiles の後付けスクリプト | 実行するだけ |
| D | npm で入るもの（Biome, dprint 等） | プロジェクトの devDependency | `package.json` |

### 収録判定

base に入れる条件は次のいずれか。

- npm では入らない（OS パッケージ、root 権限が要る）
- エージェントが直接使う（`ripgrep`, `jq`, `git`, `gh`, `dnsutils` 等）

入れない条件。

- 人間の対話体験にしか効かない → C（後付けスクリプト）
- npm で入る → D（devDependency）。base に焼くとバージョンがプロジェクトの
  `package.json` と乖離し、ローカルと CI でフォーマット結果が変わる
- プロジェクト固有 → プロジェクトの Dockerfile

### 収録物

- Node 24（`node:24` 由来）、pnpm（`ARG PNPM_VERSION` で pin）
- `git` / `gh` / `sudo` / `zsh` / `less` / `procps` / `man-db` / `unzip` / `gnupg2`
- `jq` / `ripgrep` / `fd-find`（`fd` として PATH に露出）
- `vim-tiny`（`git commit` / `rebase -i` がエディタ不在で失敗しないための最小保険）
- egress-guard 実行に必要なもの: `iptables` / `ipset` / `iproute2` / `dnsutils` / `aggregate`
  （`curl` と `jq` は上の行と `node:24` に含まれる）
- egress-guard 本体: `/usr/local/bin/init-project-firewall.sh`（`ARG EGRESS_GUARD_VERSION` で pin）と
  `/etc/sudoers.d/node-firewall`
- `crit`（`CRIT_HOST=0.0.0.0`、更新チェック無効）
- locale `C.UTF-8`、TZ `Asia/Tokyo`、bash / zsh の履歴永続化設定
- 作業ユーザー `node`（UID/GID 1000）、`/workspaces` `~/.claude` `~/.codex` を作成済み。
  `WORKDIR` は `/workspaces`（複数形。devcontainer の既定に合わせている）

### 非収録

- egress-guard の実効設定（`firewall.json`）… 許可ドメインがプロジェクト別で、
  `COPY` 元がプロジェクトのビルドコンテキストにあり base のビルド時には存在しない。
  プロジェクトの Dockerfile で入れる（[examples/Dockerfile](./examples/Dockerfile)）。
  egress-guard のうち base に入らないのはこれだけ
- `starship` / `helix` / `micro` / `eza` / `bat` / `fzf` / `delta` / `herdr` / `ax` … dotfiles の後付けスクリプト
- Biome / dprint … devDependency
- `postgresql-client` 等のプロジェクト固有パッケージ … プロジェクトの Dockerfile

---

## プロジェクトからの使い方

[examples/](./examples/) の 4 ファイルを `.devcontainer/` にコピーし、
`<your-project>` と `CRIT_PORT` を差し替える。

```
.devcontainer/
├── Dockerfile             ← examples/Dockerfile
├── docker-compose.yml     ← examples/docker-compose.yml
├── devcontainer.json      ← examples/devcontainer.json
├── post-create.sh         ← examples/post-create.sh
├── firewall.json          ← プロジェクトの許可ドメイン
└── devcontainer-lock.json ← Feature の版を固定。初回ビルドで生成される。コミットすること
```

雛形は **Docker Compose 構成**。egress-guard がこれを第一に推奨している。Compose は
プロジェクトごとにユーザー定義ネットワーク（`<name>_default`）を自動で作り、その上でだけ
Docker の埋め込みリゾルバ `127.0.0.11` が使えるため。デフォルトブリッジのままだと
ホスト側の DNS アドレス宛に外向きの穴が 1 つ開く。根拠と、Compose を使わない場合の代替は
[`packages/egress-guard/README.md`](../../packages/egress-guard/README.md) の
「ネットワーク構成（推奨）」。

### 忘れると時間を溶かす設定

**`docker-compose.yml` の `build.pull`。**

```yaml
build:
  pull: true
```

浮動タグ `:1` を参照する運用では、ローカルに古い base が残っているとリビルドしても
更新されない。「更新したのに反映されない」で嵌る。

**`devcontainer.json` の `"build": { "options": ["--pull"] }` は `dockerComposeFile` を
使うと効かない。** 同じ理由で `runArgs` / `containerEnv` / `mounts` / `workspaceMount` も
無視される。`cap_add` を `runArgs` に書き戻すと、効かないまま egress-guard の適用だけが
失敗する。

**`docker-compose.yml` のマウント先と `devcontainer.json` の `workspaceFolder` を
一致させること。** ずれると `postCreateCommand` が exit 127 で落ちる。エラーはコマンドの
側に出るため、原因がマウント先の不一致だと気づきにくい。

### 既存プロジェクトを載せ替える場合

新規ではなく pnpm 10 の devcontainer を移す場合は [migration.md](./migration.md) を先に
読むこと。base は pnpm 11 を焼いており、`strictDepBuilds` の既定変更で `pnpm install` が
失敗する、`.npmrc` の設定が読まれなくなる、`pnpm/action-setup` が v6 以上でないと動かない、
といった当たりがある。

---

## 保護範囲（egress-guard の前提）

egress-guard は「正しく動くツールが意図しない宛先へ通信するのを防ぐ」ためのもので、
悪意あるコードを封じ込めるサンドボックスではない。以下は保護されない。

- **コンテナ作成中の通信**。devcontainer の lifecycle は
  `initializeCommand`（ホスト側）→ **Feature の導入** → `postCreateCommand` →
  `postStartCommand` の順。firewall を適用するのは `postStartCommand` なので、
  Feature の取得も `post-create.sh` の `npm install` も制限なしで実行される。
  この時点で復号キーは既にコンテナ内にある。Feature を使うと版は
  `devcontainer-lock.json` に固定されるが、**固定されるのは取得物であって通信ではない**
- **`waitFor` は待機指定であって境界ではない**。エディタが接続を報告するタイミングを
  制御するだけで、先行する lifecycle command の通信は止めない
- **コンテナ内で root を取ったプロセス**。雛形は egress-guard の実装上
  `NET_ADMIN` / `NET_RAW` を付けており、root は iptables を書き換えられる。
  sudoers の引数制限が抑止するのは通常の `node` ユーザーによる設定差し替えであって、
  root 奪取後の回避ではない
- **ホストや Docker デーモンへの攻撃**

前提として、ワークスペースの内容と lifecycle command が悪意を持たないこと、
`firewall.json` と egress-guard パッケージのバージョンが管理下にあることを要求する。
この Dockerfile が `ARG EGRESS_GUARD_VERSION` でバージョンを固定するのはこのため。
dist-tag のまま追従させると、パッケージ側の更新がそのままコンテナ内 root での
コード実行になる。

厳密に保護したい場合は、lifecycle command の実行前（コンテナの entrypoint 段階）で
firewall を張る設計が必要になる。現状はそこまで踏み込んでいない。

---

## リリース

`.github/workflows/devcontainer-base.yml` が
`linux/amd64,linux/arm64` のマルチアーキビルドと GHCR への push を行う。

### タグ体系

| タグ | 内容 |
|---|---|
| `:1` | メジャー内の最新。**利用側が参照するのはこれ** |
| `:1.4` | マイナー内の最新 |
| `:1.4.2` | 特定バージョン |
| `sha-<commit>` | ビルド元コミット |

`:latest` は生成しない（ワークフローで `flavor: latest=false` を指定）。
参照先を `:1` に一本化し、メジャーを跨いだ破壊的変更が黙って降ってこないようにするため。

### 手順

```sh
# images/devcontainer-base/ の変更を main にマージしたあと
git tag -a devcontainer-base-v1.0.0 -m "devcontainer-base 1.0.0"
git push origin devcontainer-base-v1.0.0
```

タグ名は `devcontainer-base-v<MAJOR>.<MINOR>.<PATCH>`。形式が違うとワークフローが
検証で落ちる。プレリリース（`-rc.1` など）も弾かれる。手元での試作は
`docker buildx build --platform linux/amd64,linux/arm64 images/devcontainer-base` で行う。

npm パッケージのリリースタグ（`@himorogy/egress-guard@0.1.0`、
[secure-publish.md](../../docs/secure-publish.md) §4.4）と形式を分けているのは、
**公開先のレジストリが違う**ため。npm への公開は実質取り消せないが、GHCR は版の削除も
タグの付け替えもできる。取り消し可能性が違うものを、タグ名の時点で区別している。

`@himorogy/devcontainer-base@1.0.0` のように npm 側の形式へ寄せないのは、npm に存在
しないパッケージ名を騙ることになるため。タグ名を見て npm を探す人が出る。

push すると `prepare` がタグを検証し、`release` が **environment `ghcr-publish` の承認待ちで停止する**。
承認者はタグを打った本人以外（`prevent_self_review`）。承認後に `:1` / `:1.0` / `:1.0.0` /
`sha-xxxxxxx` が同時に更新される。ゲートを揃えた理由は
[secure-publish.md](../../docs/secure-publish.md) §4.8。

### トリガーの使い分け

- **タグ push** … リリース。承認を経て GHCR へ push
- **Pull Request**（`images/devcontainer-base/**` 変更時）… 両アーキの検証ビルドのみ。push しない
- **workflow_dispatch** … 検証ビルドのみ。push しない

**GHCR へ push する経路はタグ 1 本だけ。** 以前は `workflow_dispatch` から `:edge` で
push できたが、承認ゲートを置きながら迂回路を残す意味がないため廃止した。

`workflow_dispatch` はワークフローファイルがデフォルトブランチに存在しないと発火しない。
feature ブランチでの先行検証は Pull Request 経由で行う。

main への push はトリガーにしていない。利用側が引くのはリリースタグだけで、
main の各コミットを GHCR に積む必要がないため。

### 初回だけ手動で必要なこと

GHCR のパッケージは初回 push 時に **private** で作成されるのが通常。組織の
package creation / visibility ポリシー次第で結果は変わるため、初回リリース後に
実際の可視性を確認し、private なら GitHub の
`Packages → devcontainer-base → Package settings → Change visibility` で
**Public** に切り替える。

初回 push が権限エラーで落ちる場合は、組織設定で Actions からの package creation が
許可されているかを確認する。ワークフロー側の `packages: write` だけでは足りない。

public にしておくと利用側の `docker pull` に認証が不要になる。base は中立な
開発基盤のみを収録しているため公開して問題ない。

---

## 検証チェックリスト

ワークフローは push 後に両アーキで `crit --version` / `pnpm --version` / `$LANG` を
確認する。手元でより詳しく見る場合は以下。

```sh
IMAGE=ghcr.io/himorogy/devcontainer-base:1

# 1. vi が使えるか（vim-tiny が alternatives を登録しているか）
docker run --rm "$IMAGE" vi --version

# 2. locale
docker run --rm "$IMAGE" sh -c 'echo $LANG; locale'          # C.UTF-8

# 3. pnpm が packageManager と一致しているか
docker run --rm "$IMAGE" pnpm --version

# 4. bash 履歴の永続化
docker run --rm "$IMAGE" bash -c 'echo $HISTFILE'            # /commandhistory/.bash_history

# 5. 非対話シェルにプロンプト汚染がないか（余計な出力がなければ OK）
docker run --rm "$IMAGE" zsh -c 'echo ---; git --version; echo ---'

# 6. エージェントが実際に使う経路
docker run --rm "$IMAGE" bash -c 'echo $PS1'                 # 空

# 7. マルチアーキ
docker run --rm --platform linux/amd64 "$IMAGE" crit --version
docker run --rm --platform linux/arm64 "$IMAGE" crit --version
```

sudoers の引数制限は base の時点で確認できる。引数を伴う呼び出しが sudo に拒否される
こと（スクリプトが起動して失敗するのではなく、sudo が実行そのものを断ること）を見る。

```sh
# sudo に拒否されること
docker run --rm -u node "$IMAGE" sudo /usr/local/bin/init-project-firewall.sh --config /tmp/x

# 引数なしは sudo を通る。firewall.json と NET_ADMIN が無いため
# スクリプト自体は失敗するが、それは sudo の拒否とは別のメッセージになる
docker run --rm -u node "$IMAGE" sudo /usr/local/bin/init-project-firewall.sh
```

---

## 既知のトレードオフ

**digest pin をしない。** 規制対応（510(k) / ISO 13485）の文脈では「いつビルドしても
同じ成果物」が求められるため、本来は digest 固定が望ましい。現状は運用負荷を優先して
浮動タグ `:1` を選択している。再現性の要求が強まったプロジェクトのみ digest pin +
Renovate（`pinDigests: true`）へ切り替える。この変更は base に手を入れずに後付けできる。

**Node バージョンは base に単一固定。** `mise` 等の切替機構は採用していない。理由は
①コンテナ起動後に nodejs.org へのダウンロードが走り、egress-guard の設計思想
（実効設定を root 固定・self-service 遮断）と衝突する ②再現性が `mise.toml` 側に移り
base digest だけで環境が確定しなくなる ③shim 経由で PATH 解決が複雑になり
エージェント運用のデバッグが困難になる。

**マルチアーキビルドは QEMU 経由。** `crit` はクロスコンパイルで QEMU を回避しているが、
`apt-get` は arm64 側でエミュレーションが走る。ビルド時間が問題になったら
ネイティブランナー（`ubuntu-24.04-arm`）の matrix ビルド + digest マージに切り替える。

**apt パッケージは pin していない。** Renovate も導入していない。

**ワークフローを検証用とリリース用のジョブに分けていない。** `permissions` はジョブ単位に
しか書けないため、push しない Pull Request のビルドにも `packages: write` が付く。
fork からの PR では `GITHUB_TOKEN` が read-only に制限され、login / push step も
条件でスキップされるので現状の書き込み経路はない。ビルド定義の重複を避けるために
1 ジョブのままにしているが、step を追加する際は権限の広さを意識すること。

**`docker/*` の action を 5 つ使っている。** リポジトリの action 許可リストに明示的に
載せたうえで、commit SHA で固定している。`packages: write` を持つジョブで第三者の
コードを動かすことになり、[`docs/secure-publish.md`](../../docs/secure-publish.md) §4.3 の
原則から外れる。判断の根拠と、ネイティブ arm64 ランナーへの移行でこれを外す道筋は
同 §4.6。

---

## 残タスク

- **雛形の実地検証**。`examples/` の Compose 構成はまだ一度も起動していない。
  このリポジトリでは検証しない方針のため（「判断済み」）、base を利用する
  別のリポジトリで「検証チェックリスト」を通す
- **`packages/enclave-env/templates/devcontainer/` の移行**。まだ旧構成のまま。
  ワークスペースが `/workspace`（単数形）で、pnpm の版も固定されていない。
  手順と注意点は [migration.md](./migration.md)
- **crit のバージョン検証**。`crit --version` は `dev` を返すため、
  `ARG CRIT_VERSION` で指定した版が実際に入ったかをイメージ側から確認できない。
  ビルダー段で `go version -m /out/crit` を `${CRIT_VERSION}` と突き合わせれば
  ビルド時に落とせる。あわせて
  [monitor.yml](../../.github/workflows/monitor.yml) に crit の追従チェックがない
- **`examples/post-create.sh` が `pnpm lint:sh` の対象外**。`lint:sh` は
  `pnpm -r` でワークスペースのパッケージだけを回るため、`images/` 以下は
  shellcheck にかからない
- **`ARG EGRESS_GUARD_VERSION` の更新運用**。egress-guard を上げるには base の再ビルドが
  要る。Renovate は入れていないので、上げる操作自体は手動のまま。上げ忘れは
  [monitor.yml](../../.github/workflows/monitor.yml) が毎日 npm と照合して Slack に出す

### 判断済み（再検討するときに読む）

- **このリポジトリ自身の `.devcontainer/` は base image に載せ替えない。** karakuri は
  egress-guard を開発している場所であり、その egress-guard は base image に焼き込まれて
  いる。開発環境が base に依存すると、**base が壊れたとき、それを直すための環境が
  起動しなくなる**。自分を直す手段が自分の成果物に依存する循環になる。コンパイラや
  パッケージマネージャが bootstrap 経路を分けて保つのと同じ理由。

  加えて、開発のループに「公開」が挟まる。`.devcontainer/Dockerfile` は npm の
  公開版を版指定で入れており、作業ツリーのスクリプトが動いているわけではない。**この点は base に載せ替えても変わらない。** 変わるのは
  更新の経路で、今は Dockerfile の 1 行を書き換えてリビルドすれば新しい版を試せるが、
  base 経由では新しい版を試すために先にイメージを公開する必要がある。

  引き換えに失うのは、`examples/` の雛形がこのリポジトリでは実地検証されないこと。
  Compose での起動・`cap_add` の実効・埋め込みリゾルバ・`workspaceFolder` と
  マウント先の一致は、base を利用する別のリポジトリで確認する（「検証チェックリスト」）
- **`NET_RAW` は雛形に残す。** 実測すると Docker 既定の bounding set
  （`0xa80425fb`）に `NET_RAW` が含まれており、`--cap-add=NET_RAW` は既定構成では
  no-op だった（`--cap-add` で増えるのは `NET_ADMIN` のビットだけ）。落として得られる
  実利がなく、`--cap-drop=ALL` を併用する構成でだけ壊れる。なお `iptables` は netfilter と
  話すのに `AF_INET SOCK_RAW` を開くため、そもそも `CAP_NET_RAW` を要求するはずだが、
  これは未検証。イメージができたら
  `--cap-drop=NET_RAW --cap-add=NET_ADMIN` で起動し、init が失敗することで確かめられる
- **dotfiles の後付けスクリプトへの移管は行わない。** base の守備範囲外として整理した
  ツール群（`starship` / `helix` / `micro` / `eza` / `bat` / `fzf` / `delta` / `herdr` /
  `ax`）は、base から外したままにする
