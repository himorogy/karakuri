# 次セッションへの引き継ぎ

作業ブランチ `feat/monorepo-firewall`。直近のコミットは `git log --oneline -8` で確認してください。

**この文書は作業が片付いたら削除してください。**

---

## 0. まず読むもの

| 文書 | 役割 |
|---|---|
| [`spec.md`](./spec.md) | **規範記述。§1 の不変条件 I1〜I7 が中核** |
| [`design.md`](./design.md) | なぜそう作ったか（設計判断 21 件、受容した残余リスク 5 件、却下した案の一覧） |
| [`known-issues.md`](./known-issues.md) | 未解決のもの（未実装 1・未検証 4・保留 2） |
| [`verification-record.md`](./verification-record.md) | 受け入れ検証の記録。**§2 のカバレッジ表で「どの不変条件が未確認か」が引けます** |
| [`../README.md`](../README.md) | 使い方 |
| [`web-search-fetch.md`](./web-search-fetch.md) | 外部ツールの挙動に関する参考。**§1〜§3 は Claude Code v2.1.220 で確認済み**（WebFetch は直接 egress する / 91 ドメインで要約がバイパスされる） |

文書の役割分担は意図的に分けてあります。**理由は design、規範は spec、未解決は known-issues。** 同じ内容を 2 箇所に書かないでください（以前それで重複が膨らみ、整理に 1 セッション使いました）。

検証:

```sh
# リポジトリのルートで。CI が回すのと同じ 3 つ。
pnpm lint          # biome
pnpm lint:sh       # shellcheck（ワークスペース全体へ再帰）
pnpm test          # 同上。設定 95 件 + ルール 145 件
```

> **導入済みの devcontainer の中では `140 passed, 0 failed, 5 skipped` になります。** `/etc/egress-guard/firewall.json` が存在する環境では、その 5 件が何も検査できないためです（[`verification-record.md`](./verification-record.md) §5）。CI では全件実行されます。

