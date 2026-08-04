# Claude Code の Web Search / Fetch と egress 規制

egress-guard は allowlist に無いドメインへの通信を遮断します。「では Claude Code の Web 検索・Web 取得は使えなくなるのか」に答えるための**外部ツールの挙動に関する参考文書**です。egress-guard の仕様ではありません。

**ここに書いた挙動を測り直すための手順も、本書が持ちます**（§5）。Claude Code のバージョンが上がるたびに測り直す必要があり、その手順は egress-guard 自身の受け入れ検証（[`verification-record.md`](./verification-record.md)）とは別系統だからです。**参考文書であると同時に、その参考情報の再取得手順書でもあります。**

| 節 | 内容 | 根拠 |
|---|---|---|
| §1 | WebFetch はコンテナから直接 egress する。WebSearch はしない | **実測**（`ss` による接続のサンプリング） |
| §2 | 要約が挟まる条件と、それをバイパスする 91 ドメイン | **実装の静的解析＋ライブ再現** |
| §3 | 打ち切りの 3 段と、その定数 | **実装の静的解析** |
| §4 | 使い分け | 上記からの導出 |
| §5 | §1〜§3 を測り直すための再実行手順 | — |

**すべて 2026-08-03、Claude Code v2.1.220 で確認しています**（`BUILD_TIME 2026-07-24T22:17:45Z`、`GIT_SHA 4073f595`）。**バージョン依存の情報です。** 実装は将来変わります。

結論は次のとおりです。

* **WebSearch は追加設定なしで使えます。** 検索の実行中、コンテナから外部への新規接続は観測されませんでした
* **WebFetch は `allowDomains` に入れたドメインでしか使えません。** 取得はコンテナ内の `claude` プロセスが対象ドメインへ直接 TCP 接続して行っています。**この文書が以前「Anthropic 側で完結すると考えられる」と推論していたのは誤りでした**
* 取得内容はふつう小型モデルの要約を経由するため、**prompt injection のリスクは低くなります**（無効化ではありません）
* **ただし 91 の事前承認ドメインでは要約が丸ごとバイパスされ、原文がそのまま返ります。** ここでは緩衝材が働きません（§2）
* 代償として、**長文ページでは情報が落ちます**。egress 規制の副作用ではなく Claude Code 側の仕様です

この文書の出発点は [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)（zhizhiarv、Claude Code v2.1.126 の調査、2026-05-04 時点）です。**記事の主張は §2・§3 でおおむね再現しましたが、食い違いが 1 つあります**（打ち切りは無言ではない。§3）。

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

**WebFetch は取得先のほかに `api.anthropic.com` にも出ます。** 取得の前にブロックリストを照会し、要約のためにもう一度呼ぶためです（§2）。どちらも基底プロファイルに含まれるため設定は要りません。

```js
// 取得前のブロックリスト照会（結果はプロセス内にキャッシュされる）
await No.get(`https://api.anthropic.com/api/web/domain_info?domain=${encodeURIComponent(e)}`, {timeout: IHy})
// can_fetch !== true なら status:"blocked"
```

**「直接取得する」ことと「原文が返る」ことは別です。** 取得はコンテナ、要約は Anthropic 側で、層が違います。原文の HTML はコンテナのプロセスを通りますが、ツールの結果として返るのは §2 のとおり Haiku の要約です。egress 規制から見た帰結も要約の有無とは無関係で、**取得先が allowlist に無ければそもそも接続できません**。

```
コンテナ内の claude ── TCP 443 ──→ 取得先        ← §1 で実測した層
        └── 取得した HTML を Anthropic へ ──→ Haiku 要約   ← §2（記事が扱う層）
                                                  └──→ ツールの結果
