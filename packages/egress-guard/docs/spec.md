# init-project-firewall.sh 仕様書

devcontainer 向け egress 制御スクリプトの仕様。**何が成り立つかの規範記述**です。

決定の根拠・代替案・却下した理由はここには書きません。関連文書を参照してください。

| 文書 | 内容 |
|---|---|
| [`../README.md`](../README.md) | 使い方（セットアップと運用） |
| [`design.md`](./design.md) | **なぜそう作ったか**（脅威モデル・設計判断・受容した残余リスク） |
| [`known-issues.md`](./known-issues.md) | 未解決のもの（未実装・未検証・未決） |
| [`verification-record.md`](./verification-record.md) | 受け入れ検証の記録（カバレッジ・見逃した欠陥・手順） |

---

## 1. 目的とスコープ

### 目的（守るもの）

1. **漏洩シンクの制限** — injection・暴走時に、コンテナ内の秘密・コードを書き出せる先を allowlist に限定する
2. **DNS 経路の固定** — 53 番宛を、コンテナに割り当てられたリゾルバのみに固定する。任意のネームサーバーへ直接投げる経路を塞ぎ、試行を記録する。**トンネリング本体は防げない**（許可されたリゾルバが再帰問い合わせをするため。§9.4）
3. **攻撃プラットフォーム化の防止** — default DROP により C2 通信・スキャンの踏み台化を防ぐ

### Non-goals（守らないもの・守れないもの）

* **悪性コンテンツの流入防止はしない。** INPUT 側フィルタに実効性はない
* **完全な exfil 防止は保証しない。** 許可先への GET クエリ等による低帯域漏洩は残る
* **DNS トンネリングの遮断はしない。** 許可したリゾルバが再帰問い合わせをするため（§9.4）
* **L7 制御（メソッド別・パス別の制御）はしない。** 将来の proxy 移行で扱う（§10）
* **IPv6 の allowlist は作らない。** 外向き IPv6 は全 DROP（§4.7）

想定する敵、および各 Non-goal を受容した理由は [`design.md`](./design.md) §1・§3。

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

基底プロファイルはスクリプトに埋め込みます（同梱 JSON は不可。理由は [`design.md`](./design.md) §2.17）。

### 2.1 権限モデル

**要件:**

1. `/usr/local/bin/init-project-firewall.sh` が `root:root` 所有・`755`。イメージビルド時に**コピー**して配置する
2. sudoers は固定パスかつ**引数なし**のみ許可する

   ```
   node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""
   ```

   **末尾の `""` は必須。** これを落とすと任意の引数を許すことになります
3. `firewall.json` は `/etc/egress-guard/firewall.json` に root 所有で配置する
4. `postStartCommand` で `sudo /usr/local/bin/init-project-firewall.sh` を実行する

`postCreateCommand` は既定で `remoteUser`（= `node`）として実行されるため、1・3 の配置には使えません。

**`chattr +i` は使いません。** 成立している防御は次の 2 点です。

* ファイルが `root:root` 所有・`755`・`/usr/local/bin` 配下にあり、`node` に書き込み権限がない
* `node` に許可された sudo が当該スクリプトの引数なし実行のみで、`chattr` も `cp` も実行できない

#### 起動時の配置検査

スクリプトは適用時に次を確認します。違反はすべて exit≠0（panic テーブル適用）です。

| 対象 | 検査内容 | 条件 |
|---|---|---|
| スクリプト自身 | root 所有・group/other 非書き込み | `SUDO_USER` / `SUDO_UID` がある場合のみ |
| `/etc/egress-guard/firewall.json` | root 所有・group/other 非書き込み・symlink でない | 常時（`--config` 指定時を除く） |
| `/etc/egress-guard` | root 所有・group/other 非書き込み | 同上 |

**これらが捕まえるのは設定ミスであり、攻撃者に対する防御ではありません。** 限界は [`design.md`](./design.md) §3.4。

