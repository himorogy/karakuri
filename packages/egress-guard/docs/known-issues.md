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

> **「AAAA を持つ許可先への足踏み」はここから外しました。** 当初は未検証事項として挙げていましたが、実測を待たず設計で解消したためです。経緯は [`design.md`](./design.md) §2.12 の代替案。

---

## 3. Linux ホスト上の Docker

**分類:** 未検証

実機検証はすべて linuxkit VM（Docker Desktop / macOS）上です。Linux ホストでは次が変わります。

* **デフォルトブリッジのリゾルバが実在のネットワーク機器になる** — 家庭用ルータや社内 DNS サーバーを指すため、「実機の 53 番への到達経路が 1 本開く」意味合いが Docker Desktop より大きくなります（[`design.md`](./design.md) §4.2）
* **`systemd-resolved`（`127.0.0.53`）を使うホスト** — デフォルトブリッジでは Docker が公開 DNS へフォールバックします（何にフォールバックするかは [`design.md`](./design.md) §4.2）。この挙動下での動作は未確認です。ユーザー定義ネットワークを使えば回避できます
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

パッケージ導入を [Dev Container Feature](https://containers.dev/implementors/features/) にまとめる案です。**Feature 側に移せるもの・移せないもの、`firewall.json` の渡し方の検討（案 A / B / C）、採用しない理由は [`design.md`](./design.md) §2.21 へ移しました。**

### 着手する条件

`egress-guard` を他プロジェクトで実際に再利用する段階になったら、**案 C**（[`design.md`](./design.md) §2.21）で再検討します。それまでは README の `Dockerfile` スニペットを複製する方式のほうが、監査可能性と `docker build` 互換の両方を保てます。

---

## 7. VS Code 拡張の配信 CDN を allowlist できない

**分類:** 保留（[`spec.md`](./spec.md) §10.1 待ち。現行方式では回避策がありません）

拡張のカタログは `marketplace.visualstudio.com`（基底プロファイルの `vscode` バンドル）ですが、**実体を配るのは `*.vsassets.io` の 2 系統**です。ここが遮断されると**拡張のインストールが失敗します**。`~/.vscode-server/extensions` はボリュームに載っていないため、**再ビルドのたびに再ダウンロードが必要**です。

**2 系統ある点は 2026-08-19 に実測して分かりました。** 当初この項目は `*.gallerycdn.vsassets.io` だけを挙げていましたが、**1 つの拡張のインストールで次の両方へ接続します。**

```
CONNECT davidanson.gallerycdn.vsassets.io:443
CONNECT davidanson.gallery.vsassets.io:443      ← "cdn" が付かない別ホスト
```

**片方だけ許可しても拡張は入りません。** 名前ベースの ACL へ移す際は、`.gallerycdn.vsassets.io` と `.gallery.vsassets.io` の両方が要ります。

**`marketplace.visualstudio.com` を許可しても届きません。** あれはカタログ API で、実体は別系統です。2026-08-03 の解決結果:

```
marketplace.visualstudio.com    150.171.73.16  150.171.74.16
vscode.blob.core.windows.net    20.150.83.4
update.code.visualstudio.com    150.171.110.137
実際に観測した宛先              23.52.106.50  23.52.128.81  23.52.128.85
                                23.62.21.90   23.11.39.161  23.208.85.184
```

重なりがありません。**この 3 つは `vscode` バンドルに入っているので、それを選んでいれば「入れてあるのに拡張が入らない」という形で現れます。**

allowlist に載せる手段が両方とも塞がっています。

* **ワイルドカードは受理されません**（[`spec.md`](./spec.md) §9.1）
* publisher 別の具体名（`anthropic.gallerycdn.vsassets.io` など）なら書けますが、**いずれも同じ Akamai プロパティへの CNAME で、IP が回ります。** 2026-08-03 の観測では 2 コンテナで **6 つの異なる IP** に散りました（上記）

**起動時スナップショット方式の弱点（[`spec.md`](./spec.md) §9.7 の CDN drift）が実害として出た最初の例です。** 名前で判定する層に移せば構造ごと解消します。

**この項目と §9.7 の 2 件をもって、[`spec.md`](./spec.md) §10.1（L7 proxy 移行）に着手する判断をしました。** 配置（sidecar コンテナ）・TLS を終端しないこと・接続方式（明示型）は [`design.md`](./design.md) §2.23 で確定しています。実装は未着手です。

### 移行の前提だった未確認事項は解決しました（2026-08-19）

明示型 proxy は `HTTP_PROXY` / `HTTPS_PROXY` に従うクライアントにしか効きません。**VS Code Server の拡張ギャラリークライアントがこれを読むという明文が公式ドキュメントに無く、読まなければこの項目は明示型では解消しない**、という状態でした。

**実測して、読むことを確認しました。** `HTTPS_PROXY` を向けた先で受け取った最初の行を記録するだけのリスナ（[`../poc/l7-proxy/test-helpers/connect-sniffer.py`](../poc/l7-proxy/test-helpers/connect-sniffer.py)）を立て、拡張をインストールしたところ、上記の 2 系統への `CONNECT` が届きました。

**確認できたのは「proxy 設定を読むこと」までです。** このリスナは中継せず 502 を返して切るため、拡張のインストールが成功することはこの時点では確かめていません。

### PoC で 2 系統とも allowlist に載ることを確認しました（2026-08-19）

同じ日に PoC を回し、**`.gallerycdn.vsassets.io` と `.gallery.vsassets.io` のサフィックスマッチ 2 行だけで、`allowed-domains.txt` に書いていない具体名（`anthropic.gallerycdn.vsassets.io` 等）が通ること**を確認しました。proxy のアクセスログにその具体名が残るため、サフィックスマッチが効いたことも裏付けられています。記録は [`verification-record.md`](./verification-record.md) §6.24。

**この項目の核である「ワイルドカードが書けないから allowlist できない」は、名前で判定する層に移せば解消します。**

**通しでも確認しました（同日）。** VS Code でアタッチした devcontainer から Squid 越しに拡張をインストールし、proxy のアクセスログに 2 系統とも `TCP_TUNNEL/200` が残ることを確かめています（[`verification-record.md`](./verification-record.md) §6.24）。**この項目は L7 proxy 移行で解消することが実証されました。**

**項目としては、実装が入るまでここに残します。** 現時点で存在するのは PoC であって、`init-project-firewall.sh` の縮小も `firewall.json` からの ACL 変換もまだありません。

> **あわせて分かったこと:** `gallery.vsassets.io` は `marketplace.visualstudio.com` と同じアドレスを返します。上の 2026-08-03 の表で「重なりがありません」としたのは `gallerycdn` 側についてであり、**`gallery` 側は重なっていました。** `enforce` でも一部の拡張が入る理由がここから説明できます（[`verification-record.md`](./verification-record.md) §6.24 の副産物）。

コンテナ内に DNS 連動の allowlist を挟む案でも解消しますが、**別の理由で却下しました**（[`design.md`](./design.md) §2.20）。

現状は「拡張はイメージビルド時に入れておく」か「拡張の更新を諦める」かの二択です。

この項目から分けて置いたものが 2 つあります。

* **ワイルドカードを受理していたら何が起きるか**（`*.gallerycdn.vsassets.io` は literal で引けてしまい、apex 解決より悪い形になること）は [`design.md`](./design.md) §2.10。
* **`enforce` と `audit` で入る拡張を比べる手順**は [`verification-record.md`](./verification-record.md) §6.23。
