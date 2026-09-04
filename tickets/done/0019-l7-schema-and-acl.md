---
status: close
type: feat
base: main
targets:
  - docs/guarantees.md
  - packages/egress-guard/README.md
  - packages/egress-guard/docs/spec.md
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/templates/firewall.audit.json
  - packages/egress-guard/templates/firewall.example.json
  - packages/egress-guard/templates/firewall.json
  - packages/egress-guard/tests/firewall-config.test.sh
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# firewall.json にスキーマ version 2 と実現層を導入し、proxy ACL への変換を足す

## 内容

egress-guard の egress 制御を、L3（iptables + ipset の IP allowlist）だけの構成から、
L7 forward proxy を既定としつつ L3 も選べる構成へ移す束の 1 枚目。束は 3 枚:

- **0019 スキーマ version 2 と proxy ACL への変換**（このチケット）
- 0020 最終テーブルの分岐と sidecar の配線
- 0021 実装に対する検証と、L7 への切り替え

束の共通の前提:

- **実現層の既定は L7。L3 は設定に明示したときだけ選べる。** 既定を安全側に置くのは、L3 に残る
  制限（ワイルドカード不可、アドレスが動くドメインを載せられない）を知らずに踏む経路を作らない
  ため
- **TLS を終端しない。** proxy はクライアントの `CONNECT` を受けてトンネルするだけで、証明書を
  差し替える構成は採らない
- **proxy は明示型。** クライアントは `HTTP_PROXY` / `HTTPS_PROXY` を読んで自分から proxy へ
  つなぐ。透過型（気づかせずに横取りする方式）は採らない。暗号化された ClientHello の下では
  接続先名が読めず、allowlist が黙って無効化されるうえ、そうなったことを検出する手段が
  現在の実装に無いため
- **不変条件は 3 枚のどこでも弱めない。** とくに「ポリシーの変更にはイメージの再ビルドが要る」
  という性質は、L7 側でも sidecar のイメージに ACL を焼き込むことで満たす
- **proxy の実装は Squid を前提に書くが、固定ではない。** 常駐メモリの都合で別の実装へ替える
  可能性がある。そのため **ACL の出力形式は「1 行 1 ドメインのプレーンテキスト」に保ち、
  実装固有の設定は書かない**

このチケットで行うこと。

### 1. スキーマ version 2

`version` は現在 `1` のみを受理する。`2` を受理するように広げ、次を足す。

- **実現層のフィールド**を追加する。値は L7 と L3 の 2 つ。**省略時は L7。** L3 は明示しないと
  選べない。フィールド名と値の綴りは既存の `mode` / `profile` の流儀（許容値を直書きし `case`
  で検証する）に揃える
- **`version` が 1 の設定は L3 として解釈する。`version` の省略は従来どおり拒否する。** 既存の
  利用者の設定はすべて `version` を持っている（これまで必須だった）ので、`1` を受理すれば互換は
  保たれる。**省略を受理しても救われる既存設定は 1 つも無く、失うものがある**——`version` の
  打ち間違いが「省略」として解釈され、version 2 のつもりの設定が黙って L3 で動く経路が開く。
  実現層のフィールドは version 2 でだけ書ける
- **version 2 では `.example.com` 形式（先頭ドット）を `allowDomains` で受理する。** 意味は
  「そのドメイン自身と、その下のすべてのサブドメイン」——`.example.com` は `example.com` にも
  `a.b.example.com` にも一致する。**apex を含む。**
- **`*` を含む値は version 2 でも従来どおり拒否する。** `*.example.com` は一般には apex を
  含まない記法として使われており、apex を含む意味をこの綴りに与えると、書いた内容より広く
  効くという形のずれを作る。拒否メッセージには「代わりに `.example.com` と書く」を含める
- **L3 を選んだ設定に先頭ドットの値が書かれていたら拒否する。** L3 の実現層はサブドメインを
  列挙できないため、受理すると apex だけが許可されてサブドメインが黙って落ちる。受理したが
  履行しない状態を作らない

### 2. proxy ACL への変換

`init-project-firewall.sh` に、設定から proxy 用の ACL を stdout へ出す読み取り専用のオプション
を足す（`--print-allowlist` と同じ系統の、netfilter に触れないオプション）。

- 出力は **1 行 1 ドメインのプレーンテキスト**。profile のバンドル由来と `allowDomains` を
  マージ・ソート・重複除去する（`--print-allowlist` と同じ扱い）
- **包含関係にある行を潰す。** `.example.com` と `example.com` の両方が出力に並ぶと、Squid は
  1 つの ACL 内でこの 2 つを同時に扱えず、警告を出したうえで一方を落とす（致命ではないので
  黙って片方が効かなくなる）。**変換側で、広いほうだけを残す。** `.example.com` があれば
  `example.com` も `a.example.com` も出力しない
- **`--print-allowlist` と同じく、ネットワークにも netfilter にも触れる外部コマンドを起動しない。**
  egress が閉じたコンテナから非特権で読めることが要件

このオプションを sidecar のイメージのビルド時に呼ぶのが 0020 の仕事であり、このチケットでは
**変換そのものと、その出力の検査**までを行う。

### 3. テンプレートと README

- 同梱テンプレート 3 種を version 2 へ上げる。`firewall.json` と `firewall.audit.json` は実現層を
  **書かない**（既定の L7 を選ばせる）。`firewall.example.json` は先頭ドットの例を見せる
