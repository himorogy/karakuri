# ホスト側ツールの配布設計

status: draft (rev.4)

rev.4 の主変更（1 件）。**H7 を追加しました**（§7）— `compose.prod.yaml` をプロジェクトごとに分け、置き場所ごとホスト上の git リポジトリにします。ただしそのリポジトリはどの devcontainer にも mount しません。実機検証の過程で、このファイルだけが H1 の「手編集が `git status` に出る」の外にいることが問題になり、そこから「git 管理下に置けばよい」という素朴な答えが**検知と防止を混同している**ことが判明しました。エージェントが編集するリポジトリなら、それが workspace であれ dotfiles であれ防止は失われます。§7.2 に整理を置きました。

rev.3 の主変更（1 件）。H1 が決めていなかったタグの命名を確定しました（§2.1）— `host-tools-v*` 系列を新設します。イメージのリリースタグと分けるのは、`.dockerignore` が `templates/` を外しているためホスト側ツールの変更がイメージの中身を変えないからです。

rev.2 の主変更（2 件）。実装着手時の確認で判明したものです。

**1. H5 を「digest のリポジトリ記録」から「タグからの digest 解決操作の提供」へ変えました**（§6）。rev.1 の段階 1 は順序が閉じていませんでした — digest はビルド後に確定するため、タグのツリーに含めるにはタグの付け替えが要り、それは §2.4 でリスクとして挙げたものです。あわせて、タグから digest を 1 コマンドで解決できることを実測したため、記録する動機そのものが消えました。

**2. H4 に karakuri 側の独立した実装対象が無いことを明記しました**（§5.3）。誤ったコンテナ特定は利用者の `.zshrc` にあり、リポジトリ側の修正対象ではありません。H3 の関数ファイルへ織り込む形で実装されます。実装順序（§8）もこれに合わせました。

対象は `images/runtime-base/templates/` に置いてある、**ホスト上で実行される部品**の配布方式です。`docs/prod-secret-isolation-design.md`（以下「本設計書」）が定義した broker 契約・注入経路・起動ラッパーは、そのどれもがホスト側で動きます。しかし本設計書はそれらの**配り方**を決めていません。「参考実装をコピーして使う」とだけ書かれた状態で、コピー先での版管理・改竄検出・呼び出し規約の共通化がすべて利用者の裁量に落ちています。この文書はそこを埋めます。

決定には `H1` 〜 `H7` の番号を振ります。本設計書へ統合する際に `D` 番号へ移す前提の暫定記号です。出荷物（`templates/` 配下・各 README）にはこの記号を書きません（本設計書 §4.8 の規約）。

**利用側の運用そのものは範囲外です。** karakuri が配るものと、その配り方だけを決めます。受け取った側が dotfiles をどう構成するか、そこでどのツールを動かすかは利用者の責任であり、この文書は前提を置きません（§1.2 で現状の一例として参照はします）。

---

## 1. 現状

### 1.1 正本と、その届き方

正本は `images/runtime-base/templates/` の 8 ファイルです。イメージには含まれておらず（`images/runtime-base/Dockerfile` に `templates/` の `COPY` はありません）、GitHub 上のリポジトリにしか存在しません。

利用側への届き方は手動コピーです。`images/runtime-base/migration.md` は次のように案内しています。

```
cp images/runtime-base/templates/prod-run.sh ~/.local/bin/prod-run.sh
```

`example/README.md` も同様に「`templates/` のコピー」と明記しています。

### 1.2 コピー先で起きていること

実際の利用側では、コピーしたスクリプトを **dotfiles リポジトリに取り込み、そこから `~/.local/bin/` へ symlink する**運用になっています。さらに、スクリプトへ渡す環境変数の組み立てが `.zshrc` のシェル関数として手書きされています。

```zsh
dev-inject() {
  BROKER_BW_BIN=~/.local/bin/bw \
  BROKER_BW_ITEM=env/$1/shared/dev,env/_common/dev,env/$1/dev \
  DEV_BROKER=~/.local/bin/broker-bitwarden.sh \
  DEV_COMPOSE_PROJECT=$1-dev \
  dev-inject.sh
}
```

