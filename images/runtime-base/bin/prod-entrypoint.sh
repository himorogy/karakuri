#!/bin/sh
# /usr/local/bin/prod-entrypoint.sh
#
# broker (ホスト側で秘密鍵を保管・認可する任意のコマンド) の dotenv 形式
# 出力を stdin から受け取り、コンテナ内 tmpfs (/run/secrets) へ書き出す。
# その後、明示された git ref から /src (tmpfs。起動ごとに捨てることで、前回
# 実行が打ったローカル ref や書き残した .git/config を持ち越さない) を復元し、
# "$@" を exec する。環境変数を一切経由しないため、ホストシェルの environ にも
# compose プロセスの environ にも docker inspect の Config.Env にも
# secret は現れない
# (docs/prod-secret-isolation-design.md §4.1 / §4.6)。
set -eu
: "${GIT_REPO:?}" "${GIT_REF:?}"

# broker がどの OS で走るか (ひいては改行コードが LF か CRLF か) は
# 読めないため、行末の CR は毎行剥がす。剥がし忘れると鍵名や値の末尾に
# 不可視の \r が残り、shim 側のファイル比較や dotenvx の鍵選択が
# 不可解に失敗する。
cr=$(printf '\r')

# --- secrets: stdin (dotenv 形式) -> /run/secrets (tmpfs) ---
umask 077
mkdir -p /run/secrets
# entrypoint は入力を反射しない: パース失敗時のメッセージに $line や $k を
# 埋めない。broker の出力が壊れて "KEY=" の形になっていない場合、その行は
# secret 本体そのものでありうる。`logging: none` はホストのログファイルを
# 止めるだけで、アタッチ先の端末表示 (とそのスクロールバック) は止められ
# ないため、位置は行番号だけで示す
# (docs/prod-secret-isolation-design.md §4.6)。
#
# lineno は「読んだ行」の通し番号 (空行・コメント行も数える)。n は「取り
# 込んだ secret の件数」で意味が異なる — n を流用すると後段の
# `[ "$n" -gt 0 ]` の検証 (「1 件も secret が来なかった」の検出) が壊れる
# ため、別カウンタにする。
n=0
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno+1))
  line=${line%"$cr"}
  case "$line" in ''|\#*) continue ;; esac

  # '=' を含まない行を許すと k=${line%%=*} が行全体を鍵名にしてしまい、
  # 意図しないファイル名で secret が書かれる事故につながるため、ここで
  # 弾く。
  case "$line" in
    *=*) ;;
    *) echo "invalid secret input at stdin line $lineno: missing '='" >&2; exit 1 ;;
  esac

  k=${line%%=*}
  v=${line#*=}

  # 鍵名を [A-Za-z_][A-Za-z0-9_]* に制限する。broker が壊れた行を
  # 出力した場合でも、"/" や ".." を含む鍵名で /run/secrets/$k が
  # パストラバーサルに使われないようにするための最終防波堤。
  case "$k" in
    [A-Za-z_]*) ;;
    *) echo "invalid secret input at stdin line $lineno: invalid key" >&2; exit 1 ;;
  esac
  case "$k" in
    *[!A-Za-z0-9_]*) echo "invalid secret input at stdin line $lineno: invalid key" >&2; exit 1 ;;
  esac

  # ダブルクォート / シングルクォートいずれの引用も剥がす。v の途中に
  # "=" が含まれるケース (DATABASE_URL=postgres://u:p@h/db?a=b 等) は、
  # v=${line#*=} が最初の "=" だけを削るので既に正しく残っている。
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
  esac

  [ -n "$v" ] || { echo "invalid secret input at stdin line $lineno: empty secret" >&2; exit 1; }
  printf '%s' "$v" > "/run/secrets/$k"
  n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "no secrets received on stdin" >&2; exit 1; }
export GIT_ASKPASS=/usr/local/bin/git-askpass