> `pnpm lint:sh` はこのコンテナでは動きません（shellcheck が未導入）。**CI では走ります**（`ubuntu-latest` に同梱）。手元で確かめたいときは [koalaman/shellcheck のリリース](https://github.com/koalaman/shellcheck/releases) からバイナリを落としてください。GitHub は基底プロファイルに入っているため `enforce` のままでも取得できます。

---

## 1. 次にやること（優先度順）

**2026-08-03 に enforce での常用が成立し、Docker Compose 構成の検証も完了しました。** 環境が要る未検証項目（IPv6 有効コンテナ・Linux ホスト・CI ランナー・rootless）を除けば、**残っているのは L7 proxy への移行だけ**です。

### 1.1 L7 proxy 移行（[`spec.md`](./spec.md) §10.1）の検討

**実現層の交代はこれ一本になりました。** 中間段として枠だけ置いてあった DNS 連動 allowlist（dnsmasq + `ipset=`）は、2026-08-03 に調査して**却下しました**（[`design.md`](./design.md) §2.20）。

* **常駐する `CAP_NET_ADMIN` プロセスが、エージェントの選んだ名前に対する上流応答を処理し続ける構造になる。** 現行設計には常駐する特権プロセスが 1 つもありません
* **期待していた「TTL 連動」が実装として存在しない。** dnsmasq は `IPSET_ATTR_TIMEOUT` も `IPSET_FLAG_EXIST` も送らず、追加は上流応答の解析時だけです

**§10.1 を急ぐ動機は増えています。** 2026-08-03 に、現行方式では表現できない実害が 2 件出ました。

* **`deb.debian.org`** — TTL 25 秒。`allowDomains` に書いても通らない（[`spec.md`](./spec.md) §9.7）
* **`*.gallerycdn.vsassets.io`** — VS Code 拡張の配信 CDN（[`known-issues.md`](./known-issues.md) #7）

**どちらも「名前で判定する層」に移せば消えます。** 逆に言えば、現行の L3 実現層に留まる限り、この 2 つは回避策がありません。

大きい変更なので、着手前に「ホスト側 proxy をどう配布・起動するか」を決める必要があります。`provision-devcontainer.sh` のようなホスト側スクリプトが既にあるなら、そこに寄せられるかもしれません。

---

## 2. 未解決の一覧

[`known-issues.md`](./known-issues.md) が正です。要約:

| # | 内容 | 分類 |
|---|---|---|
| 1 | インストール時のチェックサム検証がない | 未実装 |
| 2 | IPv6 が有効なコンテナでの動作（`curl -6` の実到達性） | 未検証 |
| 3 | Linux ホスト上の Docker | 未検証 |
| 4 | `host.docker.internal` が公開アドレスを返すケース | 未検証（ユニットテストで担保） |
| 5 | CI ランナー / クラウド開発環境 / rootless Docker | 未検証 |
| 6 | Dev Container Feature 化 | 保留（着手条件を記載済み） |
| 7 | VS Code 拡張の配信 CDN を allowlist できない | 保留（→ §1.1） |

加えて [`verification-record.md`](./verification-record.md) §2 の「未確認」表に、上記に載らないものが 2 件あります。

* **I3: GitHub meta API 不達でも適用が成立すること** — meta 単独の不達を再現する手順が無い
* **`SET` ターゲットが使えないカーネルでのフォールバック** — ユニットテストのみ

**Docker Compose 構成（README の第一推奨）は 2026-08-03 に検証済みです**（[`verification-record.md`](./verification-record.md) §6.22）。長く続いていた優先度の反転は解消しました。

---

## 3. 進めるときの前提

### 3.1 脅威モデル

**敵はコンテナ内で動くエージェント自身**です（[`design.md`](./design.md) §1）。「root を取られるか」ではなく「**攻撃者が目的を達成できるか**」で考えてください。この観点の欠落が、過去に指摘 1（エージェントがポリシーを書き換えられた）を生んでいます。

### 3.2 不変条件を弱める変更は仕様変更

実装や構成を変えるときは、**I1〜I7 それぞれが保存されるか**を確認してください（[`spec.md`](./spec.md) §7 の 9）。保存されない変更は、spec §1 の不変条件の書き換えを伴う明示的な決定として design.md に記録します。

### 3.3 検証を設計するときの観点

[`verification-record.md`](./verification-record.md) §4 に、**過去に見逃した 5 件と「欠けていた観点」**をまとめてあります。新しい検証項目を立てるときはここを読んでください。要点:

* 「root を取れるか」でなく「目的を達成できるか」で項目を立てる
* **検証項目は仕様を追認するだけになりうる。** 「この期待結果は望ましい状態か」を項目ごとに問う
* **初期状態を明示する。** 前回の適用が残った状態と素の状態で結果が変わる項目は両方実施する
* **異常終了の経路を網羅する。** SIGKILL だけでなく `die` する経路ごとに終了状態を確認する
* **同じ検査を要する入力経路を列挙する**（設定ファイル / DNS 応答 / meta API / `ip route` / `resolv.conf`）
* **許可機能は「許可されること」まで確認する。** 遮断の確認だけでは機能が使えるか分からない
* **文書の主張と検証項目を突き合わせる。** 対応する項目が無い主張はしない
* **落ちているテストを緑にするときは、緑にした版が変異を捕まえるか確かめる。** 期待値を環境に合わせて書き換えると、赤は消えても検査は消えたままになります。実際にそれをやりかけました（[`verification-record.md`](./verification-record.md) §5）。**確かめられない項目は緑にせず `SKIP` として件数に出してください**
* **診断そのものが記録を汚染しないか確かめる。** `egress-audit-v4` の中身を名前に戻そうとして `openssl s_client` で候補 IP を叩き、**その接続を全て自分のコンテナに記録してしまいました**（[`verification-record.md`](./verification-record.md) §6.21）。観測対象と観測手段が同じ経路を通る項目では、先に切り分け手段（ここでは `timeout` 残量からの時刻逆算）を用意してください

### 3.4 テストの落とし穴

[`spec.md`](./spec.md) §7.1 に実装側の落とし穴が、[`verification-record.md`](./verification-record.md) §3 にテスト側の落とし穴があります。特に:

* **追加する回帰テストは、必ず修正前のコードで失敗することを確認してください。** 過去に `assert_contains ... -- 'pattern'` の `--` 誤用で 12 件が空振りしていた事故があります
* スタブが単純すぎると実環境でしか出ない分岐が消えます（実装欠陥 5 件のうち 4 件がこれ）

### 3.5 devcontainer の運用

* `.devcontainer/init-project-firewall.sh` は `packages/egress-guard/scripts/` の**コピー**です。パッケージ公開までは手動で同期してください（sudoers が `node_modules` を指せないため、依存として参照できません）
* `.devcontainer/firewall.json` は codex CLI 用に `chatgpt.com` / `api.openai.com` / `auth.openai.com` を許可しています。**不要なら削ってください**
* `firewall.json` の変更は**イメージ再ビルドで反映**されます。内容の検証だけなら再ビルド不要です

  ```sh
  /usr/local/bin/init-project-firewall.sh --check-config --config .devcontainer/firewall.json
  ```
* **設定エラーは panic テーブルに倒れます。** タイプミスがあるとコンテナが閉じるので、再ビルド前に `--check-config` を通してください
* **適用されているかは毎回確かめてください。** イメージが古いと旧版のスクリプトが残り、`postStartCommand` は成功したように見えます（2026-08-03 に実際に起きました）。`curl --connect-timeout 5 https://example.com` が失敗すること、`ls -l /usr/local/bin/init-project-firewall.sh` のサイズがパッケージ側と一致することの 2 点で判別できます
* **コンテナを取り違えないでください。** `shutdownAction: none` のため、他プロジェクトの devcontainer が同時に動いています。`ipset` を読むときは `docker ps` でコンテナ ID を確かめてから `docker exec -u root <id> ...` としてください（`karakuri-dev-container` が名前です）

---

## 4. やらないと決めたこと

蒸し返さないための一覧です。詳細は [`design.md`](./design.md) §5。

| 案 | 却下の理由 |
|---|---|
| ワイルドカードを受理して apex だけ解決 | 「受理するが実現しない」は最悪の性質 |
| GET だけ全ドメイン許可 | GET は書き出しチャネル。L3/L4 では実装不能 |
| nat を退避・復元する | 非特権ユーザーは nat に書けない。守るものが無い |
| `chattr +i` で immutable にする | Docker の既定 capability で不可能。防御価値も限定的 |
| `--cap-add=SYSLOG` でログを読む | ホストと他コンテナのカーネルログが全て読めてしまう |
| `nf_log_all_netns=1` に依存する | 再起動で戻る。全コンテナのログが混ざる |
| ホスト網を包括的に許可する | ホストに Tailscale 網が繋がっている可能性 |
| sudo 経由でのみ固定パス、`--check-config` には探索を残す | 見に行く場所を増やすほど攻撃面が増える |
| 設定エラーではルールを変更しない | 初回起動時は全 ACCEPT が残る |
| IPv6 を実測してから REJECT を判断する | 実測は 1 環境・1 クライアントの結果にしかならない |
| DNS 連動 allowlist（dnsmasq + `ipset=`） | 常駐の `CAP_NET_ADMIN` プロセスに敵が選んだ入力を食わせ続けることになる。TTL 連動も実装として存在しない |
