# 次セッションへの引き継ぎ

作業ブランチ `feat/monorepo-firewall`。直近のコミットは `git log --oneline -8` で確認してください。

**この文書は作業が片付いたら削除してください。**

---

## 0. まず読むもの

| 文書 | 役割 |
|---|---|
| [`spec.md`](./spec.md) | **規範記述。§1 の不変条件 I1〜I7 が中核** |
| [`design.md`](./design.md) | なぜそう作ったか（設計判断 20 件、受容した残余リスク 5 件、却下した案の一覧） |
| [`known-issues.md`](./known-issues.md) | 未解決のもの（未実装 1・未検証 5・保留 1） |
| [`verification-record.md`](./verification-record.md) | 受け入れ検証の記録。**§2 のカバレッジ表で「どの不変条件が未確認か」が引けます** |
| [`../README.md`](../README.md) | 使い方 |
| [`web-search-fetch.md`](./web-search-fetch.md) | 外部ツールの挙動に関する参考。**§1 は実測済み**（WebFetch は直接 egress する） |

文書の役割分担は意図的に分けてあります。**理由は design、規範は spec、未解決は known-issues。** 同じ内容を 2 箇所に書かないでください（以前それで重複が膨らみ、整理に 1 セッション使いました）。

検証:

```sh
cd packages/egress-guard
pnpm test          # 設定 95 件 + ルール 145 件
pnpm lint:sh
npx biome check .
```

---

## 1. 次にやること（優先度順）

### 1.1 devcontainer イメージの再ビルド（最優先）

**このリポジトリのコンテナに egress-guard が適用されていません。** コミット 4477ba0 の devcontainer 変更がイメージに反映されていないためです。2026-08-03 時点の症状:

* `curl https://example.com` が 200 を返す（遮断されていない）
* コンテナの IP が `172.17.0.3` = デフォルトブリッジ。`egress-guard-karakuri` 網ではない
* `/usr/local/bin/init-project-firewall.sh` が 4.6 KB の**旧 anthropic 版**（`allowed-domains`）。egress-guard 版（49 KB）は入っていない

つまり**現在このコンテナで動くエージェントは外部へ無制限に出られます。** Dev Containers: Rebuild Container で解消します。

再ビルド後、続けて次の 2 つを実施してください。

* [`verification-record.md`](./verification-record.md) §6.19 の 19.3 — **WebFetch が遮断されたときのフォールバック挙動**（下記 1.2 の前提）
* §6.2 の 2.1〜2.5 — 適用そのものの確認

### 1.2 WebFetch の扱いの確定（再ビルド直後・5 分）

**WebSearch / WebFetch の egress は実測済みです**（2026-08-03、Claude Code v2.1.220）。結果は当初の推論と逆でした。

* **WebFetch はコンテナ内の `claude` プロセスが取得先へ直接 TCP 接続する。** `allowDomains` に無いドメインは取得できない
* **WebSearch は egress しない。** 追加設定なしで使える

反映済み: [`web-search-fetch.md`](./web-search-fetch.md) §1、[`spec.md`](./spec.md) §9.2、README、[`known-issues.md`](./known-issues.md) 項目 5、[`verification-record.md`](./verification-record.md) §1・§2・§6.19。

残っているのは 1 点だけです。**測定は egress-guard 未適用の状態で行ったため、直接接続が REJECT されたときの挙動を観測していません。** フォールバックするなら文書の記述を緩める必要があります。判定は §6.19 の 19.3（WebFetch を 1 回実行するだけ）。

> **1.2 の結論が出るまで、`allowDomains` 外の WebFetch に依存する作業を計画しないでください。** 下記 1.3 の dnsmasq 調査がこれに該当します。

### 1.3 論点 2 — DNS 連動 allowlist（dnsmasq + `ipset=`）の調査

[`spec.md`](./spec.md) §10.2 に「採否未決」として枠だけ入っています。**外部レビューからの提案で、3 つの課題を同時に緩めます。**

* **§9.1 の部分解消** — `ipset=/neon.tech/egress-allow-v4` はサブドメイン解決のたびに IP を注入するため、ワイルドカードが本来の意味で機能する
* **I4 の強化** — 非許可名は NXDOMAIN で返すため「経路の固定」が実質的な遮断に近づく。クエリログで試行の可視化もできる（現行の recorder に映らない唯一のシグナル）
* **CDN drift が構造ごと消える** — 解決時に TTL の新鮮な IP が set に入るため、起動時スナップショット方式の弱点が無くなる

**ここが一番効きます。** 現状は起動時スナップショットの弱点を「再適用運用」（[`spec.md`](./spec.md) §6.4）と「verify のいずれか判定」（§5.2）という 2 つの緩和策で埋めているだけで、どちらも本質的な解決ではありません。

調査が要る点:

* dnsmasq 自体の attack surface。**コンテナ内に常駐プロセスが 1 つ増える**
* `ipset=` の実際の挙動（TTL、set の maxelem、削除されないエントリの扱い）
* コンテナ内常駐プロセスの管理（誰が起動するか、死んだらどうなるか。**dnsmasq が死ぬと名前解決が全部止まる**）
* `resolv.conf` の向き先を変えることと [`design.md`](./design.md) §2.7 の整合。**現在は「Docker が書いた resolv.conf を読む」ことが非特権ユーザーの介入を排除する根拠**になっています。自分で書き換えるならその根拠を作り直す必要があります
* 設定生成が I5 を保つか（検証済み `firewall.json` の値のみから生成すること）

**L7 proxy（§10.1）を導入するなら不要になる可能性が高い**ため、位置づけの判断も含めて検討してください。

### 1.4 Docker Compose 構成での検証

**README の第一推奨（案 A）が未検証**です。項目 17 は案 B（`initializeCommand`）で実施しました。

これは**優先度の反転が再発している状態**です。項目 17 で一度解消したのと同じ種類の問題なので、放置しないでください。手順は [`verification-record.md`](./verification-record.md) §6.18 がそのまま使えます（`--network` の確認だけ読み替え）。

---

## 2. 未解決の一覧

[`known-issues.md`](./known-issues.md) が正です。要約:

| # | 内容 | 分類 |
|---|---|---|
| 1 | インストール時のチェックサム検証がない | 未実装 |
| 2 | IPv6 が有効なコンテナでの動作（`curl -6` の実到達性） | 未検証 |
| 3 | Linux ホスト上の Docker | 未検証 |
| 4 | `host.docker.internal` が公開アドレスを返すケース | 未検証（ユニットテストで担保） |
| 5 | WebFetch が遮断されたときのフォールバック挙動 | 未検証（→ §1.2） |
| 6 | CI ランナー / クラウド開発環境 / rootless Docker | 未検証 |
| 7 | Dev Container Feature 化 | 保留（着手条件を記載済み） |

加えて [`verification-record.md`](./verification-record.md) §2 の「未確認」表に、上記に載らないものが 3 件あります。

* **I3: GitHub meta API 不達でも適用が成立すること** — meta 単独の不達を再現する手順が無い
* **`SET` ターゲットが使えないカーネルでのフォールバック** — ユニットテストのみ
* **Docker Compose 構成** — §1.4

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
* **適用されているかは毎回確かめてください。** イメージが古いと旧版のスクリプトが残り、`postStartCommand` は成功したように見えます（§1.1 で実際に起きました）。`curl --connect-timeout 5 https://example.com` が失敗すること、`ls -l /usr/local/bin/init-project-firewall.sh` のサイズがパッケージ側と一致することの 2 点で判別できます

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
