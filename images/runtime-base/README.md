# runtime-base

prod container と devcontainer の**共通土台**になるイメージ。

```
ghcr.io/himorogy/runtime-base:1
```

`images/devcontainer-base` はこのイメージを `FROM` で継承する。二層にしている理由は、prod
のレイヤ集合が dev のレイヤ集合の**真部分集合**になるからで、これにより prod のサプライ
チェーン面積が構造的に dev を超えないことが保証される。共通の第三のベースを両者が継承する
構成ではこの性質は得られない。

本 README は収録物と運用手順を扱う。設計の全体像・脅威モデル・判断根拠は
[`docs/prod-secret-isolation-design.md`](../../docs/prod-secret-isolation-design.md) にある。
個々の判断の根拠は、それが効いている場所（entrypoint のコメント、
`templates/host/compose.prod.yaml` のコメント）にも書いてある。

---

## 何が入っているか

| 種別 | 中身 |
|---|---|
| 実行系 | Node 24、pnpm、dotenvx、wrangler、git、gh |
| secret 注入 | `wrangler` / `gh` / `dotenvx` の shim、`prod-entrypoint.sh`、`git-credential-gh-token`、`git-askpass` |
| 制約 | `core.hooksPath` + pre-commit hook、egress-guard 本体と sudoers、github.com の credential helper の固定（`GIT_CONFIG_COUNT` 系）と `git-auth-check` |

入っていないもの（= devcontainer-base 側に積む）: crit、エージェント類、zsh / less / man-db /
ripgrep / fd / vim-tiny 等の対話系、シェル履歴の永続化設定、`/workspaces`。

### 配置規約 — 能力は最小に、制約は最大に

| 種別 | 例 | 配置 |
|---|---|---|
| **能力** — できることを増やすもの | エージェント、crit、対話ツール | prod で使わないなら runtime-base に**入れない** |
| **制約** — できることを減らすもの | git hook、`core.hooksPath`、egress ポリシー | **全層に入れる**（= runtime-base に置く） |

真部分集合の関係が守っているのは攻撃面であり、制約を足しても攻撃面は増えない。したがって
「prod で実行しないものは入れない」は**能力にのみ**適用する。

制約を下層に置く積極的な理由は、「prod で実行しない運用であるはずだが、実行できてしまう」
経路を塞ぐことにある。運用上コミットが prod で起きない前提であっても、起きた場合に検査が
効く状態にしておく。

---

## secret の受け渡し

環境変数を一切経由しない。

```
broker（ホストの OS キーチェーン等）
  → stdout
  → パイプ
  → docker compose run -T の stdin
  → prod-entrypoint.sh
  → /run/secrets/<変数名>（コンテナ内 tmpfs、mode 600）
  → shim が実行時にだけ環境変数として注入
```

この経路の結果、平文はホストシェルの environ にも、compose プロセスの environ にも、
`docker inspect` の `Config.Env` にも現れない。

### なぜ compose の `secrets:` を使わないのか

使えないから。compose の `environment` / `content` ソース secrets は bind mount では**なく**、
コンテナ作成後・起動前に Docker API（CopyToContainer）で**コンテナの writable layer へ書き込まれる**。
writable layer は `/var/lib/docker/overlay2`、すなわちホスト（Docker Desktop では VM）の不揮発
ディスクである。さらに `read_only: true` と併用すると書き込み先が read-only になり**起動そのものが
失敗する**（docker/compose#12031、#12303）。`tmpfs: ["/run/secrets"]` を足しても効かない。

公式ドキュメントの「`/run/secrets/<name>` に bind mount される」という記述は `file:` ソースにのみ
当てはまる。

---

## shim の仕組み

`wrangler` / `gh` / `dotenvx` は、実行のたびに `/run/secrets/<変数名>` の有無を見て secret を
注入する薄いラッパーに差し替えてある。

意味論は**三値**で、環境の判別は一切しない。

| `/run/secrets/<VAR>` | ふるまい |
|---|---|
| 存在する（非空） | その値を環境変数として注入し、実体を exec する |
| 存在するが空 / 読めない | 非ゼロ終了する |
| 存在しない | プロセス環境をそのまま引き継いで実体を exec する（素通し） |

prod では entrypoint が prod secret を書き、dev では dev 向けのトークンが別機構で与えられる。
どちらでも同じ shim が同じように振る舞う。

`dotenvx` の `<VAR>` は `wrangler` / `gh` と違って固定 1 個ではなく、対応する `.env` ファイルごとに
`DOTENV_PRIVATE_KEY*` の glob で複数ありうる。素の `.env` を使うプロジェクトの鍵ファイルは
`/run/secrets/DOTENV_PRIVATE_KEY`（無サフィックス）、`.env.<環境名>` を使うプロジェクトの鍵ファイルは
`/run/secrets/DOTENV_PRIVATE_KEY_<環境名>`（大文字。例: `.env.prod` → `DOTENV_PRIVATE_KEY_PROD`）になる。

**シェル関数ではなく PATH 上の実行ファイルにしてある。** `pnpm run` / Makefile / `xargs` は
`sh -c` を起動して rc を読まないため、関数はスコープ外になって素のバイナリが呼ばれる。
PATH 上の実行ファイルであればこれらの経路でも効く。

### ただし `pnpm run` の内側では効かない

`pnpm run <script>` は `node_modules/.bin` を PATH の**先頭**に積む。プロジェクトが
`@dotenvx/dotenvx` をローカル依存に持っていると、script 内の `dotenvx` はそちらへ解決され、
**shim は素通りされる**。既存の 4 リポジトリはいずれもローカルに dotenvx を持つ。

したがって **prod では dotenvx を最上位に置く**。

```sh
# 効く — 最上位の dotenvx が shim に解決され、export した鍵を子プロセスが継承する
prod-run.sh dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy

# 効かない — pnpm が node_modules/.bin を先頭に積み、ローカルの dotenvx が呼ばれる
prod-run.sh pnpm deploy
```

後者は鍵が無い状態で復号を試みるが、**`--strict` が無いと沈黙する** — dotenvx は復号に失敗
しても非ゼロ終了せず、暗号文をそのまま値として注入して rc=0 を返す（実測: `FOO=encrypted:...`
のままアプリが起動し、deploy は成功と報告される）。`--strict` を付ければ確実に rc=1 になる。

### `--strict` / `--no-armor` はイメージ側で強制しない

prod の運用手順としては必須だが、**このイメージは強制しない。**

強制できる場所は shim しかない。しかし shim は devcontainer-base にも継承され、`--strict` は
**正当な使い方を壊す** — dotenvx には `--convention flow`（`.env` / `.env.local` /
`.env.development` を重ねる規約）があり、この規約では一部のファイルが存在しないのが正常である。
実測すると、`.env` と `.env.local` があって `.env.development` が無い状態で
`--convention flow --strict` は rc=1 で落ちる（欠けていると言われるのは `.env.development.local`）。
`--no-armor` も、dev の開発者が自分の dev 鍵を Armor で管理している運用を壊す。

**これは dotenvx の使い方の問題であってコンテナの責務ではない。** shim がプロジェクトの env
構成を知らないまま焼く判断ではない。付け忘れたときに何が起きるかは上記のとおりで、下記の
「git hook」と同じく**予防ではなく運用手順**の位置づけになる。

