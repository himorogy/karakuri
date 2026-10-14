---
status: close
type: feat
base: main
targets:
  - host-tools/proxy-log-setup.sh
  - host-tools/proxy-log/karakuri-proxy-log-export
  - host-tools/proxy-log/com.karakuri.proxy-log-export.plist
  - host-tools/tests/proxy-log.test.sh
  - host-tools/README.md
  - package.json
  - .devcontainer/docker-compose.yaml
  - images/devcontainer-base/examples/docker-compose.yaml
  - docs/guarantees.md
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# egress-proxy のアクセスログをホストの保管庫へ日次で書き出す

## 内容

束: 0052-proxy-log-vault → 0046-egress-guard-from-source → 0047-retire-egress-guard-npm → 0049-proxy-logformat → 0048-firewall-l7-without-external-dns → 0050-template-internal-network → 0051-karakuri-internal-network

egress-guard と egress-proxy の配布・記録・経路を見直す束で、3つの流れからなる。

- egress-guard の配布をイメージだけにする（0046 / 0047）。各イメージが npm を経由せず、このリポジトリのソースから焼く
- egress-proxy のアクセスログを、LLM を通らない経路（パッケージのインストールスクリプト、git hooks、エディタ拡張、常駐プロセスなど）の通信を後から照会できる記録にする（0052 / 0049）。拒否された宛先の判定はこのリポジトリの外の監査側が持ち、ここでは保管庫とその契約までを提供する
- dev から DNS で外へデータを持ち出す経路を、dev を internal ネットワークだけに載せて塞ぐ（0048 / 0050 / 0051）。issue `#83` が起点で、`#83` は 0051 の close で閉じる

順序の依存は次のとおり。
0052 は他に依存しない。
0049 と 0048 は 0046 を待つ（0049 は 0046 と同じファイルに触るため、0048 は npm の新版を出さないので 0046 が無いと改修がイメージへ届かないため）。
0050 は 0048 入りの devcontainer-base のタグを待つ。
0051 は 0050 の着地と、0048 入りの devcontainer-base・0049 入りの egress-proxy のタグを待ち、karakuri の pin をまとめて上げる。

egress-proxy のアクセスログを、LLM を通らない経路（パッケージのインストールスクリプト、git hooks、エディタ拡張、常駐プロセスなど）の通信を後から照会できる記録として扱えるようにする束である。
悪性パッケージは公表が数週〜数か月遅れるので、「その期間にその宛先へ通信したか」を1年遡って引けることが要になる。
0052 がログをホストの保管庫へ書き出して1年保持し、0049 がログの行に照会と時刻の突き合わせに要る項目を足す。
拒否された宛先の判定（抑制リスト、未判定の管理、照会）はこのリポジトリの外の監査側が持つ。
このリポジトリが提供するのは保管庫とその契約までで、抑制リストは読まない。
0052 は今の配布イメージのまま動くように作り、0049 を待たない。

### 現状

アクセスログは compose の名前付きボリューム（karakuri では `karakuri-proxy-log`）の `access.log` 1本にあり、ローテーションも保持期間も無い。
ボリュームは `docker compose down -v` で消える。
egress-proxy の squid.conf は `logfile_rotate` を書いておらず、この状態で `squid -k rotate` を送っても `access.log` は改名されず、同じファイルに書き続ける（squid 5.7、Debian `5.7-2+deb12u5` で実測）。

### 作るもの

macOS の利用者権限の LaunchAgent として日次で動くジョブと、その install / uninstall を行う `host-tools/proxy-log-setup.sh` を足す。
ジョブ本体は `host-tools/proxy-log/karakuri-proxy-log-export`、plist は `host-tools/proxy-log/com.karakuri.proxy-log-export.plist` に置く。
既存の `host-tools/loopback-setup.sh` と `host-tools/loopback/` の作法（配置前の突き合わせ、`launchctl bootout → bootstrap`、plist に `KeepAlive` を書かない、テストのスタブの作り方）に揃える。
ただし loopback と違い root は要らない（ジョブが叩く Docker の socket は利用者のもの）ので、LaunchDaemon ではなく LaunchAgent にし、`sudo` を使わない。

配置先:

