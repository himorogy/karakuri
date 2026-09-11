---
status: open
type: feat
base: main
targets:
  - .devcontainer/Dockerfile
  - .devcontainer/docker-compose.yaml
  - .devcontainer/firewall.json
  - .devcontainer/proxy
  - docs/guarantees.md
  - images/devcontainer-base/examples/docker-compose.yaml
  - package.json
  - packages/egress-guard/README.md
  - packages/egress-guard/docs/known-issues.md
  - packages/egress-guard/docs/verification-record.md
  - packages/egress-guard/templates/proxy/squid.conf
  - packages/egress-guard/tests/ptr-spoof-harness.py
  - packages/egress-guard/tests/verify-l7.sh
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# karakuri 自身を L7 へ切り替え、実機での判定を常設の検証スクリプトにする

## 内容

egress-guard の egress 制御を、L3（iptables + ipset の IP allowlist）だけの構成から、
L7 forward proxy を既定としつつ L3 も選べる構成へ移す束の 3 枚目、最後。束は 3 枚:

- 0019 スキーマ version 2 と proxy ACL への変換（**先行。マージ済みであること**）
- 0020 最終テーブルの分岐と、sidecar の配布物としての整備（**先行。マージ済みであること**）
- **0021 karakuri 自身の L7 への切り替えと、実機での検証**（このチケット）

束の共通の前提:

- **実現層の既定は L7。L3 は設定に明示したときだけ選べる**
- **TLS を終端しない。proxy は明示型（`HTTP_PROXY` / `HTTPS_PROXY` と `CONNECT`）**
- **不変条件は 3 枚のどこでも弱めない。** ポリシーの変更にはイメージの再ビルドが要るという性質は、
  sidecar のイメージに ACL を焼き込むことで満たす
- **ACL の出力形式と検証の判定基準は proxy の実装に依存させない**

0019 と 0020 が入った時点で、機構は揃っているが**このリポジトリ自身はまだ L3 で動いている**。
このチケットが切り替えと、その確認を行う。

**このリポジトリ自身を切り替える理由は 2 つある。**

- **切り替えないと、常設する検証スクリプトの判定対象が存在しない。** 下の項目 2 が引き継ぐ判定は
  本実装（このリポジトリの devcontainer 構成）へ向けたものであり、とくに「proxy 環境変数を無視した
  直接の接続が塞がれていること」は L7 と L3 を組み合わせた状態でだけ成立する。切り替えを別の
  作業単位へ回すと、スクリプトを常設しても走らせる対象が無い
- **配られる側でしか踏まない欠陥が、自分で使っていない間は検査を全部通ったまま残る。**
  下の項目 4 の 2 件は、publish 前の先行検証（利用側リポジトリ）で初めて出たもので、
  このリポジトリが L3 のままなら検査は緑のままだった。**なお順序としては、その先行検証が
  他コンテナでの確認にあたる**——このチケットはその後段であり、標準の順序から外れていない

### 1. karakuri 自身を L7 へ切り替える

- `.devcontainer/firewall.json` を version 2 へ上げ、実現層は**書かない**（既定の L7 を選ぶ）。
  合わせて、これまで L3 では書けなかったドメインを先頭ドットの形で足せるようになる
- `.devcontainer/docker-compose.yaml` に `egress-proxy` service を足し、`dev` へ proxy の環境変数を
  配線する。**大文字と小文字の両方**、`no_proxy` / `NO_PROXY` に `localhost,127.0.0.1`、
  `NODE_USE_ENV_PROXY=1`
- **proxy のイメージは `packages/egress-guard/templates/proxy/` を compose から直接参照する。**
  `.devcontainer/` の下に写しを作らない。写しを作ると配布物と実際に動いているものが静かに
  食い違い、そのずれは検査を全部通ったまま残る。配布物の Dockerfile は `firewall.json` と
  `proxy/squid.conf` を build context の root から解決するため、このリポジトリの配置では
  `.devcontainer/proxy` を `templates/proxy/` への symlink として置く（写しではなく参照）
- **`firewall.json` はこのリポジトリに 1 本のまま。** dev のイメージと proxy のイメージが同じ
  ファイルを読む。proxy 用に別の設定ファイルを置かない
- **`.devcontainer/Dockerfile` の base の pin を `devcontainer-base:edge` の digest へ上げる。**
  公開済みの base はすべて egress-guard 0.2.0 以下を焼いており、`version: 2` の設定を
  `unsupported schema version` で拒否する。切り替えた設定でその base を使うと、起動時の
  ファイアウォール適用が失敗して devcontainer が fail-closed で立ち上がらない。`:edge` は先行検証で
  使った、未公開の egress-guard を焼いたビルドである。pin は index の digest で行う
  （`sha256:12dbdd8ed072f9e3bf34b1ef70d03aeb3b62d0d25e00dd09c0715deb1223bc1d`。
  `docker buildx imagetools inspect` の `Digest:`。プラットフォーム単体の manifest の digest で
  pin すると別アーキで pull できない）。**正式版への pin の戻しはこのチケットの範囲外**（下の
  「やらないこと」の順序を参照）