### ただし黙ってはいない — shim が警告する

強制しないことと黙ることは別である。`--strict` を欠いたときの失敗は rc=0 で暗号文が値として
注入される静かなものなので、忘れたことに気付く機会が一度も無くなってしまう。

shim は以下を**すべて**満たすときだけ、stderr へ 1 行（3 行に折り返して）出す。

- 引数に `run` がある
- 引数に `--strict` が無い
- `/run/secrets/DOTENV_PRIVATE_KEY_PROD*`（glob）に一致するファイルが存在する

```
dotenvx: WARNING: production key is injected but --strict
dotenvx:   is absent. dotenvx exits 0 even when decryption
dotenvx:   fails, injecting the ciphertext as the value.
```

見ているのは「環境」ではなく「注入済みの prod 鍵ファイルの有無」である。shim の三値意味論
（存在→注入 / 空→エラー / 不在→素通し）は環境を判別しない設計であり、prod 鍵の観測はその設計と
矛盾しない。**dev には prod 鍵が来ない設計なので、dev では一度も出ない。**
`--convention flow` も `--ignore=` も壊さない。

なお `-f` でファイルを明示した場合、不在ファイルは `--strict` の有無に関わらず rc=1 になる
（実測）。prod は `-f .env.prod` を明示する運用なので、prod で `--strict` が追加で担うのは
**復号失敗の顕在化だけ**である。

`--no-armor` の根本対処は prod への egress 制限に寄せる。フラグを個別に追いかけるより、
外への通信を面で塞ぐ方が Armor 以外の同種の機構もまとめて止まる。

この制約は shim 一般の性質であって dotenvx 固有ではない。`wrangler` / `gh` をローカル依存に
持つプロジェクトでも同じことが起きる。

### 実体は `/opt/tools/bin` にある

PATH は `${PNPM_HOME}/bin:${NPM_CONFIG_PREFIX}/bin:${PATH}` の順で、**npm global bin が
`/usr/local/bin` より先に来る**。したがって shim を `/usr/local/bin` に置くだけでは、npm global
直下に残った実体に PATH 解決で負けて素通りされる。

対処として、実体は `/opt/tools/bin`（PATH には載せない）へ退避し、`/usr/local/bin` に shim を置く。
npm がグローバル領域に張るシンボリックリンクは相対パスなので、単純な `mv` ではリンク切れになる。
`readlink -f` で絶対パスの実体を解決してから新しいリンクを張っている。

この関係が壊れると shim が黙って素通りするだけで、失敗が表面化しない。Dockerfile に
`command -v` による**ビルド時検証**を焼いてあり、PATH 順や配置が変わった時点でビルドが落ちる。
push されたイメージに対しても CI の smoke test が同じ検証を行う。

### 注入済みの鍵は対話シェルで見える

`/run/secrets` のファイル名は環境変数名そのものなので、**名前だけなら安全に出せる**。対話
シェルの起動時に一覧が出る（値は出さない）。

```
$ docker exec -it <container> bash
karakuri-context: 注入済み: DOTENV_PRIVATE_KEY_LOCAL GH_TOKEN
karakuri-context: GIT_REF=main GIT_COMMIT=4f3a9c2b8e1d7a05... (mutable ref)
git-auth-check: 実効 helper=/usr/local/bin/git-credential-gh-token / イメージ固定: 生きている
```

これが効くのは主に dev である。`DOTENV_PRIVATE_KEY_LOCAL` は持つが `_DEVELOPMENT` は持たない、
という**権限階層を鍵束で表現する**運用があり、持っていない鍵を要する操作は復号失敗として
現れる。何が注入されているかが見えれば切り分けが早い。

「持っているべき鍵の一覧」はプロジェクト固有なので、このイメージには持てない。**注入済みの
ものを列挙するだけ**で、無いものは映らない。

### 素通しは fail-open ではない

prod container は `/home/node` が tmpfs で毎回空であり、`~/.wrangler` / `~/.config/gh` 等の
fallback 資格情報が存在しえない。したがって必要な secret を欠いたコマンドは、下流の認証失敗
として顕在化する。加えて entrypoint が取込件数 ≥ 1 と各値の非空を検証している。

---

## git の認証（github.com）

plain な `git` の `clone` / `fetch` / `push` は shim を通らない。github.com への認証は、イメージ
自前の credential helper `/usr/local/bin/git-credential-gh-token` が `/run/secrets/GH_TOKEN` を
読む経路に固定してある。トークンが無ければ helper が `quit=1` を返し、git は他の経路へ落ちずに
その場で失敗する。

### なぜ askpass ではなく helper なのか

git は credential helper を設定順（system → global → local → 環境変数）に呼び、**最初に資格情報を
返した helper で解決を確定する**。`GIT_ASKPASS` は「どの helper も答えなかった場合」の
フォールバックにすぎない。

dev container では VS Code の Dev Containers 拡張が **2 つとも握っている**。

1. 接続のたびに global の gitconfig へ credential helper を書き込む
2. 統合ターミナルの environ へ `GIT_ASKPASS` を注入して上書きする

1 だけを潰しても 2 が残る。実測（統合ターミナル内、打ち消しのみを入れた状態）:

```
$ echo $GIT_ASKPASS
/vscode/vscode-server/bin/<hash>/extensions/git/dist/askpass.sh
$ GIT_TRACE=1 git ls-remote https://github.com/<org>/<repo>.git
...
trace: run_command: /vscode/vscode-server/bin/<hash>/extensions/git/dist/askpass.sh 'Password for ...'
```

helper は 1 本も呼ばれていないのに、フォールバック先が VS Code のものに差し替わっていた。
`GIT_ASKPASS` は environ なので、イメージの `ENV` は接続のたびに上書きされる。

一方 credential helper は**設定**であり、環境変数による設定（`GIT_CONFIG_COUNT` 系）は
**全ての設定ファイルを読んだ後**に適用される。gitconfig の記述順にも environ の注入にも
左右されずに認証先を固定できるのは、こちら側だけである。

### スロット 0 で捨て、スロット 1 で積む

```
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=credential.https://github.com.helper
GIT_CONFIG_VALUE_0=                                        # 空 = それまでの helper を捨てる
GIT_CONFIG_KEY_1=credential.https://github.com.helper
GIT_CONFIG_VALUE_1=/usr/local/bin/git-credential-gh-token  # 自前を積み直す
```

結果、github.com の helper 一覧は**自前の 1 本だけ**になる。得られる性質が 4 つある。

- **`GIT_ASKPASS` の乗っ取りが無関係になる。** 認証は helper で確定し、askpass に到達しない
- **`store` の宛先が自前 1 本だけになる。** git は認証に成功すると資格情報を `store` で
  **全ての** helper に配る。VS Code の helper が一覧に残っていると、注入した fine-scoped な
  トークンがそこを経由してホストの資格情報ストアへ書き戻る（実 clone で観測。
  `verification-record.md`）。打ち消しが先にあるので、この書き戻し先ごと消える
- **URL に埋まった username を上書きできる。** `dev.containers.copyGitConfig` でホストの
  gitconfig が持ち込まれると、`[url "https://<user>@github.com/"] insteadOf` のような設定で
  username が固定されることがある。helper が返す `username=x-access-token` が使われる
