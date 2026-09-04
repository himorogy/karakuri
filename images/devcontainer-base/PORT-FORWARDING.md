# ホストからコンテナ内サービスへの到達（port forwarding）

コンテナ内で動くサービス（各アプリの dev サーバ、crit）へホストのブラウザから到達する方法をまとめます。

本書は base イメージが提供する機構の説明です。ホスト名の割り当て・ポート一覧・`~/.ssh/config` の具体的な転送行はプロジェクトごとに決まるため、各プロジェクトの `.devcontainer/README.md` 側に置いてください（末尾「プロジェクト側で定めること」参照）。

## 前提: コンテナは devcontainer ツールで作る

コンテナは devcontainer CLI（`devcontainer up`）か VS Code の Dev Containers 拡張で作ってください。**素の `docker compose up` は支援しません。**

`devcontainer.json` は `features`・`postCreateCommand`・`postStartCommand` を持ち、`waitFor` を `postStartCommand` に置いています。`docker compose` を直接叩くとこの 3 つがどれも走らないため、**egress-guard が適用されないコンテナ**ができます。環境変数が一部届かないという程度の話ではありません。

環境変数の届き方もこの前提に乗っています。sshd はセッションの環境を自分の environ から引き継がないため、`docker exec` が sshd へ渡した値は、それがイメージの `ENV` であれ compose の `environment:` であれ SSH セッションには届きません（実測は `images/runtime-base/verification-record.md`）。届くのは PAM（pam_env）が `/etc/environment` から読んだものだけです。devcontainer ツールはコンテナ作成時にコンテナの env 全量を `/etc/environment` へ写す（`patchEtcEnvironment`）ので、**この前提を守る限り、イメージの `ENV` も compose の `environment:` も等しく SSH セッションへ届きます。**

写し込みは作成時 1 回だけで、マーカー（`/var/devcontainer/.patchEtcEnvironmentMarker`）が二重実行を防ぎます。`/var` は tmpfs ではないためマーカーはコンテナの停止・起動をまたいで残り、`/etc/environment` が起動のたびに伸びることはありません（2026-09-03 に実測）。

## なぜ `docker-compose.yaml` に `ports:` を書かないのか

egress-guard が INPUT を DROP しており、許可されるのは以下の 3 つだけです。

```
:INPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp --dport $SSHD_PORT -m conntrack --ctstate NEW -j ACCEPT
```

publish してもパケットはコンテナに届いた時点で落ちます。RST が返らないため、ブラウザ上は「接続が pending のまま返らない」という症状になります。

到達経路は 2 つあり、どちらも **compose の publish を使いません**。

| 開発環境 | 経路 |
|---|---|
| VS Code | Dev Containers 拡張の自動転送。コンテナ内のヘルパーが `127.0.0.1:<port>` へ接続し、docker exec チャネル上を流す |
| それ以外（wezterm 等） | ホスト側の SSH port forwarding（後述） |

いずれも接続元がコンテナ内の loopback になるため、`-A INPUT -i lo -j ACCEPT` に当たります。

2 つの経路は同時に生きられますが、**プロジェクトのホスト名で開けるのはどちらか一方だけです**（「どちらの経路を使うかは選ぶ必要がある」参照）。

## SSH 利用者の設定

### 1. `~/.ssh/config`

