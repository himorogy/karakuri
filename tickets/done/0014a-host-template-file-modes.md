---
status: close
type: fix
base: main
targets:
  - images/runtime-base/templates/host/host-run.sh
  - images/runtime-base/templates/host/karakuri.sh
  - images/runtime-base/templates/tests/karakuri.test.sh
  - images/runtime-base/tests/host-file-modes.test.sh
  - images/runtime-base/tests/run.sh
  - docs/guarantees.md
verify:
  - pnpm lint
  - pnpm lint:sh
  - pnpm test
---

# 配布物の実行ビットの欠落を直し、mode を検査に載せる

## 内容

`images/runtime-base/templates/host/host-run.sh` が mode 100644 で記録されている。ファイルは
配布されるが実行できないため、`karakuri-run` は解決に失敗して止まる。index が 100644 を
持っている以上、clone した全ホストで再現する。0014 の受け入れ検証の最初のコマンドで踏んだ。

**配布物の mode が壊れていると、利用側は着手すらできない。** 台帳は `C-2` で runtime-base
イメージ内の配置（PATH 上にあり実行可能であること）を約束しているが、公開面 `D`（ホストと
利用側リポジトリへ配布されるテンプレート）には同じ軸が一行も無い。今回の壊れ方は、その空白に
そのまま落ちている。

### 直すもの

**1. mode。** `host-run.sh` を 100755 にする。同ディレクトリの棚卸しでは他に取りこぼしは無く、
100644 のまま正しいものが4つある——`compose.prod.yaml`（データ）、`karakuri.sh`（source 専用で
実行しない）、`loopback/com.karakuri.loopback-aliases.plist`（launchd の設定。`loopback-setup.sh`
が root 所有 0644 で install する）、`shims/_dotenvx.cmd`。最後の1つは意図して 644 に置く。
cmd.exe は POSIX の実行ビットを見ないので立てても効果が無く、逆に立てると PATH 上の `shims/`
から実行可能として拾われうる（中身は sh として解釈できない）。

**この4つはいずれも shebang を持たず、100755 の8つはいずれも持つ。** 例外は1つも無い。

**2. エラーの分岐。** 現在の文面は置き場所の問題だけを示唆する。

    karakuri: cannot find 'host-run.sh'. Put it next to karakuri.sh, or on PATH,
    or point KARAKURI_TOOL_DIR at the directory that holds it

「ファイルはあるが実行できない」ケースでこれが出るため、置き場所と `KARAKURI_TOOL_DIR` を
疑う時間が生まれる。探索で当たったのに実行できない場合は、対象のパスと直すコマンドを示す
分岐へ倒す。

あわせて PATH 側の解決にも実行可能であることを要求する。**現状はシェルによって出方が違う。**
bash の `command -v` は実行ビットの無いファイルを拾ってくるため、旧実装はそのパスを解決結果
として返し、呼び出し側が `Permission denied` で落ちていた。zsh は拾わないので `cannot find`
になる。同じ壊れ方が二通りに見えるのを止める。

**3. 検査。** 配布テンプレートの mode を検査に載せ、`pnpm test`（CI の test ジョブ）から回す。
検査の対象は working tree ではなく git の index である——配られるのは clone や archive の結果
であり、そこに載るのは index が持つ mode だからで、working tree 側は `core.fileMode=false` や
実行ビットを持てないファイルシステムで簡単に食い違う。中身（shebang）も index から読む。
working tree の中身と index の mode を突き合わせると、片方だけがコミットされた状態で判定がずれる。

見るのは「実行して使うもの」と「読み込んで使うもの」の区別と mode の一致である。**判定は
shebang の有無で代用する。これは検査の手段であって、約束の一部ではない**——「実行するスクリプト
には shebang を書く」という別の規約を足しているのではなく、その区別が既にファイル自身に
書かれているのを使うだけである（`host/` の14ファイルで、shebang の有無と正しい mode は例外なく
一致する）。ファイルの一覧を別に持つと同じ判断の二重管理になり、`host/` にファイルが増える
たびに一覧の更新漏れという別の壊れ方（無信号で通る）を作る。`shipped-symbols.test.sh` と
同じく、検査自身の検知能力は既知の壊れ方をその場で作って毎回確かめる。

### やらないこと

- `templates/host` 以外の mode 検査（`images/runtime-base/bin`、`packages/*/bin`、
  `.github/scripts`、`templates/tests` など）。同じ機構で広げられるが、今回踏んだのはホストへ
  配る一式であり、イメージへ焼かれるものは `C-2` が別の軸で見ている（ビルド時に実行権が付く
  ものが含まれ、リポジトリ上の mode は判定材料にならない）
- working tree 側の mode の検査。上記の理由で偽陽性になる
- `host-run.sh` の中身。今回触るのは mode だけである
- `dock.sh.new` の扱い。リポジトリの配布物には存在せず（tracked にも git 履歴にも無い）、正体は
  `tmp/` に置かれた過去の試作物である。手元に残っている複製はこの変更の対象ではない
- `_dotenvx.cmd` を 100755 にすること。上記のとおり効果が無く、害がある

## 保証

### 新たに宣言する保証

`docs/guarantees.md` の `## Guarantees` へ `§23` を追加し、`§13` へ2行を足す。

#### `### 23. images/runtime-base/tests/host-file-modes.test.sh — 配布テンプレートの file mode`

- ホストへ配るテンプレート一式のうち、**実行して使うスクリプトは、clone した先でそのまま
  実行できる**。受け取った側が mode を直す手順を要求されることはない（テスト: "配布物の mode が、
  実行して使うものと読み込んで使うものの区別と一致する"）
- 逆に、**読み込んで使うファイル（source される関数集・compose・plist・Windows 用ラッパー）は
  実行可能にならない**。PATH 上の `shims/` から誤って起動される経路を作らない（テスト:
  "否定対照: 読み込んで使うファイルの 100755 を検知する"）

#### `§13`（`karakuri.test.sh`）へ足す行

- 下位スクリプトが見つかったのに実行できない場合、置き場所ではなく mode を問題として報告し、
  対象のパスと直すコマンドを示す。実行できないものを解決結果として返して呼び出し側を落とす
  ことはなく、この振る舞いは bash と zsh で変わらない（テスト:
  "the error does not blame the placement when the file was found"）

### 維持する保証

- 台帳 `§13`（`karakuri.test.sh`）。`_karakuri_tool` を書き換えるため、下位スクリプトの解決が
  隣接ディレクトリ → PATH の順であること、および解決に失敗したとき下位スクリプトを一度も
  起動せずに非ゼロで終わる既存の分岐を変えない
- 台帳 `§19`（`host-run.sh`）。mode だけを直し、中身の振る舞いには触れない
- 台帳 `§11`（`shipped-symbols.test.sh`）。新設する検査と書き換えるコメントに、このリポジトリの
  外では参照先の無い記号を持ち込まない

### 廃止する保証

- なし。配布テンプレートの mode に関する約束は台帳に一行も無く（`C-2` が見ているのは
  runtime-base イメージ内の配置であって、公開面 `D` には対応する軸が無い）、今回が初出である。
  エラー文面の変更も `§13` の既存行が触れていない領域で、取り下げる約束は生じない
