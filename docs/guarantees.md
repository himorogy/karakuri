# 保証台帳

## Guarantees

### 1. `packages/env-guard/tests/install.test.sh` — `packages/env-guard/bin/env-guard.js`

起源: `0006-ledger-env-guard`

- `install` は、書き込みが1キーの追加で済むときだけ `package.json` を書き換える。追加後のファイルは期待テキストと1バイトの差も無い（既存キーの順序・インデント・末尾改行を含む）（テスト: "pre-commit 未設定 -> 追加した 1 キー以外は 1 バイトも変わらない"）
- 既に `simple-git-hooks` セクションがあるときは、その中へ `pre-commit` を足すだけで、同居する他の hook 設定はそのまま残る
- 導入済みのリポジトリで再実行しても終了コード 0 で、導入済みである旨を出力し `package.json` は1バイトも変わらない（テスト: "2 回目の実行 -> package.json が 1 バイトも変わらない"）
- `simple-git-hooks` が依存に無いときは非ゼロ終了し、依存として入れるためのコマンドを出力し、`package.json` には触れない
- `pre-commit` に別のコマンドが設定済みのときは上書きせずに非ゼロ終了し、現在の値と必要な値の両方を出力する。既存の値はそのまま残る（テスト: "別のコマンドが設定済み -> 既存の値が保たれている"）
- `install --check` は状態を報告するだけで `package.json` を一切書き換えない。未導入なら非ゼロ、導入済みなら 0 で終了する
- `install` は `package.json` に書けたことをもって成功としない。hook が実体化され、その呼び先のファイルが実際に置かれていることまで確かめてから 0 で終了する
- 呼び先のパッケージが `node_modules` に無いときは、`package.json` に書けても hook ファイルが生まれても成功と報告せず、理由を添えて非ゼロ終了する。同じ状態で `--check` も 0 を返さない（テスト: "否定対照: hook の呼び先が無い -> 導入を成功と報告せず非ゼロ終了する"）
- 導入後、平文の値を含む `.env` を stage して commit しようとすると hook が非ゼロで拒否し、どの変数が暗号化されていないかを名前で伝える
- 拒否の出力に平文の値そのものは現れない（テスト: "通し: 拒否の出力に値そのものが出ていない"）
- 暗号化済みの `.env` は通り、検査した件数が出力される
- hook からスキャナへの経路が壊れていて検査できないときは、黙って通さず理由を添えて非ゼロ終了する（テスト: "否定対照: スキャナが見つからない -> 黙って通さず、理由付きで非ゼロ終了する"）
- `core.hooksPath` の指す hook が共有スキャナ `env-guard-scan` を直接呼んでいれば、パッケージ側の hook を経由していなくても `--check` は 0 を返す。スキャナにもパッケージ側の hook にも触れない hook ファイルでは `--check` が非ゼロになる（意図的な緩和。コンテナ内で `--check` が偽陰性になった実測に基づく）
- `install` は、git リポジトリの外、または `git` が PATH に無いときは `package.json` を書き換えず、何も書かなかった旨を出して非ゼロ終了する（テスト: "git repo の外 -> 非ゼロ終了し、何も書かなかったことを出力する"）

### 2. `images/runtime-base/tests/env-guard.test.sh` — `packages/env-guard/bin/env-guard-scan`

起源: `0006-ledger-env-guard`

- 平文の `.env` は非ゼロ終了し、`<パス> line <行番号>: <キー名> is not encrypted` の形で場所とキー名が名指しされる
- 暗号化済みの `.env` は 0 で終了し、検査したファイル数が出力に残る
- 作業ツリーに `.env.keys` があると非ゼロ終了し、そのパスが報告される
- 既定の検査対象は basename が `.env` で始まるものと `secret.env.*`。それ以外の名前は対象外として 0 で通る。既定の許可リストは `.env.container.example` を飛ばし、飛ばしたことが出力に残る
- 平文の値と、`=` を含まない行の内容そのものは、検出時にも出力へ一切反射されない。報告されるのはキー名と行番号だけである（テスト: "the plaintext value is not echoed to the log" / "a line without '=' is not echoed to the log"）
- 1件も検査しなかった実行は黙って 0 を返さず、何も検査しなかったことを明示する
- git リポジトリでない場所では「0件検査して合格」に倒さず非ゼロ終了し、何も検査していないことを説明する（テスト: "a directory that is not a git repo fails instead of passing"）
- リポジトリルートの `env-guard.conf` で検査対象パターンと許可リストを上書きでき、既定では拾わないファイルを拾い、既定では落ちるファイルを許すようになる
- 設定ファイルが壊れているとき（未知のディレクティブ・値の無いディレクティブ・読めない）は既定へ黙って倒れず、行番号付きの理由を添えて非ゼロ終了する（テスト: "an unknown directive fails instead of falling back to the defaults"）
- `env-guard.conf` 自身は、パターンを「全部拾う」に上書きしてもなお検査対象にならない（設定ファイルの中身は暗号化された代入の形を取り得ないため、検査対象になれば必ず落ちる）
- 同じリポジトリに対して CI 側の入口（tracked の一覧）と hook（staged の一覧）は、終了コードだけでなく出力までバイト一致する
- hook は自前の判定を持たず共有スキャナへ委ねる。hook が呼ぶスキャナを差し替えると、合否も終了コードも差し替えた側のものになる（テスト: "the hook passes plaintext when the scanner it calls passes" / "the hook returns the stand-in scanner's own exit code"）。hook 単体でも `pattern` / `allow` の上書きが同じように効く

### 3. `images/runtime-base/tests/hook.test.sh` — `packages/env-guard/hooks/pre-commit`

起源: `0006-ledger-env-guard`

- hook はカレントディレクトリの git リポジトリのルートを自分で決め、そこを起点に `.env.keys` を探す
- リポジトリルート直下の `.env.keys` でもサブディレクトリの `.env.keys` でも非ゼロ終了し、検出したパスがそのまま出力に現れる
- `node_modules` 配下の `.env.keys` は無視する
- `.env.keys` が一つも無ければ、平文でない `.env` 系ファイルが存在していても 0 で通る
- 走査を完走できなかったときは「0件だった」と取り違えて 0 を返さず、理由が読み取れる形で非ゼロ終了する（テスト: "find が失敗したら理由 (検査を完走できなかった) が読み取れる形で非ゼロ終了する"）

### 4. `packages/egress-guard/tests/firewall-config.test.sh` — `packages/egress-guard/scripts/init-project-firewall.sh`（設定の検証）

起源: `0007-ledger-egress-guard`

- `--check-config` は設定を検証して終了し、規則には一切触れない。受理時は 0 で終了し、読んだ設定のパスと妥当である旨を出す
- 未知フィールド・未知 `mode`・JSON でない入力・オブジェクトでない入力はすべて非ゼロで拒否する
- `version` は必須であり、値は `1` と `2` を受理する。それ以外の値・非整数・省略はいずれも拒否する。実現層のフィールドを書けるのは version 2 の設定だけである（テスト: "version 2 is accepted" / "config rejected: an omitted version" / "a realisation layer field is refused in a version 1 config"）
- version 2 の設定で `layer` を省略すると L7 を選んだことになる。L3 は明示して初めて選ばれる（テスト: "an omitted realisation layer means L7"）
- version 2 の `allowDomains` は先頭ドットの値を受理し、それは「そのドメイン自身とすべてのサブドメイン」を意味する。`*` を含む値は version にかかわらず拒否し、メッセージは代わりに書くべき先頭ドットの形を含む（テスト: "a leading dot domain is accepted in version 2" / "the wildcard rejection points at the leading dot form"）
- `layer` に `l3` を選んだ設定に先頭ドットの値が含まれていれば拒否する。L3 はサブドメインを列挙できず、受理すれば apex だけが通ってサブドメインは黙って落ちるため（テスト: "a leading dot domain is refused under L3"）
- `--print-proxy-acl` の出力は 1 行 1 ドメインのプレーンテキストで、profile 由来と `allowDomains` をマージ・ソート・重複除去し、包含関係にある行は広いほうだけを残す。ネットワークにも netfilter にも触れる外部コマンドを起動しない（テスト: "the proxy ACL subsumes narrower entries" / "the proxy ACL runs no network or netfilter command"）
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

### 5. `packages/egress-guard/tests/firewall-rules.test.sh` — `packages/egress-guard/scripts/init-project-firewall.sh`（規則の適用）

起源: `0007-ledger-egress-guard`

