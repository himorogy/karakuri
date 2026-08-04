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
- 作業ユーザー `node`（UID/GID 1000）、`/workspace` `~/.claude` `~/.codex` を作成済み

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

[examples/](./examples/) の 2 ファイルを `.devcontainer/` にコピーし、
`<your-project>` と `CRIT_PORT` を差し替える。

```
.devcontainer/
├── Dockerfile          ← examples/Dockerfile
├── devcontainer.json   ← examples/devcontainer.json
└── firewall.json       ← プロジェクトの許可ドメイン
```

### 忘れると時間を溶かす設定

```jsonc
"build": { "options": ["--pull"] }
```

浮動タグ `:1` を参照する運用では、ローカルに古い base が残っているとリビルドしても
更新されない。`--pull` がないと「更新したのに反映されない」で嵌る。

---

## 保護範囲（egress-guard の前提）

egress-guard は「正しく動くツールが意図しない宛先へ通信するのを防ぐ」ためのもので、
悪意あるコードを封じ込めるサンドボックスではない。以下は保護されない。

- **コンテナ作成中の通信**。devcontainer の lifecycle は
  `initializeCommand`（ホスト側）→ `postCreateCommand` → `postStartCommand` の順。
  firewall を適用するのは `postStartCommand` なので、`postCreateCommand` の
  `curl | bash` は制限なしで実行される。この時点で復号キーは既にコンテナ内にある
- **`waitFor` は待機指定であって境界ではない**。エディタが接続を報告するタイミングを
  制御するだけで、先行する lifecycle command の通信は止めない
- **コンテナ内で root を取ったプロセス**。雛形は egress-guard の実装上
  `--cap-add=NET_ADMIN` / `--cap-add=NET_RAW` を付けており、root は iptables を
  書き換えられる。sudoers の引数制限が抑止するのは通常の `node` ユーザーによる
  設定差し替えであって、root 奪取後の回避ではない
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
| `:edge` | `workflow_dispatch` からの任意ビルド |

`:latest` は生成しない（ワークフローで `flavor: latest=false` を指定）。
参照先を `:1` に一本化し、メジャーを跨いだ破壊的変更が黙って降ってこないようにするため。

### 手順

```sh
# images/devcontainer-base/ の変更を main にマージしたあと
git tag devcontainer-base-v1.0.0
git push origin devcontainer-base-v1.0.0
```

タグ名は `devcontainer-base-v<MAJOR>.<MINOR>.<PATCH>`。プレフィックスを付けるのは
npm パッケージ側のリリースタグ（`v0.2.1`）と名前空間が衝突しないようにするため。
形式が違うとワークフローが検証で落ちる。

push すると `:1` / `:1.0` / `:1.0.0` / `sha-xxxxxxx` が同時に更新される。

### トリガーの使い分け

- **タグ push** … リリース。GHCR へ push
- **Pull Request**（`images/devcontainer-base/**` 変更時）… 両アーキの検証ビルドのみ。push しない
- **workflow_dispatch** … 任意ビルド。`push` 入力を true にすると `:edge` と `sha-<commit>` で push

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

---

## 残タスク

- **dotfiles の後付けスクリプトへの移管**（別リポジトリ）
  - `starship` / `helix` / `micro` / `eza` / `bat` / `fzf` / `delta` / `herdr` / `ax` の導入
  - 現行 base の `/etc/zsh/zshrc` にあった starship 初期化と fzf keybinding を `~/.zshrc` へ
  - `EDITOR` / `VISUAL` の設定
  - `~/.zshrc` の冒頭に `[[ -o interactive ]] || return` のガードを入れる。
    `~/.zshenv` に書くと全起動で読まれて非対話シェルが壊れる
- **`ARG EGRESS_GUARD_VERSION` の更新運用**。egress-guard を上げるには base の
  再ビルドが要る。Renovate を入れていないため手動。上げ忘れの検知手段はまだない
- **`NET_RAW` の要否確認**。egress-guard の実装が確定したら、本当に必要かを再確認し、
  不要なら雛形の `--cap-add=NET_RAW` を落とす
- **既存プロジェクトの移行**。このリポジトリ自身の `.devcontainer/` と
  `templates/devcontainer/` はまだ旧構成のまま
