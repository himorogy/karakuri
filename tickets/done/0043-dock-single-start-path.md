---
status: open
type: fix
base: main
targets:
  - host-tools/dock.sh
  - host-tools/tests/dock.test.sh
  - host-tools/karakuri.sh
  - host-tools/README.md
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm test
---

# dev container の起動経路を karakuri-dock up に一本化し、起動時に firewall を適用する

## 内容

### 症状

1. Docker Desktop で dev の compose project（dev と egress-proxy の2コンテナ）を停止しても、dev だけが起き上がり、egress-proxy は停止したまま残る。
   dev だけを停止し直しても、また起き上がる。
   原因は ssh クライアントの自動再接続である。
   ProxyCommand から呼ばれた `dock.sh --stdio` が、停止中の dev を `docker start` で起こす。
   起きた dev は `/run` の tmpfs が空なので secret 判定で exit 1 し、クライアントは再接続を繰り返す。
2. `--ensure-running`（`karakuri-dock up` が呼ぶ）も dev だけを `docker start` する。
   コンテナ ID に対する `docker start` は compose の `depends_on` を見ないので、project ごと停止した後の `up` では egress-proxy が起動しない。
3. egress-guard の firewall は devcontainer.json の `postStartCommand` が適用するもので、`docker start` では実行されない。
   iptables のルールはコンテナのネットワーク名前空間ごと停止で消える。
   したがって dock.sh が起動した dev には、今はどの経路でも firewall が無い。
   Docker Desktop の開始ボタンなど dock.sh を通さずに起動した dev も同じで、その後に `karakuri-dock up` を打っても「起動済み」として素通りし、secret だけが入る。

### 変更

コンテナを起動するのは `--ensure-running` だけにし、そこで「全コンテナ起動・firewall 適用・secret 注入」が揃うことを担保する。

**`--stdio` と既定モード（対話シェル）**

- 停止中のコンテナを起動しない。
  `docker start` を呼ばず、stdout に何も出さず、stderr に案内を出して exit 1 する。
- 案内の文言は「停止中」と「secret 未注入」で揃え、どちらもホスト側で打つ起動コマンドとして `karakuri-dock -p <project> up` を示す。
  例: `dev container for '<project>' is not running. Start it on the host with 'karakuri-dock -p <project> up' (plus your usual -b/-H/-w), then reconnect`
  dock.sh は `-b` / `-H` / `-w` の値を受け取っていないので、プレースホルダで埋めずに「いつもの指定を足す」と書く。
  利用者が定義する短い関数名（README の `dock`）は配布物が知らない名前なので出さない。
- secret 注入済みで起動中のときの振る舞い（`sshd-inetd` への exec、対話 zsh）は変えない。

**`--ensure-running`**

コンテナは compose project ラベル（`com.docker.compose.project`）で全件を引く。
対象サービス（`-s`、既定 dev）は既存どおりサービスラベルで特定する。

- 対象サービスが起動中で、同じ project の他のコンテナもすべて起動中で、対象サービスに secret が注入済みなら、何も起動・停止せずに 0 を返す。
  secret は `/run` の tmpfs にあり、注入するのは `karakuri-dock up` の経路だけなので、揃っていれば「この起動の後に正規の手順を通った」とみなす。
  起動中のコンテナを毎回再起動しないのは、`up` を打ち直しただけで中の作業が消えるのを避けるため。
- それ以外（どれかが停止中、または secret 未注入）なら次の順で処理する。
  1. project の全コンテナを停止する（対象サービスを先に止め、sidecar 無しで動く時間を作らない）
  2. 対象サービス以外のコンテナを起動する
  3. 対象サービスを起動する
  4. 対象サービスで `docker exec -u root <container> /usr/local/bin/init-project-firewall.sh` を実行する。失敗したら非ゼロで終わる
- 起動順は sidecar のサービス名（`egress-proxy`）を決め打ちせず、「対象サービス以外 → 対象サービス」で決める。ホスト側ツールは名前を組み立てない方針に合わせる。
- firewall スクリプトのパスは固定で持つ。
  devcontainer.json の `postStartCommand`（node から `sudo` で同じスクリプトを引数なしで実行）と、root・引数なし・設定は固定パス `/etc/egress-guard/firewall.json` という点で一致する。
  スクリプトは再実行を想定した設計なので、devcontainer CLI が適用した後に重ねても害はない。
- stdout は空のまま保つ。firewall スクリプトの出力は stderr へ回す。
- 再起動で secret は消える。注入は既存どおり `karakuri-dock` が `--secrets-ok` の結果を見て行う（`karakuri.sh` の流れは変えない）。

**コメントと README**

