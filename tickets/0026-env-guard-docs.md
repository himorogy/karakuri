---
status: open
type: docs
base: kuda/0025-current-docs-inventory
targets:
  - packages/env-guard/README.md
  - packages/env-guard/bin/env-guard-scan
  - packages/env-guard/bin/env-guard.js
  - packages/env-guard/hooks/pre-commit
  - packages/env-guard/tests/install.test.sh
  - docs/conventions.md
verify:
  - pnpm test
---

# env-guard の README を 3 要素へ圧縮し、コード内コメントを整理する

## 内容

記述整理をパッケージ単位で進める束の 1 枚目。順序は env-guard（このチケット）→ egress-guard → devcontainer-base → runtime-base + host-tools → root + example + .github。各枚は `docs/conventions.md` を targets に持つので直列に進め、次の枚は前の枚のブランチから切る。この枚では手法を校正する——README の各節を「載せる / 落とす」で判定し、残る節を conventions「README の機能節」の 3 要素（何のために / どう動くか / 保証）へ組み替え、README から落とした説明の正本になるコード内コメントを `kuda:comments` の分類で整理する。成果の指標は「文書の総量が減って情報が残る」こと。着手前の計測は README 216 行、コード内コメント 282 行。

**base が統合ブランチでない理由（feature ブランチ例外）。** 先行する 0024（host tools の移設）と 0025（現在形文書の archive 化）が PR レビュー待ちでマージされておらず、この変更は 0025 後の状態（設計書が `docs/archive/` にある）を前提にする。0025 のブランチを base にし、先行がマージされたら PR の宛先は main へ移る。

### 判定の門

行を残すかどうかは、置き場所を考える前に決める。次のどれかに当たる行は落とす。落とした行の中身は git 履歴と正本（`packages/env-guard/bin/env-guard-scan` と `bin/env-guard.js` の冒頭コメント）に残る。

- コードから読める
- 叩けば機械が教える（`env-guard --help` の usage、失敗時の出力）
- 台帳とテストが固定している（`docs/conventions.md`「解説の正本」——散文で持たない）

残る節は 3 要素にする。「何のために」は必須で、打ち消す相手（平文の env ファイルをコミットする事故）と前提（dotenvx で暗号化した `.env` と、その私鍵 `.env.keys`）を含める。「どう動くか」は利用者が判断を誤る余地がある行だけ。「保証」はテストファイル名で参照する（`images/runtime-base/tests/env-guard.test.sh` / `images/runtime-base/tests/hook.test.sh` / `packages/env-guard/tests/install.test.sh`）。台帳の節番号・`§`・「設計書」の語は README に書かない（npm で他組織へ渡る README であり、`images/runtime-base/tests/shipped-symbols.test.sh` が strict で検査する）。

### README の判定表（行番号は現在の README）

