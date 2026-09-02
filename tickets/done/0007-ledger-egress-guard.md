---
status: close
type: docs
base: main
targets:
  - docs/guarantees.md
verify: []
---

# 台帳に `@himorogy/egress-guard` の保証を載せる

## 内容

この変更は保証台帳の敷設を配布単位で分割した束の3枚目である。

**束の全体像。** このリポジトリは複数の配布単位を通じて外部へ公開面を提供しているが、これまで保証台帳を持たなかった。既存の18本のテストが固定している振る舞いを抽出し、外から観測できる語彙の宣言文として台帳へ移す。抽出はテストのラベルではなくテスト本体を読んで行った。

**家族一覧（順序依存あり）:** 0005 分母と境界宣言 → 0006 env-guard → **0007 egress-guard** → 0008 prod 起動経路 → 0009 認証と出荷物検査 → 0010 ホスト入口 → 0011 ホスト注入・broker・loopback。

**不変条件:** 台帳を変更する経路はチケットのみ。索引の粒度はテストファイル単位に固定する（0005 が境界宣言で定めた）。

**この枚の役割。** 0005 が敷いた分母のうち配布単位 B（npm パッケージ `@himorogy/egress-guard`）の保証を `§4` と `§5` として台帳へ載せる。

`init-project-firewall.sh` はイメージへも複製されるが、この枚が載せるのは**スクリプトそのものの振る舞い**であって、イメージへ複製されて実行可能になっていることではない。後者は配置の約束であり 0009 が扱う。

これはセキュリティ境界なので、順序に関する約束（何が何より前に起きるか）と fail closed の性質を落とさずに書く。

### やらないこと

- 他の配布単位の保証を載せること
- `packages/egress-guard` の実装・テストの変更
- イメージへの配置の約束（0009 が扱う）

## 保証

### 新たに宣言する保証

台帳 `docs/guarantees.md` の `## Guarantees` へ以下の2節を追加する。出典はテストファイル単位。

#### `### 4. packages/egress-guard/tests/firewall-config.test.sh — packages/egress-guard/scripts/init-project-firewall.sh（設定の検証）`

- `--check-config` は設定を検証して終了し、規則には一切触れない。受理時は 0 で終了し、読んだ設定のパスと妥当である旨を出す
- `version` は必須で整数 `1` のみ。未知フィールド・未知 `mode`・JSON でない入力・オブジェクトでない入力はすべて非ゼロで拒否する
- `allowDomains` のワイルドカードは全形（`*` / `*.com` / `*.co.*` / `example.*` / `*.example.com`）で拒否し、メッセージに代わりに書くべきものを含める。DNS がゾーンの子孫を列挙できない以上、受理は「受理したが履行しない」方針になるため（テスト: "the wildcard rejection explains what to write instead"）
- `allowDomains` に受理されるのは ASCII のホスト構文だけで、空文字・空白・シェルメタ文字・コマンド置換・改行・連続ドット・先頭や末尾のハイフン・単一ラベル・IP リテラルはいずれも拒否する
- `allowCidrs` は全経路・RFC1918・loopback・link-local・CGNAT を拒否し、**それらを内包する上位ネットも同じく拒否する**。prefix の欠落、範囲外の prefix、範囲外のオクテット、ゼロ埋め八進、規則の断片を追記した文字列も拒否する
- `allowHostPorts` と `sshdPort` は 1〜65535 の十進整数のみ受理する。`0` は「無効」の綴りではないので拒否する（テスト: "config rejected: sshdPort 0"）
- `sshdPort` の省略と `null` は「inbound port を一切開かない」という方針そのものであり、どちらも受理される
- 制御文字を含む値は、どのフィールドにあってもフィールド名にあっても拒否し、原因を名指しする。差分で人間が読んだ値と実際に許可される値が食い違う経路を閉じるため（テスト: "the control character rejection names the cause"）
- 固定パスの設定ファイルは、symlink でないこと・ファイルとその親ディレクトリの双方が root 所有であること・双方が group や other から書き込めないことを要求し、外れると理由を述べて非ゼロ終了する。設定ファイルが存在しないこと自体はエラーではない（テスト: "a symlink is refused even when it points at a root owned file"）
- `profile` は選ばれたバンドルだけを導入する。配列・単一文字列・空配列・`null`・省略がすべて受理され、同じバンドルを重複指名しても1回指名と同じ方針になる。「全部」を意味する名前は存在しない
- バンドル名は6つに限られ、未知の名前は実在するバンドルの一覧を添えて拒否する。退役した名前は専用の拒否メッセージを持ち、書き換え例と全バンドル名を含める
- ベンダーのバンドルは互いのホストを持ち込まない。どのバンドルにも属さないホストは一覧にも現れない
- `--print-allowlist` は選択した profile・ドメイン・CIDR・ホストポート・モードを stdout に出す。バンドル由来と `allowDomains` はマージ・ソート・重複除去され、進捗行は stdout に混ざらない
- `--print-allowlist` は、適用が拒否する設定からは一覧を作らず同じ検証で非ゼロ終了する。また sudo 経由の起動を拒否する（テスト: "--print-allowlist is refused when invoked through sudo"）
- 同梱テンプレート3種と、README および `docs/` のフェンス内に書かれた設定例のうち版を宣言しているものは、すべて検証を通る。コメント付きの例はコメントを残したままでは拒否される。既定のテンプレートは enforce モード、audit テンプレートは audit モードを選ぶ

