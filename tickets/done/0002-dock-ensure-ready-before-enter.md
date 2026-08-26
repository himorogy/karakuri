---
status: close
type: feat
base: main
targets:
  - images/runtime-base/templates/host/dock.sh
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/dock.test.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - package.json
  - images/devcontainer-base/PORT-FORWARDING.md
  - docs/host-tools-distribution.md
  - example/README.md
verify:
  - bash images/runtime-base/templates/tests/dock.test.sh
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - bash images/runtime-base/tests/shipped-symbols.test.sh
  - pnpm lint:sh:images
---

# `karakuri-dock` を「使える状態にしてから入る」コマンドにする

## 内容

このチケットは2枚の束の1枚目である。0002（本チケット）で `karakuri-dock` と
`dock.sh` のインターフェースと各モードを揃え、0003 で Windows(Git Bash) を
想定環境として宣言し mac から Windows 上のコンテナへ 1 ホップで入る経路を通す。
0003 は 0002 の引数の形と `--stdio` の fail closed を前提とするため、順序は
0002 → 0003 で固定する。

0001 は独立した bugfix だが、port forwarding が張れない原因の切り分けについては
本チケットと組になる。転送が成立しない原因は loopback alias の不足と、`.ssh/config`
への `LocalForward` の記述漏れの2つで、前者を検出するのが 0001、後者を検出するのが
本チケットである。両方が分かる状態は 0001 と 0002 の両方が入って初めて成立するため、
0001 を先にマージする。

### 解きたい問題

`/run` は compose で tmpfs にしてあり、コンテナを停止して再起動するだけで
`/run/secrets` の中身が消える。そのため `dev-inject` はコンテナを起動するたびに
1 回実行する必要がある。実行を忘れると sshd が提示できる認可鍵が 0 件になり、
公開鍵認証が成立せずパスワード認証にフォールバックする。原因（secret が無い）から
遠い症状になるため、原因に辿り着くのに時間がかかる。

コンテナを起動するたびに注入を手で打つ運用をやめ、「起動 → 注入 → port forwarding
→ 入る」を 1 コマンドにまとめる。

### やること

**1. 引数を compose の命名規約から解放する。**

現行の `dock.sh <project>` は、compose project 名を `<project>-dev` として組み立て、
service 名を `dev` と決め打ちし、workspace を `/workspaces/<project>` と仮定する。
この 3 つの規約を同時に仮定するため、規約に合わないプロジェクトでは使えない。

```
karakuri-dock -p <compose-project> [-s <service>] [-w <workspace>] [up]
dock.sh       -p <compose-project> [-s <service>] [-w <workspace>] [<mode>]
```

`-s` の既定は `dev`。`-w` を省略した場合は `docker exec` に `-w` を渡さず、
コンテナの WORKDIR に従う。規約の組み立ては利用者側の関数が吸収する
（karakuri の配布物には入れない。例:
`dock() { karakuri-dock -p "$1-dev" -w "/workspaces/$1" }`）。

ラベルによるコンテナ特定（`com.docker.compose.project` と
`com.docker.compose.service` の厳密一致）は変えない。コンテナ名を組み立てる方式には
戻さない。`container_name` は compose ファイル側の指定次第で、組み立てた名前との
食い違いが「見つからない」や「別プロジェクトへ入る」になる。

**2. `dock.sh` にモードを 2 つ追加する。**

- `--ensure-running` — 対象コンテナを起動して終了する。stdout に何も出さない
- `--secrets-ok` — secret が注入済みかを判定して exit 0 / 1 を返す。stdout も
  stderr も空。コンテナの起動状態を変えない（判定を打っただけでコンテナが起動するのは
  呼び出し側から見て予想外である）

`--secrets-ok` の呼び出し元は `karakuri-dock` で、これが失敗したときだけ `dev-inject`
を呼ぶ分岐に使う。注入済みなら認可を求め直さないための判定である。単体でも意味を持ち、
`dock.sh -p <project> --secrets-ok; echo $?` で「今この起動に対して注入したか」を
人間が確かめられる（出力を持たないので他のコマンドから条件として使える）。

判定は `/run/secrets/SSH_AUTHORIZED_KEYS` の有無で行い、root で実行する。
`/run/secrets` の所有と mode を決めるのは注入側であり、既定ユーザーで読める保証を
判定側が前提にすると、注入側の権限を締めた瞬間に「注入済みなのに未注入と誤判定する」
形で壊れる。`/run` が tmpfs である以上、SSH 鍵の有無は「この起動に対して注入を
実行したか」と同義であり、同じ 1 回の注入で入る他の secret の有無とも一致する。

この 2 つを分けたのは、オーケストレーションを `dock.sh` に持たせず関数側から
組み立てられるようにするためである。

**3. `--stdio` を fail closed にする。**