- ジョブ本体: `~/.local/libexec/karakuri/karakuri-proxy-log-export`。install が clone から写す。plist が clone の中を直接指すと、利用者が clone を消して取り直したときにジョブが黙って失敗するため
- plist: `~/Library/LaunchAgents/com.karakuri.proxy-log-export.plist`
- 保管庫: `~/.local/state/karakuri/egress-log/<project>/`
- 状態ファイル: `~/.local/state/karakuri/egress-log/status`

launchd が渡す `PATH` には Docker Desktop の `docker` が入らないことがある。
install の時点で `docker` の絶対パスを解決し、plist かジョブ本体に固定する（どちらに置くかは実装の判断）。
解決できなければ install は非ゼロで終わり、何も配置しない。

### ボリュームの発見と label

書き出しの対象は、label `karakuri.egress-log` を持つボリュームである。
label の値はプロジェクト名で、保管庫のディレクトリ名になる。
値は英小文字・数字・ハイフンだけを許し、先頭はハイフン以外とする。
それ以外の値（空、`/` や `..` を含むものなど）のボリュームは書き出さず、状態ファイルと標準エラーに挙げて、残りのボリュームの処理を続ける。
2つ以上のボリュームが同じ値を持つ場合も、そのプロジェクトは書き出さずに挙げる（どちらのログかを保管庫の上で区別できなくなるため）。

label は compose のトップレベルの `volumes:` の定義に付ける。

- `.devcontainer/docker-compose.yaml` の `karakuri-proxy-log` に `karakuri.egress-log: karakuri`
- `images/devcontainer-base/examples/docker-compose.yaml` の `<your-project>-proxy-log` に `karakuri.egress-log: <your-project>`。雛形を写した利用者がこの値を自分のプロジェクト名に書き換えることを、雛形のコメントで1行述べる

既存のボリュームに label は後から付かない。
付けるには利用者がボリュームを作り直す必要があり、作り直すとそれまでのログは消える。
karakuri 自身についてはこの手順を検収で行う（下記）。

### 1回の実行で起きること

ボリュームごとに次を行う。

```
for vol in label karakuri.egress-log を持つボリューム:
    if label の値が不正 or 値が重複:
        書き出さず、状態に記録して次へ
    running = そのボリュームを mount している実行中のコンテナ（docker ps --filter volume=<vol>）
    if running がある:
        if 前回の実行が残した退避ファイルがある:
            先にそれを書き出す（下の書き出しと同じ手順）
        docker exec running で access.log を退避ファイル名へ mv する
        running へ SIGUSR1 を送る（docker kill --signal=USR1）  # squid が新しい access.log を作って開き直す
        退避ファイルを docker exec running 越しに読み、保管庫へ gzip で書く（一時名に書いてから rename）
        書き終えたら docker exec running で退避ファイルを消す
    else:
        img = そのボリュームを mount している停止中のコンテナのイメージ（docker ps -a --filter volume=<vol>）
        if img が無い:
            書き出さず「読めるコンテナが無い」と状態に記録して次へ
        img から使い捨てのコンテナを起こし（ネットワーク無し、uid 13、エントリポイントを sh に差し替え、ボリュームを mount）、
            残っている退避ファイルと access.log を、上と同じ手順で書き出して消す
        # 書き手がいないので rotate（SIGUSR1）は要らない
保管庫の各プロジェクトで、365日を超えたファイルを消す
状態ファイルを書く（一時名に書いてから rename）
```

止まっている proxy のボリュームも書き出すのは、ログが失われる契機（`down -v`、ボリュームの削除、Docker の初期化）がコンテナの停止中に起きやすいからである。
停止や起動の契機で書き出す案は採らなかった。
`down -v` はコンテナを消した直後にボリュームを消すので、その間に割り込める契機が無く、Docker Desktop の終了にも確実に掛けられる契機が無い。
日次で稼働の有無にかかわらず書き出せば、失われうるのは最後の書き出しから1日以内の分に収まる。
使い捨てのコンテナのイメージを停止中のコンテナから取るのは、ボリュームを書いていた egress-proxy のイメージがホストにあることが確実で、外からイメージを pull しなくて済むからである。
`docker compose down` でコンテナごと消えたボリュームは、イメージを特定できないので書き出さない（次に `up` したときの実行で書き出される）。
停止後に起動した squid が `access.log` の無いディレクトリでファイルを作り直すこと、egress-proxy のイメージに `sh` / `mv` / `rm` があることは**未確認**である。

