---
status: close
type: docs
base: main
targets:
  - docs/guarantees.md
  - packages/env-guard/tests/install.test.sh
  - images/runtime-base/tests/env-guard.test.sh
verify:
  - bash packages/env-guard/tests/install.test.sh
  - bash images/runtime-base/tests/env-guard.test.sh
---

# 台帳に `@himorogy/env-guard` の保証を載せる

## 内容

この変更は保証台帳の敷設を配布単位で分割した束の2枚目である。

**束の全体像。** このリポジトリは複数の配布単位を通じて外部へ公開面を提供しているが、これまで保証台帳を持たなかった。既存の18本のテストが固定している振る舞いを抽出し、外から観測できる語彙の宣言文として台帳へ移す。抽出はテストのラベルではなくテスト本体を読んで行った。

**家族一覧（順序依存あり）:** 0005 分母と境界宣言 → **0006 env-guard** → 0007 egress-guard → 0008 prod 起動経路 → 0009 認証と出荷物検査 → 0010 ホスト入口 → 0011 ホスト注入・broker・loopback。

**不変条件:** 台帳を変更する経路はチケットのみ。索引の粒度はテストファイル単位に固定する（0005 が境界宣言で定めた）。

**この枚の役割。** 0005 が敷いた分母のうち配布単位 A（npm パッケージ `@himorogy/env-guard`）の保証を台帳へ載せる。`## Guarantees` 節をこの枚が新設し、`§1` から `§3` を書く。以降の枚は `§4` から続けて追加する。

`§2`（スキャナ）と `§3`（hook）の出典は `images/runtime-base/tests/` に置かれているが、検査対象は `packages/env-guard` の配布物なので配布単位 A に属する。テストの置き場ではなく約束の対象で節を割る。

**転記の途中で見つかった観測の穴を2つ塞ぐ。** 転記は「テストが固定している振る舞いだけを載せる」原則で進めたが、レビューで2行が原則を満たしていないと分かった。1つは `install` が git の無い場所で何も書かずに落ちること（分岐は実装にあるが検査が1本も無い）、もう1つは hook が自前の判定を持たないこと（ソース文字列を `grep` しているだけで、実行結果を見ていない）。どちらも台帳に載せる以上は観測が要るので、既存の2ファイルへテストを足す。実装には触れない。

**あわせて `install.test.sh` の fixture を環境から切り離す。** この dev container はイメージが `/etc/gitconfig` に `core.hooksPath` を焼いており、`git init` しただけの fixture もその値を継承する。そのため `git rev-parse --git-path hooks` がイメージ側のディレクトリを返し、既存の4件がコンテナ内でだけ落ちる（CI は `/etc/gitconfig` にこの設定を持たないので緑）。この枚が `verify` にこのテストを載せる以上、同じコマンドが場所によって色を変える状態は残せない。`make_repo` で `core.hooksPath` を local に明示して塞ぐ。

### やらないこと

- 他の配布単位の保証を載せること
- `packages/env-guard` の実装の変更（この枚が触るのはテストだけで、振る舞いは変えない）
- 上の2点以外のテストの追加（台帳へ載せる行の裏打ちと、`verify` に載せるテストが環境で色を変えないようにする分に限る）
- 「テストが触れていない面」として抽出したもののうち、候補層へ積むと 0005 で決めた1件（hook が `core.hooksPath` 経由でイメージから実際に効くこと）以外の処分。それらは境界宣言の免責が受け持つ

## 保証

### 新たに宣言する保証

台帳 `docs/guarantees.md` の `## Guarantees` へ以下の3節を追加する。出典はテストファイル単位。

#### `### 1. packages/env-guard/tests/install.test.sh — packages/env-guard/bin/env-guard.js`

