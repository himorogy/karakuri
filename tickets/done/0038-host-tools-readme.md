---
status: close
type: docs
base: main
targets:
  - host-tools/README.md
  - images/runtime-base/README.md
  - docs/archive/host-tools-distribution.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - example/README.md
  - host-tools/broker-bitwarden.sh
  - host-tools/loopback-setup.sh
  - docs/archive/runtime-base-migration.md # 拡張: 移す節を指す参照がここにも残っていた
  - host-tools/karakuri.sh # 拡張: PR レビューの指示で alias の例を README へ移す
  - DEVCONTAINER.md # 拡張: PR レビュー中に人間が新設した devcontainer のセットアップ手順
  - README.md # 拡張: DEVCONTAINER.md へのリンクを 1 行足す（PR レビューの指示）
verify:
  - pnpm test
  - ~/.claude/skills/kuda/scripts/kuda-md-reflow --check host-tools/README.md
---

# host-tools の README を新設し、runtime-base README から使い方を移送して 3 要素へ圧縮する

## 内容

記述整理をパッケージ単位で進める束のうち、host-tools 束の 1 枚目。
家族は 0038（この枚。README の新設と移送元の圧縮、設計書の削除）→ 0039（`host-tools/` のスクリプトのコメント整理）→ 0040（`host-tools/tests/` のコメント整理）。
0039 と 0040 はこの枚のブランチから切る。
この枚が README を正本として書く説明を、後の 2 枚がスクリプト側から落とすためである。

`host-tools/` は `host-tools-v*` タグの clone として利用側へ渡る配布単位だが、その使い方は `images/runtime-base/README.md` の「使い方」「broker」「ホストにも同名の shim がある」に置かれている。
これを `host-tools/README.md` へ移し、`docs/conventions.md`「README の機能節」の 3 要素（何のために / どう動くか / 保証）へ組み替える。
成果の指標は文書の総量が減って情報が残ること。
着手前の計測は移送元 405 行（209〜232 行と 605〜969 行）、設計書 411 行。

### 判定の門

行を残すかどうかは、置き場所を考える前に決める。
次のどれかに当たる行は落とす。
落とした行の中身は git 履歴と正本（各スクリプトの冒頭コメント）に残る。

- コードから読める
- 叩けば機械が教える（`karakuri-help`、各スクリプトの usage、`karakuri-broker-env` の出力）
- 台帳とテストが固定している（`docs/conventions.md`「解説の正本」により散文で持たない）

残る節は 3 要素にする。
「何のために」は必須で、打ち消す相手を含める。
「どう動くか」は利用者が判断を誤る余地がある行だけ。
「保証」はテストファイル名で参照する（`host-tools/tests/<name>.test.sh`。clone に同梱されるので到達性は変わらない）。

**`host-tools/README.md` は `images/runtime-base/tests/shipped-symbols.test.sh` の strict 走査に自動的に入る**（`host-tools/` 配下を `find -type f` で列挙する）。
書けないもの: `§`、英大文字 1 字 + 数字 1〜2 桁の記号（I6 / D21 / H1 / L7 の型）、「設計書」の語、`rev.N`、`docs/prod-secret-isolation-design.md` とその archive パス。
台帳の節番号もこの型に当たるので、台帳への参照はテストファイル名だけで書く。

新設する README は `docs/writing-rules.md`（kuda 同梱）「並べ方」に従い、意味ごとに 1 行で書き、列幅で折り返さない。
提出前に `~/.claude/skills/kuda/scripts/kuda-md-reflow --check host-tools/README.md` を通し、`--candidates host-tools/README.md` が列挙する行は読んで分けるかを決める。

### README の判定表（行番号は現在の `images/runtime-base/README.md`）