この関数の中身のうち、`env/<project>/shared/dev,env/_common/dev,env/<project>/dev` という項目名の並べ方も、`<project>-dev` という compose project 名の付け方も、`example/README.md` に書いてある karakuri 側の規約です。**規約は karakuri にあるのに、その実装は各利用者の `.zshrc` にある**という状態になっています。

### 1.3 何が問題か

二つあります。

**版ずれが検出できない。** コピーには版の刻印がなく、正本が更新されてもコピー側は気づけません。逆に、コピー側が手で編集されても誰も気づけません。secret の搬送路に対する改竄が、変更の痕跡を残さずに成立します。

**規約が三重に写されている。** karakuri の README、利用側の dotfiles、利用側の `.zshrc` の三箇所に同じ規約が散っています。karakuri 側で命名規約を変えたとき、追随すべき場所を利用者が自力で見つける必要があります。

---

## 2. H1: 配布方式は固定パスへの浅い clone とする

### 2.1 決定

利用側は karakuri をタグ指定で clone し、dev workspace の外にある固定パスへ置きます。

```
git clone --depth 1 --branch <tag> https://github.com/himorogy/karakuri.git ~/.config/karakuri
```

`~/.local/bin/` への symlink、または `PATH` への追加でコマンドとして解決できるようにします（H3 で扱う関数ファイルが両方を吸収します）。

更新は明示的な fetch と checkout のみで行います。`git pull` による暗黙の追随はしません。

**タグは `host-tools-v*` 系列を新設します。** イメージのリリースタグ（`runtime-base-v*`）とは別系列にします。`.dockerignore` が `templates/` をビルドコンテキストから外しているため、ホスト側ツールを変更してもイメージの中身は変わりません。同じ系列を使うと、内容の変わらないイメージのマルチアーキビルドが毎回走ることになります。

系列を分けても H5 は成立します。compose ファイルへ書く digest はイメージのタグから解決する操作で引くので（§6.1）、ホスト側ツールの版がイメージのタグと揃っている必要がありません。

`host-tools-v*` はどのワークフローのトリガにも一致しません（`runtime-base-v*` / `devcontainer-base-v*` / `@himorogy/*@*` のいずれでもない）。タグを打っても CI は動かず、リポジトリのある時点に名前が付くだけです。

### 2.2 根拠

**コピーが一つも生まれません。** 利用側にあるのは正本と同じ git オブジェクトです。この文書が解こうとしている二重管理は、コピーを版で管理することではなく、コピーを作らないことで消えます。他の候補（後述）はいずれも「コピーは作るが版は固定する」に留まります。

**手編集が `git status` に出ます。** 改竄検出のための機構を別途作る必要がありません。secret 搬送路の完全性を、既に手元にある道具で継続的に確認できます。

**更新の確認が 1 コマンドです。**

```
git -C ~/.config/karakuri fetch --tags
git -C ~/.config/karakuri log --oneline HEAD..origin/main -- images/runtime-base/templates/
```

**前提ツールが git だけです。** 追加の CI もパッケージレジストリも要りません。

**compose テンプレートが同じ経路で来ます。** `templates/compose.prod.yaml` もホスト側に置く必要のあるファイルです（`prod-run.sh` の `PROD_COMPOSE_FILE` が指す先であり、`example/README.md` が workspace の外への配置を必須としています）。配布経路を一本にできます。

### 2.3 却下した候補

**A. runtime-base イメージへ同梱し `docker cp` で取り出す。**

`docker create` してから `docker cp` する形であれば、コンテナを起動せずに取り出せるため、entrypoint も shim も走りません。副作用の少なさは魅力があり、何より **`compose.prod.yaml` に書いた digest と同じ digest からツールを取り出せる**という、この案だけが持つ性質があります。

却下の理由は三つです。第一に、取り出しに digest が必要です。人間が版を認識する単位はタグであり、README に書いた digest は更新のたびに古くなります。第二に、ホスト側ツールだけを直したい場合でもイメージの再ビルドと再 pull が要ります。第三に、初回セットアップの順序がねじれます — compose ファイルを取り出すためにイメージが必要で、そのイメージの digest は compose ファイルに書く、という往復が発生します。

