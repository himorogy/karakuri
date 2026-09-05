---
status: close
type: feat
base: main
targets:
  - docs/guarantees.md
  - images/devcontainer-base/examples/docker-compose.yaml
  - packages/egress-guard/README.md
  - packages/egress-guard/docs/design.md
  - packages/egress-guard/docs/spec.md
  - packages/egress-guard/package.json
  - packages/egress-guard/scripts/init-project-firewall.sh
  - packages/egress-guard/templates/proxy/Dockerfile
  - packages/egress-guard/templates/proxy/squid.conf
  - packages/egress-guard/tests/firewall-rules.test.sh
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# 最終テーブルを実現層で分岐させ、proxy sidecar を配布物として据える

## 内容

egress-guard の egress 制御を、L3（iptables + ipset の IP allowlist）だけの構成から、
L7 forward proxy を既定としつつ L3 も選べる構成へ移す束の 2 枚目。束は 3 枚:

- 0019 スキーマ version 2 と proxy ACL への変換（**先行。マージ済みであること**）
- **0020 最終テーブルの分岐と、sidecar の配布物としての整備**（このチケット）
- 0021 karakuri 自身の L7 への切り替えと、実機での検証

束の共通の前提:

- **実現層の既定は L7。L3 は設定に明示したときだけ選べる。** 既定を安全側に置くのは、L3 に残る
  制限（ワイルドカード不可、アドレスが動くドメインを載せられない）を知らずに踏む経路を作らない
  ため
- **TLS を終端しない。** proxy はクライアントの `CONNECT` を受けてトンネルするだけで、証明書を
  差し替える構成は採らない
- **proxy は明示型。** クライアントは `HTTP_PROXY` / `HTTPS_PROXY` を読んで自分から proxy へ
  つなぐ。透過型は採らない
- **不変条件は 3 枚のどこでも弱めない。** とくに「ポリシーの変更にはイメージの再ビルドが要る」
  という性質は、L7 側でも sidecar のイメージに ACL を焼き込むことで満たす
- **proxy の実装は Squid を前提に書くが、固定ではない。** ACL の出力形式は「1 行 1 ドメインの
  プレーンテキスト」に保ち、実装固有の設定は proxy のテンプレートの中だけに閉じる

このチケットで行うこと。

### 1. 最終テーブルの分岐

`init-project-firewall.sh` の最終 IPv4 テーブルの構成を、実現層で分岐させる。

- **L7 のとき、最終テーブルを「proxy 宛の許可 + DNS の固定 + loopback」まで縮小する。**
  ドメイン由来の ipset は最終テーブルに載せない。名前による許可は proxy 側の ACL が担う
- **L3 のときは現在の構成のまま変えない**
- **`l3` を選んだときは、その実現層に残る制限を適用ログに出す。** 「ワイルドカード（先頭ドット）
  が書けないこと」「アドレスが動くドメインを allowlist に載せられないこと」を、制限を踏む前に
  読める場所に置く
- **分岐は最終テーブルを組み立てる 1 箇所に閉じる。スクリプトは 1 本のままにする。** 共通のまま
  残すもの: 設定のバリデーション、配置検査、panic テーブル、DNS の固定、IPv6 の全拒否、
  遮断先の記録、冪等性、sudo 経由の起動の制限、`--print-allowlist`

`allowCidrs` と `allowHostPorts` は名前ではなくアドレスの指定なので、**L7 でも最終テーブルに
そのまま載せる**。proxy は名前を扱う層であり、この 2 つを代替しない。

**GitHub の meta API から取る IPv4 レンジは、L7 では取得しない。** これは名前ではなくアドレスだが、
`allowCidrs` と違って利用者が書いたものではなく、`profile` に `github` を含めたことの副産物として
allowlist のセットに入る。L7 の最終テーブルにセットの許可が残っている限り、これは **proxy を迂回して
全ポートへ抜ける経路**になり、「proxy 宛の許可・DNS の固定・loopback・`allowCidrs`・`allowHostPorts`
だけが残る」に反する。L7 では GitHub の名前は proxy の ACL 側にあるので、レンジを持つ意味も無い。
**L3 側の取得は 1 行も変えない。** テストは L7 と L3 の対で置く。

### 1b. L7 の audit を proxy 側へ移す

**audit は L7 でも残す。** どこへの通信が要るのかを観測する機能であり、L7 に移った途端に使えなく
なるのでは移行の意味が減る。ただし**実現の場所を iptables から proxy へ移す**。

現在の audit は 2 つの機構でできており、どちらも L7 では成立しない。