| 節（行） | 判定 | 行き先 / 理由 |
|---|---|---|
| ホストにも同名の shim がある 209〜232 | 圧縮して移送（`_dotenvx` の節） | 「何のために」= `pnpm run` は `node_modules/.bin` を PATH の先頭に積むので素の `dotenvx` はローカル版に負ける。`_dotenvx` へ揃えると迂回されない（2 文）。素の名前を置かない理由は正本 `host-tools/shims/_dotenvx` 冒頭が持つので落とす。鍵無しで落とす・出どころを問わない・値を出さないは `host-shim.test.sh` が固定するので保証参照へ。Windows の `.cmd` は「pnpm の run-script は Windows で cmd.exe から起動する」の 1 行だけ |
| 入手 607〜611（対象 OS） | 残す（1 行） | 導入の前提。Linux ホストが対象外であることは判断を誤る余地 |
| 入手 613〜615（host-tools と templates/project の二分） | 落とす | `templates/project` は runtime-base の配布物。この README は host-tools だけを扱う |
| 入手 617〜626（clone コマンド・タグ系列） | 残す（コマンド + 2 行） | 使い方。タグは `host-tools-v*` の系列でイメージのタグとは別。系列を分けた理由は落とす |
| 入手 628〜632（PATH か symlink・Windows のパス形式） | 残す（2 行） | 使い方。Git Bash の `~` が Unix 形式である注意は判断を誤る余地 |
| 入手 634〜637（コピーではなく clone の理由） | 圧縮して残す（1 文） | README 冒頭の「何のために」へ。コピーは版ずれと改竄が見えない。clone なら `git status` に出る |
| 入手 639〜645（更新は明示的に） | 残す（コマンド + 1 行） | 使い方。`git pull` で追随させない理由（未リリースが prod の経路に入る）は 1 行 |
| 入手 647〜651（clone 先は workspace の外） | 圧縮して残す（2 文） | README 冒頭の「何のために」へ。打ち消す相手は、bind mount された workspace 内のスクリプトを dev container のエージェントが書き換える経路。この README が正本になり、各スクリプト冒頭の同文は 0039 で畳む |
| 入手 653〜657（karakuri.sh を source） | 残す（source の 1 行） | 使い方。関数一覧は `karakuri-help` が出す。短い名前は alias で付け、例は `karakuri.sh` 末尾にある、の 1 行 |
| 入手 659〜660（source で shims が PATH の末尾へ） | 落とす | `karakuri.test.sh` が固定 |
| 入手 662〜676（Windows は `~/.bash_profile`） | 圧縮して残す（2 行） | 使い方。理由は「Git Bash は login shell として起動し、`ssh <host> bash -lc` も login shell で `~/.bashrc` は読まれない」の 1 行 |
| 入手 678〜680（`KARAKURI_ORG` は任意） | 落とす | `karakuri-help` が「複数 org を横断するなら設定しない」まで出す |
| 入手 682〜691（SSH port forwarding・loopback・sudo・Windows・1 ホップ） | 圧縮して残す（dev の節に 2 行） | `~/.ssh/config` の書き方と `ProxyCommand` に `dock.sh` の絶対パスを書く理由は `images/devcontainer-base/PORT-FORWARDING.md` へ参照。`karakuri-loopback install` が初回 1 回は使い方。sudo が要るのは loopback だけ、は `karakuri-help` が言う。Windows で何もしないは `loopback-setup.test.sh` が固定。1 ホップ経路は PORT-FORWARDING の領分 |
| broker 本体 693〜702（native ビルド） | 圧縮して残す（2 行） | 使い方 + 判断を誤る余地。理由は 1 行（npm 版は postinstall が走り、版が黙って動き、node の切り替えで消える）。README が正本になり、`broker-bitwarden.sh` 冒頭の要約は 0039 で畳む |
| broker 本体 704〜722（取得コマンド） | 残す（コードブロック。コメントは圧縮） | 叩いても出ない手順 |
| broker 本体 724〜733（PATH に入れない・`KARAKURI_BW_BIN`） | 圧縮して残す（2 行） | 使い方 + 1 行（PATH 上に置くとバージョンマネージャの shim が先に来うる） |
| broker 本体 735〜736（同期は取得のたび・`BROKER_BW_SYNC`） | 落とす | `broker-bitwarden.test.sh` が固定 |
| broker 本体 736〜739（鍵束の置き方） | 圧縮して残す（2 行） | 項目名は `karakuri-broker-env <dev\|prod> <project>` が出す。中身は Secure Note に dotenv 形式の全文で、共有分と個人分を項目で分ける。加えて `BW_SESSION` をシェルへ export して常駐させない（同一ユーザーの任意のプロセスが無認可で vault を読める）の 1 行を足す（正本は `broker-bitwarden.sh` 冒頭にあり、0039 で畳む） |
| karakuri-run 741〜746 | 残す（2 行 + usage 1 行） | 「何のために」= ホストでしかビルドできないプロジェクト向け。dev container も prod も経由しない |
| karakuri-run 748〜754（`-b` 必須・`-e`・`--`・項目の並び） | 落とす | `karakuri.test.sh` が固定 |
| karakuri-run 756〜759（例） | 残す（1 例） | 使い方 |
| karakuri-run 761〜766（`-e prod` の限界） | 圧縮して残す（2 行） | 判断を誤る余地: prod の私鍵がホストのビルド木に入り、依存と postinstall の子プロセス全部から読める。既定が dev である理由 |
| CI 768〜778 | 残す（2 行 + コードブロック） | 使い方。CI runner には shim が無いので PATH へ足す。鍵は secrets から環境変数で渡せば通る |
| CI 780〜783（Windows runner） | 圧縮して残す（1 行） | 使い方 |
| CI 785〜787（npm の `bin` として配らない） | 落とす | 設計判断。履歴層 |
| CI 789〜792（移行時に CI が赤くなりうる） | 圧縮して残す（1〜2 行） | 判断を誤る余地: 落ちたら既存の鍵未供給の顕在化であって、この経路が壊したのではない |
| CI 794〜795（手で export した古い鍵は通る） | 落とす | `host-shim.test.sh`「鍵の出どころを問わない」が固定 |
| CI 797〜802（受け入れの作業） | 残す（箇条書き 4 行） | 使い方のチェックリスト |
| compose 804〜812（プロジェクトごとに 1 枚・`KARAKURI_PROD_COMPOSE_DIR`） | 残す（2 行 + ツリー） | 使い方。探索規則は `karakuri.test.sh` が固定 |
| compose 814〜817（コピーして digest を差し替え） | 残す（2 行） | 使い方。「編集を伴うコピーはこれだけ」は落とす |
| compose 818〜823（1 枚共有・一斉適用・check-image） | 圧縮して残す（1 行） | 一斉適用のトレードオフだけ |
| compose 823〜831（git リポジトリにしてよい・mount しない） | 圧縮して残す（2 文） | 置き場所の「何のために」: mount した時点で「書き換えられない」が「diff に出る」へ落ちる |
| prod 833〜838（compose.prod.yaml の配置先 `~/.config/<project>/`） | 落とす | 806〜812 の `KARAKURI_PROD_COMPOSE_DIR/<repo>.yaml` と食い違う。ディレクトリ運用に一本化する |
| prod 840〜848（生の `prod-run.sh` 呼び出し例） | 落とす | `prod-run.sh` の usage が同じ例を出す。README には `karakuri-prod-exec` の 1 例を置く |
| prod 850〜855（`dotenvx` を最上位に） | 圧縮して残す（1 行） | 「dotenvx は pnpm の外側に置く。理由は `prod-run.sh` の usage」。一般論は runtime-base README「shim の仕組み」が持つ |
| GIT_REF 857〜866（40 桁 hex・脱出口） | 落とす | `prod-run.test.sh` が早期拒否と脱出口の名指しを固定。usage が `PROD_ALLOW_MUTABLE_REF` を説明する |
| GIT_REF 868〜876（既定を拒否にする理由） | 圧縮して残す（2 文） | prod の節の「何のために」: ブランチ名は「レビューした対象と流したもの」の一致を切る。正本は `host-tools/compose.prod.yaml` の `GIT_REF` のコメント |
| GIT_REF 877〜889（解決済み sha の記録・`/run/prod-ref`） | 移送しない | entrypoint の振る舞い。runtime-base README に残す（下記） |
| GIT_REF 888〜889（署名タグ未実装） | 落とす | usage が「署名検証は未実装」と言う |
| GIT_REF 891〜898（依存インストール・`sh -c` の例） | 落とす | `karakuri-prod-run` が install を挟む。既定は `karakuri-help` が出す |
| GIT_REF 900〜904（`pnpm install` の後の `clean` 禁止） | 移送しない | entrypoint と store の話。runtime-base README に残す（下記） |
| 環境変数を確認する 906〜914 | 圧縮して残す（1 例） | `karakuri-prod-exec <org/repo> <sha> dotenvx get -f .env.prod`。「dev からは書けるが読めない」は runtime-base の領分 |
| 対話シェル 916〜928 | 書き直す（2 コマンド + 1 文） | 生の `run -dT` は事実誤り（detach は stdin を中継する compose クライアントを消し、broker は Broken pipe、entrypoint は EOF 待ちで止まる）。`karakuri-prod-base <org/repo> <sha>`（端末 1、前面）→ `karakuri-prod-shell <repo>`（端末 2）。「何のために」= stdin が secret の搬送路なので `run` の対話 TTY と両立しない。0 件・複数件で失敗することは `karakuri.test.sh` が固定 |
| broker 930〜937（契約） | 残す（5 項に直す） | 「どう動くか」: broker を差し替えるなら満たすもの。現在の 4 項に「stdout 以外へ secret を出さない」を足して `broker-bitwarden.sh` 冒頭の 5 項と同文にする。スクリプト側は 0039 で README へのポインタに畳む |
| broker 939〜943（参照実装 keychain・Windows 未決） | 落とす | keychain broker は台帳で `テスト未作成` なので README に書けない（存在は `host-tools/` の一覧から読める）。「Windows 側の標準は未決」は bw を標準にした時点で偽。差し替え点が 2 関数であることは `karakuri.test.sh` が固定し、関数名は `karakuri-help` が出す |
| broker 945〜948（鍵束は git 管理しない） | 圧縮して残す（1 文） | broker の節の「何のために」の前提: 鍵束は個人の資格情報で、git 管理する暗号化物は `.env.prod` だけ |
| broker 950〜955（Keychain「常に許可」） | 落とす | keychain 固有。正本 `broker-macos-keychain.sh` 冒頭が同文を持つ |
| pipefail 957〜968 | 節ごと落とす | broker 失敗で全体が非ゼロ、SIGPIPE の切り分けは `dev-inject.test.sh` / `prod-run.test.sh` が固定。起動ラッパーは配布物であり利用者は書かない |