- **打ち消しは URL 限定。** github.com 以外のホストの helper はそのまま残る

`VALUE_1` が絶対パスなのは意図的。helper 名を裸で書くと git は PATH から
`git-credential-<name>` を探すが、このイメージの PATH は `${NPM_CONFIG_PREFIX}/bin` が
`/usr/local/bin` より先に来るため、同名を置かれると乗っ取られる（shim と同じ罠）。

`/etc/gitconfig` に打ち消しを書く案は不成立（実測）。git は system → global の順に読むので、
空値で捨てた後に global の helper が積み直される。system より後に読まれる設定ファイルは
イメージから固定できない。

### トークンが無いときは連鎖ごと止める

helper が「答えない」だけでは足りない。**helper の失敗は黙ってフォールスルーする** — 出力なしで
`exit 0` でも、`exit 1` でも、username だけ返しても、git は次の helper や askpass へ進み、そこで
成功してしまう（実測）。

`/run/secrets/GH_TOKEN` が不在・空・読めない場合、helper は stdout へ `quit=1` を出す。git は
helper の連鎖を打ち切ってその場で失敗する。

```
git-credential-gh-token: GH_TOKEN not available: /run/secrets/GH_TOKEN
fatal: credential helper '/usr/local/bin/git-credential-gh-token' told us to quit
```

端末プロンプトにも落ちないので、対話シェルで人間がホスト側の資格情報を打ち込んで迂回すること
も、エージェントがプロンプトの前で無限に待つこともない。

「読めない」の扱いに注意が要る。`password=$(cat "$f")` の形だと `cat` の失敗が拾えず、空の
password を返して成立してしまう。shim と同じく、読み取り結果を変数に受けてから判定している。

### `GIT_ASKPASS` は残してある

`GIT_ASKPASS=/usr/local/bin/git-askpass`（`git-askpass` の実体は runtime-base、`ENV` の設定は
devcontainer-base）はそのまま。github.com は helper で確定するのでここへは来ないが、
github.com 以外のホストと、prod の entrypoint 経路で使う。

### prod でも効く

環境変数による設定は repo local（`.git/config`）より後に適用されるので、打ち消しは checkout
済みコードが仕込んだ `credential.helper` にも及ぶ。信頼しないコードが `credential.helper` を
仕込み、次回の entrypoint 自身の `fetch` で呼ばせて `GH_TOKEN` を受け取る経路が、github.com に
ついては閉じる。「なぜ `/src` を使い捨てるのか」で挙げている `.git/config` 持続の一種である。

トークン破棄（entrypoint の手順 10）の後は、helper が `quit=1` を返すようになる。`exec` 後に
走る信頼しないコードから github.com への認証付き操作ができないことが、`unset GIT_ASKPASS` だけ
だった頃より強く担保される。

### 何が失われるか

**`GH_TOKEN` を注入していないコンテナでは、github.com への https 認証が失敗する。** ホスト側の
資格情報へフォールバックしないことがこの設計の目的なので、これは副作用ではない。

- 影響するのは認証が要る https 操作だけ。public repo の clone は 401 が返らないため、credential
  の解決そのものが起きない
- ssh remote（`git@github.com:owner/repo.git`）は影響しない
- github.com 以外のホストは影響しない

意図して外すなら、利用側で `GIT_CONFIG_COUNT` を設定し直す。

### 設定が黙って外れることへの備え

`GIT_CONFIG_COUNT` は git が持つ**唯一のカウンタ**である。イメージがスロット 0 と 1 を占有して
いるため、同じ仕組みで設定を足したい利用側と衝突する。利用側が `GIT_CONFIG_COUNT` を自分で
設定すると、イメージの 2 スロットは**黙って**消える。消えても認証は（ホスト側の資格情報で）
通るので、失敗としては現れない。

`/usr/local/bin/git-auth-check` が対話シェルの起動ごとに実効値を確認する（`karakuri-context` から
呼ばれる）。`git config --get-urlmatch credential.helper https://github.com` の結果と、イメージが
固定した `GIT_CONFIG_COUNT` 系が生きているかどうかを、想定どおりのときも含めて常に1行で報告する。

利用側で `GIT_CONFIG_COUNT` を使いたい場合は、イメージが置いている 5 つを引き継いだうえで、
自分の設定を 2 番以降に足すこと。

---

## prod-entrypoint.sh

`/usr/local/bin/prod-entrypoint.sh`。secret の取り込みと workspace の復元を一体で行う。

1. stdin（dotenv 形式）を EOF まで読み、`/run/secrets/<変数名>` へ書く（umask 077）
2. 空値・`=` を含まない行・不正な鍵名は**即座に非ゼロ終了**する。取込件数が 0 でも落とす
3. **自己検査** — `/src` と secret の置き場が tmpfs であること、`/src` が `exec` であること
4. **`GIT_REPO` に資格情報が埋まっていないこと**を確認する
5. `GIT_ASKPASS` を設定し、`/src`（tmpfs）を `git init` + `fetch` で用意する（github.com への認証は
   イメージが焼いた credential helper が担う。「git の認証（github.com）」を参照）
6. `GIT_REF` が完全な commit sha であることと、**それが自分自身に解決されること**を確認する
7. 解決した sha を stderr と `/run/prod-ref` へ記録する
8. `checkout --detach --force` → `reset --hard` → `clean -xdff` の順で `GIT_REF` の状態へ復元する
9. `pnpm config set store-dir /src/.pnpm-store` で store を node_modules と同一 tmpfs へ向ける
10. `rm -f /run/secrets/GH_TOKEN` と `unset GIT_ASKPASS` で clone 用トークンを破棄する（以降 helper は
    `quit=1` を返すようになる）
11. `exec "$@"`（引数が無ければ非ゼロ終了）

順序には意味がある。自己検査（3）が secret 取込（1）の後・git 操作（5）の前にあるのは、
secret が届いていない状態で環境の話をされても診断の役に立たず、かつ無駄な fetch を避けたい
ため。資格情報の検証（4）が `remote set-url`（5）より前なのは、通した時点で
`/src/.git/config` にトークンが書かれてしまうため。一致検証（6）が記録（7）より前なのは、
逆だと拒否した ref が「immutable な sha を実行した」という記録として残るため
**（記録が嘘をつくのが一番悪い）**。トークン破棄（10）が `exec`（11）の直前なのは、
そこから先が信頼しないコードだからである。

### tmpfs であることを自分で確かめる

`compose.prod.yaml` の `read_only` / `tmpfs` は**一行の変更で静かに外せる**。特に危ないのが
`/src` を named volume に戻す変更で、「毎回 clone して依存を落とし直すのは遅い」という
性能上の動機から出る自然な一行であり、`read_only: true` を保ったままでも成立してしまう。
そして**起動も deploy も成功し続けたまま**、前回実行の信頼しないコードが `.git/config` に
仕込んだ設定が entrypoint 自身の git 操作で発火する経路が復活する（下記「なぜ `/src` を
毎回捨てるのか」）。

そこで entrypoint は `/proc/mounts` を読み、`/src` と secret の置き場が tmpfs でなければ
実際の fstype を名指しして落とす。

```
prod-entrypoint: /src is not a tmpfs: fstype=ext4
prod-entrypoint:   mount line: /dev/vda1 /src ext4 rw,relatime 0 0
```

