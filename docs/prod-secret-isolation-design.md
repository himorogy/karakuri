# prod secret 分離設計

status: draft (rev.9) supersedes: `@himorogy/enclave-env` の `templates/prod-shell.sh`

rev.9 の主変更（3 件）。プロジェクト側での使い勝手評価（`example/README.md`）から出た決定を反映した。

**1. dev container の鍵注入を broker 方式へ寄せ、ホスト上の恒久平文（compose `env_file` の `dev/.env.container`）を廃止した**（§4.9 / D28）。prod が §6.3 で廃止した `~/.config/<project>/.env.container` と同じ形が dev にだけ残っていた。ただし目的はホスト上の保管状態と意図しない書き出し面の縮小に**限る** — dev container 内のエージェントは同一 UID で動くため、どの搬送路を選んでも鍵の能力は行使でき、そこを守るのは搬送路ではなく鍵のスコープである。注入スクリプト `dev-inject.sh` は詳細仕様の擦り合わせ中で**未実装**（論点は §4.9 に列挙）。

**2. 対話 prod 作業の標準手順を「二段構え」に確定した**（§6.4 / D29）。rev.8 まで §11 は非対話への一本化を第一候補としていたが、dryrun → 適用のような対話的運用が実在する。対話 TTY が使えないのは防衛判断ではなく stdin を搬送路にした技術的帰結（D3）であり、二段構えは注入 1 回・clone 1 回でセッションを維持でき、防御を何も緩めずに体験を回復する。`/src` の tmpfs（D18）は維持する。

**3. GH_TOKEN の checkout 後破棄が dev への流用の障害にならないことを明文化した**（§4.9）。破棄は prod-entrypoint.sh 内の処理であり、dev は entrypoint を通らない。dev で共通化するのは broker・shim・`/run/secrets` 規約・git-askpass であって、entrypoint ではない。

**2026-08-16 追記: `GIT_ASKPASS` は git の認証経路として単独では成立しない**（§4.6 / D33）。プロジェクト側での使用で発覚した。git は credential helper を先に呼び、資格情報が返った時点で確定する。しかも VS Code の Dev Containers 拡張は global gitconfig の helper と統合ターミナルの `GIT_ASKPASS` の**両方**を握るため、helper を打ち消すだけでも足りない。認証先をイメージ自前の credential helper に固定した（環境変数による設定は全設定ファイルの後に適用されるので、記述順にも environ の注入にも勝てる）。dev では破壊的変更（`GH_TOKEN` の注入が必須になる）で、prod では N-2 の一角が閉じる。

rev.8 の主変更（3 件）。

**1. `@himorogy/enclave-env` を廃止し、`@himorogy/env-guard` を新設した。** 保留にしていた「package という配布層が要るか」に答えが出た（§6.3）— 要る。ただし enclave-env としてではない。コンテナの外（ホストの GUI git クライアント）からコミットする経路にはイメージの `core.hooksPath` が届かず、そこを塞ぐにはホストへスキャナを届ける手段が要る。一方で enclave-env に残すべき中身は無かった。共有スキャナと pre-commit hook は `packages/env-guard` へ移し、**リポジトリ内にスキャナは 1 ファイルしか存在しない**状態にした（D25）。イメージへは named build context で供給する（D26）。

**2. この文書を `.local/` から `docs/` へ移し、git の追跡下に置いた。** rev.7 が §4.8 で「記号ではなくパスで参照せよ」という規約を立てたが、その参照先が `.gitignore` の対象だったため、**許可した形の参照も宙に浮いていた** — 書いた本人以外は、他 org どころか clone した人間も辿れない。規約が成立する前提を揃えた。**3. §4.8 が予告していた出荷物からの記号の一括棚卸しを実施し、再発防止の検査を置いた**（`images/runtime-base/tests/shipped-symbols.test.sh`、`pnpm test` から走る）。棚卸しの対象は「karakuri の外へ出るか」で切った。詳細は §4.8。

あわせて、公開リポジトリに置くものと置かないものを分けた。この文書の §11 は「今この瞬間 prod がどうなっているか」を現在形で書いていたが、それは設計ではなく運用状態であり、対象リポジトリ名と並べれば「どの案件のどの防御が開いているか」の一覧になる。構成の性質としての記述に書き換え、運用状態は非公開の記録へ移した。

rev.7 の主変更: rev.6 に対する適合・敵対レビューの指摘を反映し、あわせて**移行手順 4（CI 側の検知）の前提を実測で潰した**。最大の変更は §8.2 で、当初案の `dotenvx precommit` を CI 検査から**破棄した** — クリーンな checkout（差分ゼロ）では平文の tracked `.env` を 2 件見つけておきながら「encrypted/gitignored (2)」と表示して rc=0 を返すことを実測した（D23）。単なる no-op ではなく「検査した風の緑」であり、検知装置としては無いより悪い。tracked ファイルの直接走査へ差し替える。同じ実測で D20 の主柱も確定した — `--convention flow --strict` は実際に落ちる（`.env.development.local` 不在で rc=1）。rev.6 では推論で書いていた箇所が実測になった。

実装側の穴として、entrypoint に **tmpfs であることの自己検査**を追加した（`/src` が named volume に戻る一行のドリフトで、起動も deploy も成功したまま防御が消える。§4.6）。**40 桁 hex を名前とする ref** で D21 の sha ゲートを通過できる穴と、**`GIT_REPO` への資格情報埋め込み**も閉じた。`--strict` の欠落については、強制はしないまま **shim が prod 鍵の注入を観測したときだけ 1 行警告する**ことにした（D22）— 「強制しない」は「黙る」を意味しない。あわせて §4.8 に**出荷物へ設計書の記号を書かない**規約を置いた。

rev.6 の主変更: Codex による適合レビューを受け、**「必須と書きながら機構では強制しない」というズレを解消した**。二つの項目を逆方向へ倒している。`GIT_REF` は entrypoint で**完全な commit sha を強制**し、`PROD_ALLOW_MUTABLE_REF=1` を明示したときだけ可変 ref を許す（§4.6 / D21）。逆に `--strict` / `--no-armor` は **イメージ側で強制しない**ことを確定させた（D20 の書き換え）— shim は dev container にも継承され、`--strict` は `--convention flow` のような正当な重ね掛けを壊しうる。プロジェクトの env 構成を知らない層に焼く判断ではなく、これは **dotenvx の使い方の問題であってコンテナの責務ではない**。破ったときの結果は残余リスク R12 として記録する。あわせて entrypoint が解決済み commit sha を stderr と `/run/prod-ref` へ出すようにし（可変 ref を許した場合でも「何をデプロイしたか」が残る）、`$HOME` の書込み可否と `/src` の `exec` を起動時に自己検査する。注入済みの鍵名を対話シェルで表示する仕組みも足した（§4.3）。

rev.5 の主変更: **CI 上で 7 回の実測を行い、推測で書いていた箇所を全て置き換えた。** 最大の変更は `/src` を named volume から **tmpfs** へ移したこと（D18）。rev.4 の `reset --hard` でも I7 は閉じておらず、named volume を再利用する構成では前回実行の（信頼しない）コードが打ったローカル ref が次回の `GIT_REF` として解決されること（N-1）と、`.git/config` に仕込まれた `core.fsmonitor` が entrypoint 自身の git 操作で発火し、しかも `GH_TOKEN` を破棄する**前**に走ること（N-2）を実測で確認した。tmpfs 化で両方とも構造的に消え、R6（`/src` への書き込みが Docker VM のディスクに残る）も同時に解消する。あわせて実測で判明した以下を反映した — compose の tmpfs は素の短縮形では root 所有かつ `noexec` になり、`uid=`/`gid=` と `exec` の明示が要る（§4.2）。`${NPM_CONFIG_PREFIX}/bin` が `/usr/local/bin` に優先するため shim は実体の退避なしには素通りされる（§4.3）。`pnpm run` は `node_modules/.bin` を PATH 先頭に積むため D5 の「全経路で効く」は誤りだった（§4.3 / D5）。dotenvx は復号失敗を rc=0 で返し暗号文を値として注入するため `--strict` が要る（D20）。pnpm の store は node_modules と同一 tmpfs に置かないとハードリンクが張れず RAM が倍になる（D19）。`core.hooksPath` は repo の `.git/config` から上書きできるので強制装置ではない（§4.7）。broker 契約の dotenv 方言を明文化し（§4.1）、`sudo` を runtime-base に置く判断を明示した（§4.5）。

rev.4 の主変更: §9 手順 1〜3 の実装中に Codex 敵対レビューで見つかった **I7 の穴**を修正した。rev.3 の entrypoint は `git checkout --detach` + `git clean -xdff` で復元していたが、この組み合わせでは **named volume を再利用したときに tracked file の改変が残る**（`checkout` は HEAD が既に同じ commit にあると working tree を復元せず、`clean` は untracked しか消さない）。prod で走ったコードが自分のソースを書き換えれば、次回同じ `GIT_REF` で起動しても改変済みコードが実行され、「明示された ref から復元される」が成立しない。`reset --hard` を追加して閉じた（§4.6）。あわせて entrypoint のエラーメッセージが入力行・鍵名をそのまま出力していた点（broker の出力が壊れていた場合に secret 本体が stderr に出る）を修正し、shim の `$(cat ...)` 失敗が `set -e` に捕捉されず空値注入になる穴を塞いだ（§4.3 / §4.6）。

rev.3 の主変更: compose secrets の `environment` ソースは実装調査（docker/compose ソース・issue）により **I1 を満たさず、`read_only: true` と併用不可（起動失敗）** と判明したため却下し、stdin 注入方式へ転換した（§4.1 / D1–D3）。鍵束は git 管理 + SOPS ではなく**各運用者の OS キーチェーンに置き、broker 契約で受け渡す**（§4.1 / D17 — 束の中身は個人資格情報であり、SOPS の age 鍵平文常駐も受容しない）。あわせて shim の三値意味論（§4.3 / D15）、`dotenvx prebuild` の除外（§4.7 / D16）、整合性リスクの明文化（R10）、GitHub プラン情報の更新（§8.3）を反映した。さらに Codex 敵対レビューを受け、`pipefail` による I6 の穴（§4.1）、clone 用トークンの checkout 後破棄（§4.6）、broker のリポジトリ外配置（§4.1）、「常に許可」リスク（R11）、I1 と swap の関係（§3 脚注）を反映した。

---

## 1. 目的

LLM エージェントが常駐する dev container から prod の秘匿情報を構造的に到達不能にする。従来の `prod-shell.sh`（`docker run` + `--env-file` + workspace bind mount + dev/prod 相互排他チェック）を docker compose 構成に置き換え、運用上の約束に依存していた防御を宣言的な構成に移す。

副次目標として、ここで定義する仕組みは `@himorogy` 以外の org へも流用する。したがって**特定プランでのみ利用可能な GitHub 機能に依存しない**ことを制約に含める（§8.3）。

---

## 2. 脅威モデル

### 2.1 信頼境界

| 領域              | 信頼        | 根拠                           |
| --------------- | --------- | ---------------------------- |
| ホスト OS          | 信頼する      | ここが破られたら全層が破れる               |
| dev container   | **信頼しない** | LLM エージェントが常駐し、任意のコマンドを実行しうる |
| prod container の**実行環境**  | 信頼する      | 人間が明示的に起動し、エージェントを含まない。ただし**そこで実行されるコードは信頼しない**（dev が書くため。R10）       |
| git 管理下の暗号化ファイル | 信頼する      | 平文は含まない                      |

前提条件（実測済み・維持必須）: dev container は Docker socket を持たない。`.devcontainer/devcontainer.json` に socket mount / docker-in-docker / docker-outside-of-docker はいずれも存在しない。この前提が崩れると、dev container から prod container への `docker exec` や任意 volume の mount が可能になり、本設計の分離全体が無効化される。§10 に恒常検証項目として置く。

### 2.2 対処する脅威

| #   | 脅威                                      | 旧構成の防御               | 評価        |
| --- | --------------------------------------- | -------------------- | --------- |
| T1  | dev container の LLM が prod secret を直接読む | コンテナ分離               | 有効・維持     |
| T2  | prod 秘密鍵がホスト上に恒久平文で存在する                 | なし                   | **未対応**   |
| T3  | prod 由来の平文が workspace 経由で dev に逐次流入する   | trap によるクリーンアップ      | fail-open |
| T4  | `docker inspect` で env が読める             | dev/prod 相互排他チェック    | 運用依存で脆い   |
| T5  | 意図しない書き出し（ログ・コアダンプ・診断レポート）で漏れる          | なし                   | **未対応**   |
| T6  | 平文 env が誤って git にコミットされる                | 各 clone への hook 手動導入 | 伝播しない     |
| T7  | dev container が prod の**構成・コードを改変**する（整合性） | なし                   | **残余リスクとして受容**（R10） |

T3 について: 相互排他チェックが守るのは**同時性**のみで、prod → ホスト → dev という**逐次的な残留**には効かない。trap は SIGKILL / OOM / `docker kill` / ホスト再起動で飛ぶため、構造的に fail-open である。

T7 について: 本設計が守るのは**機密性**である。dev は `.env.prod` へ書けるし（§6.1）、prod が実行するコードそのものを書ける。この経路は構成では塞げず、deploy 前の人間のレビューが唯一のゲートになる（R10）。

---

## 3. 不変条件

| #      | 不変条件                                           |
| ------ | ---------------------------------------------- |
| **I1** | prod 秘密鍵の平文が**不揮発ストレージ**上に存在しない（ホストのディスク、および Docker Desktop VM のディスクイメージを含む。tmpfs / パイプバッファ等の RAM は許容） |
| **I2** | prod 秘密鍵の平文がホストシェルの environ に存在しない             |
| **I3** | prod secret が prod container 内で環境変数として常時保持されない |
| **I4** | prod 由来の平文が dev container から到達可能な場所に残らない       |
| **I5** | prod イメージの**能力**の集合が dev イメージの能力の集合の部分集合である    |
| **I6** | secret の欠落が**沈黙した成功**にならない。空の secret ファイルは即エラー、entrypoint は取込件数と非空を検証し、ファイル不在時は下流ツールが認証失敗を顕在化させる。**broker 失敗が docker の終了で隠れないよう `pipefail` を必須とする** |
| **I7** | prod の実行対象が明示された git ref から復元される               |

I1 の「不揮発」限定は rev.3 で明示した。RAM 上の一時的存在（broker プロセスのヒープ、パイプバッファ、コンテナ内 tmpfs）まで排除することは不可能であり（R3）、達成目標は「電源断で消える場所以外に書かない」である。厳密には swap / hibernation image / クラッシュダンプにより RAM 内容が不揮発媒体へ退避されうる（R7）。I1 が実効的に意味するのは「**平文が暗号化されない形で不揮発媒体に残らない**」であり、この最後の砦をディスク暗号化の前提（R1、FileVault / BitLocker）が担う。swap も暗号化ボリューム上にあるため、字義の「一度もディスクに書かれない」ではなく「ディスクに書かれても暗号化されている」で閉じる。

I6 は rev.3 で再定式化した。shim は devcontainer-base にも継承され（I5 の帰結）、dev container では dev 環境向けの `GH_TOKEN` / `CLOUDFLARE_API_TOKEN` が別機構で注入される想定である。したがって shim は「ファイルが存在すれば注入・空ならエラー・不在なら素通し」の環境非依存な意味論とし、環境の判別をしない。§4.3 参照。

**I6 の範囲は搬送路に限る（rev.7 で確定）。** rev.5 はここに「I6 は消費側にも及ぶものとし `dotenvx run --strict` を必須要件に加える」と書いていたが、rev.6 の D20 は `--strict` を**イメージ側で強制しない**と決めており、不変条件の一部が強制なしの運用規約という状態になっていた。「必須と書きながら機構では強制しない」という、rev.6 が他の箇所で解消したのと同じ形のズレである。

I6 が構造的に保証するのは搬送路 — entrypoint の取込検証（件数 ≥ 1・各値の非空）、パイプ段の `pipefail`、shim の三値意味論 — に限定する。**消費側の沈黙した失敗（dotenvx が復号に失敗しても rc=0 を返し暗号文を値として注入する）は不変条件ではなく残余リスク R12 として扱う。** 強制しない代わりに、shim が prod 鍵の注入を観測したときだけ警告を出す（D22）。予防ではなく検知の位置づけであり、T6 のコミット前検査を緩和策に落とした判断（下記）と同型である。

**I7 の実現方法は rev.5 で変わった。** rev.4 までは named volume の再利用を前提に `checkout` + `reset --hard` + `clean` の三段構えで復元していたが、これでは**ref 自体が汚染された場合**（N-1）と、**`.git/config` に仕込まれた設定が entrypoint 自身の git 操作で発火する場合**（N-2）を防げないことが実測で判明した。`/src` を tmpfs にして毎回捨てることで、両方を構造的に排除する（D18 / §4.6）。あわせて `GIT_REF` は完全な commit sha を要件とする — content-addressed であり偽装できないため。

T6 に対応する不変条件は**置かない**。コミット前検査は `--no-verify` で素通りし、コンテナ外や git CLI を経由しない経路には効かないため、強制装置たりえない（§4.7 / R8）。緩和策として扱う。

---

## 4. 設計

### 4.1 鍵の受け渡し（I1 / I2 / T2 / T4）

#### 却下: compose secrets の `environment` ソース（rev.2 案）

rev.2 は `secrets: { dx_prod: { environment: DOTENV_PRIVATE_KEY_PROD } }` を「ホストディスクを経由しない」として採用したが、実装調査により以下が判明し却下する。

- compose の `environment` / `content` ソース secrets は bind mount では**ない**。コンテナ作成後・起動前に Docker API（CopyToContainer、tar 注入）で**コンテナの writable layer へ書き込まれる**。writable layer は `/var/lib/docker/overlay2` すなわちホスト（Docker Desktop では VM）の不揮発ディスクであり、I1 を満たさない。機構は compose maintainer 本人が明言している（docker/compose#9648 コメント）。
- さらに `read_only: true` と**併用不可**。書き込み先が read-only のため起動が失敗する（docker/compose#12031、#12303）。`tmpfs: ["/run/secrets"]` を足しても効かない（#12303 で報告者が実測済み）。v2.33.1 の変更はエラーメッセージを明確化しただけで、機構は未修正である。
- 公式 docs の「`/run/secrets/<name>` に bind mount される」という記述は **`file:` ソースのみ**に当てはまる。rev.2 の誤りは docs の記述をそのまま信じたことに起因する。
- 副発見: secret 参照先の env var が「未設定」ならエラーになるが、「**設定済みで空**」の場合は secret ファイルが**無言で作られない**（v2.40.1 以降）。compose の失敗を当てにできないため、検証は entrypoint 側で行う（§4.6）。

#### 採用: stdin 注入（broker → パイプ → コンテナ内 tmpfs）

```sh
# broker（下記契約を満たす任意のコマンド）の dotenv 出力を entrypoint へ直結する
# 例: macOS Keychain
set -o pipefail   # broker 失敗を docker の exit 0 で隠さない（I6）。zsh は既定 on、sh/bash は明示要
security find-generic-password -s "<project>-prod-env" -w | \
  GIT_REPO=<url> GIT_REF=<sha> \
  docker compose -f compose.prod.yaml run -T --rm prod pnpm deploy
```

`pipefail` が無いと、broker が認可失敗で非ゼロ終了しても、パイプの最終要素（docker）が 0 を返せばパイプ全体が成功扱いになる。entrypoint 側の非空検証（§4.6）が第二の防波堤だが、パイプ段でも止める。

**どちらが落ちたかの判定には SIGPIPE を考慮する（rev.4）。** 起動ラッパーが `PIPESTATUS` で原因を切り分ける場合、docker が先に失敗して stdin を閉じると broker は書き込み中に SIGPIPE を受けて 141 で終了する。`PIPESTATUS` は `(141, <docker の非ゼロ値>)` になるため、素朴に「broker を先に見る」実装は真の原因（docker）を隠して「broker failed (exit 141)」と誤報告する。broker 側が 141 かつ docker 側も非ゼロなら docker を原因として報告する。**broker と起動スクリプト自体は dev workspace の外（ホストの固定パス）に置く**。workspace はホストに bind mount されており、リポジトリ内の Makefile / npm script / broker ラッパーを dev が書き換えれば、人間がホストで実行する際に正規 broker の前後で鍵を複製できる（Codex 敵対レビュー #13）。リポジトリ内スクリプトに broker 起動を委譲しない。

**鍵束は git 管理しない。** 束の中身（`GH_TOKEN` / `CLOUDFLARE_API_TOKEN` 等）は開発者・運用者ごとに異なる個人資格情報であり、リポジトリ共有物ではない。git 管理する暗号化物は `.env.prod`（dotenvx、プロジェクト共有）だけである。プロジェクト共有の `DOTENV_PRIVATE_KEY_PROD` は、各運用者が自分の鍵束に格納し、運用者間の受け渡しはチームのパスワードマネージャで行う。

**broker 契約** — 以下を満たすコマンドであれば実装は問わない。

1. 下記の**方言**に従う dotenv 形式を stdout に出力する
2. 保管中の実体が不揮発ストレージ上で平文でない（OS キーチェーン等の暗号化ストアに置く）。**復号鍵そのものが平文でローカルに常駐する方式は契約違反**
3. 取得時に OS レベルの認可（パスワード / Touch ID プロンプト）が働く。プロンプトの緩和（「常に許可」等）は開発者の裁量に委ねる
4. 非対話環境で認可を得られない場合は非ゼロ終了する（パイプ全体が I6 で止まる）
5. **stdout 以外へ secret を出さない。** stderr に自分の診断を書くのは構わないが、そこに secret 本体（や、それを含みうる入力行）を反射させてはならない

