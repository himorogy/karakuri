# init-project-firewall.sh 仕様書

devcontainer 向け egress 制御スクリプトの仕様。実装レビューの基準文書。

---

## 1. 目的とスコープ

### 目的（守るもの）

1. **漏洩シンクの制限** — injection・暴走時に、コンテナ内の秘密・コードを書き出せる先を allowlist に限定する
2. **DNS トンネリングの遮断** — 公式 init-firewall.sh 最大の穴。DNS を Docker 内部リゾルバ宛のみに固定する
3. **攻撃プラットフォーム化の防止** — default DROP により C2 通信・スキャンの踏み台化を防ぐ

### Non-goals（守らないもの・守れないもの）

- **悪性コンテンツの流入防止はしない。** allowlist に GitHub/npm がある時点で任意コンテンツは流入する。INPUT 側フィルタに実効性はなく、目的としない
- **完全な exfil 防止は保証しない。** 許可先への GET クエリ等による低帯域漏洩は残る。残余リスクは enclave-env 本来の役割（prod キー不在・least-privilege クレデンシャル）で受け止める
- **L7 制御（メソッド別・パス別の制御）はしない。** 将来の proxy 移行で扱う（§8）

### 設計原則

- 基底ポリシーはパッケージ（版管理・全プロジェクト共通）、プロジェクト差分は repo 内 `firewall.json`
- 冪等（何度実行しても同じ結果、`-exist` 問題の再発なし）
- 将来 L7 proxy へ移行する際、本スクリプトが「proxy 宛のみ許可」へ縮小できる構造にする

---

## 2. 構成要素

| 要素 | 置き場所 | 役割 |
|---|---|---|
| `init-project-firewall.sh` | enclave-env パッケージ内 → インストール時に `/usr/local/bin/` へ root がコピー | ルール適用本体 |
| `firewall.json` | プロジェクト repo（例: `.devcontainer/firewall.json`） | プロジェクト固有の追加許可 |
| 基底プロファイル | パッケージ内（スクリプトに埋め込み or 同梱 JSON） | 全プロジェクト共通の allowlist |
| Dockerfile ボイラープレート | 各プロジェクト（安定・低頻度更新） | NET_ADMIN/NET_RAW cap、sudoers 行、インストールフック |

### 権限モデル（最重要設計点）

**sudoers が node_modules 内のパスを指してはならない。** node_modules は node ユーザーが書き換え可能なため、そこを sudo 対象にすると「agent がスクリプト本体を書き換えて root 実行」という権限昇格経路になる。

正しい流れ:

1. `postCreateCommand`（root 権限フェーズ）で enclave-env 内のスクリプトを `/usr/local/bin/init-project-firewall.sh` に**コピー**し、`root:root` 所有・`755`・可能なら `chattr +i`
2. sudoers は固定パスのみ許可: `node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh`（引数ワイルドカードなし。firewall.json のパスはスクリプト内で固定）
3. `postStartCommand` で `sudo /usr/local/bin/init-project-firewall.sh` を実行

`firewall.json` は node 書き換え可能な場所にあってよい（データであり、root で動くスクリプト側が検証するため）。ただし §7 のスキーマ検証が必須条件。

---

## 3. firewall.json スキーマ