```
Host devc-<your-project>-dev
  HostName <your-project>-dev
  # プロジェクトのポート一覧に合わせて列挙する
  LocalForward 127.0.1.1:4588 localhost:4588
  LocalForward 127.0.1.1:<port> localhost:<port>

Host devc-*
  ProxyCommand ~/.config/karakuri/images/runtime-base/templates/host/dock.sh -p %h --stdio
  User node
  IdentityFile ~/.ssh/keys/<your-key>
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath ~/.ssh/cm-%n
  ControlPersist no
  ExitOnForwardFailure yes
  # トランスポートは docker exec のローカルパイプで、ネットワーク経路が存在しない。
  # ホスト鍵はコンテナ再作成のたびに変わるため、検証を切ってよい（後述）。
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

上の雛形では、`Host` の別名（`devc-<your-project>-dev`）と `HostName`（= dock.sh へ渡る compose project 名そのもの、`<your-project>-dev`）は `devc-` の分だけ異なります。`karakuri-dock` は `-H` を省略すると `-p` に渡した値をそのまま ssh Host として使うため、この雛形のままでは `-H` を省略できません。省略すると `ssh -G <your-project>-dev` を引いてしまい、`Host devc-<your-project>-dev` のブロックに当たらず、「転送を持たないホスト」として port forwarding が飛ばされます。

雛形どおりに使うときは、`karakuri-dock -p <compose-project> -H devc-<compose-project>` のように `-H` へ別名をそのまま渡してください（[example/README.md](../../example/README.md) の `dock` 関数はこの形です）。`-H` は `-p` から独立に指定でき、`ssh -G` の検査・`karakuri-port-forward` の呼び出し先の両方に使われます。渡す値は完全な ssh Host 名です（`karakuri-dock` / `karakuri-port-forward` は `devc-` のような接頭辞を補いません）。

`-H` を省略できるのは、別名を `-p` の値と完全に一致させた場合だけです。その場合、別名は `devc-` で始まらなくなるため上の `Host devc-*` のワイルドカードには当たらず、その Host 専用の `ProxyCommand` ブロックを別に書く必要があります（下の `Host devc-<your-alias>` の例を参照）。

接続は `ssh devc-<your-project>-dev` です。転送を張り直すときは `karakuri-port-forward devc-<your-project>-dev` を使います（古い master を落としてから繋ぎ直します）。

上の `Host devc-*` とワイルドカード `%h` の組み合わせは、別名を `HostName`（compose project 名）と揃える運用が前提です。別名を自由にしつつ `HostName` を compose project 名から切り離したい場合、`ProxyCommand` の `-p` へ compose project 名をリテラルで書けば `%h` の結合が外れます。このブロックは既存の `Host devc-*`（上の設定例）より前に置いてください。ssh は各キーで最初に見つかった指定が勝つため、後ろに置くと `devc-*` の `ProxyCommand ... -p %h` が勝ち、`dock.sh` が `devc-<your-alias>` という誤った project 名で呼ばれます。

```
Host devc-<your-alias>
  ProxyCommand ~/.config/karakuri/images/runtime-base/templates/host/dock.sh -p <compose-project> --stdio
  # プロジェクトのポート一覧に合わせて列挙する
  LocalForward 127.0.1.1:4588 localhost:4588
  LocalForward 127.0.1.1:<port> localhost:<port>
  User node
  IdentityFile ~/.ssh/keys/<your-key>
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath ~/.ssh/cm-%n
  ControlPersist no
  ExitOnForwardFailure yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

代償は、`Host devc-*` の 1 本では済まなくなることです。プロジェクトを増やすたびに、この形の `Host` ブロックを 1 つずつ足すことになります。

`ProxyCommand` のパスは、ホスト側ツール一式を clone した場所に合わせてください。上の例は `karakuri.sh` を `~/.config/karakuri/.../templates/host/karakuri.sh` から source する場合の隣です。入手方法は [docs/host-tools-distribution.md](../../docs/host-tools-distribution.md) を参照してください。

**ここに `karakuri-dock` とは書けません。** `ssh` は `ProxyCommand` を `/bin/sh -c` で起動するため、`karakuri.sh` が `source` で定義した関数はそこから見えません。同じ `dock.sh` の対話シェル側は `karakuri-dock -p <compose-project> [-b <broker-key>]` で呼べますが（利用者側に置く短い `dock` 関数の作り方は [example/README.md](../../example/README.md) の「dev の起動」を参照）、`ProxyCommand` は関数を経由できません。

`dock.sh` は実行ファイルなので、`templates/host` を `PATH` に入れていれば `ProxyCommand dock.sh -p %h --stdio` とも書けます。ただし `ssh` を起動する側の環境の `PATH` に依存します（対話シェルから打つ分には効きますが、GUI アプリや別ツールが `ssh` を起動する経路では違う `PATH` になります）。**絶対パスを勧めます。**

`HostName` は DNS では引かれません。`ProxyCommand` の `%h` に展開されて `dock.sh -p` へ渡る値になるだけです。`dock.sh` はこの値をそのまま compose project 名として使い、`com.docker.compose.project` と `com.docker.compose.service` のラベルでコンテナを引きます（`<your-project>-dev` のような組み立ては `dock.sh` 側ではもう行わないので、`HostName` に compose project 名そのものを書きます）。**`docker-compose.yaml` の `name:` が `HostName` と同じ値である必要があります**（雛形のとおりであれば `<your-project>-dev` で合っています）。`container_name` の書き方には依存しません。