**方言（rev.5 で明文化）** — rev.4 までは「dotenv 形式」としか書いておらず、パーサの実装がそのまま契約の定義になっていた。契約側から固定し直す。

- 1 行 1 変数の `KEY=value`。`=` を含まない行はエラー
- 鍵名は `[A-Za-z_][A-Za-z0-9_]*`。外れたらエラー
- 値は任意。**最初の `=` より後ろは全て値**（`DATABASE_URL=postgres://u:p@h/db?a=b` が壊れない）
- 値全体が対応する単一引用符または二重引用符で囲まれていれば剥がす。**エスケープ（`\"`）と複数行値は非対応**
- 改行は LF / CRLF のどちらでもよい（行末の CR は剥がす）
- 空行と `#` で始まる行は無視する
- `export ` 接頭辞は**非対応**
- 空値（`KEY=`）はエラー。取込件数 0 もエラー（I6）

参照実装: **標準は Bitwarden CLI**（`templates/host/broker-bitwarden.sh`。rev.9 の実測で確定 — D30。bw は native ビルドを版 pin + SHA-256 照合で固定パスへ置く。カンマ区切りの複数項目マージに対応し、チーム共有の鍵束と個人の鍵束を別項目に分けて「共有→個人」の順で並べると、取込側の後勝ちにより個人側が同名キーを上書きする。unlock は 1 回）。macOS 単独の代替は `security` CLI（Keychain 項目は Secure Enclave 由来の鍵で暗号化され、ACL で毎回確認 / Touch ID / 常時許可を選べる。dotenv 全文を **base64 で 1 項目に**格納する — `-w` の対話登録プロンプトは 1 行しか受け付けず、複数行の dotenv をそのまま渡すと全体が 1 行に潰れて最初の変数の値として取り込まれることを実測した。rev.9。あわせて登録時は `-T ""` で信頼アプリを空にする — 省くと作成アプリが信頼リストに入り、以後の取得が認可プロンプトなしで通り契約 3 が静かに消える。取得時プロンプトが 2 回出る現象は partition list — Sierra 以降の第 2 認可層 — によるもので、`apple-tool:,apple:` を設定すると項目 ACL の 1 回だけになる。いずれも実測済みで、登録ツール `broker-macos-keychain-set.sh` が格納から partition list 設定までを行う）。Windows は Credential Manager 直接よりも 1Password / Bitwarden 等の CLI（生体認証アンロック + dotenv 出力）が実務的。**SOPS は不採用**: 標準の age 運用は復号鍵を `~/.config/sops/age/keys.txt` に平文常駐させるため契約 2 に違反する。KMS / ハードウェアプラグインを足せば回避できるが、鍵束を git 管理しない以上、ファイル暗号化ツールを挟む動機自体がない。

- broker の stdout → パイプ → prod-entrypoint.sh の stdin へ直結し、entrypoint が**コンテナ内 tmpfs**（`/run/secrets/<VAR名>`、umask 077）へ書く（§4.6）。恒久平文ファイル（旧 `~/.config/<project>/.env.container`）は廃止する。
- 環境変数を一切経由しないため、ホストシェルの environ（I2）にも、compose プロセスの environ にも、`docker inspect` の `Config.Env`（T4）にも現れない。
- `GIT_REPO` / `GIT_REF` は秘匿情報ではないため通常の環境変数で渡す。

平文が存在する箇所は、① broker プロセスのメモリ、② カーネルのパイプバッファ（RAM）、③ prod container 内の `/run/secrets`（tmpfs）、④ shim 実行中の対象プロセスの environ、の 4 箇所に限定され、いずれも不揮発ストレージに触れない（I1）。

制約: stdin を secret の**搬送路**に使うため、**`run` の対話 TTY と両立しない**（`-T` で pseudo-TTY を無効化し、entrypoint が stdin を EOF まで消費する）。これは broker の選定（Keychain / 1Password 等）とは無関係で、搬送路が stdin である限り何を上流に置いても変わらない（broker の認可プロンプトは GUI ダイアログであり stdin を使わないため、パイプとは干渉しない）。prod 運用は非対話の一発コマンド（`pnpm deploy`、`dotenvx get` 等）に寄せる。対話シェルが必要な場合は、注入完了後に `docker exec -it` で入る二段構えを標準手順とする（§6.4。rev.9 で確定）。

#### 代替（Linux ホスト限定・記録として）

`file:` ソース + ホスト tmpfs（`/dev/shm` 配下に mktemp → 書込 → compose run → 削除）であれば、compose の宣言性と TTY を保ったまま I1 を満たせる。`file:` ソースは本物の bind mount であり `read_only: true` とも共存する。ただし macOS にはネイティブ tmpfs がなく、Docker Desktop のファイル共有設定にも依存するため、実行ホストが Linux に一本化された場合のみ再検討する（§11）。trap による削除が fail-open である点は残るが、残留先が RAM のため再起動で消える。

### 4.2 compose 定義

```yaml
# compose.prod.yaml — dev 側の compose ファイルとは完全に分離する
services:
  prod:
    image: ghcr.io/himorogy/runtime-base@sha256:<digest>
    entrypoint: ["/usr/local/bin/prod-entrypoint.sh"]
    working_dir: /src
    environment:
      GIT_REPO: ${GIT_REPO:?GIT_REPO is required}
      GIT_REF:  ${GIT_REF:?GIT_REF is required}
      # 未設定が既定の安全な状態なので `:?` にしない（rev.7）
      PROD_ALLOW_MUTABLE_REF: ${PROD_ALLOW_MUTABLE_REF:-}
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /src:exec,uid=1000,gid=1000,mode=0755
      - /run:uid=1000,gid=1000,mode=0755
      - /tmp:uid=1000,gid=1000,mode=1777
      - /out:uid=1000,gid=1000,mode=0755
      - /home/node:uid=1000,gid=1000,mode=0755
    ulimits:
      core: 0
    logging:
      driver: "none"
```

`volumes:` は持たない。**`/src` は named volume ではなく tmpfs である**（rev.5。D18）。

- `secrets:` ブロックは持たない（§4.1 で却下）。`/run` を tmpfs にし、entrypoint が `/run/secrets/` を作る。
- `${VAR:?}` により、`GIT_REF` 未指定なら compose 自体が失敗する（I7 / I6）。
- **`PROD_ALLOW_MUTABLE_REF` は passthrough する（rev.7）。** これを欠くと D21 の脱出口がホストの環境変数から entrypoint へ届かず、`PROD_ALLOW_MUTABLE_REF=1` を指定したはずなのに拒否される。fail-closed 側なので事故にはならないが、D21 の設計と食い違う。

#### この compose ファイルは「守られていること」を自分では検査しない（rev.7）

ここに書かれた `read_only` / `tmpfs` / `ulimits` は、**一行の変更で静かに外せる**。特に危険なのが `/src` を named volume に戻す変更で、「毎回 clone して依存を落とし直すのは遅い」という性能上の動機から `volumes: [prod-src:/src]` を足すのは自然な一行であり、`read_only: true` を維持したままでも成立してしまう。そして**起動も deploy も正常に成功し続けたまま** N-2（前回実行の信頼しないコードが `.git/config` に仕込んだ `core.fsmonitor` が、`GH_TOKEN` 破棄より前の entrypoint 自身の git 操作で発火する。CI で 8 回の発火を実測済み）と R6 が復活する。`/run` 側の変種では平文 secret が writable layer（= 不揮発ディスク）へ書かれ、I1 が沈黙のまま破れる。

compose ファイル自身にこのドリフトを止める手段はないため、**検査は entrypoint 側に置く**（§4.6 の自己検査）。ラッパーや compose を迂回されても効く場所に置く、という D21 と同じ判断である。

#### tmpfs のマウントオプション（rev.5。全て実測）

rev.4 までの素の短縮形 `tmpfs: ["/run", "/tmp", "/out", "/home/node"]` は**そのままでは動かない**。実測（Docker Engine 28.0.4 / Compose v2.38.2）:

```
素の短縮形:  tmpfs on /src type tmpfs (rw,nosuid,nodev,noexec,relatime,mode=755,inode64)
             → root:root 所有。USER node の entrypoint が /run/secrets を作れず起動直後に失敗
             → noexec。/src 上の実行ファイルが動かない
uid/gid 付き: 755 node:node。mkdir が通る
exec 付き:    (rw,nosuid,nodev,relatime,...) noexec が消え、/src 上の実行ファイルが動く
```

- **所有権**: 素の tmpfs は root:root で作られる。`read_only: true` の下ではコンテナ起動後に chown する手段がない（prod に root への昇格経路を意図的に持たせていないため）。`uid=`/`gid=` を明示する。既定 mode が 1777 だという推測は**誤り**で、実測は 755 だった。
- **`noexec`**: docker の tmpfs は既定で `rw,nosuid,nodev,noexec` が付く。**`uid=`/`gid=`/`mode=` を渡しても `noexec` は残る**。消すには `exec` の明示が要る。
- **`/src` には `exec` が必須。** これが無いと `node_modules/.bin` 配下の実行ファイルが一切動かず（`sh: 1: tsup: Permission denied`、rc=126）、ビルドも deploy も成立しない。`/src` は信頼しないコードを**実行するための場所**であり、noexec にする意味は元々ない。
- **`/run`（secrets）と `/out`（成果物）は noexec のまま**にする。ここで何かを実行する用途はない。
- `/tmp` も noexec のままとする。一時ファイルを実行する種類のツール（node-gyp 等）が踏む可能性はあるが、実際に踏むまでは絞っておく。
- 記法は `docker run --tmpfs` と同じ `<path>:<options>` の短縮形を使う。compose spec の long syntax（`type: tmpfs` の `tmpfs:` サブキー）は `size` / `mode` しか規定しておらず `uid`/`gid` の可搬性に確証が持てないため。短縮形は dockerd の Mount API にオプション文字列としてそのまま渡る。
- `user: "1000:1000"` はイメージが `USER node` で終わるので本来冗長だが、tmpfs の `uid=` と実行 UID を一致させる意図をこのファイル単体で読めるようにするため明示する。**片方だけ変えると起動しなくなる**ので、変更時は必ず両方を直す。
- `size=` は指定しない。既定はホスト RAM の 50%（CI ランナーでは 7.9G）。実行ホストのメモリ量に比例するため、`node_modules` と store を載せるだけの余裕があるかは実行ホスト側の問題になる（§11）。

### 4.3 shim（I3 / I6）

secret を環境変数として常時保持せず、実行時にのみ注入する。**PATH 上の実行ファイル**として置く。

```sh
#!/bin/sh
# /usr/local/bin/wrangler  （実体は /opt/tools/bin/ に退避）
set -eu
f=/run/secrets/CLOUDFLARE_API_TOKEN
if [ -e "$f" ]; then
  [ -s "$f" ] || { echo "empty secret: $f" >&2; exit 1; }
  # 読み取りは exec の引数内ではなく独立した文で行う（rev.4。下記）
  v=$(cat "$f") || exit 1
  [ -n "$v" ] || { echo "empty secret: $f" >&2; exit 1; }
  exec env -u NODE_OPTIONS \
    CLOUDFLARE_API_TOKEN="$v" /opt/tools/bin/wrangler "$@"
fi
exec env -u NODE_OPTIONS /opt/tools/bin/wrangler "$@"
```

- **シェル関数では不可。** `pnpm run` / Makefile / `xargs` は `sh -c` を起動して rc を読まないため関数はスコープ外になり、素のバイナリが呼ばれる。PATH 上の実行ファイルであればこれらの経路でも効く。

#### 実体を `/opt/tools/bin` へ退避する（rev.5。PATH 順の罠）

イメージの PATH は `${PNPM_HOME}/bin:${NPM_CONFIG_PREFIX}/bin:${PATH}` であり、**npm global bin が `/usr/local/bin` より先に来る**。`dotenvx` と `wrangler` は npm global install なので、実体を残したまま `/usr/local/bin` に shim を置いても **PATH 解決で負けて素通りされる**。しかもその失敗は**何のエラーも出さない** — secret が注入されないまま実体が走り、下流の認証失敗として初めて表面化する。

- 実体は `/opt/tools/bin`（**PATH には載せない**）へ退避する。npm がグローバル領域に張る bin は相対シンボリックリンクなので、単純な `mv` ではリンク切れになる。`readlink -f` で絶対パスの実体を解決してから張り直す。apt 由来（`gh`）は `mv` で足りる。
- **ビルド時に `command -v` で検証を焼く。** `RUN [ "$(command -v dotenvx)" = /usr/local/bin/dotenvx ]` 等。PATH 順や配置が変わった時点でビルドが落ちる。これが唯一の防波堤になる（docker 不要の単体テストは shim の三値意味論しか検証できず、PATH 解決の勝敗はビルドしてみないと分からない）。
- push されたイメージに対しても CI の smoke test で同じ検証を行う。ビルドキャッシュや将来の変更で焼き込み検証が飛ぶ余地を潰すため。

#### `pnpm run` の内側では効かない（rev.5。D5 の訂正）

rev.4 までの「PATH 解決を経由する shim であれば**全経路で効く**」は**誤り**だった。`pnpm run <script>` は `node_modules/.bin` を PATH の**先頭**に積む。プロジェクトが `@dotenvx/dotenvx` をローカル依存に持っていると、script 内の `dotenvx` はそちらへ解決され shim は素通りされる。既存の 4 リポジトリはいずれもローカルに持つため、必ず踏む。

したがって **prod では dotenvx を最上位に置く**ことを運用の要件とする（実測で確認済み）。

```sh
# 効く — 最上位の dotenvx が shim に解決され、export した鍵を子プロセスが継承する
prod-run.sh dotenvx run --strict -f .env.prod -- pnpm deploy

# 効かない — pnpm が node_modules/.bin を先頭に積み、ローカルの dotenvx が呼ばれる
prod-run.sh pnpm deploy
```

この制約は shim 一般の性質であって dotenvx 固有ではない。`wrangler` / `gh` をローカル依存に持つプロジェクトでも同じことが起きる。**「最上位に置く」だけでは守られない**（規約は破られる）ため、破ったときに何が起きるかが重要になる。dotenvx の場合は D20 の `--strict` がそこを埋める。

**rev.9 追記（D31）**: dev 実機の実測（npm scripts 内の `which dotenvx` / `which wrangler` がローカル `.bin` を返す）を受け、npm scripts の側から shim を確実に通す経路として **明示呼び名 `_dotenvx` / `_wrangler` / `_gh`** を追加した。同一ファイルへのリンクで、shim が呼び名（`$0`）を見て注入後の実体解決先を切り替える — 素の名前は従来どおり `/opt/tools/bin` の実体へ（PATH 遮蔽）、`_` 付きは **PATH 解決に任せる**。npm scripts 内では `node_modules/.bin` が先頭にあるため、`_dotenvx run -f .env.dev --strict -- next dev` と書けば**プロジェクトが pin したローカル版が鍵注入付きで動く**（ローカル版が無ければ遮蔽 shim 経由で実体に落ちる。名前が一度だけ変わるので無限再帰しない）。三値意味論は呼び名によらず同一。`--strict` 等のフラグ選択は従来どおりスクリプト作者に残る（wrapper への焼き込みは D20 が退けた `--convention flow` 破壊を再導入するため行わない）。
- **shim は環境を判別しない。** 意味論は「`/run/secrets/<VAR>` が存在すれば注入・存在するが空ならエラー・不在なら素通し」の三値で、prod / dev のどちらでも同一に振る舞う。prod では entrypoint が prod secret を書き（§4.6）、dev では dev 環境向けの `GH_TOKEN` / `CLOUDFLARE_API_TOKEN` が同パスへのファイル注入で与えられる（§4.9。rev.9 で env var 注入の廃止を決定）。素通し時はプロセス環境をそのまま引き継ぐため、移行が済むまでの env var 注入とも両立する。
- 空ファイルの即エラーは compose の空値無言スキップ（§4.1）と同型の事故への防御である（I6）。**ファイル不在の素通しは fail-open ではない**: prod container では `/home/node` が tmpfs で毎回空であり、`~/.wrangler` / `~/.config/gh` 等の fallback 資格情報が存在しえないため、必要な secret を欠いたコマンドは下流の認証失敗として顕在化する。加えて entrypoint が取込件数 ≥ 1 と各値の非空を検証する（§4.6）。
- `env -u NODE_OPTIONS` については §4.4 を参照。
- `$( )` は末尾改行を除去するため、secret ファイルの trailing newline は自動処理される。
- **読み取りは `exec` の引数内に置かない（rev.4 で修正）。** `exec env VAR="$(cat "$f")" ...` の形だと、`cat` が失敗しても終了コードは外側の `env` のものになり、`set -e` は発火しない。結果として「ファイルは存在し非空だが読めない」状態が**空値の注入**として素通りする — I6 が排除したい「沈黙した成功」そのものである。`v=$(cat "$f") || exit 1` と独立した文で読み、非空を再検査してから `exec` する。dotenvx shim の `export "NAME=$(cat "$f")"` も同型（終了コードは `export` のものになる）なので同じ分解が要る。
- **素通し側にも `env -u NODE_OPTIONS` を付ける。** §4.4 の diagnostic report 遮断は secret 注入の有無と無関係に効くべきものである。
- dotenvx 用 shim は**固定 1 変数ではなく `DOTENV_PRIVATE_KEY_*` の汎用ループ**にする。鍵変数名は環境ごとに異なり（`_PROD` / `_DEVELOPMENT` / `_LOCAL`）、prod container には `_PROD` だけが、dev container には dev 向けの鍵だけが `/run/secrets` に置かれる。shim を環境別に分けない理由は D5 と同じ: shim は PATH 上で実体と同名（`dotenvx`）を名乗ることで `pnpm run` / Makefile 内の呼び出しを無改変で横取りしており、別名コマンド（`dotenv-prod` 等）にすると既存スクリプトの `dotenvx` 呼び出しが素のバイナリへ直行して shim を素通りする。複数の鍵が同時に注入されても、dotenvx は `-f` のファイル名規約（`.env.prod` → `_PROD`）で正しい鍵を選ぶ。

```sh
#!/bin/sh
# /usr/local/bin/dotenvx  （実体は /opt/tools/bin/ に退避）
set -eu
for f in /run/secrets/DOTENV_PRIVATE_KEY_*; do
  [ -e "$f" ] || continue          # glob 不一致（ファイルなし）は素通し
  [ -s "$f" ] || { echo "empty secret: $f" >&2; exit 1; }
  v=$(cat "$f") || exit 1          # export の中で読むと cat の失敗が消える
  [ -n "$v" ] || { echo "empty secret: $f" >&2; exit 1; }
  export "${f##*/}=$v"
done
# --strict の欠落を警告する（rev.7 / D22）。強制はしない
exec env -u NODE_OPTIONS /opt/tools/bin/dotenvx "$@"
```

#### `--strict` の欠落を警告する（rev.7 / D22）

D20 は `--strict` を**イメージ側で強制しない**と決めた。判断は維持する — shim はプロジェクトの env 構成を知らない層であり、`--strict` は `--convention flow` のような正当な重ね掛けを壊す（実測で確認済み。D20）。**しかし「強制しない」は「黙る」を意味しない。** `--strict` を欠いたときの失敗は rc=0 で暗号文が値として注入されるという静かなものなので（R12）、忘れたことに気付く機会が一度もない状態になる。

以下を**全て**満たすときだけ、実体を exec する前に stderr へ 1 行（3 行に折り返す）警告を出す。

- 引数に `run` サブコマンドがある
- 引数に `--strict` がない
- `/run/secrets/DOTENV_PRIVATE_KEY_PROD*`（glob）に一致するファイルが存在する

三つ目は rev.9 で固定名 `_PROD` から広げた。dotenvx のファイル名規約は `.env.prod` → `_PROD`、`.env.production` → `_PRODUCTION` であり、固定名では後者の命名を使うプロジェクトで prod 鍵が注入されているのに警告が黙る。`_LOCAL` / `_DEVELOPMENT` は接頭辞 `PROD` に一致しないため誤発火しない。

```
dotenvx: WARNING: production key is injected but --strict
dotenvx:   is absent. dotenvx exits 0 even when decryption
dotenvx:   fails, injecting the ciphertext as the value.
```

**これは環境の判別ではなく、注入済み鍵の観測である。** shim が既に行っていること（`/run/secrets/DOTENV_PRIVATE_KEY_*` を見る）の延長にすぎず、D15 の三値意味論とは矛盾しない。prod 鍵は dev container には来ない設計なので、dev 側でのノイズはゼロになる。`--convention flow` も `--ignore=` も壊さない。R12 の「静かな失敗」が「うるさい成功」に変わるだけで、強制なしに I6 の趣旨を回収できる。
- dotenvx には raw な鍵ファイルを直接読む仕組みがない（`-fk` は dotenv 形式のファイルを要求する）ため、shim による env 注入が正当な経路である。なお dotenvx は私鍵 env が無い場合 `.env.prod` に隣接する `.env.keys` へ**自動フォールバック**するため、workspace 内に `.env.keys` が存在しないことの検査は移行後も維持する（共有スキャナが担う。§8.2）。
- **注入済みの鍵名を対話シェルで表示する（rev.6）。** `/run/secrets` のファイル名は環境変数名そのものなので、**名前だけなら安全に出せる**（値は出さない）。対話シェルの起動時に一覧を出し、`/run/prod-ref` があればそれも出す。

  これが効くのは dev である。`DOTENV_PRIVATE_KEY_LOCAL` は持つが `_DEVELOPMENT` は持たない、という**権限階層**を鍵束で表現する運用があり、持っていない鍵を要する操作は復号失敗として現れる。何が注入されているかが見えれば、原因の切り分けが早い。「持っているべき鍵の一覧」はプロジェクト固有なので runtime-base には持てない — **注入済みのものを列挙するだけ**に留め、無いものは映らないことで気づかせる。

  置き場所は `/etc/bash.bashrc` から source する形にする。`profile.d` はログインシェルでしか読まれず、`docker exec -it <c> bash` が非ログインであるため取りこぼす。devcontainer-base では `/etc/zsh/zshrc` にも足す。