```json
{
  "version": 1,
  "profile": "default",
  "mode": "enforce",
  "allowDomains": ["*.neon.tech"],
  "allowCidrs": ["203.0.113.0/24"],
  "allowHostPorts": [5432]
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `version` | int | ✔ | スキーマ版。未知の版は **fail-closed で拒否** |
| `profile` | string | — | 基底プロファイル名。当面 `default` のみ |
| `mode` | `"enforce"` \| `"audit"` | — | 既定 `enforce`。`audit` は DROP せず LOG のみ（ポリシー育成用、§6） |
| `allowDomains` | string[] | — | 追加許可ドメイン。ワイルドカードは `*.example.com` 形式のみ |
| `allowCidrs` | string[] | — | 追加許可 CIDR |
| `allowHostPorts` | int[] | — | ホストゲートウェイ宛に許可するポート（§4.6） |

### バリデーション（root スクリプト側で実施、違反は exit≠0）

- JSON スキーマ違反 → 拒否
- `"*"` 単独、`*.*`、TLD ワイルドカード（`*.com` 等）→ 拒否
- `0.0.0.0/0`、`::/0`、プレフィックス長 < 8 の CIDR → 拒否
- プライベートアドレス帯（RFC1918）の CIDR → 拒否（ホスト側は `allowHostPorts` で明示的に扱う。Tailscale 網への横移動を allowDomains/Cidrs 経由で開けさせない）
- ドメイン名の文字種検証（injection 対策: シェル展開・ipset コマンドに渡る前に `[a-zA-Z0-9.*-]` に限定）

---

## 4. スクリプト仕様

### 4.1 前提・実行環境

- bash、`set -euo pipefail`
- 要求コマンド: `iptables` `ip6tables` `ipset` `dig`（または `getent`）`jq` `aggregate`（任意）
- root で実行されていなければ即 exit
- devcontainer 内（Docker 埋め込みリゾルバ 127.0.0.11 の存在）を前提。存在しなければ警告して DNS 固定をスキップするか判断（→ 実装時に決定。推奨: fail-closed で exit）

### 4.2 処理順序

1. firewall.json 読込・検証（§3）。**検証失敗は即 exit≠0**（ルール未適用のまま起動させない）
2. Docker NAT ルール（127.0.0.11 宛 DNAT）の退避
3. 既存ルール flush、ipset は `destroy` → `create`（冪等性の担保。`add -exist` に頼るのではなく毎回作り直す）
4. NAT ルール復元
5. 基本許可: loopback、ESTABLISHED/RELATED
6. **DNS 固定**: UDP/TCP 53 は宛先 127.0.0.11 のみ ACCEPT。それ以外の 53 番宛は DROP（トンネリング遮断）
7. allowlist 解決: 基底プロファイル ∪ firewall.json のドメインを解決し ipset へ。GitHub は meta API の CIDR を使用
8. ホストゲートウェイ: `allowHostPorts` に列挙されたポートのみ ACCEPT（§4.6）
9. default policy: INPUT/OUTPUT/FORWARD とも DROP（IPv4/IPv6 両方）
10. OUTPUT: ipset マッチを ACCEPT、残りは mode に応じて REJECT（enforce）or LOG のみ（audit）
11. 自己検証（§5）。失敗時 exit≠0

### 4.3 冪等性

- 2回連続実行 → 同一のルールセット・exit 0
- 実行途中で kill → 再実行で正常状態に収束（flush から始まるため）

### 4.4 名前解決の失敗ハンドリング

- **個別ドメインの解決失敗 = warn して continue。** そのドメインが通らないだけで fail-closed に倒れるため安全側。公式スクリプトのように起動不能（issue #15611 型）にしない
- ただし基底プロファイルの必須ドメイン（api.anthropic.com 等）が1つも解決できない場合はネットワーク自体の異常なので exit≠0

### 4.5 IPv6

- **ip6tables も default DROP 必須。** IPv4 だけ塞いで IPv6 素通りは公式スクリプト系でありがちな穴
- 当面 IPv6 の allowlist は作らず全 DROP でよい（必要になったら追加）

### 4.6 ホストゲートウェイの扱い

公式スクリプトはホスト網を包括許可しているが、ホストには Tailscale 網が繋がっているため横移動リスクがある。本仕様では**既定は不許可**とし、必要なポート（VSCode Server、sshd、ローカル DB 等）だけ `allowHostPorts` で開ける。

### 4.7 INPUT 側

- default DROP + ESTABLISHED/RELATED
- コンテナ内 sshd を使う運用があるため、sshd ポートの ACCEPT を基底に含める（ポート番号はパッケージ側定数 or firewall.json で上書き可）

### 4.8 ログ

- audit mode: DROP 対象を `LOG --log-prefix "fw-audit: "` で記録（レート制限付き `-m limit`）
- enforce mode でも DROP 直前に同様の LOG を薄く入れておくと、新プロジェクトで「何を許可すべきか」の調査が `dmesg`/journal で完結する

---

## 5. 自己検証（スクリプト末尾で必ず実行）

| テスト | 期待 |
|---|---|
| `curl https://example.com`（未許可） | 失敗（timeout/reject） |
| `curl https://api.anthropic.com` | 成功 |
| `dig @8.8.8.8 example.com` | 失敗（DNS 固定の確認） |
| `dig example.com`（127.0.0.11 経由） | 成功 |
| firewall.json の追加ドメイン1件 | 成功 |
| IPv6 で外部到達（環境に v6 があれば） | 失敗 |