# --- self-check: /src が exec であること ----------------------------------------
# docker の tmpfs は既定で noexec が付き、uid=/gid=/mode= を渡してもそれは
# 消えない (docs/prod-secret-isolation-design.md §4.2)。これを忘れて
# `/src:uid=1000,gid=1000,mode=0755` のように `exec` を明示し忘れると、
# /src 自体のマウントは成立したまま起動してしまう。失敗が表面化するのは
# ずっと後、pnpm install が node_modules/.bin 配下の実行ファイル
# (例えば tsup) を呼ぶ段になってからで、"sh: 1: tsup: Permission denied"
# / rc=126 という、原因 (mount オプション) が読み取れない形で出る。ここで
# /src を使い始める前に自己検査し、早く原因を名指しして落とす。
#
# secrets の取込より後・git 操作より前に置く: secret が無い状態で落ちても
# 診断の役に立たず (この entrypoint が守るのは「secret や前提の欠落が沈黙
# した成功にならず、読み取れる失敗になる」ことであって、たまたま先に来た
# 検査を通すことではない)、また git 操作より前に置けば無駄な fetch を
# 避けられる。
#
# 検査手段は /proc/mounts の該当行を読むだけに留める。`mount` コマンドの
# 出力を併用する案もあったが、mount(8) はこのイメージに必須の依存として
# 入れておらず (util-linux は node:24 ベースイメージに元から入っているが、
# 明示的な依存として管理していない)、/proc/mounts は procfs がマウント
# されていれば常に読めるカーネル由来の情報源なので、外部コマンドに頼らず
# 検査できるこちらを選んだ (この判断は docker が使える環境での実測なしに
# 書いている。docker を要する検証項目
# (docs/prod-secret-isolation-design.md §10) に追加すべき)。
#
# /proc/mounts が読めない環境 (procfs 非マウント等) では検査自体が新しい
# 失敗原因になっては本末転倒なので、スキップして続行する。
if [ -r /proc/mounts ]; then
  src_mount_line=$(grep ' /src ' /proc/mounts 2>/dev/null || true)
  case "$src_mount_line" in
    *noexec*)
      echo "prod-entrypoint: /src is mounted noexec: $src_mount_line" >&2
      echo "prod-entrypoint:   compose の /src tmpfs マウントに 'exec' オプションの明示が必要" >&2
      echo "prod-entrypoint:   (例: tmpfs: [\"/src:exec,uid=1000,gid=1000,mode=0755\"])。" >&2
      echo "prod-entrypoint:   docker の tmpfs は既定で noexec が付き、uid=/gid=/mode= を渡しても消えない" >&2
      exit 1
      ;;
  esac
fi

