---
status: close
type: feat
base: main
targets:
  - images/devcontainer-base/bin/git-identity-setup
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/examples/devcontainer.json
  - images/devcontainer-base/tests/git-identity.test.sh
  - images/devcontainer-base/README.md
  - package.json
  - docs/guarantees.md
  - images/runtime-base/tests/shipped-symbols.test.sh
verify:
  - pnpm lint:sh
  - pnpm test
---

# git identity の供給経路を token からの導出へ一本化する

## 内容

dev container 内の `user.name` / `user.email` に供給経路が無い。以前は VS Code が
`dev.containers.copyGitConfig`（既定 true）でホストの gitconfig を暗黙にコピーしていたぶんだけ
動いていたが、CLI 起動やコンテナの作り直しではその経路を通らず、コミットが
`Author identity unknown` で止まる。動いている間は誰も気づかない穴である。

供給経路を `/run/secrets/GH_TOKEN` からの導出に一本化する。github.com への認証を注入した
トークンだけに固定してある（`images/runtime-base/Dockerfile` の `ENV GIT_CONFIG_COUNT` 直上）
のと同じ考え方を identity にも適用し、**「どのアカウントとして push するか」と「誰として commit
するか」を構造的にずらさない。**トークンを差し替えれば identity も追随する。

あわせて `dev.containers.copyGitConfig` を雛形で明示的に `false` にし、ホストの gitconfig が
暗黙に持ち込まれる経路を切る。注入へ寄せるなら暗黙の供給を残さないのが対で、切らないと
「VS Code から開いたときだけ動く」状態が残り、同じ穴が再発する。

### 置き場所と実行の形

**スクリプトはイメージへ焼き、雛形からはコマンド名で呼ぶ。**
`images/devcontainer-base/README.md` は「雛形に post-create.sh は無い。プロジェクト共通の
スクリプトを置く必然が無くなった」と明言しており、雛形にスクリプト本体を足すとこの設計と食い違う。
`postStartCommand` が `sudo /usr/local/bin/init-project-firewall.sh` を呼んでいるのと同じ形にする。

**層は devcontainer-base。** 配置規約「能力は最小に、制約は最大に」に従う。prod は detached HEAD
で commit しないので identity は prod で使わない能力であり、runtime-base には入れない。
`images/devcontainer-base/bin/` は新設になる（現在このディレクトリは無く、devcontainer-base の
スクリプトは Dockerfile 内の `RUN printf` でインライン生成されている。COPY する形は
runtime-base の `bin/` に先例がある）。

**実行は `postCreateCommand`。** `gh api` を叩くのでネットワークが要り、egress-guard 適用後
（`postStartCommand`）では宛先が許可されていない可能性がある。個人フック `/personal/setup.sh` の
後に続ける。`~/.gitconfig` はコンテナ層にあり作り直しで消えるが、作り直せば `postCreateCommand`
が再び走るので追随する。

### 導出の内容

- アカウント情報は `gh api user` から取る。`gh` はイメージの shim で、`/run/secrets/GH_TOKEN` を
  実行時にだけ環境変数へ注入する
- `user.name` は表示名を使い、未設定（`null`）ならログイン名へ落とす。表示名は GitHub の
  プロフィールとして既に公開されている情報であり、利用者が値を選ぶ余地をプロフィール側に残す
- `user.email` は `<id>+<login>@users.noreply.github.com` を組み立てる。アカウントの登録
  メールアドレス（`.email`）は使わない。公開設定に依存するうえ、コミットに永続する本アドレスを
  public リポジトリへ晒さないため
- **既存の identity があり導出値と異なる場合は、両方を示す警告を出したうえで上書きする。**
  ホスト側の資格情報による認証を認めない設計と対称で、identity も token 側を正とする
- トークンが無い・アカウント情報を取得できない（scope 不足による 403 など）場合は、identity を
  設定せず理由を 1 行出して 0 で終わる。起動を壊さない

**取得と組み立てを分ける。** `gh api` を呼ぶ部分と、その出力から値を組み立てて `git config` へ
書く部分を分離し、テストは前者を差し替えて後者を検査する。ネットワークを使わずに導出の正しさを
固定できる形にする。

### やらないこと

- コミット署名。鍵の供給が別途要る。SSH agent forwarding は権限転送そのもので、注入へ寄せる
  この方針と正面から衝突するため、やるなら別チケットで「コンテナ内に閉じた鍵の注入」を設計する
- fine-grained PAT で `gh api user` が通るかの確定。未実測だが、取得に失敗しても identity 無しで
  続行する設計なので壊れない。通らないことが分かった時点で別チケットにする
- 対話シェルの起動ごとのずれ検出。導出の時点で既存値と比較すれば足り、毎シェルで `gh api` を
  叩く形は取らない
- runtime-base への配置。prod の identity 供給
- 過去のコミットの書き換え。履歴改変のコストのほうが高い
- ホスト側（VS Code 以外のエディタ、GUI の git クライアント）の identity。コンテナの外は
  この経路の対象外である
- `images/devcontainer-base/README.md:137-139` の `postCreateCommand` が exit 127 で落ちるという
  記述と、`examples/devcontainer.json` の「その形の実行は無くなった」という記述の食い違い。
  今回の変更で `postCreateCommand` の形が変わるため隣接するが、別の誤りなので直すなら別チケット

## 保証

### 新たに宣言する保証

`docs/guarantees.md` の `## Guarantees` へ `§22` を追加する。

#### `### 22. images/devcontainer-base/tests/git-identity.test.sh — images/devcontainer-base/bin/git-identity-setup`

- トークンからアカウント情報を取得できるとき、コンテナ内の git の author 名と author メール
  アドレスが、そのアカウントの表示名（未設定ならログイン名）と、公開設定に依存しない転送用
  アドレスになる（テスト: "アカウント情報から name と noreply email が設定される"）
- 設定されるメールアドレスにアカウントの登録メールアドレスは使われない。取得したアカウント情報に
  登録アドレスが含まれていても、それが author メールアドレスとして現れることはない
  （テスト: "登録メールアドレスは author に現れない"）
- 既に author 名かメールアドレスが設定されており、それがトークンのアカウントから導いた値と
  異なる場合、両方の値を示す警告を出したうえでトークン側の値へ書き換える
  （テスト: "既存の identity と食い違うときは警告して上書きする"）
- トークンが無い、またはアカウント情報を取得できない場合、identity を一切変更せず、理由を
  1 行出して成功として終わる。起動を壊さない（テスト: "取得に失敗しても identity を触らず 0 で終わる"）
- アカウント情報の取得と、そこから値を組み立てて設定する処理が分かれており、取得を差し替えた
  状態で導出結果を検査できる（テスト: "取得部を差し替えた状態で導出結果が固定される"）

### 維持する保証

- 台帳 `§10`（`git-credential.test.sh`）。`gh` の shim 経由でトークンを使うため経路が隣接する。
  github.com の credential helper の固定と、トークンが無いときに連鎖ごと止まる振る舞いを変えない
- 台帳 `§11`（`shipped-symbols.test.sh`）。`images/devcontainer-base/bin/` を新設するため、
  イメージへ焼き込まれるコードの範囲が広がる。参照先の無い記号を持ち込まない。**この節が挙げる
  「イメージへ焼き込まれるコード」の走査範囲へ新設ディレクトリを加える**（レビューの指摘を受けた
  軽量裁可により targets を 1 ファイル広げた。検査の対象が実態より狭いままだと、記号の不在は
  今回の目視でしか担保されない）

### 廃止する保証

- なし。既存の約束を取り下げる変更ではない。identity には現在どの約束も無く、今回が初出である
