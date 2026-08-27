---
status: close
type: feat
base: main
targets:
  - images/devcontainer-base/PORT-FORWARDING.md
  - images/runtime-base/README.md
  - images/runtime-base/templates/host/loopback-setup.sh
  - images/runtime-base/templates/tests/loopback-setup.test.sh
  - images/runtime-base/templates/host/dev-inject.sh
  - images/runtime-base/templates/host/prod-run.sh
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/dev-inject.test.sh
  - images/runtime-base/templates/tests/prod-run.test.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - images/runtime-base/templates/host/dock.sh
  - images/runtime-base/templates/tests/dock.test.sh
verify:
  - bash images/runtime-base/templates/tests/dock.test.sh
  - bash images/runtime-base/templates/tests/loopback-setup.test.sh
  - bash images/runtime-base/templates/tests/dev-inject.test.sh
  - bash images/runtime-base/templates/tests/prod-run.test.sh
  - bash images/runtime-base/templates/tests/karakuri.test.sh
  - bash images/runtime-base/tests/shipped-symbols.test.sh
  - pnpm lint:sh:images
---

# 対応 OS を macOS と Windows(Git Bash) に定め、mac から Windows 上のコンテナへ 1 ホップで入れるようにする

## 内容

このチケットは2枚の束の2枚目である。0002 で `karakuri-dock` と `dock.sh` の引数が
compose の命名規約から解放され、`--secrets-ok` と `--ensure-running` が入り、
`--stdio` が fail closed になっていることを前提とする。順序は 0002 → 0003 で固定。

扱うことは2つある。

### 1. 対応 OS を macOS と Windows(Git Bash) に定める

**ホストツールの対応 OS は macOS と Windows(Git Bash / MSYS2) の 2 つとし、Linux は
想定しない。** ホストツールはホスト側で動かすものであり、開発機として Linux を使う想定が
無いためである（コンテナの中は Linux だが、ホストツールをそこで動かすことはない）。
テストは Linux 上の CI とこのリポジトリの devcontainer で走るが、OS はスタブで偽装するため
対応 OS の範囲とは独立している。

現状は次のようになっている。

- OS の分岐は `uname -s` が `Darwin` かどうかの二値が 2 箇所だけである
  （`karakuri.sh` の `_karakuri_check_loopback` と `loopback-setup.sh` の macOS 判定）。
  非 Darwin はすべて同じ扱いになっている
- `dock.sh` は `docker exec` に `MSYS_NO_PATHCONV=1` を常時付けており、Git Bash 上での
  実行が既に意識されている。ただし OS による分岐は持っていない
- スクリプトの shebang は `#!/usr/bin/env bash` で、`karakuri.sh` は source される
- `karakuri-loopback` と `loopback-setup.sh` は macOS の loopback alias を再起動後も
  再適用する仕組みであり、macOS 専用である。Windows は 127.0.0.0/8 全体が最初から
  bind できるため、alias を張る作業自体が無い
- 配布は tag を指定した shallow clone で行い、OS に依存しない。足りないのは PATH への
  載せ方の記述だけである

**`loopback-setup.sh` と `karakuri-loopback` は macOS 以外では何もせず早期に終了させる。**
これは実行時の振る舞いを観察してから決めることではないので、判断をここで確定させる。
`lo0` の alias は macOS 固有の概念であり、Windows は 127.0.0.0/8 全体を最初から bind
できる。`/etc/hosts` の管理も Windows では意味を持たない（Git Bash の `/etc/hosts` は
Windows 側の名前解決に使われないため、書き換えても効かないうえに無意味な副作用が残る）。

判定は現状の「Darwin かどうか」の二値をそのまま使い、非 Darwin の側を「何もせず終了」に
変える。`MINGW*` などの名前で Windows を判定する必要は無い——Linux を対応 OS に含めない
ので、非 Darwin は Windows だけになる。挙動が変わるため
`templates/tests/loopback-setup.test.sh` も併せて直す。

実機で確認し、必要なら直すこと。

- `karakuri-dock` と `dock.sh` の各モードが Git Bash で動くこと
- `karakuri.sh` を Git Bash の起動ファイルから source する導線
- Windows で `karakuri-loopback` が何も変更せずに終了すること

### 2. mac から Windows 上のコンテナへ 1 ホップで入る

mac 側の ssh config に ProxyCommand を入れ子で書く。

```
Host devc-win-<project>
    ProxyCommand ssh <windows-host> dock.sh -p <project>-dev --stdio
    LocalForward 3000 localhost:3000
```