- `install` は、書き込みが1キーの追加で済むときだけ `package.json` を書き換える。追加後のファイルは期待テキストと1バイトの差も無い（既存キーの順序・インデント・末尾改行を含む）（テスト: "pre-commit 未設定 -> 追加した 1 キー以外は 1 バイトも変わらない"）
- 既に `simple-git-hooks` セクションがあるときは、その中へ `pre-commit` を足すだけで、同居する他の hook 設定はそのまま残る
- 導入済みのリポジトリで再実行しても終了コード 0 で、導入済みである旨を出力し `package.json` は1バイトも変わらない（テスト: "2 回目の実行 -> package.json が 1 バイトも変わらない"）
- `simple-git-hooks` が依存に無いときは非ゼロ終了し、依存として入れるためのコマンドを出力し、`package.json` には触れない
- `pre-commit` に別のコマンドが設定済みのときは上書きせずに非ゼロ終了し、現在の値と必要な値の両方を出力する。既存の値はそのまま残る（テスト: "別のコマンドが設定済み -> 既存の値が保たれている"）
- `install --check` は状態を報告するだけで `package.json` を一切書き換えない。未導入なら非ゼロ、導入済みなら 0 で終了する
- `install` は `package.json` に書けたことをもって成功としない。hook が実体化され、その呼び先のファイルが実際に置かれていることまで確かめてから 0 で終了する
- 呼び先のパッケージが `node_modules` に無いときは、`package.json` に書けても hook ファイルが生まれても成功と報告せず、理由を添えて非ゼロ終了する。同じ状態で `--check` も 0 を返さない（テスト: "否定対照: hook の呼び先が無い -> 導入を成功と報告せず非ゼロ終了する"）
- 導入後、平文の値を含む `.env` を stage して commit しようとすると hook が非ゼロで拒否し、どの変数が暗号化されていないかを名前で伝える
- 拒否の出力に平文の値そのものは現れない（テスト: "通し: 拒否の出力に値そのものが出ていない"）
- 暗号化済みの `.env` は通り、検査した件数が出力される
- hook からスキャナへの経路が壊れていて検査できないときは、黙って通さず理由を添えて非ゼロ終了する（テスト: "否定対照: スキャナが見つからない -> 黙って通さず、理由付きで非ゼロ終了する"）
- `core.hooksPath` の指す hook が共有スキャナ `env-guard-scan` を直接呼んでいれば、パッケージ側の hook を経由していなくても `--check` は 0 を返す。スキャナにもパッケージ側の hook にも触れない hook ファイルでは `--check` が非ゼロになる（意図的な緩和。コンテナ内で `--check` が偽陰性になった実測に基づく）
- `install` は、git リポジトリの外、または `git` が PATH に無いときは `package.json` を書き換えず、何も書かなかった旨を出して非ゼロ終了する（テスト: "git repo の外 -> 非ゼロ終了し、何も書かなかったことを出力する"）

#### `### 2. images/runtime-base/tests/env-guard.test.sh — packages/env-guard/bin/env-guard-scan`

- 平文の `.env` は非ゼロ終了し、`<パス> line <行番号>: <キー名> is not encrypted` の形で場所とキー名が名指しされる
- 暗号化済みの `.env` は 0 で終了し、検査したファイル数が出力に残る
- 作業ツリーに `.env.keys` があると非ゼロ終了し、そのパスが報告される
- 既定の検査対象は basename が `.env` で始まるものと `secret.env.*`。それ以外の名前は対象外として 0 で通る。既定の許可リストは `.env.container.example` を飛ばし、飛ばしたことが出力に残る
- 平文の値と、`=` を含まない行の内容そのものは、検出時にも出力へ一切反射されない。報告されるのはキー名と行番号だけである（テスト: "the plaintext value is not echoed to the log" / "a line without '=' is not echoed to the log"）
- 1件も検査しなかった実行は黙って 0 を返さず、何も検査しなかったことを明示する
- git リポジトリでない場所では「0件検査して合格」に倒さず非ゼロ終了し、何も検査していないことを説明する（テスト: "a directory that is not a git repo fails instead of passing"）
- リポジトリルートの `env-guard.conf` で検査対象パターンと許可リストを上書きでき、既定では拾わないファイルを拾い、既定では落ちるファイルを許すようになる
- 設定ファイルが壊れているとき（未知のディレクティブ・値の無いディレクティブ・読めない）は既定へ黙って倒れず、行番号付きの理由を添えて非ゼロ終了する（テスト: "an unknown directive fails instead of falling back to the defaults"）
- `env-guard.conf` 自身は、パターンを「全部拾う」に上書きしてもなお検査対象にならない（設定ファイルの中身は暗号化された代入の形を取り得ないため、検査対象になれば必ず落ちる）
- 同じリポジトリに対して CI 側の入口（tracked の一覧）と hook（staged の一覧）は、終了コードだけでなく出力までバイト一致する
- hook は自前の判定を持たず共有スキャナへ委ねる。hook が呼ぶスキャナを差し替えると、合否も終了コードも差し替えた側のものになる（テスト: "the hook passes plaintext when the scanner it calls passes" / "the hook returns the stand-in scanner's own exit code"）。hook 単体でも `pattern` / `allow` の上書きが同じように効く

