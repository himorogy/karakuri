# ホストからコンテナ内サービスへの到達（port forwarding）

コンテナ内で動くサービス（各アプリの dev サーバ、crit）へホストのブラウザから到達する方法をまとめます。

本書は base イメージが提供する機構の説明です。ホスト名の割り当て・ポート一覧・`~/.ssh/config` の具体的な転送行はプロジェクトごとに決まるため、各プロジェクトの `.devcontainer/README.md` 側に置いてください（末尾「プロジェクト側で定めること」参照）。

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

## SSH 利用者の設定

### 1. `~/.ssh/config`

```
Host devc-<your-project>
  HostName <your-project>
  # プロジェクトのポート一覧に合わせて列挙する
  LocalForward 127.0.1.1:4588 localhost:4588
  LocalForward 127.0.1.1:<port> localhost:<port>

Host devc-*
  ProxyCommand docker exec -i -u root %h-devcontainer /usr/local/sbin/sshd-inetd
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

接続は `ssh devc-<your-project>` です。

`HostName` は DNS では引かれません。`ProxyCommand` の `%h` に展開されてコンテナ名を組み立てるためだけに使われます。**`docker-compose.yaml` の `container_name` と（`%h` への接尾辞込みで）一致している必要があります。**

`LocalForward` の転送先 `localhost` はコンテナ内で解決されます。

### 2. `/etc/hosts` と loopback エイリアス

プロジェクトのホスト名を loopback アドレスへ割り当てます。

```
127.0.1.1 <your-project-hostname>
```

プロジェクトごとに別の loopback アドレス（`127.0.1.2` など）を割り当てれば、**プロジェクト間でポート番号を使い回せます**。

macOS では `127.0.1.1` を明示的に有効化する必要があります。

```sh
sudo ifconfig lo0 alias 127.0.1.1 up
```

再起動で消えるため、launchd に載せて永続化します。

```xml
<!-- /Library/LaunchDaemons/dev.loopback-alias.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.loopback-alias</string>
  <key>ProgramArguments</key>
  <array>
    <string>/sbin/ifconfig</string>
    <string>lo0</string><string>alias</string>
    <string>127.0.1.1</string><string>up</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

```sh
sudo launchctl load -w /Library/LaunchDaemons/dev.loopback-alias.plist
```

### 仕組み

`/usr/local/sbin/sshd-inetd` は base イメージが焼いているラッパーで、ホスト鍵が無ければ生成してから `sshd -i -e` を exec します。`sshd -i` は inetd モードで、**listen ソケットを持たず** stdin/stdout 上で 1 接続だけを処理します。それを `docker exec -i` のパイプに繋いでいるため、SSH セッションは docker exec チャネルに乗ります。コンテナに TCP の口を開けずに済み、攻撃面が増えません。VS Code の自動転送と実質同じ経路を、ツール非依存で再現しています。

`-u root` が必要なのは、`sshd` がホスト鍵（`/etc/ssh/ssh_host_*`、root のみ読める）を読むためです。

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

## VS Code 利用者の設定

`/etc/hosts` に 1 行足すだけです。

```
127.0.0.1 <your-project-hostname>
```

loopback エイリアスも `~/.ssh/config` も不要です。Dev Containers 拡張が自動でポートを転送します。

ただし **VS Code の自動転送は 127.0.0.1 にしか bind できません**（bind 先を変える設定は存在しません）。そのため、複数プロジェクトを同時に開くとポートが衝突します。衝突すると VS Code は別のホストポートを自動で割り当てるため、決めたホスト名:ポートでは開けなくなります。同時に開くプロジェクトがある場合は、後述の方法で `CRIT_PORT` 等をずらしてください。

## crit のポート

crit CLI 自体のデフォルトは**ランダムポート**です。base イメージが既定値を固定しています。

```
CRIT_PORT=4588
```

ポートが固定されているのは、ホスト側の `LocalForward` を静的に書けるようにするためです。

一時的にずらしたい場合は起動時に指定します。

```sh
crit -p 4590
```

プロジェクトとして恒久的にずらす場合は、プロジェクトの Dockerfile で **ENV と `/etc/environment` の両方**を上書きします。

```dockerfile
ENV CRIT_PORT=4590
RUN sed -i 's/^CRIT_PORT=.*/CRIT_PORT="4590"/' /etc/environment
```

両方が要るのは経路によって環境の出どころが違うためです。docker exec 経由のシェル（VS Code 含む）はコンテナの ENV を引き継ぎますが、SSH セッションは sshd が environ を引き継がず、PAM（pam_env）が `/etc/environment` から環境を組み立てます。**compose の `environment:` は SSH セッションに届かない**ので、そこで上書きしてはいけません（経路によって値が食い違います）。

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

## プロジェクト側で定めること

以下は base では決まらないため、各プロジェクトの `.devcontainer/README.md` に置いてください。

- ホスト名（例: `<your-project>.test`）と、割り当てる loopback アドレス
- ポート一覧（どのサービスが何番か、環境変数の原本はどこか）
- `~/.ssh/config` の具体的な `LocalForward` 行
- サービス URL・クッキーの `Domain` とホスト名の整合（`localhost` でログインが通らない等の注意）
- `CRIT_PORT` を base の既定 4588 からずらすかどうか