スクリプト側には多重防御として、`SUDO_USER` / `SUDO_UID` が設定された状態で引数が渡された場合に開発用オプション（§8）を拒否する動作があります。

#### 設定内容の扱い

`firewall.json` が root 所有であることは「誰が書き換えられるか」を制約するだけで、値の正当性を保証しません。**内容は攻撃者制御データとして検証します**（§3.2）。

設計の根拠は [`design.md`](./design.md) §2.1・§2.16・§2.19。

---

## 3. firewall.json

### 3.1 設定の所在とスキーマ

**読むのは `/etc/egress-guard/firewall.json` だけです。探索は一切行いません。** 見つからない場合は基底プロファイルのみで動作します。理由は §2.1。

設定は**イメージビルドが配置するもの**であり、スクリプトが見つけ出すものではありません（理由は [`design.md`](./design.md) §2.1）。まだインストールされていないファイルを検証する場合は `--config` でパスを明示します（§8）。

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

順序の要点:

* **適用フェーズは設定を読む前に始まります。** `iptables` の存在を確認した時点から、どの失敗も閉じた状態で終わります（§4.6）
* **6 を 7 より先に行うのが本仕様の核です。** リビルド中に外部ネットワークを必要とする工程が存在しないため、途中で強制終了されても「開いたまま固定される」状態になりません
* 8 は 6 の後。`host.docker.internal` の解決は bootstrap テーブルの下で成立します
* 10 は 9 の後。`api.github.com` に到達できるのが最終テーブル適用後のためです。GitHub の主要ホストは 7 の DNS 解決で許可済みなので、10 が失敗しても GitHub は使えます

各判断の根拠は [`design.md`](./design.md) §2.2・§2.8。

### 4.3 DNS の扱い

**リゾルバは `/etc/resolv.conf` から検出します**（決め打ちにしない理由は [`design.md`](./design.md) §2.7）。

* `nameserver` 行の IPv4 アドレスをすべて収集する
* 収集したアドレス宛の UDP/TCP 53 のみ ACCEPT、それ以外の 53 番宛は DROP
* IPv4 のリゾルバが 1 つも無い場合は **exit≠0**（DNS を開放するとトンネリングでポリシー全体が無意味になるため）
* `127.0.0.11` 以外だった場合は警告を出す（ユーザー定義ネットワークのほうが強い構成である旨）

`resolv.conf` は root 所有で Docker が書き込むため、非特権ユーザーがリゾルバを差し替えることはできません。収集したアドレスは iptables に渡る前に IPv4 として検証します。

#### ルール順序

DNS の DROP ルールは**汎用の `ESTABLISHED,RELATED` ACCEPT より前**に置きます（[`design.md`](./design.md) §2.6）。

### 4.4 ルールの適用方式

**各アドレスファミリのフィルタテーブルを `iptables-restore` の単一トランザクションで置き換えます。** chain policy も同じ入力に含めます。

* チェーンが空のまま policy が ACCEPT になる中間状態が存在しない
* SIGKILL を受けても、旧テーブルか新テーブルのどちらかしか観測されない
* **nat テーブルには触りません。** `iptables-restore` は入力に含まれるテーブルしか置き換えないため、Docker の DNS DNAT は無傷のまま残ります

IPv4 と IPv6 は 1 つのトランザクションを共有できません。そのため IPv6 を先に最終状態へ確定させ、以降は触らない構成にしています。

根拠は [`design.md`](./design.md) §2.3・§2.4。

### 4.5 allowlist の構築