### 2. 実機の判定を常設の検証スクリプトにする

`packages/egress-guard/tests/verify-l7.sh` を新設し、`package.json` に実行するスクリプトを足す
（`verify:docker` と同じ扱い。**`pnpm test` からは呼ばない**——Docker と外向きの到達性が要るため）。

判定項目は `poc/l7-proxy/verify.sh` のものを引き継ぐ。PoC のスクリプトをコピーするのではなく、
**判定の内容だけを持ってきて、対象を本実装（このリポジトリの devcontainer 構成）へ向ける。**

引き継ぐ項目:

- proxy 経由で `apt-get update` が 1 回目も 2 回目も成立する（アドレスが動く配信元でも落ちない
  ことを見る項目なので、**時間を置いた 2 回目が要る**）
- 先頭ドットで許可したドメインの、設定に書いていない具体的なホストへ接続でき、proxy のログに
  その具体名が残る
- 許可していないドメインへの接続は失敗し、proxy のログに拒否した名前が残る
- 逆引きした名前で allowlist を通過できない
- 管理インタフェースが拒否される
- proxy を止めると外向きが失われる
- **エージェントのコンテナのファイルシステムに ACL のファイルが存在しない**

**新しく判定する項目:**

- **proxy 環境変数を無視した直接の接続が塞がれていること。** PoC ではここが確認できていない。
  クライアントが `HTTP_PROXY` を読まずに直接つなごうとしても、縮小した最終テーブルが落とす。
  L7 と L3 を組み合わせた状態でだけ成立する項目であり、**この束が成立しているかどうかを最終的に
  決めるのはこの項目**
- **ACL の変更にイメージの再ビルドが要ること。** PoC では確認していない。実行中のコンテナから
  ACL を書き換える経路が無く、`firewall.json` を変えても再ビルドするまで proxy の判定が変わらない

### 3. 記録と既知の問題

- `verification-record.md` に、このチケットの検収でホスト上を実際に走らせた結果を記録する。
  **記録には、ホストの OS、Docker の版、iptables のバックエンド（`nf_tables` か `legacy` か）を
  含める。** Linux ホストでは挙動が変わるため
- 同 §2 のカバレッジ表を更新し、どの不変条件がどの項目で確かめられたかを合わせる
- `known-issues.md` #7（配信 CDN が 2 系統あり、ワイルドカードを受理できないために allowlist に
  載せられない）を、解消したものとして書き換える。**解消した項目を消すのではなく、何によって
  解消したかを残す**
- `README.md` に、L7 の構成が実機で確かめられていることと、確認の走らせ方を書く

### 4. 実機での先行検証で出た配布物の欠陥を直す

publish 前の先行検証（`devcontainer-base` の `:edge` に未公開の egress-guard を焼き、
利用側リポジトリで L7 を立てて確かめた）で、**配布物の側に 2 件の欠陥が出た。** どちらも
このリポジトリを L7 へ切り替えれば同じように踏むので、切り替えと同じチケットで直す。

- **proxy のアクセスログがエージェントのコンテナから読めない。** Squid はログを `0640`・
  owner と group をどちらも `proxy`（uid/gid 13）で作る。`dev` は uid 1000 の `node` なので、
  `:ro` でマウントできていても other に読み権限が無く `Permission denied` になる。
  **`dev` に補助グループ 13 を与えれば読める**（`group_add: ["13"]`）。group には `r--` しか
  無いので書き込みは依然できず、**「読めるが書き換えられない」が両方成立する**（`:ro` の
  マウントと合わせて二重になる）。実測で確認済み。
  直す先は**このリポジトリの `.devcontainer/docker-compose.yaml` と、配布物の雛形
  （`images/devcontainer-base/examples/docker-compose.yaml`）の両方**——雛形を直さないと、
  利用側が同じ状態を作る
- **proxy の起動ログに `FATAL: pinger: Unable to open any ICMP sockets.` が出る。**
  `cap_drop: [ALL]` で ICMP に要る権限が無いため。**Squid 本体は正常に動いており**
  （proxy 経由の通信は成立する）、`cache_peer` を使わないこの構成で pinger は不要だが、
  配布物のログに `FATAL` が出続けると利用者は壊れていると判断する。`squid.conf` で
  pinger を無効にして黙らせる

**先頭ドットのドメインに `WARNING: failed to resolve` が出る件はこのチケットで直さない。**
`init-project-firewall.sh` を変えることになり、下の「維持する保証」の
「このチケットは `init-project-firewall.sh` を 1 行も変えない」と衝突するため。派生チケット
（`0020a`）で扱う。