- **記録器**は最終テーブルの中のルールで、allowlist を通り抜けた宛先の **IP** を ipset に足す。
  L7 で最終テーブルを縮小すると、エージェントの通信は proxy 宛の許可に当たって終わり、**記録器に
  到達しない**。proxy が拒否した宛先はそもそも iptables を通らないので、これも記録されない。
  加えて記録の単位が IP のままで、**名前でポリシーを書く L7 とは単位が合わない**
- **`mode: audit` は OUTPUT のポリシーを `ACCEPT` にする。** L7 で最終テーブルを縮小したうえで
  OUTPUT が ACCEPT だと、**proxy を迂回した直接接続がすべて通る**。0021 が宣言する「proxy 環境
  変数を無視した直接接続は塞がれる」と正面からぶつかる

**決着は次のとおり。**

1. **L7 では `mode: audit` を proxy の挙動として実現する。** audit の意味は「落とすはずだった
   ものを通し、記録する」であり、L7 でそれを担えるのは proxy である。**proxy を「allowlist に
   無い宛先も通すが、通した事実を名前で記録する」側に倒す。** enforce では従来どおり拒否する
2. **`mode` は iptables 側の分岐に使わない。** L7 では audit でも enforce でも最終テーブルは
   同一で、**OUTPUT を `ACCEPT` にしない**。proxy への到達だけは常に強制され、proxy を迂回した
   直接接続は audit でも塞がれる。これで 0021 の fail-closed の保証と衝突しない
3. **ipset の記録器は L7 では作らない。** 観測面が proxy のログに移るため、維持する意味が無い
4. **proxy のログはエージェントのコンテナから読める。** どこへの通信が要るのかを調べるのは
   devcontainer の中で作業している人間とエージェントなので、ホストへ降りないと読めないのでは
   使われない。**ただし読み取り専用でマウントすること**——書ける状態にすると、侵害されたエージェント
   が自分の通信記録を消せる。名前付きボリュームを proxy 側は読み書き、`dev` 側は `:ro` で渡す
5. **`mode` は ACL と同じくビルド時に焼き込む。** proxy の設定は実行中に差し替えられない
   （「変更には再ビルドが要る」を構成で満たす）ので、audit と enforce の切り替えも再ビルドを経る。
   `mode` を読んで proxy の設定を組み立てるのは、ACL を焼き込むのと同じビルド段

**L3 側の audit は現行のまま 1 行も変えない。** ipset の記録器も OUTPUT の `ACCEPT` も L3 では
そのまま残る。分岐が増えるのは L7 側だけ。

### 2. proxy を配布物として据える

`packages/egress-guard/templates/proxy/` を新設し、sidecar のイメージと設定を置く。
`package.json` の `files` は `templates` を含んでいるので、この配下は npm パッケージに乗る。

- **`Dockerfile`** — PoC の `poc/l7-proxy/Dockerfile.proxy` が雛形。次を引き継ぐ。
  - Docker Official Image のベースを使う。Squid には公式イメージが無いため自前で組む
  - **`USER proxy`（uid 13）で起動する。** root で起動すると Squid が降格を試み、
    `cap_drop: [ALL]` の下では権限が無くて `SIGSEGV` で落ちる
  - **`--no-install-recommends` で周辺ツールを削る**
  - **ベースイメージは浮動タグで参照し、digest では固定しない。** このリポジトリは規制対応で
    ない限り digest 固定をしない方針を採っており、そこに揃える。PoC の Dockerfile のコメントは
    digest 固定を要求しているので、その記述を落とす
  - **ACL と `mode` をイメージのビルド時に焼き込む。** `init-project-firewall.sh` の ACL 出力
    オプション（0019）をビルドの中で呼び、その出力をイメージに入れる。設定を読む段は egress-guard
    が入ったイメージを別のビルド段として使い、そこから成果物だけを持ってくる。**`mode` も同じ段で
    読み、audit と enforce のどちらの設定を焼くかを決める**（1b の 5）
  - **pin する版は、ACL 出力オプションを含む版でなければならない。** 現在 npm に公開されている
    最新は `0.2.0` で、これは 0019 より前の版なので ACL 出力オプションを持たない。`package.json`
    の版を上げ、Dockerfile はその版を pin する。publish そのものはこのチケットの範囲外だが、
    雛形が自分より古い版を指す状態は残さない