* live set（`egress-allow-v4`）はルールから名前で参照されるだけ。中身は staging set（`egress-allow-v4-stg`）で組み立て、`ipset swap` でアトミックに差し替える（[`design.md`](./design.md) §2.5）
* swap の時点で live なのは bootstrap テーブルであり、そのテーブルは set を参照しません。したがって**部分的に構築された allowlist を参照するルールは存在しません**
* staging は毎回作り直すため、前回の内容に依存しません（冪等性の根拠）
* 基底プロファイルのドメイン、GitHub の主要ホスト、`firewall.json` のドメインを DNS で解決して投入
* `firewall.json` の CIDR をそのまま投入
* 最終テーブル適用後に GitHub meta API の CIDR を live set へ追加

#### DNS 応答のアドレス検査

**名前解決で得た IP も禁止レンジ（§3.2 の表）に照らします。** 該当するアドレスは警告して allowlist に入れません（[`design.md`](./design.md) §2.9）。

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

**設定エラーでも panic に倒します**（[`design.md`](./design.md) §2.8）。タイプミスの検出は `--check-config`（§8）で行ってください。

panic テーブル:

```
:INPUT DROP / :FORWARD DROP / :OUTPUT DROP
-A INPUT  -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A INPUT  -p tcp --dport <sshdPort> -j ACCEPT
-A OUTPUT -p tcp --sport <sshdPort> -m conntrack --ctstate ESTABLISHED -j ACCEPT
```

**OUTPUT の汎用 ESTABLISHED は含めません。** 含めると、失敗前に確立された exfil 接続が動き続けます。`docker exec` による接続はネットワークスタックを経由しないため、対話アクセスは維持されます。

SIGKILL では trap が発火しません。それでも「開いたまま」が残らないのは §4.4 の適用方式と §4.2 の順序によるものです。ただし**スクリプトが最初の `iptables-restore` に到達する前に殺された場合**は何も変更されず、直前の状態が残ります。これは「エラーだが全開で起動」ではなく「スクリプトが走らなかった」状態で、`postStartCommand` の失敗としてコンテナ起動側に伝わります。

### 4.7 IPv6

**外向き IPv6 は allowlist を持たず全 DROP です。** loopback（`::1`）のみ通します。audit モードでも DROP のままで、試行は `fw-drop6:` のログに残ります。理由は [`design.md`](./design.md) §2.12。

#### ip6tables が使えない場合

「`ip6tables` が無い = IPv6 が無い」という推論は成り立ちません（[`design.md`](./design.md) §2.13）。判定は次のとおりです。

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

`host.docker.internal` の解決結果は、**私設アドレス（RFC1918 / CGNAT / link-local）であることを確認**します。該当しないアドレスは警告して使いません。

両方を対象にする理由とアドレス検査の根拠は [`design.md`](./design.md) §2.15。

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

リゾルバ宛の ACCEPT より後にあるため、正規の問い合わせは記録されません。bootstrap テーブルにはこの記録ルールを入れません（[`design.md`](./design.md) §2.11）。

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

**運用の前提にしません。** 出力される環境では時刻とポートも取れるため残してあります（[`design.md`](./design.md) §2.11）。

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

**プローブは、実際に対象外であることを確認してから選びます**（[`design.md`](./design.md) §2.14）。

* 外部 DNS のプローブ — `8.8.8.8` → `1.1.1.1` → `9.9.9.9` の順に試し、**設定済みリゾルバでない**ものを選ぶ
* 未許可先のプローブ — `example.com` → `example.net` → `example.org` の順に試し、解決した IP が**すべて allowlist 外**であるものを選ぶ

どれも使えない場合は警告付きでスキップします（検証を「成功」にはしません）。

### 5.2 判定の精度

`dig` は NXDOMAIN や SERVFAIL でも exit 0 を返すため、終了コードだけでは判定しません。**IPv4 形式の回答が実際に返ったか**で判定します。

`firewall.json` のドメイン検証は接続ではなく `ipset test` で行います。データベース等の非 HTTP サービスが多く、到達性テストが成立しないためです。

