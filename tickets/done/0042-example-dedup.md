---
status: close
type: refactor
base: main
targets:
  - example/Dockerfile
  - example/docker-compose.yaml
  - example/docker-compose.prod.yaml
  - example/README.md
  - images/runtime-base/tests/template-sync.test.sh
  - images/runtime-base/tests/prod-compose-template.test.sh
  - images/runtime-base/tests/run.sh
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# example の複製を削除し、README から正本を指す

## 内容

### 現状

`example/` の 4 ファイルのうち 3 つが他所の複製で、3 つとも正本から乖離している。

- `example/Dockerfile` は `images/devcontainer-base/examples/Dockerfile` と完全に一致する
- `example/docker-compose.yaml` は `images/devcontainer-base/examples/docker-compose.yaml` の古い版で、L7 の一式（`depends_on`、proxy の環境変数、`NODE_USE_ENV_PROXY`、access log の volume、`egress-proxy` サービス）が無い
- `example/docker-compose.prod.yaml` は `host-tools/compose.prod.yaml` と image 行を除いて一致する。その image 行の digest は runtime-base v1.2.2 のもので、現行は v1.7.0

固有の内容を持つのは `example/README.md` だけである。

`images/runtime-base/tests/template-sync.test.sh` は prod の compose の二重化を意図したものとして守ってきた。
example 側は「読んだ人がそのまま写して起動できる実 digest」を持つ、という理屈である。
しかし検査が見るのは「解決済みの digest であること」までで、現行であることを保つ仕組みは無く、monitor の監視対象にも入っていない。
実際に 5 リリース分古いまま残り、写した人に古いイメージを使わせる経路になっていた。
守ろうとした性質が成り立っていないので、複製ごと消す。

### 変えるもの

1. `example/Dockerfile` / `example/docker-compose.yaml` / `example/docker-compose.prod.yaml` を削除する
2. `example/README.md` が削除する 3 ファイルを指している箇所を、正本のパスへ向け直す。該当は 3 箇所。あわせて、prod の compose の置き場所を古い書き方で残している 1 箇所を推奨配置にそろえる（PR レビューで追加）
   - 冒頭の対応表（9〜11 行付近）。「本ディレクトリ」の列が成り立たなくなるので、正本・コピー先・役割の 3 列にする。dev のイメージと compose の正本は `images/devcontainer-base/examples/`、prod の compose の正本は `host-tools/compose.prod.yaml`
   - 「`docker-compose.prod.yaml` に設定済み」（131 行付近。`init: true` の所在）→ `host-tools/compose.prod.yaml`
   - 「本ディレクトリの `docker-compose.yaml` に反映済み」（184 行付近）→ `images/devcontainer-base/examples/docker-compose.yaml`
   - 「推奨配置」節の本文「ホストの固定パス（`~/.config/<project>/`）に置く」（19 行付近）→ 同じ README の配置図と対応表に合わせて `~/.config/prod-compose/`
3. `images/runtime-base/tests/template-sync.test.sh` を `images/runtime-base/tests/prod-compose-template.test.sh` へ改名し、中身をテンプレート側の検査だけに縮める
   - 残すのは「`host-tools/compose.prod.yaml` の image がプレースホルダのまま」の検査。テスト名 "テンプレートの image はプレースホルダのまま" は変えない
   - この検査に検知能力があることを否定対照（実 digest を持つ版をその場で作って落ちることを確かめる）で持つ
   - 一致検査、example 側の digest の検査、example の存在検査、一致検査の否定対照は消える
   - 冒頭のコメントは、プレースホルダにしておく理由（差し替え忘れを pull の失敗として顕在化させる）だけにする
4. `images/runtime-base/tests/run.sh` の呼び出し（29〜31 行付近）を新しいファイル名に向け、コメントを検査の中身に合わせる
5. `docs/guarantees.md` の §12 を縮める（下記「保証」）。見出しは新しいファイル名と「配布テンプレートの compose」に直す。節番号は 12 のまま

`git mv` で改名するので、targets には旧パスと新パスの両方を載せている。
改名するテストは実行ビット（100755）を持つファイルで、新しいパスでも 100755 を保つ。モードの検査には旧パスの削除と新パスの作成の対として現れる。

### 経路の列挙

- 参照: 削除する 3 ファイルを名指しているのは `example/README.md` の 3 箇所と template-sync のテスト・`run.sh`・台帳 §12 だけ（`docs/archive/` と `tickets/done/` を除く）。`package.json` の `lint:sh:images` は `images/runtime-base/tests/*.sh` のワイルドカードなので、改名に追随して編集は要らない。`.github/workflows` からの参照は無い
- `example/README.md` への他ファイルからのリンク（`images/devcontainer-base/PORT-FORWARDING.md:69,98,172`、`images/devcontainer-base/examples/docker-compose.yaml:19`、`host-tools/tests/karakuri.test.sh:916`）は README が残るので壊れない
- 台帳の節番号: §12 の番号は変えないので、番号で節を指している箇所（`docs/guarantees.md:315` の §15、`:589` の §22・§24、候補層 0014 / 0018 / 0018a）は影響を受けない

### やらないこと

- `example/README.md` の本文の圧縮・文体の整理（root / example の束）。このチケットで触るのは上の 4 箇所だけ
- `DEVCONTAINER.md` と `example/README.md` の役割の整理。両者は相互リンクなしに並存しており、重なりは「dev の起動」付近だけ（root / example の束）
- `example/` のディレクトリ名の変更
- `images/devcontainer-base/examples/` と `host-tools/compose.prod.yaml` の中身

## 保証

### 新たに宣言する保証

- なし。既存の約束の縮小と検査の移し替えで、新しい振る舞いを差し出さない

### 維持する保証

§12 の次の行は、テストファイルの改名を挟んでも残す。

- 配布テンプレートのイメージ指定は実在する digest を持たず、プレースホルダのままである。実 digest を焼くと利用者の差し替え忘れが「起動はするが古いイメージ」として静かに通るため、取得の失敗として顕在化させる（テスト: "テンプレートの image はプレースホルダのまま"）

### 廃止する保証

§12 の次の 5 行を取り下げる。
利用例の compose（`example/docker-compose.prod.yaml`）そのものを削除し、二重化を解消するため。

- 配布テンプレートの compose と利用例の compose は、イメージ指定の行を除く全行が完全に一致する（テスト: "image 行を除く全行が一致する"）
- 二枚が別ファイルとして存在すること自体は意図的であり、統合はしない
- 利用例のイメージ指定は逆に、解決済みの digest を持つ
- どちらかのファイルが存在しなければ、検査は 0 を返さず失敗として終わる
- 一致検査に検知能力があることを、テンプレート本文に 1 行足した版をその場で作って毎回確かめる