- **`squid.conf`** — PoC の `squid.conf` が雛形。**逆引きした名前を ACL の判定に使わない設定を
  必ず入れる**（入れないと、接続先の IP の逆引きが返す名前で allowlist を通過できてしまう）。
  管理インタフェースを拒否し、キャッシュを持たず、私設アドレス宛を先に落とす。
  **`mode` による差は「allowlist に無い宛先を拒否するか、通したうえで記録するか」の 1 点に閉じる**
  ——逆引きの禁止・管理インタフェースの拒否・私設アドレスの遮断は audit でも外さない（audit は
  「どこへの通信が要るか」を調べるための緩和であって、防御全体を外す指定ではない）。

  **この 3 つは判定の並びで「allowlist に無い宛先の拒否」より前に置くこと。** audit で緩めるのは
  その 1 つだけであり、前段は素通りさせない。**audit の実装として「先頭に全許可を足す」書き方を
  すると 3 つとも無効化される**ので、並びを保ったまま 1 箇所だけを変える形にする。
  PoC の設定がこの並びになっているので、そこから崩さない

**PoC の Dockerfile は「ACL をイメージに焼き込まず read-only bind mount する」と書いているが、
本実装ではその判断を採らない。** PoC のクライアントはリポジトリを mount していなかったため
コンテナ境界だけで条件を満たせたが、本物の devcontainer はリポジトリの作業ツリーを書き込み
可能で mount している。ホスト側のパスから mount すると、エージェントが ACL を書き換えられ、
再ビルドを経ずにポリシーが変わる経路ができる。**焼き込みにすることで、変更に再ビルドが要る
という性質が構成そのものから出る。**

### 3. compose の雛形

`images/devcontainer-base/examples/docker-compose.yaml` に `egress-proxy` service の据え方と、
`dev` 側の配線を示す。

- `cap_drop: [ALL]`、`security_opt: no-new-privileges`、`read_only: true`、`user: "13:13"`、
  書き込み先を tmpfs にする。**ホストへポートを公開しない**
- **proxy のログだけは名前付きボリュームに置き、`dev` からも読めるようにする**（1b の 4）。
  proxy 側は読み書き、**`dev` 側は `:ro`**。書ける状態にすると、侵害されたエージェントが自分の
  通信記録を消せる。tmpfs のままだとコンテナをまたいで共有できないので、ログの置き場だけ
  tmpfs から名前付きボリュームへ移す（他の書き込み先は tmpfs のまま）
- `dev` 側の環境変数は compose の `environment:` に置く（利用側が変える前提があるものの置き場）。
  **`HTTP_PROXY` / `HTTPS_PROXY` は大文字と小文字の両方を出す**（`curl` と `apt` は小文字しか
  読まない）。`no_proxy` / `NO_PROXY` に `localhost,127.0.0.1` を入れる（ループバックの内部通信を
  proxy へ回さないため）。`NODE_USE_ENV_PROXY=1` を置く（Node の `fetch` は既定で proxy 環境変数を
  読まない）
- **雛形はコメントで示すだけにせず、実際に動く形で書く。** 雛形が配布物であり、ここが古いまま
  だと利用側は動かない構成をコピーする

### 4. README と規範文書の現在形化

- **ワイルドカード拒否メッセージの後半を、実現層に応じて正しい案内にする。** 現在の文面は
  「audit モードで走らせて ipset を読み、必要なホストを特定しろ」で終わっている。上の 1b の
  とおり、この経路は L7 では機能しない。L7 では proxy のログを読む案内に差し替える
- `packages/egress-guard/README.md` に、実現層の選び方、sidecar の据え方、L3 に残る制限を書く。
  **git を ssh で使っている場合は proxy 環境変数が効かないので、`ProxyCommand` で `CONNECT` に
  載せるか https 経由へ切り替える必要がある**ことを併記する（このリポジトリ自身は https +
  トークンで認証しているため機構は入れない。利用側の案内としてだけ書く）
- `spec.md` §10.1 を「将来拡張」から現在の構成の記述へ書き換える
- `design.md` §2.23 と §2.24 を、決定の記録から実装された構成の記述へ揃える
- **`spec.md` と `README.md` の中で、この変更によって実現層に依存するようになった記述をすべて
  現在形へ直す。** 対象は節番号で数え上げず、**次の 2 本の grep が出す行を尽くす形で確定させる**
  ——記録器と meta 取得のどちらも「無条件に書かれていた振る舞いが、既定層（`l7`）では起きなく
  なる」という同じ形をしており、節を名指しで列挙すると必ず数え落とす。

  ```
  git grep -n "egress-audit-v4" -- packages/egress-guard/docs/spec.md packages/egress-guard/README.md
  git grep -n "meta API"        -- packages/egress-guard/docs/spec.md packages/egress-guard/README.md
  ```

  ヒットした各行について、実現層に依存するなら限定を足し、依存しないならそのまま残す。**受け入れ
  基準（`spec.md` §11）も対象**——記録器を前提にした基準は既定層では成り立たない

