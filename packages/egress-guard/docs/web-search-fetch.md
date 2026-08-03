# Claude Code の Web Search / Fetch と egress 規制

egress-guard は allowlist に無いドメインへの通信を遮断します。「では Claude Code の Web 検索・Web 取得は使えなくなるのか」に答えるための**外部ツールの挙動に関する参考文書**です。egress-guard の仕様ではありません。

**根拠の強さが節によって違います。** 混同しないよう最初に示します。

| 節 | 内容 | 根拠 |
|---|---|---|
| §1 | WebFetch はコンテナから直接 egress する。WebSearch はしない | **実測**（2026-08-03、Claude Code v2.1.220） |
| §2〜§4 | Haiku 要約とそのトレードオフ | 参照元の記事（Claude Code v2.1.126 のソース調査） |

結論は次のとおりです。

* **WebSearch は追加設定なしで使えます。** 検索の実行中、コンテナから外部への新規接続は観測されませんでした
* **WebFetch は `allowDomains` に入れたドメインでしか使えません。** 取得はコンテナ内の `claude` プロセスが対象ドメインへ直接 TCP 接続して行っています。**この文書が以前「Anthropic 側で完結すると考えられる」と推論していたのは誤りでした**
* 取得内容は Haiku の要約を経由するため、**prompt injection のリスクは低くなります**（無効化ではありません）
* 代償として、**長文ページでは情報が落ちます**。egress 規制の副作用ではなく Claude Code 側の仕様です

§2〜§4 の参照元: [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)（zhizhiarv、Claude Code v2.1.126 の調査、2026-05-04 時点）。**バージョン依存の情報です。**

---

## 1. WebFetch は直接 egress する。WebSearch はしない（実測）

### 結果

| | 通信先 | allowlist |
|---|---|---|
| Claude Code の **WebSearch** | `api.anthropic.com` のみ | 基底プロファイルに含まれる（設定不要） |
| Claude Code の **WebFetch** | **取得先ドメインそのもの** | **`allowDomains` への追加が必要** |
| `curl https://example.com` などの自前の取得 | そのドメイン | `allowDomains` への追加が必要 |

WebFetch は、コンテナ内の `claude` プロセスが取得先へ直接 TCP 443 を張ります。

```
209.51.188.20:443  users:(("claude",pid=32345,fd=14))
```

したがって **`enforce` モードでは、`allowDomains` に無いドメインの WebFetch は遮断されます。** 「egress 規制下でも Web 取得は素通しで使える」という理解は成り立ちません。

WebSearch は逆で、検索実行中に新しい通信先は現れませんでした。Anthropic 側で完結しているという理解と整合します。

### 測定条件と手順

**2026-08-03、Claude Code v2.1.220、Docker Desktop / macOS arm64 のコンテナ内。egress-guard は未適用の状態で測定しました。**

未適用の状態を選んだのは、`enforce` 下で測ると「遮断されたので接続が見えない」のか「そもそも接続しない」のかを区別できないためです。規制の無い状態で**実際に張られた接続**を見れば、この区別が要りません。

`ss` で全 TCP ソケットの peer を 0.5 秒ごとに記録します。TIME-WAIT は約 60 秒残るため、短命な接続も取りこぼしません。

```sh
# [node] 記録を開始する
while :; do
	ss -Htnp state all | awk -v t="$(date +%s)" '{print t, $5, $6}' >> peers.log
	sleep 0.5
done
```

この状態で Claude Code に WebFetch / WebSearch を実行させ、`peers.log` に現れた peer を、実行前の baseline と突き合わせます。

* **WebFetch** — `ftp.gnu.org`（`209.51.188.20`）と `www.debian.org`（`128.31.0.62`）を対象に各 2 回。いずれも呼び出しの直後に対象 IP が現れ、約 5.5 秒後に消えました。`ss -p` によるプロセス帰属は `claude` 本体です
* **WebSearch** — 2 回実行。検索結果に現れたドメイン（`cateee.net`、`forum.openwrt.org` など）への接続はありません

**紛らわしい観測が 1 つあります。** 検索の窓で `35.190.46.17`（GCP）と `104.16.10.34`（Cloudflare）が新しく現れます。これは検索起因ではありません。Web ツールを一切使わない制御窓 71 秒でも継続して ESTAB のままであり、Claude Code の常駐テレメトリと判断しました。**検索の測定では、この 2 つを baseline に含めてから差分を取ってください。**

### egress-guard 適用後に測る場合

適用後は `egress-audit-v4`（遮断先の記録）でも確認できます。上の測定より手軽ですが、**遮断された宛先しか映らない**ため、「接続を試みたか」は分かっても「接続できたか」は分かりません。

```sh
# [root] 記録をいったん空にする
ipset flush egress-audit-v4

# この状態で Claude Code に WebSearch / WebFetch を実行させる

# 遮断された宛先を読む
ipset list egress-audit-v4
```