- `dock.sh` 冒頭のモード説明と CONTRACT、`usage()` を新しい振る舞いに合わせる。
- `karakuri.sh` の `karakuri-dock` のコメント（`--ensure-running` の役割）を合わせる。
- `host-tools/README.md` の「dev container に入る」節に次の2点を書く。
  - 停止は自由だが、起動は `karakuri-dock up`（または devcontainer CLI）で行う。それ以外で起動した dev は、次の `up` で再起動される。
  - devcontainer CLI がコンテナを作成している最中（`postCreateCommand` の実行中）に `up` しない。secret 未注入なので再起動になり、`postCreateCommand` が途中で止まる（firewall は `up` が適用するので健全性には影響しない。止まった `postCreateCommand` は再作成でやり直す）。

**テスト**（`host-tools/tests/dock.test.sh`。既存のフェイク docker に `stop` と、複数コンテナの `ps` / `inspect` を足す）

- 停止中の `--stdio` / 既定モードが `docker start` を呼ばず、非ゼロで終わり、stdout が空で、stderr に `karakuri-dock -p <project> up` を含むこと
- `--ensure-running` が、全コンテナ起動中かつ注入済みのとき `stop` / `start` / `exec` を一切呼ばないこと
- `--ensure-running` が、sidecar 停止・対象停止・secret 未注入のそれぞれで、全停止 → 対象以外の起動 → 対象の起動 → firewall 適用の順に呼ぶこと
- firewall 適用が失敗したら `--ensure-running` が非ゼロで終わること
- 既存の「停止中の `--stdio` が `docker start` の stdout を漏らさない」ケースは、起動しなくなるので削除する

### やらないこと

- `karakuri-dev-inject` を直接打つ経路の封鎖。Docker Desktop で起動した後にこれを打つと、firewall 無しのまま secret が入り「揃った」状態に見える。公開面の整理として #75 で扱う
- 起動後処理を `devcontainer.metadata` ラベルの `postStartCommand` から読む案（#76）
- ssh クライアント側の再接続の振る舞い。停止中は exit 1 を返し続けるだけで、再試行を止めるのはクライアントの設定である
- dev container の作成。dock.sh は既存コンテナの起動だけを扱い、0件なら今どおりエラーにする

## 保証

### 新たに宣言する保証

- 標準入出力モードと既定モードは、停止中のコンテナを起動しない。非ゼロで終わり、stdout に何も出さず、stderr にホスト側で打つ起動コマンドを示す（テスト: "--stdio does not start a stopped container"、"the default mode does not start a stopped container"）
- 標準入出力モードは secret 未注入のとき 1 で止まり、stdout に1バイトも出さず、sshd を起動しない。stderr の案内にはホスト側で打つ起動コマンドを示す（テスト: "--stdio does not exec sshd-inetd when secrets are missing"）
- 起動確認モードは、対象サービスと同じ project の全コンテナが起動中で secret が注入済みなら、どのコンテナも停止・起動せずに 0 を返す（テスト: "--ensure-running leaves a ready project untouched"）
- 起動確認モードは、上の条件が揃わなければ project の全コンテナを停止し、対象サービス以外を先に、対象サービスを最後に起動し、対象サービスに egress-guard の firewall を適用してから 0 を返す。適用に失敗すれば非ゼロで終わる。いずれも stdout は空である（テスト: "--ensure-running restarts the whole project and applies the firewall"、"--ensure-running fails when the firewall cannot be applied"）

### 維持する保証

- §14「標準入出力モードは secret 注入済みのとき、絶対パスで sshd を起動する」——停止中の分岐を足す箇所の直後にあり、起動中かつ注入済みの経路を変えないこと
- §14「既定モードは対話シェルを開き、作業ディレクトリの指定があるときだけそれを下位へ渡す」——同じく起動中の経路を変えないこと
- §14「secret の確認モードはコンテナの起動状態を変えない」——起動確認モードが secret 判定を内部で使うが、確認モード自身は今どおり副作用を持たない

### 廃止する保証

- §14「起動確認モードは、停止中なら起動して 0、起動済みなら起動せずに 0 を返す。どちらも stdout は空である」——起動済みでも条件が揃わなければ再起動するようになるため。新たに宣言する保証の3・4行目が置き換える
- §14「標準入出力モードは停止中のコンテナを secret 判定の前に起動し、その起動が出す stdout を外へ漏らさない」——停止中は起動しなくなるため。新たに宣言する保証の1行目が置き換える
- §14「標準入出力モードは secret 未注入のとき 1 で止まり……stderr の案内には、ホスト側で打つべきコマンドと broker のキーを別引数として示す」——案内が broker のキーを示さず `karakuri-dock -p <project> up` を示すようになるため。新たに宣言する保証の2行目が置き換える
