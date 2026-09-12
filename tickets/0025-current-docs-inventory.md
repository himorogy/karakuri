---
status: open
type: docs
base: kuda/0024-host-tools-relocate
targets:
  - docs/host-tools-distribution.md
  - docs/prod-secret-isolation-design.md
  - images/runtime-base/migration.md
  - images/runtime-base/verification-record.md
  - images/devcontainer-base/migration.md
  - packages/egress-guard/docs/design.md
  - packages/egress-guard/docs/spec.md
  - packages/egress-guard/docs/known-issues.md
  - packages/egress-guard/docs/measuring-egress.md
  - packages/egress-guard/docs/web-search-fetch.md
  - packages/egress-guard/docs/verification-record.md
  - docs/archive/host-tools-distribution.md
  - docs/archive/prod-secret-isolation-design.md
  - docs/archive/runtime-base-migration.md
  - docs/archive/runtime-base-verification-record.md
  - docs/archive/devcontainer-base-migration.md
  - docs/archive/egress-guard-design.md
  - docs/archive/egress-guard-spec.md
  - docs/archive/egress-guard-known-issues.md
  - docs/archive/egress-guard-measuring-egress.md
  - docs/archive/egress-guard-web-search-fetch.md
  - docs/archive/egress-guard-verification-record.md
  - README.md
  - SECURITY.md
  - example/README.md
  - images/devcontainer-base/README.md
  - images/runtime-base/README.md
  - packages/egress-guard/README.md
  - images/runtime-base/tests/shipped-symbols.test.sh
  - docs/secure-publish.md
  - images/devcontainer-base/PORT-FORWARDING.md
  - docs/guarantees.md
verify:
  - pnpm test
---

# 現在形4種の外にある文書を docs/archive/ へ凍結する

## 内容

記述整理の作業単位 A。現在形の文書を kuda の既定4種（台帳 / conventions / README / CLAUDE.md）とその分割ファイルに絞るため、どれにも属さない 11 本を `docs/archive/` へ移し、現在形の文書からの参照を新しいパスへ付け替える。`docs/archive/` は現在形ではなく、conventions と README を整備するときの参考資料である。整備が済んだら削除する（別チケット）。このチケットでは中身を編集しない。

**base が統合ブランチでない理由（feature ブランチ例外）。** 先行する 0024（host tools の `host-tools/` への移設）が PR レビュー待ちでマージできず、この変更は 0024 後のパス（`host-tools/`）を前提にする。0024 のブランチを base にし、0024 がマージされたら PR の宛先は main へ移る。

### 棚卸しの判定

4種の外にあるが**残す**もの（このチケットでは触らない）:

- `SECURITY.md` — README の分割。脆弱性報告経路という公開面の使い方で、置き場所は GitHub が決める
- `images/devcontainer-base/PORT-FORWARDING.md` — devcontainer-base README の分割。conventions が正本として指定している
- `packages/egress-guard/docs/agent-brief.md` — README の分割。npm の `files` に同梱され、利用側のコンテナでエージェントが読む
- `packages/egress-guard/CHANGELOG.md` — `.changeset/` の生成物
- `docs/secure-publish.md` — `.github/CODEOWNERS` という現役のルールが参照している。参照元が生きている間は archive に置かない
- `packages/egress-guard/poc/l7-proxy/` の文書 — 文書だけ抜くと PoC が成立しない。ディレクトリごと削除するかは別チケット

**移設**するもの（11 本）。`docs/` 直下の 2 本はファイル名のまま、それ以外は同名衝突を避けるため元のディレクトリ名を接頭辞にする。`git mv` で移し、中身は変えない:

- `docs/host-tools-distribution.md` → `docs/archive/host-tools-distribution.md`
- `docs/prod-secret-isolation-design.md` → `docs/archive/prod-secret-isolation-design.md`
- `images/runtime-base/migration.md` → `docs/archive/runtime-base-migration.md`
- `images/runtime-base/verification-record.md` → `docs/archive/runtime-base-verification-record.md`
- `images/devcontainer-base/migration.md` → `docs/archive/devcontainer-base-migration.md`
- `packages/egress-guard/docs/design.md` → `docs/archive/egress-guard-design.md`
- `packages/egress-guard/docs/spec.md` → `docs/archive/egress-guard-spec.md`
- `packages/egress-guard/docs/known-issues.md` → `docs/archive/egress-guard-known-issues.md`
- `packages/egress-guard/docs/measuring-egress.md` → `docs/archive/egress-guard-measuring-egress.md`
- `packages/egress-guard/docs/web-search-fetch.md` → `docs/archive/egress-guard-web-search-fetch.md`
- `packages/egress-guard/docs/verification-record.md` → `docs/archive/egress-guard-verification-record.md`