**判定は「再解決した IP のうち**いずれか**が allowlist に載っていれば成功」とします**（[`design.md`](./design.md) §2.14）。禁止レンジのアドレスは判定対象から除きます（§4.5）。

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
2. **実効設定は root 所有の `/etc/egress-guard/firewall.json` のみ**（§2.1）。エージェントが書けるファイルを適用経路に入れない。repo 側のコピーは PR レビュー必須ファイルとして扱う。内容は攻撃者制御データとして検証する（§3.2）
3. **文字列の取り扱い** — `firewall.json` 由来の値を検証前にシェル・iptables/ipset に渡さない
4. **サプライチェーン** — スクリプトは root で動く。プライベートレジストリ＋lockfile 固定を維持する。配置時のチェックサム検証は未実装（[known-issues](./known-issues.md)）
5. **DNS を全開放にしない** — 割り当てられたリゾルバへの固定が本仕様の核。緩めるとトンネリングで全体が無意味化する
6. **IPv6 を忘れない**（§4.7）
7. **fail-closed の一貫性** — 適用フェーズに入って以降のあらゆる失敗（設定エラーを含む）は panic + exit≠0。ルール未適用で終わってよいのは、`iptables` が使えると確認する前だけ。「エラーだが全開で起動」は作らない（§4.6）
8. **受容した残余リスク**は [`design.md`](./design.md) §3 にまとめてある。レビュー時はそこに載っていないものが新たに増えていないかを見る

### 7.1 実装上の落とし穴（回帰させないこと）

実機検証で顕在化した、再発しやすい欠陥です。

* **`IFS=$'\n\t'` の下で `"$*"` を使わない。** 改行で連結され、1 行のルールが複数行に割れます。空白連結が必要な箇所では `local IFS=' '` を使ってください
* **パイプの下流で早期終了しない。** `head -n1` / `grep -q` / `awk '...; exit'` は上流を SIGPIPE で殺し、`set -o pipefail` + `set -e` の下ではスクリプト全体が落ちます。出力をいったん変数に受けてから処理してください
* **自己検証のプローブをハードコードしない**（§5.1）
* **自己検証を「最初の 1 IP」で判定しない**（§5.2）。DNS ラウンドロビンで起動がランダムに失敗します
* **DNS 応答を検証済みデータとして扱わない**（§4.5）。`allowCidrs` にある検査は、名前解決の結果にも要ります
* **配置の検査は競合には勝てない**（[`design.md`](./design.md) §3.4）。**防いでいるのは誤設定であって、競合する攻撃者ではありません。** ここを強い保証として扱う記述を書かないこと
* **外部コマンドに渡す前にアドレスファミリで絞る。** GitHub meta API は IPv6 プレフィックスも返します。`aggregate` の挙動はビルドによって異なるため、渡す前に IPv4 だけにしてください

---

## 8. 開発用オプション

```
--check-config           設定を検証して終了（ルールに触れない）
--config <path>          固定のパスではなくこのファイルを読む
--resolv-conf <path>     /etc/resolv.conf ではなくこのファイルからリゾルバを読む
```

`--check-config` を単体で使うとインストール済みの設定（`/etc/egress-guard/firewall.json`）を検証します。`--config` と組み合わせると、再ビルドで配置される前の repo 側コピーを検証できます。**この 2 つは設定の所在を変えません**（§3.1）。

`--check-config` を残している理由は [`design.md`](./design.md) §2.18。

いずれも開発・テスト専用です。**`SUDO_USER` / `SUDO_UID` が設定された状態で引数が渡された場合は拒否します。** sudoers が正しく書かれていれば、そもそも sudo 経由では到達しません。

`--config` で明示指定した場合は所有者検証を行いません（sudo 経由では到達できない開発用の抜け道であり、インストール前のファイルを検証する際の障害にしないため）。

---

## 9. 仕様上の制限

**決定済みの制限**です。実装が追いついていないのではなく、そう決めた結果としてこうなっています。判断の根拠は [`design.md`](./design.md)、未解決のものは [`known-issues.md`](./known-issues.md)。

