---
status: open
type: fix
base: main
targets:
  - images/runtime-base/tests/verify-docker.sh
verify:
  - pnpm lint:sh
  - pnpm test
---

# verify-docker.sh を macOS ホストで GNU sed なしに走らせ、compose の後始末でネットワークを残さないようにする

## 内容

`images/runtime-base/tests/verify-docker.sh` は、ヘッダに「CI（ubuntu-latest）でも手元の macOS ホストでも同じスクリプトが走ることを狙っている」と書いている。
2026-10-15 に macOS ホストで runtime-base:2 を検収したとき、次の2つの問題でそのままでは走らなかった。

### 1. BSD sed で落ちる

macOS で引数なしに走らせると、`sed: invalid command code f` で止まる。

- スクリプトの `sed` 呼び出しは 10 か所ある（407・427・440・491・526・567・607・620・659・694 行）。
- どれも `sed -i <スクリプト> <ファイル>` の形をとる。
- BSD sed の `-i` は拡張子を必須の引数にとる。そのため、直後のスクリプトが拡張子として食われ、ファイルパスがスクリプトとして読まれる。
- macOS の一時ディレクトリは `/var/folders/...` にある。このパスがアドレス `/var/` とコマンド `f` に読まれたのが、上のエラー文面の出所と見ている。
  - 確かめたのはエラー文面だけである。この読み取りは推定で、BSD sed の版は未確認。
- 検収では GNU sed（Homebrew の gnu-sed）の gnubin を PATH の先頭に置いて回避した。

変えること:

- `sed` を使うすべての箇所を、GNU sed と BSD sed のどちらでも同じ結果になる形にする。macOS で GNU sed を入れなくても走るようにする。
- 置換の中身（何をどう書き換えるか）は変えない。
  - 427・440 行の改行入りの置換は、コメント（421〜423 行）が両対応の書き方だと明記している。この書き方は維持してよい。

### 2. compose_down が失敗を握りつぶし、ネットワークが溜まる

`compose_down`（771〜773 行）は `docker compose -f <file> -p <project> down -v` を打つ。

- `GIT_REPO` / `GIT_REF` を compose のプロセスに渡していない。
- 対象の compose ファイルは `${GIT_REPO:?…}` / `${GIT_REF:?…}` を持ち、compose はパースの時点でこれを展開する。
  - 根拠は `compose_run`（765〜768 行）のコメント。
- そのため、両方の変数が環境に無いと `down` はパースで失敗する。stdout・stderr・終了コードを捨てているので、失敗は表に出ない。
- 各テストの project 名は `verify-…-$$` で、実行のたびに変わる。片付かなかったネットワークは実行ごとに溜まる。
- 検収（Docker Desktop、版は未記録）では、何度か走らせたあとに `all predefined address pools have been fully subnetted` で止まった。
- ダミーの `GIT_REPO` / `GIT_REF` を環境に置くと回避できた。このとき 42 measurements、44 assertions passed、0 failed だった。

変えること:

- `compose_down` が、呼び出し側の環境に `GIT_REPO` / `GIT_REF` が無くても `down` を完走できるようにする。
  - `down` はコンテナを作らないので、値の中身は問わない。
- `down` が失敗したときは、その旨を stderr に出す。
  - 失敗しても、スクリプト全体の合否は変えない。後始末の失敗であって、検証項目の失敗ではないため。
  - 黙らせない理由は、今回の漏れが表に出ず、アドレス帯を使い切るまで気づけなかったことにある。

### 付随して直すもの

ヘッダ（11〜12 行）は「jq のような macOS に既定で入っていないツールには依存しない」と書いている。一方で、342〜345 行は jq を必須にし、無ければ exit 1 する。ヘッダの記述を実態に合わせる。

### 触ってはいけないもの

A11（2714 行付近）と A32・A33（3011・3019 行付近）は、`env -u GIT_REPO` / `env -u GIT_REF` で必須の変数を外し、compose が失敗することを確かめる否定対照である。これらの意図と挙動は変えない。

### やらないこと

- 途中で異常終了したときの後始末（EXIT trap で compose のネットワークや volume を片付けること）は足さない。
  - 今の trap は SCRATCH の削除だけを担う。各テストが自分で片付けるという設計（176 行のコメント）は維持する。
- 既に溜まっているネットワークの掃除手順は、スクリプトにも README にも書かない。
- macOS 上での動作を CI で検査する仕組みは作らない。GitHub Actions の macOS runner で docker を使えるかは未確認である。macOS での確認は検収で行う。
- bash 3.2（macOS の既定の bash）での互換は、検査の対象にしない。
  - scout の調査では非互換の構文は見つかっていない。ただし `set -u` の下での空配列の展開は未確認である。
  - 検収で落ちたら、別のチケットにする。
- `stat -c` などコンテナ内で実行するコマンドの GNU 依存は扱わない（ホストでは実行されない）。
- `packageManager: pnpm@12` の下で pnpm 10 系のホストの自動切り替えが壊れる件は扱わない。移行が完了すれば不要な記述になるため、見送りとした。

確かめること（検収で人間が見る）:

- macOS ホストで、GNU sed を PATH に置かず、`GIT_REPO` / `GIT_REF` も環境に置かずに `bash images/runtime-base/tests/verify-docker.sh ghcr.io/himorogy/runtime-base:2` が完走し、0 failed になる。
- 実行の前後で `docker network ls` を比べ、`verify-` で始まる project のネットワークが増えていない。

## 保証

### 新たに宣言する保証

- なし（検証用スクリプトの修正で、利用者に差し出している振る舞いに触れない）

### 維持する保証

- verify-docker.sh の測定と表明の内容（何を確かめるか）は変えない

### 廃止する保証

- なし
