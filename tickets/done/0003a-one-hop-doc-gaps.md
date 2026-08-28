---
status: close
type: docs
base: main
targets:
  - images/devcontainer-base/PORT-FORWARDING.md
verify:
---

# 1 ホップ経路の運用で読み取れない 3 点を文書に書く

## 内容

0003 で通した 1 ホップ経路（mac から Windows 上のコンテナへ ssh で直接入る）の検収と、その後
の運用で出た課題を扱う派生チケットである。3 点とも `PORT-FORWARDING.md` の 1 ホップ節に閉じ
ており、実装には触れない。

0002b（`-H` による ssh Host 別名の分離）と 0002c（`devc-` 接頭辞の合成と `ControlPath` 規約
への依存の除去）のマージ後を前提とする。`-H` が入ったことで (b) の誤読の余地が増えている。

### (a) 作業ディレクトリを指定する手段が無いように見える

通常経路（`karakuri-dock -p <compose-project> -w <workspace>`）は `docker exec -w` で作業
ディレクトリを指定できるが、1 ホップ経路には**それに相当する手段が無い**。`--stdio` が起動
するのはコンテナ内の sshd であり、ログイン後の作業ディレクトリを決めるのは sshd とログイン
シェルである。`docker exec` の `-w` はこの経路では使われない。

利用者から見ると `-w` を渡しても黙って無視されるだけで理由が分からない。自力で辿るには
`--stdio` の分岐が sshd を起動していることと、cwd の決定がその先にあることまで理解する必要
があり、`dock.sh` を読まない利用者には到達できない。

書くのは次の 3 点に限る。

- この経路では `-w` で指定できない。`--stdio` はコンテナ内の sshd を起動するだけで、ログイン
  後の作業ディレクトリは sshd とログインシェルが決める
- 固定したい場合は、薄い関数（`win-dock`）の接続段に
  `-o RequestTTY=yes -o RemoteCommand="cd <workspace> && exec zsh -l"` を渡す
- **`~/.ssh/config` の `Host` ブロックに `RemoteCommand` を書く形は勧めない。** その Host
  では `ssh <host> <command>` と `sftp` が `Cannot execute command-line and remote command.`
  で失敗する。接続段にだけ渡せばこの副作用が無い

  起草時に「`karakuri-port-forward` の `ssh -fN` にも掛かる」「scp が使えなくなる」も根拠と
  して挙げていたが、**どちらも実測で否定された**（レビューによる。OpenSSH 9.2p1）。`-N` は
  セッションチャネルを開かないので `RemoteCommand` は走らず、`scp` は自身で
  `-oRemoteCommand=none` を付けるため影響を受けない。**成立する副作用は上の 2 つだけである
  ことを文書に書き、成立しない 2 つを書かない。**

`-w` そのものの説明は書かない（`dock.sh` の usage に `used by the default mode only` と
出ており、コードから読める）。

### (b) `karakuri-dock up` が張る転送と mac 側の転送が別物であることが読めない

1 ホップ節は「転送は `karakuri-port-forward` で別に張る」と書いているが、その直後に Windows
側で `karakuri-dock -p <compose-project> -b <broker-key> up` を打つ手順が続く。`karakuri-dock`
は内部で `karakuri-port-forward` を呼ぶため、読者は「`up` で転送が張られるなら mac 側の段は
何のためか」と読む。実際にその質問が出た。

`karakuri-dock` が呼ぶ `karakuri-port-forward` は、**それが実行されるホスト（Windows）の
ssh config を見て Windows から張る**。mac のブラウザからコンテナへ届く転送は mac の ssh が
張るものであり、別物である。Windows 側には 1 ホップ用の `LocalForward` が無いので、実際には
「転送を持たないホスト」として飛ばされ、その旨の 1 行が出る。