- **`DOTENV_PRIVATE_KEY_*` の env 注入が 2.x でも効くことは実測済み**（`get` / `run` の双方、shim 経由・複数鍵同居・`-f` によるファイル名規約での鍵選択を含む）。2.0.0 が `run` / `config` / `get` を `@dotenvx/primitives` 由来の共有 resolver 経由へ付け替えた影響は無かった。1.x で暗号化したファイルを 2.x が復号できることも確認した。

### 4.4 意図しない書き出しの遮断（T5）

| 経路                       | 実態                                                                                                               | 対処                                                                                |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Docker のログドライバ           | 既定の `json-file` はコンテナの stdout/stderr をホストの `/var/lib/docker/containers/<id>/<id>-json.log` に書く。TTY 付きアタッチでも記録される | `logging: driver: "none"`。アタッチ時の表示は attach ストリーム経由なので手元には出る。失うのは `docker logs` のみ |
| コアダンプ                    | `/proc/sys/kernel/core_pattern` は名前空間化されておらず、`|systemd-coredump` 等になっていればコンテナ内プロセスのコアが**ホスト側に**書かれる              | `ulimits: core: 0`。コンテナ作成時の rlimit なのでシェルを経由しない起動パスにも効く                           |
| Node の diagnostic report | `environmentVariables` セクションを含む。既定 off だが `NODE_OPTIONS` が `.npmrc` や親環境から混入しうる                                  | shim で `env -u NODE_OPTIONS`                                                      |
| エージェントのセッションログ           | Claude Code の `~/.claude/projects/*.jsonl` は tool_result を平文で保存し、以降の全ターンでモデルに再送する                                | prod container にエージェントを置かない。dev 側では「エージェントに secret を stdout させない」運用で対処            |
| ターミナルのスクロールバック           | 通常は RAM。セッション復元・自動ログ保存・`script(1)`・tmux `pipe-pane` を有効にしている場合のみディスクへ。メモリ逼迫時は swap 経由で落ちる                        | 該当設定の棚卸し。実行はメモリに余裕のあるホスト側に寄せる                                                     |
| シェル履歴                    | コマンドのみ記録され値は残らない                                                                                                 | 対処不要                                                                              |
| dotenvx 2.x の外部連携          | `dotenvx run --help` に `--no-armor` / `--no-native` / `--no-1password` / `--no-bitwarden` が並ぶ。**いずれも既定で有効**で、無効化フラグの側が用意されている。Armor は Dotenvx のホスト型サービスであり、`.env` 内の参照や token の解決でネットワークへ出る経路になりうる。1.x にはこれらの機能自体が無く、2.x へ上げたことで増えた面である | prod では `--no-armor` を付ける。`--no-native`（OS キーチェーン）はコンテナに実体が無いので実害はないが、意図を明示する意味で併記する。強制の機構は §11 |

### 4.5 イメージ二層化（I5）

```
images/runtime-base/       node + pnpm + dotenvx + git + wrangler + gh + shim + prod-entrypoint.sh + git hooks + egress-guard
images/devcontainer-base/  FROM runtime-base:1.4.2 — crit / herdr / helix / delta / ax / eza / エージェント類
```

- prod のレイヤ集合が dev のレイヤ集合の真部分集合になり、**prod のサプライチェーン面積が dev を超えないことが構造的に保証される**（I5）。共通の第三の base を両者が継承する構成ではこの性質は得られない。
- **dotenvx と復号ランナーを runtime-base に焼き込むことは、アプリ依存グラフからの分離でもある**。復号処理が app の `package.json` / lockfile / postinstall と別のサプライチェーンに乗るため、dev が依存を差し替えても復号ツール自体は汚染されない（R10 (c) の構造的裏付け）。ただし checkout 済みコードが prod 内で `npm i -g dotenvx@evil` 等で PATH を上書きする余地は残るため、prod での動的インストールは禁止する。
- prod は base を `sha-<commit>` で pin し、devcontainer は `:1` を追随する。prod イメージは「変わらないこと」に価値がある。
- `images/devcontainer-base` の名称は「devcontainer 用の base」として引き続き正確なので変更しない。

#### 配置規約: 能力は最小に、制約は最大に

| 種別                   | 例                                                        | 配置                                  |
| -------------------- | -------------------------------------------------------- | ----------------------------------- |
| **能力** — できることを増やすもの | エージェント、crit、helix、delta、ax、eza                           | prod で使わないなら runtime-base に**入れない** |
| **制約** — できることを減らすもの | git hook、`core.hooksPath`、rlimit、`read_only`、egress ポリシー | **全層に入れる**（= runtime-base に置く）      |

I5 が守っているのは攻撃面であり、制約を足しても攻撃面は増えない。したがって「prod で実行しないものは入れない」は能力にのみ適用する。

制約を下層に置く積極的な理由は、**「prod で実行しない運用であるはずだが、実行できてしまう」経路を塞ぐこと**にある。運用上コミットが prod で起きない前提であっても、起きた場合に検査が効く状態にしておく。実装上も `core.hooksPath` は `--system`（`/etc/gitconfig`）に書くため、どの層が `/etc/gitconfig` を持つかを一箇所に確定させたほうが破綻しない。

**制約を置いた場所の所有権も規約の一部である（rev.7）。** hook ファイル自体を root 所有 0755 にしても、親ディレクトリが node 所有なら `mv` でディレクトリごと差し替えられる。ビルド時の `chown -R` は node が実際に書く必要のある範囲（`${PNPM_HOME}` と `${NPM_CONFIG_PREFIX}`）に限定し、`/usr/local/share` のような制約の置き場を巻き込まない。実害の大きさは小さい — コミット前検査はそもそも `--no-verify` で素通りする緩和策であり（R8）、prod では `read_only` により成立しない — が、「制約は改変されにくい場所に置く」という配置意図と食い違ったままにしない。

**確認済み（rev.3）**: 本 repo の active な devcontainer は claude-code を devcontainer Feature（`ghcr.io/anthropics/devcontainer-features/claude-code`）で導入しており、Features はイメージビルド時に焼き込まれる。したがって**旧構成の `IMAGE="<project>-devcontainer"`（devcontainer CLI の出力イメージ）を prod に流用することは不可**で、runtime-base の新設は必須である。

#### `sudo` の受容（rev.5 で明文化）

runtime-base には `sudo` が入る。egress-guard の sudoers ルール（`NOPASSWD` で `init-project-firewall.sh` のみ、引数なし）が要求するためで、**egress ポリシーという「制約」の従物**として置いている。純粋な能力としては例外にあたる。

- `sudo` は setuid root バイナリであり、prod の攻撃面としては最大の追加物になる。sudoers が許すのは引数を取らない固定スクリプト 1 本のみで、`compose.prod.yaml` は `cap_add` を持たないため実行しても失敗するだけだが、`sudo` 自体の CVE 面は残る
- I5（部分集合）は構成上自明に成立している。問題は「能力は最小に」との整合であり、**§11 の「prod への egress-guard 適用」が決まるまでの暫定として受容する**
- egress-guard を prod に適用しないと決めた場合、`sudo` と sudoers と firewall スクリプトを runtime-base から devcontainer-base へ移すのが筋になる

#### pnpm の store（rev.5）

`read_only: true` の下では `$PNPM_HOME/store`（= `/usr/local/share/pnpm/store`）を作れず、`pnpm install` が `ENOENT` で落ちる。store は書ける場所（tmpfs）へ向ける必要がある。置き場所は **node_modules と同一の tmpfs マウント**でなければならない（D19）。

設定は**同じ値の 2 形式への直書き**（`$HOME/.config/pnpm/config.yaml` に `storeDir: /src/.pnpm-store`、`$HOME/.config/pnpm/rc` に `store-dir=/src/.pnpm-store`）で行う。前者は v11 系が、後者は self-switch した v10 系の install が読む（いずれも実測。下記）。**rev.9 変更（D32）**: 当初は `pnpm config set store-dir <path>`（実測で確認した手段）を entrypoint が呼んでいたが、実機で落ちた — pnpm（9.7+）は cwd の `package.json` の `packageManager` を見て**自分自身をその版へ切り替える**（self-switch）。entrypoint のこの行は clone 後の `/src` で走るため、プロジェクトが別系列（実例: `pnpm@10.9.0`）を pin していると `config set` は切替先の版の挙動で走り、read_only の既定 store（`$PNPM_HOME/store`）を mkdir しようとして ENOENT で死ぬ（実測 2026-08-08。空の `/src` では再現せず、`packageManager` 付き `package.json` を cwd に置くと再現）。pnpm を起動しなければ self-switch も起きない。config.yaml の内容は `pnpm config set` の書き込み結果（下記実測）の再現。rc（ini）を併記するのは実機 install での追加実測による — self-switch した v10 系は、`pnpm store path` こそ config.yaml を読んで正しい値を返すのに、**install の store controller は rc しか読まず**既定 store の mkdir で ENOENT 死する（2026-08-14）。観測コマンドの結果を根拠に config.yaml 単独へ削って一度失敗した。**権威は install 自身**。

- 環境変数 `npm_config_store_dir` は**効かない**
- 書き込み先は **`$HOME/.config/pnpm/config.yaml`** で、形式は **YAML**（`storeDir: <path>`）。`.npmrc` の `store-dir=` ではない。手で `$HOME/.npmrc` や `$HOME/.config/pnpm/rc` に置いても効かないのは、ファイル名と形式の両方が違うため（この段落は v11 系の実測。self-switch した v10 系の install は逆に `rc` の `store-dir=` を読む — rev.9 の実機実測、上記）
- **イメージには焼かない。** dev container の store は `/workspaces/.pnpm-store` にあり `/src` は存在しないため、runtime-base に焼くと devcontainer-base 側が壊れる。prod だけに効かせるため、entrypoint が実行時に設定する（§4.6）。`$HOME` は tmpfs なので毎回新規に書かれる

### 4.6 ワークスペース（I4 / I7）

bind mount を廃止し、prod container 内で clone する。secret の取り込みも entrypoint が担う。

**コード片は載せない（rev.7 で方針変更）。** rev.6 まではここに entrypoint の縮約版を置いていたが、実装が rev.4 以降 5 回変わる間にこの縮約版だけが取り残され、`=` を含まない行をエラーにしない・CR を剥がさない・単一引用符を剥がさない・鍵名を検査しない、という**契約（§4.1 の方言）に違反した参照実装**が設計書の中に残っていた。流用されれば `/run/secrets/<行全体>` へ書くパストラバーサルになる。実装を逐語コピーして同期を約束するより、**設計内容だけをここに置き、詳細は実装を正典にする**方が破綻しない。

正典: `images/runtime-base/bin/prod-entrypoint.sh`。パースの受理・拒否の規則は §4.1 の「方言」が契約であり、実装はそれを満たす。

**操作の順序**（この順序自体が設計であり、入れ替えてはならない）:

1. `GIT_REPO` / `GIT_REF` の存在検証（`: "${VAR:?}"`）
2. stdin（dotenv 形式）を `/run/secrets/<VAR名>` へ、`umask 077` で書く。件数 ≥ 1 と各値の非空を検証（I6）
3. **自己検査** — `/src` と secret の置き場が tmpfs であること、`/src` が `exec` であること（下記）
4. `GIT_REPO` に資格情報が埋まっていないことの検証（下記）
5. `git init` + `remote set-url` + `fetch --tags --prune`
6. `GIT_REF` の形式検証（完全な commit sha か、`PROD_ALLOW_MUTABLE_REF=1` か。D21）
7. `rev-parse --verify "${GIT_REF}^{commit}"` で解決。**解決先が `GIT_REF` 自身と一致することの検証**（下記）
8. 解決済み sha を stderr と `/run/prod-ref`（0644）へ記録
9. `checkout --detach --force` → `reset --hard` → `clean -xdff` の三段構え
10. `$HOME` が書けることの自己検査 → store-dir を `$HOME/.config/pnpm/config.yaml` へ直書き（D19 / D32。pnpm は起動しない）
11. `rm -f /run/secrets/GH_TOKEN` と `unset GIT_ASKPASS`
12. 引数の存在を検証して `exec "$@"`

順序上の要点:

- **自己検査（3）は secrets 取込（2）の後・git 操作（5）の前。** secret が届いていない状態で先に環境の話をされても診断の役に立たず、git 操作より前に置けば無駄な fetch を避けられる
- **資格情報の検証（4）は `remote set-url`（5）より前。** ここを通すと、その時点で `/src/.git/config` にトークンが書かれる
- **一致検証（7）は記録（8）より前。** 逆だと、拒否した ref が `/run/prod-ref` に `MUTABLE_REF=0` として残る。**記録が嘘をつくのが最も悪い**
- **store の設定（10）は `clean`（9）の後。** store は `/src` の中にあるので `clean -xdff` の対象になる
- **トークン破棄（11）は `exec`（12）の直前。** そこから先が信頼しないコードである

#### tmpfs であることの自己検査（rev.7）

`/proc/mounts` から `/src` と **secret の置き場の親**の mountpoint 行を引き、fstype が `tmpfs` でなければ実際の fstype を名指しして落とす。§4.2 に書いた「一行のドリフトで防御が静かに消える」を、compose を読まない層で検出するための防壁である。

検査対象を `/run` と直書きせず `/run/secrets` から導出するのは、**守りたいのが「`/run` という名前のパス」ではなく「secret を書く先が不揮発ディスクへ落ちないこと」だから**である。導出する方が検査の意図に近く、副次的に単体テスト（`/run/secrets` と `/src` を一時ディレクトリへ書き換えて実行する方式）が実行ホストの `/run` 構成に依存しなくなる — 直書きすると、`/run` が非 tmpfs の mountpoint として現れるホストでテストが落ちる。

- 該当行が**見つかった**が fstype が違う → `exit 1`。named volume へ戻す変更（N-2 と R6 の復活）と、`/run` を writable layer に戻す変更（I1 の破れ）がここで止まる
- 該当行が**見つからない**、または `/proc/mounts` が読めない → **WARNING を出して続行**。既存の noexec 検査は診断目的なので黙ってスキップしてよいが、この検査は I1 / I7 の防壁なので黙らせない
- **残余**: 「`/src` が一切マウントされておらず、コンテナの writable layer がそのまま見えている」構成は該当行が存在しないため警告どまりになる。これが起きるには `read_only: true` も同時に落とす必要があり、単独のドリフトとしては成立しない。またこの検査は entrypoint の単体テスト（`/src` と `/run/secrets` を一時ディレクトリへ書き換えて実行する方式）でも「該当行なし」の経路に入るため、ここを `exit 1` にすると回帰テストが実行不能になる

#### 40 桁 hex を名前とする ref を弾く（rev.7）

D21 の形式検査（40 桁 hex なら `mutable=0`）は**文字列の形しか見ていない**。dev（信頼しない側）が 40 桁 hex 文字列を名前とするブランチ／タグを push し、その hex に対応するオブジェクトは存在しない状態を作れる。`git rev-parse --verify "<40hex>^{commit}"` はオブジェクトが不在なら ref 名として解決を試みるため、`refs/remotes/origin/<40hex>` に落ちて成功しうる。結果として**可変 ref の内容が immutable として実行され、`/run/prod-ref` にも `MUTABLE_REF=0` と記録される** — 記録が嘘をつくのが最も悪い。

`rev-parse` の直後に、`mutable=0` の場合だけ解決結果と `GIT_REF` の一致を検査する。git が出力する sha は小文字なので、比較の前にどちらかへ正規化する。**正規化は形式検査の hex クラスを小文字に絞る形では行わない** — そうすると大文字の完全 sha が「可変 ref」に分類され、`PROD_ALLOW_MUTABLE_REF=1` で通ってしまい意味がずれる。比較の直前に畳む。不一致なら「commit sha に見えるが別のオブジェクトに解決された」ことと解決先を出して落とす。

**この攻撃経路は現行の git では成立しない（rev.7 で実測）。** レビューはこの穴を「未確認」として挙げていたが、git 2.39.5 で実測したところ、40 桁 hex を名前とする ref は `rev-parse` 側が**意図的に無視する**（`refname ... is ambiguous / it will be ignored when you just specify 40-hex` の警告付きで rc=1 になる）。ブランチ（`refs/remotes/origin/<40hex>`）とタグ（`refs/tags/<40hex>`）の両方で確認した。したがって追加した一致検査は、**現行 git に対しては多重防御**である。

それでも入れる理由は、この設計が git の親切心に依存する形になっていないことを構造で示すためである。`rev-parse` の DWIM 規則は git のバージョンや実装（libgit2 系、将来の変更）に属するものであって、本設計が管理できる範囲にない。I7 が要求するのは「明示された ref から復元される」であり、それを外部実装の挙動に預けたままにしない。検査自体は 3 行で、`mutable=0` の経路にしか走らない。

#### `GIT_REPO` への資格情報埋め込みを拒否（rev.7）

`GIT_REPO=https://x:ghp_xxx@github.com/...` の形式を渡されると、`remote set-url` によって `/src/.git/config` に URL が残り、`exec "$@"` 後の信頼しないコードが `git config remote.origin.url` でトークンを読める。`rm -f /run/secrets/GH_TOKEN`（上記 11）の防御が丸ごと空振りになる。

fetch より前に `*://*@*` の形を拒否する。認証は `GIT_ASKPASS` 経由（`/run/secrets/GH_TOKEN`）が唯一の正規経路である。**エラーメッセージに `$GIT_REPO` の値を出さない** — 埋まっているのは資格情報そのものである。ssh URL（`git@github.com:...`）は `://` を含まないためこのパターンには一致しない。

```sh
#!/bin/sh
# /usr/local/bin/git-askpass
set -eu
f=/run/secrets/GH_TOKEN
case "$1" in
  Username*) echo "x-access-token" ;;
  # GH_TOKEN の不在は許容する（public repo の fetch はトークン無しで動くべき）。
  # 認証が実際に必要な場面で欠けていれば、ここで落として顕在化させる（rev.5）
  Password*) [ -s "$f" ] || { echo "GH_TOKEN not provided" >&2; exit 1; }
             cat "$f" ;;
esac
```

- **clone 用トークンは checkout 後に破棄する。** `GH_TOKEN` は clone/fetch に必要だが、その後 `exec "$@"` で走る**信頼しない checkout 済みコード**からも `/run/secrets/GH_TOKEN` として読める（Codex 敵対レビュー #10）。fetch 完了直後に `rm -f /run/secrets/GH_TOKEN` し、`unset GIT_ASKPASS` する。deploy が別途 GitHub 資格情報を要するなら、clone 用とは別スコープ（read-only・単一 repo・短寿命）を deploy 直前に注入する。取得用と実行用の資格情報を同一セッションに同居させない。

- secret ファイル名は**環境変数名そのまま**（`/run/secrets/DOTENV_PRIVATE_KEY_PROD` 等）とし、shim との対応を機械的にする。
- 値の検証（非空・件数 ≥ 1）は entrypoint で行う。compose の失敗に頼らない（§4.1 の空値無言スキップ）。
- `git init` + `fetch` 方式は、前回失敗の残骸で `/src` が非空になっていても壊れない（`git clone` は非空ディレクトリで失敗する）。
- **`GIT_REF` は完全な commit sha を強制する（rev.6 / D21）。** 40 桁 hex 以外は entrypoint が拒否し、`PROD_ALLOW_MUTABLE_REF=1` を明示したときだけ警告して続行する。署名タグは検証機構が未実装で、現状は「タグを許容することでリスクだけが増える」状態にある。タグ運用が必要になったら署名検証と併せて再設計する（§11）。

  判断の根拠は**失敗の性質の違い**である。ブランチ名は「起動した瞬間に何をデプロイしたか分からず、main が動くので後から再現もできない」— 事故は「見たことのないものを流した」になる。sha は「古いかもしれないが既知で再現可能」— 事故は「一度は見たものの古い版を流した」になる。R10 の唯一のゲートが deploy 前の人間のレビューである以上、**レビューした対象と流したものの一致**を切る方を既定にはできない。

  **解決済みの commit sha は必ず記録する。** `rev-parse` の戻り値を stderr に出し、`/run/prod-ref`（tmpfs、sha は秘匿情報ではないので 0644）にも書く。可変 ref を許した場合、これが「何をデプロイしたか」の唯一の記録になる。`logging: driver: none` のため `docker logs` では取れないが、アタッチしている手元には出る。対話二段構え（§11）では entrypoint の出力が detached 側へ行くので、`docker exec` で入ったシェルからは `/run/prod-ref` を読む。

  **起動ラッパーに `git ls-remote` で事前解決させる案は不採用。** ブランチ名の UX と sha の保証を両立できるが、ラッパーにネットワーク経路と（private repo なら）git の資格情報を持ち込むことになる。ラッパーは broker の出力を docker へ中継する以上のことをしない、という位置づけを崩さない。
