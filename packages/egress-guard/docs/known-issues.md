# 未解決の課題

**まだ解決していないものだけ**を記録します。

* **決定済みの制限**（ワイルドカード不可、GET 全許可の拒否、`chattr +i` 不使用など）は [`spec.md`](./spec.md) §9
* **受容した残余リスク**（DNS トンネリング、低帯域 exfil、TOCTOU など）は [`design.md`](./design.md) §3
* **設計判断の根拠**は [`design.md`](./design.md) §2

解決したもの・受容を決めたものはこの文書から消し、上記へ移します。ここに残るのは**いつか手を付けるもの**と、**着手条件を定めて保留したもの**だけです。

分類:

* **未実装** — やると決めているが手を付けていない
* **未検証** — 実装は済んでいるが、実環境での確認が終わっていない
* **保留** — 調査済みで採用しうるが、着手する条件が揃っていない

---

## 1. インストール時のチェックサム検証がない

**分類:** 未実装

スクリプトは root で動作します。パッケージの改竄に対しては、プライベートレジストリと lockfile の固定に依存しており、`/usr/local/bin` へのコピー時にチェックサムを検証する仕組みはありません。

イメージビルド時のハッシュ検証を入れるのが望ましい状態です。

---

## 2. IPv6 が有効なコンテナでの動作

**分類:** 未検証

検証環境のコンテナには `lo` の `::1` しか IPv6 アドレスがありません。`--ipv6` や `enable_ipv6` で IPv6 を有効にした構成は未確認です。

### 確認したいこと

* **`curl -6` による遮断の実到達性** — global IPv6 アドレスが無いため、自己検証でも恒常的にスキップされます
* **IPv6 が有効な状態で allowlist の性質が保たれるか** — IPv4 の allowlist を IPv6 経路が素通りしないこと（[`design.md`](./design.md) §2.12 の 1 番目の理由）

### 解消済み: AAAA を持つ許可先への足踏み

当初は「AAAA を持つ許可先への接続が、IPv6 の silent DROP でタイムアウト待ちになるのではないか」を未検証事項として挙げていました。

**これは実測を待たず設計で解消しました。** IPv6 の OUTPUT 末尾に `-j REJECT --reject-with icmp6-adm-prohibited` を置いたため、IPv4 へのフォールバックは即座に起こります（[`spec.md`](./spec.md) §4.7、[`design.md`](./design.md) §2.12）。クライアントが Happy Eyeballs を実装しているかどうかに依存しなくなりました。

**実測しても解決にはなりませんでした。** 得られるのは 1 つの環境・1 つのクライアントについての結果であり、環境依存の不確実性は残ったままです。

---

## 3. Linux ホスト上の Docker

**分類:** 未検証

実機検証はすべて linuxkit VM（Docker Desktop / macOS）上です。Linux ホストでは次が変わります。

* **デフォルトブリッジのリゾルバが実在のネットワーク機器になる** — 家庭用ルータや社内 DNS サーバーを指すため、「実機の 53 番への到達経路が 1 本開く」意味合いが Docker Desktop より大きくなります（[`design.md`](./design.md) §4.2）
* **`systemd-resolved`（`127.0.0.53`）を使うホスト** — デフォルトブリッジでは Docker がループバックを除外して `8.8.8.8` / `8.8.4.4` にフォールバックします。この挙動下での動作は未確認です。ユーザー定義ネットワークを使えば回避できます
* `iptables` のバックエンド（`nf_tables` / `legacy`）やディストリビューションによる差異

---

## 4. `host.docker.internal` が公開アドレスを返すケース

**分類:** 未検証（ユニットテストで担保）

公開アドレスが返った場合にポートを開かないことは、**実機では再現できませんでした。** 偽の DNS 応答をコンテナ内から作れないためです。

`/etc/hosts` に細工しても効きません。`resolve_domain` は `dig` を先に試し、**Docker Desktop は `host.docker.internal` を DNS で解決する**ため `getent` フォールバックに到達しないためです。

`tests/firewall-rules.test.sh` の `hostpublic` ケース（`FW_HOST_INTERNAL_PUBLIC=1` で `getent` に `8.8.8.8` を返させる）で次を検証しています。

* `8.8.8.8` 宛のルールが生成されない
* ゲートウェイ宛のルールは残る
* `not a private address` の警告が出る
* 実行は失敗しない

---

## 5. CI ランナー / クラウド開発環境 / rootless Docker

**分類:** 未検証

* **GitHub Codespaces 等**での動作
* **rootless Docker** — `NET_ADMIN` の扱いが変わります

---

## 6. Dev Container Feature 化

**分類:** 保留