### 参照の付け替え

現在形の文書が移設対象を指している箇所を、新しいパスへ付け替える。目的はリンク切れをゼロに保つことで、参照文そのものを削るのは README 圧縮のチケット（別）が行う。相対リンクは各ファイルからの相対パスで書き直す。節番号（§）を伴う参照はそのまま残す。

- `README.md` — `images/devcontainer-base/migration.md` と `packages/egress-guard/docs/measuring-egress.md` へのリンク
- `SECURITY.md` — egress-guard の design / spec / known-issues へのリンク
- `images/devcontainer-base/README.md` — `migration.md` へのリンク
- `images/runtime-base/README.md` — `docs/prod-secret-isolation-design.md` と `verification-record.md` へのリンク
- `packages/egress-guard/README.md` — 冒頭の文書表と本文にある `docs/` 配下へのリンク全件。`docs/agent-brief.md` の行だけは据え置く。同梱 README のリンク先がパッケージ外へ出るのは、README 圧縮で参照文を削るまでの過渡状態として受け入れる
- `example/README.md` — 「設計書 rev.9 に反映済み」の行は付け替えず削除する。archive を参照させる価値が無い
- `docs/secure-publish.md` — egress-guard の design / spec へのリンク（残す文書だが、参照先が移設される）
- `images/devcontainer-base/PORT-FORWARDING.md` — `docs/host-tools-distribution.md` へのリンクと、`images/runtime-base/verification-record.md` への平文の参照

参照の探し方: 移設対象のファイル名を `git grep` し、上記 8 ファイルに当たった行を直す。上記以外のファイル（コード内コメント・workflows・Dockerfile・テスト）に当たった行はスコープ外なので触らない。

### 検査対象の調整

`images/runtime-base/tests/shipped-symbols.test.sh` は `images/runtime-base/migration.md` を strict 検査の対象にしている（`require_files` と `scan_strict` の引数）。移設で対象の集合が変わるので、この 2 箇所から `migration.md` を外す。他の検査対象と否定対照は変えない。

許可パターン（`ALLOWED_REF`）は旧パスの文字列一致なので、移設先 `docs/archive/` のパスを伴う節番号を弾く。新パスも許可側に入れる。コピー先で解決できないパスを検知する `DESIGN_DOC` も同じく新パスへ追随させる（templates / host-tools 向けの門が archive 経由で開かないようにする）。旧パスの許可と検知は据え置く（設計書を指すコード内コメントは旧パスのままなので、それを落とすのはコメント整理のチケット）。PR レビューでの裁定により追加した。

台帳 §11 の対象範囲の文言は「このリポジトリに留まる README と移行手順」と書いているが、移設後は移行手順にあたる検査対象が無くなる。文言を実態に同期する（「と移行手順」を落とす）。約束の内容は変えない。

### やらないこと

- 移設した文書の中身の編集、conventions への制約の抽出、archive の削除、known-issues の Issue 化、`poc/l7-proxy/` の処遇（別チケット）
- README 本文の圧縮と参照文の削除（README 圧縮のチケット）
- コード内コメント・workflows・Dockerfile・テストのコメントにある設計書のパスの書き換え（コメント整理のチケット）

## 保証

### 新たに宣言する保証

- なし。文書の移設と参照の付け替えであり、外から観測可能な振る舞いは変わらない。egress-guard の npm 同梱内容（`docs/` 配下）は変わるが、台帳 §23 が約束しているのは配布物の file mode であって同梱ファイルの一覧ではない

### 維持する保証

- 台帳 §11（`images/runtime-base/tests/shipped-symbols.test.sh` — 出荷物の記号検査）。検査対象から `images/runtime-base/migration.md` を外すので、対象の集合が変わる。他の対象と否定対照は変えない。台帳の対象範囲の文言を実態に同期するが、約束（記号の不在）は変えない

### 廃止する保証

- なし。約束を取り下げる変更ではない