`allowDomains` に無いドメインを WebFetch すれば、その IP がここに現れるはずです。

### 残った未確認

**直接接続が REJECT されたとき、Claude Code が Anthropic 側の取得へフォールバックするかは未確認です。** 上の測定は egress-guard 未適用の状態で行ったため、遮断されたときの挙動を観測していません。

* フォールバックする → `allowDomains` 外でも WebFetch は動く（ただし遮断の記録は残る）
* フォールバックしない → `allowDomains` 外の WebFetch はエラーになる

[`known-issues.md`](./known-issues.md) 項目 5 に残してあります。適用済みのコンテナで WebFetch を 1 回実行すれば判定できます。

---

## 2. Haiku 要約が挟まる（prompt injection の観点ではむしろ利点）

WebFetch は取得した HTML をそのままモデルに渡しません。Markdown 化したうえで、**Haiku が `prompt` パラメータに沿って要約したもの**が返ります。記事によれば、`url` と `prompt` はどちらも省略できないため、既定では常に要約が返ります。

これは prompt injection に対する緩衝材として働きます。取得先のページに「これまでの指示を無視して〜」の類が埋め込まれていても、それは**要約タスクを与えられた Haiku の入力**であり、Claude Code 本体の指示列に直接入るわけではありません。攻撃者から見れば、間に 1 段挟まったぶん狙いを通しにくくなります。

**万能ではありません。** 要約役のモデルが指示に従ってしまえば、要約文それ自体に攻撃者の文言が載ります。「危険性が低減される」であって「無効化される」ではない、という理解が正確です。

### 要約がバイパスされる条件

記事によれば、次の 3 つを**すべて**満たすときだけ原文が返ります。

1. 取得先が `Content-Type: text/markdown` をサポートしている
2. Claude Code が信頼している 80 以上のドメインに含まれる（`docs.python.org`、`developer.mozilla.org` など）
3. Markdown 化した長さが 10 万文字以下

裏を返すと、**信頼ドメインの原文取得では上記の緩衝材が働きません**。ただし対象は公式ドキュメントサイト群であり、任意の第三者ページよりリスクは低いと考えられます。

---

## 3. トレードオフ: 長文では情報が落ちる

記事が挙げている打ち切り点は次の 3 段です。

| 段階 | 上限 |
|---|---|
| HTTP レスポンスの取得 | 10 MiB |
| HTML → Markdown 変換 | 先頭 1 MiB 文字のみ |
| Haiku へ渡す前 | 先頭 10 万文字のみ |

**この打ち切りは警告なしに起きます。** 記事は「長いウェブページの後半はサイレントに捨てられます」と述べ、Wikipedia の長大なページに対して「最後の 2 文を取得して」と指示しても取れない例を挙げています。UI には `Received 204.4KB (200 OK)` のように取得サイズが表示されるため、原文がすべて渡っているように見えてしまう点も指摘されています。

加えて、要約そのものに起因する劣化があります。

* 細部の欠落 — 要約の性質上、元の記述の粒度は保たれません
* 解釈のずれ — 要約は解釈を含みます。原文と食い違うことがあります
* 伝言ゲーム — 要約を読んだモデルがさらに要約する構造では、誤差が累積します

また、内部プロンプトには「いかなる元文書からの引用も 125 文字以内」という制約があるとされています。**原文の逐語引用が必要な作業には向きません。**

---

## 4. 使い分け

**調査の起点は WebSearch です。** 追加設定なしで使え、egress も発生しません。

**WebFetch には取得先ごとの許可が要ります。** §1 のとおりコンテナから直接取得しているため、`allowDomains` に入っていないドメインは取得できません。よく参照するドキュメントサイトは、あらかじめ `firewall.json` に列挙しておくことになります。

```json
{
	"version": 1,
	"profile": "default",
	"mode": "enforce",
	"allowDomains": ["docs.example.com"]
}
```

**許可した時点で、そのドメインは `curl` でも取得できるようになります。** WebFetch だけを許可する、という区別は L3/L4 ではできません（[`spec.md`](./spec.md) §9.2）。取得内容が Haiku 要約を通るかどうかは呼び出し側の選択であり、egress 規制では強制できません。信頼できるドメインに限って追加してください。

どのドメインが要るか分からない場合は `mode: "audit"` で運用し、`egress-audit-v4` に溜まった IP から特定します。

`firewall.json` の反映にはイメージの再ビルドが必要です（理由は [`design.md`](./design.md) §2.1）。

---

## 参考

* [`spec.md`](./spec.md) §9.2 — 「GET を全ドメイン許可」ができない理由
* [`known-issues.md`](./known-issues.md) 項目 5 — 遮断時のフォールバック挙動が未確認であることの記録
* [`verification-record.md`](./verification-record.md) §6.19 — §1 の測定手順
* [`README.md`](../README.md) — `egress-audit-v4` の読み方
* [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)