退避は logrotate の create 方式である。
`mv` のあと rotate までの間に来た行は、squid が開いたままのファイル（退避ファイル）に入り、rotate のあとの行は新しい `access.log` に入る。
この手順で行が欠けないこと、`logfile_rotate` を書かない設定のままで成り立つことは、squid 5.7 を直接起動して実測した（`mv` → CONNECT → `-k rotate` → CONNECT を2周し、全行がどちらかのファイルに1回ずつ入った）。
`squid -k rotate` は squid と同じ uid から送れば root も capability も要らない（同じく実測。別の uid からは未確認）。
ただし egress-proxy のイメージでは squid が `squid -N` で PID 1 として動き、pid ファイルの値が 1 になるので、`squid -k rotate` は `Bad PID file ... unreasonably small PID value: 1` で拒否される（ホスト検収で実測）。
`squid -k rotate` がしているのは squid の pid へ SIGUSR1 を送ることだけなので、ジョブは `docker kill --signal=USR1` でコンテナの PID 1（squid）へ直接送る。
これで squid が新しい `access.log` を作って開き直し、その後の行が新しいファイルへ入ることも同じ検収で実測した。
コンテナの中で `docker exec` が uid 13 として動き、`mv` と `rm` がイメージに入っていて、`read_only` のルートと `cap_drop: [ALL]` の下でもボリューム上で通ることは**未確認**である（この開発環境には docker が無い）。
実装者は docker のスタブでテストを組み、実機での確認は検収に回す。

退避ファイルの名前は固定にする（`access.log.export` など）。
前回の実行が書き出しの途中で失敗して退避ファイルが残っていても、次の実行で先にそれを書き出せば行は失われない。
固定名にしたのは、退避が2つ以上溜まる経路を作らないためである。

書き出しの途中で失敗して状態がはっきりしないとき（`docker exec` が失敗を返したが、コンテナの中のコマンドは効いていたかもしれない場合など）は、行を失うより重複させるほうを取る。
保管庫に書いたファイルを消すのは、退避ファイルが残っていて次の実行で書き出し直されると確かめられたときだけにする。
確かめられないときは保管庫のファイルを残して失敗とし、次の実行で同じ行が重複しうることを受け入れる。

`docker exec` が失敗を返したのにコンテナの中のコマンドが効いていた場合を考慮する範囲は、行が失われる経路を塞ぐところまでとする。
そのときの状態ファイルの記録が実際とずれることは受け入れる。
docker の操作が失敗したと分かっている場合は、その失敗を別の状態（読めるコンテナが無い、label が不正など）に読み替えず、失敗として記録する。

rotate（SIGUSR1）を送ってから squid が新しい `access.log` を開き直すまでには間がありうる。
退避ファイルを読んで消すのは、開き直したと確かめてからにする。

保管庫のファイル名は、書き出した時刻（UTC）を入れた `access-<YYYYMMDDTHHMMSSZ>.log.gz` とする。
1ファイルが持つのは前回の書き出しから今回の退避までの行である。
保持期間の判定はファイル名の時刻で行う（mtime はコピーやバックアップで変わるため）。

### 状態ファイル

監査側が「ジョブが止まっていないか」を判定するために読む。
書式は `key=value` の行とし、少なくとも次を持つ。

- 最終実行の開始時刻と終了時刻（UTC、ISO 8601）
- 全体の結果（`ok` / `partial` / `failed`）
- ボリュームごとの結果（稼働中から書き出した、停止中から書き出した、読めるコンテナが無い、label が不正、など）と書き出した行数

Docker に繋がらない場合も、状態ファイルは `failed` として書き、非ゼロで終わる。
状態ファイルを書けなかった場合だけは標準エラーにしか残らない（plist の `StandardErrorPath` で `~/Library/Logs/` 配下のファイルへ向ける）。

### 実行の契機

`StartCalendarInterval` で1日1回とする。
スリープ中に過ぎた予定は復帰時に1回だけ走る（launchd の挙動。未確認——実装者が `man launchd.plist` で確かめる）。
手で1回走らせる入口として `proxy-log-setup.sh run` を置く。

### 文書

`host-tools/README.md` に、install / uninstall / run の使い方と、保管庫の契約（配置、ファイル名、状態ファイルの書式、保持期間、行の形式は egress-proxy の版で変わりうること）を書く。
行の形式そのものは squid.conf の `logformat` が正本なので、README には写さず参照だけ置く。
既存の compose を使っている利用者が label を付ける手順（ボリュームの作り直しでログが消えること）も README に書く。

