# egress 規制下での Claude Code Web Search / Fetch

egress-guard は allowlist に無いドメインへの通信を遮断します。「では Claude Code の Web 検索・Web 取得は使えなくなるのか」という疑問に答えるための文書です。

結論を先に書きます。

* **使えます。** allowlist を広げる必要はありません
* しかも、**取得内容が Haiku の要約を経由するため、prompt injection のリスクはむしろ低くなっています**
* 代償として、**長文ページでは情報が落ちます**。これは egress 規制の副作用ではなく、Claude Code 側の仕様です
* 「どうしても原文をそのまま読ませたい」ケース以外は、これで十分です

参照元: [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)（zhizhiarv、Claude Code v2.1.126 の調査、2026-05-04 時点）

---

## 1. なぜ allowlist を広げなくてよいのか

Claude Code の Web 検索・Web 取得は、コンテナから任意のドメインへ直接 HTTP を投げる仕組みではありません。処理は Anthropic 側で完結し、コンテナから見た通信先は `api.anthropic.com` だけです。`api.anthropic.com` は egress-guard の基底プロファイルに含まれているため、追加設定は不要です。

つまり、次の 2 つは別物です。

| | 通信先 | allowlist |
|---|---|---|
| Claude Code の WebSearch / WebFetch | `api.anthropic.com` | 基底プロファイルに含まれる（設定不要） |
| `curl https://example.com` などの自前の取得 | そのドメイン | `allowDomains` への追加が必要 |

### 実測で確かめる

上記は仕様の理解であり、環境やバージョンで変わり得ます。**遮断先の記録（`egress-audit-v4`）で実際に確認できます。**

```sh
# コンテナ内・root（ホストからは docker exec -u root <container> ...）

# 1) 記録をいったん空にする
ipset flush egress-audit-v4

# 2) この状態で Claude Code に WebSearch / WebFetch を実行させる

# 3) 遮断された宛先が増えていないことを確認する
ipset list egress-audit-v4
```

`enforce` モードのまま実行して `egress-audit-v4` に何も溜まらなければ、コンテナから外部ドメインへの直接 egress は発生していない、ということです。

> **検証状況:** 本パッケージの実機検証（2026-08-02）ではこの手順は未実施です。実施したら結果をここに追記してください。

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

**通常は Claude Code の WebSearch / WebFetch で十分です。** 調査・仕様確認・エラーメッセージの当たりを付ける、といった用途で要約の粒度が問題になることは多くありません。

原文をそのまま読ませる必要があるのは、次のようなケースです。

* 仕様書やライセンス文書を逐語で確認する
* 長大なページの後半に用がある
* 数値・コード片・設定例を正確に取り出す

この場合は `firewall.json` の `allowDomains` にそのドメインを追加し、`curl` などで直接取得します。

```json
{
	"version": 1,
	"profile": "default",
	"mode": "enforce",
	"allowDomains": ["docs.example.com"]
}
```

**このとき緩衝材は無くなります。** 取得した内容はそのままコンテキストに入るため、prompt injection の危険は元に戻ります。信頼できるドメインに限って追加してください。

`firewall.json` の反映にはイメージの再ビルドが必要です（理由は [`spec.md`](./spec.md) の §2.1）。

---

## 参考

* [`spec.md`](./spec.md) — §2.1 権限モデル、§3 firewall.json、§4.10 遮断先の記録
* [`known-issues.md`](./known-issues.md) — 項目 2「GET を全ドメイン許可」ができない理由
* [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)
