#!/bin/sh
# /usr/local/bin/prod-entrypoint.sh
#
# broker (ホスト側で秘密鍵を保管・認可する任意のコマンド) の dotenv 形式
# 出力を stdin から受け取り、コンテナ内 tmpfs (/run/secrets) へ書き出す。
# その後、明示された git ref から /src (tmpfs。rev.5 / D18) を復元し、"$@" を
# exec する。環境変数を一切経由しないため、ホストシェルの environ にも
# compose プロセスの environ にも docker inspect の Config.Env にも
# secret は現れない
# (設計書 .local/prod-secret-isolation-design.md §4.1 / §4.6)。
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
# ないため、位置は行番号だけで示す (設計書 §4.6)。
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

# --- self-check: /src が exec であること (codex 指摘 #6) ------------------------
# compose の tmpfs 短縮形は既定で noexec になり (設計書 §4.2)、これを
# 忘れて `/src:uid=1000,gid=1000,mode=0755` のように `exec` を明示し忘れると、
# /src 自体のマウントは成立したまま起動してしまう。失敗が表面化するのは
# ずっと後、pnpm install が node_modules/.bin 配下の実行ファイル
# (例えば tsup) を呼ぶ段になってからで、"sh: 1: tsup: Permission denied"
# / rc=126 という、原因 (mount オプション) が読み取れない形で出る。ここで
# /src を使い始める前に自己検査し、早く原因を名指しして落とす。
#
# secrets の取込より後・git 操作より前に置く: secret が無い状態で落ちても
# 診断の役に立たず (I6 が求めるのは「前提の欠落が読み取れる失敗になる」
# ことであって、たまたま先に来た検査を通すことではない)、また git
# 操作より前に置けば無駄な fetch を避けられる。
#
# 検査手段は /proc/mounts の該当行を読むだけに留める。`mount` コマンドの
# 出力を併用する案もあったが、mount(8) はこのイメージに必須の依存として
# 入れておらず (util-linux は node:24 ベースイメージに元から入っているが、
# 明示的な依存として管理していない)、/proc/mounts は procfs がマウント
# されていれば常に読めるカーネル由来の情報源なので、外部コマンドに頼らず
# 検査できるこちらを選んだ (この判断は docker が使える環境での実測なしに
# 書いている。§10 の検証項目に追加すべき)。
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
      echo "prod-entrypoint:   既定の短縮形は noexec になる（設計書 §4.2 参照）" >&2
      exit 1
      ;;
  esac
fi

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
# named volume 再利用時に tracked file の改変を確実に戻すため、三段構え
# にする。三つの役割は重複ではない: checkout --detach --force が HEAD を
# 動かし (HEAD が既に $GIT_REF を指していると checkout 単体では working
# tree を復元しない。--force を付けても「切り替えが起きない」ので同じ)、
# reset --hard が tracked file の改変を $GIT_REF の内容へ戻し (clean が
# 消すのは untracked / ignored のみで、これは担わない)、clean -xdff が
# untracked / ignored を消す。reset --hard を欠くと、prod で走ったコード
# が自分のソースを書き換えた場合、次回同じ GIT_REF で起動しても改変済み
# コードが実行されてしまい I7 (「明示された ref から復元される」) が
# 破れる (設計書 §4.6)。
git -C /src fetch --tags --prune origin

# --- GIT_REF: 完全な commit sha を既定で強制する (rev.6 / D21) -----------------
# rev.5 まではラッパー (prod-run.sh) の警告だけで、ブランチ名やタグでも
# そのまま実行が続いていた。これは契約と実装がずれている: R10 の唯一の
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
# フィードバックに過ぎない。設計書 §4.6 / D21)。
case "$GIT_REF" in
  *[!0-9a-fA-F]*|"") mutable=1 ;;
  *) [ "${#GIT_REF}" -eq 40 ] && mutable=0 || mutable=1 ;;
esac
if [ "$mutable" -eq 1 ]; then
  if [ "${PROD_ALLOW_MUTABLE_REF:-}" = 1 ]; then
    echo "prod-entrypoint: WARNING: GIT_REF is not a full commit sha: $GIT_REF" >&2
    echo "prod-entrypoint:   可変 ref はレビュー対象と実行対象の一致を保証しない（設計書 R10 / D21）" >&2
  else
    echo "prod-entrypoint: GIT_REF must be a full 40-character commit sha: $GIT_REF" >&2
    echo "prod-entrypoint:   意図する場合は PROD_ALLOW_MUTABLE_REF=1 を設定する（設計書 D21）" >&2
    exit 1
  fi
fi

# バグ4: GIT_REF が fetch 後の repo で commit として解決できない場合、
# 後続の `git checkout --detach --force "$GIT_REF"` は git の「ref として
# 解決できなければパス名として解釈する」挙動により
# "fatal: git checkout: --detach does not take a path argument '<ref>'"
# という、原因 (指定された ref が存在しない) を読み取れないメッセージで
# 落ちる。ここで先に ref 解決だけを検証し、読み取れる失敗にする
# (設計の不変条件 I6: secret / 前提の欠落が読み取れる失敗になること)。
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

# 何をデプロイしたかを残す。可変 ref を許した場合 (PROD_ALLOW_MUTABLE_REF=1)、
# これが「何をデプロイしたか」の唯一の記録になる。`logging: driver: none`
# のため docker logs では取れないが、アタッチしている手元の stderr には出る。
# 対話二段構え (§11) では entrypoint の出力が detached 側へ行くため、
# `docker exec` で入ったシェルからは /run/prod-ref を読む (prod-context が
# 表示する。設計書 §4.3 / §4.6)。
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

# pnpm の store を node_modules と同一の tmpfs (/src) に置く (rev.5 / D19)。
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
# 書き込みに依存して効いているのかは特定できていない (設計書 §11 の
# 未決事項)。この行が壊れたときにどこを見ればよいかは今のところ不明。
#
# store (/src/.pnpm-store) は /src の中にあるため、上の `clean -xdff` の
# 対象になる。entrypoint は checkout -> clean -> exec "$@" の順であり、
# pnpm install はその後 (exec された側) で走るため同一 run 内で消える
# ことはない。この順序 (store の設定を clean より後に置くこと) を
# 入れ替えてはならない。
#
# --- self-check: $HOME が書けること (codex 指摘 #4) -----------------------------
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
# (設計書 §4.6)。
rm -f /run/secrets/GH_TOKEN
unset GIT_ASKPASS

# exec は引数なしだと何もせず exit 0 を返す。無引数呼び出しを「成功」
# として見逃さないよう、ここで明示的に落とす (I6)。
[ "$#" -gt 0 ] || { echo "no command given" >&2; exit 1; }
exec "$@"
