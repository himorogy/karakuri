# devcontainer-base 引き継ぎ資料

作成日: 2026-08-03
引き継ぎ先: ローカル Claude Code
成果物: 改訂版 `Dockerfile`（本資料と同時に出力）

---

## 1. 目的と背景

各プロジェクトの devcontainer が個別に Dockerfile を持っており、共通部分の改善
（例: `ipset add` に `-exist` を付ける）を全プロジェクトへ伝播させるのが辛い。
これを解消するため、GHCR に共通ベースイメージを置き、各プロジェクトは `FROM` で
参照する構成にする。

個人の開発設定（dotfiles、個人ツール）は既存の後付けスクリプト
（Mac → ssh → ホスト → `docker exec` でコンテナに注入）が担当済み。
本件の base はその守備範囲の**外側**を担う。

---

## 2. 層の分離（設計の骨格）

| 層 | 中身 | 手段 | 更新の伝播 |
|---|---|---|---|
| A | OS パッケージ、root 権限が要るもの、エージェントが直接使うもの | **base image** | `FROM` の更新 |
| B | 共通だが設定がプロジェクト別（egress-guard 等） | devcontainer Feature | **将来構想・今回は保留** |
| C | 個人の対話的体験にしか効かないもの | 既存の後付けスクリプト | 実行するだけ |
| D | npm で入るもの（Biome, dprint 等） | プロジェクトの devDependency | `package.json` |

### 収録判定基準

base に入れる条件は次のいずれか。

- npm では入らない（OS パッケージ、root 権限が要る）
- エージェントが直接使う（`ripgrep`, `jq`, `git`, `gh`, `dnsutils` 等）

入れない条件。

- 人間の対話体験にしか効かない → C（後付けスクリプト）
- npm で入る → D（devDependency）。base に焼くとバージョンがプロジェクトの
  `package.json` と乖離し、ローカルと CI でフォーマット結果が変わる
- プロジェクト固有 → プロジェクトの Dockerfile

---

## 3. 決定事項

| 項目 | 決定 | 根拠 |
|---|---|---|
| ベース元 | `node:24`（公式イメージ、現状維持） | `mcr.microsoft.com/devcontainers/*` は Oh My Zsh が入り、「shell 起動を速く保つため Oh My Zsh を入れない」という既存判断と衝突する。Debian からの自作は `node:24` が無償で提供するものの再実装になる |
| Node バージョン | base に単一固定 | 再現性が最も強い（イメージ digest が Node を一意に決める）。Radwisp の 510(k) 文脈で説明しやすい |
| Node の切替機構（mise 等） | **不採用** | ①コンテナ起動後に nodejs.org へのダウンロードが走り、egress-guard の設計思想（実効設定を root 固定・self-service 遮断）と衝突する ②再現性が `mise.toml` 側に移り base digest だけで環境が確定しなくなる ③shim 経由で PATH 解決が複雑になりエージェント運用のデバッグが困難になる |
| アーキ別タグ分岐 | 当面しない | Electron は自前の Node を内包するのでホスト Node はツールチェーンを動かすだけ。実際にはバージョンが割れにくい。割れた時点で `:1-node22` を切る |
| pnpm | base に pin（`10.30.0`） | 未 pin だとビルド日時で変わり、`packageManager` フィールドと乖離する |
| pnpm のプロジェクト別上書き | 可能だが**例外運用** | `devcontainer.json` の `build.args` は base イメージには届かない。プロジェクトの Dockerfile で入れ直す形になる（§6 参照） |
| 適用範囲 | 自分の org のプロジェクトのみ | 受託案件は対象外 |
| レジストリ | GHCR、**public** | pull 認証が不要になる。base は中立な開発基盤のみを収録するので公開して問題ない |
| タグ体系 | `:1` / `:1.4` / `:1.4.2` / `sha-<commit>` | |
| 参照方法 | 浮動タグ `:1` | digest pin はしない（下記トレードオフ参照） |
| Renovate | 導入しない | 自動 PR の運用負荷を嫌ったため。後から追加可能 |
| apt パッケージの pin | しない | |
| locale | `C.UTF-8`（`LANG` / `LC_ALL` 両方を明示） | 未設定だと `locale=POSIX` になり日本語入出力とソート順が不安定。エージェント運用ではソート順の決定性を優先 |
| TZ | `Asia/Tokyo`（ARG デフォルト） | 従来は build-arg 未指定時に `TZ=""` になっていた |
| Biome / dprint | base に入れない → devDependency | base とプロジェクトでバージョンがずれるとローカルと CI でフォーマット差分が出る。npm が既にバージョン管理機構を持っているので base に重複させると二重管理 |
| Starship | base から外す → 後付けスクリプト | 成果物に影響しない。設定（`starship.toml`）が個人固有で、バイナリだけ base に置くと半端な分割になる |
| crit | **base 残留** | エージェントとのやり取りの基軸に据えるため。Claude Code 連携がコンテナ内の CLI とローカル daemon を前提とする |