digest 一致という利点は H5 で別途回収します。

**B. dotfiles から karakuri を submodule 参照する。**

版は commit sha で固定でき、diff も見えます。ただし利用側の dotfiles に他リポジトリが混ざります。ホスト側ツールを dotfiles に置く必然性がないという判断（利用側の評価）と逆行するため採りません。

**C. GitHub Release の tarball を SHA-256 照合して取得する。**

`broker-bitwarden.sh` 冒頭が案内している bw の入手手順とまったく同じ作法であり、一貫性はあります。しかし取得のたびに curl・照合・展開の三手順を踏む必要があり、展開先を git 管理下に置かない限り手編集も見えません。リリースワークフローの追加工数に対して、H1 より優れる点がありません。

**D. npm パッケージとして配る。**

公開経路の堅さでは最有力です。`.github/workflows/release.yml` は OIDC の trusted publisher・`environment: npm-publish` による人間の承認ゲート・`--ignore-scripts` を備えており、`.github/workflows/monitor.yml` が経路外の公開を日次で検出します。provenance も生成されます。

それでも却下します。決定的なのは**グローバルインストールが node のバージョン管理と結合する**ことです。`broker-bitwarden.sh` は bw の npm 版を非推奨とする理由の一つに「nodenv 等の環境では node 版ごとのインストールになり、node を切り替えると消える」を挙げています。同じ問題がそのまま当たります。prod の起動ツールが node の切り替えで黙って消えるのは、運用として受け入れられません。

副次的な理由として、ホストに node がある前提を置くことになります（dev の実行環境はコンテナ内なので、この前提は弱い）。またグローバルインストール先は git 管理外であり、手編集の可視化が失われます。

### 2.4 残るリスクと緩和

**clone 内のコードを実行することになります。** `~/.config/karakuri` は dev workspace ではなく、dev container へ bind mount されないため、本設計書 §2.1 の信頼境界（dev container を信頼しない）は保たれます。ただし detached tag への固定を外して `main` を追随させると、未リリースのコードを prod 経路で実行しうるため、更新は明示的な checkout のみとします。

**タグの付け替えを検出できません。** 軽量タグは後から動かせます。`prod-run.sh` が `GIT_REF` に完全な commit sha を要求しているのと同じ論理がここにも当たります。clone 後の `git rev-parse HEAD` を利用側で記録しておけば、次回の checkout で変化が見えます。強制はしませんが、`migration.md` で案内します。

---

## 3. H2: `templates/` を配置先で分割する

### 3.1 決定

現在の `templates/` を、ファイルの置き場所によって二つに分けます。

```
templates/host/       ホストの固定パスへ置くもの
  broker-bitwarden.sh
  broker-macos-keychain.sh
  broker-macos-keychain-set.sh
  dev-inject.sh
  prod-run.sh
  compose.prod.yaml
  karakuri.sh              (H3 で新設)

templates/project/    プロジェクトのリポジトリへ置くもの
  env-guard.conf
  env-guard.yml

templates/tests/      現状維持
```

### 3.2 根拠

`compose.prod.yaml` を `host/` に置く点だけ補足します。名前から「プロジェクトのリポジトリに置くもの」に見えますが、`prod-run.sh` 冒頭が「compose ファイルのパスもこのファイル自身の場所からのリポジトリ相対推測をしない」と述べ、`example/README.md` が workspace の外への配置を必須としているとおり、これはホスト側のファイルです。分類を名前ではなく配置先で切ることで、この誤解が構造的に起きなくなります。

H1 と組み合わせると、利用側の `PATH` 追加は `~/.config/karakuri/images/runtime-base/templates/host` の一箇所で済みます。

### 3.3 波及

パスを参照している箇所の書き換えが要ります。

- `package.json` の `lint:sh:images` と `test`（`templates/*.sh` と `templates/tests/*.sh` を直接列挙）
- `images/runtime-base/tests/shipped-symbols.test.sh` の `TEMPLATE_FILES`
- `images/runtime-base/tests/verify-docker.sh`（`templates/compose.prod.yaml` と `templates/prod-run.sh` を複数箇所で参照）
- `images/runtime-base/migration.md`、`images/runtime-base/README.md`、`example/README.md` の案内