**0002b で `-H` が入ったことで、この誤読の余地は増えている。** `-H` を渡せば mac 側の Host を
指定できるように読めるが、`-H` が変えるのは実行ホストの ssh が解決する Host 名であって、
転送を張るホストではない。Windows 側で `-H` に mac の Host 別名を渡しても、`ssh -G` を評価
するのも `ssh -fN` を打つのも Windows である。

この対比を 1 句足す。`-H` を渡しても実行ホストは変わらないことも併せて書く。

### (c) 薄い関数の例のクォートが 1 段足りず、引数が渡らない

現在の文書は薄い関数の 1 段目を次の形で示している。

```sh
ssh <windows-host> bash -lc "karakuri-dock -p $1-dev -b $1 up" || return 1
```

**この形は動かない。** 呼び出し側のシェルが `"..."` を剥がすため、ssh には別々の引数として
渡る。ssh はそれをスペースで連結してリモートシェルへ渡すので、Windows 側で実行されるのは
`bash -lc karakuri-dock -p <compose-project> -b <broker-key> up` である。`bash -lc <string>`
は最初の引数だけをコマンド文字列として実行し、残りを `$0` `$1` … に割り当てるため、
`karakuri-dock` が引数なしで呼ばれて usage を出して終わる。`|| return 1` は効くので関数は
そこで止まり、**注入されないまま止まったことが利用者からは分かりにくい**。

クォートをもう 1 段重ねた形が正しい。実測で成立を確認した。

```sh
ssh <windows-host> "bash -lc 'karakuri-dock -p <compose-project> -b <broker-key> up'" || return 1
```

同じ実測で、この経路が `~/.bash_profile` を読んで関数を見えるようにしていることも確認できた
（関数が無ければ `command not found` になる）。したがって「実機で確認済み」という現在の記述
自体は残してよい——0003 の検収時点では対話シェルでの読み込みしか確認していなかったが、
このチケットの起草時に経路そのものを実測した。

### やらないこと

- **`dock.sh` に手を入れない。** `--stdio` で `-w` を効かせる案は成立しない。`docker exec`
  の `-w` は exec するプロセス（sshd）の作業ディレクトリを変えるだけで、その sshd が受けた
  ssh セッションのログインシェルは改めて home へ移る
- **`ProxyCommand` の中で `cd` を挟む案は採らない。** `dock.sh` 冒頭の CONTRACT が禁じて
  いる（fd 1 は SSH トランスポートであり、シェルの介在は改行やプロンプトの混入を招く）
- **コンテナ側の shell 初期化（`~/.zshrc` 等）で chdir する案は文書に書かない。** 利用者の
  選択肢としては存在するが、2 つ並べると読者に選択を持たせることになる。設定が mac 側に
  閉じ、コンテナの中身に手を入れずに済む形だけを示す
- **`karakuri.sh` を絶対パスで source する形（`ssh <host> "bash -c 'source <絶対パス> &&
  karakuri-dock ...'"`）は書かない。** `~/.bash_profile` に source 行がある前提への依存を
  減らせるが、`bash -lc` で成立することを実測しており、その前提は README が導線として明記
  していて 1 ホップ節からリンクもしている。上と同じ理由で選択肢を増やさない
- 通常経路（`karakuri-dock`）の挙動と、`karakuri.sh` / `dock.sh` の実装は変えない
- `karakuri-prod-run` の Windows 実機での未確認事項（0003 で保持したもの）はこのチケットで
  扱わない

## 保証

### 新たに宣言する保証

- なし。文書だけの変更であり、外から観測可能な振る舞いは増減しない。(a) の `-w` が効かない
  ことも、(b) の転送が別物であることも、0002 と 0003 で決まった既存の挙動であり、それを
  説明するだけである

### 維持する保証

- `dock.sh --stdio` の CONTRACT（fd 1 を SSH トランスポートとして扱い、診断出力は stderr に
  のみ出す）。この経路に `cd` を挟む案を書かないことがこの保証を守る側に立つ

### 廃止する保証

- なし。記述の追加と訂正のみで、既存の約束を取り下げない