secret が未注入なら exit 1 で終了し、stdout に 1 バイトも出さず、stderr にホスト側で
`karakuri-dock up` を実行するよう促す。素通しすると sshd がパスワード認証へ
フォールバックし、原因から遠いところで詰まる上に、CONTRACT が禁じている stdin の
読み取りを sshd 側が始める。

ssh の裏で注入を代行はしない。secret の注入には認可（パスワード / 生体認証）を
必須とする方針であり、非対話の ssh 接続の裏で黙って認可を求めると、応答できないまま
固まる。副作用として再帰が 1 段で止まる。`karakuri-dock up` → `karakuri-pf` →
`ssh -fN` → ProxyCommand `dock.sh --stdio` の順に呼ばれるが、`--stdio` は
オーケストレーションを呼び返さないのでここで終わる。

**4. `karakuri-dock` をオーケストレーション化する。**

```
karakuri-dock -p <project>       起動 → 未注入なら注入 → pf → 中で zsh
karakuri-dock up -p <project>    同じ。入る手前で止まる
```

- `dev-inject` は `--secrets-ok` が失敗したときだけ呼ぶ（注入済みなら認可を
  求め直さない）
- `DEV_COMPOSE_PROJECT` は `-p` の値をそのまま渡す。`DEV_BROKER` の未設定検査は
  `dev-inject` に任せる（同じ検査を 2 箇所に置くと、片方だけ直したときに食い違う）
- port forwarding を張るかは `ssh -G <host> | grep -q '^localforward '` で決める。
  転送を書いていないホストへ `ssh -fN` すると、何も転送しない master が残るだけに
  なる。設定を自前で読み直さず ssh 自身の解決結果を見るので、`Host *` や `Include`
  まで込みで正しい
- **転送を張らなかったときは、飛ばしたこととその理由を stderr に 1 行出す。** 黙って
  飛ばすと `.ssh/config` への `LocalForward` の書き忘れに気づけない。loopback alias を
  追加しただけで config への追記を忘れた場合、`ssh -G` には `localforward` 行が
  無いため「転送を持たないホスト」と判定され、正常に張れた場合と区別できないまま通る。
  意図的に転送を持たないホストでも同じ 1 行が出るが、警告ではなく行った処理の通知
  として出す
- 転送が成立しない原因は2つあり、検出する場所が違う。`.ssh/config` に `LocalForward`
  が無い場合は上の 1 行で分かる。loopback alias が足りない場合は
  `_karakuri_check_loopback` が `karakuri-loopback add <addr>` の実行を促して port
  forwarding を中断する（この検査は 0001 で修正するまで常に素通ししていた）。alias の
  検査は macOS のみで、Linux と Windows は 127.0.0.0/8 全体が最初から bind できるため
  検査自体が無い
- pf の失敗の扱いは呼び方で変える。`up` は入らないので転送の成否をそのまま返す
  （黙って成功に変えない）。`up` 無しは警告に留めて入る（転送が張れないことと、
  コンテナで作業を始められることは別である）
- 対話シェルで `exec` しない。`exec` するとシェルそのものが `docker exec` に
  置き換わり、コンテナを抜けた時点で端末が閉じる

ツールの探索には既存の `_karakuri_tool` を使う。新規に作らない。`karakuri.sh` の
関数を増減させたときは、ファイル冒頭のコメント一覧・関数の実体・`karakuri-help` の
3 箇所を揃える（ファイル内に規律として明記されている）。

**5. テストを追加する。**

`templates/tests/dock.test.sh` を新設し、`package.json` の `test` スクリプトに
登録する（`test` は個別列挙。`lint:sh:images` は glob、`shipped-symbols.test.sh` は
動的列挙なので追加は要らない）。スタブ化の作法は `karakuri.test.sh` に倣う
（PATH 先頭にフェイクのディレクトリを置き `docker` などを差し替える）。

`dock.test.sh` で最低限確認すること。

- `--stdio` 未注入で exit 1 かつ stdout が完全に空
- `--stdio` 注入済みで exit 0
- `--stdio` で停止中のコンテナを起動したとき、`docker start` の stdout が漏れない
- `--secrets-ok` の exit 0 / 1、stdout と stderr が空、コンテナの起動状態を
  変えないこと
- `--ensure-running` の起動あり / なし。どちらも stdout が空
- モードの排他（複数指定したときに名指しで失敗する）
- コンテナ 0 件 / 複数件でそれぞれ別のメッセージで失敗する
- 引数なし、未知のオプション、`--help` で stdout が空

`karakuri.test.sh` に追加すること。

- `karakuri-dock` が起動 → 注入 → pf の順に呼ぶこと
- `--secrets-ok` が成功したときに `dev-inject` を呼ばないこと
- 転送の無いホストで port forwarding を張らず、飛ばしたことを stderr に出すこと
- port forwarding の失敗時、`up` 有りは失敗を返し、`up` 無しは警告して入ること
- リネーム後の関数名で呼べること。旧名が残っていないこと
- 引数の誤りで usage を出して失敗すること
- bash と zsh の両方で出力が一致すること