```

### 測定条件と手順

**2026-08-03、Claude Code v2.1.220、Docker Desktop / macOS arm64 のコンテナ内。** 測定は egress-guard 未適用の状態で、`ss` による接続のサンプリングで行いました。手順は本書 §5.1。

`peers.log` に現れた peer を、Web ツールを実行する前の baseline と突き合わせています。

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

### 遮断されたときフォールバックはしない（実測）

**`enforce` 下で `allowDomains` に無いドメインを WebFetch すると、そのまま失敗します。** Anthropic 側の取得へ切り替わることはありません。

2026-08-03、`enforce` を適用したコンテナで確認しました。

| 操作 | 結果 |
|---|---|
| WebFetch → `ftp.gnu.org`（`allowDomains` 外） | **失敗。出力なし** |
| WebFetch → `nodejs.org`（`allowDomains` 内） | 成功 |
| WebSearch | 成功 |

**したがってこの文書の記述はそのまま成立します。** WebFetch は取得先ごとの許可が要り、WebSearch は要りません。

---

## 2. 要約が挟まる（prompt injection の観点ではむしろ利点）

WebFetch は取得した HTML をそのままモデルに渡しません。Markdown 化したうえで、**小型モデルが `prompt` パラメータに沿って要約したもの**が返ります。要約役は small/fast 層（`ANTHROPIC_SMALL_FAST_MODEL` で差し替え可、既定は `claude-haiku-4-5`）で、thinking は無効です。

これは prompt injection に対する緩衝材として働きます。取得先のページに「これまでの指示を無視して〜」の類が埋め込まれていても、それは**要約タスクを与えられた小型モデルの入力**であり、Claude Code 本体の指示列に直接入るわけではありません。攻撃者から見れば、間に 1 段挟まったぶん狙いを通しにくくなります。

**万能ではありません。** 要約役のモデルが指示に従ってしまえば、要約文それ自体に攻撃者の文言が載ります。「危険性が低減される」であって「無効化される」ではない、という理解が正確です。

### 要約がバイパスされる条件

分岐は 1 行です。`_` が事前承認ドメイン判定、`f` が `Content-Type`、`u` が Markdown 化した本文、`ymr` は `1e5`。

```js
if (_ && f.includes("text/markdown") && u.length < ymr) T = u;
else T = await Iin(i, u, {..., isPreapprovedDomain: _, ...});
```

つまり次の 3 つを**すべて**満たすときだけ原文が返ります。記事の主張どおりでした。

1. **取得先が `Content-Type: text/markdown` を返す** — リクエストは `Accept: text/markdown, text/html, */*` を送るため、コンテントネゴシエーションに対応したサイトが該当します
2. **事前承認ドメインに含まれる**（下記）
3. **Markdown 化した長さが 10 万文字未満**（`ymr = 1e5`。記事の「10 万文字以下」は厳密には「未満」）

### 事前承認ドメインは 91 件

ソース上は 92 エントリで、`learn.microsoft.com` が重複しているため実質 91 件です。記事の「80 以上」と整合します。判定はこうなっています。

```js
function Bpd(e, t) {                       // e = hostname, t = pathname
  if (pBy.has(e)) return !0;               // ホスト名だけで一致
  let r = mBy.get(e);
  if (r) {
    if (/%(25)*(2f|5c|2e)/i.test(t)) return !1;   // エンコードされた / \ . を拒否
    for (let n of r) if (t === n || t.startsWith(n + "/")) return !0;
  }
  return !1
}
```

**7 件はパス接頭辞付きで、ドメイン全体ではありません。**

* `claude.com/docs`
* `github.com/anthropics`
* `wordpress.org/documentation`
* `huggingface.co/docs`
* `www.kaggle.com/docs`
* `vercel.com/docs`
* `dev.wix.com/docs`

残りはホスト名一致です（`docs.python.org`、`developer.mozilla.org`、`code.claude.com`、`nodejs.org`、`kubernetes.io` など、公式ドキュメントサイト群）。パス接頭辞の判定にはパストラバーサル対策が入っています。

### 実際にバイパスさせた

`code.claude.com` は事前承認ドメインで、`Accept: text/markdown` に対して `content-type: text/markdown; charset=utf-8` を返します。

```sh
curl -s -H 'Accept: text/markdown, text/html, */*' https://code.claude.com/docs/en/overview -o overview.md
wc -c overview.md    # 16445
```

同じ URL に対し、要約されれば絶対に長文にならない `prompt` で WebFetch を実行しました。

> prompt: `Answer with exactly one word, nothing else: does this page mention MCP? Reply only "yes" or "no".`

**返ってきたのは 1 語ではなく、`curl` で取った 16,445 バイトと先頭・末尾が一致する原文でした。** `prompt` は完全に無視されます。

**この経路では緩衝材がありません。** 対象が公式ドキュメントサイト群である点は緩和材料ですが、「そのドメインが侵害されれば原文がそのままコンテキストに入る」という性質は残ります。**`allowDomains` にこれらを入れるときは、遮断の可否だけでなくこの点も勘定に入れてください。**

### 引用 125 文字の制限は条件付き

記事が挙げている「いかなる元文書からの引用も 125 文字以内」は実在しますが、**事前承認ドメイン以外に対してのみ**です。プロンプトが二択になっています。

```js
return `... ${t}\n\n${r ? "Provide a concise response based on the content above. Include relevant details, code examples, and documentation excerpts as needed."
                       : "Provide a concise response based only on the content above. In your response:\n - Enforce a strict 125-character maximum for quotes from any source document. ..."}`