---

## 4. H3: 呼び出し規約を関数ファイルとして配る

### 4.1 決定

`templates/host/karakuri.sh` を新設し、利用側の `.zshrc` / `.bashrc` からは 1 行の `source` だけを書く形にします。

```sh
. ~/.config/karakuri/images/runtime-base/templates/host/karakuri.sh
```

このファイルが提供するもの:

- SSH port forwarding の張り直しと後始末
- 項目名の組み立てと compose project 名の規約を含む注入コマンド
- prod タスクの実行と、対話 prod 作業の二段構え（本設計書 §6.4）
- タグから image digest を解決する操作と、compose ファイルの digest との照合（§6.1）

関数名は §4.4 で決めます。

利用側に残す設定は環境変数で外に出します。

- `KARAKURI_BW_BIN` — bw 実行ファイルの絶対パス（PATH 上の解決に任せない。現在の推奨配置は
  `~/.dev-broker/bw` のような PATH の外で、バージョンマネージャの shim 等 PATH 上で先に来る
  ものに broker の呼び先が奪われないようにするため）
- `KARAKURI_ORG` — GitHub org。**任意**。扱う org が一つに定まる場合だけ設定し、複数あるなら設定しない（リポジトリは `<org>/<repo>` の 1 引数で毎回渡せる。§4.3 の引数形式を参照）
- `KARAKURI_PROD_COMPOSE` — `compose.prod.yaml` の配置先

### 4.2 根拠

利用側の `.zshrc` に書かれている内容を分類すると、大半が karakuri 側の規約です。

**完全に共通** — `pf` / `clean-pf` はプロジェクトに依存しません。`images/devcontainer-base/PORT-FORWARDING.md` は `~/.ssh/config` の設定（`ControlPath ~/.ssh/cm-%n` を含む）を案内していますが、それを操作する側は案内していません。利用側の `clean-pf` が `~/.ssh/cm-devc-*` を走査しているのは、この文書が定めた `ControlPath` の規約に依存した実装です。規約を持っている側が操作も提供すべきです。

**規約が karakuri 側にある** — `dev-inject` / `prod-run` / `prod-base` / `prod-shell` の中身は、broker 項目の命名規約・compose project 名の規約・二段構えの手順のいずれも `example/README.md` と本設計書が定めたものです。

**利用側に残すべき** — bw のパス、org 名、compose ファイルの配置先。これらは環境そのものであり、karakuri が決められません。

**判断が要る** — 利用側の `prod-run` には `pnpm install --frozen-lockfile && pnpm <task>` が埋め込まれています。runtime-base は pnpm を前提としたイメージなのでこの既定は妥当ですが、`prod-run.sh` に任意のコマンドを渡す余地は残す必要があります。既定を pnpm タスクとしつつ、生のコマンドを渡す経路を別名で用意します。

### 4.3 実装上の制約

**bash と zsh の両方で動くこと。** 利用側の `prod-run` は `${(j: :)argv[4,-1]}` という zsh 固有の記法を使っています。`"${@:4}"` に置き換えれば両方で動きます。本設計書 §1 が副次目標に置いている「`@himorogy` 以外の org への流用」に効きます。

**broker 実装への依存を分離すること。** 上記の関数群は Bitwarden broker を前提とした環境変数（`BROKER_BW_ITEM`）を組み立てます。broker は差し替え可能という契約（`broker-macos-keychain.sh` 冒頭）があるため、broker 固有部分は関数ファイル内で分離し、他の broker を使う利用者が置き換えられる形にします。

**`source` されるファイルであり、実行されるファイルではありません。** `set -euo pipefail` を書くと利用者の対話シェルに副作用が出ます。各関数の内部で完結させます。

### 4.4 関数名は接頭辞付きとし、短縮は利用者の alias に委ねる

提供する名前は次のとおりです。

```
karakuri-pf            karakuri-clean-pf
karakuri-dev-inject
karakuri-prod-run      karakuri-prod-exec
karakuri-prod-base     karakuri-prod-shell
karakuri-image-digest  karakuri-check-image
```

根拠は三つです。