`LocalForward` の転送先 `localhost` はコンテナ内で解決されます。

### 2. `/etc/hosts` と loopback エイリアス

プロジェクトのホスト名を loopback アドレスへ割り当てます。

```
127.0.1.1 <your-project-hostname>
```

プロジェクトごとに別の loopback アドレス（`127.0.1.2` など）を割り当てれば、**プロジェクト間でポート番号を使い回せます**。どのアドレスをどのプロジェクトに割り当てるかは各自で決めてください。`127.0.1.x` を dev container 用、`127.0.2.x` を別マシンへの SSH 用、といった分け方もできます。ツール側は範囲を固定していません（`127.0.0.0/8` であることだけを検査します）。

macOS では、`127.0.0.1` 以外の loopback アドレスは `ifconfig lo0 alias` で明示的に有効化しないと bind できません。しかも設定は再起動で消えます。`karakuri-loopback` がこの 2 つ（起動時の再適用と `/etc/hosts` への登録）をまとめて面倒を見ます。

初回に 1 回だけ、LaunchDaemon を入れます。

```sh
karakuri-loopback install
```

以後、プロジェクトを追加するたびに 1 行です。

```sh
karakuri-loopback add 127.0.1.1 <your-project-hostname>
```

これで次の 3 つが揃います。

- `/etc/karakuri/loopback-aliases` にアドレスが記録され、**再起動のたびに LaunchDaemon が張り直す**
- その場で `ifconfig lo0 alias` も実行されるので、再起動を待たずに使える
- `/etc/hosts` の管理ブロック（`# BEGIN karakuri (managed)` ～ `# END karakuri`）にホスト名が登録される

現状は `karakuri-loopback list` で確認できます。設定ファイル・`lo0` の実際の状態・`/etc/hosts` の 3 つを並べて出すので、「`/etc/hosts` には書いたが alias を張り忘れている」といったズレがその場で分かります。

`karakuri-loopback` は `sudo` を要求します（LaunchDaemon の配置と `/etc/hosts` の編集のため）。`karakuri.sh` が提供する関数のうち、特権が要るのはこれだけです。日常的に打つ `karakuri-port-forward` は `sudo` を必要としません。

このツールは macOS 専用です。対応 OS は macOS と Windows(Git Bash) の 2 つで、Windows では `karakuri-loopback` は何も変更せずに終了します（その旨を示す 1 行を出すだけです）。Windows は `127.0.0.0/8` を最初から bind でき、Git Bash の `/etc/hosts` は Windows の名前解決に使われないため、そもそも設定する対象がありません。

Windows で名前を引きたい場合は、Git Bash の `/etc/hosts` ではなく `C:\Windows\System32\drivers\etc\hosts` を管理者権限で編集してください。`127.0.0.0/8` 全体を最初から bind できるので、macOS のような alias の段は不要で、`127.0.0.1 <name>` の 1 行を足すだけで足ります。反映されないときは `ipconfig /flushdns` を試してください。

`/etc/hosts` は Docker Desktop など他のツールも触るファイルです。`karakuri-loopback` はマーカーで囲んだ管理ブロックの中だけを書き換え、その外には触れません。編集前に `/etc/hosts.karakuri.bak` へ退避します。

### 仕組み

`/usr/local/sbin/sshd-inetd` は base イメージが焼いているラッパーで、`/run/sshd`（privilege separation ディレクトリ）を作り、ホスト鍵が無ければ生成してから `sshd -i -e` を exec します。`sshd -i` は inetd モードで、**listen ソケットを持たず** stdin/stdout 上で 1 接続だけを処理します。それを `docker exec -i` のパイプに繋いでいるため、SSH セッションは docker exec チャネルに乗ります。コンテナに TCP の口を開けずに済み、攻撃面が増えません。VS Code の自動転送と実質同じ経路を、ツール非依存で再現しています。

listen ソケットを持たない経路なので、egress-guard の `firewall.json` に `sshdPort` を書く必要はありません。書くと inbound が 1 本開き、`docker exec` を経由しない到達経路が生まれます。egress-guard は 0.2.0 で `sshdPort` を opt-in にし、省略時は sshd 向けの規則を一切出さなくなりました（0.1.x は未指定でも 22 を開けていました）。この雛形では書かないのが正解です。

`-u root` が必要なのは、`sshd` がホスト鍵（`/etc/ssh/ssh_host_*`、root のみ読める）を読むためです。