該当する行が `/proc/mounts` に無い場合、あるいは `/proc/mounts` 自体が読めない場合は
WARNING を出して続行する。**黙ってスキップはしない** — これは診断ではなく防壁である。

検査対象を `/run` と直書きせず `/run/secrets` から導出しているのは、守りたいのが
「`/run` という名前のパス」ではなく「secret を書く先が不揮発ディスクへ落ちないこと」だから。

### `GIT_REPO` に資格情報を埋めない

`https://x:<token>@github.com/...` の形で渡すと、`remote set-url` によって URL が
`/src/.git/config` に残り、`exec` 後に走る信頼しないコードが `git config remote.origin.url`
で読める。`/run/secrets/GH_TOKEN` を破棄している防御が丸ごと空振りになるため、この形は拒否
する。認証は credential helper `git-credential-gh-token`（stdin で渡した `GH_TOKEN` を `/run/secrets`
から読む）が唯一の正規経路。
ssh 形式（`git@github.com:owner/repo.git`）は `://` を含まないので影響しない。

### 完全な sha であることと、それ自身に解決されることは別

`GIT_REF` が 40 桁 hex という**形**をしていることは、それが commit sha であることを意味
しない。40 桁 hex を名前とするブランチやタグを作ることは可能で、その場合 git の実装によっては
ref 名として解決されうる。すると**可変 ref の内容が immutable な sha として実行され、
`/run/prod-ref` にもそう記録される**。解決結果が `GIT_REF` 自身と一致することまで確認する。

現行の git（2.39.5 で実測）はこのケースを意図的に無視するため、この検査は多重防御である。
`rev-parse` の解決規則は git の版と実装に属するもので、このイメージが管理できる範囲にない。

### 復元の三段階は重複ではない

- `checkout --detach --force` … HEAD を移す
- `reset --hard` … tracked file の改変を戻す
- `clean -xdff` … untracked / ignored を消す

`checkout` は HEAD が既に同じ commit にあると working tree を復元せず、`clean` は untracked
しか消さない。この二つだけだと、`/src` を再利用したときに前回実行が書き換えた tracked file が
残る。`/src` は tmpfs で毎回捨てられるので現構成では起きないが、その前提が崩れても壊れない
ように三段構えを維持している（多重防御）。

### 存在しない ref は明示的に落とす

`git checkout --detach <ref>` は ref として解決できないと引数を**パス名**と解釈し、
`fatal: git checkout: --detach does not take a path argument 'v9.9.9'` という原因の読み取れない
エラーになる。fail-closed ではあるが、これを踏んだ人間は原因に辿り着けない。`fetch` の後に
`rev-parse --verify --quiet "${GIT_REF}^{commit}"` で検証し、`GIT_REF does not resolve to a
commit in the fetched repository: <ref>` として落とす。`GIT_REF` は秘匿情報ではない（通常の
環境変数で渡す設計）のでメッセージに含めてよい。

### pnpm の store

`read_only: true` の下では既定の `$PNPM_HOME/store`（`/usr/local/share/pnpm/store`）を作れず、
`pnpm install` が `ENOENT` で落ちる。store は **node_modules と同一の tmpfs マウント**に
置く必要がある。別マウント（`$HOME` 配下）に置くとハードリンクがマウントを跨げず copy に
フォールバックし、**RAM が倍**になる。

```
store を $HOME 配下（別 tmpfs）  合計 260M  リンク数 2 以上のファイル    0/3546
store を /src 配下（同一 tmpfs） 合計 131M  リンク数 2 以上のファイル 3491/3546
```

pnpm 自身が出力で機構を明言する — 前者は `Packages are copied ...`、後者は
`Packages are hard linked ...`。

設定は entrypoint が `pnpm config set store-dir /src/.pnpm-store` で行う。環境変数
`npm_config_store_dir` は効かない。書き込み先は `$HOME/.config/pnpm/config.yaml`（YAML の
`storeDir:`。`.npmrc` の `store-dir=` ではない）で、`$HOME` は tmpfs なので毎回新規に書かれる。

**イメージには焼かない。** dev container の store は `/workspaces/.pnpm-store` にあり `/src` は
存在しないので、runtime-base に焼くと devcontainer-base 側が壊れる。

store は `/src` の中にあるため `clean -xdff` の対象になる。entrypoint は checkout → clean →
`exec "$@"` の順で `pnpm install` はその後に走るため、同一 run 内で消えることはない。
**この順序を入れ替えてはならない。**

### なぜ `/src` を使い捨てるのか

`/src` は named volume ではなく **tmpfs** である。再利用する構成には、`checkout` +
`reset --hard` + `clean` の三段構えでも塞がらない穴が二つあり、いずれも実測で再現した。

**ref の汚染。** `git fetch --tags` は既存のローカルタグを clobber せず（`--force` が無い）、
ローカル branch は fetch の対象外である。前回実行の（信頼しない）コードが
`git tag v1.2.3 <別コミット>` を打てば、次回 `GIT_REF=v1.2.3` で `checkout` も `reset --hard` も
**攻撃者の ref を解決する**。三段構えは「汚染された ref へ正しく復元する」だけで、指定した
commit を実行する保証にはならない。実測では 2 回目の実行が別の commit の内容を checkout した。
安全なのは完全な commit sha だけで、これは content-addressed なので偽装できない。

**`.git/config` の持続。** 上記のとおり local が system に勝つため、`core.fsmonitor` のような
コマンドを実行する設定を仕込まれると、次回の entrypoint 自身の git 操作で発火する。実測では
8 回実行され、しかも `GH_TOKEN` を破棄する**前**だった。`credential.helper` を仕込めばトークン
そのものを受け取れる。`filter.*.smudge` + `.gitattributes` も同型で、**設定経由の実行経路を
列挙して潰すのは筋が悪い。**

tmpfs にすれば毎回まっさらな repo から始まるため、どちらも構造的に成立しない。同時に、prod で
走るコードが復号値・CLI キャッシュ・トークンを `/src` へ書いてもコンテナ削除後に Docker VM の
ディスクへ残らなくなる。**現在コンテナが書ける場所は全て tmpfs であり、悪意ある明示書き込みで
あっても不揮発媒体には届かない。**

代償は毎回の full clone と全依存の再ダウンロード、そして RAM 消費である。tmpfs の既定サイズは
ホスト RAM の 50%（CI ランナーでの実測は 7.9G）。karakuri 自身での `/src` 合計は実測 79M
だった（以前の測定では 131M。依存を 1 パッケージ分減らしたことによる差で、構成の変更ではない）。
**この数字はプロジェクトの依存木で決まる**ので、そのまま当てにはできない。依存の重い
プロジェクトを載せるなら、実行ホストのメモリ量が直接の制約になる。

### 入力を反射しない

パース失敗時のエラーメッセージには入力行も鍵名も出さず、stdin の行番号だけを示す。broker の
出力が壊れて `KEY=value` の形になっていない場合、その行は secret 本体そのものでありうる。
`logging: none` が止められるのはホストのログファイルだけで、アタッチ先の端末表示とその
スクロールバックは止められない。

### clone 用トークンの破棄