| 節（行） | 判定 | 行き先 / 理由 |
|---|---|---|
| 冒頭 3〜10（スキャナ 1 本、hook = staged / CI = tracked、同じ一覧なら一致） | 圧縮して残す | 「何のために」の段落。「1 本」である理由は正本 `bin/env-guard-scan` が持つ。バイト一致は `env-guard.test.sh` が固定するので保証参照へ。staged / tracked の違いだけは「hook は通ったのに CI で落ちた」を読むのに要るので「どう動くか」に 1 行 |
| 冒頭 12（実行時依存なし） | 落とす | `package.json` の dependencies とスクリプト冒頭から読める |
| 平文のまま置かれた env ファイル 18〜38 | 圧縮して残す | 4 種の行分類は落とす（コードと正本コメント）。既定の対象・許可リストは台帳が固定するので落とす。残すのは判断を誤る余地の 2 点だけ——行単位で判定する（暗号化済みファイルに平文を足しても検出する）/ `production.env` のように `.env` で始まらない名前は既定で対象外（`env-guard.conf` で足す） |
| 作業ツリーに置かれた `.env.keys` 40〜44 | 圧縮して残す | 「何のために」に前提を含める——dotenvx が私鍵の環境変数を持たないとき `.env.keys` へフォールバックする挙動を 1 文（観測は正本 `bin/env-guard-scan` が持つ）。「渡された一覧に依らずリポジトリ全体を見る」は、絞り込んでも検出される点で判断を誤る余地があるので 1 行。探索範囲の詳細は `hook.test.sh` が固定 |
| 値はログに出しません 46〜50 | 圧縮して残す | 導入判断の材料（CI のログへ secret が写らない）なので「何のために」に 1 文。`=` を含まない行の扱いと理由は落とす（台帳と正本） |
| コマンドとして 56〜71 | 残す（圧縮） | 公開面の使い方。スキャナは `--help` を持たず引数無しでは stdin を待つので、叩いても入力形式は分からない。2 つの例と npx で一度だけ走らせる例、リポジトリルートで実行すること、を残す。ルートで実行する理由の散文は 1 行に |
| pre-commit hook として 73〜82（導入 2 コマンド） | 残す | 使い方。simple-git-hooks を先に入れる指示を含む |
| 同 84〜90（「このコマンドがすること」1〜3 と理由） | 落とす | `env-guard --help` の usage が install と `--check` を説明し、`install.test.sh` が実体化の確認を固定する |
| 同 92〜100（冪等・衝突時の挙動・合成例） | 落とす | 衝突時の出力が現在の値・必要な値・合成例まで教える（`bin/env-guard.js` の `conflictReport`）。挙動は `install.test.sh` が固定 |
| 同 102〜110（`prepare` に simple-git-hooks） | 残す（2 行と JSON） | `.git/hooks/` は clone に付いてこない = 判断を誤る余地。npm の `prepare` は腐らないので観測した版は併記しない |
| 同 112〜116（`--check`） | 落とす | usage が教える。「コンテナの中と外」の行で 1 回だけ言及する |
| hook がスキャナを見つけられなかったとき 118〜122 | 落とす | 探索順はコードから読める。黙って通さないことは `install.test.sh` が固定。`PATH` を引かず自分の位置から解決する理由（ログインシェルと違う `PATH` で起動される GUI の git クライアントでも同じスキャナが走る）は正本 `hooks/pre-commit` のコメントへ移す（起草時は正本が既に持つと書いていたが、持っていなかった。レビューで判明） |
| `core.hooksPath` を直接使う方法 124〜134 | 圧縮して残す（2〜3 行。コマンド例は落とす） | `.git/hooks/` を丸ごと無視するのは git が強いる挙動で、husky 等を黙って壊す。プロジェクトの導入手順には使わない、と書く。イメージ側で使う用途の説明は runtime-base の README の領分なので、ここには書かない |
| コンテナの中と外で、効いているものが違う 136〜145 | 圧縮して残す（表は落とす） | `env-guard install` の「何のために」そのもの——無いとホストの git クライアントからの commit に hook が効かない。正本は `bin/env-guard.js` 冒頭コメント。コンテナ側で hook が効くことは runtime-base の未検証の約束（テスト困難）なので、保証は起源チケット id `0009-ledger-auth-and-shipped` で参照する（下記 conventions の追加規則） |
| 終了コード 149〜165 | 節ごと落とす | 0 / 1 の 2 値と「0 件検査の緑を区別する」は台帳とテストが固定し、正本コメントにもある。hook を組む側に要るのは「非ゼロ = 拒否」だけで、それは「何のために」に含まれる |
| `env-guard.conf` 169〜192 | 圧縮して残す | 書式は叩いても出ない（未知のディレクティブのエラーは有効な名前しか教えない）ので最小例を 1 ブロック。「1 行でもあれば既定を置き換える（追加ではない）」は判断を誤る余地なので 1 行。source / eval しない理由・ファイル名をドットで始めない理由・hook と CI が同じ設定を読む理由は落とす（正本 `bin/env-guard-scan` のコメントが持つ）。上書きできることと壊れた設定の扱いは台帳が固定 |
| 壊れた設定は既定へ倒れません 194〜200 | 節ごと落とす | 台帳とテストが固定。保証参照へ |
| 平文を見つけたら 204〜210 | 節ごと落とす | 検出時の出力が `dotenvx encrypt -f <file>` を教え、`.env.keys` の残留も検出時の出力が教える |
| ライセンス 214〜216 | 落とす | `package.json` の `license` から読める |