**ラッパーを経由せず `sshd -i` を直接起動してはいけません。** `docker-compose.yaml` は `/run` を tmpfs にしているため、`/run/sshd` はコンテナを起動するたびに消えます。ラッパーが毎回作り直しているのはこのためで、飛ばすと `Missing privilege separation directory: /run/sshd` で接続が閉じます。原因（ラッパーを通っていないこと）から遠いメッセージなので、`ProxyCommand` にフォールバックを書かないでください。ラッパーが無いイメージに対しては、`docker exec` が `executable file not found` で明示的に失敗するのが正しい壊れ方です。

`ExitOnForwardFailure yes` は、ホスト側のポートが既に使われている場合に接続ごと失敗させます。転送されないまま接続だけ成功して原因が分からなくなる状態を防ぎます。

### ホスト鍵はコンテナごとに変わる

`/etc/ssh/ssh_host_*` はイメージに焼かれていません（焼くと全コンテナが同一鍵になるため、ビルド時に削除しています）。ラッパーが初回接続時に生成するので、コンテナを作り直すたびにホスト鍵が変わります。

上の設定例に `StrictHostKeyChecking no` を入れているのはこのためです。通常は勧められない設定ですが、ここではトランスポートが `docker exec` のローカルパイプで、そもそもネットワーク経路が存在しません。接続先のすり替えには Docker へのアクセス権が必要で、それを持たれた時点でホスト鍵検証の有無は結果を変えません。

### 公開鍵は dev-inject で注入する

公開鍵はイメージに焼けません（個人の鍵であり、全利用者共通の base に置くものではありません）。sshd は認可鍵を次の 2 か所から読みます（イメージの sshd_config で設定済み）。

```
AuthorizedKeysFile /run/secrets/SSH_AUTHORIZED_KEYS .ssh/authorized_keys
```

標準の経路は 1 つ目です。broker の個人アイテムに `SSH_AUTHORIZED_KEYS` キーとして公開鍵を持たせれば、GH_TOKEN 等の secret と同じ dev-inject 1 回で注入されます。専用の注入スクリプトは要りません。具体的な手順 — アイテムの命名（全プロジェクト共通の個人アイテム `env/_common/dev`）・値の形式・`BROKER_BW_ITEM` のマージ順 — は [example/README.md](../../example/README.md) の「dev の起動」を参照してください。

公開鍵は秘密情報ではありません。broker に載せるのは秘匿のためではなく、搬送と再注入のタイミング規律を secret と 1 本にまとめるためです。tmpfs なのでコンテナ停止で消えますが、消える条件も再注入の作法も secret と同じで、覚えることが増えません。dev-inject を忘れると git 認証も同時に失敗するため、SSH だけが静かに壊れることもありません。

2 つ目の `~/.ssh/authorized_keys` は、broker を使わない導入形態（devcontainer-base を別の注入手段と組み合わせる場合）向けに残してあります。こちらはコンテナを作り直すと消えるため、都度の再投入が必要です。

## mac から Windows 上のコンテナへ入る（1 ホップ）

devcontainer が Windows の docker で動いている場合も、上の `ProxyCommand` を入れ子にするだけで mac から直接コンテナへ ssh が張れます。Windows 側に loopback エイリアスも `karakuri-port-forward` も要りません。

```
Host devc-win-<your-project>
    ProxyCommand ssh <windows-host> <dock.sh の絶対パス> -p <your-project>-dev --stdio
    LocalForward 3000 localhost:3000
    ControlMaster auto
    ControlPath ~/.ssh/cm-%n
    ControlPersist no
    ExitOnForwardFailure yes
```

このブロックは既存の `Host devc-*`（上の「1. `~/.ssh/config`」参照）より前に置いてください。ssh は各キーで最初に見つかった指定が勝つため、後ろに置くと `devc-*` の `ProxyCommand` が勝って 1 ホップになりません。逆にこのブロックは `User` / `IdentityFile` / `StrictHostKeyChecking` / `UserKnownHostsFile` を持たないので、`devc-*` からの継承を前提にしています。

`LocalForward` は mac 側の 1 段だけで済みます。`ProxyCommand ssh <windows-host> <dock.sh の絶対パス> -p <your-project>-dev --stdio` は既定シェルのまま SSH トランスポートが成立することを実機で確認済みです（`bash -lc` で包む必要はありません）。`dock.sh` は実行ファイルで絶対パス指定なので、`ssh <host> <command>` の非対話・非ログイン経路でも PATH に依存せず素通しできます。パスはホスト側ツール一式を clone した Windows 側の場所に合わせてください（上の「1. `~/.ssh/config`」と同じ理由で絶対パスを勧めます）。