#### `### 5. packages/egress-guard/tests/firewall-rules.test.sh — packages/egress-guard/scripts/init-project-firewall.sh（規則の適用）`

- 適用は「先に閉じ、後で作る」。IPv6 の遮断は他のどの適用よりも前に、bootstrap テーブルの導入は最初の名前解決と最初の外向き取得よりも前に、そして allowlist の差し替えよりも前に完了する（テスト: "IPv6 is closed before anything else is applied" / "IPv4 is closed before the first name resolution"）
- bootstrap テーブルは、INPUT と OUTPUT を落としたうえで割り当てられた resolver への 53 だけを許し、他の 53 を落とす。allowlist も記録器もホストゲートウェイも持たない。記録器はカーネルモジュールに依存し、bootstrap の適用失敗は致命なので載せない（テスト: "the bootstrap table has no recorder"）
- テーブルの更新はテーブル単位の入れ替えだけで行い、個々の規則を逐次変更する経路は使わない（テスト: "no per-rule iptables mutation is used"）
- allowlist は staging 側に全件を投入し終えてから原子的に差し替える。最後の追加は差し替えより前に来る（テスト: "the allowlist is complete before the swap"）
- 最終 IPv4 テーブルの順序は、resolver の許可 → 53 の記録 → 53 の遮断 → 確立済み接続の許可 → allowlist の許可 → 記録 → ログ → 拒否。DNS の固定は確立済み接続の許可より前、allowlist の許可は記録より前、記録は拒否より前に置かれる
- 一致しない egress は黙って捨てず、明示的に拒否する（テスト: "unmatched egress is rejected"）
- resolver は解決設定に書かれたアドレスを udp と tcp の両方で固定し、ハードコードしない
- IPv6 側は allowlist を持たず、記録用のログを添えて拒否する。黙って落とすと AAAA を持つ許可済みホストが接続の遅延として現れるため（テスト: "IPv6 egress is refused, not silently dropped"）
- audit モードでは OUTPUT の方針を**あえて許可のまま**にし、拒否を置かず、落ちるはずだった宛先を記録する。一方で INPUT は落としたまま、DNS の固定もそのまま、IPv6 も拒否したままにする（テスト: "audit leaves OUTPUT on ACCEPT" / "audit keeps INPUT on DROP"）
- 記録用のセットは期限付きで作られ、破棄されない。実行をまたいで残すのが意図（テスト: "the audit set is created but never destroyed"）
- 同じ設定での2回目の連続実行は 0 で終わり、IPv4 と IPv6 のいずれも1回目と完全に同一のテーブルを生成する
- 生成されるテーブルは1規則1行の整形された形をとり、規則行は必ず遷移先を持つ
- `sshdPort` を書かない設定では、bootstrap・最終・panic のどのテーブルにも inbound ポートも対になる応答経路も現れない。inbound を開くと戻りが確立済み接続として allowlist を経由せず出ていけるため、入口であると同時に出口になる（テスト: "no inbound port is opened when sshdPort is omitted"）
- `sshdPort` を書いた設定では3つのテーブルすべてにそのポートが開く。panic テーブルにはさらに応答経路の許可が付く（panic は一般の確立済み接続を持たないため、これが無いと開いていても使えない）。退役した既定ポートへは戻らない
- 例外として、**設定が拒否された実行の panic テーブルでは `sshdPort` をあえて開かない**。その panic テーブルは設定を読む前に適用されるので、ファイルの中の数値はまだ検証されていない（テスト: "a port named by a refused configuration is not opened"）
- 適用のフェーズは設定の読み取りより前に始まる。初回起動での「以前の方針」は全許可なので、設定エラーで何も適用せず抜けるとコンテナが開けっ放しになる。よって設定の拒否も panic テーブルへ落ちる（テスト: "a rejected configuration falls back to the panic table"）
- 設定の拒否・resolver の欠落・anchor の解決失敗・ホストポートの宛先が定まらないこと・最終テーブルの拒否・自己検証の失敗は、いずれも非ゼロ終了し IPv4 と IPv6 の両方で panic テーブルへ落ちる。panic テーブルは INPUT・FORWARD・OUTPUT を落とし、loopback の2規則だけを持ち、DNS の固定も確立済み接続も allowlist も記録器もログも拒否も持たない。**IPv6 側の panic テーブルは拒否すら持たず黙って落とす**
- panic テーブルの適用自体が拒否されても実行は非ゼロで終わり、残るのは直前に受理された bootstrap テーブル——すなわち既に閉じており、割り当て resolver への 53 だけが通る状態である（テスト: "the effective table is still the bootstrap table"）
- 記録器を含む最終テーブルが拒否された場合は、記録器を外した同じテーブルで一度だけ再試行して 0 で終わり、その旨を報告する。再試行のテーブルも拒否を保つ。再試行も拒否されたときだけ panic テーブルを**独立した適用として**投入し非ゼロで終わる（テスト: "the panic table is a restore of its own, not the last rejected one"）
- GitHub の meta API は、github バンドルが選ばれているときだけ、かつ最終テーブルが有効になった後にだけ取得する。後でなければならないのは、その取得に要る egress を開くのが最終テーブル自身だからである。選ばれていないときに取得を試みないのは、意図的なスキップと取得失敗を区別するためであり、毎回「meta が使えない」と警告すると、本当にレンジが欠けた1回を読み飛ばす習慣を作る。取得は加算のみの best-effort で、同じホストは DNS 経由で既にセットに入っている——**唯一の外部取得をこの位置に置くことで、リビルドのどの工程も外部到達性を前提としない状態を保ち、任意の時点で強制終了しても不変条件が壊れないようにしている**（テスト: "the meta API is only fetched after the final table is live"）
- meta 応答の各項目は集約に渡す前に検証を通す。IPv6 の項目・private なレンジ・不正な表記は集約にもセットにも到達せず、落とした件数を報告する。使えない項目があっても実行は失敗しない（テスト: "a private meta range never reaches aggregate"）
- meta 応答を最後まで読めなかった場合は、追加ゼロで 0 終了しつつその旨を報告する。セットは加算のみなので、沈黙して部分適用にしない
- DNS の回答も禁止レンジで篩う。メタデータサービスのアドレスや private なアドレスはセットに入らず、理由が報告される。CIDR の指定には禁止レンジの検査があるのに DNS の回答には無い、という非対称がそのまま迂回路になっていた——許可済みドメインのゾーンが攻撃者の管理下にあるか汚染されていれば、メタデータサービスのアドレスを返すだけで allowlist に載る。しかも**再適用の時刻を選べる立場の者は rebinding のタイミングも選べる**（テスト: "the metadata service address is not allowed"）
- 全回答が禁止レンジのドメインは、解決できなかったのと同じ扱いで警告だけを出して実行を継続し、自己検証もそのドメインを飛ばす。ここで失敗にすると、外部の名前空間を握る者が回答1本でコンテナを起動不能にできる
- ホストポートの許可は、既定経路のゲートウェイとホスト名の解決結果の**両方**に対して個別アドレスとして出す。ホストのネットワーク全体は開かない。両方に出すのは、この2つが別アドレスになりうるためで、実測ではゲートウェイ宛の規則にパケットが1つも乗らず、到達はホスト名側でのみ成立した——片方だけを許していた頃はこの機能自体が動いていなかった（テスト: "the host network is not allowed wholesale"）
- ホスト名が公開アドレスを返した場合はそこにポートを開かず報告するが、ゲートウェイ側は開いたまま実行を継続する。ホスト名が私設アドレスを返すのは正常なので禁止レンジの検査は使えず、代わりに「私設アドレスであること」を要求する逆向きの検査を置いている。公開アドレスが返るのは名前が横取りされた場合であり、そこにポートを開けばホスト宛の許可ではなく**任意のインターネットホストへの穴**になる。ゲートウェイ側を落とさないのは、そちらがカーネルの経路表という別の入力源から来ており、汚染されうる入力に可用性の決定権を渡さないためである
- 自己検証の「到達できないはず」の検査は、その宛先が allowlist に載っていたら別の宛先へ移る。解決結果が実行のたびに入れ替わっても、構築時と検証時のアドレス集合が1つでも重なれば合格と判定する（正しい方針を確率的に panic させないため）
- anchor になるドメインが1つも無い設定は失敗ではなく、検査を飛ばした旨を述べて 0 で終わる。anchor が空になるのは方針にドメインが1本も無いとき——CIDR とホストポートだけの設定——に限られ、それは正当な設定である。死んだネットワークと空の allowlist を区別する手立てが無い以上、探るためのドメインを勝手に発明するより、飛ばしたと言うほうがよい。飛ばすのは「許可したものに届くか」側の検査だけで、「許可していないものが遮断されるか」側は飛ばさない
- anchor がある場合に解決できなければ非ゼロ終了し panic テーブルへ落ちる（テスト: "an unresolvable host falls back to the panic table"）
- 適用時の設定は固定パスからのみ読み、作業ディレクトリを探索しない。ワークスペース側に置かれた設定は読まれず、方針を緩められない（テスト: "the workspace copy cannot relax the policy"）
- sudo 経由の起動で引数を1つでも渡すと拒否する。sudoers の指定が空引数リストを書き忘れていても、開発用オプションが非特権ユーザーの手に渡らないようにするため
- sudo 経由の起動では、スクリプト自身が root 所有でなければ昇格経路の問題として拒否し、理由を述べる（テスト: "a script the unprivileged user owns is refused under sudo"）
- `--print-allowlist` は、ネットワークにも netfilter にも触れる外部コマンドを一つも起動しない。egress が既に閉じたコンテナから非特権で読めることが要件

### 維持する保証

- 台帳末尾の境界宣言（0005 が敷いた免責・公開面の定義・索引の粒度）
- 0006 が載せた `§1`〜`§3`。この枚は節を追加するだけで既存の節に触れない

### 廃止する保証

- なし。既存の約束を取り下げる変更ではない