```

`r` は `isPreapprovedDomain`。**事前承認ドメインでは、要約に回った場合でも 125 文字制限は課されず、コード例や引用を含めるよう明示的に指示されます。**

---

## 3. トレードオフ: 長文では情報が落ちる

打ち切りは 3 段で、記事の挙げる値と一致します。定数はソース上の識別子です。

| 段階 | 上限 | 定数 |
|---|---|---|
| HTTP レスポンスの取得 | 10 MiB | `RHy = 10485760`（axios の `maxContentLength`） |
| HTML → Markdown 変換 | 先頭 1 MiB 文字のみ | `ogd = 1048576` |
| 要約モデルへ渡す前 | 先頭 10 万文字のみ | `ymr = 1e5` |

### 「無言で捨てられる」は v2.1.220 では成り立たない

**ここだけ記事と食い違います。** どちらの打ち切り段にも、末尾にマーカーが付きます。

```js
async function Ain(e) {                                  // HTML → Markdown
  let t = (await kHy()).turndown(e.slice(0, ogd));
  if (e.length > ogd) t += `\n\n[Content truncated due to length...]`;
  return t
}

// 要約モデルへ渡す前
let a = t.length > ymr ? t.slice(0, ymr) + `\n\n[Content truncated due to length...]` : t;
```

**ただし後者のマーカーが入るのは要約モデルへの入力です。** 要約役がそれを最終出力に載せる保証はないため、**呼び出し側から見れば無言のまま終わることはあり得ます。** 前者のマーカーは Markdown 本体に入るので後段まで残ります。

いずれにせよ、記事の指摘した実害（長大なページの後半に用があるとき取れない）はそのままです。

### 要約そのものに起因する劣化

* 細部の欠落 — 要約の性質上、元の記述の粒度は保たれません
* 解釈のずれ — 要約は解釈を含みます。原文と食い違うことがあります
* 伝言ゲーム — 要約を読んだモデルがさらに要約する構造では、誤差が累積します

引用 125 文字の制限もあります（§2 の末尾。**事前承認ドメイン以外のみ**）。**原文の逐語引用が必要な作業には向きません。**

### その他の上限

静的解析で分かった、記事に出てこないものです。

| 項目 | 値 | 定数 |
|---|---|---|
| リクエストのタイムアウト | 60 秒 | `AHy = 60000` |
| ブロックリスト照会のタイムアウト | 10 秒 | `IHy = 1e4` |
| URL の長さ上限 | 2000 文字 | `xHy = 2000` |
| リダイレクトの最大段数 | 10 | `ngd = 10` |

リダイレクトは `maxRedirects: 0` で 1 段ずつ手動追跡し、**別ホストへ飛ぶ場合は追わずにモデルへ差し戻します**。ユーザー名やパスワードを含む URL、ラベルが 2 個未満のホスト名は取得前に拒否されます。

---

## 4. 使い分け

**調査の起点は WebSearch です。** 追加設定なしで使え、egress も発生しません。

**WebFetch には取得先ごとの許可が要ります。** §1 のとおりコンテナから直接取得しているため、`allowDomains` に入っていないドメインは取得できません。よく参照するドキュメントサイトは、あらかじめ `firewall.json` に列挙しておくことになります。

```json
{
	"version": 1,
	"profile": ["anthropic", "npm", "github"],
	"mode": "enforce",
	"allowDomains": ["docs.example.com"]
}
```

**許可した時点で、そのドメインは `curl` でも取得できるようになります。** WebFetch だけを許可する、という区別は L3/L4 ではできません（[`spec.md`](./spec.md) §9.2）。取得内容が要約を通るかどうかは呼び出し側がどのツールを使うかで決まり、egress 規制では強制できません。信頼できるドメインに限って追加してください。

**§2 の 91 ドメインを追加するときはもう一段慎重に。** 事前承認ドメインは要約をバイパスするため、`curl` を使うまでもなく原文がそのままコンテキストに入ります。「WebFetch なら要約が挟まるから安全側」という前提は、この 91 件については成り立ちません。

どのドメインが要るか分からない場合は `mode: "audit"` で運用し、`egress-audit-v4` に溜まった IP から特定します。

`firewall.json` の反映にはイメージの再ビルドが必要です（理由は [`design.md`](./design.md) §2.1）。

---

## 5. 再実行手順

**Claude Code が上がったら実行し直してください。** §1〜§3 の主張がバージョンを跨いで生き続けるための手順です。

**もともと [`verification-record.md`](./verification-record.md) §6.19 の 19.0〜19.2 と §6.20 にあったものを、参考文書である本書へ移しました。** 項目ラベルは 19.0 → 5.1.1、19.1 → 5.1.2、19.2 → 5.1.3、20.1〜20.7 → 5.2.1〜5.2.7 と付け替えています。**egress-guard 自身の検証（`enforce` 下で `allowDomains` 外の WebFetch が遮断され、フォールバックしないこと）は [`verification-record.md`](./verification-record.md) §6.19 に残っています。**

### 5.1 接続のサンプリング（§1 の測定）

**この測定だけは egress-guard を適用しない状態で実施します。** `enforce` 下で測ると「遮断されたので接続が見えない」のか「そもそも接続しない」のかを区別できません。規制の無い状態で**実際に張られた接続**を見れば、この区別が要りません。

`ss` で全 TCP ソケットの peer を 0.5 秒ごとに記録します。TIME-WAIT が約 60 秒残るため、短命な接続も取りこぼしません。

```sh
# [node] 記録を開始する（バックグラウンド）
while :; do
	ss -Htnp state all | awk -v t="$(date +%s)" '{print t, $5, $6}' >> peers.log
	sleep 0.5