**6. `karakuri-pf` と `karakuri-clean-pf` をリネームする。**

`pf` という略称は、人間が直接叩くことを想定して付けたものである。`karakuri-dock` が
主な経路になると、この関数は複合コマンドの構成要素として読まれる場面が増えるため、
略称のままでは何をするか読み取れない。

- `karakuri-pf` → `karakuri-port-forward`
- `karakuri-clean-pf` → `karakuri-clean-port-forward`

転送エラーのログのファイル名も関数名に揃える（`pf-<host>.log` →
`port-forward-<host>.log`）。旧名のログは残るが、転送エラーの揮発的な記録であり
移行のための読み替えは行わない。ファイル冒頭のコメント一覧と `karakuri-help` も
併せて揃える。

**7. 公開ドキュメントを追随させる。**

引数の形と関数名が変わるため、`PORT-FORWARDING.md` の ProxyCommand の例と
`karakuri-pf` の記載、`images/runtime-base/README.md` と `example/README.md` の
`karakuri-dock` / `karakuri-pf` の記載を同じコミットで直す。

### やらないこと

- Windows(Git Bash) での動作確認と、mac から Windows 上のコンテナへ 1 ホップで入る
  経路は 0003 で扱う。ただしこのチケットで書くコードは macOS 固有のコマンドに
  依存させない
- 公開鍵を `~/.ssh/authorized_keys` へ永続化する案は採らない。ssh で入れても他の
  secret は `/run/secrets` に無いままであり、注入はホスト側で実行する設計
  （broker をコンテナから到達不能な場所に置くのが目的）なので、入った後にコンテナ内
  から注入はできない。結局ホスト側で 1 コマンド打つことになり、「ssh だけ通る」状態が
  増えるだけである
- `dev-inject.sh` は変更しない。引数を取らない設計を維持し、必要な値は
  `DEV_COMPOSE_PROJECT` 経由で渡す
- `dock` という短い名前の関数は karakuri に入れない。配布物が汎用的な名前を他人の
  シェルに注入することを避ける。規約の吸収と合わせて利用者側に置く
- broker の設定ファイルは作らない。`DEV_BROKER` は環境変数のみで扱い、一時的な
  上書きはコマンド前置きで行う

## 保証

### 新たに宣言する保証

- `dock.sh --secrets-ok` は、指定した compose project と service のコンテナに
  secret が注入済みなら exit 0、未注入なら exit 1 を返す。stdout と stderr には
  何も出さず、コンテナの起動状態を変えない
- `dock.sh --ensure-running` は対象コンテナを起動して終了し、stdout に何も出さない
- `dock.sh --stdio` は secret が未注入のとき exit 1 で終了し、stdout に 1 バイトも
  出さない
- `karakuri-dock` と `dock.sh` は compose project 名・service 名・workspace を
  引数で受け、コンテナ名や workspace のパスを組み立てない
- `karakuri-dock` は secret が注入済みのとき `dev-inject` を呼ばない
- `karakuri-dock` は port forwarding を張らなかったとき、飛ばしたこととその理由を
  stderr に出す（設定に `LocalForward` が無い場合を含む）

保証台帳は未敷設のため、これらに対応する台帳の行は作らない。

### 維持する保証

- コンテナの特定はラベルの厳密一致で行い、0 件・複数件はいずれも明示的に失敗する
  （「とりあえず 1 つ選ぶ」をしない）
- `--stdio` は fd 1 を SSH トランスポートとして扱い、診断出力を stderr にのみ出す
  （`dock.sh` 冒頭の CONTRACT）
- `--stdio` は sshd のラッパーを絶対パスで exec し、フォールバックを持たない
  （フォールバックは失敗を隠して原因の分かりにくいエラーに変える）
- secret は broker の stdout から `docker exec -i` 経由でのみコンテナへ入る。
  `dock.sh` はこの経路を持たない
- `karakuri.sh` は `set -euo pipefail` を使わず、bash と zsh の両方で動く
- loopback alias の不足は `_karakuri_check_loopback` が検出し、`karakuri-loopback add`
  の実行を促して port forwarding を中断する（0001 で修正した検査を壊さない）
- `ifconfig` の実行に失敗した場合は fail open して転送を止めない

### 廃止する保証

- `dock.sh <project>` という単一引数の呼び出し形式を廃止する。compose project 名を
  `<project>-dev` として組み立て、service 名を `dev` と決め打ちし、workspace を
  `/workspaces/<project>` と仮定する挙動を取り下げる。規約の組み立ては利用者側の
  関数に移る
- `karakuri-pf` と `karakuri-clean-pf` という関数名を廃止する
  （`karakuri-port-forward` / `karakuri-clean-port-forward` へ移る）。転送エラーの
  ログのファイル名も `pf-<host>.log` から `port-forward-<host>.log` へ変わる