接続を張るのは常に mac（外側）で、コンテナ側から穴を開けません。コンテナ起点の `ssh -R` は egress-guard の allowlist に載っていない宛先へは通らないため成立せず、通すには宛先を明示的に許可することになります。

### 転送は `karakuri-port-forward` で別に張る

上の設定例をそのまま `ssh devc-win-<your-project>` で対話接続すると、`LocalForward` を持つのも入るのも同じ ssh セッションになります。転送先の dev サーバが落ちたときに出る `connect_to localhost port <port>: failed.`（後述「よく出るエラー」の同名の節参照）が、通常経路のようにログファイルへ逃げず、作業中の端末そのものへ出続けます。転送自体は壊れておらず実害はありませんが、作業を邪魔します。

通常経路（mac 上のコンテナ）でこれが起きないのは、`karakuri-dock` が転送を `karakuri-port-forward` 経由で張り（`ssh -fN` の stderr がログファイルへ逃げる）、作業する端末は `docker exec -it zsh` で別プロセスになっているからです。1 ホップ経路には `docker exec` に相当する分離が無いので、接続前に転送だけを別セッションで張っておく必要があります。

```sh
karakuri-port-forward devc-win-<your-project>   # master を張る（ログは port-forward-devc-win-<your-project>.log）
ssh devc-win-<your-project>                     # 既存の master に相乗りして入る
```

`karakuri-port-forward` は渡した名前をそのまま ssh へ渡すので、`devc-win-<your-project>` もそのまま渡せます。新しい仕組みは要りません。

secret の注入は Windows 側で行います。`dev-inject` は broker をコンテナから到達不能な場所に置くためにホスト側で実行する設計であり、コンテナが Windows 上の docker で動く以上、注入できるのは Windows ホストだけです。mac から接続する前に、Windows 側で次を実行して注入を済ませてください。

```
karakuri-dock -p <your-project>-dev -b <your-project> up
```

`--stdio` は未注入なら fail closed で終了するため、これを忘れると mac 側には「secret が無い」という明示的なエラーが返ります。

`karakuri-dock` は `up` の内部に転送を張る段を持ちますが、それは実行ホスト（Windows）の `~/.ssh/config` を見て Windows 側から張るものです。上の 2 行の手順で mac 側に別セッションを立てているのはこれとは別物で、mac のブラウザからコンテナへ届く転送は mac の ssh が張ります。Windows 側でその名前（`-H` 省略時は `<your-project>-dev`）に `LocalForward` が無ければ「転送を持たないホスト」として飛ばされ、その旨の 1 行が出ます。`-H` を渡しても実行ホストは変わらないため、Windows 側で `-H` に mac の Host 別名を渡しても、`ssh -G` を評価するのも `ssh -fN` を打つのも Windows のままです。

`ProxyCommand` の中で注入は代行できません。`ssh <windows-host> 'karakuri-dock -p <your-project>-dev -b <your-project> up && dock.sh ... --stdio'` の形は、`up` の出力が `ProxyCommand` の stdout に混ざって SSH トランスポートを壊すことと、注入が求める認可（パスワード / 生体認証）に非対話の `ProxyCommand` が応答できないことの 2 つで成立しません。

2 段を 1 コマンドにまとめたい場合は、mac 側に注入 → 転送 → 接続を並べる薄い関数を置いてください。

```sh
win-dock() {
  ssh <windows-host> "bash -lc 'karakuri-dock -p $1-dev -b $1 up'" || return 1
  if karakuri-port-forward "devc-win-$1"; then
    ssh "devc-win-$1"
  else
    echo "win-dock: port forwarding failed — entering without it" >&2
    ssh -o ClearAllForwardings=yes "devc-win-$1"
  fi
}
```