done
```

| # | 確かめること | 手順 | 判定 |
|---|---|---|---|
| 5.1.1 | baseline を取る | Web ツールを使わずに 60 秒以上記録する | 現れる peer を控える。`api.anthropic.com` のほか**常駐テレメトリが 2 つある**（測定時は GCP と Cloudflare の各 1） |
| 5.1.2 | WebFetch の egress | 対象ドメインを `dig` で控えてから WebFetch を実行する | **対象 IP が現れる。** `$6` のプロセスが `claude` |
| 5.1.3 | WebSearch の egress | 検索を実行する | **baseline 以外の peer が現れない** |

> **5.1.1 を飛ばさないでください。** 常駐テレメトリは検索の窓でも新しく現れることがあり、baseline を取っていないと 5.1.3 が偽陽性になります。**Web ツールを使わない制御窓で同じ peer が継続して ESTAB なら、それはテレメトリです。**

> **対象ドメインの選び方。** CDN 上のドメインは、他の通信と IP が重なって判定できなくなります（測定時、`manpages.debian.org` と `www.debian.org` は同じ IP 集合でした）。`ftp.gnu.org` のように**単独 IP で他が触らない先**を選んでください。

> WebFetch の応答は URL ごとに 15 分キャッシュされます。**再測定では別の URL を使ってください。**

### 5.2 実装の静的解析（§2・§3 の確認）

**egress-guard の検証ではありません。** 環境にも依存しません。

配布物は Bun の単一実行ファイルで、JS が平文で埋め込まれています。読める領域を切り出してから grep します。

```sh
# [node] JS 領域の位置を掴む
B=$(readlink -f "$(command -v claude)")
grep -abo "Fetches a URL" "$B" | head -1        # 測定時は 248440257