**利用者の名前空間を占有しません。** `source` される側が `pf` や `prod-run` のような一般的な名前を取ると、利用者の既存の関数やコマンドを黙って覆います。上書きされた側は「なぜか挙動が変わった」としてしか観測できません。

**`karakuri-` まで打って補完すると、提供されているコマンドが一覧で出ます。** 文書を引かずに何があるか分かる状態は、接頭辞の副産物ではなく採用理由の一つです。

**短縮は利用者が自由に付けられます。** 対話シェルの alias は関数に対しても働き、引数もそのまま渡ります。karakuri 側が短い名前を先取りすると利用者は元に戻せませんが、長い名前を配れば利用者はいつでも短くできます。非対称なので、戻せる側を既定にします。

関数ファイルの末尾に、推奨する alias の例をコメントとして置きます。利用者が `.zshrc` へ写せる形にしておけば、短縮のためだけに関数定義を読み直す必要がなくなります。

### 4.5 prod タスクの既定は pnpm とし、環境変数で上書きできるようにする

既定は現在の利用側実装と同じ `pnpm install --frozen-lockfile && pnpm <task>` です。runtime-base は pnpm を前提としたイメージであり、既定として妥当です。

上書きは二つの環境変数で行います。

- `KARAKURI_PROD_INSTALL` — 既定は `pnpm install --frozen-lockfile`。空文字を設定すると install 段を省きます
- `KARAKURI_PROD_RUN` — 既定は `pnpm`。タスク名の前に置くコマンド（`npm run` / `make` など）

タスクランナーを一切挟まずに生のコマンドを渡す経路として `karakuri-prod-exec` を別に用意します。これは引数をそのまま `prod-run.sh` へ渡します。

**実装上の注意** — install 段とタスクを `&&` で繋ぐために `sh -c` へ文字列として渡す形になり、タスク名に空白やメタ文字が入ると意図と違う解釈になります。ホスト上で人間が打つコマンドなので攻撃面ではありませんが、引用符の付け忘れが prod で別のコマンドを走らせる事故にはなります。`KARAKURI_PROD_INSTALL` が空の場合は `sh -c` を経由せず引数を配列のまま `prod-run.sh` へ渡し、連結が必要な場合にだけ `sh -c` を使う実装にします。`karakuri-prod-exec` は常に配列のまま渡します。

### 4.6 範囲に含めないもの

**`~/.ssh/config` の生成や配布はしません。** `images/devcontainer-base/PORT-FORWARDING.md` が設定例を示しており、`karakuri-pf` / `karakuri-clean-pf` が依存しているのはそのうち `ControlPath ~/.ssh/cm-%n` の規約だけです。`LocalForward` に並べるポートも `HostName` に書くコンテナ名もプロジェクト固有であり、生成しても利用者が全面的に書き換えることになります。書き方の参考を示すに留めます。

---

## 5. H4: compose project 名をプロジェクトごとに分ける

### 5.1 問題

利用側の `prod-shell` は次のようにコンテナを特定しています。

```zsh
docker exec -it -w /src "$(docker ps -q --filter name=prod-run | head -1)" bash
```

`PROD_COMPOSE_FILE` は全プロジェクトで同一のファイル（`~/.config/prod-run/docker-compose.prod.yaml`）を指しています。compose project 名は compose ファイルの所在から導かれるため、**どのプロジェクトの prod を起動しても同じ project 名になります**。結果として `--filter name=prod-run` は複数プロジェクトのコンテナに一致し、`head -1` がそのうち一つを黙って選びます。

`prod-base` で二つのプロジェクトの prod を同時に立てている状況で `prod-shell` を打つと、意図しない側の prod 環境に入ります。入った先には別プロジェクトの secret が注入済みであり、`/src` には別プロジェクトのコードが checkout されています。**選択が黙って行われるため、入った本人が気づけません。**

### 5.2 決定

`COMPOSE_PROJECT_NAME` をプロジェクトごとに振り、`prod-shell` は compose 経由でコンテナを引きます。