これで mac から直接コンテナへ ssh が張れ、`LocalForward` は mac 側の 1 段で済む。
Windows 側の loopback alias も `karakuri-pf` も要らない。`karakuri-pf` は bind
アドレスもポートも組み立てず `ssh -G` で解決結果を読むだけなので、この経路のために
karakuri 側のコードを変える必要はない。

接続を張るのは常に外側（mac）であり、コンテナ側から穴を開けない。コンテナ起点の
`ssh -R` は、コンテナからの外向き通信が allowlist に載っていない宛先へは通らないため
成立せず、通すには宛先を明示的に許可することになる。コンテナ内の常駐エージェントを
信用しないという前提と合わないので採らない。

`--stdio` が fail closed である帰結として、mac から接続する前に Windows 側で
`karakuri-dock up` を打って注入を済ませる必要がある。ssh の裏で黙って認可を求めない
という 0002 の方針どおりで、mac 側からは「secret が無い」ことが明示的なエラーとして
返る。

**注入は Windows 側で行う。** `dev-inject` は broker をコンテナから到達不能な場所に
置くためにホスト側で実行する設計であり、コンテナが Windows 上の docker で動く以上、
そのコンテナへ注入できるのは Windows ホストだけである。したがって Windows 側に
`DEV_BROKER` の設定と、broker が叩く secret store（およびその認証）が必要になる。
mac 側の設定を流用する経路は無い。

**`ProxyCommand` の中で注入を代行しない。** `ssh <windows-host> 'karakuri-dock up ...
&& dock.sh ... --stdio'` の形は 2 つの理由で成立しない。第一に `up` の出力が
`ProxyCommand` の stdout に混ざり、SSH トランスポートを壊す。第二に注入は認可
（パスワード / 生体認証）を要求するが、`ProxyCommand` は非対話で、stdin は SSH
トランスポートに占められており CONTRACT が stdin の読み取りを禁じている。認可に
応答できないまま固まる。どちらも `dock.sh` 冒頭の CONTRACT が扱っている話である。

2 段を 1 コマンドにまとめたい場合は、mac 側に「先に `ssh <windows-host> karakuri-dock
up`、次に `ssh devc-win-<project>`」を並べる薄い関数を置く。`up` が普通の ssh
セッションで走るので認可のプロンプトが端末に出て、stdout の汚染も起きない。この関数は
規約の吸収と同じ扱いで利用者側に置き、karakuri の配布物には入れない。

実機で確認すること。

- Windows の OpenSSH sshd 経由で `dock.sh --stdio` がバイト透過に動くこと。
  `ssh <windows-host> <command>` は sshd の既定シェルで実行され、Windows の既定は
  `cmd.exe` である。改行コードの変換が入ると SSH トランスポートが壊れる。既定シェルの
  設定を変えるか、`bash -lc` を挟む形にするかを実測で決め、決めた側を文書に書く
- 注入前に mac から接続したとき、`--stdio` の fail closed が mac 側に見えること
- `LocalForward` でコンテナ内で起動したサービスが mac のブラウザから開けること

これらは Windows 実機と mac の両方が必要であり、機械的な verify に落とせない。
検収（人間の動作確認）に委ねる。`dock.test.sh` には、既定シェルの扱いを決めた結果
`dock.sh` の呼び出し形が変わった場合にその形を固定するテストだけを追加する。

### 3. Git Bash の MSYS パス変換を全ホストツールで塞ぐ

Git Bash（MSYS2）は、コマンドライン引数が `/` で始まるときそれを Windows のパスへ変換する。
`docker exec` に渡すコンテナ内の絶対パスがこれに当たり、変換されるとコンテナ内に存在しない
パスになって `executable file not found`（exit 127）で落ちる。検収の実機で
`karakuri-dock -p <project> up` が次の形で落ちることを確認した。

```
OCI runtime exec failed: exec: "C:/Program Files/Git/usr/local/bin/secrets-ingest.sh":
stat C:/Program Files/Git/usr/local/bin/secrets-ingest.sh: no such file or directory
```

`dock.sh` は `docker` の呼び出しに `env MSYS_NO_PATHCONV=1` を前置きしてこれを避けているが、
他のホストツールには付いていない。同型の箇所は 3 つある。

- `dev-inject.sh` の `docker exec -i "$cid" /usr/local/bin/secrets-ingest.sh`
- `karakuri.sh` の `karakuri-prod-shell` が呼ぶ `docker exec -it -w /src "$cid" bash`
- `prod-run.sh` の `docker compose run -T --rm prod "$@"`（タスク引数が `/` で始まる場合）