### 9.1 ワイルドカードドメインは使用不可

`*` を含む `allowDomains` エントリはバリデーションで拒否します。拒否メッセージには回避策（具体的なホスト名の列挙、audit モードでの特定）を含めます。

```
rejected allowDomains entry: *.example.com - wildcards are not supported. DNS cannot
enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses.
List the host names you need instead; run in audit mode and read ipset egress-audit-v4
to find out which ones those are.
```

L7 proxy（§10）への移行時にスキーマ version 2 で再導入します。根拠は [`design.md`](./design.md) §2.10。

### 9.2 「GET を全ドメイン許可」はできない

L3/L4 では HTTP メソッドが見えず、L4 で表現すると 443 番の全開放になります。また GET 自体が書き出しチャネルであるため、許可すれば §1 の目的 1 が無効になります。

**この要求の大半はそもそも成立しない可能性があります。** Claude Code の WebSearch / WebFetch が Anthropic 側で完結するなら、コンテナから任意ドメインへの egress は不要です。**未実測です** — 根拠と確認手順は [`web-search-fetch.md`](./web-search-fetch.md)。

コンテナから直接取得する必要がある場合は、そのドメインを `allowDomains` に個別追加します。

### 9.3 適用前に確立された接続は継続する

最終テーブルは `ESTABLISHED,RELATED` を ACCEPT するため、適用前に確立されていた allowlist 外への TCP 接続は継続できます。DNS だけは例外です（§4.3）。panic テーブルには OUTPUT の ESTABLISHED 許可がありません。

受容の理由は [`design.md`](./design.md) §3.3。

### 9.4 DNS トンネリングは防げない

53 番の宛先はリゾルバ 1 つに固定していますが、**そのリゾルバは再帰問い合わせをします。** 得られている性質は「経路の固定と、それ以外の試行の遮断・記録」であって、トンネリングの遮断ではありません。埋め込みリゾルバ `127.0.0.11` でも同じです。

受容の理由と対策の選択肢は [`design.md`](./design.md) §3.1。

### 9.5 配置検査は競合する攻撃者には勝てない

§2.1 の配置検査が捕まえるのは設定ミスです。TOCTOU、および悪意をもって差し替えられたスクリプトには無効です。[`design.md`](./design.md) §3.4。

### 9.6 ポリシー変更にイメージ再ビルドが要る

§2.1 の帰結です。`--check-config` で内容の検証だけは再ビルド不要で行えます。[`design.md`](./design.md) §3.5。

---

## 10. 将来拡張

* **L7 proxy 移行** — ホスト側に proxy を置く段階になったら、本スクリプトは「proxy 宛 + DNS 固定のみ許可」に縮小し、ドメイン/メソッド ACL は proxy 側 per-project 設定へ移す。`firewall.json` のスキーマは proxy 設定へ変換可能な形（ドメインリスト中心）を維持する。§9.1 と §9.2 はここで解消する
* **IPv6 allowlist** — 必要になった場合、`hash:net family inet6` の set 追加、AAAA 解決、`emit_filter_v6` への ACCEPT 1 行、GitHub meta の v6 レンジ取得で対応できる構造になっている
* **NFLOG** — 時刻・ポートまで必要になった場合、`LOG` を `NFLOG` に置き換えるとコンテナ内から `tcpdump -i nflog:1` で読めます（`nfnetlink_log` は netns 対応）。現状は ipset 記録で足りているため見送り
* **Claude Code sandbox 併用** — 現状 devcontainer 内 sandbox は namespace 制約で非推奨。devcontainer を外す判断をした場合は本スクリプト自体が不要になり、`.claude/settings.json` に役割が移る

---

## 11. 受け入れ基準

実装レビューおよび実機検証の基準です。各項目が実際に確かめられているかは [`verification-record.md`](./verification-record.md) §2 のカバレッジ表を参照してください。

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