節の組み立て（PR レビューの裁定で変更）: 4 部構成にする。
(1) これは何か——host-tools が何であるか（ホストで動く配布単位で、鍵の搬送路とコンテナへの入口を担う）を先に述べ、置き場所の注意はその後に置く。
(2) 同梱されているコマンドの概説——`karakuri-help` より少し説明的に、各コマンドが何を担うかを 1〜2 文ずつ。
(3) 推奨の使い方——入手（clone・PATH・source・Windows・更新）と、alias の例（`karakuri.sh` 末尾の「推奨する alias の例」をここへ移し、`karakuri.sh` 側は README への参照 1 行にする）、bw の用意、prod と dev の手順。
(4) 仕組みの概説と応用方法——broker の考え方（karakuri は Bitwarden CLI を標準の broker として採用しており、その利点を先に述べてから、契約を満たせば実装は問わないことと契約 5 項へ繋ぐ）、`_dotenvx` と CI、compose の置き場所と digest。
各機能の説明は 3 要素（何のために → どう動くか → 保証）を保つ。
dev の説明は現状 `example/README.md` と `PORT-FORWARDING.md` が散文を持つので、ここでは 3 要素の最小形に留める（後の束がそちらの散文を落とすときの行き先になる）。
見出しの語と文体は実行者に委ねる。