`dock.sh` にも漏れが 2 箇所ある。当初これを「対策済み」と判断したが、`MSYS_NO_PATHCONV=1`
が付いているのは対話シェルと sshd を exec する 3 箇所だけで、**secret の有無を判定する
2 箇所には付いていない**。

- `--secrets-ok` の `docker exec -u root "$container" test -f /run/secrets/SSH_AUTHORIZED_KEYS`
- `--stdio` の未注入判定（同じ形の `test -f`）

判定対象のパスが変換されるため `test -f` が常に false になり、Windows 上では
`--secrets-ok` が注入済みでも 1 を返し、`--stdio` は注入済みでも fail closed で落ちる。
検収の実機で `karakuri-dev-inject` が 5 件の secret を注入したあとに `--secrets-ok` が
1 を返すことを確認した。

**指定は呼び出しごとに書かず、スクリプト単位に寄せる。** 呼び出しごとに書く形が今回の
漏れの原因であり、`docker` の呼び出しを足すたびに同じ漏れが起きる。

- 独立した実行スクリプト（`dock.sh` / `dev-inject.sh` / `prod-run.sh`）は冒頭で
  `export MSYS_NO_PATHCONV=1` する。スクリプトは独立したプロセスなので、呼び出し側の
  シェルには漏れない。既に入れた `env` の前置きは削り、この形へ寄せる
- `karakuri.sh` は利用者の対話シェルに source されるため export しない。
  `karakuri-prod-shell` の 1 箇所だけ `env` の前置きを維持し、**例外がこの 1 箇所である
  ことと、その理由（source されるファイルである）をコメントに書く**

export はそのスクリプトが起こす全ての子プロセスに効く。`dev-inject.sh` / `prod-run.sh` は
broker も起動するが、broker が受け取る項目名は環境変数（`BROKER_BW_ITEM`）で渡るため、
コマンドライン引数の変換の対象外である。`prod-run.sh` の `-f "$PROD_COMPOSE_FILE"`
（ホスト側のパス）の変換も止まる点は前置きの形と変わらない——この論点は実測待ちとして
別に扱い、このチケットでは形を変えない。

各テストに、`docker` のフェイクが受け取った環境から `MSYS_NO_PATHCONV=1` が渡っている
ことを検査するケースを足す。`dock.test.sh` には `--secrets-ok` と `--stdio` の判定系
2 モードについて足す（今回漏れていた箇所であり、否定対照が要る）。フェイクの作法は既存の
ものに倣う。パス変換そのものは MSYS 上でしか起きないため、Linux の CI で検査できるのは
「変数を渡していること」までであり、変換が実際に止まることの確認は検収に委ねる。

### 4. 検収で確定した事項を文書へ反映する

Windows 実機と mac で検収を行い、チケットが実機に委ねていた 3 点が確定した。文書側の
「実機で確認すること」という留保を外し、確定した内容を書く。

**(a) Git Bash の起動ファイルからの導線** — `~/.bash_profile` と `~/.bashrc` のどちらに
書いても対話シェルでは読まれた。ただし依存すべきは `~/.bash_profile` の側である。Git Bash が
login shell として起動するため `~/.bash_profile` は bash 自身の仕様で読まれるのに対し、
`~/.bashrc` が読まれるかは `/etc/profile` / `/etc/bash.bashrc` の構成次第で変わる。加えて
`ssh <host> bash -lc "..."` の経路（下記 (c) の薄い関数が使う）は login shell なので
`~/.bash_profile` を読み、`~/.bashrc` は非対話 bash では原則読まれない。`README.md` の
当該段落を、`~/.bash_profile` を推し、`~/.bashrc` に依存しない形へ確定させる。

**(b) Windows sshd の既定シェルとバイト透過** — mac 側 ssh config の `ProxyCommand` に
`dock.sh` の絶対パスを直接書いた形（`ssh <windows-host> <絶対パス>/dock.sh -p
<compose-project> --stdio`）で、既定シェルのまま SSH トランスポートが成立した。`bash -lc`
で包む必要は無かった。`PORT-FORWARDING.md` の「実機で確認し、壊れる場合は既定シェルを
変えるか `bash -lc` を挟む」という留保を外し、この形が動くことを書く。

ただし**リモートで `karakuri-dock` を呼ぶ側には `bash -lc` が要る**。あちらは
`karakuri.sh` が source で定義する関数であり、`ssh <host> <command>` の非対話・非ログイン
経路では見えないためである。`dock.sh` が実行ファイルで絶対パス指定であることとの非対称は
残るので、両者の違いが読み取れる形で書く。