# --- self-check: /src と secret の置き場が tmpfs であること ---------------------
# 上の noexec 検査とは別のブロックにする。扱いが違うため: noexec 検査は
# 診断が目的なので検査できない環境では黙ってスキップしてよいが、こちらは
# 防壁そのもの (下記) なので、検査できなかったことを黙って飲み込まない。
#
# /src が tmpfs でなくなる経路は現実的にありうる。「毎回 clone するのは
# 遅い」という動機で compose に `volumes: [prod-src:/src]` を足すと、起動も
# deploy も正常に成功し続ける。表面上は何も壊れないまま、前回実行の
# 信頼しないコードが /src/.git/config に書き残した設定 (core.fsmonitor 等、
# git が任意コマンドを起動する設定) が、次回の entrypoint 自身の git 操作で
# 発火する経路が復活する (CI で 8 回の発火を実測した)。checkout 前に走る
# のは entrypoint であって "$@" ではないため、後段の clean -xdff では防げ
# ない。
#
# secret の置き場が tmpfs でなくなれば、そこへ書いた平文 secret がコンテナの
# writable layer — すなわちホストの不揮発ディスク — へ落ちる。stdin 経由で
# 環境変数を避けた意味がここで消える。
#
# 検査対象は "/run" と直書きせず、secret を書く先 (/run/secrets) の親として
# 導出する。ここで守りたいのは「/run という名前のパス」ではなく「secret を
# 書く先が不揮発ディスクへ落ちないこと」であり、導出する方が検査の意図に
# 近い (secret の置き場を将来移しても検査が自動的に追随する)。dirname(1) を
# 呼ばずパラメータ展開で済ませるのは、上の noexec 検査と同じ理由 —
# 外部コマンドへの依存を増やさないため。
secrets_parent=/run/secrets
secrets_parent=${secrets_parent%/*}
# secret の置き場が最上位 (/foo) だと ${x%/*} は空文字になる。空のまま
# 検査すると「該当行なし」で WARNING に化けて防壁が黙って外れるので / に戻す。
[ -n "$secrets_parent" ] || secrets_parent=/

# この検査は secret を書いた後になるが、順序はこのままにする。検査を
# secrets 取込より前へ動かすと、broker 出力が壊れている場合の
# 診断 (行番号付きのパースエラー) がこの検査の後になり、読み取りにくくなる。
if [ -r /proc/mounts ]; then
  for mnt_target in /src "$secrets_parent"; do
    mnt_fstype=""
    mnt_line=""
    # 同じ mountpoint に複数行がある場合、実際に見えているのは最後にマウント
    # されたものなので、break せず最後の一致を採る。フィールドは 1 個の空白
    # 区切りなので、$mnt_dev 以降を空白で繋ぎ直せば元の行が復元できる。
    while read -r mnt_dev mnt_point mnt_type mnt_rest; do
      if [ "$mnt_point" = "$mnt_target" ]; then
        mnt_fstype="$mnt_type"
        mnt_line="$mnt_dev $mnt_point $mnt_type $mnt_rest"
      fi
    done < /proc/mounts

    if [ -z "$mnt_line" ]; then
      echo "prod-entrypoint: WARNING: cannot verify that $mnt_target is a tmpfs: no such mountpoint in /proc/mounts" >&2
      echo "prod-entrypoint:   検査を実施できないまま続行する（この検査は防壁なので黙ってスキップしない）" >&2
    elif [ "$mnt_fstype" != tmpfs ]; then
      echo "prod-entrypoint: $mnt_target is not a tmpfs: fstype=$mnt_fstype" >&2
      echo "prod-entrypoint:   mount line: $mnt_line" >&2
      echo "prod-entrypoint:   expected: tmpfs（/src は起動ごとに git から復元する使い捨てであり、" >&2
      echo "prod-entrypoint:   secret の置き場には平文の secret が載る。いずれもホストの不揮発" >&2
      echo "prod-entrypoint:   ディスクへ残してはならない）" >&2
      echo "prod-entrypoint:   compose に $mnt_target を指す volumes: / bind mount が足されていないか確認する" >&2
      exit 1
    fi
  done
else
  echo "prod-entrypoint: WARNING: cannot verify that /src and $secrets_parent are tmpfs: /proc/mounts is not readable" >&2
  echo "prod-entrypoint:   検査を実施できないまま続行する（この検査は防壁なので黙ってスキップしない）" >&2
fi

# --- GIT_REPO: URL への資格情報の埋め込みを拒否 ---------------------------------
# `GIT_REPO=https://x:<token>@github.com/...` の形で渡されると、下の
# `remote set-url` によってトークンが /src/.git/config へそのまま残る。
# checkout 後に /run/secrets/GH_TOKEN を消しても、exec で走る信頼しない
# コードが `git config remote.origin.url` で読めてしまい、取得用の資格情報を
# 実行側に残さないという前提が空振りになる。
#
# fetch より前ではなく remote の設定より前に置く: 一度でも set-url が走れば
# 資格情報はディスク上の config に書かれてしまうため。
#
# メッセージに $GIT_REPO を出さない (埋まっているのは資格情報そのもの)。
# ssh 形式 (git@github.com:owner/repo.git) は "://" を含まないためこの
# パターンには一致せず、従来どおり通る。
case "$GIT_REPO" in
  *://*@*)
    echo "prod-entrypoint: GIT_REPO must not embed credentials in the URL" >&2
    echo "prod-entrypoint:   URL に埋めた資格情報は remote set-url により .git/config へ残り、" >&2
    echo "prod-entrypoint:   exec 後に走る信頼しないコードから git config で読める" >&2
    echo "prod-entrypoint:   認証は stdin で渡した GH_TOKEN を GIT_ASKPASS 経由で使う設計なので、" >&2
    echo "prod-entrypoint:   GIT_REPO には資格情報を含まない URL を渡す" >&2
    exit 1
    ;;
esac

# --- workspace: clone/fetch + 明示 ref へ復元 ---
# git clone は非空ディレクトリで失敗するため init + fetch にする。前回
# 実行が失敗した残骸で /src が非空になっていても壊れない。
if [ ! -d /src/.git ]; then
  git init -q /src
fi
# remote が既にある場合 (volume 再利用) は set-url で冪等にする。
# add は二回目の呼び出しで "remote origin already exists" になるため。
if git -C /src remote get-url origin >/dev/null 2>&1; then
  git -C /src remote set-url origin "$GIT_REPO"
else
  git -C /src remote add origin "$GIT_REPO"
fi
# /src が非空の状態から始まっても、確実に $GIT_REF の内容へ戻すために
# 三段構えにする。三つの役割は重複ではない: checkout --detach --force が
# HEAD を動かし (HEAD が既に $GIT_REF を指していると checkout 単体では
# working tree を復元しない。--force を付けても「切り替えが起きない」ので
# 同じ)、reset --hard が tracked file の改変を $GIT_REF の内容へ戻し
# (clean が消すのは untracked / ignored のみで、これは担わない)、
# clean -xdff が untracked / ignored を消す。
#
# /src は tmpfs であり毎回まっさらなので、実運用ではこの三段構えは冗長に
# 見える。それでも残すのは、「毎回まっさら」が compose run --rm の挙動と
# tmpfs 指定という外部の前提に依存しているためで、その前提が崩れても
# 「明示された ref の内容が実行される」が成立するようにしておく (多重防御)。
# 前回実行が途中で失敗して /src に残骸が残っているケースも、この経路が
# 拾う (docs/prod-secret-isolation-design.md §4.6)。
git -C /src fetch --tags --prune origin

# --- GIT_REF: 完全な commit sha を既定で強制する --------------------------------
# 以前はラッパー (prod-run.sh) の警告だけで、ブランチ名やタグでも
# そのまま実行が続いていた。これは契約と実装がずれている: dev 側が書いた
# コードを prod がそのまま実行するという構造に対する唯一の
# ゲートは deploy 前の人間のレビューであり、その前提は「レビューした対象と
# 流したものが一致する」ことである。ブランチ名はその一致を切る (押した
# 瞬間に何を流したか分からず、後から再現もできない)。sha は content-
# addressed で偽装できず「古いかもしれないが既知で再現可能」という失敗に
# 留まる。失敗の性質が違うため既定は拒否とし、危険を理解した上でブランチ
# 運用を選ぶ余地だけ PROD_ALLOW_MUTABLE_REF=1 という明示的な脱出口で残す。
#
# この検査は entrypoint 側に置く。ラッパーを迂回して直接
# `docker compose run` された場合や、ラッパー自体の改変・迂回があっても
# 効くようにするため (ラッパー側の同種チェックは「権威」ではなく早期
# フィードバックに過ぎない。
# docs/prod-secret-isolation-design.md §4.6)。
case "$GIT_REF" in
  *[!0-9a-fA-F]*|"") mutable=1 ;;
  *) [ "${#GIT_REF}" -eq 40 ] && mutable=0 || mutable=1 ;;
esac
if [ "$mutable" -eq 1 ]; then
  if [ "${PROD_ALLOW_MUTABLE_REF:-}" = 1 ]; then
    echo "prod-entrypoint: WARNING: GIT_REF is not a full commit sha: $GIT_REF" >&2
    echo "prod-entrypoint:   可変 ref はレビュー対象と実行対象の一致を保証しない" >&2
  else
    echo "prod-entrypoint: GIT_REF must be a full 40-character commit sha: $GIT_REF" >&2
    echo "prod-entrypoint:   意図する場合は PROD_ALLOW_MUTABLE_REF=1 を設定する" >&2
    exit 1
  fi
fi

# GIT_REF が fetch 後の repo で commit として解決できない場合、
# 後続の `git checkout --detach --force "$GIT_REF"` は git の「ref として
# 解決できなければパス名として解釈する」挙動により
# "fatal: git checkout: --detach does not take a path argument '<ref>'"
# という、原因 (指定された ref が存在しない) を読み取れないメッセージで
# 落ちる。ここで先に ref 解決だけを検証し、読み取れる失敗にする
# (この設計の不変条件: secret や前提の欠落が沈黙した成功にならず、原因の
# 読み取れる失敗になること)。
# $GIT_REF は秘匿情報ではない (GIT_REPO / GIT_REF は stdin 経由の secret
# とは別に、通常の環境変数として渡す設計) ので、メッセージに含めてよい。
#
# `git checkout --detach --force -- "$GIT_REF"` のように `--` で ref と
# パスの曖昧さを断つことも検討したが採らない: `--` を付けると git は
# それ以降の引数を無条件にパスとして扱うため、正しい ref を渡した場合
# でも checkout がパス引数として解釈してしまい壊れる。ここで断ちたいのは
# 「ref 解決に失敗した後にパスへフォールバックする」あいまいさであって
# checkout の引数解釈そのものではないため、事前の `rev-parse --verify` に
# よる検証だけで十分。
commit=$(git -C /src rev-parse --verify --quiet "${GIT_REF}^{commit}") || {
  echo "GIT_REF does not resolve to a commit in the fetched repository: $GIT_REF" >&2
  exit 1
}

# 40 桁 hex は「sha である」ことを意味しない。dev 側 (信頼しない側) は 40 桁
# hex を名前とするブランチやタグを push でき、その hex に対応するオブジェクト
# が存在しなければ、上の rev-parse は refs/remotes/origin/<40 桁 hex> へ
# フォールバックして解決に成功する。上の書式検査だけでは mutable=0 のまま
# 可変 ref の内容が実行され、/run/prod-ref にも MUTABLE_REF=0 と記録されて
# しまう。解決結果が GIT_REF 自身と一致することをここで確かめて塞ぐ。
if [ "$mutable" -eq 0 ]; then
  # git が出力する sha は常に小文字。書式検査側の hex クラスを [0-9a-f] に
  # 絞る案もあったが、それだと大文字混じりの sha が「可変 ref」に分類され
  # PROD_ALLOW_MUTABLE_REF=1 で通ってしまい、意味がずれる。書式検査は
  # 大文字を受け入れたまま、比較のためだけにここで小文字へ畳む。
  git_ref_lc=$(printf '%s' "$GIT_REF" | tr 'A-F' 'a-f')
  if [ "$git_ref_lc" != "$commit" ]; then
    echo "prod-entrypoint: GIT_REF looks like a commit sha but resolved to a different object: $GIT_REF" >&2
    echo "prod-entrypoint:   resolved to: $commit" >&2
    echo "prod-entrypoint:   同じ 40 桁 hex を名前とするブランチ/タグが upstream に存在すると" >&2
    echo "prod-entrypoint:   この形になる。可変 ref の内容が immutable な sha として実行される" >&2
    exit 1
  fi
fi

# 何をデプロイしたかを残す。可変 ref を許した場合 (PROD_ALLOW_MUTABLE_REF=1)、
# これが「何をデプロイしたか」の唯一の記録になる。`logging: driver: none`
# のため docker logs では取れないが、アタッチしている手元の stderr には出る。
# 対話シェルを二段構え (`compose run -dT` で起動しておき `docker exec -it`
# で入る) にした場合は entrypoint の出力が detached 側へ行くため、
# `docker exec` で入ったシェルからは /run/prod-ref を読む (prod-context が
# 表示する。docs/prod-secret-isolation-design.md §4.3 / §4.6)。
echo "prod-entrypoint: GIT_REF=$GIT_REF resolved to $commit" >&2

# /run/prod-ref は umask 077 (このファイル冒頭) の影響を受けて既定では
# 0600 になる。sha は秘匿情報ではなく (GIT_REF / GIT_REPO は通常の環境
# 変数で渡す設計)、対話二段構えで `docker exec -it <c> bash` して入った
# シェル (entrypoint とは別プロセス・別 umask) から node ユーザーとして
# 読めるようにする必要があるため、明示的に 0644 へ緩める。
printf 'GIT_REF=%s\nGIT_COMMIT=%s\nMUTABLE_REF=%s\n' \
  "$GIT_REF" "$commit" "$mutable" > /run/prod-ref
chmod 644 /run/prod-ref

git -C /src checkout --detach --force "$GIT_REF"
git -C /src reset --hard "$GIT_REF"
git -C /src clean -xdff

# pnpm の store を node_modules と同一の tmpfs (/src) に置く。
# `read_only: true` の下では既定の $PNPM_HOME/store
# (/usr/local/share/pnpm/store) を作れず、pnpm install が ENOENT で落ちる。
# store は node_modules と別のマウント (例えば $HOME 配下) に置いてもよい
# わけではない: pnpm はパッケージをハードリンクで store から
# node_modules へ配るが、ハードリンクはマウントを跨げないため別マウント
# だと copy にフォールバックし、RAM 使用量が実測で倍になる (260M vs
# 131M。リンク数 2 以上のファイルが 0/3546 vs 3491/3546。pnpm 自身が
# `copied` / `hard linked` と出力で明言する)。
#
# 環境変数 npm_config_store_dir は効かない (実測)。$HOME/.npmrc や
# $HOME/.config/pnpm/rc に手で書いても効かない。`pnpm config set` だけが
# 効くことを実測で確認した。ただしこの設定が実際どのファイルへの
# 書き込みに依存して効いているのかは特定できていない
# (docs/prod-secret-isolation-design.md §11 の未決事項)。この行が壊れた
# ときにどこを見ればよいかは今のところ不明。
#
# store (/src/.pnpm-store) は /src の中にあるため、上の `clean -xdff` の
# 対象になる。entrypoint は checkout -> clean -> exec "$@" の順であり、
# pnpm install はその後 (exec された側) で走るため同一 run 内で消える
# ことはない。この順序 (store の設定を clean より後に置くこと) を
# 入れ替えてはならない。
#
# --- self-check: $HOME が書けること ---------------------------------------------
# `pnpm config set store-dir` は $HOME/.config/pnpm/config.yaml を書く。$HOME
# が書けない構成 (tmpfs の /home/node 指定漏れ、コンテナ実行 uid と tmpfs の
# uid= がずれている、等) だと、直後の `pnpm config set` が set -e で
# ここが落ちるだけになり、"$HOME" が原因だと画面上は分からない
# (mkdir/open の ENOENT や EACCES がそのまま出るだけで、期待していた前提
# が書かれない)。ここで先に検査し、何を期待していて何が実際かを名指しで
# 出してから落とす。
if [ ! -w "$HOME" ] || ! mkdir -p "$HOME/.config/pnpm" 2>/dev/null; then
  echo "prod-entrypoint: \$HOME is not writable: $HOME" >&2
  echo "prod-entrypoint:   expected: a writable tmpfs at \$HOME (compose の /home/node tmpfs 指定、" >&2
  echo "prod-entrypoint:   uid=/gid= が実行 uid と一致していること) so that" >&2
  echo "prod-entrypoint:   'pnpm config set store-dir' can write \$HOME/.config/pnpm/config.yaml" >&2
  echo "prod-entrypoint:   actual: mkdir -p \"\$HOME/.config/pnpm\" failed (see compose tmpfs / uid config)" >&2
  exit 1
fi

# set -eu 下なのでこのコマンドが失敗すれば entrypoint 全体がここで落ちる。
# それでよい: store を設定できないまま進めても、後続の pnpm install が
# ENOENT で落ちるだけなので、ここで早く落ちた方が原因を追いやすい。
pnpm config set store-dir /src/.pnpm-store

# clone 用トークンは checkout 後に破棄する。以降 exec で走るのは
# checkout 済みの信頼しないコードであり、そこから /run/secrets/GH_TOKEN
# を読ませない。取得用と実行用の資格情報を同一セッションに同居させない
# (docs/prod-secret-isolation-design.md §4.6)。
rm -f /run/secrets/GH_TOKEN
unset GIT_ASKPASS

# exec は引数なしだと何もせず exit 0 を返す。無引数呼び出しを「成功」
# として見逃さないよう、ここで明示的に落とす (前提の欠落を沈黙した成功に
# しない)。
[ "$#" -gt 0 ] || { echo "no command given" >&2; exit 1; }
exec "$@"