- README のワイルドカード拒否メッセージの実物を、新しい文面へ差し替える
- **README に実現層フィールドの節を立てる。** 選び方（省略時は L7、`l3` は明示したときだけ）と、
  `l3` を明示した version 2 の設定例を 1 つ置く。**この例をテンプレートに入れることはできない**
  ——`l3` の設定は先頭ドットを拒否するので、先頭ドットの例と同じファイルには同居できず、
  同梱テンプレートは検証を通る必要がある。実現層はこのチケットが新設する公開面なので、
  利用者が字面を読める場所が 1 つも無い状態にしない

### 4. spec.md の現在形化

`spec.md` §9.1 は「ワイルドカードドメインは使用不可」を現在形で書いている。version 2 でこれは
L3 に限った制限になるため、その節を書き換える。**§9.1 を削除するのではなく、L3 実現層の制限
として書き直す**（L3 は残るので制限も残る）。

**§3.1 のフィールド表も同時に直す。** 表は `version` を「現在は `1` のみ」と書いており、この
チケットがテンプレート 3 種を version 2 へ上げるため、**同梱テンプレートが拒否されると読める
状態になる**。`version` の受理範囲を直し、実現層のフィールドの行を足し、`allowDomains` の
「ワイルドカードは使用不可」を先頭ドットの扱いに合わせる。

§10.1 の記述の更新は 0020 で行う。

### やらないこと

- **sidecar の追加も、compose の配線も、`init-project-firewall.sh` の最終テーブルの分岐も
  しない。** それらは 0020。このチケットが変えるのは設定の読み取りと検証、および ACL の出力
  だけで、**適用される iptables のルールは 1 行も変わらない**
- **実装候補（Squid かどうか）を決める材料はここに書かない。** 出力形式を実装非依存に保つのが
  このチケットの責任範囲
- `verification-record.md` と `known-issues.md` は触らない（0021）
- 設定ファイルの自動移行ツールは作らない。version 1 はそのまま動くので移行は任意

### 実装上の注意

- 変換の出力に設計文書の節番号や不変条件の記号を書かない。README の拒否メッセージも同様に、
  受け取った側が参照先を持たない記号を含めない
- テストは既存の `check_config` / `accepts` / `rejects` の流儀に合わせる。新しい検査を足したら
  **受理側だけでなく拒否側の対照も必ず置く**

## 保証

### 新たに宣言する保証

- `version` は必須であり、値は `1` と `2` を受理する。それ以外の値・非整数・省略はいずれも拒否
  する。実現層のフィールドを書けるのは version 2 の設定だけである（テスト: "version 2 is accepted" /
  "config rejected: an omitted version" / "a realisation layer field is refused in a version 1 config"）

  > version 1 の設定を L3 として解釈することは、このチケットでは宣言しない。**このチケットの
  > 範囲では観測面が無い**——`LAYER` を読むのは version 2 の先頭ドット判定だけで、version 1 の
  > 設定では先頭ドットが先にホスト名構文で落ちるため、解釈を L7 に変えてもテストが緑のままに
  > なる。最終テーブルの分岐が入って観測可能になる 0020 で宣言する。
- version 2 の設定で実現層を省略すると L7 を選んだことになる。L3 は明示して初めて選ばれる
  （テスト: "an omitted realisation layer means L7"）
- version 2 の `allowDomains` は先頭ドットの値を受理し、それは「そのドメイン自身とすべての
  サブドメイン」を意味する。`*` を含む値は version にかかわらず拒否し、メッセージは代わりに
  書くべき先頭ドットの形を含む（テスト: "a leading dot domain is accepted in version 2" /
  "the wildcard rejection points at the leading dot form"）
- L3 を選んだ設定に先頭ドットの値が含まれていれば拒否する。L3 はサブドメインを列挙できず、
  受理すれば apex だけが通ってサブドメインは黙って落ちるため（テスト: "a leading dot domain is refused under L3"）
- proxy ACL の出力は 1 行 1 ドメインのプレーンテキストで、profile 由来と `allowDomains` を
  マージ・ソート・重複除去し、包含関係にある行は広いほうだけを残す。ネットワークにも
  netfilter にも触れる外部コマンドを起動しない（テスト: "the proxy ACL subsumes narrower entries" /
  "the proxy ACL runs no external command")

### 維持する保証

- 台帳 §4 の「同梱テンプレート3種と、README および `docs/` のフェンス内に書かれた設定例のうち
  版を宣言しているものは、すべて検証を通る」——テンプレート 3 種と README の例を version 2 へ
  上げるため、この検査の対象がまるごと入れ替わる
- 台帳 §4 の「`allowDomains` に受理されるのは ASCII のホスト構文だけ」以下の各拒否——先頭ドット
  を受理するようになるため受理の境界が動く。空文字・シェルメタ文字・制御文字・連続ドット・
  単一ラベル・IP リテラルの拒否はいずれもそのまま残る
- 台帳 §5 の適用に関する行はすべて維持する。このチケットは iptables のルールを 1 行も変えない

### 廃止する保証

- 台帳 §4 の「`version` は必須で整数 `1` のみ」——`2` を受理するようになるため取り下げ、上記の
  新しい行で置き換える
- 台帳 §4 の「`allowDomains` のワイルドカードは全形（`*` / `*.com` / `*.co.*` / `example.*` /
  `*.example.com`）で拒否し、メッセージに代わりに書くべきものを含める」——`*` を含む形の拒否は
  残るが、「代わりに書くべきもの」の内容が具体名の列挙から先頭ドットの形に変わるため、
  行として取り下げて上記の新しい行で置き換える