`GH_TOKEN` は clone / fetch には要るが、その後 `exec "$@"` で走るのは**信頼しない checkout 済み
コード**である。fetch 完了直後に破棄することで、取得用と実行用の資格情報を同一セッションに
同居させない。deploy が別途 GitHub 資格情報を要するなら、clone 用とは別スコープ
（read-only・単一 repo・短寿命）を deploy 直前に注入する。

---

## git hook

`core.hooksPath` を `/usr/local/share/git-hooks` に**イメージへ焼き込んである**（`--system`、
すなわち `/etc/gitconfig`）。

- 全リポジトリ・全 clone・worktree に自動で効く。`dotenvx precommit --install` は不要
- 改善はイメージタグの更新で伝播する
- `core.hooksPath` は**全 hook を上書きする**ため、hook 側で `.husky/pre-commit` と
  `.githooks/pre-commit` へ明示的にチェーンしている
- この設定が効いている間、各リポジトリの `.git/hooks/*` は無視される。過去に `--install` で
  書き込んだ `pre-commit` が死んだまま残るので、移行時に掃除すること

### hook は判定を持たない — 検査は共有スキャナに一本化してある

hook がすることは「staged なファイルの一覧を作って共有スキャナ `env-guard-scan` に渡す」
ことと、per-repo hook へのチェーンだけである。何を平文と見なすか・どのファイル名を検査
対象とするか・許可リスト・`.env.keys` の再帰探索は、すべてスキャナ側にある。

```
                   ┌─ hook  : git diff --cached --name-only   （staged）
検査対象の一覧 ────┤
                   └─ CI    : git ls-files                    （tracked）
                                        │
                                        ▼
                              /usr/local/bin/env-guard-scan
```

CI（karakuri の reusable workflow `env-guard.yml`）は、まったく同じ 1 本のファイルに
tracked なファイルの一覧を渡す。**スコープだけが違い、判定は同一になる。** 差分を見るか
現在の状態を見るかは文脈が決めることで、何を平文と見なすかは文脈に依らない。

以前ここで呼んでいた `dotenvx precommit` は外した。precommit は自前のファイル名フィルタを
持っていて上書きできないため、残すと「CI は通るのに hook だけ落ちる」逆向きの分岐を作る。
staged ファイルに対する検査内容は共有スキャナが同じだけ覆う。

### 検査対象はリポジトリごとに変えられる

リポジトリルートに `env-guard.conf` を置くと、ファイル名パターンと許可リストを上書きできる。

```
pattern (^|/)production\.env$
allow   *.env.container.example
```

- 既定は `(^|/)\.env` と `(^|/)secret\.env\.`、許可リストは `*.env.container.example`
- `pattern` / `allow` は指定した側の既定を**置き換える**（追加ではない）
- hook と CI が同じファイルを同じ規則で読むので、**上書きが片方にだけ効くことがない**
- このファイルは **`source` されない**。行単位でパースされ、値はパターン文字列としてしか
  使われない
- ファイル名がドットで始まらないのは、`.env-guard.conf` にすると既定パターンに自分自身が
  一致して、設定ファイルが env ファイルとして検査され必ず落ちるため

既定のパターンは basename が `.env` で始まるものしか拾わない。`production.env` のような
名前を使っているプロジェクトは、上記のように `pattern` で明示すること。

雛形は `images/runtime-base/templates/project/env-guard.conf`（プロジェクトのリポジトリへ
置くもの。全項目がコメントアウトされた状態で、
書式と既定値の説明が入っている）。

### セットアップ

新しいプロジェクトに検査を入れるときにやること。**多くのプロジェクトでは 1 と 3 だけで済む。**

**1. コミット時の検査 — 何もしなくてよい**

devcontainer が devcontainer-base（= runtime-base の上）に載っていれば、`core.hooksPath` が
イメージに焼かれているので全リポジトリ・全 clone・worktree で自動的に効く。導入コマンドは
無い。過去に `dotenvx precommit --install` や simple-git-hooks が書いた
`.git/hooks/pre-commit` が残っていると「入っているつもりで効いていない」状態になるので、
移行時に掃除すること（ただしホストからコミットする運用があるなら消さない。下記
「ホスト側の git はこれを読まない」参照）。

**2. 検査対象の指定 — 既定で足りるなら不要**

まず、いま何が tracked になっているかを見る。

```sh
git ls-files | grep -E '\.env'
```

出てきたものが全て `.env` で始まる basename（`.env` / `.env.production` /
`apps/api/.env.local` 等）なら、**`env-guard.conf` は置かなくてよい。** 置かない状態が既定で
あり、それが正しい状態である。`production.env` のような名前や、平文が正常なサンプルファイルが
あるときだけ置く。

**3. CI の検査 — スタブを 1 枚置く**

```yaml
# .github/workflows/env-guard.yml
on: [push, pull_request]
jobs:
  env-guard:
    uses: himorogy/karakuri/.github/workflows/env-guard.yml@<karakuri の commit SHA>
```

**ref は commit SHA で固定することを勧める。** この 1 行が検査全体の信頼の起点になる —
呼び出された workflow は、スキャナの版と期待する SHA256 を自分の中に持っており、npm から
取ったものをその期待値と照合してから実行する。つまり「どの ref を指すか」を決めた時点で、
実際に走るスキャナまでが決まる。タグは指す先を後から変えられるので、固定したつもりのものが
固定されない。

雛形は `images/runtime-base/templates/project/env-guard.yml`（プロジェクトのリポジトリへ
置くもの）。呼び出し側 org の Actions ポリシーが
「選択した actions / reusable workflows のみ許可」なら、`himorogy/karakuri/...` を allowlist へ
明示的に追加する必要がある（プランの制限ではなく設定項目）。

**確認すること**: 初回の実行で「何件検査したか」が出る。`0 file(s) were inspected` なら、
それは「安全だった」ではなく「検査対象が 1 つも無かった」である。2 の `pattern` が
プロジェクトの実態と合っているかを疑うこと。

なお CI は tracked なファイル全体を見るので、**過去にコミット済みの平文もここで初めて
表面化する**。移行直後の 1 回目が赤くなる可能性がある。

### リポジトリ側から無効化できる（強制装置ではない）

git の設定優先順位は **local > global > system** である。イメージが書くのは system
（`/etc/gitconfig`）なので、リポジトリの `.git/config` に `core.hooksPath` を書けば**上書きできる**。
実測（`git config --show-origin --get-all core.hooksPath`）:

```
file:/etc/gitconfig   /usr/local/share/git-hooks
file:.git/config      /tmp/local-hooks        ← 実効値はこちら
```

`--no-verify` でも素通りするし、git CLI を経由しない書き込み（GitHub API、libgit2 系）にも
効かない。**この hook は予防ではなく早期検知**であり、設計上も不変条件ではなく緩和策として
位置づけている。本線は CI 側の検査に置く。

`env-guard.conf` による上書きができることも、この性質と整合する。設定ファイルはリポジトリの
中にあり書き換えられるが、そもそも `--no-verify` で素通りする装置なので防御水準は下がらない。
「攻撃者を止める装置」ではなく「事故を早く見つける装置」であり、プロジェクトが自分の都合で
検査範囲を宣言できることの方が価値が大きい。