### runtime-base README 側

209〜232 行と 605〜969 行を落とし、「shim の仕組み」の末尾と旧「使い方」の位置に `host-tools/README.md` への参照を 1 行ずつ置く。
877〜889 行（解決済み sha の記録）と 900〜904 行（`pnpm install` の後の `clean`）は entrypoint の話なので、「prod-entrypoint.sh」の節の下へ内容を変えずに寄せる。
見出しは実行者に委ねる。
この 2 段落の圧縮は runtime-base の束で行う。
寄せ方に異論があれば PR レビューのインラインコメントで議論する。

### 参照の付け替え

削除する設計書と、移す節を指している参照を `host-tools/README.md` へ向ける。
直すのは参照の行だけで、本文の圧縮は各ファイルの束で行う。

- `images/devcontainer-base/PORT-FORWARDING.md` 96 行目（`docs/archive/host-tools-distribution.md` → `host-tools/README.md`）と 237 行目（`~/.bash_profile` の出典を runtime-base README → `host-tools/README.md`）
- `example/README.md` 22〜23 行目（「ホスト側ツールを入手する」）と 99 行目（「broker 本体（bw）を用意する」）
- `host-tools/broker-bitwarden.sh` 30 行目付近（bw の入手手順の正典を runtime-base README → `host-tools/README.md`）
- `host-tools/loopback-setup.sh` 77 行目付近（対応 OS の出典を runtime-base README → `host-tools/README.md`）
- `docs/archive/runtime-base-migration.md` 154 行目（「ホスト側ツールを入手する」への参照 → `host-tools/README.md` の「入手」。レビューで見つかった分。参照行だけを直す）