- **存在しない ref は明示的に落とす（rev.5）。** `git checkout --detach <ref>` は ref として解決できないと引数をパス名と解釈し、`fatal: git checkout: --detach does not take a path argument 'v9.9.9'` という原因の読み取れないエラーになる。fail-closed ではあるが、運用でこれを踏んだ人間は原因に辿り着けない。`fetch` の後に `rev-parse --verify --quiet "${GIT_REF}^{commit}"` で検証する。`GIT_REF` は秘匿情報ではない（通常の環境変数で渡す設計）のでメッセージに含めてよい。
- **`/src` は tmpfs である（rev.5。D18）。** named volume は廃止した。理由は下記「なぜ `/src` を使い捨てるのか」。dev container のマウント対象外であることは変わらない（そもそもホストのディスク上に存在しない）。dev container が Docker socket を持たないこと（§2.1）が I4 の前提である点も変わらない。

#### github.com の認証は credential helper で固定する（2026-08-16 追記。実測。D33）

`GIT_ASKPASS` を設定すれば認証がそこを通る、というのは**誤り**だった。git は credential helper を設定順（system → global → local → 環境変数）に呼び、**最初に資格情報を返した helper で解決を確定する**。`GIT_ASKPASS` はどの helper も答えなかった場合のフォールバックにすぎない。

dev container では VS Code の Dev Containers 拡張が**両方**を握っている。(1) 接続のたびに global の gitconfig へ credential helper を書き込む。(2) 統合ターミナルの environ へ `GIT_ASKPASS` を注入して上書きする。したがって github.com への https 認証は `/run/secrets/GH_TOKEN` ではなく**ホスト側の資格情報**で通り、しかも**成功する**ので気づく契機がない。この文書が排除しようとしている「秘密の取り違えが沈黙した成功になる」形そのものである（プロジェクト側での使用で発見。2026-08-16）。

最初に入れた対策は (1) だけを潰すもの（環境変数で helper を打ち消し、askpass へ落とす）だったが、実機で (2) が残っていることを確認した。統合ターミナルの `GIT_ASKPASS` は VS Code のスクリプトを指しており、`GIT_TRACE=1` にそれが起動される様子がそのまま出る。**環境変数は接続のたびに上書きされるので、イメージの `ENV` では守れない。**

**採る形**: credential helper 側で固定する。helper は設定であり、環境変数による設定は全ての設定ファイルを読んだ後に適用されるため、gitconfig の記述順にも environ の注入にも左右されない。

```
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=credential.https://github.com.helper
GIT_CONFIG_VALUE_0=                                        # 空 = それまでの helper を捨てる
GIT_CONFIG_KEY_1=credential.https://github.com.helper
GIT_CONFIG_VALUE_1=/usr/local/bin/git-credential-gh-token  # 自前を積み直す
```

github.com の helper 一覧が自前 1 本だけになることで、4 つの性質が同時に得られる（すべて実測）。

- **`GIT_ASKPASS` の乗っ取りが無関係になる。** 認証は helper で確定し、askpass に到達しない
- **`store` の宛先が自前 1 本だけになる。** git は認証に成功すると資格情報を `store` で**全ての** helper に配る。VS Code の helper が残っていると、注入した fine-scoped なトークンがそこを経由してホストの資格情報ストアへ書き戻る（実 clone で観測）。打ち消しが先にあるので、この書き戻し先ごと消える。**「自前 helper を `/etc/gitconfig` に置く」案を一度退けた理由はこれだったが、打ち消しと組み合わせれば消える**
- **URL に埋まった username を上書きできる。** `dev.containers.copyGitConfig` が持ち込むホストの `[url ...] insteadOf` で username が固定されても、helper が返す `username=x-access-token` が使われる
- **打ち消しは URL 限定。** github.com 以外のホストの helper は残る

`VALUE_1` は絶対パスにする。helper 名を裸で書くと git は PATH から `git-credential-<name>` を探すが、このイメージの PATH は `${NPM_CONFIG_PREFIX}/bin` が `/usr/local/bin` より先に来る（§4.3 の shim と同じ罠）。

**`/etc/gitconfig` に打ち消しを書く案は不成立**（実測）。system → global の順に読むため、空値で捨てた後に global の helper が積み直される。system より後に読まれる設定ファイルはイメージから固定できないので、環境変数以外に順序で勝つ手段がない。

**トークン不在は `quit=1` で連鎖ごと止める。** helper が「答えない」だけでは足りない — 出力なしの `exit 0` でも `exit 1` でも username だけ返しても、git は次の helper や askpass へフォールスルーしてそこで成功する（実測）。`/run/secrets/GH_TOKEN` が不在・空・読めない場合、helper は stdout へ `quit=1` を出す。git は `fatal: credential helper ... told us to quit` で即座に落ちる。端末プロンプトにも落ちないので、対話シェルで人間がホスト側の資格情報を打ち込んで迂回することも、エージェントがプロンプトの前で無限に待つこともない。「読めない」を空パスワードとして成立させない書き方（読み取り結果を変数に受けてから判定する）は §4.3 の shim と同じ。

**`GIT_ASKPASS` は残す。** github.com は helper で確定するので到達しないが、github.com 以外のホストと prod の entrypoint 経路で使う。

**副次的に N-2 の一角が閉じる。** 環境変数による設定は local を含む全ての設定ファイルより後に適用されるため、打ち消しは `.git/config` に仕込まれた `credential.helper` にも及ぶ。下記 N-2 が「機構は同一である」として残していた窃取経路は、github.com について構造的に消える。さらにトークン破棄後は helper が `quit=1` を返すので、`exec` 後の信頼しないコードから github.com への認証付き操作ができないことが `unset GIT_ASKPASS` だけだった頃より強く担保される。`core.fsmonitor` 等の他の実行経路は残るので、「設定経由の実行経路を列挙して潰すのは筋が悪い」という結論自体は変わらない。

**代償**: `GH_TOKEN` を注入していないコンテナでは、github.com への認証が要る https 操作が失敗する。ホスト側の資格情報へフォールバックしないことが目的なので、これは副作用ではない。public repo の clone（401 が返らないため credential 解決自体が起きない）、ssh remote、github.com 以外のホストは影響しない。

**この防御は黙って外れうる。** `GIT_CONFIG_COUNT` は git が持つ唯一のカウンタで、イメージがスロット 0 と 1 を占有する。利用側が同じ仕組みで設定を足すとイメージの 2 スロットが消え、消えても認証は（ホスト側の資格情報で）通る。`/usr/local/bin/git-auth-check` が対話シェルの起動ごとに実効値を確認し、自前 helper のパスと一致しなければ警告する（`prod-context` から呼ぶ。空なら「askpass へ落ちる」、別物なら「確定先と `store` の宛先を奪われる」と原因を分ける）。到達範囲は prod-context と同じで、非対話の git まではカバーしない。

**VS Code 側の設定も併用する。** `git.terminalAuthentication: false` を雛形の `devcontainer.json` に入れて、environ への `GIT_ASKPASS` 注入自体を止める。github.com はイメージ側で閉じているので必須ではないが、github.com 以外のホストでも注入は起きるため重ねてある。ホストのユーザー設定ではなくコンテナ側に適用される設定なので、雛形から配れる。

#### なぜ `/src` を使い捨てるのか（rev.5。実測に基づく）

named volume を再利用する構成には、**rev.4 の `reset --hard` でも塞がらない**穴が二つあり、いずれも CI で実際に再現した。

**N-1 ref の汚染。** `git fetch --tags` は既存のローカルタグを clobber せず（`--force` が無い）、ローカル branch は fetch の対象外である。したがって前回実行の（信頼しない）コードが `git tag v1.2.3 <evil>` を打てば、次回 `GIT_REF=v1.2.3` で `checkout` も `reset --hard` も**攻撃者の ref を解決する**。三段構えは「汚染された ref へ正しく復元する」だけで、I7 を守らない。実測では 2 回目の実行が指定と異なる commit の内容（`world`）を checkout した。安全なのは完全な commit sha だけで、これは content-addressed なので偽装できない。

**N-2 `.git/config` の持続。** git の設定優先順位は **local > global > system** である。イメージが書く `/etc/gitconfig` は repo の `.git/config` に上書きされる。`core.fsmonitor` のような**コマンドを実行する設定**を仕込まれると、次回の entrypoint 自身の fetch / checkout / reset / clean で発火する。実測では 8 回実行された。しかもその位置は `rm -f /run/secrets/GH_TOKEN` の**前**であり、**トークンがまだ存在する状態で任意コードが走る**。`credential.helper` を仕込めばトークンそのものを受け取れる（この経路は `file://` remote では認証が発生しないため CI では再現できなかったが、機構は同一である。**2026-08-16 追記**: この一角は github.com について閉じた — 上記「github.com の認証は credential helper で固定する」の打ち消しが `.git/config` の helper にも及ぶ）。`filter.*.smudge` + `.gitattributes` も同型。**設定経由の実行経路を列挙して潰すのは筋が悪い。**

tmpfs にすれば毎回まっさらな repo から始まるため、**両方とも構造的に成立しない**（実測で確認: N-1 は `GIT_REF does not resolve to a commit` で fail-closed、N-2 は `fresh .git/config`）。同時に **R6**（prod で走るコードが復号値・CLI キャッシュ・トークンを `/src` へ書けばコンテナ削除後も Docker VM のディスクに残る）も解消する。

代償は毎回の full clone と全依存の再ダウンロードで、RAM も消費する。実測では karakuri 自身で `/src` 合計 79M（rev.5 時点では 131M。依存を 1 パッケージ分減らした差であり、構成の変更ではない。この値はプロジェクトの依存木で決まる）、tmpfs の既定サイズは 7.9G だった。deploy の頻度からして許容できる。

`git init` + `fetch` と三段構えの復元は、tmpfs でも**そのまま残す**。tmpfs が毎回新しいことは `compose run --rm` の挙動に依存しており、その前提が崩れても壊れないようにしておく（多重防御）。前回失敗の残骸から復帰できる性質（`git clone` は非空ディレクトリで失敗する）も維持される。
- **`checkout` だけでは I7 を満たさない（rev.4 で修正）。** `git checkout --detach <sha>` は HEAD が既にその commit にあると working tree を復元せず、tracked file の改変をそのまま残す（`--force` を付けても「切り替えが起きない」ので同じ）。`git clean` が消すのは untracked / ignored だけである。したがって named volume を再利用する構成では、prod で走ったコードが自分のソースを書き換えると、次回同じ `GIT_REF` で起動しても改変済みのコードが実行される。これは R10（dev が書いたコードを prod が実行する）を **前回実行分にまで持続させる**経路であり、I7 の「明示された ref から復元される」が成立しない。`reset --hard "$GIT_REF"` を必ず併記する。三つの役割は重複ではない: `checkout --detach --force` が HEAD を移し、`reset --hard` が tracked を戻し、`clean -xdff` が untracked / ignored を消す。
- **entrypoint は入力を反射しない。** パース失敗時のエラーメッセージに入力行や鍵名を埋めてはならない。broker の出力が壊れて `KEY=` の形になっていない場合、その行は secret 本体そのものでありうる。`logging: none` はホストのログファイルを止めるだけで、アタッチ先の端末への表示（およびそのスクロールバック / 端末ログ、§4.4）は止められない。位置は行番号だけで示す。
- `git clean -xdff` により、前回実行の残留物が持ち越されない。**依存インストールはコマンド側の責務**とする（例: `run -T --rm prod sh -c 'pnpm install --frozen-lockfile && dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy'`）。`-e node_modules` での除外という選択肢は**消えた** — `/src` が tmpfs である以上、run をまたいだ node_modules の保持は元から成立しない。
- **`clean` と `pnpm install` の順序に依存がある。** store（`/src/.pnpm-store`）は working tree の中にあるため `clean -xdff` の対象になる。entrypoint は checkout → clean → `exec "$@"` の順で、`pnpm install` はその後に走るので同一 run 内で消えることはない。この順序を入れ替えてはならない。
- ビルド成果物は `/out`（tmpfs）に出力する。prod 値を埋め込んだ `dist/` は secret そのものを保持するため。
- entrypoint が stdin を EOF まで消費するため、`exec "$@"` 後のコマンドは stdin を受け取れない。stdin を必要とする prod コマンドが現れた場合は搬送方式の再設計が必要（現状該当なし）。
- 相互排他チェックは不要になる。あれは共有 workspace が生んでいた制約であり、prod-shell ごと廃止される。

### 4.7 コミット前検査（T6 / 緩和策）

検査ロジックは**自前の共有スキャナ 1 本**が持つ（`packages/env-guard/bin/env-guard-scan`。D24 / D25）。hook と CI が同じファイルを呼び、違うのは渡すファイル一覧の作り方だけである（hook は staged、CI は tracked）。

**当初は dotenvx 本体の `dotenvx precommit` を使う設計だった。** 外した理由は 2 つあり、どちらも実測で決まった。第一に、`precommit` の検査対象は `git diff HEAD` に現れる差分だけで、差分の無いクリーンな checkout では平文の tracked `.env` を見つけたうえで rc=0 を返す（D23。§8.2）。第二に、自前のファイル名フィルタを持っていてプロジェクト側から上書きできないため、hook にだけ残すと「CI は通るが hook だけ落ちる」という逆向きの分岐を作る（D24）。**hook の文脈で `precommit` 自体は正しく動く** — 壊れているから外したのではなく、判定を 2 つ持たないために外した。

配布は `core.hooksPath` による。`dotenvx precommit --install` のように `.git/hooks/pre-commit` へ書き込む方式は、`.git/hooks` が versioned でないため clone ごとに実行が要り、既存 clone には効かず、改善も伝播しない（D12）。代わりに `core.hooksPath` をイメージに焼く。

```dockerfile
# images/runtime-base/Dockerfile
COPY hooks/pre-commit /usr/local/share/git-hooks/pre-commit
RUN chmod +x /usr/local/share/git-hooks/pre-commit \
 && git config --system core.hooksPath /usr/local/share/git-hooks
```

rev.2 にあった `RUN dotenvx prebuild` は**削除した**。二重に不要である。第一に、`prebuild` は実行時点のビルドコンテキストにある `.env*` を静的走査するだけであり、app コードが存在しない runtime-base のビルド中では「常に緑の no-op」にしかならない。第二に、本設計では app コードと `.env.prod` は**実行時にコンテナ内の tmpfs へ clone される**（§4.6）ため、`COPY` で `.env*` がイメージに焼き込まれる経路自体が存在せず、prebuild が守る脅威が構造的に不成立である。prebuild が意味を持つのは「`.env*` を含みうるビルドコンテキストから app イメージを焼くプロジェクト」だけで、その場合に限り当該アプリの Dockerfile（`COPY` 段の直後）へ置く。本設計の配布物には含めない。

```sh
#!/bin/sh
# /usr/local/share/git-hooks/pre-commit
set -e
root=$(git rev-parse --show-toplevel)

# 判定は共有スキャナ（§8.2 / D24）に一本化する。hook が渡すのは
# 「staged なファイルの一覧」だけで、何を平文と見なすかは持たない
git diff --cached --name-only | <共有スキャナ>

for h in "$root/.husky/pre-commit" "$root/.githooks/pre-commit"; do
  if [ -x "$h" ]; then "$h"; fi
done
```

- **判定は共有スキャナに一本化する（rev.7 / D24）。** hook は「staged なファイルの一覧」を渡すだけで、ファイル名パターン・許可リスト・暗号化の判定・`.env.keys` の再帰検査は全てスキャナ側にある。CI（§8.2）は同じスキャナに tracked な一覧を渡す。**スコープだけが違い、判定は同一。**
- **`dotenvx precommit` は hook から外れる。** rev.6 まではこれが hook の本体だったが、自前のファイル名フィルタを持っていて上書きできないため、プロジェクトごとの上書きを入れた時点で「CI は通るが hook だけ落ちる」という逆向きの分岐を作る。**hook の文脈で `precommit` が正しく動くこと自体は実測で確認してある**（平文 `.env` を staged にすると rc=1）— 外す理由は壊れているからではなく、判定を 2 つ持たないためである。
- **`.env.keys` の検査は再帰で行う（rev.7）。** dotenvx の自動フォールバックは `.env` ファイルに**隣接する** `.env.keys` を拾うため、`apps/backend/.env.keys` は実際に効いてしまう。ルート直下しか見ない実装では monorepo で素通りする — 既存 4 repo は全て monorepo であり、必ず踏む形だった。`find` 自体が失敗した場合は「走査しきれていない以上『無い』とは言えない」として fail-closed にする。
- 全リポジトリ・全 clone・worktree に自動で効き、`--install` は不要になる。イメージタグの更新で伝播する。
- `core.hooksPath` **は全 hook を上書きする。** husky / lefthook を使うプロジェクトが黙って壊れるため、上記のようにチェーンさせる。
- この設定が効いている間、各リポジトリの `.git/hooks/*` は無視される。過去に `--install` で書き込んだ `pre-commit` が死んだまま残るので、「入っているつもりで効いていない」状態を避けるため移行時に掃除する。
- **リポジトリ側から無効化できる（rev.5。実測）。** git の設定優先順位は local > global > system であり、イメージが書くのは system（`/etc/gitconfig`）である。repo の `.git/config` に `core.hooksPath` を書けば**上書きできる**。

  ```
  git -C /src config --show-origin --get-all core.hooksPath
    file:/etc/gitconfig   /usr/local/share/git-hooks
    file:.git/config      /tmp/local-hooks        ← 実効値はこちら
  ```

  したがって `core.hooksPath` は**強制装置ではない**。`--no-verify` でも素通りし、git CLI を経由しない書き込み（GitHub API、libgit2 系）にも効かない。T6 に不変条件を置かず緩和策として扱う判断（§3 / R8）は、この実測とも整合する。予防の本線は §8.2 の CI に置く。同じ優先順位が prod では N-2（§4.6）として現れる。

#### ホスト側からのコミット

`core.hooksPath` は**コンテナ内の** `/etc/gitconfig` に書かれるため、ホストの git はこれを読まない。したがってホストの GUI クライアント（Fork 等）は従来通り `.git/hooks/pre-commit` を参照し、**イメージ焼き込みによってホスト側の hook が無効化されることはない**。両者は独立に動作する。

| 実行場所  | 参照する hook                                                 |
| ----- | --------------------------------------------------------- |
| コンテナ内 | `/usr/local/share/git-hooks/`（イメージ由来）。`.git/hooks` は無視される |
| ホスト   | `.git/hooks/pre-commit`（従来通り）                             |

実際のリスクは、イメージ焼き込みを理由に per-repo の hook 導入（simple-git-hooks 等）を撤去した場合に、**ホスト側だけが無防備になる**ことである。撤去する場合はホスト側の手当てを同時に行う。

#### 方式は A（simple-git-hooks との併用）で確定した（rev.8）

二案あった。**A. 併用** — コンテナは `core.hooksPath`、ホストは既存の simple-git-hooks を維持する。**B. ホストも `core.hooksPath`** — `git config --global core.hooksPath ~/.config/git/hooks` を dotfiles で配布する。

**A を採る。** simple-git-hooks が macOS 実機で動作していることが確認できており、動いている仕組みの上に載せる方が、新しい仕組みを持ち込んで挙動を一から確かめるより速い。加えて B は `.git/hooks/` を丸ごと無視させるため、そのリポジトリが持っている他の hook を黙って殺す。イメージの中でそれが許されるのは、コンテナの中の git 設定という閉じた場所だからである。人のホストの global 設定に対して同じことをするのは筋が違う。

導入は `@himorogy/env-guard` の `env-guard install` が行う。`package.json` の `simple-git-hooks.pre-commit` に hook の呼び出しを 1 行足し、simple-git-hooks を実行して `.git/hooks/pre-commit` を実体化し、**それが実在し実行可能で意図した hook を呼んでいることを確かめてから**成功を報告する。書いただけで「入った」と報告して実際には何も検査されていない状態を作らない。

既に別の `pre-commit` コマンドが設定されていれば**上書きせず落ちる**。既存の検査を黙って消さないためで、合成は人間に委ねる。

#### PATH の問題は測る前に消えた（rev.8）

rev.7 まではここに「GUI クライアントの PATH。Finder / Dock から起動したプロセスはログインシェルの PATH を継承しない」を実測項目として置いていた。**これは測って決める問いではなかった。**

hook は自分自身の場所（`$0`）からスキャナの位置を割り出す。隣の `bin/env-guard-scan` を見て、無ければ `/usr/local/bin/env-guard-scan` を見る。**`PATH` を一度も引かない。** したがって GUI クライアントの `PATH` がログインシェルと違っても、走るスキャナは同じである。

残るのは「見つけられなかったときに何が起きるか」だけで、これは環境の性質ではなく**こちらが書くコードの性質**である。どちらにも無ければ非ゼロで終わる。テストで確かめられる。

同じ理由で「`node_modules` が named volume になっていないか」も、測るべき問いから外れた。named volume ならホストからパスが解決できず、hook の呼び出し（`sh node_modules/@himorogy/env-guard/hooks/pre-commit`）が 127 で落ちる。**落ちる方向なので commit は止まる。** 静かに通る経路がない以上、事前に測る必要はない。

**「静かに失敗しうる」ことが問題だった**という認識は正しかった。効いているつもりで効いていない状態は hook がないより悪い。ただし対処は実測ではなく、静かに失敗しない書き方をすることだった。

### 4.8 出荷物に設計書の記号を書かない（rev.7）

`I6` / `R12` / `D21` / `§4.2` といった記号は、**この設計書の中でしか意味を持たない**。にもかかわらず rev.7 時点の実装は、コンテナのエラーメッセージ・コード内コメント・compose ファイル・README にこれらを埋め込んでいた。他 org へイメージとテンプレートを配布する前提（§1 / §8）である以上、**受け取った側には参照先が存在しない**。「`設計書 R10 / D21` を参照」と書かれた stderr を運用中に踏んだ人間は、何も辿れない。