- 適用は「先に閉じ、後で作る」。IPv6 の遮断は他のどの適用よりも前に、bootstrap テーブルの導入は最初の名前解決と最初の外向き取得よりも前に、そして allowlist の差し替えよりも前に完了する（テスト: "IPv6 is closed before anything else is applied" / "IPv4 is closed before the first name resolution"）
- bootstrap テーブルは、INPUT と OUTPUT を落としたうえで割り当てられた resolver への 53 だけを許し、他の 53 を落とす。allowlist も記録器もホストゲートウェイも持たない。記録器はカーネルモジュールに依存し、bootstrap の適用失敗は致命なので載せない（テスト: "the bootstrap table has no recorder"）
- テーブルの更新はテーブル単位の入れ替えだけで行い、個々の規則を逐次変更する経路は使わない（テスト: "no per-rule iptables mutation is used"）
- allowlist は staging 側に全件を投入し終えてから原子的に差し替える。最後の追加は差し替えより前に来る（テスト: "the allowlist is complete before the swap"）
- L3 実現層では、最終 IPv4 テーブルの順序は、resolver の許可 → 53 の記録 → 53 の遮断 → 確立済み接続の許可 → allowlist の許可 → 記録 → ログ → 拒否。DNS の固定は確立済み接続の許可より前、allowlist の許可は記録より前、記録は拒否より前に置かれる（起源: `0020-l7-sidecar-and-branch`）
- L7 実現層では、最終 IPv4 テーブルの順序は、resolver の許可 → 53 の遮断 → 確立済み接続の許可 → `allowCidrs` / `allowHostPorts` の許可 → proxy 宛の許可 → ログ → 拒否。53 番への試行の記録（ipset への追加）は置かないが、割り当てリゾルバ以外への 53 番を拒否したこと自体は `fw-dns-drop:` の `LOG` ルールとして残る（起源: `0020-l7-sidecar-and-branch`）
- L7 実現層を選んだ設定では、最終 IPv4 テーブルにドメイン由来の allowlist が現れず、proxy 宛の許可・DNS の固定・loopback・`allowCidrs`・`allowHostPorts` だけが残る。名前による許可は proxy 側の ACL が担う（テスト: "the L7 final table carries no domain allowlist" / "allowCidrs still reaches the L7 final table"）（起源: `0020-l7-sidecar-and-branch`）
- L3 実現層を選んだ設定では、最終 IPv4 テーブルは現在と同一である。加えて適用ログに、その実現層に残る制限（先頭ドットのドメインが書けないこと、アドレスが動くドメインを載せられないこと）が出る（テスト: "the L3 final table is unchanged" / "choosing L3 reports what it cannot express"）（起源: `0020-l7-sidecar-and-branch`）
- `version` が `1` の設定は L3 実現層として扱われ、最終 IPv4 テーブルは実現層を `l3` と明示した version 2 の設定と同一になる（テスト: "a version 1 config produces the L3 final table"）（起源: `0020-l7-sidecar-and-branch`）
- 一致しない egress は黙って捨てず、明示的に拒否する（テスト: "unmatched egress is rejected"）
- resolver は解決設定に書かれたアドレスを udp と tcp の両方で固定し、ハードコードしない
- IPv6 側は allowlist を持たず、記録用のログを添えて拒否する。黙って落とすと AAAA を持つ許可済みホストが接続の遅延として現れるため（テスト: "IPv6 egress is refused, not silently dropped"）
- L3 実現層では、audit モードは OUTPUT の方針を**あえて許可のまま**にし、拒否を置かず、落ちるはずだった宛先を記録する。一方で INPUT は落としたまま、DNS の固定もそのまま、IPv6 も拒否したままにする（テスト: "audit leaves OUTPUT on ACCEPT" / "audit keeps INPUT on DROP"）（起源: `0020-l7-sidecar-and-branch`）
- L3 実現層では、記録用のセットは期限付きで作られ、破棄されない。実行をまたいで残すのが意図（テスト: "the audit set is created but never destroyed"）（起源: `0020-l7-sidecar-and-branch`）
- L7 実現層では、`mode` が `audit` でも `enforce` でも最終 IPv4 テーブルは同一であり、OUTPUT の方針は `ACCEPT` にならない。ipset の記録器も置かない。proxy への到達は `mode` によらず強制され、proxy を迂回した直接接続は audit でも塞がれる（テスト: "the L7 final table is identical in audit and enforce" / "L7 audit does not put OUTPUT on ACCEPT" / "the L7 final table has no recorder"）（起源: `0020-l7-sidecar-and-branch`）
- bootstrap テーブル・panic テーブル・IPv6 の全拒否・DNS の固定・冪等性は実現層によって変わらない（テスト: "the bootstrap table is identical across realisation layers" / "the panic table is identical across realisation layers" / "the IPv6 table is identical across realisation layers" / "the second L7 run produces an identical IPv4 table" / "the second L7 run produces an identical IPv6 table" / "the L7 final table accepts the assigned resolver on udp/53" / "the L7 final table accepts the assigned resolver on tcp/53" / "the L7 final table drops other udp/53" / "the L7 final table drops other tcp/53"）（起源: `0020-l7-sidecar-and-branch`）
- 同じ設定での2回目の連続実行は 0 で終わり、IPv4 と IPv6 のいずれも1回目と完全に同一のテーブルを生成する
- 生成されるテーブルは1規則1行の整形された形をとり、規則行は必ず遷移先を持つ
- `sshdPort` を書かない設定では、bootstrap・最終・panic のどのテーブルにも inbound ポートも対になる応答経路も現れない。inbound を開くと戻りが確立済み接続として allowlist を経由せず出ていけるため、入口であると同時に出口になる（テスト: "no inbound port is opened when sshdPort is omitted"）
- `sshdPort` を書いた設定では3つのテーブルすべてにそのポートが開く。panic テーブルにはさらに応答経路の許可が付く（panic は一般の確立済み接続を持たないため、これが無いと開いていても使えない）。退役した既定ポートへは戻らない
- 例外として、**設定が拒否された実行の panic テーブルでは `sshdPort` をあえて開かない**。その panic テーブルは設定を読む前に適用されるので、ファイルの中の数値はまだ検証されていない（テスト: "a port named by a refused configuration is not opened"）
- 適用のフェーズは設定の読み取りより前に始まる。初回起動での「以前の方針」は全許可なので、設定エラーで何も適用せず抜けるとコンテナが開けっ放しになる。よって設定の拒否も panic テーブルへ落ちる（テスト: "a rejected configuration falls back to the panic table"）
- 設定の拒否・resolver の欠落・anchor の解決失敗・ホストポートの宛先が定まらないこと・最終テーブルの拒否・自己検証の失敗は、いずれも非ゼロ終了し IPv4 と IPv6 の両方で panic テーブルへ落ちる。panic テーブルは INPUT・FORWARD・OUTPUT を落とし、loopback の2規則だけを持ち、DNS の固定も確立済み接続も allowlist も記録器もログも拒否も持たない。**IPv6 側の panic テーブルは拒否すら持たず黙って落とす**
- panic テーブルの適用自体が拒否されても実行は非ゼロで終わり、残るのは直前に受理された bootstrap テーブル——すなわち既に閉じており、割り当て resolver への 53 だけが通る状態である（テスト: "the effective table is still the bootstrap table"）
- 記録器を含む最終テーブルが拒否された場合は、記録器を外した同じテーブルで一度だけ再試行して 0 で終わり、その旨を報告する。再試行のテーブルも拒否を保つ。再試行も拒否されたときだけ panic テーブルを**独立した適用として**投入し非ゼロで終わる（テスト: "the panic table is a restore of its own, not the last rejected one"）
- L3 実現層では、GitHub の meta API は、github バンドルが選ばれているときだけ、かつ最終テーブルが有効になった後にだけ取得する。後でなければならないのは、その取得に要る egress を開くのが最終テーブル自身だからである。選ばれていないときに取得を試みないのは、意図的なスキップと取得失敗を区別するためであり、毎回「meta が使えない」と警告すると、本当にレンジが欠けた1回を読み飛ばす習慣を作る。取得は加算のみの best-effort で、同じホストは DNS 経由で既にセットに入っている——**唯一の外部取得をこの位置に置くことで、リビルドのどの工程も外部到達性を前提としない状態を保ち、任意の時点で強制終了しても不変条件が壊れないようにしている**（テスト: "the meta API is only fetched after the final table is live"）（起源: `0020-l7-sidecar-and-branch`）
- L7 実現層では、`profile` に `github` が含まれていても GitHub の meta API を取得せず、その IPv4 レンジは allowlist のセットに入らない。名前による許可は proxy 側の ACL が担うため、IP レンジを持つ意味が無く、持つと proxy を迂回して全ポートへ抜ける経路になる。L3 実現層では従来どおり取得する（テスト: "the L7 layer does not fetch the GitHub meta ranges" / "the L3 layer still fetches the GitHub meta ranges"）（起源: `0020-l7-sidecar-and-branch`）
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

### 6. `images/runtime-base/tests/entrypoint.test.sh` — `images/runtime-base/bin/prod-entrypoint.sh`

起源: `0008-ledger-prod-entry`