- `prod-run` / `prod-base` は `COMPOSE_PROJECT_NAME=prod-<project>` を設定して `prod-run.sh` を呼ぶ
- `prod-shell` は `docker compose -p prod-<project> -f "$KARAKURI_PROD_COMPOSE" ps -q prod` でコンテナを引き、該当が 0 件なら明示的に失敗する（`head -1` による暗黙の選択をしない）
- `prod-shell` はプロジェクト名を引数に取る（省略時に「一つしかないだろう」と仮定しない）

該当が複数件ある場合も失敗させます。`dev-inject.sh` が複数一致を検出して止めている（同スクリプトの「cannot decide which one to inject into」）のと同じ扱いです。secret を持つコンテナの特定を推測で行わない、という一貫性を取ります。

### 5.3 実装対象

この決定に対応する karakuri 側の実装対象は、H3 の関数ファイルだけです。誤ったコンテナ特定は利用者の `.zshrc` にあり、karakuri のリポジトリには修正すべきコードがありません。関数ファイルを書くときに正しい形で書く、というのがここでの実装になります。

**利用側には、関数ファイルが届くまでの間の危険が残ります。** 現在の `prod-shell` は複数プロジェクトの prod を同時に立てた状態で誤ったコンテナを選びます。この文書は利用側の運用を範囲外としていますが、既知の危険であるため、H3 の提供までは同時起動を避けるか、利用者自身の関数を先に直す必要があります。

---

## 6. H5: image の pin はタグから digest を解決する操作として提供する

### 6.1 決定

digest をリポジトリに記録することはしません。`templates/host/compose.prod.yaml` の `REPLACE_WITH_ACTUAL_DIGEST` はプレースホルダのまま残します。

代わりに、タグから digest を解決する操作を H3 の関数ファイルで提供します。

- `karakuri-image-digest <tag>` — 指定タグの digest を解決し、compose ファイルへ貼り付けられる `image:` 行の完成形を出力する
- `karakuri-check-image <tag>` — 現在の `$KARAKURI_PROD_COMPOSE` に書かれている digest が指定タグのものと一致するか検査する。不一致なら非ゼロで終了する

解決手段は `docker buildx imagetools inspect <ref> --format '{{.Manifest.Digest}}'` です。

**compose ファイルの自動書き換えはしません。** このファイルは prod の防御（`read_only`・tmpfs の記法・`cap_drop` など）を宣言している中心的なファイルであり、`sed` で機械的に触る経路を作ると、パターンの取り違えが防御を消す形で現れます。digest を出力して利用者が貼る形に留め、書き換えたかどうかは利用者の目を通します。

### 6.2 根拠

**記録案は順序が閉じませんでした。** digest はビルド後に確定します。タグのツリーに digest を含めるには「タグを打つ → ビルド → digest 確定 → コミット」という順になり、そのコミットは既に打ったタグの外側にあります。タグを付け替えれば入りますが、タグの付け替えは §2.4 でリスクとして挙げたものそのものです。「clone したタグから digest が手に入る」は、記録では達成できません。

**解決が 1 コマンドで済むなら、記録する必要がありません。** 記録案が消そうとしていたのは「利用者が GHCR のパッケージ画面まで digest を探しに行く」手間でした。これは解決コマンドで消えます。

**転記そのものも減ります。** 出力を `image:` 行の完成形にすれば、利用者が 64 桁の hex を写す作業はコピー操作に変わります。記録案では転記が残っていました。

**`karakuri-check-image` が版ずれの検出を担います。** H1 は clone 側のドリフトを `git status` で見ますが、compose ファイルに書かれた digest は clone の外にあるため git では見えません。ここだけは別の検査が要ります。

実測: タグ `1.2.2` から解決した digest は `sha256:dbb547457fa73f39cb9e030e41d016f8b6bab64cf9830b124dadce853597fa39` であり、`example/docker-compose.prod.yaml` に書かれている値と一致しました。

---

## 7. H7: compose ファイルはプロジェクトごとに分け、到達不能な場所で履歴を残す

### 7.1 問題

H1 が clone を選んだ利点は「手編集が `git status` に出る」ことでした。`compose.prod.yaml` だけがその外にいます。clone 内のファイルをそのまま使うことができないためです — `image:` の digest を書き換える必要があり、clone を汚すと改竄検出が常時汚れた状態になり、タグを切り替えたときに衝突します。