節の組み立て: 冒頭に「何のために」を 1 段落 → 機能節を 3 つ（スキャナ `env-guard-scan` / pre-commit hook / 導入コマンド `env-guard install`）。各節は「何のために」→「どう動くか」（判定表で残すとした行だけ）→「保証」。`env-guard.conf` はスキャナ節の「どう動くか」に入れる。見出しの語と文体は実行者に委ねる。

`.husky/pre-commit` と `.githooks/pre-commit` へのチェーン（現在の 75 行目）は README に残さない。コードから読める上に、台帳に行が無くテストも無い振る舞いなので、下記の規則により README に書けない。候補層 `docs/guarantee-candidates/0026-env-guard-docs.md` に 1 行（hook はスキャナの後に `.husky/pre-commit` と `.githooks/pre-commit` があれば順に実行し、他の hook 管理ツールを黙って無効にしない）を積む。テストを足す枚は別に切る。

### conventions への追加

`docs/conventions.md`「README の機能節」の規則「参照はテストファイル名で書く」に続けて、参照先が裁可済み節でない場合の 2 段を足す。

- 未検証の約束（`テスト困難`）に着地する機能は、その約束の起源チケット id で参照する。`tickets/done/<id>.md` は git 管理下にあり、到達性はテストファイル名と同じ
- `テスト未作成` に着地する機能と、台帳に行が無い振る舞いは README に書けない。書きたければ先にテストを足す（type: test のチケット）。README の圧縮がテスト作成の引き金になる

文面は実行者が規則の文体に揃える。

### コード内コメントの整理

`kuda:comments` の分類を 4 ファイルに掛ける——WHAT 型（直下のコードの言い換え）は削除、WHY 型（非自明な理由・外部制約・過去の失敗）は残す（冗長な言い回しは削るが、情報を落としてまで 1 行に圧縮しない）、機械へ移せる「守らせる」型は移してから捨てる。README から落とした説明はこれらのコメントが正本になるので、**README とコメントの両方から同じ説明を消さない**。判断に迷うブロックは触らず、提出時の報告に載せる。加えて:

- `bin/env-guard-scan` 6 行目と `hooks/pre-commit` 4〜7 行目のブロックにある設計書参照（`docs/prod-secret-isolation-design.md §…`）は落とす。参照先は `docs/archive/` へ移されており、runtime-base の束で削除される。参照が担っていた理由は同じコメントブロックが既に持っている。落とすと env-guard の中から `shipped-symbols.test.sh` の許可パターンに依存する行が消えるが、検査は変えない
- `bin/env-guard-scan` 2 行目と `hooks/pre-commit` 2 行目のイメージ内パス（`/usr/local/bin/env-guard-scan` / `/usr/local/share/git-hooks/pre-commit`）は、このファイルの要約ではなく配置先の記述で、正本は `images/runtime-base/Dockerfile` にある。分類で判定する
- `tests/install.test.sh` のコメントはテストの意図（WHY 型）が多い見込み。件数を稼がない

### やらないこと

- 台帳 `docs/guarantees.md` の編集（README から台帳への片方向参照のみ。文言の乖離を見つけたら報告に載せる）
- runtime-base 側の文書・コメント（`images/runtime-base/Dockerfile`、`templates/project/env-guard.conf` / `env-guard.yml`、`.github/workflows/env-guard.yml`）——runtime-base の束で扱う
- `.husky` / `.githooks` チェーンのテスト追加（別チケット）
- スキャナへの `--help` の追加などコードの振る舞いの変更

## 保証

### 新たに宣言する保証

- なし。文書とコード内コメントの変更であり、外から観測可能な振る舞いは変わらない。hook のチェーンは台帳に行が無い振る舞いとして候補層へ置く（裁可の対象外）

### 維持する保証

- 台帳 §1（`packages/env-guard/tests/install.test.sh`）、§2（`images/runtime-base/tests/env-guard.test.sh`）、§3（`images/runtime-base/tests/hook.test.sh`）。README がこれらを参照先にするが、テストと振る舞いは触らない。`tests/install.test.sh` はコメントだけを変える
- 台帳 §11（`images/runtime-base/tests/shipped-symbols.test.sh`——出荷物の記号検査）。env-guard の README と、イメージへ焼き込まれる `bin/env-guard-scan` / `hooks/pre-commit` の内容が変わるが、検査対象の集合と否定対照は変えない

### 廃止する保証

- なし。約束を取り下げる変更ではない