- 引数を渡さずに呼ぶと非ゼロ終了する。無引数の起動を成功として素通りさせない
- stdin から取り込む secret の入力検査は `§7` と同一である。1件も来ない・`=` を含まない行・空値・鍵名の形式違反のいずれでも非ゼロ終了し、それぞれの理由を出す
- 取込失敗のメッセージは入力行そのものも鍵名そのものも出力に反射しない（テスト: "パース失敗メッセージに入力行 (目印文字列) が出ない"）
- リポジトリ指定に資格情報が埋め込まれていれば非ゼロ終了し、埋めたトークン文字列は出力に現れない。この拒否は git 操作より前に効く（テスト: "GIT_REPO への資格情報埋め込み -> 非ゼロ終了、stderr にトークンが出ない"）
- ssh 形式のリポジトリ指定はこの資格情報チェックでは拒否しない。この場合の終了コードは固定せず、「その理由では落ちない」ことだけを固定する
- 正常系は 0 で完走し、secret は1変数1ファイル・mode 600 で保存され、作業ツリーが指定 ref のコミット内容へ復元される（テスト: "正常系: 生成された secret ファイルが mode 600"）
- GitHub トークンだけは checkout の後にファイルごと削除され、exec される側からは読めない。他の鍵は残る（テスト: "正常系: checkout 後に GH_TOKEN が削除されている"）
- 作業ツリーが非空かつ git 管理下でない残骸状態からでも復元でき、二回目の実行も成功し、remote の URL は指定したものになる。一度目の後に追跡ファイルを書き換えても、二度目で ref の内容へ戻る（テスト: "named volume 再利用時に tracked file の改変が復元される"）
- コミットとして解決できない ref は、解決できない旨を含むメッセージで非ゼロ終了する
- ref が40桁 hex でなければ既定で非ゼロ終了し、メッセージが脱出口の環境変数を名指しする。**この拒否時には解決結果の記録ファイルを書かない**（テスト: "40 桁 hex でない GIT_REF が拒否されたとき /run/prod-ref は書かれない (拒否は記録より前)"）。脱出口を明示したときだけ警告を出して 0 で続行する
- 40桁 hex の ref は脱出口なしで、可変 ref の警告も出さずに通る。大文字混じりの完全な sha も拒否しない。逆に40桁 hex を名前とするブランチやタグを指定した場合は非ゼロ終了し、記録も残らない。どちらの防壁で落ちるかは git の版に依存するため、固定するのは「非ゼロ終了かつ記録なし」だけである（テスト: "40 桁 hex を名前とする ref -> 非ゼロ終了し /run/prod-ref も書かれない"）
- 完走時に解決結果の記録が mode 644 で作られ、指定した ref・解決済みの sha・可変 ref であったかの3行が書かれ、解決した旨が stderr に出る（テスト: "/run/prod-ref が mode 644 (umask 077 の影響を受けず chmod で緩めている)"）
- 起動中に pnpm は一度も実行されない。store の設定は2種類の設定ファイルの両方へ、同一のパスで書かれる（読む側が pnpm の版で割れているため、片方では足りない）（テスト: "entrypoint は pnpm を一度も起動しない (self-switch を踏まない)"）
- 作業ツリーと secret 置き場の親が tmpfs であることを確認できないときは、対象パスを名指しした警告を出したうえで続行する。黙ってスキップしない

### 7. `images/runtime-base/tests/secrets-ingest.test.sh` — `images/runtime-base/bin/secrets-ingest.sh`

起源: `0008-ledger-prod-entry`

- `KEY=value` 行ごとに secret の置き場へ mode 600 のファイルが作られ、値が末尾改行なしでそのまま入る（テスト: "正常系: 生成された secret ファイルが mode 600"）
- 取込完了時、取り込んだ鍵名だけを空白区切りで並べた1行が stderr に出る。値は stderr のどこにも出ない（テスト: "正常系: stderr に値が出ない (鍵名のみ)"）
- 値に `=` が含まれても壊れない。区切りは最初の `=` だけである
- 値全体を囲む引用符は剥がされ、行末の CR も剥がされる。CRLF 入力でもファイルの中身は LF 入力とバイト単位で同一になる
- 空行とコメント行は無視され、取込一覧にも件数にも入らない
- `=` を含まない行、鍵名の形式違反、`export` 接頭辞、空値、取込0件は、いずれも非ゼロ終了し、それぞれの理由を出す
- 鍵名の形式検査は、secret 置き場に対するパストラバーサルを塞ぐ最終防波堤である（テスト: "不正な鍵名 -> 非ゼロ終了: ../etc/passwd=x"）
- 失敗メッセージは入力行の内容も鍵名も反射しない。位置は行番号だけで示す（テスト: "パース失敗メッセージに入力行 (目印文字列) が出ない"）
- 同じ鍵で再実行すると上書きされ、「既にある」で失敗しない
- `export` 接頭辞の非対応と空値の拒否は、パーサの穴ではなく方言の定義である。1行1変数の `KEY=value` のみを受け付け、dotenv 一般では合法な空値を secret の搬送路としては壊れた入力とみなす

### 8. `images/runtime-base/tests/shim.test.sh` — `images/runtime-base/shims/{wrangler,gh,dotenvx}`

起源: `0008-ledger-prod-entry`

- secret ファイルが存在し中身があるとき、対応する環境変数がその値で実体プロセスの環境に入り、実体が呼ばれる。呼び出し元が同名の環境変数を既に持っていても、ファイルの値が勝つ
- secret ファイルが存在して空のとき、非ゼロ終了し、空である旨と当該パスを stderr に出す。実体は一切呼ばれない（テスト: "wrangler: secret ファイルが空のとき実体は呼ばれない"）
- secret ファイルが存在し非空だが読めないとき、空値を注入して実体を呼ぶのではなく非ゼロ終了する。実体は呼ばれない（テスト: "wrangler: secret ファイルが読めない (mode 000) -> 非ゼロ終了 (空値注入ではない)"）
- secret ファイルが不在のとき、エラーにせず素通しで実体を呼び、呼び出し元の環境変数はそのまま引き継がれる。**環境の判別はせず、判定材料はファイルの有無だけである**
- `NODE_OPTIONS` は注入あり・素通しの両分岐で実体の環境から取り除かれる。無関係な環境変数はそのまま引き継がれる
- `dotenvx` の shim は、一致する鍵ファイルを全て同時に export する。対象には、素の `.env` に対応するサフィックスの無い鍵と、`.env.<環境名>` に対応するサフィックス付きの鍵の両方が含まれる。一致が0件なら素通し、一致した中に1つでも空ファイルがあれば非ゼロ終了する（テスト: "dotenvx: DOTENV_PRIVATE_KEY (無サフィックス) 単独 -> 注入される" / "dotenvx: DOTENV_PRIVATE_KEY (無サフィックス) が空単独 -> 非ゼロ終了、当該パスが出て実体は呼ばれない"）
- `dotenvx` の shim は、prod 鍵が注入された状態で実行を伴い厳格モードを伴わない呼び出しのときだけ警告を出す。判定は環境ではなく prod 鍵ファイルの観測で行う
- その警告は動作を変えない。警告の有無にかかわらず実体が受け取る引数列は完全に同一で、実体の終了コードがそのまま返る。厳格モードを強制せず警告に留めるのは、正当な重ね掛けを壊さないためである
- 警告文に、受け取った側で解決できない記号は出さない（テスト: "dotenvx: 警告文に設計書内でしか通じない記号が出ない"）
- 先頭に `_` を付けた呼び名で起動すると、注入は同じに行われたうえで実体の解決が PATH に委ねられる。プロジェクトローカルのバイナリがあればそれが注入付きで呼ばれ、無ければ退避された実体に到達する（無限再帰しない）
- `_` 付きの呼び名でも三値の意味論は変わらない（テスト: "_wrangler: 空 secret は非ゼロ終了 (三値意味論を維持)"）

### 9. `images/runtime-base/tests/karakuri-context.test.sh` — `images/runtime-base/bin/karakuri-context`

起源: `0008-ledger-prod-entry`

- 非対話シェルから読み込んだとき、stdout にも stderr にも一切出力せず 0 で戻る
- 対話シェルから読み込んだとき、secret の置き場にあるファイルの名前が出力される。**値は出力のどこにも現れない**（テスト: "対話相当 (bash -i) で値 (目印文字列) は出ない"）
- secret の置き場が空、またはディレクトリごと不在のとき、鍵が無い旨の専用の1行が出る
- 置き場が存在して中身ゼロのときでも glob の展開エラーを出さず、途中終了もせず、後続の出力まで到達する
- 解決結果の記録が読めるとき、その内容が出力される。可変 ref であった場合は同じ行に注記が付く
- 記録が無いときは何も言わない。「見つからない」という行すら出ない。secret の置き場については逆に「無い」と明示する——この非対称は意図的である
- 対話シェルの起動ごとに、実行可能な認証確認コマンドが置かれていれば一度呼ばれ、その出力は対話シェルに見える
- 実行可能ビットが落ちている認証確認コマンドは呼ばれない（テスト: "否定対照: 実行可能でなければ git-auth-check は呼ばれない"）
- 認証確認コマンドが非ゼロで終わっても、その失敗は外へ漏れず、読み込みは成功扱いで本来の出力も欠けない（テスト: "git-auth-check が非ゼロで終わってもシェルと本来の出力を壊さない"）
- エラーで停止する設定のシェルから壊れた状態で読み込んでも、呼び出し元シェルを落とさず後続コマンドまで到達する（テスト: "set -e なシェルで source してもシェルを壊さず後続コマンドまで到達する"）