結果として、このファイルには変更履歴も改竄検出もありません。**prod の防御を宣言しているのはこのファイルです** — `read_only`・tmpfs の記法・`cap_drop`・`init: true`。`karakuri-check-image` は digest しか見ておらず、防御宣言の書き換えは素通りします。

### 7.2 検知と防止を混同しない

この問題に「git 管理下に置けばよい」と答えると誤ります。**検知は防止ではありません。** `git diff` に出るのは「後から見れば分かる」であって「書き換えられない」ではなく、エージェントが書き換えて commit すれば、人間がレビューしない限り正当な変更に見えます。

したがって、エージェントが編集するリポジトリ（プロジェクトの workspace も、dotfiles も）に置く案はいずれも防止を失います。dotfiles を「workspace ではないから安全」と扱うのは誤りで、そこにもエージェントが常駐しているなら、防止の強さはプロジェクトの workspace と変わりません。違うのは日常の作業対象に混ざるかどうかという運用上の差だけです。

**防止は到達不能にすることでしか得られません。**

### 7.3 決定

`compose.prod.yaml` はプロジェクトごとに分け、置き場所ごとホスト上の git リポジトリにします。**そのリポジトリはどの devcontainer にも mount しません。**

```
~/.config/prod-compose/        ホスト上の git リポジトリ。どこにも mount しない
  <repo>.yaml
```

`KARAKURI_PROD_COMPOSE_DIR` にこのディレクトリを設定すると、prod 系の関数が repo 名から対応するファイルを引きます。従来の単一ファイル運用（`KARAKURI_PROD_COMPOSE`）も互換のため残し、両方設定されていれば DIR を優先します。

到達不能なので改竄検出は不要になり、git 管理の役割は**変更履歴**だけになります。digest をいつ上げたかが追えれば十分で、そのために規律を要求することもありません。

### 7.4 副次的な効果

`karakuri-check-image <tag>` は、DIR 運用のときディレクトリ内の全ファイルを検査します。どのプロジェクトが古い digest のままかが一覧で出ます。1 枚を共有していた頃はこの問いが存在しませんでしたが、分けた以上は必要になります。

### 7.5 認識している限界

複数プロジェクトの履歴が 1 つのリポジトリに混ざるため、プロジェクト単位の監査には使いにくくなります。個人の運用を前提として受け入れます。分けるなら、リポジトリをプロジェクトごとに作るか、コミットメッセージに規約を置くことになります。

---

## 8. H6: 「リポジトリ内から実行するな」の文言を精密化する

### 7.1 問題

`prod-run.sh` と `dev-inject.sh` の冒頭には次の警告があります。

> このファイルをリポジトリ内から実行するな。

H1 を採ると、利用者は `~/.config/karakuri` という clone、すなわちリポジトリの中からこれらを実行することになります。文言上は正面から抵触して見えます。

### 7.2 決定

禁止の対象を「dev container へ bind mount される workspace」と明示します。

禁止の実質的な根拠は、同じコメントが続けて説明しているとおり「dev workspace はホストに bind mount されているため、そこに置いたスクリプトを dev container 内のエージェントが書き換えられる」という点にあります。karakuri の別 clone は bind mount されず、この経路が存在しません。

文言だけの修正ですが、放置すると「設計書の指示に反する運用」に見える状態が常態化します。規約が守られているかどうかを読んで判断できなくなることが、規約そのものより先に壊れます。

---

## 9. 実装順序

H2 → H3 → H1 → H6 の順とします。H4 と H5 は独立した作業を持たず、H3 の関数ファイルに織り込む形で実装されます（§5.3 / §6.1）。

H2（分割）を先頭に置くのは、H3 の関数ファイルを分割後の位置へ直接置けば、参照の書き換えが一度で済むためです。

H1（配布方式の案内）は H2 と H3 が終わってから行います。分割前の構成を前提にした手順を案内すると、直後に書き換えることになります。

H6 は独立しており、順序に制約はありません。

H7 は上記が一通り動いた後、実機での検証を経て決まりました。H3 の関数ファイルへの追加として実装されます。節の並びは H5（digest）の直後に置いてあります — どちらも compose ファイルの扱いで、続けて読むほうが筋が通るためです。