同じ性質が prod にも効く。`.git/config` は clone 後のコードが書き換えられるため、
`core.fsmonitor` のような**コマンドを実行する設定**を仕込まれると、次回の git 操作で走る。
実測では、named volume を再利用する構成で entrypoint 自身の fetch / checkout / reset / clean が
仕込まれたコマンドを 8 回実行した。しかも `/run/secrets/GH_TOKEN` を破棄する**前**である。

**だから `/src` は tmpfs で毎回捨てる。** 下記「なぜ `/src` を使い捨てるのか」を参照。

### ホスト側の git はこれを読まない

`core.hooksPath` はコンテナ内の `/etc/gitconfig` に書かれる。ホストの GUI クライアント（Fork 等）は
従来通り `.git/hooks/pre-commit` を参照するので、**イメージ焼き込みによってホスト側の hook が
無効化されることはない**。両者は独立に動作する。

実際のリスクは、イメージ焼き込みを理由に per-repo の hook 導入（simple-git-hooks 等）を撤去した
場合に、ホスト側だけが無防備になることにある。撤去する場合はホスト側の手当てを同時に行う。

`dotenvx prebuild` は焼いていない。runtime-base では app が存在しないので常に緑の no-op であり、
かつ本設計は app を実行時 clone するため `.env*` がイメージに焼かれる経路自体が無い。

---

## 使い方

### ホスト側ツールを入手する

ホスト側ツール（`karakuri.sh` の関数群と `dock.sh`）が動作する OS は macOS と
Windows(Git Bash / MSYS2) の 2 つ。Linux はホストとしては対象にしない（コンテナの中は
Linux だが、ホストツールをそこで動かすことはない）。

テンプレート一式は [`templates/`](./templates/) にある。置き場所で二つに分けてあり、
`templates/host/` はホストの固定パスへ置くもの、`templates/project/` はプロジェクトの
リポジトリへ置くもの（`env-guard.conf` / `env-guard.yml`）。

`host/` 側は、**このリポジトリをタグ指定で clone して使う**。ファイルを個別にコピーしない。

```sh
git clone --depth 1 --branch host-tools-v1.0.0 https://github.com/himorogy/karakuri.git ~/.config/karakuri
```

タグは `host-tools-v*` 系列を使う。イメージのリリースタグ（`runtime-base-v*`）とは別系列で、
ホスト側ツールだけの版を表す。`templates/` は `.dockerignore` でビルドコンテキストから
外れているため、ここが変わってもイメージの中身は変わらない。系列を分けておくと、
ホスト側ツールの修正がイメージの再リリースを引き起こさない。

`~/.config/karakuri/images/runtime-base/templates/host` を `PATH` に足すか、そこから
`~/.local/bin/` へ symlink を張る。どちらでもよい。Windows(Git Bash) では `~` は
`git clone` を打った Git Bash 上のホームディレクトリで、パスは Unix 形式
（`/c/Users/<name>/...`）になる。`C:\Users\...` 形式ではないので、Windows のエクスプローラ
等で確認したパスをそのまま貼らないこと。

コピーではなく clone にするのは、コピーが増えるほど「手元のものが正本と同じか」を
確かめる手段が無くなるためである。clone なら手元にあるのは正本と同じ git オブジェクトで、
書き換えれば `git status` に出る。secret の搬送路が黙って書き換わっていないことを、
追加の道具なしに確認できる。

更新は明示的に行う。`git pull` で追随させない — 未リリースの状態が prod の経路に
入りうる。

```sh
git -C ~/.config/karakuri fetch --tags
git -C ~/.config/karakuri log --oneline HEAD..origin/main -- images/runtime-base/templates/
git -C ~/.config/karakuri checkout host-tools-v<new>
```

clone 先は dev workspace の外に置くこと。**禁じているのは置き場所であって、git リポジトリの
中にあること自体ではない。** dev workspace はホストに bind mount されており、そこに置いた
ラッパーを dev container の LLM エージェントが書き換えれば、人間がホストで実行する際に
正規 broker の前後で鍵を複製できる。この clone は bind mount されないので、その経路が無い。

呼び出し規約は [`templates/host/karakuri.sh`](./templates/host/karakuri.sh) にある。
`.zshrc` / `.bashrc` からこれを `source` すると、broker 項目の命名・compose project 名・
対話 prod 作業の二段構えといった規約が関数として入る。設定として残るのは
`KARAKURI_BW_BIN` / `KARAKURI_PROD_COMPOSE` のような、環境そのものを指すものだけになる。
関数の一覧と推奨 alias はファイル末尾のコメントにある。

Windows(Git Bash) では `~/.bash_profile` に書く。無ければ作り、直接
`source ~/.config/karakuri/images/runtime-base/templates/host/karakuri.sh` を書くか、
`~/.bashrc` にまとめる習慣があるなら `~/.bash_profile` から `~/.bashrc` を source する
定番の形にしてそちらへ書く。

`~/.bashrc` に直接書いて済ませないのは 2 つ理由がある。ひとつは、Git Bash は login shell
として起動するため `~/.bash_profile` は bash 自身の仕様で必ず読まれるのに対し、
`~/.bashrc` が読まれるかは `/etc/profile` / `/etc/bash.bashrc` の構成次第で、版や配布形態
によって変わりうること。もうひとつは、`ssh <host> bash -lc "..."` の経路
（[`PORT-FORWARDING.md`](../devcontainer-base/PORT-FORWARDING.md) の「mac から Windows 上の
コンテナへ入る」が使う）は login shell なので `~/.bash_profile` を読むが、`~/.bashrc` は
非対話 bash では原則読まれないこと。`~/.bashrc` にしか書いていないと、ローカルの対話シェル
では動くのにリモート実行だけ関数が見つからないという食い違いが起きる。

`KARAKURI_ORG` もあるが、こちらは**任意**である。リポジトリは `<org>/<repo>` の 1 引数で
渡せるので、扱う org が複数あって一つに定まらないなら設定しない。設定するのは「ほとんどの
場合これ」という org がある場合だけで、その場合もスラッシュ付きで渡せば上書きできる。

`karakuri-help` が関数の一覧と、環境変数の説明・現在値を出す。

SSH port forwarding を使う場合は、これに加えて `~/.ssh/config` の設定と、初回 1 回の
`karakuri-loopback install` が要る。前者の書き方と、`ProxyCommand` に `templates/host/dock.sh`
の絶対パスを書く理由は
[`images/devcontainer-base/PORT-FORWARDING.md`](../devcontainer-base/PORT-FORWARDING.md) にある。
後者は `/etc/hosts` の管理ブロックを用意し、macOS では loopback エイリアスを再起動を跨いで
張り直す LaunchDaemon を入れる。**`karakuri.sh` が提供する関数のうち、`sudo` を要求するのは
`karakuri-loopback` だけである。** Windows(Git Bash) では `karakuri-loopback` は何も変更せず
終了する（macOS 専用であることを示す 1 行を出すだけ）。mac から Windows 上のコンテナへ入る
1 ホップの経路（下記 PORT-FORWARDING.md 参照）では、`LocalForward` は mac 側の 1 段だけで
済むため、この段自体が要らない。

### broker 本体（bw）を用意する

標準の broker は Bitwarden CLI を呼ぶ。**bw 本体は karakuri の配布物ではない**ので、clone には
含まれない。別途取得する。