### やらないこと

- 抑制リスト・未判定・照会・通知（監査側が持つ）
- mount しているコンテナが1つも無いボリューム（`docker compose down` のあと）からの書き出し。その状態で `docker volume rm` されたら、最後の書き出しより後の行は失われるが、受け入れる
- 外からのイメージの pull
- logformat の変更（0049）
- Windows / Linux のホスト。macOS 以外では `proxy-log-setup.sh` はどのサブコマンドでも何も配置せず、その旨を出して 0 で終わる（`loopback-setup.sh` と同じ扱い）
- 保管庫の暗号化と圧縮率の調整
- 検査の深さ: label の値の検証は上の文字種と重複だけを見る。プロジェクト名の長さの上限、ディスク容量の不足、保管庫の権限の異常、時計の巻き戻りは検査の対象にしない

### 検収

ホストで次を確かめる。

1. karakuri の proxy-log ボリュームを label 付きで作り直す（`docker compose down` → `docker volume rm karakuri-proxy-log` → `up`。それまでのログは消える）
2. `proxy-log-setup.sh install` → `run` で、保管庫に gzip が1本でき、`access.log` が空から書き直されていること、状態ファイルが `ok` であること
3. proxy を止めた状態で `run` し、止める前の行が書き出されること。そのあと起動した proxy が新しい `access.log` に書くこと
4. 2 の直後にもう一度 `run` して、行が重複せずに次のファイルへ入ること。2 と 4 では、`run` のあいだに通信を流し続け、保管庫と新しい `access.log` の行数の合計が流した行数と一致することも確かめる
5. clone を別の場所へ移してからも `run` とスケジュール実行が動くこと

## 保証

### 新たに宣言する保証

台帳の末尾に節を新設する（`host-tools/tests/proxy-log.test.sh` — `host-tools/proxy-log-setup.sh` と `host-tools/proxy-log/`）。
テスト名は実装時に決め、各行に併記する。

- label `karakuri.egress-log` を持ち、mount しているコンテナ（停止中を含む）があるボリュームのアクセスログは、1回の実行ごとにホストの保管庫のそのプロジェクトのディレクトリへ書き出される。書き出した行は保管庫で欠けず、次の実行で重複しない。前回の実行が途中で失敗していても、その分の行は次の実行で書き出される（テスト: 新設）
- 保管庫の中で365日を超えたファイルは消え、それより新しいファイルは消えない（テスト: 新設）
- label の値が不正なボリュームと、値が他と重複するボリュームは保管庫に書き出されず、その旨が状態ファイルに残る。他のボリュームの書き出しは続く（テスト: 新設）
- 各実行は、最終実行の時刻と結果を状態ファイルに残す。Docker に繋がらないときも、失敗として残す（テスト: 新設）
- macOS 以外では、どのサブコマンドも何も配置せず 0 で終わる（テスト: 新設）
- 保管庫のファイル名は `access-<YYYYMMDDTHHMMSSZ>.log.gz`（書き出した時刻、UTC）である。状態ファイルは最終実行の開始時刻・終了時刻・全体の結果（`ok` / `partial` / `failed`）と、ボリューム名をキーにしたボリュームごとの結果（書き出した行数、読めるコンテナが無い、label が不正、など）を持つ（テスト: 新設）
- docker が見つからないとき、`proxy-log-setup.sh install` は非ゼロで終わり、何も配置しない（テスト: 新設）
- `proxy-log-setup.sh install` は2回打っても0で終わり、置かれる内容は変わらない。`uninstall` は保管庫と状態ファイルを残す（テスト: 新設）
- 実機の Docker と egress-proxy で、書き出しのあいだに来た行が欠けない — `未検証の約束 (テスト困難: ホストの Docker と稼働中の egress-proxy が要る。漏れうるのはコンテナ内での mv の権限と、SIGUSR1 を受けた squid の開き直しで、検収で行数の突き合わせを行う)`

### 維持する保証

- 公開面の定義（台帳「境界宣言」）の `host-tools/` の列挙に、新設の `host-tools/proxy-log-setup.sh` と `host-tools/proxy-log/` を足す。既存の項目は変えない
- 雛形の compose（台帳「境界宣言」の E）の既存のサービス定義は変えず、ボリュームに label を足すだけである

### 廃止する保証

- なし（新しい公開面を足す変更で、既存の約束を取り下げない）
