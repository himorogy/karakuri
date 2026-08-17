# ホスト側ツールの配布設計

status: draft (rev.1)

対象は `images/runtime-base/templates/` に置いてある、**ホスト上で実行される部品**の配布方式です。`docs/prod-secret-isolation-design.md`（以下「本設計書」）が定義した broker 契約・注入経路・起動ラッパーは、そのどれもがホスト側で動きます。しかし本設計書はそれらの**配り方**を決めていません。「参考実装をコピーして使う」とだけ書かれた状態で、コピー先での版管理・改竄検出・呼び出し規約の共通化がすべて利用者の裁量に落ちています。この文書はそこを埋めます。

決定には `H1` 〜 `H6` の番号を振ります。本設計書へ統合する際に `D` 番号へ移す前提の暫定記号です。出荷物（`templates/` 配下・各 README）にはこの記号を書きません（本設計書 §4.8 の規約）。

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

- `pf` / `clean-pf` — SSH port forwarding の張り直しと後始末
- `dev-inject` — 項目名の組み立てと compose project 名の規約を含む注入コマンド
- `prod-run` — prod タスクの実行
- `prod-base` / `prod-shell` — 対話 prod 作業の二段構え（本設計書 §6.4）

利用側に残す設定は環境変数で外に出します。

- `KARAKURI_BW_BIN` — bw 実行ファイルの絶対パス
- `KARAKURI_ORG` — GitHub org（`prod-run` の第 1 引数を省略できるようにする既定値）
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

### 5.3 補足

この問題は H3 の関数ファイル化の前提です。誤った実装を共通化すると、全利用者に配ることになります。

---

## 6. H5: リリース済みイメージの digest をリポジトリに記録する

### 6.1 決定

`templates/host/compose.prod.yaml` の `image:` に書かれている `REPLACE_WITH_ACTUAL_DIGEST` を、リリース時に確定した実 digest で埋められるようにします。

段階を分けます。

**段階 1（この設計の範囲）** — リリースタグに対応する digest を、リポジトリ内の追跡ファイルとして記録します。`.github/workflows/runtime-base.yml` は push 後に digest を得ているため、リリースノートまたはリポジトリ内のファイルへ出力できます。利用側は clone したタグの記録を見て compose ファイルへ転記します。

**段階 2（将来）** — テンプレート内の digest を CI が自動で埋めます。digest はビルド後に確定するため、タグを打った後にコミットを積む形になり、タグとコミットの前後関係が反転します。この扱いを決めるまでは段階 1 に留めます。

### 6.2 根拠

H1 の唯一の弱点は「動かすイメージの digest とツールの版が人任せ」でした（却下した A 案だけがこれを構造的に解決していました）。タグを checkout しただけで対応する digest が手に入る状態にすれば、この弱点は消えます。

段階 1 でも、利用者が digest を探しに GHCR のパッケージ画面へ行く必要がなくなります。転記そのものは残りますが、転記元が clone 内にある状態と、外部サイトにある状態とでは、間違いの起きやすさが違います。

---

## 7. H6: 「リポジトリ内から実行するな」の文言を精密化する

### 7.1 問題

`prod-run.sh` と `dev-inject.sh` の冒頭には次の警告があります。

> このファイルをリポジトリ内から実行するな。

H1 を採ると、利用者は `~/.config/karakuri` という clone、すなわちリポジトリの中からこれらを実行することになります。文言上は正面から抵触して見えます。

### 7.2 決定

禁止の対象を「dev container へ bind mount される workspace」と明示します。

禁止の実質的な根拠は、同じコメントが続けて説明しているとおり「dev workspace はホストに bind mount されているため、そこに置いたスクリプトを dev container 内のエージェントが書き換えられる」という点にあります。karakuri の別 clone は bind mount されず、この経路が存在しません。

文言だけの修正ですが、放置すると「設計書の指示に反する運用」に見える状態が常態化します。規約が守られているかどうかを読んで判断できなくなることが、規約そのものより先に壊れます。

---

## 8. 実装順序

H4 → H2 → H3 → H1 → H5 → H6 の順とします。

H4 を先頭に置くのは §5.3 の理由です。誤ったコンテナ特定を共通化する前に直します。

H2（分割）は H3（関数ファイルの新設）より先に行います。分割後の位置へ直接置けば、参照の書き換えが一度で済みます。

H1（配布方式）は H2 と H3 が終わってから案内します。分割前の構成を前提にした手順を案内すると、直後に書き換えることになります。

H5 と H6 は独立しており、順序に制約はありません。

未決として残るのは H5 の段階 2（テンプレート内 digest の自動埋め込み）のみです。タグを打った後に digest が確定するため、タグとコミットの前後関係が反転します。この扱いを決めるまで段階 1 に留めます。