**native ビルドを取る。`npm install -g @bitwarden/cli` は使わない。** broker はホスト側で最も
特権的な部品で、マスターパスワードを握り、全鍵束を stdout に出す。その取得経路は狭く・固定的に
保つ。npm 版はインストール時に postinstall が走り、依存木が深く、update で黙って版が動く。
nodenv 等の環境では node の版ごとのインストールになるため、node を切り替えた瞬間に消える。
native 版は単一ファイルで、版は自分で上げるまで動かない。

```sh
# bitwarden/clients の Releases（cli-v* タグ）から取得する
VER=<version>
curl -LO "https://github.com/bitwarden/clients/releases/download/cli-v${VER}/bw-macos-${VER}.zip"

# Releases ページに併記されている値と突き合わせる。ここを飛ばすなら native を選ぶ意味がない
shasum -a 256 "bw-macos-${VER}.zip"

# PATH の外へ置く（理由は下記）
mkdir -p ~/.dev-broker
unzip "bw-macos-${VER}.zip" && mv bw ~/.dev-broker/bw && chmod +x ~/.dev-broker/bw

# 初回実行が隔離属性で止まる場合
xattr -d com.apple.quarantine ~/.dev-broker/bw

# アカウントへのログイン（初回のみ）
~/.dev-broker/bw login
```

Linux なら `bw-linux-<VER>.zip`、Windows なら `bw-windows-<VER>.zip` を同じ手順で。

**`~/.dev-broker/` は PATH に入れない。** `~/.local/bin` のような PATH 上のディレクトリへ置くと、
PATH 順で先に来たもの（バージョンマネージャの shim など）が勝ちうる。broker が呼ぶバイナリは
固定的であってほしいので、PATH から外し、絶対パスで名指しする。

```sh
export KARAKURI_BW_BIN="$HOME/.dev-broker/bw"
```

名指しを必須にしておくと、設定漏れが「別の bw が黙って呼ばれる」ではなく「bw が見つからない」
として現れる。失敗の出方が変わるだけに見えるが、前者は気づく契機が無い。

vault の同期は broker が取得のたびに 1 回行うので、`bw sync` を手で打つ必要はない
（`BROKER_BW_SYNC=0` で無効化できる）。鍵束をどう Bitwarden 側に置くか — Secure Note の
項目名の付け方、共有分と個人分の分け方 — は
[`templates/host/broker-bitwarden.sh`](./templates/host/broker-bitwarden.sh) の冒頭にある。

### compose ファイルを置く

`compose.prod.yaml` はプロジェクトごとに 1 枚持つ。置き場所をまとめて
`KARAKURI_PROD_COMPOSE_DIR` に指すと、prod 系の関数が repo 名から `<repo>.yaml` を引く。

```
~/.config/prod-compose/
  <repo>.yaml
```

`templates/host/compose.prod.yaml` をこの名前でコピーし、`image:` の digest を実在のものへ
差し替える（`karakuri-image-digest <tag>` が貼り付け用の行を出す）。**ホスト側ツールのうち、
編集を伴うコピーになるのはこのファイルだけ**である。他は clone のまま使う。

全プロジェクトで 1 枚を共有する形も `KARAKURI_PROD_COMPOSE` として残してあるが、その場合は
イメージの更新が全プロジェクトへ一斉に適用される。分けておくと更新のタイミングをプロジェクト
ごとに選べる。`karakuri-check-image <tag>` は、ディレクトリ運用のとき中の全ファイルを検査
するので、どのプロジェクトが古い digest のままかは一覧で分かる。

**この置き場所は git リポジトリにしてよい。ただしどの devcontainer にも mount しないこと。**
このファイルは prod の防御（`read_only`・tmpfs の記法・`cap_drop`・`init: true`）を宣言して
いる当のもので、エージェントが到達できる場所へ置けば、防御そのものが書き換え対象になる。
git 管理の目的は改竄検知ではなく、digest をいつ上げたかの履歴を残すことにある — 到達不能で
あれば検知は要らない。

逆に、mount した時点でこの構成は「書き換えられないもの」から「書き換えられたら diff に出る
もの」へ落ちる。`git diff` は後から見れば分かるという性質であって、書き換えを止めはしない。
エージェントが書き換えて commit すれば、人間がレビューしない限り正当な変更に見える。

### prod でコマンドを実行する

`compose.prod.yaml` は名前だけ見ると「プロジェクトのリポジトリに置くもの」に見えるが、
`host/` に入っているのが正しい。`prod-run.sh` の `PROD_COMPOSE_FILE` が指す先であり、
下記の起動コマンド例のとおりホストの固定パス（`~/.config/<project>/`）に置く。これは
clone から `~/.config/<project>/` へコピーする（`image:` の digest を差し替えるため、
ここだけは編集を伴うコピーになる）。

`karakuri.sh` を source していれば、下の生の呼び出しは `karakuri-prod-run` が組み立てる。
以下は、その下で実際に何が渡っているかを示したものである。

```sh
PROD_COMPOSE_FILE=~/.config/acme/compose.prod.yaml \
PROD_BROKER="$HOME/.local/bin/acme-broker" \
BROKER_KEYCHAIN_SERVICE=acme-prod-env \
GIT_REPO=https://github.com/acme/app.git \
GIT_REF=<40 桁の commit sha> \
~/.local/bin/prod-run.sh dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy
```

**`dotenvx` を最上位に置くこと。** `prod-run.sh pnpm deploy` の形にすると、`pnpm run` が
`node_modules/.bin` を PATH 先頭に積んでローカルの dotenvx が shim に勝ち、鍵が注入されない
（上の「`pnpm run` の内側では効かない」を参照）。

### `GIT_REF` は完全な commit sha を強制する

40 桁 hex 以外は **entrypoint が拒否**する。ラッパー側でも早期に落とすが、権威は entrypoint
にある（ラッパーを迂回しても効く）。

危険を理解した上でブランチ運用を選ぶなら、明示的に外す。

```sh
PROD_ALLOW_MUTABLE_REF=1 GIT_REF=main ... prod-run.sh ...
```

既定を拒否にしている理由は、**失敗の性質が違う**こと。

- **ブランチ名** — 押した瞬間に何をデプロイしたか分からず、main が動くので後から再現もできない。
  事故は「見たことのないものを流した」になる
- **sha** — 古いかもしれないが既知で再現可能。事故は「一度は見たものの古い版を流した」になる

dev が書いたコードを prod が実行する経路の唯一のゲートは deploy 前の人間のレビューで、
その前提は「レビューした対象と流したものが一致する」こと。ブランチ名はその一致を切る。

**解決済みの commit sha は必ず記録される。**

```
prod-entrypoint: GIT_REF=main resolved to 4f3a9c2b8e1d7a05...
```

同じ内容が `/run/prod-ref` にも書かれる（tmpfs、sha は秘匿情報ではないので 0644）。
可変 ref を許した場合、これが「何をデプロイしたか」の唯一の記録になる。`logging: driver: none`
なので `docker logs` では取れないが、アタッチしている手元には出る。対話二段構えで
`docker exec` して入った場合は `cat /run/prod-ref` で読む。

署名タグは検証機構が未実装なので、現状はリスクだけが増える。実装するまで `PROD_ALLOW_MUTABLE_REF`
が唯一の逃げ道で、これは検証を伴わない。