### 10. `images/runtime-base/tests/git-credential.test.sh` — `images/runtime-base/bin/{git-credential-gh-token,git-auth-check}`

起源: `0009-ledger-auth-and-shipped`

- イメージは github.com 向けの資格情報ヘルパを「空値で打ち消してから絶対パスで積み直す」構成で環境変数に固定し、その絶対パスに対応する実体がリポジトリの `bin` にある。イメージ側への配置そのものは `C-2b` が持つ
- 利用者側の設定に別のヘルパが書かれ、かつ環境に敵対的な問い合わせプログラムがいる状況でも、github.com の認証はイメージ自前のヘルパだけで確定し、他のヘルパも問い合わせプログラムも一度も起動しない
- 認証成功後の保存要求は自前のヘルパにだけ配られ、利用者側に書かれたヘルパへは配られない。トークンがホスト側の資格情報ストアへ書き戻らない
- 認証要求にユーザ名が含まれていても、自前のヘルパが返すユーザ名が採用される
- 打ち消しの範囲は github.com のみで、他のホストでは利用者が設定したヘルパがそのまま生き残る
- リポジトリ側の設定に後から仕込まれたヘルパにも打ち消しが及び、そのヘルパは呼ばれない（テスト: ".git/config に仕込まれた helper も呼ばれない"）
- **打ち消しをシステム全体の設定に書いた場合は利用者側の設定に負ける。** 環境変数でなければこの守りが成立しないことを、あえて「守れない」側の事実として固定している。ここが赤くなったら環境変数による固定をやめられる合図になる
- トークンが読める場合、ヘルパは固定のユーザ名とトークンを 0 で返し、stderr には一切出力しない（テスト: "トークンあり: stderr に何も出さない (値が漏れない)"）
- トークンが不在・空・読めないのいずれでも、空のトークンを返さず、以降のヘルパと問い合わせプログラムへの連鎖を止める指示を返して 0 で終わる。非ゼロで終わると git が次のヘルパへ黙って落ち、敵対的な問い合わせプログラムで認証が「成功」してしまうため、あえて成功終了する（テスト: "トークンが読めない (mode 000): 空の password ではなく quit=1"）
- 保存・消去・引数なしのときは何も出力せず 0 で終わる。書き戻し先として振る舞わない
- トークンが無い状態では git の認証は失敗として終わり、敵対的な問い合わせプログラムは呼ばれず、ホスト側の資格情報が出力に現れない（テスト: "トークンが無ければ git は失敗し、敵対的な askpass は呼ばれない"）
- 認証確認コマンドは、実効ヘルパが自前のものと一致していても黙らず、常に1行を報告して 0 で終わる。報告には実効ヘルパのパスが入り、ヘルパが一本も無ければ問い合わせプログラムへ落ちる旨がその位置に入る。一致・別物・不在のいずれでも 0 で終わり、シェルの起動を止めない（テスト: "否定対照: 一致していても出力が空にならない" / "実効 helper が空でも rc=0 で1行報告する"）
- 同じ1行に、イメージが環境変数で置いたヘルパ固定が生きているかも入る。固定は利用者が同じ仕組みで自分の設定を足すと黙って消え、そのとき認証はホスト側の資格情報で成功してしまい失敗として現れないため、実効ヘルパとは独立に報告する（テスト: "イメージ固定が外れていれば報告にその別が付く (実効 helper が別物でも空でも)"）
- 認証確認コマンドの報告文に、受け取った側で解決できない記号は出さない
- 認証確認コマンドの報告文に、トークンの値そのものは現れない。報告に載るのは実効ヘルパのパスとイメージ固定の生死だけである（テスト: "報告に注入した値が出ない"）

### 11. `images/runtime-base/tests/shipped-symbols.test.sh` — 出荷物の記号検査

起源: `0009-ledger-auth-and-shipped`

- 出荷物のどこにも、このリポジトリの外では参照先の無い記号が残らない
- 禁止の強さは受け取った側が参照先に到達できるかで二段に分かれる。他リポジトリ・他組織へ丸ごと渡るもの（テンプレート一式と、パッケージとして配る README）と、このリポジトリに留まる文書は、コメントか本文かを問わず記号そのものを持たない
- 記号を伴ってよいのは、同じ行に git 管理下の文書へのパスが書かれている場合だけである。禁じているのは記号ではなく「到達できない参照」であるため（テスト: "否定対照: git 管理下の文書への参照は strict でも通る"）
- ただし他リポジトリ・他組織へ渡るものは、このリポジトリにしか存在しない設計文書へのパス自体も持てない。記号を消してパス参照へ書き換える逃げ道を塞いである（テスト: "否定対照: templates 向けの検査が設計文書へのパスを検知する"）
- イメージへ焼き込まれるコードは、パスを伴わない裸の記号を持たない
- 検査対象のディレクトリが移動・改名・空になった場合、検査は 0 を返さず即座に致命終了する。1件も走査しないまま通ることが無い
- 検査自身に検知能力があることを、既知の違反を毎回その場で作って確かめる（テスト: "否定対照: strict が既知の違反 (記号入りコメント) を検知する"）
- この検査の対象範囲には、配布されるテンプレート一式・パッケージの README・このリポジトリに留まる README と移行手順・イメージへ焼き込まれるコードが含まれる。文書の内容の正しさは約束しない——約束するのは記号の不在だけである

### 12. `images/runtime-base/tests/template-sync.test.sh` — 配布テンプレートと利用例の同期

起源: `0009-ledger-auth-and-shipped`

- 配布テンプレートの compose と利用例の compose は、イメージ指定の行を除く全行が完全に一致する（テスト: "image 行を除く全行が一致する"）
- 二枚が別ファイルとして存在すること自体は意図的であり、統合はしない。読むためのものと、コピーされて実行時に読まれるものという役割の違いを保ったまま、中身の乖離だけを禁じる
- テンプレートのイメージ指定は実在する digest を持たず、プレースホルダのままである。実 digest を焼くと利用者の差し替え忘れが「起動はするが古いイメージ」として静かに通るため、取得の失敗として顕在化させる（テスト: "テンプレートの image はプレースホルダのまま"）
- 利用例のイメージ指定は逆に、解決済みの digest を持つ。読んだ人がそのまま写して起動できる形になっている
- どちらかのファイルが存在しなければ、検査は 0 を返さず失敗として終わる
- 一致検査に検知能力があることを、テンプレート本文に1行足した版をその場で作って毎回確かめる

### 13. `images/runtime-base/templates/tests/karakuri.test.sh` — `images/runtime-base/templates/host/karakuri.sh`

起源: `0010-ledger-host-entry`