現在は `Dockerfile` がパッケージ導入の全てを担っています（`iptables` 等の apt 導入、スクリプトの `/usr/local/bin` への配置、`firewall.json` の `/etc/egress-guard` への配置、sudoers の生成）。これを [Dev Container Feature](https://containers.dev/implementors/features/) にすれば、導入側の `Dockerfile` を短くできます。**実現は可能ですが、現時点では採用しません。**

### Feature 側に移せるもの

`Dockerfile` から次が消えます（約 25 行）。

* apt 導入の `iptables` / `ipset` / `iproute2` / `dnsutils` / `aggregate` / `jq`
* `COPY init-project-firewall.sh` と `chown` / `chmod`
* sudoers の生成
* `USER root` ↔ `USER node` の往復（Feature はイメージビルド後に root で実行され、完了後に元の `USER` へ戻るため不要）

`devcontainer.json` からは次を Feature 側の宣言に移せます。

* `--cap-add=NET_ADMIN` / `NET_RAW` → Feature の `capAdd`
* `postStartCommand`

### Feature 側に移せないもの

* **`initializeCommand`（`docker network create`）** — ホスト側で実行されるもので、Feature が宣言できるプロパティに含まれません
* **`--network=egress-guard-*`** — `runArgs` は Feature の宣言対象外です。Feature が宣言できるのは `init` / `privileged` / `capAdd` / `securityOpt` / `entrypoint` / `mounts` / `containerEnv` / `customizations` と各ライフサイクルフックに限られます
* **`waitFor: "postStartCommand"`** — 利用側の `devcontainer.json` での指定が必要です

つまり **`devcontainer.json` はほとんど短くなりません。得られるのは `Dockerfile` の簡略化だけです。**

### `firewall.json` をどう渡すか

ここが本題です。プロジェクト固有の `firewall.json` を root 所有の固定パスへ置く方法（[`design.md`](./design.md) §2.1）が問題になります。

* **`install.sh` はワークスペースのファイルを読めません。** イメージビルド時に実行されるため、ワークスペースはまだマウントされていません。読めるのは Feature 自身のディレクトリの中だけです
* **Feature のライフサイクルフックはワークスペースを読めますが、`/etc` に書けません。** `onCreateCommand` 等はワークスペースがマウントされた状態で走りますが、`remoteUser`（= `node`）として実行されるためです

つまり「フックで repo の `firewall.json` を `/etc` へコピーする」という抜け道はありません。

**案 A: Feature の options で渡す**

```jsonc
"ghcr.io/<owner>/egress-guard:1": {
  "allowDomains": "chatgpt.com,api.openai.com",
  "mode": "enforce"
}
```

`install.sh` が `/etc/egress-guard/firewall.json` を生成します。書き込み経路の信頼モデルは現行と同等です（`devcontainer.json` も非特権ユーザーが書けますが、反映にはイメージ再ビルドが要ります）。

問題は**設定を受け取る経路が、テストの無いシェルスクリプトに移る**ことです。

* Feature の options は文字列と真偽値しか取れないため、配列はカンマ区切りに退化します。`install.sh` にカンマ区切り文字列から JSON を組み立てる処理が入ります
* その生成処理は**既存のテストスイートの対象外**です。`tests/firewall-config.test.sh` が守っているのは `read_config` から先だけで、その手前に新しいコード経路が増えます
* クォートを誤ると壊れます。`allowDomains` に `a.com","allowCidrs":["0.0.0.0/0` のような値を入れられたときに JSON 構造を破れないことを、`install.sh` 側で保証する必要があります。適用時の検証（`validate_cidr`、未知フィールド拒否）が最終的に弾くため致命傷にはなりませんが、**防御が 1 段だけになります**
* `--check-config` で事前に検証する経路も失われます

**案 B: ローカル Feature**

`./.devcontainer/features/egress-guard/` に置けばディレクトリごとコピーされるため `firewall.json` を同梱できます。ただし OCI 配布ができず、Feature 化の主目的である再利用性が失われます。

**案 C: ハイブリッド（採用するならこれ）**

Feature はスクリプト・依存パッケージ・sudoers だけを担い、`firewall.json` は導入側の `Dockerfile` が配置します。

```dockerfile
COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard && chmod 644 /etc/egress-guard/firewall.json
```

`Dockerfile` に 3 行残りますが 25 行が消えます。プロジェクト固有のポリシーがリポジトリ内の JSON のまま残るため、既存の検証・テスト資産をそのまま使えます。

**ただし案 C には穴があります。** Feature 側でスクリプト・sudoers・`postStartCommand` が揃うため、**導入側が `COPY firewall.json` を書き忘れても静かに動きます。** firewall は適用され、自己検証も通り、基底プロファイルだけの状態で正常起動します。プロジェクト固有の許可が全部消えていることに気づけません。

現在は README の 4 項目がセットで、どれか欠ければ実行できない（sudoers 無し）か、`no firewall.json found` が出ます。しかもこの行は WARNING ですらない `info` なので、Feature 化して「設定だけ欠けて他は揃っている」状態が作れるようになると、なおさら埋もれます。

### 採用しない理由

* **セキュリティ機構を外部依存にすることになります。** 現在はスクリプトの実体がリポジトリにあり、差分で監査できます。OCI Feature の `:1` のような可変タグはサプライチェーン面を増やすため `@sha256:` でのピン留めが要りますが、ピン留めするとバージョン更新が手作業に戻り、Feature 化の利点が半減します

  具体的な帰結があります。`assert_script_is_root_owned`（[`design.md`](./design.md) §2.19）は `/usr/local/bin/init-project-firewall.sh` が root 所有であることしか見ず、**それが正しいスクリプトかは検証しません。** これは現在も同じですが、現在は「実体がリポジトリにあり差分で監査できる」ことが補っています。Feature 化するとその補いが消えます（§3.4 で「捕まえるのは設定ミスであって攻撃者ではない」と明記した検査の、有効範囲が狭まります）
* **設定の置き忘れが検出できなくなります**（案 C の穴。上記）
* **素の `docker build` では適用されません。** Feature は `devcontainer build` や VS Code の経路でのみ処理されます。CI が `docker build` でイメージを作ると、ファイアウォールの入っていないイメージが何の警告もなく出来上がります。fail-closed を旨とする設計と噛み合いません
* **二重管理になります。** `packages/egress-guard/scripts/` と Feature 内のコピーを同期するリリース手順が要ります
* 得られるのが `Dockerfile` 25 行の削減だけで、上記のコストに見合いません

### 着手する条件

`egress-guard` を他プロジェクトで実際に再利用する段階になったら、**案 C** で再検討します。それまでは README の `Dockerfile` スニペットを複製する方式のほうが、監査可能性と `docker build` 互換の両方を保てます。

---

## 7. VS Code 拡張の配信 CDN を allowlist できない

**分類:** 保留（§10.2 の採否待ち。現行方式では回避策がありません）

拡張のカタログは `marketplace.visualstudio.com`（基底プロファイル）ですが、**実体を配るのは `*.gallerycdn.vsassets.io`** です。ここが遮断されると**拡張のインストールが失敗します**。`~/.vscode-server/extensions` はボリュームに載っていないため、**再ビルドのたびに再ダウンロードが必要**です。

**`marketplace.visualstudio.com` を許可しても届きません。** あれはカタログ API で、実体は別系統です。2026-08-03 の解決結果:

```
marketplace.visualstudio.com    150.171.73.16  150.171.74.16
vscode.blob.core.windows.net    20.150.83.4
update.code.visualstudio.com    150.171.110.137
実際に観測した宛先              23.52.106.50  23.52.128.81  23.52.128.85
                                23.62.21.90   23.11.39.161  23.208.85.184
```

重なりがありません。**この 3 つは基底プロファイルに入っているので、「入れてあるのに拡張が入らない」という形で現れます。**

allowlist に載せる手段が両方とも塞がっています。

* **ワイルドカードは受理されません**（[`spec.md`](./spec.md) §9.1）
* publisher 別の具体名（`anthropic.gallerycdn.vsassets.io` など）なら書けますが、**いずれも同じ Akamai プロパティへの CNAME で、IP が回ります。** 2026-08-03 の観測では 2 コンテナで **6 つの異なる IP** に散りました（上記）

### ここでワイルドカードを受理していたら

**`*.gallerycdn.vsassets.io` は literal で引けます。** DNS のワイルドカードレコードそのものが応答するためです。

```
dig +noall +answer A '*.gallerycdn.vsassets.io'   → 184.85.102.26  184.85.102.48
```

**引けたうえで、実際に使われる `23.*` とは別の IP が返ります。** 受理する実装なら「解決成功」としてこの 2 つを allowlist に入れ、通信は落ちます。ログ上は成功しているため、原因に辿り着くのが難しくなります。

[`design.md`](./design.md) §5 は「ワイルドカードを受理して apex だけ解決」を**「受理するが実現しない」は最悪の性質**として却下しましたが、**これはそれより悪い形です。** apex 解決なら別の名前を引いていると分かります。ワイルドカード専用の A レコードが返る場合は、正しく解決できたようにしか見えません。

**CDN によって成否が分かれる点も質が悪いところです。** Cloudflare の R2（`*.r2.cloudflarestorage.com` → `172.64.190.1` / `172.64.66.1`）は anycast がフラットなため、同じ手が**たまたま成立します**。動く例が先にあると、動かない例に当たったとき実装ではなく環境を疑うことになります。

**起動時スナップショット方式の弱点（§9.1 の CDN drift）が実害として出た最初の例です。** [`spec.md`](./spec.md) §10.2 の DNS 連動 allowlist を採れば構造ごと解消します。**この項目は §10.2 の採否を判断する材料として扱ってください。**

現状は「拡張はイメージビルド時に入れておく」か「拡張の更新を諦める」かの二択です。

### `enforce` で実際に減ることを確認した

2026-08-03、同じワークスペースで両モードを比べた結果です（VS Code の UI 上での確認）。

| モード | 入った拡張 |
|---|---|
| `enforce` | `anthropic.claude-code`、`biomejs.biome` |
| `audit` | 上記に加えて `ms-vscode.js-debug-companion`、`ms-ceintl.vscode-language-pack-ja` |

**`enforce` では 2 つ足りません。** `gallerycdn` の遮断と整合します。

**ただし「全滅する」わけではない点に注意してください。** `enforce` でも 2 つは入っており、この差がどこから来るのかは未確認です（別経路で取得しているのか、キャッシュから復元されたのか）。**「拡張が入らない」ではなく「一部が入らない」が正確な記述です。**