### 既知のトレードオフ（覆すときに読む）

**digest pin をしない選択について。** Radwisp は 510(k) / ISO 13485 の文脈で
「いつビルドしても同じ成果物」が要求されるため、本来は digest 固定が望ましい。
今回は運用負荷を優先して浮動タグ `:1` を選択した。規制対応で再現性の要求が
強まった場合は、Radwisp のみ digest pin + Renovate（`pinDigests: true`）に
切り替える。この変更は既存の Dockerfile に手を入れずに後付けできる。

**浮動タグ運用の必須設定。** ローカルに古い base が残っていると rebuild しても
更新されない。各プロジェクトの `devcontainer.json` に以下が必要。

```jsonc
"build": { "options": ["--pull"] }
```

これを忘れると「更新したのに反映されない」で時間を溶かす。

---

## 4. base から外すもの

| ツール | 移動先 | 備考 |
|---|---|---|
| `starship` | 後付けスクリプト | `~/.zshrc` に配置（§7 参照） |
| `helix` / `micro` | 後付けスクリプト | `EDITOR` / `VISUAL` の設定も後付け側へ移す |
| `eza` / `bat` / `fzf` | 後付けスクリプト | fzf の keybinding 読み込みも `~/.zshrc` へ |
| `herdr` / `ax` | 後付けスクリプト | |
| `delta` | 後付けスクリプト | git config（`core.pager`）が dotfiles 側にあるため |
| `postgresql-client` | プロジェクトの Dockerfile | Neon を使うプロジェクトのみ必要 |

**副産物**: これらを外した結果、最終ステージからアーキ分岐（`TARGETARCH` の
case 文）が完全に消える。マルチアーキビルドが素直になり、イメージも軽くなる。

---

## 5. 改訂版 Dockerfile の変更点

現行 Dockerfile からの差分は以下7点。

1. **crit をクロスコンパイル化**
   `FROM --platform=$BUILDPLATFORM` + `GOOS`/`GOARCH` 指定で、arm64 ビルド時の
   QEMU エミュレーションを回避。
   注意: `GOBIN` はクロスコンパイル時に使えない。出力先がネイティブ時
   `/go/bin/crit`、クロス時 `/go/bin/${GOOS}_${GOARCH}/crit` と変わるため、
   `find` で吸収して `/out/crit` に正規化している。

2. **locale / TZ を明示**
   `LANG=C.UTF-8`、`LC_ALL=C.UTF-8`、`ARG TZ=Asia/Tokyo` + `/etc/localtime` の設定。

3. **bash 履歴のバグ修正**
   現行版は `SNIPPET` 変数を定義した後どのファイルにも書き込んでおらず、
   bash 側の履歴永続化が機能していなかった（zsh 側のみ動作していた）。
   `/etc/bash.bashrc` への追記を実装。

4. **pnpm を pin**
   `ARG PNPM_VERSION=10.30.0` + `npm install -g pnpm@${PNPM_VERSION}`。

5. **sudoers の引数制限**
   `NOPASSWD: /usr/local/bin/init-project-firewall.sh ""` の `""` は
   「引数を取らない実行のみ許可」の意。実効設定を `/etc/egress-guard` に固定し
   探索を廃止した設計意図を、引数経由での設定差し替えを塞ぐことで sudoers 側でも
   担保する。

6. **対話ツール群の除外**（§4）

7. **`vim-tiny` を追加**
   `micro` を外すと `EDITOR` が実体のない参照になり、`git commit` や
   `rebase -i` が壊れる。最小の保険として `vi` を base に確保する。
   実際に使うエディタは後付けスクリプトが入れて `EDITOR` を上書きする。

---

## 6. 残タスク

### 6.1 GitHub Actions ワークフロー（最優先）