- prod 系の3コマンドは同じリポジトリ解決を共有し（`karakuri-prod-run` で確認）、リポジトリを1引数で受け、組織名付きの指定からも、既定の組織名で補った裸の指定からもクローン URL を組み立てる。組織名が未設定で補えないときと、区切りを2つ以上含む指定のときは、下位スクリプトを一度も起動せずに非ゼロで終わり、前者のエラーは補うべき環境変数を名指しする
- 2番目の引数はそのまま ref として渡る
- prod 系の3コマンドはいずれも compose プロジェクト名を `prod-<repo>` として渡す
- 既定では導入コマンドとタスクをシェル経由の1文字列として連結し、タスク引数は引用符で包む。導入コマンドに空文字を設定したときだけシェルを経由せず、各語が独立した引数として渡り、空白を含む引数は1引数のまま保たれる
- 任意コマンドの実行は、既定の導入コマンドが設定されていてもシェルを経由せず、区切りを含めて逐語で渡す
- broker の呼び出しは2つの関数に閉じており、利用者が同名の関数を再定義すると、そちらが下位スクリプトへ渡る環境と broker のパスを決め、既定の broker 固有の環境変数は一切渡らなくなる
- 既定の broker 項目名は命名規約に従って組み立てられ、prod と dev で異なる並びを持つ。broker の実体を差し替える環境変数は、設定したときだけ下位へ渡る
- dev 注入は、プロジェクト名を**加工せずそのまま**下位へ渡す。broker の項目キーは明示指定があればそれ、無ければプロジェクト名を使う
- dev 注入は、プロジェクト名や項目キーに区切りを含む値、共通名を項目キーにする指定、位置引数だけの呼び出し、必須オプションの欠落、値の欠落、未知のオプションを、いずれも下位スクリプトを起動する前に非ゼロで拒否する
- コンテナへの入室は、起動確認 → secret の注入確認 →（未注入のときだけ注入）→ port forwarding → 対話シェル、の順に下位コマンドを呼ぶ。secret が注入済みのときは注入が走らない
- `up` を付けた入室は port forwarding まで済ませたところで止まり、対話シェルを開かない
- ssh のホスト名は、明示指定があればそれ、無ければプロジェクト名を**そのまま**使う。サフィックスを剥がさない（テスト: "[$s] the ssh host keeps the full -p value ('myproj-dev'), not a stripped 'myproj'"）
- ssh の実効設定に転送の指定が無ければ転送を張りに行かず、その旨を stderr に出したうえで成功として対話シェルを開く
- 転送の失敗は `up` を付けたときだけ致命的で、`up` 無しでは警告に留める。「転送が張れないこと」と「作業を始められること」を分けた判断である
- port forwarding は渡された名前を逐語で ssh に渡し、接頭辞を足さない。既存の master を落としてから新しいセッションを張る
- 残っている control socket のファイルは**削除しない**（ssh 実装が stale な socket を自分で片付けるため）（テスト: "[$s] karakuri-port-forward leaves the control socket alone"）
- 転送の stderr はホストごとのログファイルへ追記され、成功時は stdout にも stderr にも何も出ない。失敗時だけログの末尾が stderr に出る。2回目の失敗は上書きではなく追記になる
- macOS のときだけ loopback 別名の事前検査が走る。転送の bind アドレスが loopback 帯にあるのに別名が張られていなければ、そのアドレスと張るためのコマンドを示して失敗する。別のアドレスは代わりにならない
- この検査は master を落とすより前に走り、失敗したときは ssh を一度も起動せず、既存の control socket もそのまま残る（テスト: "[$s] neither 'ssh -fN' nor 'ssh -O exit' runs when the check fails"）
- 検査は通らないときに黙って通す側へ倒す。実効設定が取れないとき、転送の指定が無いとき、bind 側が照合の対象外のときは、何も言わずに転送を張る。検査は説明を良くするためのものであり、転送の可否を決める権限を持たない
- loopback の設定コマンドは引数を個数も内容も検査せずそのまま下位スクリプトへ素通しし、broker や compose の環境変数を一切足さない
- prod シェルは compose のラベルでコンテナを引き、compose ファイルを読まない。ref や compose の指定がすべて未設定でも成功する
- 一致が0件でも複数件でも実行に進まずに失敗する。1件のときだけ対話シェルを開く。区切りを含むリポジトリ名は拒否する（テスト: "[$s] prod-shell fails when no container matches"）
- compose ファイルはディレクトリ指定から2つの拡張子で探し、ディレクトリ指定が単一ファイル指定に勝つ。両方の拡張子が存在するときも、どちらも無いときも、探したパスを名指しして下位スクリプトを起動せずに止める（テスト: "[$s] a repository with both .yaml and .yml fails"）
- digest の解決は compose ファイルを書き換えず、解決した結果を1行 stdout に出すだけである。行末のコメントは digest の一部として読まれず、コメント行の指定も拾わない（テスト: "[$s] image-digest leaves the compose file untouched"）
- ディレクトリ内のファイルがイメージ名で食い違っているときは、食い違うファイルを名指しして止め、レジストリへの問い合わせを行わない（テスト: "[$s] no registry lookup happens while the image name is ambiguous"）
- digest の検査は全ファイルを名前順に掃引し、**最初の問題で打ち切らない**。打ち切ると後ろのファイルの貼り忘れが永久に見えないためである。一致・不一致・未挿入をそれぞれ区別して報告する
- ヘルプは下位スクリプトを一切呼ばず、公開している関数の名前と環境変数の現在値を出す。「未設定」と「空文字を設定」を区別して見せ、**broker の項目名は決して出さない**
- 以上のすべてが bash で成り立ち、zsh が入っている環境では zsh でも同一に成り立つ（zsh が無い環境では zsh 側の検査が skip される）
- `karakuri-run` は broker の項目キーの明示指定を必須とし、省略・区切りを含む値・共通名を項目キーにする指定・終端子より前の位置引数を、いずれも供給層を一度も起動せずに非ゼロで拒否する（テスト: "否定対照: 項目キーの省略は供給層を起動する前に拒否される"）（起源: `0014-host-secret-run`）
- 終端子より後ろは一切解釈されず、逐語でコマンドとして渡る。空白を含む引数は1引数のまま保たれる（起源: `0014-host-secret-run`）
- broker の項目の並びは `-e` で選び、既定は `dev`。`dev` は全プロジェクト共通の個人項目を挟む3項目、`prod` は挟まない2項目で、いずれも既存の dev 注入・prod 起動と同じ並びである。`-e` に `dev` / `prod` 以外を渡すと broker を一度も起動せずに非ゼロで終わる（テスト: "否定対照: 未知の -e は broker を起動する前に拒否される"）（起源: `0014-host-secret-run`）
- broker の差し替え点は既存の2関数のままである。利用者が同名の関数を再定義すると、`karakuri-run` もそちらの結果を使う（起源: `0014-host-secret-run`）
- 共通名を項目キーにする指定は `-e` の値によらず拒否される（起源: `0014-host-secret-run`）
- source すると shim のディレクトリが PATH の**末尾**へ加わる。既存の PATH の先頭は変わらず、何度 source しても重複しない（テスト: "何度 source しても shim のディレクトリが PATH に重複しない"）（起源: `0014-host-secret-run`）
- 下位スクリプトが見つかったのに実行できない場合、置き場所ではなく mode を問題として報告し、対象のパスと直すコマンドを示す。実行できないものを解決結果として返して呼び出し側を落とすことはなく、この振る舞いは bash と zsh で変わらない（テスト: "the error does not blame the placement when the file was found"）（起源: `0014a-host-template-file-modes`）

### 14. `images/runtime-base/templates/tests/dock.test.sh` — `images/runtime-base/templates/host/dock.sh`

起源: `0010-ledger-host-entry`

- compose プロジェクトの指定が無ければ、モードに依らずコンテナ探索を一切行わずに非ゼロ終了し、欠けているオプションを名指しする（`--secrets-ok` と引数なしの呼び出しで確認）
- コンテナは compose のプロジェクトラベルとサービスラベル（既定は dev）の二つで引く。0件と2件以上はそれぞれの理由を述べて非ゼロ終了し、どちらも起動状態の問い合わせへ進まない（テスト: "more than one matching container fails"）
- モードを指定するオプションを2つ同時に渡すと、コンテナ探索より前に非ゼロ終了し、衝突した両方の名前を出す
- secret の確認モードは、注入済みで 0、未注入で 1 を返し、いずれの場合も stdout と stderr を完全に空に保つ。判定に使う下位コマンド自身の出力も外へ漏らさない。結果は終了コードだけで伝える契約である
- secret の確認モードはコンテナの起動状態を変えない。停止中のコンテナに対しては起動もせず 1 を返す。secret の置き場は再起動をまたいで残らないため、停止していれば未注入が確定する（テスト: "--secrets-ok exits 1 when the container is not running (secrets cannot survive a stop)"）
- 起動確認モードは、停止中なら起動して 0、起動済みなら起動せずに 0 を返す。どちらも stdout は空である
- 標準入出力モードは secret 未注入のとき 1 で止まり、stdout に1バイトも出さず、sshd を起動しない。stderr の案内には、ホスト側で打つべきコマンドと broker のキーを別引数として示す（テスト: "--stdio does not exec sshd-inetd when secrets are missing"）
- 標準入出力モードは secret 注入済みのとき、絶対パスで sshd を起動する。フォールバック先の候補は持たない。見つからなければ明示的に失敗する方が、別の sshd が起動して原因の遠いエラーになるより良いという判断である
- 標準入出力モードは停止中のコンテナを secret 判定の前に起動し、その起動が出す stdout を外へ漏らさない。標準出力が接続そのものであり、1バイトでも混ざると壊れるため（テスト: "--stdio does not leak the 'docker start' stdout of a stopped container"）
- secret 判定を行う下位コマンドは、Windows 経路のための環境変数を受け取る
- 既定モードは対話シェルを開き、作業ディレクトリの指定があるときだけそれを下位へ渡す。省略時は付けず、コンテナ側の設定に従う
- 引数なし・未知のオプションは非ゼロ終了し、stdout は空で、使い方を stderr に出す
- 素の位置引数は、未知のオプションとは区別した文言で、コンテナ探索の前に非ゼロ終了する
- ヘルプは 0 で終わり、使い方を stderr に出して stdout は空に保つ。コンテナ探索は行わない。全モードで stdout を汚さない規律の一部である