**この設計書を `.local/` から `docs/` へ移した（rev.8）。** 当初の理由は「設計書が git 管理外にあり誰も辿れない」ことだったが、それは記号だけの問題ではなく、規約が許していた**パス参照も同じく宙に浮いていた**ことを意味する。`.local/` は `.gitignore` の対象なので、clone した人間にも存在しない。記号を消してパス参照に置き換える規約は、参照先が追跡対象になって初めて成立する。

規約:

- **ユーザーの目に触れる文字列**（stderr / stdout メッセージ、CI の出力、テンプレートのコメント）は**単体で意味が通るように書く**。何が期待され、何が実際で、次に何をすればよいかを、記号ではなく言葉で書く。テンプレートは他リポジトリへ丸ごとコピーされるため、`docs/` へのパス参照もコピー先では解決できない — ここには記号もパスも置かない
- **コード内コメント**は設計書をパスで参照してよい（`docs/prod-secret-isolation-design.md §4.6` の形）。ただし記号だけを裸で置かない。パスを添えてもなお、コメント単体で何を言っているかが分かること
- **README** はこのリポジトリに留まるので、`docs/` 配下へのリンクは辿れる。禁じるのは記号だけである
- 設計上の判断の背景を残したい場合は、記号ではなく**その判断の中身を 1 行で書く**。「可変 ref はレビュー対象と実行対象の一致を保証しない」は記号を知らなくても伝わる

**棚卸しは完了した（rev.8）。** 対象は「karakuri の外へ出るか」で切った — イメージが `COPY` するファイル、`templates/**`、README / migration。`.github/workflows/**` と `images/*/tests/**` は対象外とした（読者は必ずこのリポジトリを持っており、緑になっている測定を記号のために書き換える危険に見合わない）。

**再発防止として `images/runtime-base/tests/shipped-symbols.test.sh` を置いた**（`pnpm test` から走る）。上の三段の規約をそのまま検査に落としてある。否定対照を 5 本内蔵し、既知の違反を検知すること・許すべきものを誤検知しないことを毎回確認する。

### 4.9 dev container の鍵注入（rev.9）

dev 鍵（`DOTENV_PRIVATE_KEY_LOCAL` / `_DEVELOPMENT`、dev 用に fine-scope した `GH_TOKEN` / `CLOUDFLARE_API_TOKEN` 等）も prod と同じ broker 方式で注入する（D28）。従来の注入方式 — compose の `env_file` で `dev/.env.container` を読み environ に載せる — には二つの悪い性質がある。

1. **ホスト不揮発ディスク上の恒久平文**である。prod 側が §6.3 で廃止した `~/.config/<project>/.env.container` と同じ形が dev にだけ残っており、バックアップ・クラウド同期にも乗る。
2. **コンテナ environ に常駐**する。`docker inspect` の `Config.Env` で可視になり、全子プロセスへ無差別に継承され、コアダンプ・Node diagnostic report へ落ちる面が開く（dev compose は prod と違い `ulimits: core: 0` も `logging: driver: none` も持たない）。

#### 何を守り、何を守らないか

この変更は **dev container 内のエージェントから鍵を隠すためのものではない**。エージェントは node と同一 UID で動くため、`/run/secrets` を直接読めるし、shim 経由でツールに鍵を使わせることもできる。搬送路をどう変えても「エージェントが鍵の能力を行使できる」は不変であり、そこを守る装置は搬送路ではなく**鍵のスコープ**である。守れるのは上記 1・2 — ホスト上の保管状態と、意図しない書き出し面 — に限る。この限定を理解した上で、増える複雑性（起動後の注入 1 ステップ）と釣り合うと判断した。

#### 経路

dev container は IDE（devcontainer 拡張）が起動するため、prod のような entrypoint への stdin 注入経路が無い。かわりに、**起動済みのコンテナへホストから注入する**。

```sh
# ホスト側。templates/host/dev-inject.sh の骨子
<dev 用 broker> | docker exec -i <dev-container> /usr/local/bin/secrets-ingest.sh
```

- dev 用 broker は prod と同じ契約（§4.1）・同じ実装で、鍵束のサービス名だけを分ける（例: `prj1-dev-env` / `prj1-prod-env`）。
- 取込スクリプトは stdin の dotenv（§4.1 の方言）を `/run/secrets/<VAR 名>`（umask 077）へ書く。shim（§4.3）は三値意味論のまま無変更で効く。plain git の fetch / push は `GIT_ASKPASS=/usr/local/bin/git-askpass` を設定すれば `/run/secrets/GH_TOKEN` を読む — イメージに焼き込み済みで、**dev は prod-entrypoint.sh を通らないため checkout 後破棄（§4.6）の影響を受けない**。
- **dev compose に `/run` の tmpfs が必須である。** `tmpfs: ["/run:uid=1000,gid=1000,mode=0755"]`。これが無いと `/run/secrets` はコンテナの writable layer = ホスト側の不揮発ディスクへ書かれ、恒久平文を廃止した意味が消える。オプション無しの短縮形が root:root 所有になる罠は §4.2 と同じ。
- 注入を忘れた場合は下流の認証失敗として顕在化する（shim は不在素通し）。ただし dotenvx だけは `--strict` を欠くと沈黙する — dev には prod 鍵が来ないため D22 の警告も出ない。dev の運用でも `--strict` を推奨する理由になる。

#### 擦り合わせ結果（2026-08-06 決定・同日実装。各プロジェクトの移行は未実施）

- **取込スクリプトは entrypoint から切り出して共通化する。** prod-entrypoint.sh から dotenv 取込部（方言パース + `/run/secrets` への書き込み + 件数・非空の検証）を `/usr/local/bin/secrets-ingest.sh`（正典は `images/runtime-base/bin/secrets-ingest.sh`）へ切り出してイメージに焼き、entrypoint と `docker exec` の両方が同じファイルを呼ぶ。方言パーサの実装を 1 つに保つ — 2 実装になると、D24 が潰した「判定が 2 つ」と同じ形が搬送路側に生まれる。取込完了時に書き込んだ**鍵名だけ**（値は出さない）を stderr へ出す — §4.3 の「名前だけなら安全に出せる」と同じ判断
- **コンテナは compose project 名から引く**（`docker compose -p <name> ps -q dev` 相当）。`container_name` 決め打ちは、プロジェクト複製時の直し忘れがそのまま「別プロジェクトへの注入」事故になるため採らない
- **再注入は「コンテナを起動するたびに 1 回」が運用になる。** `/run` は tmpfs であり、再作成だけでなく停止 → 再起動でも消える（tmpfs はコンテナ起動ごとに新規マウント）。dev-inject は冪等（再実行は上書き）とし、完了時に書き込んだ鍵名（値は出さない）を stderr へ出す。未注入のまま使った場合は shim の素通しにより下流の認証失敗として顕在化し、対話シェルの注入済み鍵名表示（§4.3）でも確認できる。なお dev-inject は**起動ラッパーではない** — 起動は従来どおり IDE が行い、dev-inject は起動後に打つ注入コマンドである（prod-run.sh が起動そのものを包むのとは役割が違う）
- **plain git の認証**: dev compose の `environment:` に `GIT_ASKPASS: /usr/local/bin/git-askpass` を置く（パスは秘匿情報ではないため env で渡してよい）。GH_TOKEN 不在で認証が要求された場合は非ゼロ終了で顕在化する。**2026-08-16 追記**: github.com についてはこの経路を使わない。credential helper が askpass を先取りし、VS Code は helper と `GIT_ASKPASS` の両方を握るため、認証先はイメージ自前の credential helper に固定してある（§4.6 / D33）。askpass が担うのは github.com 以外のホストと prod の entrypoint 経路。devcontainer-base がどちらも焼き込んでいるので、compose には書かない。
  （2026-08-16 更新: devcontainer-base v2 以降は ENV と `/etc/environment` の両方へ焼き込み済みで、compose には**書かない** — compose の `environment:` は sshd セッションへ届かず（sshd は environ を引き継がず PAM が `/etc/environment` を読む）、経路間で値が食い違うため。base を使わないイメージでは従来どおり compose で設定する。`images/devcontainer-base/PORT-FORWARDING.md` 参照）
- **移行手順**: 鍵束の Keychain 登録 → dev compose の `/run` tmpfs 化 + `GIT_ASKPASS` 追加（devcontainer-base v2 以降は焼き込み済みのため追加不要。上の 2026-08-16 更新を参照） → dev-inject 運用へ切替 → `env_file` 行と `dev/.env.container` の削除、の順。切替と削除を分けるのは、注入漏れの切り分けを env_file が生きているうちに済ませるため（shim はファイルを environ より優先するので、両方が有る期間も動作は file 側で検証できる）

---

## 5. 設計判断

| #   | 判断                                                   | 理由                                                                                                                                                                                                            |
| --- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| D1  | compose secrets（`environment` / `file` / `content` ソースいずれも）を不採用 | `environment` / `content` は CopyToContainer で writable layer（= 不揮発ディスク）に書かれ、かつ `read_only: true` と併用不可（起動失敗）。`file` はホスト上の平文ファイルが前提。docs の bind mount 記述は `file` のみ真（§4.1）                                    |
| D2  | broker の stdout を stdin パイプで直結（環境変数を経由しない）                  | rev.2 の `sops exec-env` は「親シェルの environ を汚さない」ためだったが、stdin 注入では**環境変数自体を経由しない**ため、compose プロセスの environ 露出（旧 R4）ごと消える。broker が dotenv 形式で出力すれば変換も不要                                                    |
| D3  | stdin パイプ方式を**採用**（rev.2 では不採用）                       | 旧判断の根拠「D1+D2 で同じ性質が得られる」が実装調査で崩れた。entrypoint はもともと自前（§4.6）であり、宣言性の追加コストは secret 取込ループ十数行のみ。トレードオフとして対話 TTY を失う（§4.1）                                                                                            |
| D4  | swarm の `docker secret` を不採用                         | `docker stack deploy` では secret がクラスタ上の**長寿命オブジェクト**になる。短命な露出を減らすために永続オブジェクトを増やすのは逆行                                                                                                                           |
| D5  | shim はシェル関数ではなく PATH 上の実行ファイル。**ただし全経路で効くわけではない**（rev.5 で訂正） | §4.3 参照。関数は `sh -c` を起動する経路（`pnpm run` / Makefile / `xargs`）でスコープ外になるため不可。ただし rev.4 までの「PATH 解決を経由する shim であれば**全経路で効く**」は誤りだった — `pnpm run` は `node_modules/.bin` を PATH 先頭に積むため、プロジェクトがローカルに同名の依存を持つと shim が素通りされる（実測）。加えて実体を `/opt/tools/bin` へ退避しないと `${NPM_CONFIG_PREFIX}/bin` に負ける |
| D6  | `profiles:` ではなく compose ファイルを分離                     | dev 用ファイルに prod 鍵への参照を**一行も置かない**状態を作れる（fail-closed）。profiles では参照が残り、prod 鍵を持つシェルから dev を起動できてしまう                                                                                                            |
| D7  | `dotenvx decrypt` を禁止せず、`dotenvx run --` を既定とする      | 「平文がディスクに刻まれるのを防ぐ」を根拠に `decrypt` だけ禁じるのは、ビルド成果物が secret を含んでディスクに書かれる以上、一貫しない。実効的な制御は `read_only` + tmpfs である。加えて、一覧確認は `dotenvx get -f .env.prod` で**ファイルを作らずに**行えるため、`decrypt` には元々用途がない                     |
| D8  | bind mount 廃止・container 内 clone                      | §4.6 参照。dirty working tree を持ち込まないため再現性の点でも上位互換。clone 先は rev.5 で named volume から tmpfs へ変えた（D18）                                                                                                                                                               |
| D9  | 二層継承（共通 base ではなく prod → dev の継承）                    | §4.5 参照                                                                                                                                                                                                        |
| D10 | 雛形は `create-*` 形式のスキャフォールドではなく、冪等な注入コマンド             | §8.4 参照                                                                                                                                                                                                        |
| D11 | git hook は devcontainer-base ではなく runtime-base に置く   | §4.5 の配置規約。hook は制約であり攻撃面を増やさない。運用上 prod でコミットしない前提でも、**実行できてしまう**経路を塞ぐ                                                                                                                                        |
| D12 | `dotenvx precommit --install` ではなく `core.hooksPath`  | §4.7 参照。`--install` は per-clone で伝播しない                                                                                                                                                                         |
| D13 | CI の検査ロジックは reusable workflow に寄せ、プロジェクト側はスタブのみ      | §8.2 参照                                                                                                                                                                                                        |
| D14 | org ruleset / secret scanning push protection に依存しない | プラン限定機能であり、`@himorogy` は下位プラン。また本構成は他 org へも流用するため、プラン依存の前提を置けない（プラン境界の現況は §8.3）                                                                                                                              |
| D15 | shim は環境を判別せず「存在すれば注入・空ならエラー・不在なら素通し」の三値意味論         | shim は runtime-base 経由で dev にも継承される（I5 の帰結）が、dev にも dev 環境向けトークンが注入される想定のため、環境判別（番人変数等）は不要。素通しがプロセス環境を引き継ぐため dev の既存注入方式（env var / ファイル）のどちらとも両立する。prod での fail-closed 性は entrypoint の取込検証と tmpfs な `$HOME`（fallback 資格情報の不在）が担保する（§4.3）                                                                    |
| D16 | `dotenvx prebuild` を本設計の配布物に含めない | runtime-base では app 不在で常に緑の no-op、かつ本設計は app を実行時 clone するため `.env*` がイメージに焼かれる経路自体が無い（§4.7）。app イメージを焼くプロジェクトが現れた場合のみ、そのアプリ Dockerfile に個別配置                                                                                                                              |
| D17 | 鍵束を git 管理せず、各運用者の OS キーチェーン（等の暗号化ストア）に置く。SOPS 不採用 | 束の中身は個人資格情報でリポジトリ共有物ではない。SOPS の標準 age 運用は復号鍵の平文常駐を要求し broker 契約 2 に違反。git 管理をやめればファイル暗号化ツール自体が不要（§4.1）                                                                                                                              |
| D18 | `/src` を named volume ではなく **tmpfs** にする（rev.5） | named volume の再利用には rev.4 の `reset --hard` でも塞がらない穴が二つあり、いずれも実測で再現した。**N-1**: `fetch --tags` は既存ローカルタグを clobber せず、ローカル branch は fetch 対象外なので、前回実行のコードが打った ref が次回の `GIT_REF` として解決される。**N-2**: git の設定優先順位は local > system なので `.git/config` の `core.fsmonitor` 等が entrypoint 自身の git 操作で発火し、しかも `GH_TOKEN` 破棄の**前**に走る。設定経由の実行経路を列挙して潰すのは筋が悪い。tmpfs にすれば両方が構造的に消え、R6（`/src` への書き込みが Docker VM のディスクに残る）も解消する。代償は毎回の full clone と RAM 消費（実測 131M、tmpfs 既定 7.9G）（§4.6） |
| D19 | pnpm の store を **node_modules と同一の tmpfs マウント**に置く（rev.5） | `read_only` 下では既定の `$PNPM_HOME/store` を作れず `pnpm install` が ENOENT で落ちる。store を tmpfs へ移す必要があるが、`$HOME`（別マウント）へ置くとハードリンクがマウントを跨げず copy にフォールバックし、**RAM が倍**になる（実測 260M vs 131M、リンク数 2 以上のファイルが 0/3546 vs 3491/3546。pnpm 自身が `copied` / `hard linked` と出力で明言）。`/src/.pnpm-store` に置く（§4.5 / §4.6） |
| D20 | prod の `dotenvx run` には `--strict` / `--no-armor` を付けるが、**イメージ側では強制しない**（rev.6 で書き換え） | dotenvx は復号に失敗しても非ゼロ終了せず、暗号文をそのまま値として注入して rc=0 を返す（実測）。I6 が排除したい「沈黙した成功」そのものなので、prod の運用手順としては必須である。**しかし機構で強制しない。** 強制の場は shim しかないが、shim は runtime-base 経由で dev container にも継承され（I5 の帰結）、`--strict` は**正当な使い方を壊す** — dotenvx には `--convention flow`（`.env` / `.env.local` / `.env.development` を重ねる規約）があり、この規約では一部のファイルが存在しないのが正常であるところ、`--ignore=MISSING_ENV_FILE` が示すとおりファイル不在はエラーコードの一つなので、`--strict` 下では重ね掛けの 1 枚が無いだけで落ちうる。**この根拠は rev.6 では `--ignore=MISSING_ENV_FILE` の存在からの推論だったが、rev.7 で実測に置き換わった** — `.env` と `.env.local` があり `.env.development` が無い状態で `--convention flow --strict` は rc=1 で落ちる（欠けていると言われるのは `.env.development.local`）。`--no-armor` も同様に、dev の開発者が自分の dev 鍵を Armor で管理している運用を壊す。**これは dotenvx の使い方の問題であってコンテナの責務ではない。** shim がプロジェクトの env 構成を知らないまま焼く判断ではなく、プロジェクト側に委ねる。破ったときの結果は R12 に記録し、忘れたことに気付ける機会を D22 で作る。`--no-armor` の根本対処は §11 の egress-guard 適用に寄せる。**副次的な実測**: `-f` でファイルを明示した場合、不在ファイルは `--strict` の有無に関わらず rc=1 になる。prod は `-f .env.prod` を明示する運用なので、`--strict` が追加で担うのは**復号失敗の顕在化だけ**である |
| D22 | `--strict` の欠落を shim が**警告する**（強制はしない）（rev.7） | D20 の「強制しない」は維持するが、「黙る」まで引き受ける必要はない。`--strict` を欠いたときの失敗は rc=0 で暗号文が値として注入されるという静かなもので（R12）、忘れたことに気付く機会が一度もない。「引数に `run` があり、`--strict` が無く、`/run/secrets/DOTENV_PRIVATE_KEY_PROD*`（glob。`.env.production` 命名の `_PRODUCTION` も拾う — rev.9 で固定名から拡張）が存在する」ときだけ stderr へ 1 行出す。**環境の判別ではなく注入済み鍵の観測**なので D15 の三値意味論と矛盾せず、prod 鍵が来ない dev 側ではノイズがゼロになる。`--convention flow` も `--ignore=` も壊さない。強制なしで I6 の趣旨を回収する最小の手段（§4.3） |
| D24 | hook と CI が**同一の共有スキャナ**を使い、検査対象パターンはプロジェクトごとに上書きできる（rev.7） | D23 で CI 側を差し替えた結果、hook（`dotenvx precommit`）と CI（独自走査）で**判定の実装が 2 つ**になった。パターンだけ揃えても判定が別なら「hook は通るが CI で落ちる」という分岐は残る。判定ロジックをリポジトリ内の 1 ファイルへ切り出し、**入力を検査対象ファイルの一覧だけにする** — hook は staged を、CI は tracked を流す。スコープだけが違い判定は同一になる。差分を見るか現在の状態を見るかは文脈が決めることで（D23）、何を平文と見なすかは文脈に依らない。イメージが `COPY` し、reusable workflow は karakuri を第二 checkout して同じファイルを取る。**hook から `dotenvx precommit` は外れる** — 自前のファイル名フィルタを持ち上書きできないため、残すと逆向きの分岐を作る。上書きはリポジトリルートの設定ファイル 1 枚で、hook と CI が同じ規則で読むので片方にだけ効くことがない。**設定ファイルは `source` せず parse する**（リポジトリの中身は信頼しない側が書ける。防御装置を攻撃経路にしない）。既定は変えず、広げるかどうかは 4 リポジトリの実測後に判断する（R13）（§8.2） |
| D23 | CI の検査から `dotenvx precommit` を**外す**（rev.7） | `precommit` の検査対象は `git diff HEAD` の差分のみで、CI のクリーンな checkout（差分ゼロ）では平文の tracked `.env` を 2 件見つけておきながら「encrypted/gitignored (2)」と表示して rc=0 を返す（実測）。**単なる no-op ではなく「検査した風の緑」**であり、検知装置としては無いより悪い — 「CI で見ている」という誤った安心を与える。tracked ファイルの直接走査へ差し替える（§8.2）。hook 側（staged 差分がある文脈）では正しく機能するので、そちらは `precommit` のままにする。同じ検査ロジックを二つの文脈で使い回そうとしたことが誤りであり、文脈が違えば手段も違ってよい |
| D21 | `GIT_REF` は entrypoint で**完全な commit sha を強制**し、`PROD_ALLOW_MUTABLE_REF=1` を明示したときだけ可変 ref を許す（rev.6） | rev.5 は「完全な commit sha を渡す」を要件としながらラッパーの警告だけで続行しており、契約と実装がずれていた。R10 の唯一のゲートは deploy 前の人間のレビューであり、その前提は「レビューした対象と流したものが一致する」ことである。ブランチ名はその一致を切る — 押した瞬間に何を流したか分からず、main は動くので後から再現もできない。一方 sha は「古いかもしれないが既知で再現可能」。**失敗の性質が違う**（未知 vs 既知）ため既定は拒否とする。ただし危険を理解した上でブランチ運用を選ぶ余地は残すため、環境変数による明示的な脱出口を置く。検査は entrypoint 側に置き、ラッパーを迂回しても効くようにする。**ラッパーに `git ls-remote` で事前解決させる案は不採用** — 起動ラッパーにネットワーク経路と資格情報を持ち込むことになり、「broker と secret 以外に触らせない」という位置づけが崩れる（§4.6） |
| D25 | 共有スキャナの正典を **`packages/env-guard/bin/env-guard-scan`** に置き、リポジトリ内に**複製を作らない**（rev.8） | 配布単位（npm パッケージ）と正典の置き場を一致させる。イメージ・karakuri の CI・ホストの三方向すべてがこの 1 ファイルを見る。**複製して同一性をテストで担保する案は採らない** — 同じファイルが 1 つしかなければ担保するものが無い。D24 が潰した「判定が 2 つ」の再来を、テストではなく構造で防ぐ。`@himorogy/enclave-env` は廃止した（§6.3） |
| D26 | イメージへは **named build context** で供給し、ビルドコンテキストは `images/runtime-base` のまま広げない（rev.8） | D25 の帰結。スキャナが `packages/env-guard` へ移ったため、`images/runtime-base` のコンテキストからは見えなくなる。当初はコンテキストをリポジトリルートへ広げる案だったが**却下した** — 除外設定に書かれていない全ファイルが docker デーモンへ転送され、新しい除外設定の網羅性が未確認事項として増える。buildx の named build context なら必要なディレクトリだけを追加供給でき、変更はビルドを行う 2 つの workflow に 1 行ずつで済む。**片方だけに足すともう片方のビルドが `COPY` で落ちる** |
| D27 | 他 org からの呼び出しは npm 経由でスキャナを取り、**karakuri 自身の CI は作業ツリーのファイルを直接使う**（rev.8。未実装） | reusable workflow が自分の ref を割り出せない問題（§8.2）は、バージョンを workflow ファイル自身に書ける npm 経由なら**問いごと消える**。ただし karakuri 自身まで npm に寄せると、**スキャナを変更する PR が変更前の公開済みスキャナで検査される** — 緑になるがその PR の変更を一度も通していない。作業ツリー検出の分岐は残し、置き換えるのは第二 checkout の側だけにする。npm から取ったものは SHA256 で照合する（`npx` は取得物のハッシュを検証しない。バージョン固定は改竄への対策にならない） |
| D28 | dev 鍵の注入も broker 方式にし、ホスト上の恒久平文（`env_file` の `dev/.env.container`）を廃止する（rev.9。機構は実装済み・各プロジェクトの移行は未実施） | 恒久平文は prod 側が廃止した `~/.config/<project>/.env.container` と同じ形であり、environ 常駐は `docker inspect` / コアダンプ / diagnostic report / 全子プロセス継承という書き出し面を開く。broker・shim・`/run/secrets` 規約・git-askpass は既存のまま流用でき、増えるのは起動後の注入 1 ステップと dev compose の `/run` tmpfs 化のみ。**エージェントから鍵を隠す目的ではない** — 同一 UID のため原理的に不可能で、そこは鍵のスコープで守る。この目的の限定を理解した上で複雑性と釣り合うと判断した（§4.9） |
| D29 | 対話 prod 作業は「二段構え」（broker をパイプした **attached の** `prod-run.sh sleep 8h`（端末 1）→ `docker exec -it`（端末 2））を標準手順とする（rev.9。土台の attached 化は実測起点） | rev.8 まで第一候補だった非対話一本化は、dryrun → 適用のような対話的運用の実在と衝突する。対話 TTY が使えないのは防衛判断ではなく stdin を搬送路にした技術的帰結（D3）であり、二段構えは entrypoint 完了後に exec するため注入・clone とも 1 回でセッションを維持でき、防御を何も緩めない。当初案の `run -dT`（detach、1 端末）は実測で不成立 — detach は stdin の中継者（compose クライアント）を消し、broker は Broken pipe、entrypoint は EOF を待ち続けて取込の行で停止、`sleep` 未実行のため自動回収も消える（§6.4）。`sleep` は `infinity` ではなく時間を切り、stop 忘れを自動回収する。`/src` の tmpfs（D18）は維持し、セッションを跨ぐ再 clone はその代償として受容する（§6.4） |
| D30 | broker の標準実装を **Bitwarden CLI（native ビルド）** とする（rev.9。実測済み） | (1) macOS 実機の実測で、登録・取得とも Keychain 参照実装より体験が良い — keychain は `-w` が単一行しか受けず base64 迂回が要り、partition list の二重プロンプトも踏んだ（いずれも対処済みだが登録 UX の重さは残る）。(2) クロスプラットフォームであり、Windows 側の broker 選定を同時に閉じる。(3) チーム共有鍵が共有コレクションでそのまま配布でき、鍵束を git 管理しない方針（D17）と噛み合う。(4) CLI は native 実行ファイルを版 pin + SHA-256 照合で固定パスに置く — broker はホスト側で最も特権的な部品（マスターパスワードを握り全鍵束を stdout に出す）であり、npm 版の postinstall 実行・深い依存木・黙った版移動を避ける。**broker 契約は不変** — カンマ区切りの複数項目マージ（unlock 1 回・並び順連結・取込側の後勝ちで個人が共有を上書き）は bitwarden 実装の機能であって契約の拡張ではない。keychain 実装は代替の参照実装として残置する（§4.1 / §11） |
| D31 | shim に**明示呼び名**（`_dotenvx` / `_wrangler` / `_gh`。同一ファイルへのリンク、`$0` で分岐）を追加し、npm scripts からは `_` 付きで呼ぶ（rev.9。実測起点） | `pnpm run` が `node_modules/.bin` を PATH 先頭へ積む以上、素の名前の shim は npm scripts 内で構造的に負ける（§4.3 rev.5 実測、dev 実機でも再確認）。代替案として検討した「取込側で `.env.keys` を併産し `-fk` で読ませる」は、(1) 出荷物と ingest の面積が増える、(2) 短く書くための wrapper に `--strict` を焼くと D20 が退けた `--convention flow` 破壊を再導入する、の 2 点で退けた。明示呼び名は面積増ゼロ（リンク 3 本 + `$0` 分岐）で、注入後の実体解決を PATH に任せることで npm scripts 内ではプロジェクトが pin したローカル版がそのまま鍵付きで動く — バージョン尊重と shim 通過が両立する。フラグ選択はスクリプト作者に残る |
| D32 | entrypoint の store-dir 設定は **pnpm を起動せず `config.yaml` へ直書き**する（rev.9。実測起点） | pnpm 9.7+ の self-switch: cwd の `packageManager` を見て pnpm が自分をその版へ切り替えるため、clone 後の `/src` で `pnpm config set` を呼ぶと「イメージに焼いた pnpm」ではなく「プロジェクトが pin した版」の挙動になり、read_only の既定 store を触って ENOENT で死ぬ（実測）。設定というホスト側の関心事に、プロジェクト側の pin が干渉する構造そのものを断つには pnpm を起動しないしかない。書く内容は `pnpm config set` の書き込み結果として実測済みの形式（`config.yaml` / `storeDir:`。`rc` / `.npmrc` の `store-dir=` は効かないことも実測済み）の再現であり、新しい推測は含まない。切替先 v10 系の読む設定は実測が二転して決着: `pnpm store path` は config.yaml を読んで正しい値を返したが、**install の store controller は rc（ini）しか読まず**、実機の `pnpm install` が既定 store の ENOENT で死んだ（2026-08-14）。観測コマンドの結果を根拠に config.yaml 単独へ削ったのが誤り — **権威は install 自身**。同じ値を両形式へ直書きして決着（§4.5 / §11） |
| D33 | github.com の認証を**イメージ自前の credential helper** に固定する（`GIT_CONFIG_COUNT=2`。スロット 0 で既存 helper を打ち消し、スロット 1 で `/usr/local/bin/git-credential-gh-token` を積む。2026-08-16。実測起点） | `GIT_ASKPASS` は helper が 1 本も答えなかった場合のフォールバックにすぎず、VS Code は **global gitconfig の helper と統合ターミナルの `GIT_ASKPASS` の両方**を握る。helper だけを打ち消す最初の対策は実機で後者に負け、認証はホスト側の資格情報で通っていた（成功するので気づけない）。helper は設定であり、環境変数による設定は全設定ファイルの後に適用されるので、記述順にも environ の注入にも左右されずに固定できる — これが唯一の順序で勝てる手段である（`/etc/gitconfig` への reset は global の helper が積み直されて不成立。実測）。打ち消しと自前 helper を組み合わせると一覧が自前 1 本になり、認証成功後に git が全 helper へ配る `store` の宛先も 1 本になる（VS Code 経由でホストの資格情報ストアへ書き戻る経路が消える。実 clone で観測）。トークン不在は `quit=1` で連鎖ごと止める — helper の無応答・非ゼロ終了はいずれもフォールスルーするので、これだけが「止めろ」を伝える手段（実測）。端末プロンプトにも落ちないため、人間が手で迂回することもエージェントが待ち続けることもない。代償は「`GH_TOKEN` 未注入では github.com の https 認証が失敗する」で、これは目的そのもの。`GIT_CONFIG_COUNT` は単一カウンタのため利用側と衝突しうるので、固定の生死を `git-auth-check` が対話シェル起動時に確認する（§4.6） |