# その周辺を切り出す（測定時は 236 MiB から 32 MiB で全部入った）
dd if="$B" bs=1M skip=236 count=32 2>/dev/null > js.bin
```

| # | 確かめること | 手順 | 測定時（v2.1.220）の値 |
|---|---|---|---|
| 5.2.1 | 要約バイパスの分岐 | `grep -aob 'text/markdown' js.bin` の各位置を `dd` で読む | `if(_&&f.includes("text/markdown")&&u.length<ymr)T=u;else T=await Iin(...)` |
| 5.2.2 | 打ち切りの 3 定数 | 上の分岐の近傍にまとまっている | `RHy=10485760` / `ogd=1048576` / `ymr=1e5` |
| 5.2.3 | 打ち切りが無言か | `grep -a 'Content truncated' js.bin` | **2 箇所でマーカーを付加**。記事の「サイレント」と食い違う |
| 5.2.4 | 事前承認ドメイン | `grep -aob 'function Bpd' js.bin` から `dd` で読む | 92 エントリ（`learn.microsoft.com` 重複、実質 91）。うち 7 件はパス接頭辞付き |
| 5.2.5 | 引用 125 文字の制限 | `grep -aob 'function TCu' js.bin` から `dd` で読む | **`isPreapprovedDomain` が偽のときだけ**課される |
| 5.2.6 | 取得前のブロックリスト照会 | 同上の近傍 | `api.anthropic.com/api/web/domain_info?domain=...` |

バイパスは実際に踏ませて確認します。

| # | 確かめること | 手順 | 判定 |
|---|---|---|---|
| 5.2.7 | 事前承認ドメインで原文が返る | 5.2.4 のリストから `Accept: text/markdown` に応じるものを選び、`curl` で保存してから、**要約されれば絶対に長文にならない `prompt`** で WebFetch する | **`prompt` が無視され、`curl` の内容と一致する原文が返る** |

> **5.2.7 の `prompt` の作り方が肝です。** 「1 語で答えろ」のような指示にしてください。要約された場合と原文が返った場合を、出力の長さだけで区別できます。

> 測定時は `code.claude.com/docs/en/overview`（16,445 バイト）で確認しました。**このサイトが将来も `text/markdown` を返す保証はありません。** 候補は `curl -sI -H 'Accept: text/markdown, text/html, */*'` の `content-type` で選び直してください。

---

## 参考

* [`spec.md`](./spec.md) §9.2 — 「GET を全ドメイン許可」ができない理由
* [`verification-record.md`](./verification-record.md) §2 — 遮断時にフォールバックしないことの記録
* 本書 §5 — §1〜§3 を測り直すための再実行手順（もとは [`verification-record.md`](./verification-record.md) §6.19・§6.20）
* [`verification-record.md`](./verification-record.md) §6.19 — 遮断された WebFetch がフォールバックしないことの確認手順
* [`README.md`](../README.md) — `egress-audit-v4` の読み方
* [Claude CodeのWebFetchは要約されている](https://zenn.dev/zhizhiarv/articles/claude-code-webfetch-haiku-summary)