### やらないこと

- **karakuri 自身の `.devcontainer/` は 1 ファイルも触らない。** このリポジトリの `firewall.json`
  は version 1（= L3）のままであり、**マージしてもこのリポジトリの通信経路は変わらない。**
  切り替えは 0021
- 実機での検証は行わない。`verify.sh` 相当の判定を本実装へ向ける作業は 0021
- `verification-record.md` と `known-issues.md` は触らない（0021）
- `poc/l7-proxy/` は残す。使い捨ての検証環境であり、役目を終えたあとの処分は別途
- 実装候補を Squid 以外へ替える検討はしない。替えるときに差し替わるのは
  `templates/proxy/` の中だけで済むように置くのがこのチケットの責任範囲

### 実装上の注意

- 出荷される文字列（適用ログ、README、`squid.conf` のコメント）に設計文書の節番号や不変条件の
  記号を書かない。受け取った側に参照先が無い
- `firewall-rules.test.sh` は L3 側の既存の検査をそのまま残したうえで、L7 側の分岐を足す。
  **L7 の検査を足したら、同じ観点の L3 側の対照を必ず置く**

## 保証

### 新たに宣言する保証

- L7 実現層を選んだ設定では、最終 IPv4 テーブルにドメイン由来の allowlist が現れず、proxy 宛の
  許可・DNS の固定・loopback・`allowCidrs`・`allowHostPorts` だけが残る。名前による許可は proxy
  側の ACL が担う（テスト: "the L7 final table carries no domain allowlist" /
  "allowCidrs still reaches the L7 final table"）
- L3 実現層を選んだ設定では、最終 IPv4 テーブルは現在と同一である。加えて適用ログに、その実現層
  に残る制限（先頭ドットのドメインが書けないこと、アドレスが動くドメインを載せられないこと）が
  出る（テスト: "the L3 final table is unchanged" / "choosing L3 reports what it cannot express"）
- `version` が `1` の設定は L3 実現層として扱われ、最終 IPv4 テーブルは実現層を `l3` と明示した
  version 2 の設定と同一になる（テスト: "a version 1 config produces the L3 final table"）

  > **0019 から送られてきた行。** 0019 はこの解釈を実装しているが、当時は実現層を読むのが
  > version 2 の先頭ドット判定だけで、解釈を L7 に変えてもテストが緑のままだった。最終テーブルの
  > 分岐が入るこのチケットで初めて外から観測できるようになる。

- L7 実現層では、`mode` が `audit` でも `enforce` でも最終 IPv4 テーブルは同一であり、OUTPUT の
  方針は `ACCEPT` にならない。ipset の記録器も置かない。proxy への到達は `mode` によらず強制され、
  proxy を迂回した直接接続は audit でも塞がれる（テスト: "the L7 final table is identical in audit
  and enforce" / "L7 audit does not put OUTPUT on ACCEPT" / "the L7 final table has no recorder"）
- L7 実現層で `mode` が `audit` のとき、proxy は allowlist に無い宛先も通したうえで、その宛先を
  名前で記録に残す。`enforce` では従来どおり拒否する。この記録はエージェントのコンテナから読める
  が、書き換えられない（未検証の約束 (テスト困難: proxy を実際に起動して通信させる必要があり、
  Docker と外向きの到達性が要る。0021 の `verify-l7.sh` と検収で確認する)）
- L7 実現層では、`profile` に `github` が含まれていても GitHub の meta API を取得せず、その IPv4
  レンジは allowlist のセットに入らない。名前による許可は proxy 側の ACL が担うため、IP レンジを
  持つ意味が無く、持つと proxy を迂回して全ポートへ抜ける経路になる。L3 実現層では従来どおり
  取得する（テスト: "the L7 layer does not fetch the GitHub meta ranges" /
  "the L3 layer still fetches the GitHub meta ranges"）
- bootstrap テーブル・panic テーブル・IPv6 の全拒否・DNS の固定・冪等性は実現層によって変わらない
  （テスト: "the bootstrap table is identical across realisation layers" /
  "the panic table is identical across realisation layers" /
  "the IPv6 table is identical across realisation layers" /
  "the second L7 run produces an identical IPv4 table" /
  "the second L7 run produces an identical IPv6 table" /
  "the L7 final table accepts the assigned resolver on udp/53" /
  "the L7 final table accepts the assigned resolver on tcp/53" /
  "the L7 final table drops other udp/53" /
  "the L7 final table drops other tcp/53"）