---

## 6. 運用

### 6.1 prod への環境変数追加

**dev container から実行できる。** dotenvx は非対称暗号を用い、公開鍵は `.env.prod` の先頭に平文で格納されている。値の追加・更新に秘密鍵は不要である（dotenvx 実装で確認済み: `set` は埋め込み公開鍵のみで暗号化し、私鍵欠如は非致命エラーに留まる）。

```sh
# dev container 内
dotenvx set FOO bar -f .env.prod
```

local / dev に追加したついでに prod にも追加する運用が、prod container を起動せずに成立する。この書き込み権が整合性リスクの裏面であることは R10 に記す。

### 6.2 prod 環境変数の確認

```sh
# prod container（一発コマンド）。いずれもファイルを作らない。<broker> は §4.1 の契約を満たすコマンド
<broker> | docker compose -f compose.prod.yaml run -T --rm prod \
  dotenvx get -f .env.prod
<broker> | docker compose -f compose.prod.yaml run -T --rm prod \
  sh -c 'dotenvx run --strict --no-armor -f .env.prod -- printenv | sort'
```

dev からは書けるが読めない。値の検証は prod 側で行う。stdout の着地先については §4.4 を参照。

prod で `dotenvx run` を使うときの必須オプション（rev.5）:

- **`--strict`** … 復号失敗を非ゼロ終了にする（D20）。無いと暗号文が値として注入され rc=0 で通る
- **`--no-armor`** … ホスト型サービスへの経路を切る（§4.4）

`dotenvx get` は既定で rc=1 を返すので `--strict` は不要だが、失敗時も暗号文を stdout に出すため、パイプで受ける側は rc を見ること。

また **dotenvx は `pnpm` の外側に置く**（§4.3）。`prod-run.sh pnpm deploy` の形にすると、`pnpm run` が `node_modules/.bin` を PATH 先頭に積んでプロジェクトのローカル dotenvx が shim に勝ち、鍵が注入されない。

### 6.3 廃止するもの

- `templates/prod-shell.sh`
- dev/prod 相互排他チェック
- `~/.config/<project>/.env.container`
- 各リポジトリの `.git/hooks/pre-commit`（`core.hooksPath` に置換）
- dev compose の `env_file` 注入（`dev/.env.container`。§4.9 の broker 方式へ置換。rev.9 で決定・移行は未実施）

`@himorogy/enclave-env` は**廃止した（rev.8）。** 保留にしていた「package という配布層が要るか」という問いには、要るという答えが出た — ただし enclave-env としてではない。

コンテナの中でコミットする限り `core.hooksPath` が効くが、**ホストの GUI git クライアントから
コミットする経路にはイメージの設定が届かない**。`core.hooksPath` はイメージ内の
`/etc/gitconfig` に書いてあり、ホストの git はそれを読まない。ここを塞ぐには、ホスト側へ
スキャナと hook を届ける手段が要る。それが package の役目である。

一方で enclave-env に残すべき中身は無かった。検査は共有スキャナが引き継ぎ、暗号化と復号は
dotenvx の直接呼び出しで足り、dev/prod 相互排他チェックは bind mount の廃止で不要になり、
2 層 devcontainer と `prod-shell.sh` は本設計が置き換える対象そのものである。**残るものが
無い package を版上げして使い続けるより、役割に合った package を新設する方が形に合う。**

`@himorogy/env-guard` を新設し、スキャナと pre-commit hook をそこへ移した
（`packages/env-guard`）。イメージは named build context 経由でこの 1 ファイルを焼き込む。
**リポジトリ内にスキャナは 1 ファイルしか存在しない** — 複製して同一性をテストで担保する
方式は採らない。同じファイルが 1 つしかなければ、担保するものが無い。

enclave-env の廃止で 1 つ実害を持ち越している。公開済みの v0.3.0 が持つ `check` は、
**ファイル内のどこかに `DOTENV_PUBLIC_KEY` の文字列があれば通す**という判定だった。
暗号化済みのファイルは必ずその行を先頭に持つので、後から平文の変数を書き足しても検出
されない。npm の deprecate メッセージには、移行先だけでなくこの欠陥を書く。既存の利用者に
届く経路がそこしかない。

`.env.keys` の workspace 内不存在チェック（dotenvx の自動フォールバック対策、§4.3）は
共有スキャナが引き継いでいる。

### 6.4 対話 prod 作業（rev.9 で標準手順化）

stdin が secret の搬送路のため、`run` の対話 TTY とは両立しない（§4.1 / D3）。dryrun → 適用のような対話的な運用は**二段構え**で行う（D29）。

**土台は attached で起動する（2 端末。rev.9 実測で確定）。** rev.9 当初案の `run -dT`（detach）は実測で不成立と判明した: attached モードでは stdin パイプをコンテナへ中継するのは compose クライアント自身であり、`-d` はそのクライアントを即座に終了させる。結果は三重の失敗になる — (1) broker は書き込み先を失い Broken pipe で死ぬ、(2) コンテナ側の stdin は open のまま誰も閉じないため、取込スクリプトが EOF を永遠に待って entrypoint が取込の行で停止する（clone にも `exec "$@"` にも到達しない）、(3) したがって `sleep 8h` は一度も走らず、時間切れによる自動回収も存在しない — `--rm` は正常終了時にしか効かないため、手で `docker rm -f` するまでコンテナが残る。secret はゼロ注入のまま `docker exec` でシェルが取れてしまうが、prod-context が「注入済みの鍵が無い」と警告する（沈黙はしない）。

```sh
# 端末 1: 土台を前面（attached）で起動する。broker の認可プロンプトも
#         entrypoint のログもここに出る。搬送路はクライアントが中継する
<prod-run ラッパー> ... prod-run.sh sleep 8h

# 端末 2: entrypoint 完了（clone 済み・sleep 稼働）後に入る
#         compose project 名で引く。名前フィルタで引いて先頭を採ってはいけない
docker compose -p prod-<repo> -f <compose ファイル> ps -q prod
docker exec -it -w /src <container> bash
```

**container の特定を推測で行わない。** compose.prod.yaml はプロジェクト固有値を持たない設計なので全プロジェクトで 1 枚を共有でき、その場合 compose project 名はファイルの所在から導かれて、どのプロジェクトの prod を起動しても同じ名前になる。`docker ps --filter name=prod-run` はそれら全部に一致し、先頭を採る実装は複数の土台が立っているときに黙って一つを選ぶ。入った先には別プロジェクトの鍵が注入済みで、`/src` には別プロジェクトのコードが clone されている。起動側で `COMPOSE_PROJECT_NAME` をプロジェクトごとに振り、取得側は compose 経由で引いて、0 件でも複数件でも失敗させる。ホスト側の関数はこの形で実装されている（`images/runtime-base/templates/host/karakuri.sh`）。

- entrypoint 完了後に exec するため `/run/secrets` は注入済み。対話シェルの起動時に注入済み鍵名が表示される（§4.3）
- 注入 1 回・clone 1 回でセッションを維持でき、その中で dryrun と適用を続けられる
- `sleep infinity` ではなく時間を切る。退出後の `docker stop` 忘れがそのまま放置され続けない。即回収するなら退出後に端末 1 を Ctrl-C（または `docker stop`）
- Ctrl-C / `docker stop` が効くのは compose の **`init: true` が前提**（rev.9 実測）。entrypoint は最後に `"$@"` を exec するため、init なしではコンテナの pid 1 が実行コマンド（二段構えでは `sleep`）そのものになり、pid 1 にはハンドラ未設定のシグナルが配達されない — Ctrl-C も SIGTERM も無視され、`docker stop` は 10 秒後の SIGKILL 頼み、`--rm` の自動回収にも届かず `docker rm -f` が要る状態を実測した。`init: true`（tini が pid 1）でシグナルが子へ転送され、Ctrl-C 一発で `--rm` の回収まで通る
- セッションを跨ぐと `/src`（tmpfs）は消え、再 clone になる。これは D18 の代償であり緩めない — named volume に戻すと、前回実行のコードが打ったローカル ref の汚染と `.git/config` 経由のコード実行（いずれも実測で再現済み。§4.2）が復活する

---

## 7. 受容残余リスク

| #   | リスク                       | 判断                                                                                                                                                                            |
| --- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | ホスト侵害                     | 防御不能。ホストを取られた時点でキーチェーンの解錠セッションもパイプ中の平文も失われる。ディスク暗号化（FileVault / BitLocker）を前提条件とする                                                                                                   |
| R2  | prod container 内部の攻撃者     | 信頼境界の内側として受容。エージェントを置かないことで発生確率を下げる                                                                                                                                           |
| R3  | メモリダンプへの完全防御              | 不可能。`$(cat ...)` の時点で平文がプロセスのヒープに載り、シェルはゼロクリアしない。達成できるのは露出窓の縮小まで                                                                                                              |
| R4  | パイプバッファ経由の露出              | broker → compose run のパイプはカーネルバッファ（RAM）のみを経由し、露出はコマンド実行長に限定される。同一ユーザーの他プロセスからの読取は /proc 経由では不可（fd を持つのは両端のみ）                                                                  |
| R5  | unlink ≠ 消去               | CoW / ジャーナリング / ウェアレベリングにより、削除後もビット列が残りうる。`shred` は現代の FS では機能しない。対処は「消す」ではなく「最初から書かない」（tmpfs / `logging: none`）                                                              |
| R6  | ビルド成果物への secret 埋め込み（rev.5 で縮小）      | `VITE_*` 等は本質的に成果物に入る。`/out` を tmpfs にすることでディスク接触を避ける。**rev.4 まで残っていた「prod で走るコードが `/src`（named volume）へ書けばコンテナ削除後も Docker VM ディスクに残る」という経路は、D18 で `/src` を tmpfs にしたことで消えた。** 現在コンテナが書ける場所は全て tmpfs であり、悪意ある明示書き込みであっても不揮発媒体には届かない（I1）。残るのは R5（unlink ≠ 消去）ではなく R7（swap / hibernation 経由で RAM 内容が退避される）の側面のみ |
| R7  | ターミナルのスクロールバックと swap      | §4.4 参照。設定棚卸しで低減するが完全には潰せない                                                                                                                                                   |
| R8  | コミット前検査の迂回                | `--no-verify`、git CLI を経由しない書き込み（GitHub API、libgit2 系）で素通りする。ホスト側 GUI クライアント（Fork）からのコミットは §4.7 の手当てで覆えるが、PATH 解決の失敗により**静かに無効化されうる**。**予防ではなく早期検知**として位置づけ、本線は §8.2 の CI に置く |
| R9  | CI 検査がマージをブロックできない        | 必須ステータスチェックは private リポジトリでは有償プランを要する（§8.3）。ブロックできない場合、CI は「赤くなる」検知にとどまる。D14 によりこれを受容し、予防を構成側（暗号化 env を git 管理する前提そのもの）に置く                                                     |
| R10 | dev が書いたコードを prod が実行する**正規の権限昇格**（機密性ではなく整合性） | 本設計の最大の残余リスク。dev は `.env.prod` へ書け（§6.1）、prod が実行するコード・依存ツリー・package script も書ける。prod で走る checkout 済みコードは復号後 secret を正規権限で読めるため、コンテナ脱獄も socket も Keychain 突破も要らない。暗号化値の diff は**キー名しか可視でなく値のレビューは不可能**（`DATABASE_URL` の宛先差し替えは diff 上「変更あり」としか見えない）。「prod container を信頼する」は正確には「**実行環境（分離・エージェント不在）を信頼するが、そこで実行されるコードは信頼しない**」であり、この二つは別物。防御は (a) deploy 前の人間レビュー、(b) prod 実行 ref の完全 commit sha pin（I7。branch/tag/submodule/LFS/レジストリ取得は可変なので content digest まで固定）、(c) dotenvx と復号ランナーをアプリ依存グラフから分離しイメージに焼き込む（§4.5 で達成済み。ただし checkout 済みコードの postinstall による上書きは prod での動的インストール禁止で塞ぐ）。本設計の一次目標は機密性であり、整合性は上記緩和の上で受容する（Codex 敵対レビュー #1/#2/#3） |
| R12 | `dotenvx run` に `--strict` を欠いた場合の沈黙した成功（rev.6） | dotenvx は復号に失敗しても rc=0 を返し、**暗号文をそのまま値として注入する**（実測: `FOO=encrypted:BAZG/...`）。アプリはその値で起動し、deploy は成功と報告される。I6 が排除したい形そのものだが、**イメージ側では強制しない**（D20）— 強制の場である shim は dev にも継承され、`--strict` は `--convention flow` のような正当な重ね掛けを壊すためである。T6 の hook（§4.7）と同じく、**予防ではなく運用手順 + 検知**の位置づけになる。**rev.7 で検知の場を一つ増やした** — shim が prod 鍵の注入を観測し `--strict` が無いときだけ stderr へ警告する（D22）。強制ではないので破れるが、破ったことが静かではなくなる。`--no-armor` を欠いた場合の外部通信も同型で、根本対処は §11 の egress-guard 適用に寄せる |
| R13 | コミット前検査のファイル名パターンから外れる env ファイル（rev.7 で受容） | 既定のパターン（`(^|/)\.env` と `(^|/)secret\.env\.`）は basename が `.env` で始まるものしか拾わない。`production.env` / `config/dev.env` を平文でコミットしても hook も CI も素通りする。**既定は広げない。** 対象の 4 リポジトリはいずれも既定のパターンで足りており、広げる動機が実在しない。広げれば平文が正常なサンプルファイル等での誤検知を新たに生み、それは「検査が信用されなくなる」方向の劣化である。命名が既定から外れるプロジェクトは `env-guard.conf` の `pattern` で宣言する（§8.2 / D24）。**宣言がリポジトリに残ることの方が、既定を広げて黙って拾うことより良い** — 何を検査対象にしているかが、そのリポジトリを読んだだけで分かる |
| R11 | broker「常に許可」設定による認証境界の消失 | broker 契約 3 のプロンプト緩和（Keychain の「常に許可」等）を選ぶと、同一ホストユーザーで走る**任意のプロセス**が無認証で秘密鍵を取り出せる。dev container 内からは直接呼べない（VM 内の UID はホストユーザーと別、Docker socket も無い）が、コンテナ脱獄・ホスト連携機能の突破・dev が書いたホスト実行スクリプトのいずれかを越えれば決定的になる。緩和は「常に許可」を避けユーザープレゼンス（Touch ID）を毎回要求すること。裁量に委ねるが、選択のリスクをここに明示する（Codex 敵対レビュー #9） |