#### `### 3. images/runtime-base/tests/hook.test.sh — packages/env-guard/hooks/pre-commit`

- hook はカレントディレクトリの git リポジトリのルートを自分で決め、そこを起点に `.env.keys` を探す
- リポジトリルート直下の `.env.keys` でもサブディレクトリの `.env.keys` でも非ゼロ終了し、検出したパスがそのまま出力に現れる
- `node_modules` 配下の `.env.keys` は無視する
- `.env.keys` が一つも無ければ、平文でない `.env` 系ファイルが存在していても 0 で通る
- 走査を完走できなかったときは「0件だった」と取り違えて 0 を返さず、理由が読み取れる形で非ゼロ終了する（テスト: "find が失敗したら理由 (検査を完走できなかった) が読み取れる形で非ゼロ終了する"）

### 維持する保証

- 台帳末尾の境界宣言のうち、免責・公開面の定義・索引の粒度（0005 が敷いた内容をそのまま残す）

### 書き換える保証

- 境界宣言の「起源の粒度」。0005 は起源を `(<チケット id>, <統合の参照>)` のペアとしていたが、チケット id だけを置く形へ改める。統合されたチケットは `tickets/done/` に残るので、そこから統合の実体まで一意に辿れる。参照を別に持つと統合の後で台帳へ追記する手順が要るが、その手順を持つ工程が無く、書き漏らしが常態化する。この枚が台帳へ載せる `§1`〜`§3` が最初の適用例になるため、なぜペアでないのかを台帳から読めるようにしておかないと、後から見た人が書き忘れと判断してしまう

### 廃止する保証

- なし。既存の約束を取り下げる変更ではない

## テストの手当て

いずれも既存ファイルへの追加・修正で、新しいテストファイルは作らない。足す2件はどちらも否定対照を実測で確かめる（実装をわざと壊すと赤くなることを見てから戻す）。

- `packages/env-guard/tests/install.test.sh` — git repo の外に `package.json` だけを置いて `install` を呼び、非ゼロ終了・`Nothing was written.` の出力・`package.json` がバイト単位で不変、の3点を見る。`mktemp -d` の作り先がたまたま git repo の中だった場合は、通ったことにせず skip して残す
- `images/runtime-base/tests/env-guard.test.sh` — hook のコピーと、標準入力を捨てて既知の終了コードを返すだけの代役スキャナを並べたツリーを作り、hook をそこから実行する。hook は自分の隣の `../bin/` を先に見るので代役が必ず選ばれる。代役が 0 を返せば平文が staged でも hook は通り、代役が 42 を返せば暗号化済みでも hook は 42 を返す。hook が自前の判定を持っていれば、どちらも成り立たない
- `packages/env-guard/tests/install.test.sh` の `make_repo` — fixture の repo に `core.hooksPath` を local で明示する。継承した値が漏れると、代役の `simple-git-hooks` が書けないまま `.git/hooks/pre-commit` が生まれず、`install` の検証もイメージの hook を読んで通ってしまう。`core.hooksPath` を意図的に使う検査 10 は自分で設定し直すので影響しない。この 1 行で、system の設定がある環境と無い環境のどちらでも同じ結果になる