`dock.sh` と `karakuri-dock` では、リモートでの呼び出し方が非対称です。`dock.sh` は実行ファイルの絶対パス指定なので `ssh <windows-host> <dock.sh の絶対パス> ...` とそのまま書けますが、`karakuri-dock` は `karakuri.sh` が `source` で定義する関数なので、`ssh <host> <command>` の非対話・非ログイン経路には存在しません。`bash -lc '...'` を 1 つの引数としてリモートへ渡し（上の例のようにクォートを 2 段重ねます）、login shell として `~/.bash_profile`（[images/runtime-base/README.md](../runtime-base/README.md) 参照）を読ませて関数を見えるようにする必要があります（実機で確認済み）。この形はリモート側のシェルが単引用符を剥がすことに依存する二段構えで、実測した環境は Windows の OpenSSH の `DefaultShell` に Git Bash の `bash.exe` が設定されたものです。

転送が張れないときに「警告に留めて入る」が単純には成立しない点に注意してください。上の設定は `ExitOnForwardFailure yes` を持つため、転送先のポートが bind できない状態では `ssh devc-win-<your-project>` そのものが `Could not request local forwarding.` で失敗し、**入れません**。`karakuri-dock` 本体（`docker exec` で入る通常経路）が転送の失敗を警告に留められるのは、入る経路と転送が別プロセスだからです。1 ホップ経路は同じ ssh セッションなのでこの前提が無く、入る側だけを通すには `-o ClearAllForwardings=yes` で転送を外して繋ぎ直す必要があります。`win-dock` はこれを行っています。`ExitOnForwardFailure` を `no` に緩めて済ませないでください——それを外すと `karakuri-port-forward` が転送の失敗を検出できなくなります（転送が無いまま master だけ残り、成功したように見えます）。この関数は規約の吸収と同じ扱いで利用者側に置くもので、karakuri の配布物には入りません。

### 作業ディレクトリを固定する

この経路では `-w` は使えません。`--stdio` はコンテナ内の sshd を起動するだけで、ログイン後の作業ディレクトリは sshd とログインシェルが決めます。

固定したい場合は、`win-dock` の接続段——通常の `ssh "devc-win-$1"`（`if` 側）と、転送が失敗したときのフォールバック `ssh -o ClearAllForwardings=yes "devc-win-$1"`（`else` 側）——の両方に `-o RequestTTY=yes -o RemoteCommand="cd <workspace> && exec zsh -l"` を渡してください。片方だけに付けると、転送が失敗した回だけ作業ディレクトリが home に戻ります。

`~/.ssh/config` の `Host` ブロックに `RemoteCommand` を書く形は勧めません。その Host では `ssh <host> <command>` と `sftp` が `Cannot execute command-line and remote command.` で失敗します（OpenSSH 9.2p1 での実測では、`karakuri-port-forward` の `ssh -fN` は `-N` がセッションチャネルを開かないため影響を受けず、`scp` は自身で `-oRemoteCommand=none` を付けるため影響を受けません）。接続段にだけ渡せばこの副作用がありません。

## VS Code 利用者の設定

`/etc/hosts` に 1 行足すだけです。

```
127.0.0.1 <your-project-hostname>
```

loopback エイリアスも `~/.ssh/config` も不要です。Dev Containers 拡張が自動でポートを転送します。

ただし **VS Code の自動転送は実質的に `127.0.0.1` へ bind されます**。そのため、複数プロジェクトを同時に開くとポートが衝突します。衝突すると VS Code は別のホストポートを自動で割り当てるため、決めたホスト名:ポートでは開けなくなります。同時に開くプロジェクトがある場合は、後述の方法で `CRIT_PORT` 等をずらしてください。