---

## 8. 伝播

繰り返し発生してきた「改善を全プロジェクトへどう届けるか」に対する統一的な答えを置く。

**位置づけ（rev.3）**: 本節は方向性の記録であり、詳細設計は **§4 の実装完了後に別途行う**。§4 実装が守るべき制約は「プロジェクト側に残すファイルを最小・パラメータ化」（`compose.prod.yaml` にプロジェクト固有値を焼かない）のみで、これを守る限り 8.2 / 8.4 の後付けに不可逆な障害は生じない。第一チャネル（イメージタグ）は §4 実装の副産物としてそのまま成立する。当面の 4 repo への展開は手動コピーで開始してよい — 8.4 の注入コマンドは冪等な後付けを前提に設計するため、分岐は後から回収できる。

### 8.1 三つのチャネル

| チャネル              | 運ぶもの                                                                      | 更新方法                 | 他 org での可搬性                                  |
| ----------------- | ------------------------------------------------------------------------- | -------------------- | -------------------------------------------- |
| イメージタグ            | shim / `core.hooksPath` + hook / egress-guard / dotenvx / prod-entrypoint | base のタグ更新           | 高（public イメージを pull するだけ）                    |
| reusable workflow | CI の検査ロジック                                                                | `@v1` 参照             | 中（GitHub Actions 前提、karakuri が public であること） |
| 注入コマンド            | `compose.prod.yaml`、workflow スタブ      | `karakuri sync` の再実行 | 高                                            |

**原則: プロジェクト側に残すファイルを減らすほど、三本目が軽くなる。** shim と `prod-entrypoint.sh` をイメージに焼いた結果、プロジェクト側に残るのは `compose.prod.yaml` 一枚（10 行程度）と workflow スタブ（5 行）だけになる。

### 8.2 CI

**当初案は破棄した（rev.7 / D23）。** rev.6 までは reusable workflow が `dotenvx precommit` を呼ぶ形で書いてあり、「CI のクリーンな checkout では no-op になる**疑い**」を要検証として残していた。実測した結果、疑いより悪かった。

```
クリーン checkout / 差分ゼロ / 平文 .env が tracked（2 件）  rc=0  ▣ encrypted/gitignored (2)
平文 .env を staged にした状態                              rc=1  ☠ .env not encrypted/gitignored
平文 .env を未 staged で編集した状態                        rc=1  ☠ 同上
平文 .env.new を untracked のまま置いた状態                 rc=0
同 .env.new を staged にした状態                            rc=1
```

平文の tracked `.env` を 2 件**見つけておきながら**「encrypted/gitignored (2)」という緑を返す。単に検査をしないのではなく、検査した件数まで表示して通す。CI に置けば「見ている」という誤った安心だけが残り、無いより悪い。

`precommit` が悪いのではなく、**文脈が違う**。hook は staged 差分がある文脈で走るので `git diff HEAD` ベースの検査で正しく、実際に効く（§4.7）。CI はクリーンな checkout であり、見るべきは差分ではなく **tracked なファイルの現在の状態**である。同じ道具を両方に使い回そうとしたのが誤りだった。

**採用: 共有スキャナ 1 本を hook と CI で使い回す（rev.7 / D24）。** 検査ロジックをリポジトリ内の単一ファイルへ切り出し、**入力を「検査対象ファイルの一覧」だけにする**。dotenvx への依存自体が不要になり、CI のインストール手順も消える。

```
                   ┌─ hook  : git diff --cached --name-only  （staged）
検査対象の一覧 ────┤
                   └─ CI    : git ls-files                   （tracked）
                                        │
                                        ▼
                            共有スキャナ（判定はここだけ）
                              ├ 設定（リポジトリルート）を parse
                              ├ ファイル名パターンで絞る
                              ├ 許可リストを skip
                              ├ 各行が encrypted: であることを検査
                              └ .env.keys が tracked なら無条件で fail
```

**スコープだけが違い、判定は完全に同一になる。** 差分を見るか現在の状態を見るかは文脈が決めることで（D23）、何を平文と見なすかは文脈に依らない。ここを分けたのが rev.6 までの構造上の誤りだった。

実体は `images/runtime-base/bin/env-guard-scan`。消費者は 3 つで、全て同じファイルを読む。

1. **hook** — runtime-base イメージが `COPY` した `/usr/local/bin/env-guard-scan` を呼ぶ。スキャナは root:root 0755 で置く（§4.5 の配置規約 — これは制約であり、node が書き換えられる場所に置かない）
2. **CI** — reusable workflow が karakuri を**第二 checkout** して取り出す。`actions/checkout` の既定は呼び出し側リポジトリなので、`repository:` を明示してもう一度使う。**ref は `github.job_workflow_ref` から取る** — これは「今動いている reusable workflow 自身」の ref を指す（`github.workflow_ref` は呼び出し**側**の workflow を指すので使えない）。固定しないと `@v1` で呼ばれた workflow が main のスキャナを実行し、版が食い違う。**parse に失敗したら ref を推測せず落とす**
3. **テスト** — 実ファイルを直接叩く

**hook から `dotenvx precommit` が外れる。** precommit は自前のファイル名フィルタを持っていて上書きできないため、残すと「CI は通るが hook だけ落ちる」という逆向きの分岐を作る。staged ファイルに対する検査内容は共有スキャナが同じだけ覆う。`.husky` / `.githooks` へのチェーンと `.env.keys` の再帰検査は維持する。

#### プロジェクトごとの上書き（rev.7）

ファイル名パターンと許可リストは**リポジトリルートの `env-guard.conf` 1 枚**で上書きできる。hook と CI が同じファイルを同じ規則で読むため、**上書きが片方にだけ効くことが構造的に起こらない**。

```
pattern (^|/)production\.env$
allow   *.env.container.example
```

- **ファイル名をドットで始めない。** `.env-guard.conf` にすると既定パターン `(^|/)\.env` に**自分自身が一致し**、設定ファイルが env ファイルとして検査されて必ず落ちる
- `pattern` / `allow` は指定した側の既定を**置き換える**（追加ではない）。指定しなかった側は既定のまま
- 不在なら既定値。既定は変えない — `(^|/)\.env` と `(^|/)secret\.env\.`、許可リストは `*.env.container.example`
- **`source` / `eval` しない。parse する。** リポジトリの中身は信頼しない側が書けるものであり（R10）、hook は dev container 内で走る。repo の内容を実行させたら、防御装置がそのまま攻撃経路になる
- 設定ファイルが壊れている・読めない場合は fail-closed。「設定が読めなかったので既定で通した」を作らない
- parse もスキャナの中に置く。読み方が 2 箇所へ散れば、それ自体が新しい分岐になる

**上書きできること自体は防御水準を下げない。** 設定ファイルはリポジトリの中にあり、dev が書き換えられる。しかし T6 のコミット前検査はもともと `--no-verify` で素通りする緩和策であり（R8）、CI 側も必須ステータスチェックが使えない環境ではマージを止められない（R9）。もともと「攻撃者を止める装置」ではなく「事故を早く見つける装置」なので、プロジェクトが自分の都合で範囲を宣言できることの方が価値が大きい。

**既定を広げない（rev.7 で確定）**: `production.env` や `config/dev.env` のように basename が `.env` で始まらないファイルは、既定のパターンでは検査されない。対象の 4 リポジトリはいずれも既定で足りており、広げる動機が実在しない。広げれば平文が正常なサンプルファイル等での誤検知を新たに生み、それは「検査が信用されなくなる」方向の劣化になる。命名が既定から外れるプロジェクトは `env-guard.conf` の `pattern` で宣言する。**宣言がリポジトリに残ることの方が、既定を広げて黙って拾うことより良い** — 何を検査対象にしているかが、そのリポジトリを読んだだけで分かる。残余リスクとしては R13 に記録する。

```
git ls-files から (^|/)\.env と (^|/)secret\.env\. に一致するものを対象にする
  許可リスト（既定は *.env.container.example。env-guard.conf で上書きできる）は skip
  空行 / # で始まる行 / DOTENV_PUBLIC_KEY で始まる行は skip
  残る行が ^[A-Z0-9_]+="?encrypted: に一致しなければ平文の混入として fail
.env.keys が tracked なら無条件で fail（私鍵そのもの）
検出 0 件のときは「何件のファイルを検査したか」を出力する
```

最後の一行が重要である。**「0 件検査して緑」と「N 件検査して全部通って緑」を出力から区別できるようにする** — これは今回破棄した `precommit` が踏んだ罠そのものであり、同じ形を自分で作らない。

**検知能力を CI 上で証明する。** 検査が平文を実際に検出することを、合成した fixture（平文 `.env` が tracked / 暗号化済み `.env` が tracked / `.env.keys` が tracked / 許可リストに一致）に対して毎回確認する。この設計は過去に 2 回「偽の合格」（意図した経路を一度も通らずに緑になっていた）で痛い目に遭っており、検知能力を確認していない検査は緑になっても意味がない。

```yaml
# 各プロジェクト/.github/workflows/env-guard.yml（スタブ）
on: [push, pull_request]
jobs:
  env-guard:
    uses: himorogy/karakuri/.github/workflows/env-guard.yml@<karakuri の commit SHA>
```

**ref は commit SHA で固定する（rev.8）。** スキャナの取得が npm 経由になり、期待する SHA256 が
workflow ファイル自身に書かれるようになった（D27 / G）。したがってこの `@` より後ろが信頼の
起点になる — 指した ref にある workflow の中の期待ハッシュが、実際に走るスキャナを決める。
タグ参照では指す先が動き、期待ハッシュも一緒に動くので、固定した意味が無くなる。

**karakuri 自身もこのスタブで自分を呼ぶ。** 自分で使っていない伝播機構は、壊れていても気付けない。ただし呼び方はローカルパス参照（`./.github/workflows/env-guard.yml`）にする — タグ参照にすると PR で変更した版ではなく公開済みの版が走り、その PR の変更が CI に掛からない。

#### 他 org への伝播は未決のまま残す（rev.7）

**手順 4 の範囲は「karakuri 自身が検査を通していること」までで、そこは満たしている。** 他 org へどう届けるかは本節の詳細設計であり、§8 冒頭の位置づけどおり後で扱う（当面の 4 repo への展開は手動コピーで開始してよい）。

ただし実測で 1 点、**先に知っておくべきことが出た**。reusable workflow が「自分がどの karakuri から来たか」を知る手段として `github.job_workflow_ref` を使う設計にしていたが、**実測ではこれが空だった** — ローカルパス呼び出しでも、同一リポジトリを指す完全参照呼び出しでも。同じコンテキストの `workflow_ref` は正しく埋まっているので、コンテキストの取得自体が壊れているわけではない。

`workflow_ref` は代用にならない。指すのは**呼び出し側**の workflow なので、他 org から呼ばれれば他 org のリポジトリを指す。karakuri が自分を呼ぶときだけ動いて他所では壊れる、という使える中で最悪の形になる。

**ただし「常に空」と結論するのは早い。** 測ったのは呼び出し元と呼び出し先が同じリポジトリの場合だけで、GitHub がその条件を内部的にローカル呼び出し扱いしている可能性を排除できていない。**他 org のリポジトリからの呼び出しを一度実行するまで未決**である（検証項目 49 と同じ制約）。

#### この詰まりは rev.8 で解ける見込みになった（未実装。D27）

スキャナが npm パッケージ `@himorogy/env-guard` の持ち物になったことで、**問いそのものが不要になる**。reusable workflow は `npx -y @himorogy/env-guard@<完全固定バージョン>` と、バージョンを workflow ファイル自身に直書きできる。workflow は自分の中身を知っているので、自分の ref を知る必要がない。**他 org から一度呼んで測るという前提条件が消える。**

引き換えに 2 つ引き受ける。

- **可用性** — CI がレジストリの可用性に依存する。受容する。取得に失敗したら検査を飛ばさず落ちること（取れなかったので通した、を作らない）
- **完全性** — こちらは受容しない。レジストリが侵害されれば、他 org の CI で攻撃者の置いたスキャナが走る。しかもそのスキャナは平文を「問題なし」と報告するだけで目的を達する。**バージョンの完全固定は改竄への対策にならない**（`npx` は取得物のハッシュを検証しない）。期待する SHA256 を workflow ファイルに直書きし、照合してから使う。呼び出し側は karakuri の commit sha で workflow を固定するので、信頼の連鎖はそこから繋がる

**karakuri 自身は npm 経由にしない。** 現行の workflow は「呼び出し側の作業ツリーにスキャナがあればそれを使う」分岐を持っており、self-call ではこちらが正しい — タグが指すスキャナではなく、いま検査されている PR のスキャナが走るためである。npm 一本化にすると**スキャナを変更する PR が変更前の公開済みスキャナで検査される**。緑にはなるが、その PR の変更を一度も通していない。置き換えるのは第二 checkout の側だけにする（D27）。

なお採らなかった代替も記録しておく。**composite action**（`uses:` された時点で自分のリポジトリが指定 ref で checkout されるので自分の ref を割り出す必要が無い。代償は呼び出し側スタブが伸びること）と、**スキャナを workflow の中へ複製し同一性をテストで担保する**（スタブは短いままだが複製が残る）。後者は D25 が構造で防いだものを、テストで防ぐ形に戻すことになる。

**許可リストの既定を広げるときの注意**: 検査対象を staged から tracked 全体へ広げたことで、これまで検査を素通りしていた既存の tracked ファイル（典型例は平文のプレースホルダを持つ `.env.example`）が新たに引っかかりうる。既定の許可リストは既存の `check.sh` と揃えて `*.env.container.example` だけにし、それ以上はプロジェクト側が `env-guard.conf` に明示する。**既定を緩める方向の変更は行わない** — 何を許したのかがそのプロジェクトのリポジトリに残らなくなるためである。

**workflow の input は `paths` だけ。** 許可リストとパターンを input からも与えられるようにすると真実の源が 2 つになり、今回潰した分岐をそのまま作り直すことになる。`paths` は「どこまで見るか」だけの指定であって判定を変えない（判定は `env-guard.conf` とスキャナに閉じている）ので、この分類には当たらない。ただし `paths` を指定すると **CI が hook より狭い範囲しか見ない**ことになる点は input の説明に明記する。`.env.keys`（私鍵そのもの）の探索だけは `paths` に関係なくリポジトリ全体に効く — tracked な私鍵は、どの部分木を見てくれと言われたかに関係なく致命的である。

karakuri が public であれば他 org からも呼び出せる。**呼び出し側の注意**: caller org の Actions ポリシーが「選択した actions / reusable workflows のみ許可」の場合、`himorogy/karakuri/...` を allowlist へ明示追加する必要がある（プラン制限ではなく設定項目）。GitHub Actions 以外の CI を使う org 向けには、同じ検査をインラインで書く形を代替として文書化する（依存ゼロ・伝播なしのトレードオフ）。

secret scanning の補完として `gitleaks` 等の OSS スキャナを同 workflow に追加できる。プラン非依存で、`.env` 以外に混入した資格情報も拾える（D14 と整合）。

### 8.3 プラン依存機能を使わない

`@himorogy` は下位プランであり、かつ本構成は他 org へ流用するため、以下には依存しない。プラン境界は 2026-08 時点の確認値。

| 機能                                | 現況                                                              | 判断                                  |
| --------------------------------- | --------------------------------------------------------------- | ----------------------------------- |
| org 単位の ruleset による workflow 強制適用 | 2025-06 から **Team プラン以上**で利用可（Enterprise 限定は旧情報）。Free は不可        | 使わない。per-repo のスタブ配布（8.1 三本目）で代替する  |
| secret scanning push protection   | 現名称 **GitHub Secret Protection**（2025-04 に GHAS から分割、per-committer 課金）。**Team 以上限定** — Free/Pro の private repo は課金しても不可。public repo は無料 | 使わない。利用可能な org では追加の防御線として推奨するにとどめる |
| 必須ステータスチェック                       | private repo では Free 不可（Pro / Team 以上）。public repo は Free でも可    | あれば使う。なくても CI は動き検知は機能する（R9）        |

### 8.4 雛形の配布

`create-*` 形式のスキャフォールドは「コピーと置換の手間」を解決するが、「改善を全プロジェクトへ伝播させる」を解決しない。一回きりの生成は、生成した瞬間から全プロジェクトが分岐する。

対象は既存の 4 リポジトリであり、新規作成を前提とする `create-*` は形が合わない。`npx @himorogy/karakuri init` / `sync` のような、何度でも実行できる注入コマンドが適切である。既存の後付けスクリプトの思想の延長になる。

生成器のソースは `example/` ではなく `templates/` に置き、公開パッケージに同梱してそこから読む。`example/` は「読むもの」、`templates/` は「実行時に読まれるもの」で役割が異なる。リポジトリのツリーを直接参照すると版の固定ができない。

---

## 9. 移行手順

| 順   | 作業                                                                                                                                      | 効果                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| 1   | `dotenvx run --` に統一                                                                                                                    | 最小の変更で T3 の大半が落ちる |
| 2   | `images/runtime-base` の切り出し。shim（三値意味論、`env -u NODE_OPTIONS` 込み）/ `prod-entrypoint.sh` / `git-askpass` / `core.hooksPath` + hook を実装               | I3 / I5 / T6      |
| 3   | `compose.prod.yaml` 一式の導入 — stdin 注入・bind mount 撤去・`read_only` + tmpfs（`/src` 込み・`exec` と `uid=`/`gid=` の明示）・`logging: none`・`ulimits: core: 0`。broker 選定と鍵束のキーチェーン移設を含む。entrypoint が secrets 取込と clone を一体で担うため、この段は分割できない | I1 / I2 / I4 / I7 / T2 / T4 / T5 |
| 4   | reusable workflow の設置とスタブ配布（precommit の CI 実効性を先に実測 — §8.2）                                                                             | T6 の CI 側         |
| 5   | ~~prod-shell の廃止~~ / ~~enclave-env の去就判断~~ / ~~出荷物からの設計書記号の一括棚卸し（§4.8）~~ ← **rev.8 で完了**                                                                                                        | —                 |

**手順 1〜3 は実装済み**（2026-08-06、ブランチ `feat-new-prodshell`）。docker を要する検証は CI（`runtime-base-verify`）で 10 回実行し、rev.5 の内容はその実測に基づく。結果は `images/runtime-base/verification-record.md` に §10 の全項目の状態として記録してある。

**手順 4 は rev.7 で実装した。** 前提だった「`dotenvx precommit` の CI 実効性」は実測で決着し（D23）、当初案を破棄して tracked ファイルの直接走査へ差し替えた。残るのは他 org の private リポジトリからの呼び出し確認で、これは他 org の repo が要るためこの環境では実測できない（§10 / 検証記録）。

---

## 10. 検証項目

**消化状況は `images/runtime-base/verification-record.md` を正とする**（rev.5）。全項目について実施済み / 未実施 / この方法では実施不能の別と、実測値をそこに記録してある。docker が要る項目は CI（`.github/workflows/runtime-base-verify.yml` が `images/runtime-base/tests/verify-docker.sh` を実行する）で消化する。ハーネスは**測定**（答えが未確定の項目。pass/fail 判定をせず観測事実を出す）と**表明**（確定済みの性質。落ちればジョブが赤くなる）を分けて出力する。

以下は項目の一覧であり、チェックボックスの状態は記録側と二重管理しない。