### archive の削除

`docs/archive/host-tools-distribution.md` を削除する。
中身は README（配布方式・タグ系列・compose の置き場所）、`host-tools/karakuri.sh` 冒頭（関数ファイルの理由・接頭辞・bash と zsh）、台帳（compose project 名・digest の解決・dock.sh のフォールバック無し）、各スクリプト冒頭（置き場所の禁止の精密化）に既にあり、`docs/conventions.md` へ抽出する制約は無い。
`docs/archive/prod-secret-isolation-design.md` は host-tools に関わる節（broker 契約・dev の注入・対話の二段構え）を読んだ上で、この枚では触らない。
削除は runtime-base の束で行う。

### やらないこと

- `docs/conventions.md` の編集（追加する規則は無い。参照規則は既存の 2 段で足りる）
- `docs/guarantees.md` の編集（README から台帳への片方向参照のみ）
- `host-tools/` のコメント整理（0039 / 0040）。この枚で触るのは参照の 2 行だけ
- `broker-macos-keychain.sh` / `broker-macos-keychain-set.sh` のテスト作成。台帳の未検証の約束に載っており、README には書かない。テストを足すかは PR レビューで議論する
- `example/README.md` と `PORT-FORWARDING.md` の本文の圧縮（それぞれの束）
- runtime-base README に残す 2 段落の圧縮（runtime-base の束）
- host-tools のタグの打ち直し（着地後に人間が行う）

## 保証

### 新たに宣言する保証

- なし。文書の新設・移送・削除であり、外から観測可能な振る舞いは変わらない

### 維持する保証

- 台帳 §13〜§20（`host-tools/tests/*.test.sh`）。README がこれらを参照先にするが、テストと振る舞いは触らない
- 台帳 §11（`images/runtime-base/tests/shipped-symbols.test.sh`）。`host-tools/README.md` が strict の走査対象に加わり、runtime-base README の内容が変わる。検査の側と否定対照は変えない
- 台帳 §12（`images/runtime-base/tests/template-sync.test.sh`）と §23（`images/runtime-base/tests/distributed-file-modes.test.sh`）。`host-tools/` にファイルが 1 つ増える（shebang 無しの 100644）。検査は変えない

### 廃止する保証

- なし。約束を取り下げる変更ではない