### 15. `images/runtime-base/templates/tests/dev-inject.test.sh` — `images/runtime-base/templates/host/dev-inject.sh`

起源: `0011-ledger-host-inject`

- 位置引数を1つでも渡すと非ゼロ終了し、使い方を出し、docker を一度も呼ばない。secret の搬送路にオプション解釈を持たせない（打ち間違いが別の動作にならないようにする）ための拒否である
- 必須の環境変数が欠けていれば非ゼロ終了し、欠けている変数名を名指しして使い方を出す
- 注入先は compose のプロジェクトとサービスで引く。サービスの既定は dev で、環境変数で差し替えられる
- 一致が0件のときと複数のときは、それぞれの理由を述べて非ゼロ終了し、実行に進まない（テスト: "docker exec is not invoked when the target is ambiguous"）
- 成功時は取込コマンドをコンテナ内で実行し、0 で終わる
- broker の stdout は、取込コマンドの stdin へ末尾改行を除きバイト単位でそのまま中継される（テスト: "fake docker exec's stdin matches the broker's output verbatim"）
- 実行は Windows 経路のための環境変数を受け取る
- broker が失敗すれば、下位が 0 で終わっても全体は非ゼロで終わり、broker を失敗段として名指しする（テスト: "dev-inject exits non-zero when broker fails, even though the fake docker exits 0"）
- 両方が失敗したとき、broker の終了コードが SIGPIPE 相当でなければ broker のものを、SIGPIPE 相当なら下位のものを返す。SIGPIPE は「下位が先に死んで stdin を閉じた」結果であって原因ではないため、症状としてのみ報告する（テスト: "exit code is docker's (5), not broker's SIGPIPE (141)"）
- 両方が失敗したときのエラーには両方の終了コードが現れる。どちらが真因か機械的に決められないことを、片方を選ばずに開示する

### 16. `images/runtime-base/templates/tests/prod-run.test.sh` — `images/runtime-base/templates/host/prod-run.sh`

起源: `0011-ledger-host-inject`

- 必須の環境変数が欠けていれば非ゼロ終了し、欠けている変数名を名指しする
- 引数なしで実行すると非ゼロ終了し、使い方を出す
- 成功時は compose 経由で使い捨てのコンテナを起動し、0 で終わる。端末割り当てを無効にする指定は必ず付く
- 渡した引数は語分割されずに1引数のまま下位へ届く
- broker の stdout は下位の stdin へ末尾改行を除きバイト単位でそのまま中継される（テスト: "fake docker's stdin matches the broker's output verbatim"）
- 実行は Windows 経路のための環境変数を受け取る
- broker と下位の終了コードの扱いは `§15` と同一である（broker 単独失敗で全体が非ゼロ、SIGPIPE は症状として扱い、両方失敗なら両方の値を出す）
- ref が40桁 hex でないとき、既定では docker を一度も起動せずに非ゼロ終了し、脱出口の環境変数を名指しする。権威は起動経路側にあるが、迂回されても閉じた側に倒れる形での早期フィードバックとして二重に検査している（テスト: "docker was not invoked when GIT_REF was rejected before launch"）
- 脱出口を明示したときは、同じ ref でも警告を出したうえで実行を続け、成功時は 0 を返す

### 17. `images/runtime-base/templates/tests/broker-bitwarden.test.sh` — `images/runtime-base/templates/host/broker-bitwarden.sh`

起源: `0011-ledger-host-inject`

- 項目名の環境変数が未設定なら非ゼロ終了し、その変数名を名指しする
- 単一項目のとき、stdout は当該項目の内容と完全に一致し、それ以外は何も混ざらない
- 解錠で得たセッション鍵は stdout に一切現れない（テスト: "stdout に stub-session-token が現れない"）
- 取得の直前に同期をセッション付きで1回だけ呼ぶ。複数項目でも1回で、必ず取得より前に呼ばれる。同期の stdout は捨てられ、出力に混ざらない
- 同期が失敗しても取得は続行し 0 を返す。ただし警告を必ず stderr に出す。ネットワークの無い場所で作業を止めないための選択だが、古いキャッシュへ黙って落ちないよう警告は欠かせない（テスト: "sync 失敗でも取得は成功する"）
- 同期を無効にする環境変数を設定すると同期を呼ばず、取得はそのまま成功する
- 区切りで複数項目を渡すと、指定した並び順のまま連結して出力する。項目の内容に末尾改行が無くても項目間に改行の境界が入る
- 複数項目でも施錠は1回で、取得だけが項目数ぶん呼ばれる
- 取得・同期・施錠の各呼び出しはセッションを環境で受け取る。セッション鍵をシェルへ常駐させる運用には依らない
- 存在しない項目が1つでもあれば全体を非ゼロ終了させ、その項目名を名指しする。部分的な鍵束のまま先へ進まない。欠けた鍵は下流の認証失敗として遅れて出るだけなので、原因を名指しできる場所で止める
- 取得が失敗した場合でも終了時に施錠が呼ばれる（テスト: "失敗時も lock が呼ばれる"）
- 項目は存在するが内容が空のとき、非ゼロ終了しその項目名を名指しする。取込側に届ける前にここで落とす
- 項目名の指定に空の名前が含まれるとき、分割後ではなく分割前の文字列の段階で検出して非ゼロ終了する。末尾の区切りのような打ち損じが黙って無視される経路を塞ぐ
- 下位コマンドの実体は環境変数で差し替えられる

### 18. `images/runtime-base/templates/tests/loopback-setup.test.sh` — `images/runtime-base/templates/host/loopback-setup.sh`

起源: `0011-ledger-host-inject`