**(c) 対話セッションに `LocalForward` を直書きする形の穴** — 1 ホップ節が示した設定例は
対話セッションに転送を持たせる形だった。この形では、転送先のサービス（dev サーバ）が
落ちたときに `connect_to localhost port <port>: failed.` が作業中の端末へ出続ける。転送
そのものは壊れておらず、サービスを起動し直せば復活するが、既存経路が持っていたログ分離が
この経路には効いていない。

通常経路（mac 上のコンテナ）でこれが起きないのは、`karakuri-dock` が転送を
`karakuri-port-forward` 経由で張り（`ssh -fN` の stderr がログファイルへ逃げる）、作業する
端末は `docker exec -it zsh` で別プロセスになっているからである。1 ホップ経路では入るのも
転送も同じ ssh セッションなので同居する。

`karakuri-port-forward` は `devc-` で始まる名前をそのまま受け取る（`_karakuri_ssh_host`）
ので、1 ホップ経路の host alias をそのまま渡せる。新しい仕組みは要らない。文書を次のように
直す。

- 1 ホップ節の設定例に `ControlMaster auto` / `ControlPath ~/.ssh/cm-%n` を含める
- 転送は `karakuri-port-forward <host alias>` で別に張り、対話セッションは master を
  再利用する形を示す。直書きした場合に何が起きるかも書く
- 既存の「2 段をまとめる薄い関数」の例を、注入 → 転送 → 接続の 3 段に差し替える。転送の
  失敗は警告に留めて入る（`karakuri-dock` 本体と同じ扱い）。この関数は規約の吸収と同じく
  利用者側に置くもので、配布物には入れない
- 通常経路でこの問題が起きない理由を 1 文添える

**`karakuri-prod-run` の Windows 実機での確認は行っていない。** `-f "$PROD_COMPOSE_FILE"`
（ホスト側のパス）が `MSYS_NO_PATHCONV=1` によって未変換のまま `docker compose` へ渡る点の
当否は未確定のままとする。prod 系を Windows で使う運用が無いため実測しておらず、確定して
いないことを文書へ書かない（推測を書かない）。

### 文書

- `PORT-FORWARDING.md` に mac から Windows 上のコンテナへ入る経路を追加する。
  現在のアーキテクチャの説明は ssh が 1 ホップ（mac から docker ホスト 1 台）である
  ことを前提に書かれている
- `images/runtime-base/README.md` に Windows(Git Bash) を想定環境として書き、
  PATH への載せ方を追記する

### やらないこと

- Linux をホストとする使用は想定しない。WSL2 と PowerShell ネイティブも対象にしない
  （PowerShell は全スクリプトの移植になる）
- 2 段の `LocalForward` チェーン（Windows 側で pf を張り、mac からそこへ重ねる形）は
  採らない。管理する master が 2 つになる
- コンテナ起点の逆方向トンネルは採らない。外向き通信の許可を追加しない
- 配布方式の設計文書は触らない。Windows の配布手順は README に書く
- `ProxyCommand` の中で注入を代行しない。代替は mac 側の薄い関数に置き、karakuri の
  配布物には入れない
- Windows 側から mac 上のコンテナへ入る逆向きは対象外

## 保証

### 新たに宣言する保証

- ホストツール（`karakuri.sh` の関数群と `dock.sh`）が動作する OS は macOS と
  Windows(Git Bash / MSYS2) の 2 つである（Linux は対応 OS に含めない）
- `dock.sh --stdio` は、mac 側 ssh config の ProxyCommand から Windows ホストを
  経由して呼ばれたとき、SSH トランスポートをバイト透過に中継する
- `karakuri-loopback` と `loopback-setup.sh` は macOS 以外で実行された場合、何も変更せず
  macOS 専用であることを示して終了する

保証台帳は未敷設のため、これらに対応する台帳の行は作らない。

### 維持する保証

- `--stdio` の CONTRACT（fd 1 を汚さない、未注入なら fail closed）は、経路が 1 段
  増えても変わらない
- コンテナへの到達経路は compose の `ports` を使わない。受信は loopback と確立済み
  接続、および opt-in で開けた sshd のポートに限られており、publish は届かない
- コンテナからの外向き通信は allowlist に載っていない宛先へは通らない。この経路の
  ために許可を追加しない
- secret は broker の stdout から `docker exec -i` 経由でのみコンテナへ入る。経路が
  1 段増えても、mac から Windows のコンテナへ secret が流れる経路は作らない

### 廃止する保証

- なし。対応する環境を増やす変更であり、既存環境に対する約束を取り下げない
