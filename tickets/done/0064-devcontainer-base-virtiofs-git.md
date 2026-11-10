---
status: close
type: fix
base: main
targets:
  - images/devcontainer-base/Dockerfile
  - images/devcontainer-base/README.md
  - .github/workflows/devcontainer-base.yml
  - docs/guarantees.md # 拡張: 新たに宣言する保証の台帳行
bundle:
  - 0064-devcontainer-base-virtiofs-git
  - 0065-karakuri-pin-3-1-0
verify:
  - pnpm lint:sh
  - pnpm lint
  - pnpm test
---

# virtiofs 上の作業ツリーで git が所有者の揺れに止められないよう、devcontainer-base の system gitconfig を設定する

## 内容

devcontainer-base を使う複数のプロジェクトから、同じ不具合が報告されている（2026-11-04、2026-11-09。2026-11-09 には別のコンテナでも再現した）。

- `/workspaces` 配下で、git が `fatal: detected dubious ownership in repository` で止まる。打ち直すと通る
- 作業ツリーに変更が無いのに、`git rebase --autosquash` が「ローカルの変更が上書きされる」で止まった例がある。`git update-index --refresh` を打つと通った
- `git commit` は成功し、同じコマンドの中で直後に続けた `git log` と `git status` が dubious ownership で止まった例がある

原因の見立ては報告元の調査で一致している。
`/workspaces` は Docker Desktop の virtiofs のマウントで、書き込みの多い操作の直後の約 1 秒（属性キャッシュの期間）だけ、所有者が uid 0 に見える。
dubious ownership は、git がリポジトリの所有者と実行ユーザーの uid を比べる検査（CVE-2022-24765 への対策）が、この一瞬を拾ったもの。
rebase が止まった件は、index に記録した stat 情報（uid を含む）と今の stat の食い違いを、git が「変更あり」と判定したものと読める。作業ツリーを守る検査は stat が食い違うと中身を比べずに拒否するので、`update-index --refresh` で stat を記録し直すと通る。

対処として 2 つの設定を `--system`（`/etc/gitconfig`）に焼く。
`/etc/gitconfig` は root の所有なので、dev の利用者（node）からは書き換えられない。
`safe.directory` は git が protected configuration（system / global / コマンドライン）からしか読まないので、system スコープなら効く（リポジトリの `.git/config` に書いた値は無視される。git 2.47.3 で実測）。

- `safe.directory = /workspaces/*` — dubious ownership 用。末尾の `/*` は git 2.46 以降の前方一致で、`/workspaces/` で始まるパスにだけ一致し、`/workspaces` そのものには一致しない。焼いた git は 2.47.3（このリポジトリの dev で確認）。`/workspaces/<repo>` は通り `/workspaces` 直上の型は拒否されることを、`GIT_TEST_ASSUME_DIFFERENT_OWNER=1` で同じ形のパターンを当てて実測した（git 2.47.3）
- `core.checkStat = minimal` — index の stat の食い違い用。uid / gid / inode と、mtime・ctime の秒未満を比べなくなる。比べ続けるのは mtime の秒、ctime の秒（`core.trustCtime` は既定の true）、サイズ（git 2.47.3 の `git help config` の記述）

### 守りが下がらないことの判断

- `safe.directory` が防ぐのは、別の uid の利用者が親ディレクトリに `.git` を仕込み、`core.fsmonitor` などからコマンドを走らせる攻撃。dev で node 以外の uid として `/workspaces` 配下にリポジトリを置けるのは root だけで、root は node の設定ファイルも書き換えられるので、この検査で止める意味がもともと無い。
  「root だけ」はイメージの構成から来る。ログインできるアカウントは root と node の 2 つで、node の sudo は `/etc/sudoers.d/node-firewall` で `init-project-firewall.sh` を引数なしで走らせることにしか許されていない（runtime-base の Dockerfile）。root で動くプロセスは sshd の特権分離の親だけである（3.1.0 の dev で `ps` により確認）。
  dev の外（ホストや、同じディレクトリをマウントした別のコンテナ）からの書き込みは、dev の構成では制御できない。ただしその書き手は、node が所有する既存のリポジトリの `.git/config` も書き換えられるので、所有者の検査では止まらない。ホストからの書き込みは virtiofs 上で uid 1000（node）として見えるので、検査をそもそも素通りする（3.1.0 の dev で `ls -n /workspaces` により確認）