- macOS 以外では、どのサブコマンドでも stdout は空、stderr に macOS 専用である旨を出し、0 で終わる。特権操作を一切試みず、ホストの設定ファイルも別名の設定ファイルも変えない（テスト: "non-macOS(Linux) 'install': no privileged operation was attempted"）
- 導入は2回打っても両方 0 で終わり、置かれるファイルの集合も設定ファイルの中身も1バイト違わない。2回目は既存の設定ファイルを残したことを告げ、設定ファイルに並んでいるアドレスはその場で張り直す
- 置かれた daemon は 0755、plist は 0644 で、いずれも配布物とバイト単位で一致する（中身に手を加えない）
- 隣に配布物が無いとき、導入は非ゼロで終わり、見つからなかったファイルを名指しし、特権操作を1つも行わず何も作らない（テスト: "missing payload: no privileged operation was attempted"）
- 導入は配置の前に、配布物の daemon が読む設定ファイルのパスと自分の書き込み先、配布物の plist が起動するプログラムのパスと自分の配置先を突き合わせる。食い違えば非ゼロで終わり、食い違う両方のパスを並べ、特権操作を1つも行わない（テスト: "install payload: nothing is placed when the daemon disagrees"）
- まだ読み込まれていない段階での解除の失敗は握って読み込みへ進み、0 で終わる。読み込み自体が失敗した場合は逆に、止まらず最後まで進んで daemon と plist を置き、設定ファイルの全アドレスを張り切ったうえで**非ゼロを返す**。途中で止めると別名が張られないまま終わり、成功にすると「再起動で消えた」に逆戻りするため、両方を避ける（テスト: "install bootstrap: a failing bootstrap does make install exit non-zero"）
- 追加は設定ファイルへアドレスだけを1行追記し、ホストの設定ファイルの管理ブロック内にアドレスと全ホスト名を1行で置き、別名を張る。同じ引数で2回打っても重複せず、既に在ることを報告する。同じアドレスへの2つ目の名前は既存行へマージされる
- 既に別のアドレスに載っている名前を移そうとすると非ゼロで終わり、現在の持ち主を名指しする。**この拒否は特権操作より前に起きる**ので、別名だけ張られた中途半端な状態が残らない（テスト: "add name collision: refused name move: no privileged operation was attempted"）
- 受け付けないアドレスとホスト名（管理対象外の帯、予約名、アドレスの形をした名前、長さ超過）は非ゼロで終わり、特権操作を1つも行わず、ファイルを1バイトも変えない。管理対象外の帯・予約名・アドレスの形をした名前については、何が誤りかを述べる
- 導入より前の追加は非ゼロで終わり、導入を先に実行するよう促し、特権操作を1つも行わない
- 末尾改行の無い設定ファイルへ追記しても、追記されたアドレスは独立した1行になり、直前の行は原文のまま残る
- アドレス指定の削除は、設定ファイルの行・管理ブロックの行・別名の3つを消し、他のアドレスはそのまま残す
- ホスト名指定の削除はその名前だけをブロックの行から落とす。行に他の名前が残れば行は残り、最後の名前が消えたときだけアドレス行ごと消える。**設定ファイルの行と別名は消さない**——同じアドレスを使っている見えない利用者を切らないためで、消し忘れる側へ倒している
- 存在しない対象の削除は、アドレス指定でもホスト名指定でも 0 で終わり、両ファイルをバイト単位で変えない。「消えているのが望んだ結果」なので失敗にしない（テスト: "removing an unknown address leaves both files byte-identical"）
- ホストの設定ファイルが読めないときは、どちらの削除も同じ非ゼロ・同じ理由で止まる。アドレス指定でも設定ファイルの行は残り、特権操作は1つも走らない
- 追加でも削除でも、管理マーカーの外側の行は追加・削除・順序変更のいずれも起きない。管理ブロックがまだ無いファイルへの新設でも同じで、既存の最終行とマーカーが1行に繋がらない（テスト: "add-no-block: every line outside the markers survives unchanged and in order"）
- マーカーの対応が壊れている場合、追加は非ゼロで終わり、触ることを拒む旨を述べ、ファイルをバイト単位で残し、特権操作を行わず、**バックアップも書かない**（何も変えようとしていないので退避を上書きしない）（テスト: "two-pairs: no backup is written either (nothing was about to change)"）
- マーカーの探索そのものが失敗した場合は「見つからなかった」と区別され、非ゼロで終わる。ファイルはバイト単位のまま変わらず、2つ目の管理ブロックが足されることはない（テスト: "marker search: no second managed block is appended"）
- ホストの設定ファイルの中身は1回の実行で1度しか読まれない。数え終えた直後に別プロセスが先頭へ行を差し込んでも、表示される管理ブロックの中身はずれず、ブロック外の行が混入しない（テスト: "hosts snapshot: no line from outside the block is pulled in"）
- 書き換え前に、書き換え直前の内容とバイト単位で一致するバックアップが所有者と権限を明示して作られ、その場所が出力で知らされる。設定ファイルも同様に退避され、利用者が手で書いたコメント行は書き換え後も残る（テスト: "the backup holds the pre-rewrite content, byte for byte"）
- 差し替えは同一ディレクトリへ staging してから rename で被せる形で行う。**その場での上書きコピーは行わない**。成功後に staging したファイルは残らない（テスト: "hosts rename: nothing copies over <hosts> in place"）
- rename が失敗した場合、非ゼロで終わり、対象ファイルは元の内容のまま完全に残り、置きかけのファイルは片付けられる（テスト: "hosts rename: the trap removes the staged file when the rename fails"）
- 読み取りから書き戻しまでの間に対象ファイルが他の書き手に変更された場合、非ゼロで終わり、何が起きたかと打ち直しの指示を出す。相手の書いた行はそのまま残り、バックアップも staging したファイルも残らない。設定ファイル側でも同じで、中止した追加は1バイトも書かない（テスト: "hosts race: the other writer's line is still there"）
- 管理ブロック内に利用者が置いたコメント行は、追加と削除のどちらを通っても原文のまま残る
- 特権の求めを待っている最中の端末切断（HUP）も、INT / TERM と同じ片付けの対象として捕捉する（テスト: "cleanup: HUP is trapped alongside INT and TERM"。固定しているのは捕捉していることまで）
- 一覧は引数を取らず、余分な引数は黙って無視せず非ゼロで終わる。管理対象外のアドレスについては実行できない指示を出さず、管理対象でない旨を述べる
- daemon は設定ファイルの各アドレスにつき別名の設定をちょうど1回ずつ呼ぶ。空行・コメント行・行末の覚え書き・末尾改行の無い最終行を正しく扱い、余分な呼び出しを出さない
- daemon は管理対象外の帯のアドレスを一切渡さず、飛ばしたアドレスを名指しする。常に存在するアドレスも名指しで飛ばし、理由を述べる。いずれの場合も 0 で終わる
- daemon は1つが失敗しても残りを処理し続け、失敗したアドレスを名指ししたうえで 0 で終わる。設定ファイルが存在しないときは何も呼ばず、1バイトも出さずに 0 で終わる。起動のたびのエラー行を読み飛ばす習慣を作らないための沈黙である

### 19. `images/runtime-base/templates/tests/host-run.test.sh` — `images/runtime-base/templates/host/host-run.sh`

起源: `0014-host-secret-run`

- 供給層は broker を1回だけ呼び、呼び出しの前に environ にあった dotenvx の私鍵変数を、名前が衝突しないものも含めてすべて削除する。子プロセスへ渡る私鍵は broker が返したものだけである（テスト: "否定対照: サフィックスが衝突しない既存の私鍵は子プロセスへ届かない"）
- broker のパスが未設定・broker が非ゼロ終了・broker の出力が空・実行するコマンドが未指定のいずれでも、コマンドを一度も起動せずに非ゼロで終わる（テスト: "否定対照: broker が非ゼロで終わるとコマンドを一度も起動しない"）
- 取り込めない行があったときは、その行の内容を出力へ一切反射させず、行番号だけを報告して非ゼロで終わる（テスト: "通し: 取り込めない行は行番号だけが報告され、内容は出ない"）
- 引数はシェルを経由せず逐語で渡り、空白を含む引数は1引数のまま保たれる

### 20. `images/runtime-base/templates/tests/host-shim.test.sh` — `images/runtime-base/templates/host/shims/_dotenvx`

起源: `0014-host-secret-run`

Windows 用のラッパーの検査だけは cmd.exe を要するため、この出典ファイルではなく `.github/workflows/ci.yml` の Windows ジョブが持つ。

- shim は私鍵変数が environ にあるときだけ実体を起動する。無いときは実体を一度も起動せずに非ゼロで終わり、鍵の無い実行が成功として素通りすることがない（テスト: "否定対照: 鍵が無いときは実体を起動しない"）
- shim は鍵の出どころを問わない。供給層を経ずに環境変数で鍵を渡した実行も通る（CI がこの形で通る）（テスト: "通し: 環境変数だけで渡した鍵でも実体が起動する"）
- shim が起動する実体は PATH 解決で選ばれる。プロジェクトが自前で用意した版がある環境では、その版が鍵付きで動く
- 鍵の値は stdout にも stderr にも現れない（テスト: "通し: 鍵の値が出力に出ていない"）
- Windows 用のラッパーは、同じ判定を同じ終了コードで返す。鍵が無いときに 0 を返さない（テスト: "否定対照: 鍵が無いとき cmd ラッパーが非ゼロを返す"。cmd.exe から実行する Windows のジョブで検査する）

### 21. `.github/scripts/tests/pin-lag.test.sh` — `.github/scripts/pin-lag.sh`

起源: `0015-pin-refresh-and-monitor-tiers`

- 固定値と上流の最新が同一のとき、`lag` は `none` を返す
- 遅れがあるとき、`lag` はその大きさと種別（`major` / `minor` / `patch`。3桁とも一致するが文字列が異なる場合は `differs`）を返す
- `severity` が返す深刻度は `alert` / `info` の2値のみである（テスト: "severity は alert / info の2値のみを返し、warn を返さない"）
- **遅れの大きさや種別だけでは深刻度が `alert` にならない。** `severity` は advisory の状態だけを見て判定し、`major` の遅れがあっても advisory の影響を受けていなければ `info` に留まる（テスト: "major 5 の遅れ + advisory 該当なし -> それでも info（STATUS を上げない）"）
- 版の文字列が `v` 前置の有無で食い違っていても、`lag` は同一の版として扱う（`v0.19.1` と `0.19.1`）
- **否定対照:** 上流の版を取得できないとき、`lag` は `none` を返して黙らず `latest-unavailable` を返す（テスト: "否定対照: 上流の版が取得できないとき none ではなく latest-unavailable を返す"）
- **否定対照:** 固定値を読み出せないとき（`ARG` の行が消えた・名前が変わった場合を含む）、`lag` は `pinned-unreadable` を返す
- `node-schedule` は `schedule.json` の日付から maintenance 入り・EOL までの残り日数を返す。**残り日数がいくつであっても、`severity` はそれを見ない**（`severity` は `node-schedule` の出力を引数に取らない）
- 固定値が npm の security advisory の影響範囲に入るとき、`advisory` は `checked-alert` を返す。遅れが `patch 1` でも、遅れが `none` でも、advisory があれば `severity` は `alert` になる
- **否定対照:** advisory の照会に失敗したとき、`advisory` は該当なしと同じ `checked-none` を返さず `check-failed` を返す（テスト: "否定対照: advisory 照会の失敗は checked-none に化けず check-failed を返す"）
- `advisory` は深刻度とは別に照会の可否を返す。照会に乗らない対象（node / crit / golang builder / egress-guard）では、遅れの有無にかかわらず `not-checked` を返す
- **否定対照:** `checked-none`（照会して該当なし）・`not-checked`（照会に乗らない）・`check-failed`（照会に失敗）・`checked-alert`（該当あり）は互いに異なる値である（テスト: "否定対照: not-checked / checked-none / check-failed / checked-alert は互いに異なる値"）

### 22. `images/devcontainer-base/tests/git-identity.test.sh` — `images/devcontainer-base/bin/git-identity-setup`

