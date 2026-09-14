# 規約

## README の機能節

README（公開面の使い方）が機能を説明する節は、次の3要素を持つ。

- **何のために** — その機能が無いと何が起きるかを1〜2文で書く。必須。個別の論点へ潜ったあとに戻る先であり、利用者が「使うかどうか」を判断する材料でもある
- **どう動くか** — 仕組みの概説。利用者が判断を誤る余地がある場合だけ書く。要否を判断するのは人間である
- **保証** — 保証台帳 `docs/guarantees.md` の該当節への参照。必須

規則は8つ。

- **「何のために」には前提を含める。** 何かを打ち消す・塞ぐ機能は、打ち消す相手を書かなければ
  目的が読めない。相手が外部の道具であればその名前と観測した挙動を書く（採用している道具の名前は
  持ち込み禁止の対象外である）。相手の挙動は変わりうるので、観測した時点は正本の側——制約を
  書いている場所——に残す
- **参照はテストファイル名で書く。** 台帳の見出しに付く連番は節の挿入でずれるため、番号にもアンカーにも依存させない
- **未検証の約束（`テスト困難`）に着地する機能は、その約束の起源チケット id で参照する。**
  裁可済みの節ではないので、指せるテストファイルが無い。`tickets/done/<id>.md` は git 管理下に
  あり、到達性はテストファイル名と変わらない
- **`テスト未作成` に着地する機能と、台帳に行が無い振る舞いは README に書けない。** 書きたければ
  先にテストを足す（`type: test` のチケット）。README の圧縮が、テストを書く引き金になる
- **1つの機能が複数の台帳節に着地してよい。** 台帳の索引はテストファイル単位であり、機能単位ではない
- **参照は README から台帳への片方向。** 台帳から README へは張らない。台帳を現在形の事実の列に保つため
- **台帳の行が README のどこからも参照されないことは正常である。** 台帳は公開面に現れない保証も持つ
- **節が肥大したら `docs/features/<name>.md` へ分離する。** 分離後も README には3要素を残し、移すのは「どう動くか」の詳細だけ

## 解説の正本

同じ仕組みの解説が複数のファイルへ散る場合、正本は**制約を書いている場所**に置く。他は自分の
1行の理由だけを持ち、正本をパスで指す。距離が近いほど、実装を変える人の目に入る。

- **正本** — 制約の実体があるファイル。打ち消しなら打ち消しを書いている場所。打ち消す相手の挙動、
  観測した時点、なぜその手段でなければ効かないかを持つ
- **個々のスクリプト** — その1行がそう書かれている理由だけ。経路全体の解説は持たない
- **README** — 機能節の3要素だけ。詳細は正本を指す
- **台帳とテストが固定している事実は、散文で持たない。** 正本にも書かない

## 環境変数の置き場

devcontainer の環境変数は compose の `environment:` に置く。イメージの `ENV` に置くのは
**利用側が変える前提が無いもの**だけである。判定は「固定する必然性があるか」ではなく
「利用側が変えるか」で行う。

前提として、コンテナは devcontainer ツール（CLI か VS Code 拡張）で作る。素の
`docker compose up` は `features`・`postCreateCommand`・`postStartCommand` を飛ばし、
egress-guard が適用されないコンテナを作るため支援しない。この前提の下では、イメージの `ENV` も
compose の `environment:` も等しく SSH セッションへ届く（機構は
`images/devcontainer-base/PORT-FORWARDING.md`「前提: コンテナは devcontainer ツールで作る」が正本）。

イメージの `ENV` に置くもの:

- `LANG` / `LC_ALL` / `TZ` / `PNPM_HOME` / `NPM_CONFIG_PREFIX` / `PATH` / `SHELL` —
  イメージの構造とロケール
- `GIT_ASKPASS` と `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `VALUE_0` / `KEY_1` / `VALUE_1` —
  変えられると認証がホスト側の資格情報へ落ちる。生死は `git-auth-check` が対話シェルの起動ごとに
  報告する
- `CRIT_NO_UPDATE_CHECK` — 起動の決定性と egress の予測可能性のための設計判断

compose の `environment:` に置くもの:

- `NODE_OPTIONS` — マシンのメモリ次第
- `CLAUDE_CONFIG_DIR` — 未設定だと `.claude.json` が `~/.claude` の**外**（`~/.claude.json`）に
  置かれ、`~/.claude` だけを named volume にしている構成ではコンテナの作り直しで失われる。
  既定値と同じパスに見えるが同じではない
- `CRIT_PORT` — 値はプロジェクトが決める。同時に開く別プロジェクトと衝突したらずらす
- `CRIT_PUBLIC_URL` と `CRIT_ALLOW_UNAUTHENTICATED_NETWORK` — 後者は機能の有効化ではなく
  **承認**である。crit は「広告 URL が非空」と「listen が非 loopback」の両方を同じフラグで
  解除するため、イメージに焼くと後者の拒否まで消える。承認はそれを必要とする判断と同じ場所に置く

## 出荷物のメッセージ言語

イメージに焼き込む出荷物が利用者へ出すメッセージ（標準出力・標準エラー）は英語で書く。受け取る側が
このリポジトリの外にいるためである。範囲は `images/*/bin`・`images/runtime-base/shims`・
`packages/env-guard` の `bin` と `hooks`
（`images/runtime-base/tests/shipped-symbols.test.sh` の lenient 検査が見ている範囲と同じ）。

`host-tools/` 配下（ホスト側ツールの usage を含む）はこの範囲の外である。

コード内のコメントは日本語のままでよい。規約が縛るのは外へ出る文字列だけである。

## 配布物の実行可能性

**実行して使うかどうかは shebang の有無で表明し、ファイルの一覧を別に持たない。**
`images/runtime-base/tests/distributed-file-modes.test.sh` と
`.github/scripts/check-published-modes.sh` はどちらもこの規約に依存している——
検査の側は対象を1件ずつ列挙するチェックリストを持たない。列挙を持つのは宣言側の
`publishConfig.executableFiles` であり、そちらは更新漏れが起きる（`files` に
shebang 付きのファイルが増えたのに列挙へ足し忘れる形。現に env-guard の
`hooks/pre-commit` で一度起きた）。検査は shebang の有無と実際の mode を
突き合わせることで、その漏れを拾う。

**発見しにくい事実。** pnpm（2026-09-10 実測、pnpm 11.25.0）が publish 用の
tarball に入れる各ファイルの mode は、ソースの mode を読まずに決まる。読むのは
`package.json` の `bin` フィールドと `publishConfig.executableFiles` の列挙だけで、
どちらにも載っていないファイルは元が 755 でも 644 になる（同時点の npm 11.17.0 は
ソースの mode をそのまま使うため、この挙動は pnpm 固有）。したがって公開物の
mode は git index を見る検査（`distributed-file-modes.test.sh`）では担保できない。
担保しているのは tarball の中身を見る検査
（`.github/scripts/check-published-modes.sh`）で、`.github/workflows/release.yml` の
build ジョブが `pnpm pack` で作った tarball に対して呼ぶ。publish ジョブは
`needs: build` でこれに従属するため、検査は結果として publish より前に効く。
publish ジョブ自身に置かない理由は、`pnpm pack`（同時点、pnpm 11.25.0）が
`prepack` 等のライフサイクルスクリプトを無効化するオプションを持たないため
（`pnpm publish --ignore-scripts` とは異なる）。publish ジョブは `id-token: write`
を持ち、第三者のコードを一切実行しない方針を取っている（`docs/secure-publish.md`
§4.3）。