- node 自身が置いたリポジトリ（`.git` 入りのアーカイブを展開したもの、エージェントが書いた `.git/config`）は所有者が node なので、設定の前から検査を素通りする。前方一致でも、配下に clone した第三者のリポジトリの扱いは実質変わらない
- `/workspaces` そのものは前方一致に含まれないので、`/workspaces/.git` を仕込む型への検査は残る
- `core.checkStat = minimal` で見落としが起き得るのは、同じ秒の中で同じサイズのまま書き換えた場合。index と同じ秒の mtime を持つエントリは、git が中身を読み直す（racy-git の扱い）ので拾える。mtime を戻す道具は ctime の秒で捕まる

### 変えるもの

- `images/devcontainer-base/Dockerfile` で、`git config --system` により上の 2 つを設定する。置き場所は git の節の近く。コメントには、症状・virtiofs の属性キャッシュという原因・守りが下がらない理由を短く書く
- `.github/workflows/devcontainer-base.yml` の smoke test（`docker run --rm ... crit --version` などが並ぶ箇所）に、`git config --system --get safe.directory` が `/workspaces/*` を、`git config --system --get core.checkStat` が `minimal` を返すことの確認を足す
- `images/devcontainer-base/README.md` の「既知のトレードオフ」に、所有者の検査を `/workspaces/*` で外していることと、stat の比較を緩めていることを、上の判断と一緒に書く

### 検収

karakuri 自身の dev は 0065 で同じ設定を一時的に持っており、dubious ownership については効果を実測済みである（`/workspaces/<repo>` で commit → log → status を 200 回まわし、`GIT_CONFIG_NOSYSTEM=1` の否定対照は 9 回失敗、設定ありは 0 回。2026-11-10）。`core.checkStat` の効果は未計測。ghcr.io には届かないので、配布物は CI と利用側の rebuild で確かめる。

1. CI の smoke test が両アーキで通ること
2. タグを打ったあと、利用側のプロジェクトのどれか 1 つで rebuild し、`git config --show-origin --get-all safe.directory` と `git config --show-origin --get core.checkStat` がどちらも `file:/etc/gitconfig` を示すこと
3. 同じ環境で、`git commit` の直後に `git log` と `git status` を同じコマンドの中で続けても、dubious ownership で止まらないこと
4. `git rebase --autosquash` を何度か打ち、「ローカルの変更が上書きされる」で止まらないこと。止まった場合、uid 以外（mtime の秒、ctime の秒、サイズ）も揺れていることになり、`core.checkStat` では防げない。その結果をこのチケットに記録して、別の手立てを起票する

### やらないこと

- リポジトリを virtiofs の外に置く構成への変更
- git の再試行ラッパー（報告元の両方が非推奨としている）
- runtime-base への設定（prod は virtiofs に載らない）
- karakuri 自身の dev への反映（0065 が一時的に同じ設定を持つ）
- タグを打つこと。この変更は `devcontainer-base-v3.2.0` で配る

## 保証

### 新たに宣言する保証

- devcontainer-base の dev では、`/workspaces` 配下のリポジトリを、所有者の uid が一時的に食い違って見えても git が拒否しない — `未検証の約束 (テスト困難: イメージのビルドと virtiofs のマウントが要る。タグを打った後の rebuild を検収で確認する)`

### 維持する保証

- §22・§24 の git identity と personal-setup。system gitconfig に足すだけで、global の書き込みには触れない
- runtime-base の `core.hooksPath`（system スコープ）。同じファイルへ別のキーを足すだけで、値は変えない

### 廃止する保証

- なし