`remote.localPortHost` という設定は存在しますが、当てにしないでください。ドキュメント上の選択肢は `localhost` と `allInterfaces` で、任意のアドレス（`127.0.1.1` など）を受けるかは確認できていません。加えて、dev container で `allInterfaces` が尊重されないという報告があります（[microsoft/vscode-remote-release#11131](https://github.com/microsoft/vscode-remote-release/issues/11131)）。**プロジェクト間でポート番号を使い回したい場合は、SSH の経路を使ってください。**

## どちらの経路を使うかは選ぶ必要がある

VS Code の自動転送（`127.0.0.1`）と SSH port forwarding（`127.0.1.1` など）は、bind するアドレスが違うので **同時に生きられます**。ポート番号が同じでも衝突しません。

しかし `/etc/hosts` はホスト名を 1 つのアドレスにしか向けられません。

```
# これは書けるが、どちらに繋がるかが不定になる
127.0.0.1 project-a.test
127.0.1.1 project-a.test
```

文法上は合法（同じ名前に複数の A レコード）ですが、`getaddrinfo` が両方返し、どちらへ接続するかはクライアント次第です。片方でしか listen していなくてもフォールバックする保証はありません。**したがって、プロジェクトのホスト名で開く経路は、どちらか一方に決めてください。**

- **VS Code 中心** — `127.0.0.1 <your-project-hostname>`。ポート番号は全プロジェクトでずらす必要がある
- **ターミナル（SSH）中心** — `127.0.1.1 <your-project-hostname>`。アドレスをプロジェクトごとに変えられるので、ポート番号は使い回せる

### 両立させない理由

ホスト名を分ければ（`project-a.test` と `project-a-vscode.test`）名前解決は決定的になり、両方の経路が同時に使えます。しかし origin が 2 つになるため、プロジェクト側で次を **すべて** 二重に持つ必要があります。

- dev サーバの `allowedHosts`（後述）
- CORS の許可 origin
- OAuth のコールバック URL（プロバイダ側にも 2 つ登録）
- 絶対 URL の設定（`API_BASE_URL` 等）を起動元に応じて切り替える実装
- クッキーは共有されないため、それぞれでログインする前提

**現時点ではこれを前提にしません。** 割に合うだけの利点が無く、特に 4 点目はアプリケーション側の実装コストになります。両立が必要になった時点で、上を満たしたプロジェクトが個別に採ればよい構成です。

## SSH の経路へ寄せる（VS Code の自動転送を止める）

VS Code を使いながら転送だけ SSH に一本化することもできます。自動転送のバグ（ポートが別のコンテナへ転送される、勝手に別のホストポートが割り当てられる等）を踏んだ場合の逃げ道です。

`devcontainer.json` の `customizations.vscode.settings` に次を入れます。

```jsonc
"remote.autoForwardPorts": false,
"remote.restoreForwardedPorts": false,
"otherPortsAttributes": { "onAutoForward": "ignore" }
```

**3 つとも要ります。** `remote.autoForwardPorts` だけでは止まらない経路（ターミナルに出た localhost リンクのクリック、出力の走査）が報告されています（[microsoft/vscode#161045](https://github.com/microsoft/vscode/issues/161045)、[#221888](https://github.com/microsoft/vscode/issues/221888)、[#129050](https://github.com/microsoft/vscode/issues/129050)）。`otherPortsAttributes` が全ポートに効く受け皿です。

### 雛形では既定にしていない

`examples/devcontainer.json` にはコメントアウトした状態で置いてあります。有効化する前に、**ホスト側ツールが入っていること**を確認してください。

`docker-compose.yaml` は `ports:` を書かず、egress-guard が INPUT を DROP しています。到達経路は「VS Code の自動転送」と「SSH port forwarding」の 2 つだけで、後者はホスト側ツール・`~/.ssh/config`・loopback エイリアスの 3 つが揃って初めて動きます。3 つが揃わないまま自動転送を切ると、**コンテナ内のサービスへ到達する手段が無くなります**。しかも publish は塞がれているのではなく応答が返らない形で失敗するため、症状からは原因に辿り着けません。

## crit のポート

crit CLI 自体のデフォルトは**ランダムポート**です。ホスト側の `LocalForward` を静的に書けるよう、雛形の `docker-compose.yaml` が値を固定しています。

```yaml
    environment:
      CRIT_PORT: "4588"
```

`4588` は雛形が置いている値であって base が決めた仕様ではありません。同時に開く別プロジェクトと衝突したら、この行をずらしてください。イメージの `ENV` に置かないのは、利用側が変える前提がある値だからです（`docs/conventions.md`「環境変数の置き場」）。

一時的にずらすだけなら起動時に指定できます。

```sh
crit -p 4590
```

なお、指定したポートが既に使われている場合、crit は `address already in use` で**起動に失敗します**。黙ってランダムポートへ退避することはないため、衝突は必ず顕在化します。

## dev サーバ側の `allowedHosts`

Vite / Astro の dev サーバは、未知の Host ヘッダを持つリクエストを拒否します（DNS リバインディング対策）。`localhost` 以外のホスト名で開くには許可が必要です。

```ts
	server: {
		host: true,
		port: ...,
		allowedHosts: [".test"],
	},
```

`.test` は RFC 6761 で予約された TLD で公開 DNS に登録できないため、ワイルドカードで許可しても外部から悪用できません。**サービスを新規に追加する場合はこの設定も必要です。**

### crit も同じ検査を持つ

crit は Host ヘッダが `localhost` か loopback IP のときだけ通します。`<your-project>.test:4588` で開くと `403 Forbidden` になります。ワイルドカードの許可リストは無く、通すには広告 URL でホスト名を 1 つ与えます。置き場は compose の `environment:` です。

```yaml
    environment:
      CRIT_PUBLIC_URL: http://<your-project>.test:4588
      CRIT_ALLOW_UNAUTHENTICATED_NETWORK: "1"
```

ホスト名は `~/.ssh/config` の `LocalForward` で使う実名に、ポートは `CRIT_PORT` に揃えてください。広告 URL は bind を変えないため、listen は `127.0.0.1` のままです。

`CRIT_ALLOW_UNAUTHENTICATED_NETWORK` は**機能の有効化ではなく承認**です。crit はネットワーク認証を持たず、ポートに到達できる者はリポジトリのファイルを読め、エージェントを起動しうるコメントを書けます。そのため crit は「広告 URL が非空」「listen が非 loopback」のどちらかに当たると、明示の承認が無い限り起動を拒否します。この 2 条件は同じフラグで解除されるので、**base イメージには焼きません**——焼くと `CRIT_HOST` を非 loopback にしたときの拒否まで一緒に消え、最後の関門が失われます。承認は、それを必要とする判断と同じ場所に置いてください。

`ports:` を書かず egress-guard が INPUT を DROP し、listen が loopback のままの構成なら、この 2 行で到達経路は増えません。**その 3 つが崩れている構成では有効化しないでください。**

雛形（`examples/docker-compose.yaml`）にはコメントアウトした状態で置いてあります。

## よく出るエラー

### `connect_to localhost port <port>: failed.` が出続ける

**転送は正常です。** 転送先のサービス（dev サーバ）が落ちているだけで、ブラウザが再接続を繰り返すたびに `ssh` がこれを吐きます。dev サーバを起動し直せば復活するので、転送を畳む必要はありません。

`karakuri-port-forward` は `ssh -fN` の stderr を `${XDG_STATE_HOME:-~/.local/state}/karakuri/port-forward-<host>.log` へ逃がすので、端末は汚れません。中身を見たいときは `tail -f` してください。

`ssh -O exit <host>` で master を落とせば止まりますが、これは転送ごと捨てる操作です。`ssh` を黙らせる目的で使わないでください。

mac から Windows 上のコンテナへ入る 1 ホップ経路で、`karakuri-port-forward` を挟まず対話セッションに `LocalForward` を直書きした場合は、ログへ逃げずこのメッセージが作業中の端末そのものへ出ます（「mac から Windows 上のコンテナへ入る（1 ホップ）」の「転送は `karakuri-port-forward` で別に張る」参照）。

### `bind: Can't assign requested address`

macOS で loopback エイリアスが張られていません。`karakuri-loopback add <addr>` で恒久化してください。`karakuri-port-forward` は接続前に `~/.ssh/config` の `LocalForward` を読んで検査するので、通常はこのメッセージではなく、どのアドレスが足りないかを名指しするメッセージが出ます。

### `Missing privilege separation directory: /run/sshd`

`ProxyCommand` がラッパー（`/usr/local/sbin/sshd-inetd`）を経由していないか、コンテナがラッパーを持たない古いイメージから作られています。`docker exec -u root <container> ls -l /usr/local/sbin/sshd-inetd` で確認してください。

その場しのぎは `docker exec -u root <container> mkdir -p /run/sshd` ですが、`/run` は tmpfs なのでコンテナを再起動するたびに消えます。イメージを更新して、`ProxyCommand` を `dock.sh` に揃えるのが恒久策です。

## プロジェクト側で定めること

以下は base では決まらないため、各プロジェクトの `.devcontainer/README.md` に置いてください。

- ホスト名（例: `<your-project>.test`）と、割り当てる loopback アドレス
- ポート一覧（どのサービスが何番か、環境変数の原本はどこか）
- `~/.ssh/config` の具体的な `LocalForward` 行
- サービス URL・クッキーの `Domain` とホスト名の整合（`localhost` でログインが通らない等の注意）
- `CRIT_PORT` を雛形の 4588 からずらすかどうか
- crit を `<your-project>.test` で開くなら `CRIT_PUBLIC_URL` と `CRIT_ALLOW_UNAUTHENTICATED_NETWORK`（「crit も同じ検査を持つ」）