- 台帳の公開面 B に `templates/proxy/Dockerfile` と `templates/proxy/squid.conf` が加わる。
  proxy のイメージは非 root（uid 13）で起動し、ACL をビルド時に焼き込むため、実行中のコンテナに
  ACL を差し替える経路を持たない（未検証の約束 (テスト困難: ホスト上でのイメージのビルドと
  実機の確認が要る。0021 の検収で確認する)）

### 維持する保証

- 台帳 §5 の「適用は『先に閉じ、後で作る』」「テーブルの更新はテーブル単位の入れ替えだけ」
  「allowlist は staging 側に全件を投入し終えてから原子的に差し替える」——分岐を最終テーブルの
  構成 1 箇所に閉じるため、適用の機構そのものは変わらない
- 台帳 §5 の panic テーブルに関する各行、`sshdPort` に関する各行、自己検証に関する各行——いずれも
  実現層の外にあるため変わらない。自己検証について L7 で飛ばすのは「許可先に到達できる」と
  「設定のドメインが allowlist に載っている」の 2 つの検査であり（どちらも proxy 経由でしか
  成立しないため）、台帳が約束しているのは「到達できないはず」の検査の扱いと、全回答が禁止
  レンジのドメインを飛ばす扱いの 2 行なので、どちらも実現層によらず成り立つ
- 台帳 §4 の設定の検証に関する行はすべて維持する。**このチケットは設定の読み取りも検証も変えない**
  ——`mode` の受理範囲は `enforce` と `audit` のまま、実現層との組み合わせを拒否したりもしない
  （1b の決着どおり L7 でも audit を許す）

### 廃止する保証

- 台帳 §5 の「audit モードでは OUTPUT の方針を**あえて許可のまま**にし、拒否を置かず、落ちる
  はずだった宛先を記録する。一方で INPUT は落としたまま、DNS の固定もそのまま、IPv6 も拒否した
  ままにする」——**実現層を問わない書き方になっているが、L7 では成り立たない**（1b のとおり L7 は
  OUTPUT を `ACCEPT` にしない）。行として取り下げ、**L3 に限った約束として宣言し直す**。
  取り下げるのは適用範囲であって振る舞いではない——L3 側の挙動は 1 行も変わらない
- 台帳 §5 の「記録用のセットは期限付きで作られ、破棄されない。実行をまたいで残すのが意図」——
  同じ理由で取り下げ、L3 に限った約束として宣言し直す。L7 では記録器を置かないため
- 台帳 §5 の「最終 IPv4 テーブルの順序は、resolver の許可 → 53 の記録 → 53 の遮断 → 確立済み
  接続の許可 → allowlist の許可 → 記録 → ログ → 拒否」——**実現層を問わない書き方になっているが、
  L7 では成り立たない**。L7 では記録器を置かないため、ドメイン由来の記録だけでなく 53 番への試行の
  記録も消える。行として取り下げ、**L3 に限った約束として宣言し直したうえで、L7 の並びを別の行と
  して宣言する**（resolver の許可 → 53 の遮断 → 確立済み接続の許可 → `allowCidrs` /
  `allowHostPorts` の許可 → proxy 宛の許可 → ログ → 拒否）。L3 側の並びは 1 つも変わらない。
  53 番への試行は L7 でも `fw-dns-drop:` の LOG 規則に残るので、信号そのものが消えるわけではない
- 台帳 §5 の「GitHub の meta API は、github バンドルが選ばれているときだけ、かつ最終テーブルが
  有効になった後にだけ取得する……同じホストは DNS 経由で既にセットに入っている」——**実現層を
  問わない書き方になっているが、L7 では成り立たない**。L7 では DNS 経由の登録そのものを行わない
  ため後半の但し書きが偽であり、加えて**取得したレンジを ipset に入れると、proxy を迂回して全ポート
  へ抜ける直通経路になる**（新たに宣言する保証の「proxy 宛の許可・DNS の固定・loopback・
  `allowCidrs`・`allowHostPorts` だけが残る」「proxy を迂回した直接接続は audit でも塞がれる」と
  正面からぶつかる）。行として取り下げ、**L3 に限った約束として宣言し直す**。**L7 では meta API を
  取得しない**——名前による許可は proxy 側の ACL が担うため、IP レンジを持つ意味が無い

  > **これら 4 行の再宣言は、上の「新たに宣言する保証」に含めて数える**（L7 側の各行が新しい約束、
  > L3 側の各行が適用範囲を狭めた再宣言）。audit の 2 行は振る舞いの取り下げではないが、順序行と
  > GitHub meta の行は L7 側の振る舞いが変わる（記録器を置かない・meta を取得しない）。いずれも
  > 台帳の行としては廃止と新設になる。