### やらないこと

- **パッケージのリリースとタグ打ちは行わない。** ただし順序は「検収が通ってからタグ」ではなく
  **「タグを打ってから検収」**である——検収には egress-guard 0.3.0（`templates/proxy/Dockerfile` が
  `npm install -g @himorogy/egress-guard@0.3.0` を要求する）と、それを焼いた base が要り、
  どちらもこのチケットのマージ後にしか出せない。マージ後の順序は次のとおりで、いずれも
  このチケットの外で行う
  1. `@himorogy/egress-guard@0.3.0` のタグを打つ
  2. `runtime-base` → `devcontainer-base` の順でタグを打つ
  3. `.devcontainer/Dockerfile` の pin を `:edge` の digest から正式版へ戻す（別の作業単位）
  4. ホスト上で検収する（下の「検収」）
- `poc/l7-proxy/` は削除しない。判定の内容を `verify-l7.sh` へ引き継いだあとの処分は別途。
  **PTR 偽装の harness（`test-helpers/ptr-spoof-harness.py`）は `tests/` 配下へコピーして常設側から
  参照する**——常設のスクリプトが処分未定の PoC に依存しないため。PoC 側の実体は処分まで残る
- proxy の実装を Squid 以外へ替える検討はしない
- `spec.md` と `design.md` は触らない（0020 で現在形化済み）

### 検収

**このチケットの中身はホスト上でしか確かめられない。** devcontainer の中には `docker` コマンドも
Docker のソケットも無く、そもそも L3 が効いている環境では proxy 自身が allowlist に縛られて、
確かめたい現象が再現しない。`verify:` に置いた検査は形式と常設のもの（lint・ユニットテスト）
だけであり、**このチケットの本体は検収で確かめる。**

検収の前提: 上の「やらないこと」の順序 1〜3 が済んでいること。sidecar のイメージは
egress-guard 0.3.0 が npm に無いと組めない。

検収の手順:

1. ホスト上でこのブランチを取り出し、devcontainer を作り直す（sidecar のイメージのビルドを含む）
2. `verify-l7.sh` をホストから走らせる
3. 実際に開発作業ができることを確認する（`pnpm install`、VS Code 拡張の導入、`git` の取得）
4. 切り戻しは `.devcontainer/firewall.json` に実現層 `l3` を書いて作り直すだけで済む

### 実装上の注意

- 検証スクリプトの判定は proxy の実装に依存させない。ログの読み取りが実装固有になる項目は、
  その旨を項目のコメントに残す
- 出荷される文字列に設計文書の節番号や不変条件の記号を書かない
- 判定できなかった項目を成功として数えない。道具が無くて実行できなかったのか、判定が通ったのか
  を区別できる形で報告する

## 保証

### 新たに宣言する保証

- proxy の環境変数を読まずに直接外へ出ようとする接続は、縮小した最終テーブルが落とす。L7 を
  選んだ構成で、proxy を迂回する経路は残らない（未検証の約束 (テスト困難: Docker と外向きの
  到達性が要り、`pnpm test` からは走らせられない。`verify-l7.sh` で常設化し、検収で走らせる)）
- `firewall.json` を書き換えても、イメージを再ビルドするまで proxy の判定は変わらない。実行中の
  コンテナから ACL を差し替える経路は無い（未検証の約束 (テスト困難: 同上)）
- 先頭ドットで許可したドメインについて、設定に書いていない具体的なホストへ接続でき、その接続は
  時間を置いた 2 回目も成立する（未検証の約束 (テスト困難: 同上)）

### 維持する保証

- 台帳 §4 の「同梱テンプレート3種と、README および `docs/` のフェンス内に書かれた設定例のうち
  版を宣言しているものは、すべて検証を通る」——README に設定例を足すため、この検査の対象が増える
- 台帳 §5 の適用に関する行はすべて維持する。このチケットは `init-project-firewall.sh` を
  1 行も変えない。変わるのはこのリポジトリが選ぶ実現層だけである
- 0020 で宣言した L7 側・L3 側の最終テーブルに関する各行——このチケットは、その L7 側を
  このリポジトリで実際に選ぶ変更であり、宣言済みの振る舞いをそのまま踏む
- 0020 の未検証の約束「proxy の記録はエージェントのコンテナから読めるが、書き換えられない」
  ——0020 自身が「0021 の `verify-l7.sh` と検収で確認する」と書いている行。**先行検証で読めない
  ことが判明したので、上の項目 4 の `group_add` はこの行を成立させるための修正である。**
  約束の内容は 1 文字も変えない（読める・書けないの両方を要求したまま）

### 廃止する保証

- なし。このリポジトリが選ぶ実現層が変わるだけで、パッケージが約束する振る舞いは増減しない