いずれか失敗で exit≠0。postStartCommand の失敗としてユーザーに見える状態にする。

---

## 6. 運用

- **新プロジェクトの立ち上げ**: `mode: "audit"` で数日回し、LOG から必要ドメインを収集 → firewall.json に転記 → `enforce` へ。静的 allowlist の「事前に全部知らないと使えない」問題の緩和策
- **ルールの再適用**: allowlist は起動時解決のため CDN の IP 変動で許可先が通らなくなることがある。`sudo /usr/local/bin/init-project-firewall.sh` の再実行で回復（sudoers 上、agent 自身も再実行できるが、読むのは検証済み firewall.json のみなので昇格には使えない）
- **enclave-env の更新**: パッケージ更新 → コンテナ rebuild で `/usr/local/bin` のコピーが更新される。伝播はこの1経路のみ

---

## 7. セキュリティ注意点（レビュー観点）

1. **権限昇格経路の遮断**: sudoers は `/usr/local/bin` の root 所有・immutable なコピーのみを指すこと。node_modules 内パス・引数付き sudoers は不可（§2）
2. **firewall.json は agent 編集可能**という前提で設計する。効力は再適用時のみだが、スキーマ検証・ワイルドカード禁止・プライベート帯拒否（§3）が防波堤。受託案件では firewall.json を PR レビュー必須ファイルとして扱う
3. **文字列の取り扱い**: firewall.json 由来の値を検証前にシェル・iptables/ipset に渡さない。`jq -r` の出力をそのまま `eval` 相当に流さない
4. **サプライチェーン**: スクリプトは root で動く。enclave-env はプライベートレジストリ＋lockfile 固定を維持し、可能なら postCreate コピー時にチェックサム検証を入れる
5. **DNS 全開放にしない**: 127.0.0.11 固定が本仕様の核。緩めるとトンネリングで全体が無意味化する
6. **IPv6 を忘れない**（§4.5）
7. **fail-closed の一貫性**: 検証エラー・自己検証失敗は必ず「ルール未適用 or DROP のまま + exit≠0」。「エラーだが全開で起動」だけは絶対に作らない
8. **既知の残余リスク（受容するもの）**: 許可ドメインへの GET クエリ経由の低帯域 exfil／GitHub 書き込み権限トークンがあれば github.com 経由の exfil は可能。対策は egress ではなくクレデンシャル側（fine-grained PAT、prod キー不在）

---

## 8. 将来拡張（実装はしないが構造で備える）

- **L7 proxy 移行**: ホスト側に proxy を置く段階になったら、本スクリプトは「proxy 宛 + DNS 固定のみ許可」に縮小し、ドメイン/メソッド ACL は proxy 側 per-project 設定へ移す。firewall.json のスキーマは proxy 設定へ変換可能な形（ドメインリスト中心）を維持する
- **Claude Code sandbox 併用**: 現状 devcontainer 内 sandbox は namespace 制約で非推奨。devcontainer を外す判断をした場合は本スクリプト自体が不要になり、`.claude/settings.json` に役割が移る

---

## 9. 受け入れ基準（実装レビュー時のチェックリスト)

- [ ] 2回連続実行で同一結果・exit 0（冪等）
- [ ] 不正な firewall.json（`"*"`、`0.0.0.0/0`、RFC1918、未知 version）が全て拒否される
- [ ] §5 の自己検証が全て通る
- [ ] `dig @8.8.8.8` が失敗する（DNS トンネリング遮断）
- [ ] ip6tables default DROP が入っている
- [ ] sudoers が固定パス・引数なしで、対象が root 所有 immutable
- [ ] 個別ドメイン解決失敗で起動が止まらない（warn + continue）
- [ ] audit mode で LOG が出て DROP されない
- [ ] shellcheck クリーン