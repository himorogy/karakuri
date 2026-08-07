#!/bin/sh
# /usr/local/bin/secrets-ingest.sh
#
# stdin の dotenv 形式入力をパースし、コンテナ内 tmpfs (/run/secrets) へ
# 1 変数 1 ファイル (umask 077) で書き出す。呼び出し元は二つ:
#
#   - prod: prod-entrypoint.sh が起動時に stdin を引き継いで呼ぶ
#   - dev:  ホスト側の注入スクリプトが起動済みコンテナへ
#           `<broker> | docker exec -i <container> /usr/local/bin/secrets-ingest.sh`
#           の形で呼ぶ
#
# 方言パーサの実装をこの 1 ファイルに保つ。パーサが 2 実装になると、挙動の
# 食い違い (片方だけ通る入力) がそのまま搬送路の穴になる
# (docs/prod-secret-isolation-design.md §4.1 / §4.9)。
#
# 再実行は同名ファイルの上書きになる (冪等)。取込完了時には、書き込んだ
# 「鍵名だけ」を stderr へ 1 行で出す (値は絶対に出さない)。
set -eu

# broker がどの OS で走るか (ひいては改行コードが LF か CRLF か) は
# 読めないため、行末の CR は毎行剥がす。剥がし忘れると鍵名や値の末尾に
# 不可視の \r が残り、shim 側のファイル比較や dotenvx の鍵選択が
# 不可解に失敗する。
cr=$(printf '\r')

umask 077
mkdir -p /run/secrets
# このスクリプトは入力を反射しない: パース失敗時のメッセージに $line や $k を
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
names=""
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
  names="$names $k"
done
[ "$n" -gt 0 ] || { echo "no secrets received on stdin" >&2; exit 1; }

# 取り込んだ鍵名だけを 1 行で出す。ファイル名 (= 環境変数名) は上の鍵名検査を
# 通った [A-Za-z0-9_] のみで、名前だけなら安全に出せる。値は絶対に出さない。
# 注入した側 (ホストの端末) が「何が入ったか」をここで確認できるようにする
# (対話シェル起動時の prod-context の表示と同じ判断)。
echo "secrets-ingest: injected:$names" >&2