- [ ] stdin 注入: entrypoint 実行後、`/run/secrets/<VAR>` が存在し、mode 600・tmpfs 上（`mount | grep /run`）であること
- [ ] `docker inspect` の `Config.Env` / `Mounts` に secret が一切現れないこと
- [ ] 空値 secret（`KEY=""`）で entrypoint が非ゼロ終了すること。stdin 空でも非ゼロ終了すること
- [ ] broker 出力の形式（quoting / 改行）と entrypoint パーサの整合（値に `=` を含むケースを含む）
- [ ] broker: 非対話環境（プロンプト不可）で非ゼロ終了し、`pipefail` 下でパイプ全体が止まること（broker exit≠0 かつ docker exit=0 の組合せを実際に作って確認）。macOS `security` の ACL 設定（毎回確認 / Touch ID / 常時許可）ごとの挙動確認
- [ ] clone 後に `/run/secrets/GH_TOKEN` が削除され、`exec "$@"` 後のコードから読めないこと
- [ ] shim が `pnpm run` / Makefile 経由でも効くこと
- [ ] **`pnpm run` の内側でローカル依存の dotenvx が呼ばれた場合に鍵が届くこと**（`pnpm run` は `node_modules/.bin` を PATH 先頭に積むため、プロジェクトがローカルに dotenvx を持つと shim が素通りされる。最上位に `dotenvx run -f ... -- pnpm ...` を置けば shim が export した鍵を子プロセスが継承する、の確認。**§4.3 / D5 の「PATH 解決を経由する shim であれば全経路で効く」は誤りであり、rev.5 で訂正する**）
- [ ] shim: `/run/secrets/<VAR>` が空ファイルのとき非ゼロ終了すること
- [ ] shim: ファイル不在時に素通しになり、dev container で既存の dev 向けトークン注入（env var / ファイルいずれの方式でも）と共存して wrangler / gh / dotenvx が動くこと
- [ ] dotenvx shim: `DOTENV_PRIVATE_KEY_*` 複数注入時に `-f .env.<name>` へ対応する鍵が選ばれること（`_LOCAL` + `_DEVELOPMENT` 同居の dev 想定）
- [ ] **dotenvx 2.x で `DOTENV_PRIVATE_KEY_*` の環境変数注入が従来通り効くこと**（2.0.0 は keyring 対応にあわせて `run` / `config` / `get` を `@dotenvx/primitives` 由来の共有 resolver 経由へ付け替えている。本設計の shim はこの経路に全面的に依存するため、実測せずに前提にできない）
- [ ] **dotenvx 1.x で暗号化した `.env.*` を 2.x が復号できること**（既存 4 repo は dotenvx 1.x 系（`^1.63.0`）で運用しており、イメージ側だけ 2.x に上げる構成になる）
- [ ] prod container: 必要 secret を欠いた状態で下流コマンドが認証失敗として**顕在化**すること（`$HOME` tmpfs により fallback 資格情報が拾われないことを含む）
- [ ] dev container に `/var/run/docker.sock` がマウントされていないこと（§2.1 の前提。devcontainer 構成変更時の恒常チェック）
- [ ] `logging: driver: none` でもアタッチ時に stdout が手元に表示されること
- [x] 対話二段構え: **`run -dT` は不成立と実測**（2026-08-08、macOS 実機。broker が Broken pipe / entrypoint が stdin EOF 待ちで停止 / `sleep` 未実行で自動回収消滅 / secret ゼロのまま exec 可能だが prod-context は警告した）。標準手順を attached 2 端末形へ改訂（§6.4 / D29）。**attached 形は実測で成立**（2026-08-14: TTY シェル取得・prod-context の鍵名表示・`/run/prod-ref`・`pnpm install` 完走・`_wrangler` / `_dotenvx` 動作）。回収も実測済み: pid 1 = `sleep` が Ctrl-C / SIGTERM を無視することを実測 → `init: true` を compose に追加（§6.4）→ init 有りで Ctrl-C 一発 → 終了・回収まで通ることを確認（2026-08-14）。**対話二段構えは attached 2 端末形で完了**
- [ ] `GIT_REF` 未指定時に compose が失敗すること
- [ ] `read_only: true` + tmpfs 構成で `git fetch` / `pnpm install` / ビルドが完走すること（`/home/node` の書き込み先、named volume `/src` の所有権を含む）
- [ ] `/src` 非空・`.git` 無しの状態（前回失敗の残骸）から entrypoint が復帰できること
- [ ] **named volume 再利用時に tracked file の改変が復元されること**（前回実行で `/src` の tracked file を書き換えたうえで同じ `GIT_REF` で再実行し、内容が ref のものに戻っていること。rev.4 の `reset --hard` が効いているかの確認）
- [ ] entrypoint のパース失敗メッセージに入力行・鍵名が出ないこと（`=` を含まない行を stdin に与え、stderr にその行が現れないこと）
- [ ] shim: secret ファイルが「存在・非空だが読めない」とき（mode 000 等）に空値注入ではなく非ゼロ終了すること
- [ ] 起動ラッパー: docker 側が先に失敗して broker が SIGPIPE（141）で落ちたとき、docker 側の終了コードと原因が報告されること
- [ ] **`/src` の tmpfs マウントに `exec` が付いていること**（付いていないと `node_modules/.bin` の実行ファイルが動かず、ビルドも deploy も成立しない。`mount | grep ' /src '` の出力で直接確認する）
- [ ] **`/run` と `/out` は `noexec` のままであること**（緩めていないことの確認）
- [ ] **tmpfs が `uid=1000` 所有で作られていること**（素の短縮形は root:root になり entrypoint が `/run/secrets` を作れない）
- [ ] **named volume 再利用時の N-1（ローカル ref の汚染）が、tmpfs 構成では成立しないこと**（前回実行で `git tag <ref> <別コミット>` を打ったうえで同じ `GIT_REF` で再実行し、fail-closed になること）
- [ ] **N-2（`.git/config` の `core.fsmonitor` 等の持続）が tmpfs 構成では成立しないこと**（前回実行で仕込んだ設定が次回の entrypoint の git 操作で発火しないこと）
- [ ] 存在しない `GIT_REF` を渡したとき、`does not resolve to a commit` として落ちること（`--detach does not take a path argument` にならないこと）
- [ ] **pnpm の store が node_modules と同一 tmpfs 上にあり、ハードリンクが効いていること**（`find node_modules -type f -links +1` の比率と、`pnpm install` の出力が `hard linked` であって `copied` でないこと）
- [ ] **`dotenvx run --strict` が鍵なしで rc=1 になること**、および `--strict` を欠いた場合に rc=0 で暗号文が値として注入されること（D20 の根拠の回帰）
- [ ] `pnpm run` の内側でローカル依存の dotenvx が呼ばれた場合に鍵が届かず、最上位に `dotenvx run` を置けば届くこと（D5 の訂正の回帰）
- [ ] **40 桁 hex でない `GIT_REF` が既定で拒否されること**、および `PROD_ALLOW_MUTABLE_REF=1` のときだけ警告付きで続行すること（D21）
- [ ] **解決済み commit sha が stderr と `/run/prod-ref` に記録されること**。可変 ref を許した場合も記録されること
- [ ] `$HOME` が書けない構成で store-dir 直書きの前に明示的な診断が出ること
- [ ] `/src` に `exec` が無い構成で、`node_modules/.bin` の実行を待たずに entrypoint が明示的に落ちること
- [ ] 対話シェルで注入済みの鍵名が表示され、**値は表示されない**こと
- [ ] entrypoint が secret 書き込み後・トークン破棄前に異常終了した場合、コンテナ停止で tmpfs ごと解放され secret が残らないこと
- [ ] `dotenvx get -f .env.prod` がファイルを生成しないこと
- [x] ホストの `core_pattern` とコアダンプ抑止（2026-08-14、macOS / Docker Desktop 実機）: `ulimits: core: 0` 下で `node -e 'process.abort()'` は `Aborted`（`core dumped` 表示なし）でコアファイル無し。否定対照 — `--ulimit core=-1` の素のコンテナで同じ abort → **`Aborted (core dumped)` + cwd に 321MB の `core`**（VM の実効 core_pattern は相対名で、行き先はプロセスの cwd。writable layer の cwd なら VM の不揮発ディスクに落ちる）。抑止が唯一かつ実効の防波堤であることを両方向で確認
- [x] **credential helper が生きていると `GIT_ASKPASS` が呼ばれないこと**、および VS Code が environ へ注入した askpass が生きていても自前 helper が勝つこと（2026-08-16。`git credential fill` と、Basic 認証を要求するローカル HTTP サーバへの実 clone の両方で確認。否定対照込み。`images/runtime-base/tests/git-credential.test.sh` が回帰として常時走る）
- [x] **認証成功後の `store` が全ての helper へ配られること**（打ち消しと自前 helper を組み合わせる根拠。実 clone で VS Code 相当の helper が注入トークンを受け取ることを観測。打ち消しを併用すると宛先が自前 1 本になることも確認。2026-08-16）
- [x] **helper の無応答・非ゼロ終了がフォールスルーすること**、および `quit=1` だけが連鎖を止めること（2026-08-16。トークン不在時に敵対的な askpass が呼ばれないことまで確認）
- [x] **統合ターミナルの `GIT_ASKPASS` が VS Code のものに差し替わっていること**（2026-08-16、実機。`GIT_TRACE=1` で VS Code の askpass.sh が起動される様子を観測。打ち消しのみの対策が不十分だった根拠）
- [x] **設定がビルドされたイメージの ENV に載っていること**（`verify-docker.sh` の M6 で表明。2026-08-17 に devcontainer-base 2.2.0 の実機でも確認）
- [x] **SSH セッション（`/etc/environment` → pam_env）でも 5 変数が効いていること**（2026-08-17、`sshd -i` を `docker exec` のパイプ上で動かす ProxyCommand 経由の実機。sshd はセッションの環境を自分の environ から引き継がないため、5 つ出ていること自体が転記の証拠になる。空値の `GIT_CONFIG_VALUE_0` も落ちない）
- [x] **`GH_TOKEN` 注入済みの実機で、github.com への https 操作が自前 helper 経由で成功すること**（2026-08-17、devcontainer-base 2.2.0 の統合ターミナル。`GIT_TRACE=1` で `get` も `store` も自前 helper だけを通ることまで確認 — 認証成功後の書き戻しがホストへ出ないことの直接の確認）
- [x] **トークン不在で即座に失敗し、端末プロンプトにも落ちないこと**、および同一 URL の否定対照（5 変数を外すとホスト資格情報で成功する）（2026-08-17、実機）
- [x] **public repo が影響を受けないこと**（トークン不在のまま ref が返る。401 が返らず credential 解決自体が起きないという主張の実測。2026-08-17）
- [ ] `core.hooksPath` 設定下で、平文 `.env` のコミットが実際に拒否されること
- [ ] husky を使うプロジェクトで、チェーン先の hook が引き続き実行されること
- [ ] **ホストの GUI クライアント（Fork）から平文** `.env` **を commit しようとして実際に拒否されること**(現行の simple-git-hooks 構成で今どうなっているかの確認を含む)
- [ ] `node_modules` が named volume か bind mount かの確認（ホスト側 hook のパス解決に影響する）
- [ ] ホスト側 hook が、依存バイナリを解決できない場合に非ゼロ終了すること（沈黙して通過しないこと）
- [ ] prod container 内でも hook が有効であること（runtime-base 配置の確認）
- [ ] **CI（クリーン checkout・差分ゼロ）で `dotenvx precommit` が実際に検出能力を持つか**（no-op なら §8.2 の fallback へ差し替え）
- [ ] 他 org の private リポジトリから karakuri の reusable workflow が呼び出せること（caller 側 Actions allowlist の設定手順を含めて文書化）

rev.7 で追加した項目:

- [ ] **`/src` が tmpfs でない構成（named volume へ戻す一行）で entrypoint が明示的に落ちること**、および secret の書き込み先が tmpfs でない構成でも同様に落ちること
- [ ] **該当行が `/proc/mounts` に無い場合に WARNING を出して続行すること**（黙ってスキップしないこと）
- [ ] **40 桁 hex を名前とする ref（オブジェクトは不在）を `GIT_REF` に渡したとき非ゼロ終了し、`/run/prod-ref` に記録が残らないこと**。あわせて現行 git がこの ref をどう扱うかを記録する（git 2.39.5 では `rev-parse` が意図的に無視することを実測済み）
- [ ] **大文字の完全 commit sha が誤って拒否されないこと**（小文字への畳み込みの回帰）
- [ ] **`GIT_REPO` に資格情報を埋めた URL を渡すと非ゼロ終了し、stderr にトークンが現れないこと**。ssh 形式（`git@host:owner/repo.git`）は誤検知しないこと
- [ ] **dotenvx shim: prod 鍵が注入済みで `run` に `--strict` が無いときだけ警告が出ること**。`--strict` あり / prod 鍵不在では出ないこと。警告の有無で実体への引数と rc が変わらないこと（D22）
- [ ] **prod-context: `/run/secrets` が存在して空のとき、zsh でもエラーを出さずに完走すること**
- [ ] **pre-commit hook: サブディレクトリの `.env.keys` を検出すること**。`node_modules` 配下は無視すること。`find` 自体が失敗した場合に、その理由が読み取れる形で fail-closed になること
- [ ] **CI の env-guard が平文の tracked `.env` を実際に検出すること**（合成 fixture による検知能力の証明。「0 件検査して緑」と「N 件検査して緑」が出力から区別できること）
- [ ] **karakuri 自身が env-guard スタブで自分を呼んでいること**（伝播機構を自分で使っていること）
- [ ] **hook と CI が同一の fixture に対して同一の判定を返すこと**（staged 経由と tracked 経由の両方から通す。D24 の本題であり、赤くなる形を作って確認する）
- [ ] **設定ファイルによる上書きが hook と CI の両方に効くこと**。設定ファイルが壊れている・読めない場合に fail-closed になること
- [ ] **設定ファイルが `source` されないこと**（実行可能な内容を書いても実行されないこと）
- [ ] **CI が使うスキャナが、reusable workflow の意図した版であること**（`@v1` で呼ばれて main のスキャナを実行しないこと）。rev.8 で方式が変わった — workflow 自身の ref を割り出すのではなく、npm の版を workflow ファイルに直書きし、取得物を SHA256 で照合する（D27 / §8.2）
- [ ] 検出時の出力に平文の値が含まれないこと（ファイル名・行番号・鍵名まで）。`=` を含まない行では鍵名すら出さないこと
- [ ] **イメージが named build context 経由でスキャナと hook を焼き込めること**（D26）。ビルドを行う workflow が 2 つあり、**両方で通ること**（片方だけに `build-contexts` を足すと、もう片方が `COPY` で落ちる）
- [ ] **npm から取得したスキャナの SHA256 照合が、改竄を検知すること**（D27 / G）。期待値と違えば非ゼロで終わり、**実行可能な状態のファイルを残さない**こと（照合前に `chmod +x` へ到達しないこと）
- [ ] **`env-guard install` が、書いただけで成功と報告しないこと**（§4.7）。`.git/hooks/pre-commit` が実在し・実行可能で・意図した hook を呼び・その呼び先がディスク上にあることまで確かめること。既存の pre-commit コマンドがある場合は上書きせず落ちること

---

## 11. 未決事項

- **実行ホストの一本化**: Mac / Windows ミニ PC のどちらで prod 実行を行うか。swap 経由の露出（R7）はメモリに余裕のある側に寄せるのが一貫する。Linux ホストに一本化できるなら `file:` ソース + `/dev/shm` の代替（§4.1）も開ける。**rev.5 でこの判断の重みが増した** — `/src` が tmpfs になったため、repo と `node_modules` と pnpm store が全て RAM に載る。tmpfs の既定サイズはホスト RAM の 50%（CI ランナーで 7.9G、実測の使用量は karakuri 自身で 131M）。依存の重いプロジェクトを載せるなら実行ホストのメモリ量が直接の制約になる。**rev.9 実機実測（macOS / Docker Desktop VM 7.65G）**: 1137 パッケージのモノレポの `pnpm install` はコンテナのメモリピーク実測 1.07G（cgroup memory.peak）で、dev container 群と同居した VM（大口は 4.9G + 1.0G）では **VM 全体の OOM で `Killed`** になった（コンテナ側の cgroup 上限は無し = 犯人はコンテナでなく VM の頭数）。tmpfs 使用量自体は途中時点で 214M / 3.9G と余裕。dev 同居運用なら VM への割当は 12G 級が必要。
- **署名タグの検証**: rev.6 で `GIT_REF` は完全な commit sha を強制するようにした（D21）。署名タグを使いたい場合は `git tag -v` 相当の検証を entrypoint に入れる必要があり、信頼する公開鍵をどこから持ってくるか（イメージに焼く / broker で渡す）が未決。実装するまでは `PROD_ALLOW_MUTABLE_REF=1` が唯一の逃げ道で、これは検証を伴わないため「危険を理解した上での選択」以上のものにはならない。
- **prod container への egress-guard 適用**: `compose.prod.yaml` は `cap_add: [NET_ADMIN, NET_RAW]` も firewall 起動も持たない。したがって**この構成のままでは prod に egress 制限は掛からない**。適用するには capability 追加と root での firewall 初期化が必要で、「能力は最小に」（§4.5 の配置規約）と緊張関係にある。prod は信頼境界の内側（§2.1）だが、依存パッケージの supply chain に対する多層防御としての価値はある。エージェント不在の prod で egress 制御に払うコスト（caps + entrypoint の root 化）が見合うか、実装時に判断する。

  **rev.6 でこの項目の重みが増した。** `--no-armor` をイメージ側で強制しないと決めた（D20）ため、dotenvx 2.x が既定で有効にする Armor（秘密鍵をリモートに置く仕組み）への経路が prod に残る。本設計は秘密鍵を broker → stdin → `/run/secrets` → shim の一本道で運ぶと決めており、リモート解決はその外側にある。フラグを個別に追いかけるより、**egress を面で塞ぐ方が筋がいい** — Armor だけでなく `bw://`（Bitwarden 参照）や将来増える同種の機構もまとめて止まる。

  **ただしこれは「繰延」であって「緩和」ではない（rev.7 で明示）。** 方向が正しいことと、その方向がまだ実装されていない間の状態が守られていることは、別である。フラグによる個別の抑止も面による遮断も無い構成では、この経路は開いたままになる。その空白を埋めるための暫定措置を以下に置く。

  - prod の運用手順書に `dotenvx run` の必須オプションとして `--strict --no-armor` を明記する（§6.2 に記載済み）
  - `--strict` の欠落は shim が警告する（D22）。**`--no-armor` の欠落には対応する警告を置かない** — `--strict` の欠落が「静かに壊れた値で動く」という自分の環境内で完結する事故なのに対し、`--no-armor` の欠落は「外へ出る」事故であり、警告で足りる性質ではないと判断した。面で塞ぐまでは残余リスクとして開いたまま数える（R12）
  - egress-guard の prod 適用を決めるまでは、この項目を §11 の未決の中で**最優先**として扱う
- **他 org 展開時のイメージ配布**: `ghcr.io/himorogy/runtime-base` を各 org から pull させるか、org ごとにミラーするか。

### rev.9 で決着し、未決から外したもの

- ~~ホスト側 hook の導入コマンド~~ → **`env-guard install` として実装済み・macOS 実機で実測済み**（2026-08-14）。方式は rev.8 で確定した A（simple-git-hooks との併用）のまま — `env-guard install` が package.json の `simple-git-hooks.pre-commit` に冪等に書き、`--check` が導入状態を検査する。実測: ホスト（ターミナル・Fork GUI）から平文 `.env` の commit が hook で拒否され、スキャナを欠いた状態では無害ファイルの commit も「Refusing to commit while this check cannot run」で fail-closed に落ちる。副産物として、dev container 内で `--check` が偽陰性を出すバグ（core.hooksPath のイメージ hook はスキャナを直接呼ぶ設計で、node_modules 経路だけを正としていた）を実測で発見し修正した。

- ~~broker の具体選定~~ → **Bitwarden CLI（native ビルド、版 pin + SHA-256 照合）を標準に確定**（D30）。macOS 実機での実測比較の結果。Keychain 参照実装は、単一行しか受けない登録プロンプトの base64 迂回と partition list の二重プロンプトを潰してなお登録の体験が重い。bw は unlock 1 回で複数項目のマージまで完結する。keychain 実装は代替の参照実装として残す。bw はクロスプラットフォームのため Windows 側の選定も同時に閉じる見込み（Windows 実機の実測は未実施）。チーム共有鍵は Bitwarden の共有コレクションに載り、「運用者間の受け渡しはチームのパスワードマネージャで行う」（§4.1）が同一ツール内で閉じる。
- ~~対話 prod shell の要否~~ → **二段構えを標準手順として確定**（§6.4 / D29）。非対話への一本化案（rev.8 までの第一候補）は撤回。旧選択肢のうち (b)（secret 不要な素の `run` シェル）は二段構えで代替でき、(c)（Linux ホスト一本化 + `file:` ソース / `/dev/shm`）は「実行ホストの一本化」の側に残した。

### rev.5 で決着し、未決から外したもの

- ~~`git clean -xdff` と node_modules 保持のトレードオフ（`-e node_modules` 除外の可否）~~ → **消滅**。`/src` が tmpfs になった以上、run をまたいだ node_modules の保持は元から成立しない（D18）。
- ~~compose の tmpfs 記法（`uid=`/`gid=` が効くか）~~ → **実測で決着**。効く。加えて `exec` の明示が要ることも判明した（§4.2）。
- ~~dotenvx 2.x で `DOTENV_PRIVATE_KEY_*` の env 注入が効くか / 1.x で暗号化したファイルを 2.x が復号できるか~~ → **実測で決着**。どちらも効く（§4.3）。
- ~~`read_only` 下で `pnpm install` が完走するか~~ → **実測で決着**。store を node_modules と同一 tmpfs に置けば、`prepare` のビルドまで完走する（D19）。
- ~~store-dir の固定手段（`pnpm config set` の書き込み先が特定できない）~~ → **判明**。`pnpm config set store-dir <path>` は **`$HOME/.config/pnpm/config.yaml`** に **YAML** で `storeDir: <path>` と書く。手で置いた `$HOME/.npmrc` / `$HOME/.config/pnpm/rc` が効かなかったのは、**ファイル名と形式の両方が違った**ためである（`store-dir=` ではなく `storeDir:`）。prod では `/home/node` が tmpfs なので毎回新規に書かれ、entrypoint が毎回設定する形と整合する（§4.6）。イメージに焼かない判断（dev は store が `/workspaces/.pnpm-store` にあり `/src` を持たない）も変わらない。