起源: `0018-git-identity-derive`

- トークンからアカウント情報を取得できるとき、コンテナ内の git の author 名と author メール
  アドレスが、そのアカウントの表示名（未設定ならログイン名）と、公開設定に依存しない転送用
  アドレスになる（テスト: "アカウント情報から name と noreply email が設定される" /
  "表示名が未設定のときはログイン名へ落ちる" / "表示名の \ がそのまま author 名になる"）
- 設定されるメールアドレスにアカウントの登録メールアドレスは使われない。取得したアカウント情報に
  登録アドレスが含まれていても、それが author メールアドレスとして現れることはない
  （テスト: "登録メールアドレスは author に現れない"）
- 既に author 名かメールアドレスが設定されており、それがトークンのアカウントから導いた値と
  異なる場合、両方の値を示す警告を出したうえでトークン側の値へ書き換える
  （テスト: "既存の identity と食い違うときは警告して上書きする"）
- トークンが無い、またはアカウント情報を取得できない場合、identity を一切変更せず、理由を
  1 行出して成功として終わる。起動を壊さない（テスト: "取得に失敗しても identity を触らず 0 で終わる" /
  "アカウント情報を取得できない (403 相当) ときも identity を触らず 0 で終わる" /
  "取得が成功しても中身がアカウント情報でないときは identity を触らず 0 で終わる"）
- アカウント情報の取得と、そこから値を組み立てて設定する処理が分かれており、取得を差し替えた
  状態で導出結果を検査できる（テスト: "取得部を差し替えた状態で導出結果が固定される"）

### 23. `images/runtime-base/tests/host-file-modes.test.sh` — 配布テンプレートの file mode

起源: `0014a-host-template-file-modes`

- ホストへ配るテンプレート一式のうち、実行して使うスクリプトは、clone した先でそのまま実行できる。受け取った側が mode を直す手順を要求されることはない
- 逆に、読み込んで使うファイル（source される関数集・compose・plist・Windows 用ラッパー）は実行可能にならない。PATH 上の `shims/` から誤って起動される経路を作らない

## Unverified Promises

### C-2a — `未検証の約束 (テスト困難: CI の runtime-base ワークフローが、push 済みイメージを両アーキで smoke test する)`

起源: `0009-ledger-auth-and-shipped`

- 3つの shim が PATH 解決で当たる位置に置かれ、`command -v` が `/usr/local/bin` 配下を返す
- secret の置き場が不在の状態でも `dotenvx` の shim が素通しで動く
- system の git 設定で `core.hooksPath` が `/usr/local/share/git-hooks` を指す
- `/usr/local/bin/prod-entrypoint.sh` が実行可能である
- `/usr/local/share/git-hooks/pre-commit` が実行可能である

### C-2b — `未検証の約束 (テスト未作成)`

起源: `0009-ledger-auth-and-shipped`

- `init-project-firewall.sh` がイメージの `/usr/local/bin` へ root 所有・755 で複製され、sudoers に無引数での実行が登録されている
- `secrets-ingest.sh`・`git-askpass`・`git-auth-check`・`git-credential-gh-token`・`karakuri-context`・`env-guard-scan` が `/usr/local/bin` へ置かれ、実行可能である（リポジトリ上のパーミッションが 644 のものが含まれ、実行権はイメージのビルド時に初めて付く）

### D-a — `未検証の約束 (テスト未作成)`

起源: `0010-ledger-host-entry`

- 転送の stderr を置くログディレクトリを作れないときは、ログ分離だけを諦めて端末へ出し、転送そのものは失敗させない
- prod 系の2番目の引数は形を検査されない。sha であることをこの層は要求しない（同じ規則を二箇所に持たないための意図的な非検査）

### D-b — `未検証の約束 (テスト未作成)`

起源: `0011-ledger-host-inject`

- `host/broker-macos-keychain.sh` は、項目名を環境変数で受け取り、キーチェーンから取り出した内容を dotenv 形式で stdout に出す。認可の失敗は非ゼロ終了として伝え、取り出した値以外を stdout に混ぜない
- `host/broker-macos-keychain-set.sh` は、標準入力から受け取った内容を指定された項目としてキーチェーンへ保存する。保存した内容を出力に反射しない
- `project/env-guard.conf` は、利用側リポジトリへコピーしたとき配布されるスキャナが受理する形式であり、既定のディレクティブだけを含む
- `project/env-guard.yml` は、利用側リポジトリへコピーしたとき、配布されるスキャナを CI から呼ぶワークフローとして成立する
- `host/broker-bitwarden.sh` は、複数項目のときも解錠を1回だけ呼ぶ。認可の求めが項目数に比例しない
- `host/broker-bitwarden.sh` の施錠自身の失敗は、本来の終了コードを上書きしない
- `host/loopback-setup.sh` の追加と削除は、引数の個数違いを非ゼロで拒否する

### B-a — `未検証の約束 (テスト困難: proxy を実際に起動して通信させる必要があり、Docker と外向きの到達性が要る。0021 の検収で確認する)`

起源: `0020-l7-sidecar-and-branch`

- L7 実現層で `mode` が `audit` のとき、proxy は allowlist に無い宛先も通したうえで、その宛先を名前で記録に残す。`enforce` では従来どおり拒否する。この記録はエージェントのコンテナから読めるが、書き換えられない

### B-b — `未検証の約束 (テスト困難: ホスト上でのイメージのビルドと実機の確認が要る。0021 の検収で確認する)`

起源: `0020-l7-sidecar-and-branch`

- proxy のイメージは非 root（uid 13）で起動し、ACL をビルド時に焼き込むため、実行中のコンテナに ACL を差し替える経路を持たない

## 境界宣言

### 免責

この台帳に載っていない振る舞いは約束ではない。予告なく変わりうる。この台帳は網羅の宣言ではない。

### 公開面の定義

台帳が対象とする面を配布単位で束ね、その下にエントリポイントを列挙する。

**A. `@himorogy/env-guard`（npm パッケージ）**
- `env-guard`（`bin/env-guard.js`）— 導入 CLI
- `env-guard-scan`（`bin/env-guard-scan`）— スキャナ本体
- `hooks/pre-commit` — 配布される commit 前フック

**B. `@himorogy/egress-guard`（npm パッケージ）**
- `scripts/init-project-firewall.sh` — egress firewall の適用 CLI
- `templates/firewall.json` / `firewall.audit.json` / `firewall.example.json` — 利用者がコピーする設定テンプレート
- `templates/proxy/Dockerfile` / `templates/proxy/squid.conf` — L7 sidecar のイメージと設定

**C-1. `runtime-base` イメージへ焼かれたコードの振る舞い**
- `/usr/local/bin/prod-entrypoint.sh`、`secrets-ingest.sh`、`git-askpass`、`git-auth-check`、`git-credential-gh-token`、`karakuri-context`、`env-guard-scan`、`init-project-firewall.sh`
- `/usr/local/bin/wrangler`、`gh`、`dotenvx`（shim）
- `/usr/local/share/git-hooks/pre-commit`

**C-2. `runtime-base` イメージへの配置そのもの**
- 上記の各ファイルが PATH 上に置かれ、実行可能であること
- `core.hooksPath` が `/usr/local/share/git-hooks` を指すこと
- `init-project-firewall.sh` が root 所有 755 で複製され、sudoers に無引数実行が登録されていること

**D. ホストと利用側リポジトリへ配布されるテンプレート**
- `host/karakuri.sh` — シェルへ source する関数集
- `host/dock.sh`、`host/prod-run.sh`、`host/dev-inject.sh`、`host/host-run.sh`
- `host/broker-bitwarden.sh`、`host/broker-macos-keychain.sh`、`host/broker-macos-keychain-set.sh`
- `host/loopback-setup.sh` と `host/loopback/` の daemon・plist
- `host/compose.prod.yaml`
- `host/shims/`（`_dotenvx` と Windows 用ラッパー）
- `project/env-guard.conf`、`project/env-guard.yml`

**E. `devcontainer-base` イメージと `examples/` の雛形3本**
公開面と判定するが、対応するテストを持たず、何を約束にすべきかも定めていない。候補層（`docs/guarantee-candidates/`）へ置く。

### 索引の粒度

出典はテストファイル単位とする。テスト名まで下ろすのは、安全性・不可逆性に関わる行に限る。

### 起源の粒度

裁可済み節と未検証の約束が持つ起源は、行ごとではなくセクション単位で置く。既存のセクションへ行を足すチケットは、その行に個別の起源を付ける。

起源に置くのはチケット id だけで、統合の参照（PR 番号など）は併記しない。統合されたチケットは `tickets/done/` に残るため、`git log --diff-filter=A -- tickets/done/<id>.md` で、そのチケットを done へ移したコミット、すなわち統合の実体まで一意に辿れる。id と別に参照を持つと、統合の後に台帳へ追記する手順が要るが、その手順を持つ工程が無い。