依存インストールはコマンド側の責務になる。`clean -xdff` が `node_modules` も消すため。

```sh
... prod-run.sh sh -c 'pnpm install --frozen-lockfile \
      && dotenvx run --strict --no-armor -f .env.prod -- pnpm deploy'
```

`sh -c` で複数コマンドを繋ぐ場合も、`dotenvx` は `pnpm` の外側に置く。

> **`pnpm install` の後に `git clean -xdff` を打たないこと。** store は `/src/.pnpm-store` に
> あるので `clean` の対象になり、`node_modules` ごと消える。後続の処理が依存を失って失敗する。
> entrypoint 内の順序（checkout → clean → コマンド）は正しいので、**利用者が渡すコマンドの
> 中で `clean` を挟んだ場合だけ**の話。復旧は `pnpm install` のやり直しだが、store の
> 再ダウンロードが要る。

### 環境変数を確認する

```sh
... prod-run.sh dotenvx get -f .env.prod
... prod-run.sh sh -c 'dotenvx run --strict --no-armor -f .env.prod -- printenv | sort'
```

いずれもファイルを作らない。dev container からは書けるが読めない（値の追加は
`dotenvx set FOO bar -f .env.prod` で秘密鍵なしに行える）。

### 対話シェルが要る場合

stdin が secret の搬送路なので、`run` の対話 TTY とは両立しない。必要な場合は二段構えにする。

```sh
<broker> | docker compose -f compose.prod.yaml run -dT --rm prod sleep infinity
docker exec -it <container> bash
```

entrypoint 完了後なので `/run/secrets` は注入済み。退出後の `docker stop` 忘れが運用上の
唯一のリスクになる。

---

## broker

秘密鍵を保管し、認可を経て dotenv 形式で stdout に出すコマンド。**契約さえ満たせば実装は問わない。**

1. dotenv 形式（`KEY=value` 行）を stdout に出力する
2. 保管中の実体が不揮発ストレージ上で平文でない（OS キーチェーン等の暗号化ストアに置く）。
   **復号鍵そのものが平文でローカルに常駐する方式は契約違反**
3. 取得時に OS レベルの認可（パスワード / Touch ID プロンプト）が働く
4. 非対話環境で認可を得られない場合は非ゼロ終了する

参照実装は [`templates/host/broker-macos-keychain.sh`](./templates/host/broker-macos-keychain.sh)（macOS の
`security` CLI）。セットアップ手順はファイル冒頭のコメントにある。Windows 側の標準は未決で、
1Password / Bitwarden CLI への統一も候補に残っている。stdin 注入方式なので、broker はコマンド
1 個の差し替えで移行でき、compose と entrypoint は無変更で済む。

**鍵束は git 管理しない。** 束の中身（`GH_TOKEN` / `CLOUDFLARE_API_TOKEN` 等）は運用者ごとに
異なる個人資格情報であり、リポジトリ共有物ではない。git 管理する暗号化物は `.env.prod`
（dotenvx、プロジェクト共有）だけ。プロジェクト共有の `DOTENV_PRIVATE_KEY_PROD` は各運用者が
自分の鍵束に格納し、運用者間の受け渡しはチームのパスワードマネージャで行う。

> **Keychain の「常に許可」について。** 一度許可すると以降は無確認でアクセスできるようになるが、
> その状態では**同一ホストユーザーの権限で走る任意のプロセス**が認証プロンプトなしに秘密鍵を
> 取り出せる。dev container からは直接呼べない（Docker socket が無く、コンテナ内 UID もホスト
> ユーザーとは別）が、コンテナ脱獄・ホスト連携機能の突破・dev が書いたホスト側スクリプトの
> いずれかを越えれば決定的な穴になる。可能な限り「常に許可」は避け、都度確認または Touch ID
> を選ぶこと。

### `pipefail` は必須

broker が認可失敗で非ゼロ終了しても、パイプの最終要素（docker）が 0 を返せばパイプ全体が
成功扱いになる。secret が一切注入されないまま prod コマンドが走る、という最悪のケースを起動前に
止めるため、起動ラッパーは `set -o pipefail` を必須とする。`zsh` は既定で有効だが、`sh` / `bash`
では明示が要る。

原因の切り分けには SIGPIPE を考慮する必要がある。docker が先に失敗して stdin を閉じると broker
は書き込み中に SIGPIPE を受けて 141 で終了するため、素朴に「broker を先に見る」実装は真の原因を
隠して「broker failed」と誤報告する。`prod-run.sh` はこれを区別している。

---

## リリース

タグを push するとマルチアーキビルドが走り GHCR へ push される。

```sh
git tag runtime-base-v1.0.0 && git push origin runtime-base-v1.0.0
```

`:1.0.0` / `:1.0` / `:1` / `sha-xxxxxxx` が付く。

**リリース順は runtime-base → devcontainer-base。** devcontainer-base は
`FROM ghcr.io/himorogy/runtime-base:${RUNTIME_BASE_VERSION}` で載るため、runtime-base が
GHCR に無い段階では pull に失敗する。実際に出るのは匿名トークン取得の
**`403 Forbidden`** で、404 ではない。

### 初回リリースの直後に、可視性を確認する

**タグを push しただけでは終わらない。** GHCR のパッケージは初回 push 時に **private** で
作成されるのが通常で、組織の package creation / visibility ポリシー次第で結果が変わる。

private のままだと、匿名で pull できないため **devcontainer-base のビルドはタグを打った後も
同じ 403 で落ち続ける**。「タグを打てば通る」ではないので、ここで一度確認する。

```
GitHub → Packages → runtime-base → Package settings → Change visibility → Public
```

public にしておくと利用側の `docker pull` に認証が要らなくなる。runtime-base は中立な
実行基盤と制約だけを収録しており、秘匿情報は一切焼かれていない（secret は起動時に stdin から
コンテナ内 tmpfs へ入る）ので、公開して問題ない。

初回 push が権限エラーで落ちる場合は、組織設定で Actions からの package creation が
許可されているかを確認する。ワークフロー側の `packages: write` だけでは足りない。

参照の仕方は用途で分ける。

| 参照元 | 参照の仕方 | 理由 |
|---|---|---|
| `compose.prod.yaml` | `@sha256:<digest>` で digest pin | prod は「変わらないこと」に価値がある。タグは後から指す先を変えられる |
| `devcontainer-base` | `:1` を追随 | 改善を伝播させたい |

---

## 検証項目

このイメージが壊れていないことの確認は、CI の smoke test に加えて
[`tests/`](./tests/) が担う。

```sh
pnpm lint:sh    # shellcheck
pnpm test       # shim / entrypoint / prod-run の挙動
```

docker が要る項目（compose の実挙動、`read_only` 下の pnpm 完走、keychain ACL ごとの挙動、
core dump の抑止）は実機で確認する。結果は
[verification-record.md](./verification-record.md) に記録する。

### 恒常チェック

**dev container が Docker socket を持たないこと。** `.devcontainer/` に socket mount /
docker-in-docker / docker-outside-of-docker のいずれも無いこと。この前提が崩れると、
dev container から prod container への `docker exec` や任意 volume の mount が可能になり、
本設計の分離全体が無効化される。devcontainer 構成を変更するたびに確認すること。