- `docker buildx` で `linux/amd64,linux/arm64` のマルチアーキビルド
- GHCR へ public で push
- タグ体系 `:1` / `:1.4` / `:1.4.2` / `sha-<commit>` の実装
  （`docker/metadata-action` の利用を想定）
- GitHub Actions のキャッシュ（`type=gha`）でビルド時間を抑える

### 6.2 プロジェクト側 `devcontainer.json` の雛形

盛り込む必要がある要素。

- `"build": { "options": ["--pull"] }` ← **必須**（§3 参照）
- `capAdd: ["NET_ADMIN", "NET_RAW"]`（egress-guard の実行に必要）
- `CRIT_PORT` のプロジェクト別設定と `runArgs` の `-p` 転送
- `containerEnv` による dotenvx の local/dev 復号キー注入
- `postStartCommand` での `sudo init-project-firewall.sh` 実行

### 6.3 後付けスクリプトへの移管

§4 のツール群をスクリプト側に移す。あわせて以下。

- 現行 base の `/etc/zsh/zshrc` にある starship 初期化と fzf keybinding の
  読み込みを `~/.zshrc` へ移す
- `~/.zshrc` の冒頭にガードを入れる（§7）
- `EDITOR` / `VISUAL` の設定を移す

### 6.4 未決定事項

- **base リポジトリの置き場所**。karakuri monorepo に
  `images/devcontainer-base/` として置く案が出ているが未確定。
  独立リポジトリにする場合、リポジトリ名は和語から採る方針
  （`@himorogy` = 神籬 に倣う）

---

## 7. Starship の非対話シェル対策

### 現状の理解

zsh の起動ファイルは読まれる条件が異なる。

| ファイル | 読まれるタイミング |
|---|---|
| `/etc/zshenv`, `~/.zshenv` | **すべての**起動 |
| `/etc/zsh/zprofile`, `~/.zprofile` | login shell |
| `/etc/zsh/zshrc`, `~/.zshrc` | **interactive shell のみ** |
| `/etc/zsh/zlogin`, `~/.zlogin` | login shell |

現行構成は `/etc/zsh/zshrc` に starship 初期化を置いているため、非対話シェルでは
読まれない。エージェントは通常 `bash -c` / `sh -c` で起動するため zsh 経路にも
入らない。**現状は安全**。

### 移管時の注意

後付けスクリプトで配置する際、`~/.zshenv` に書くと全起動で読まれて壊れる。
必ず `~/.zshrc` に置き、冒頭にガードを入れる。

```zsh
[[ -o interactive ]] || return
```

---

## 8. 検証チェックリスト

```bash
# 1. vi が利用可能か（vim-tiny が alternatives を登録しているかの確認）
docker run --rm <image> vi --version

# 2. 非対話シェルにプロンプト汚染がないか（余計な出力がなければ OK）
docker exec <ctn> zsh -c 'echo ---; git log --oneline -1; echo ---'

# 3. starship の precmd hook（非対話では空、-i 付きでのみ登録されるべき）
docker exec <ctn> zsh -c  'print -l $precmd_functions'   # 空
docker exec <ctn> zsh -ic 'print -l $precmd_functions'   # starship_precmd

# 4. エージェントが実際に使う経路
docker exec <ctn> bash -c 'echo $PS1'                     # 空

# 5. locale
docker exec <ctn> sh -c 'echo $LANG; locale'              # C.UTF-8

# 6. pnpm が packageManager と一致しているか
docker exec <ctn> pnpm --version                          # 10.30.0

# 7. sudoers の引数制限が効いているか（後者は拒否されるべき）
docker exec <ctn> sudo /usr/local/bin/init-project-firewall.sh
docker exec <ctn> sudo /usr/local/bin/init-project-firewall.sh --config /tmp/x

# 8. bash 履歴の永続化（現行版で壊れていた箇所）
docker exec <ctn> bash -c 'echo $HISTFILE'                # /commandhistory/.bash_history

# 9. マルチアーキ（両アーキで実行）
docker run --rm --platform linux/amd64 <image> crit --version
docker run --rm --platform linux/arm64 <image> crit --version
```

---

## 9. 参照

- egress-guard: `@himorogy/egress-guard`（karakuri monorepo）
  - 実効設定は `/etc/egress-guard` 固定、探索は廃止済み（コミット 865fee0）
  - ワイルドカードドメインは拒否
- 後付けセットアップスクリプト: dotfiles 内（`setup-devcontainer.sh` 系）
- 作業用ユーザーは `node`（UID/GID 1000、`node:24` 由来）
