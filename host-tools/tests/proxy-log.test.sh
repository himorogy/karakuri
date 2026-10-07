#!/usr/bin/env bash
#
# Tests for proxy-log-setup.sh and the export job it installs
# (host-tools/proxy-log/karakuri-proxy-log-export).
#
# No sudo is involved here (unlike loopback-setup.test.sh): the job only
# talks to the user's own docker socket, so every path this tool touches is
# already derived from $HOME. That means a sandbox is just "point $HOME at a
# scratch directory" — no sed rewriting of the scripts under test is needed.
#
# Docker itself is replaced by a fake `docker` on PATH (and recorded into the
# installed docker-bin file, exactly as the real install does) that models
# volumes and containers as plain files under $DOCKER_WORLD:
#
#   volume-labels                 <name>\t<label value>, one labeled volume per line
#   volumes/<name>/                the volume's content (what squid would see
#                                   mounted at /var/log/squid)
#   containers/<cid>/state         "running" or "stopped"
#   containers/<cid>/image         image name (read by `docker inspect -f {{.Image}}`)
#   containers/<cid>/mounts        volume names this container mounts, one per line
#                                   (drives `docker ps --filter volume=`)
#   containers/<cid>/fs/...        the container's view; fs/var/log/squid is a
#                                   symlink to volumes/<name> for containers that
#                                   actually mount a volume there
#   containers/<cid>/rotate-fail   if present, a `squid -k rotate` sent to this
#                                   container fails instead of recreating access.log
#   containers/<cid>/rotate-fail-effective
#                                   if present, a `squid -k rotate` sent to this
#                                   container really recreates access.log but
#                                   still reports failure
#   containers/<cid>/rotate-delay  if present, a `squid -k rotate` sent to this
#                                   container reports success without
#                                   recreating access.log (the test creates it
#                                   later, or never, to model the delay before
#                                   squid actually reopens its log)
#   containers/<cid>/mv-fail       if present, an `mv` sent to this container
#                                   fails instead of renaming the file
#   containers/<cid>/mv-fail-effective
#                                   if present, an `mv` sent to this container
#                                   really renames the file but still reports
#                                   failure
#   containers/<cid>/rm-fail       if present, an `rm -f` sent to this container
#                                   fails instead of removing the file
#   containers/<cid>/rm-fail-effective
#                                   if present, an `rm -f` sent to this container
#                                   really removes the file but still reports
#                                   failure (models a docker exec that loses its
#                                   connection after the command inside already ran)
#   containers/<cid>/exists-check-fail-after
#                                   its content is a call count N (1-based). The
#                                   job's presence check (sent both for a
#                                   leftover stash and to recheck a failed rm)
#                                   succeeds normally for the first N calls to
#                                   this container, then fails outright (exit 1,
#                                   no output) instead of reporting
#                                   present/absent (models docker itself being
#                                   unreachable)
#   containers/<cid>/exists-check-fail-until
#                                   the reverse of the above: its content is a
#                                   call count N (1-based); the presence check
#                                   fails outright for the first N calls, then
#                                   reports the real present/absent state from
#                                   then on (models a one-off failure that
#                                   later clears, as opposed to a persistent
#                                   one)
#   containers/<cid>/dir-check-fail
#                                   if present, the squid-log-directory check
#                                   `_find_proxy_container` sends to this
#                                   container fails outright (exit 1, no
#                                   output) instead of reporting present/absent
#   down                           if present, `docker version` fails (docker
#                                   unreachable)
#   ps-running-fail-after/<vol>    its content is a call count N (1-based).
#                                   The (N+1)th `docker ps --filter
#                                   volume=<vol>` (not -a) for that volume
#                                   fails outright instead of listing
#                                   anything. `_find_proxy_container` and
#                                   `_process_stopped` each send this in the
#                                   same form, so this counts calls across
#                                   both to let a test pass one and fail the
#                                   other
#   ps-all-fail-after/<vol>        same as above but for `docker ps -a
#                                   --filter volume=<vol>`
#   inspect-fail/<cid>             if present, `docker inspect -f
#                                   {{.Image}} <cid>` fails outright instead
#                                   of reporting the image name
#   run-fail/<image>               if present, `docker run ... <image> ...`
#                                   (spawning the throwaway container for the
#                                   stopped procedure) fails outright instead
#                                   of starting anything
#
# `docker exec <cid> sh -c '<script>'` rewrites the fixed path /var/log/squid
# in <script> to the container's fake fs root and then really runs it with
# `sh -c`, so mv/cat/rm/test behave for real against the fixture files. A
# literal `squid -k rotate` is special-cased to recreate an empty access.log,
# mirroring what rotate does to a live squid.
#
set -uo pipefail

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

assert_eq() {
	local label="$1" got="$2" want="$3"
	if [ "$got" = "$want" ]; then
		ok "$label"
	else
		ng "$label (got: '${got}', want: '${want}')"
	fi
}

assert_true() {
	local label="$1"
	if "${@:2}"; then
		ok "$label"
	else
		ng "$label"
	fi
}

assert_false() {
	local label="$1"
	if "${@:2}"; then
		ng "$label"
	else
		ok "$label"
	fi
}

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_DIR="$TEST_DIR/.."
SETUP_SH="$HOST_DIR/proxy-log-setup.sh"
JOB_SRC="$HOST_DIR/proxy-log/karakuri-proxy-log-export"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"

# docker を含まない PATH で proxy-log-setup.sh を走らせるテスト用。bash
# 自身は絶対パスで起動する——「docker を外した PATH」に合わせて PATH を
# 1 ディレクトリだけにすると、素の `bash` という名前の解決も同じ PATH を
# 通るため、ここで一度だけ解決した絶対パスを使わないと bash 自体が
# 見つからず command not found になる。
BASH_BIN="$(command -v bash)"

# --- フェイク uname --------------------------------------------------------------
cat >"$FAKE_BIN_DIR/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Darwin}"
FAKE_UNAME
chmod +x "$FAKE_BIN_DIR/uname"

# --- フェイク launchctl -----------------------------------------------------------
# 呼び出しを 1 行 1 回で記録し、bootout / bootstrap それぞれの終了コードを
# 環境変数で制御する。
cat >"$FAKE_BIN_DIR/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAUNCHCTL_LOG:?}"
case "${1:-}" in
bootout) exit "${FAKE_LAUNCHCTL_BOOTOUT_RC:-0}" ;;
bootstrap) exit "${FAKE_LAUNCHCTL_BOOTSTRAP_RC:-0}" ;;
esac
exit 0
FAKE_LAUNCHCTL
chmod +x "$FAKE_BIN_DIR/launchctl"

# --- フェイク docker --------------------------------------------------------------
cat >"$FAKE_BIN_DIR/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
W="${DOCKER_WORLD:?}"
cmd="${1:-}"
shift || true

case "$cmd" in
version)
	[ -e "$W/down" ] && exit 1
	exit 0
	;;
volume)
	sub="${1:-}"
	shift || true
	case "$sub" in
	ls)
		[ -f "$W/volume-labels" ] || exit 0
		cut -f1 "$W/volume-labels"
		exit 0
		;;
	inspect)
		name="$1"
		[ -f "$W/volume-labels" ] || exit 0
		awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$W/volume-labels"
		exit 0
		;;
	esac
	exit 1
	;;
ps)
	all=0
	if [ "${1:-}" = "-a" ]; then
		all=1
		shift
	fi
	vol=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--filter)
			vol="${2#volume=}"
			shift 2
			;;
		--format) shift 2 ;;
		*) shift ;;
		esac
	done
	# <kind>-fail-after/<vol> の内容は、何回目の呼び出しから失敗させるか
	# （1 始まり）。_find_proxy_container と _process_stopped は同じ
	# `docker ps` の形を別々に呼ぶので、片方だけを通して片方だけ失敗させる
	# テストにはこの数え上げが要る（exists-check-fail-after と同じ形）。
	if [ "$all" -eq 1 ]; then
		kind=ps-all
	else
		kind=ps-running
	fi
	thresh_file="$W/${kind}-fail-after/$vol"
	if [ -f "$thresh_file" ]; then
		count_file="$W/.${kind}-count/$vol"
		mkdir -p "$(dirname "$count_file")"
		n=0
		[ -f "$count_file" ] && n="$(cat "$count_file")"
		n=$((n + 1))
		printf '%s\n' "$n" >"$count_file"
		if [ "$n" -gt "$(cat "$thresh_file")" ]; then
			exit 1
		fi
	fi
	for d in "$W"/containers/*/; do
		[ -d "$d" ] || continue
		cid="$(basename "$d")"
		[ -f "${d}mounts" ] || continue
		grep -qxF "$vol" "${d}mounts" || continue
		state="$(cat "${d}state" 2>/dev/null || printf 'stopped\n')"
		if [ "$all" -eq 1 ] || [ "$state" = "running" ]; then
			printf '%s\n' "$cid"
		fi
	done
	exit 0
	;;
exec)
	cid="$1"
	shift
	root="$W/containers/$cid/fs"
	mkdir -p "$root"
	if [ "${1:-}" = "sh" ] && [ "${2:-}" = "-c" ]; then
		script="$3"
		case "$script" in
		*"squid -k rotate"*)
			if [ -e "$W/containers/$cid/rotate-fail" ]; then
				exit 1
			fi
			if [ -e "$W/containers/$cid/rotate-fail-effective" ]; then
				# docker exec が非ゼロを返しても、コンテナの中の squid は
				# 実際には開き直していることがある。そのずれを再現する
				# ため、本当に開き直したうえで失敗を返す。
				mkdir -p "$root/var/log/squid"
				[ -e "$root/var/log/squid/access.log" ] || : >"$root/var/log/squid/access.log"
				exit 1
			fi
			if [ -e "$W/containers/$cid/rotate-delay" ]; then
				# squid -k rotate はシグナルを送って戻るだけで、squid が
				# 実際に新しい access.log を開き直すまでには間がある
				# ことがある。ここでは開き直しをテストが手で起こすまで
				# 起こさない——access.log を作らずに成功で返す。
				exit 0
			fi
			# access.log を移動してから rotate を送った場合だけ、squid は
			# そのパスに新しい空ファイルを作る。移動していない（まだ
			# access.log が存在する）場合、rotate は同じファイルへの
			# 書き込みを続けるだけで中身は変わらない——チケット本文
			# 「現状」節の実測（squid 5.7）どおり。ここを無条件に
			# truncate すると、まだ退避していない内容を rotate のたびに
			# 消してしまう。
			mkdir -p "$root/var/log/squid"
			[ -e "$root/var/log/squid/access.log" ] || : >"$root/var/log/squid/access.log"
			exit 0
			;;
		"mv "*)
			if [ -e "$W/containers/$cid/mv-fail" ]; then
				exit 1
			fi
			if [ -e "$W/containers/$cid/mv-fail-effective" ]; then
				# docker exec が非ゼロを返しても、コンテナの中の mv は
				# 実際には効いていることがある。そのずれを再現する
				# ため、本当に mv したうえで失敗を返す。
				rewritten="$(printf '%s' "$script" | sed "s#/var/log/squid#${root}/var/log/squid#g")"
				sh -c "$rewritten"
				exit 1
			fi
			;;
		"rm -f "*)
			if [ -e "$W/containers/$cid/rm-fail" ]; then
				exit 1
			fi
			if [ -e "$W/containers/$cid/rm-fail-effective" ]; then
				# docker exec がデーモンとの接続断などで非ゼロを返しても、
				# コンテナの中の rm は実際に効いていることがある。その
				# ずれを再現するため、本当に rm したうえで失敗を返す。
				rewritten="$(printf '%s' "$script" | sed "s#/var/log/squid#${root}/var/log/squid#g")"
				sh -c "$rewritten"
				exit 1
			fi
			;;
		"if [ -e "*)
			# docker 自身がデーモンに繋がらない・コンテナが無いとき
			# 終了コード 1 で終わる、ジョブ側の _file_state が
			# present/absent のどちらとも区別できない状態を模す
			# ——標準出力を何も出さずに失敗で終わる。
			#
			# exists-check-fail-after の内容は、何回目の呼び出しから
			# 失敗させるか（1 始まり）。_flush_file は同じコンテナ・同じ
			# パスに対してこの確認を複数回呼ぶ（前回の退避の有無、rm
			# 失敗後の確かめ直し）ので、最初の呼び出しだけ素通す形も
			# テストに要る。
			thresh_file="$W/containers/$cid/exists-check-fail-after"
			until_file="$W/containers/$cid/exists-check-fail-until"
			if [ -f "$thresh_file" ] || [ -f "$until_file" ]; then
				count_file="$W/containers/$cid/.exists-check-count"
				n=0
				[ -f "$count_file" ] && n="$(cat "$count_file")"
				n=$((n + 1))
				printf '%s\n' "$n" >"$count_file"
				if [ -f "$thresh_file" ] && [ "$n" -gt "$(cat "$thresh_file")" ]; then
					exit 1
				fi
				# exists-check-fail-until の内容は、何回目の呼び出しまで
				# 失敗させるか（1 始まり）。exists-check-fail-after とは
				# 逆向き——「最初は確かめられず、少し経ってから確かめ
				# られるようになる」(一過性の不調が直る) 場合を模す。
				if [ -f "$until_file" ] && [ "$n" -le "$(cat "$until_file")" ]; then
					exit 1
				fi
			fi
			;;
		"if [ -d "*)
			# _find_proxy_container が squid の log ディレクトリの有無を
			# 確認するときの呼び出し。exists-check-fail-after と同じ形。
			if [ -e "$W/containers/$cid/dir-check-fail" ]; then
				exit 1
			fi
			;;
		esac
		rewritten="$(printf '%s' "$script" | sed "s#/var/log/squid#${root}/var/log/squid#g")"
		sh -c "$rewritten"
		exit $?
	fi
	if [ "${1:-}" = "cat" ]; then
		path="$(printf '%s' "$2" | sed "s#/var/log/squid#${root}/var/log/squid#g")"
		cat "$path"
		exit $?
	fi
	exit 1
	;;
inspect)
	shift # drop -f
	shift # drop the format string
	cid="$1"
	[ -e "$W/inspect-fail/$cid" ] && exit 1
	cat "$W/containers/$cid/image" 2>/dev/null
	exit 0
	;;
run)
	vol="" dest="" img=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-d) shift ;;
		--network) shift 2 ;;
		--user) shift 2 ;;
		--entrypoint) shift 2 ;;
		-v)
			vol="${2%%:*}"
			dest="${2#*:}"
			shift 2
			;;
		*) break ;;
		esac
	done
	img="$1"
	[ -e "$W/run-fail/$img" ] && exit 1
	n=0
	[ -f "$W/next-cid" ] && n="$(cat "$W/next-cid")"
	n=$((n + 1))
	printf '%s\n' "$n" >"$W/next-cid"
	newcid="tw${n}"
	mkdir -p "$W/containers/$newcid"
	printf 'running\n' >"$W/containers/$newcid/state"
	printf '%s\n' "$img" >"$W/containers/$newcid/image"
	: >"$W/containers/$newcid/mounts"
	mkdir -p "$W/volumes/$vol"
	mkdir -p "$W/containers/$newcid/fs$(dirname "$dest")"
	ln -sfn "$W/volumes/$vol" "$W/containers/$newcid/fs$dest"
	printf '%s\n' "$newcid"
	exit 0
	;;
rm)
	shift # drop -f
	cid="$1"
	rm -rf "$W/containers/$cid"
	exit 0
	;;
esac
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN_DIR/docker"

# --- サンドボックス ---------------------------------------------------------------
SANDBOX_N=0
SBHOME=""
DOCKER_WORLD=""
LAUNCHCTL_LOG=""

new_sandbox() {
	SANDBOX_N=$((SANDBOX_N + 1))
	local base="$WORKDIR/sandbox-$SANDBOX_N"
	SBHOME="$base/home"
	DOCKER_WORLD="$base/docker"
	mkdir -p "$SBHOME" "$DOCKER_WORLD/containers" "$DOCKER_WORLD/volumes"
	LAUNCHCTL_LOG="$base/launchctl.log"
	: >"$LAUNCHCTL_LOG"
	export DOCKER_WORLD LAUNCHCTL_LOG
	export FAKE_UNAME_S="Darwin"
	export FAKE_LAUNCHCTL_BOOTOUT_RC=0
	export FAKE_LAUNCHCTL_BOOTSTRAP_RC=0
}

add_volume() { # add_volume <name> <label-value>
	printf '%s\t%s\n' "$1" "$2" >>"$DOCKER_WORLD/volume-labels"
	mkdir -p "$DOCKER_WORLD/volumes/$1"
}

add_container() { # add_container <cid> <running|stopped> <image>
	mkdir -p "$DOCKER_WORLD/containers/$1/fs"
	printf '%s\n' "$2" >"$DOCKER_WORLD/containers/$1/state"
	printf '%s\n' "$3" >"$DOCKER_WORLD/containers/$1/image"
	: >"$DOCKER_WORLD/containers/$1/mounts"
}

mount_volume() { # mount_volume <cid> <vol> [<container-dest-path>]
	printf '%s\n' "$2" >>"$DOCKER_WORLD/containers/$1/mounts"
	if [ -n "${3:-}" ]; then
		mkdir -p "$DOCKER_WORLD/containers/$1/fs$(dirname "$3")"
		ln -sfn "$DOCKER_WORLD/volumes/$2" "$DOCKER_WORLD/containers/$1/fs$3"
	fi
}

fail_ps_running() { # fail_ps_running <vol> <after-N> -- the (after-N+1)th 'docker ps --filter volume=<vol>' (not -a) fails
	mkdir -p "$DOCKER_WORLD/ps-running-fail-after"
	printf '%s\n' "$2" >"$DOCKER_WORLD/ps-running-fail-after/$1"
}

fail_ps_all() { # fail_ps_all <vol> <after-N> -- the (after-N+1)th 'docker ps -a --filter volume=<vol>' fails
	mkdir -p "$DOCKER_WORLD/ps-all-fail-after"
	printf '%s\n' "$2" >"$DOCKER_WORLD/ps-all-fail-after/$1"
}

fail_inspect() { # fail_inspect <cid> -- 'docker inspect -f {{.Image}} <cid>' fails
	mkdir -p "$DOCKER_WORLD/inspect-fail"
	touch "$DOCKER_WORLD/inspect-fail/$1"
}

fail_run() { # fail_run <image> -- 'docker run ... <image> ...' (the throwaway container) fails
	mkdir -p "$DOCKER_WORLD/run-fail"
	touch "$DOCKER_WORLD/run-fail/$1"
}

run_setup() { # run_setup <argv...> -> sets RC/STDOUT/STDERR
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if HOME="$SBHOME" PATH="$FAKE_BIN_DIR:$PATH" bash "$SETUP_SH" "$@" >"$out" 2>"$err"; then
		RC=0
	else
		RC=$?
	fi
	STDOUT="$(cat "$out")"
	STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

run_job() { # run_job -> sets RC/STDOUT/STDERR; invokes the job source directly
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	if HOME="$SBHOME" "$JOB_SRC" >"$out" 2>"$err"; then
		RC=0
	else
		RC=$?
	fi
	STDOUT="$(cat "$out")"
	STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}

install_docker_bin_for_job() {
	mkdir -p "$SBHOME/.local/libexec/karakuri"
	printf '%s' "$FAKE_BIN_DIR/docker" >"$SBHOME/.local/libexec/karakuri/docker-bin"
}

status_file() { printf '%s\n' "$SBHOME/.local/state/karakuri/egress-log/status"; }

status_has() { # status_has <key=value>
	grep -qxF "$1" "$(status_file)"
}

# _past_ts <秒数> — 現在時刻からその秒数だけ過去の時刻を保管庫のファイル名
# 書式で出す。`date -d '-N days'` のような相対指定は GNU 拡張で、この
# ファイルは host-tools/ 配下として配布され macOS でも走る——BSD date には
# 無い。ジョブ本体の _epoch_from_ts と同じ考え方で、epoch へ引いてから
# GNU（`-d @epoch`）と BSD（`-r epoch`）の両方の絶対時刻書式を試す。
_past_ts() {
	local secs_ago="$1" now epoch
	now="$(date -u +%s)"
	epoch=$((now - secs_ago))
	date -u -d "@${epoch}" +%Y%m%dT%H%M%SZ 2>/dev/null ||
		date -u -r "${epoch}" +%Y%m%dT%H%M%SZ 2>/dev/null
}

echo "=== proxy-log-setup.sh: non-macOS ==="

for sub in install uninstall run; do
	new_sandbox
	FAKE_UNAME_S=Linux run_setup "$sub"
	assert_eq "non-macOS '$sub': exit 0" "$RC" "0"
	assert_eq "non-macOS '$sub': stdout is empty" "$STDOUT" ""
	assert_false "non-macOS '$sub': nothing under HOME was created" test -e "$SBHOME/.local"
done

echo "=== proxy-log-setup.sh: install ==="

new_sandbox
run_setup install
assert_eq "install: exits 0" "$RC" "0"
JOB_PATH="$SBHOME/.local/libexec/karakuri/karakuri-proxy-log-export"
assert_true "install: job body is placed" test -f "$JOB_PATH"
if cmp -s "$JOB_SRC" "$JOB_PATH"; then
	ok "install: job body is byte-identical to the source"
else
	ng "install: job body is byte-identical to the source"
fi
assert_eq "install: job body is executable (0755)" "$(stat -c '%a' "$JOB_PATH" 2>/dev/null || stat -f '%Lp' "$JOB_PATH")" "755"
assert_eq "install: docker-bin resolves the fake docker" "$(cat "$SBHOME/.local/libexec/karakuri/docker-bin")" "$FAKE_BIN_DIR/docker"
PLIST_PATH="$SBHOME/Library/LaunchAgents/com.karakuri.proxy-log-export.plist"
assert_true "install: plist is placed" test -f "$PLIST_PATH"
if grep -qF "__KARAKURI_JOB_PATH__" "$PLIST_PATH" || grep -qF "__KARAKURI_STDERR_LOG__" "$PLIST_PATH"; then
	ng "install: plist placeholders are substituted"
else
	ok "install: plist placeholders are substituted"
fi
assert_true "install: plist ProgramArguments points at the installed job" grep -qF "$JOB_PATH" "$PLIST_PATH"
assert_true "install: plist StandardErrorPath is under the sandbox HOME" grep -qF "$SBHOME/Library/Logs" "$PLIST_PATH"
if grep -qxF "bootout gui/$(id -u) ${PLIST_PATH}" "$LAUNCHCTL_LOG" && grep -qxF "bootstrap gui/$(id -u) ${PLIST_PATH}" "$LAUNCHCTL_LOG"; then
	ok "install: bootout then bootstrap were called"
else
	ng "install: bootout then bootstrap were called (log: $(cat "$LAUNCHCTL_LOG"))"
fi

echo "=== proxy-log-setup.sh: install without docker ==="

new_sandbox
run_setup_no_docker() {
	local out err
	out="$(mktemp)"
	err="$(mktemp)"
	# PATH はこのディレクトリだけにする——docker を含まない。launchctl /
	# uname のフェイクに加えて、install が docker を解決するまでに
	# proxy-log-setup.sh 自身が呼ぶ dirname と id を本物へのリンクで足す
	# （command -v で解決し、個々の呼び出し元の絶対パスには依存しない）。
	# ここに /usr/bin や /bin を足してはいけない——CI の実行環境
	# （ubuntu-latest）には /usr/bin/docker があり、足すと docker が
	# 見つかって install が通ってしまう。
	local nodocker="$WORKDIR/sandbox-$SANDBOX_N/nodocker-bin"
	mkdir -p "$nodocker"
	cp "$FAKE_BIN_DIR/uname" "$FAKE_BIN_DIR/launchctl" "$nodocker/"
	ln -s "$(command -v dirname)" "$nodocker/dirname"
	ln -s "$(command -v id)" "$nodocker/id"
	# フェイクの uname / launchctl 自身が `#!/usr/bin/env bash` なので、
	# それを exec する env が同じ PATH で bash を解決できないと、どの
	# フェイクも起動すら出来ない（command not found ではなく「macOS
	# only」の非対応分岐に化けて見える、紛らわしい壊れ方をする）。
	ln -s "$BASH_BIN" "$nodocker/bash"
	if HOME="$SBHOME" PATH="$nodocker" "$BASH_BIN" "$SETUP_SH" install >"$out" 2>"$err"; then
		RC=0
	else
		RC=$?
	fi
	STDOUT="$(cat "$out")"
	STDERR="$(cat "$err")"
	rm -f "$out" "$err"
}
run_setup_no_docker
assert_eq "install without docker: exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "install without docker: mentions 'docker'" bash -c "printf '%s' \"$STDERR\" | grep -qi docker"
assert_false "install without docker: nothing was placed" test -e "$SBHOME/.local"

echo "=== proxy-log-setup.sh: install with a missing payload ==="

new_sandbox
MISSING_SELF_DIR="$WORKDIR/sandbox-$SANDBOX_N/host"
mkdir -p "$MISSING_SELF_DIR"
cp "$SETUP_SH" "$MISSING_SELF_DIR/proxy-log-setup.sh"
chmod +x "$MISSING_SELF_DIR/proxy-log-setup.sh"
# proxy-log/ をわざと置かない。
out="$(mktemp)"
err="$(mktemp)"
if HOME="$SBHOME" PATH="$FAKE_BIN_DIR:$PATH" bash "$MISSING_SELF_DIR/proxy-log-setup.sh" install >"$out" 2>"$err"; then
	RC=0
else
	RC=$?
fi
STDOUT="$(cat "$out")"
STDERR="$(cat "$err")"
rm -f "$out" "$err"
assert_eq "install missing payload: exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "install missing payload: names the missing file" bash -c "printf '%s' \"$STDERR\" | grep -q karakuri-proxy-log-export"
assert_false "install missing payload: nothing was placed" test -e "$SBHOME/.local"

echo "=== proxy-log-setup.sh: install with a failing bootstrap ==="

new_sandbox
FAKE_LAUNCHCTL_BOOTSTRAP_RC=1 run_setup install
assert_eq "failing bootstrap: exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "failing bootstrap: job body is still placed" test -f "$SBHOME/.local/libexec/karakuri/karakuri-proxy-log-export"
assert_true "failing bootstrap: plist is still placed" test -f "$SBHOME/Library/LaunchAgents/com.karakuri.proxy-log-export.plist"

echo "=== proxy-log-setup.sh: install twice is idempotent ==="

new_sandbox
run_setup install
first="$(cat "$SBHOME/.local/libexec/karakuri/karakuri-proxy-log-export")"
first_plist="$(cat "$SBHOME/Library/LaunchAgents/com.karakuri.proxy-log-export.plist")"
run_setup install
assert_eq "install twice: second install exits 0" "$RC" "0"
assert_eq "install twice: job body unchanged" "$(cat "$SBHOME/.local/libexec/karakuri/karakuri-proxy-log-export")" "$first"
assert_eq "install twice: plist unchanged" "$(cat "$SBHOME/Library/LaunchAgents/com.karakuri.proxy-log-export.plist")" "$first_plist"

echo "=== proxy-log-setup.sh: uninstall ==="

new_sandbox
run_setup install
run_setup uninstall
assert_eq "uninstall: exits 0" "$RC" "0"
assert_false "uninstall: job body is gone" test -e "$SBHOME/.local/libexec/karakuri/karakuri-proxy-log-export"
assert_false "uninstall: plist is gone" test -e "$SBHOME/Library/LaunchAgents/com.karakuri.proxy-log-export.plist"
assert_true "uninstall: bootout was called" grep -q "bootout" "$LAUNCHCTL_LOG"

new_sandbox
run_setup uninstall
assert_eq "uninstall without install: still exits 0" "$RC" "0"

new_sandbox
run_setup install
mkdir -p "$SBHOME/.local/state/karakuri/egress-log/proj"
printf 'kept\n' >"$SBHOME/.local/state/karakuri/egress-log/proj/access-20200101T000000Z.log.gz"
printf 'run_start=2020-01-01T00:00:00Z\nrun_end=2020-01-01T00:00:01Z\nresult=ok\n' >"$SBHOME/.local/state/karakuri/egress-log/status"
run_setup uninstall
assert_true "uninstall: the vault is kept" test -f "$SBHOME/.local/state/karakuri/egress-log/proj/access-20200101T000000Z.log.gz"
assert_true "uninstall: the status file is kept" test -f "$SBHOME/.local/state/karakuri/egress-log/status"
assert_eq "uninstall: the status file content is untouched" "$(cat "$SBHOME/.local/state/karakuri/egress-log/status")" "$(printf 'run_start=2020-01-01T00:00:00Z\nrun_end=2020-01-01T00:00:01Z\nresult=ok')"

echo "=== proxy-log-setup.sh: run ==="

new_sandbox
run_setup run
assert_eq "run without install: exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "run without install: tells to install first" bash -c "printf '%s' \"$STDERR\" | grep -qi install"

new_sandbox
run_setup install
DOCKER_WORLD="$DOCKER_WORLD" run_setup run
assert_eq "run after install: exits 0 with no labeled volumes" "$RC" "0"
assert_true "run after install: writes the status file" test -f "$SBHOME/.local/state/karakuri/egress-log/status"
assert_true "run after install: status is ok" status_has "result=ok"

echo "=== karakuri-proxy-log-export: running proxy ==="

new_sandbox
install_docker_bin_for_job
add_volume vol1 proj1
add_container c-proxy running fake-proxy-image
mount_volume c-proxy vol1 /var/log/squid
# 同じボリュームを ro で mount しているだけの dev 風コンテナも同時に走って
# いる状態を混ぜる。squid の log ディレクトリを持たないので選ばれない。
add_container c-dev running fake-dev-image
mount_volume c-dev vol1 /var/log/egress-proxy
printf 'line1\nline2\nline3\n' >"$DOCKER_WORLD/volumes/vol1/access.log"

run_job
assert_eq "running: exits 0" "$RC" "0"
VAULT1="$SBHOME/.local/state/karakuri/egress-log/proj1"
GZ1="$(find "$VAULT1" -name 'access-*.log.gz')"
assert_eq "running: exactly one file is written" "$(printf '%s\n' "$GZ1" | grep -c .)" "1"
if [ -n "$GZ1" ] && [ "$(gunzip -c "$GZ1")" = "$(printf 'line1\nline2\nline3')" ]; then
	ok "running: the vault holds the original lines without loss"
else
	ng "running: the vault holds the original lines without loss"
fi
assert_false "running: the stash file is cleared" test -e "$DOCKER_WORLD/containers/c-proxy/fs/var/log/squid/access.log.export"
assert_true "running: access.log is freshly empty after rotate" bash -c "[ -f '$DOCKER_WORLD/volumes/vol1/access.log' ] && [ ! -s '$DOCKER_WORLD/volumes/vol1/access.log' ]"
assert_true "running: status records the volume and line count" status_has "volume.vol1=running:proj1:3"
VAULT_FILENAME_RE='^access-[0-9]{8}T[0-9]{6}Z\.log\.gz$'
if [[ "$(basename "$GZ1")" =~ $VAULT_FILENAME_RE ]]; then
	ok "running: the vault filename matches access-<YYYYMMDDTHHMMSSZ>.log.gz"
else
	ng "running: the vault filename matches access-<YYYYMMDDTHHMMSSZ>.log.gz (got '$(basename "$GZ1")')"
fi

# 2 回目の実行: 新しい行だけが次のファイルへ入り、前回の行と重複しない。
printf 'line4\nline5\n' >"$DOCKER_WORLD/volumes/vol1/access.log"
run_job
assert_eq "running second run: exits 0" "$RC" "0"
assert_eq "running second run: two files total now" "$(find "$VAULT1" -name 'access-*.log.gz' | wc -l)" "2"
NEWGZ="$(find "$VAULT1" -name 'access-*.log.gz' ! -path "$GZ1")"
if [ "$(gunzip -c "$NEWGZ")" = "$(printf 'line4\nline5')" ]; then
	ok "running second run: only the new lines are in the new file"
else
	ng "running second run: only the new lines are in the new file"
fi

echo "=== karakuri-proxy-log-export: running proxy write failure does not fall through to the stopped procedure ==="

new_sandbox
install_docker_bin_for_job
add_volume volF projf
add_container c-run-f running fake-proxy-image
mount_volume c-run-f volF /var/log/squid
printf 'keep1\nkeep2\n' >"$DOCKER_WORLD/volumes/volF/access.log"
# 書けない状態を作る。mv は対象ディレクトリへの書き込み権限を要るので、
# ボリュームのディレクトリ自体の書き込みビットを落とすと、squid の
# ログディレクトリを「持つ」(test -d は通る) が「書けない」コンテナになる。
chmod 0555 "$DOCKER_WORLD/volumes/volF"
# このボリュームを停止中のコンテナも mount している状態を混ぜる。稼働中の
# 書き出しが失敗したとき、停止中の手順へ落ちて代わりにこちらを読んでしまう
# と、稼働中の squid がまだ書いている行を失う。
add_container c-stopped-f stopped fake-proxy-image
mount_volume c-stopped-f volF

run_job
chmod 0755 "$DOCKER_WORLD/volumes/volF"
assert_eq "write failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "write failure: recorded as export-failed, not no-container" status_has "volume.volF=export-failed:projf"
assert_false "write failure: no throwaway container was spawned (no fallback to the stopped procedure)" test -d "$DOCKER_WORLD/containers/tw1"
assert_eq "write failure: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volF/access.log")" "$(printf 'keep1\nkeep2')"
assert_false "write failure: nothing was written to the vault" test -d "$SBHOME/.local/state/karakuri/egress-log/projf"

echo "=== karakuri-proxy-log-export: cannot confirm whether the running container is the writer — does not fall through to the stopped procedure ==="

new_sandbox
install_docker_bin_for_job
add_volume volC projc
add_container c-run-c running fake-proxy-image
mount_volume c-run-c volC /var/log/squid
touch "$DOCKER_WORLD/containers/c-run-c/dir-check-fail"
printf 'keep1\nkeep2\n' >"$DOCKER_WORLD/volumes/volC/access.log"
# このボリュームを停止中のコンテナも mount している。稼働中のコンテナが
# 書き手かどうか確認できなかったとき、ここへ落ちて代わりに読んでしまうと、
# 稼働中の squid がまだ書いている行を失う。
add_container c-stopped-c stopped fake-proxy-image
mount_volume c-stopped-c volC

run_job
assert_eq "cannot confirm writer: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "cannot confirm writer: recorded as export-failed, not no-container" status_has "volume.volC=export-failed:projc"
assert_false "cannot confirm writer: no throwaway container was spawned (no fallback to the stopped procedure)" test -d "$DOCKER_WORLD/containers/tw1"
assert_eq "cannot confirm writer: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volC/access.log")" "$(printf 'keep1\nkeep2')"
assert_false "cannot confirm writer: nothing was written to the vault" test -d "$SBHOME/.local/state/karakuri/egress-log/projc"

echo "=== karakuri-proxy-log-export: docker ps (running) failing inside the stopped procedure is not recorded as no-container ==="

new_sandbox
install_docker_bin_for_job
add_volume volP projp
add_container c-dev-p running fake-dev-image
mount_volume c-dev-p volP /var/log/egress-proxy
add_container c-old-p stopped fake-proxy-image
mount_volume c-old-p volP
printf 'devline1\n' >"$DOCKER_WORLD/volumes/volP/access.log"
# 1回目（_find_proxy_container が書き手を探すときの呼び出し）は通す。
# 2回目（_process_stopped が実行中のコンテナを除くときの呼び出し）から
# 失敗させる——これが失敗すると、実行中の c-dev-p が停止中として数えられ、
# 停止中の手順に進んでしまう。
fail_ps_running volP 1

run_job
assert_eq "ps running failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "ps running failure: recorded as export-failed, not no-container" status_has "volume.volP=export-failed:projp"
assert_eq "ps running failure: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volP/access.log")" "devline1"

echo "=== karakuri-proxy-log-export: docker ps -a failing inside the stopped procedure is not recorded as no-container ==="

new_sandbox
install_docker_bin_for_job
add_volume volQ projq
add_container c-dev-q running fake-dev-image
mount_volume c-dev-q volQ /var/log/egress-proxy
add_container c-old-q stopped fake-proxy-image
mount_volume c-old-q volQ
printf 'devline1\n' >"$DOCKER_WORLD/volumes/volQ/access.log"
# ps -a は _process_stopped しか呼ばないので、1回目から失敗させてよい。
fail_ps_all volQ 0

run_job
assert_eq "ps -a failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "ps -a failure: recorded as export-failed, not no-container" status_has "volume.volQ=export-failed:projq"
assert_eq "ps -a failure: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volQ/access.log")" "devline1"

echo "=== karakuri-proxy-log-export: docker inspect failing inside the stopped procedure is not recorded as no-container ==="

new_sandbox
install_docker_bin_for_job
add_volume volI proji
add_container c-dev-i running fake-dev-image
mount_volume c-dev-i volI /var/log/egress-proxy
add_container c-old-i stopped fake-proxy-image
mount_volume c-old-i volI
printf 'devline1\n' >"$DOCKER_WORLD/volumes/volI/access.log"
fail_inspect c-old-i

run_job
assert_eq "inspect failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "inspect failure: recorded as export-failed, not no-container" status_has "volume.volI=export-failed:proji"
assert_eq "inspect failure: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volI/access.log")" "devline1"

echo "=== karakuri-proxy-log-export: docker run failing to spawn the throwaway container is not recorded as no-container ==="

new_sandbox
install_docker_bin_for_job
add_volume volJ projj
add_container c-old-j stopped fake-proxy-image
mount_volume c-old-j volJ
printf 'stoppedline1\n' >"$DOCKER_WORLD/volumes/volJ/access.log"
# イメージは特定できている（inspect は成功する）。docker run 自体が
# 失敗する状態を作る。
fail_run fake-proxy-image

run_job
assert_eq "docker run failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "docker run failure: recorded as export-failed, not no-container" status_has "volume.volJ=export-failed:projj"
assert_eq "docker run failure: access.log is untouched" "$(cat "$DOCKER_WORLD/volumes/volJ/access.log")" "stoppedline1"

echo "=== karakuri-proxy-log-export: a failed rotate restores access.log instead of losing lines ==="

new_sandbox
install_docker_bin_for_job
add_volume volR projr
add_container c-run-r running fake-proxy-image
mount_volume c-run-r volR /var/log/squid
printf 'keep1\nkeep2\n' >"$DOCKER_WORLD/volumes/volR/access.log"
touch "$DOCKER_WORLD/containers/c-run-r/rotate-fail"

run_job
assert_eq "rotate failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "rotate failure: recorded as export-failed" status_has "volume.volR=export-failed:projr"
assert_eq "rotate failure: access.log is restored with no lines lost" "$(cat "$DOCKER_WORLD/volumes/volR/access.log")" "$(printf 'keep1\nkeep2')"
assert_false "rotate failure: the stash file is not left behind" test -e "$DOCKER_WORLD/volumes/volR/access.log.export"
assert_false "rotate failure: nothing was written to the vault" test -d "$SBHOME/.local/state/karakuri/egress-log/projr"

echo "=== karakuri-proxy-log-export: a failed rotate that really happened is not rolled back over the fresh access.log ==="

new_sandbox
install_docker_bin_for_job
add_volume volG projg
add_container c-run-g running fake-proxy-image
mount_volume c-run-g volG /var/log/squid
printf 'old1\nold2\n' >"$DOCKER_WORLD/volumes/volG/access.log"
touch "$DOCKER_WORLD/containers/c-run-g/rotate-fail-effective"

run_job
assert_eq "rotate effective failure: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "rotate effective failure: recorded as export-failed" status_has "volume.volG=export-failed:projg"
# rotate は exec の報告とは裏腹に実際には開き直していたので、access.log は
# 新しい空のファイルのはず。打ち消しの mv で古い内容を上書きしていたら
# ここが古い内容のままになる。
assert_eq "rotate effective failure: access.log is the fresh empty file, not rolled back" "$(cat "$DOCKER_WORLD/volumes/volG/access.log")" ""
assert_eq "rotate effective failure: the old content is in the stash, not lost" "$(cat "$DOCKER_WORLD/volumes/volG/access.log.export")" "$(printf 'old1\nold2')"
assert_false "rotate effective failure: nothing was written to the vault yet" test -d "$SBHOME/.local/state/karakuri/egress-log/projg"

echo "=== karakuri-proxy-log-export: an mv that really happened despite a reported failure is picked up on the next run without losing lines ==="

new_sandbox
install_docker_bin_for_job
add_volume volM projm
add_container c-run-m running fake-proxy-image
mount_volume c-run-m volM /var/log/squid
printf 'mvline1\nmvline2\n' >"$DOCKER_WORLD/volumes/volM/access.log"
touch "$DOCKER_WORLD/containers/c-run-m/mv-fail-effective"

run_job
assert_eq "mv effective failure: first run exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "mv effective failure: first run is recorded as export-failed" status_has "volume.volM=export-failed:projm"
# mv は実際には効いていたので、access.log は無く、退避ファイルに前回の
# 内容が入っているはず。squid はこの名前のファイルへ書き続けている体で、
# もう1行足す。
assert_false "mv effective failure: access.log does not exist (the mv really happened)" test -e "$DOCKER_WORLD/volumes/volM/access.log"
printf 'mvline3\n' >>"$DOCKER_WORLD/volumes/volM/access.log.export"
rm -f "$DOCKER_WORLD/containers/c-run-m/mv-fail-effective"

run_job
VAULTM="$SBHOME/.local/state/karakuri/egress-log/projm"
assert_eq "mv effective failure: second run exits 0" "$RC" "0"
ALL_M="$(for f in "$VAULTM"/access-*.log.gz; do [ -e "$f" ] && gunzip -c "$f"; printf '\n'; done)"
if printf '%s' "$ALL_M" | grep -qx 'mvline1' && printf '%s' "$ALL_M" | grep -qx 'mvline2' && printf '%s' "$ALL_M" | grep -qx 'mvline3'; then
	ok "mv effective failure: all three lines (including the one written after the failed mv) reached the vault"
else
	ng "mv effective failure: all three lines (including the one written after the failed mv) reached the vault"
fi
assert_eq "mv effective failure: no line is duplicated" "$(printf '%s' "$ALL_M" | grep -cx 'mvline1')" "1"
assert_true "mv effective failure: recorded with the combined line count" status_has "volume.volM=running:projm:3"

echo "=== karakuri-proxy-log-export: rotate succeeding late (squid reopens asynchronously) is waited for before reading the stash ==="

new_sandbox
install_docker_bin_for_job
add_volume volW projw
add_container c-run-w running fake-proxy-image
mount_volume c-run-w volW /var/log/squid
printf 'wait1\nwait2\n' >"$DOCKER_WORLD/volumes/volW/access.log"
touch "$DOCKER_WORLD/containers/c-run-w/rotate-delay"

# ジョブをバックグラウンドで走らせ、_wait_for_present が待っている間に
# squid の開き直しを手で起こす（本物の squid が非同期に access.log を
# 開き直すのを模す）。上限（10 回 × 0.2 秒 ≈ 2 秒）より先に間に合わせる。
HOME="$SBHOME" "$JOB_SRC" >/tmp/karakuri-test-wait-out.$$ 2>/tmp/karakuri-test-wait-err.$$ &
JOB_PID=$!
sleep 0.5
: >"$DOCKER_WORLD/volumes/volW/access.log"
wait "$JOB_PID"
RC=$?
rm -f "/tmp/karakuri-test-wait-out.$$" "/tmp/karakuri-test-wait-err.$$"

assert_eq "rotate delay: exits 0 once access.log appears in time" "$RC" "0"
VAULTW="$SBHOME/.local/state/karakuri/egress-log/projw"
GZW="$(find "$VAULTW" -name 'access-*.log.gz')"
if [ -n "$GZW" ] && [ "$(gunzip -c "$GZW")" = "$(printf 'wait1\nwait2')" ]; then
	ok "rotate delay: the lines written before the delayed rotate reach the vault"
else
	ng "rotate delay: the lines written before the delayed rotate reach the vault"
fi
assert_true "rotate delay: recorded as a normal successful export" status_has "volume.volW=running:projw:2"

echo "=== karakuri-proxy-log-export: rotate never taking effect in time is not read as success ==="

new_sandbox
install_docker_bin_for_job
add_volume volX projx
add_container c-run-x running fake-proxy-image
mount_volume c-run-x volX /var/log/squid
printf 'neverwait1\nneverwait2\n' >"$DOCKER_WORLD/volumes/volX/access.log"
touch "$DOCKER_WORLD/containers/c-run-x/rotate-delay"
# access.log を一度も作らない——上限に達するまで squid が開き直さない
# ケースを模す。

run_job
assert_eq "rotate timeout: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "rotate timeout: recorded as export-failed" status_has "volume.volX=export-failed:projx"
assert_false "rotate timeout: nothing was written to the vault" test -d "$SBHOME/.local/state/karakuri/egress-log/projx"
assert_eq "rotate timeout: the lines are still in the stash, not lost" "$(cat "$DOCKER_WORLD/volumes/volX/access.log.export")" "$(printf 'neverwait1\nneverwait2')"

echo "=== karakuri-proxy-log-export: a failed stash removal does not duplicate lines on the next run ==="

new_sandbox
install_docker_bin_for_job
add_volume volD projd
add_container c-run-d running fake-proxy-image
mount_volume c-run-d volD /var/log/squid
printf 'dup1\ndup2\n' >"$DOCKER_WORLD/volumes/volD/access.log"
touch "$DOCKER_WORLD/containers/c-run-d/rm-fail"

run_job
assert_eq "rm failure: first run exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "rm failure: first run is recorded as export-failed, not success" status_has "volume.volD=export-failed:projd"
VAULTD="$SBHOME/.local/state/karakuri/egress-log/projd"
assert_eq "rm failure: the vault file written before the failed rm is removed again" "$(find "$VAULTD" -name 'access-*.log.gz' 2>/dev/null | wc -l)" "0"
assert_true "rm failure: the stash file is left in place for the next run" test -e "$DOCKER_WORLD/volumes/volD/access.log.export"

# 次の実行では rm が通るようにしてから走らせる。前回の分がもう一度保管庫に
# 入るなら重複、1 回だけ入るなら直った、という形で区別できる。
rm -f "$DOCKER_WORLD/containers/c-run-d/rm-fail"
run_job
ALL_D="$(for f in "$VAULTD"/access-*.log.gz; do [ -e "$f" ] && gunzip -c "$f"; done)"
assert_eq "rm failure: once rm succeeds, each line from the failed run reaches the vault exactly once" "$(printf '%s' "$ALL_D" | grep -cx 'dup1')" "1"
assert_eq "rm failure: the other line is not duplicated either" "$(printf '%s' "$ALL_D" | grep -cx 'dup2')" "1"
assert_false "rm failure: the stash file is cleared once rm succeeds" test -e "$DOCKER_WORLD/volumes/volD/access.log.export"

echo "=== karakuri-proxy-log-export: rm reports failure after really removing the file — the vault line is not lost ==="

new_sandbox
install_docker_bin_for_job
add_volume volE proje
add_container c-run-e running fake-proxy-image
mount_volume c-run-e volE /var/log/squid
printf 'kept1\nkept2\n' >"$DOCKER_WORLD/volumes/volE/access.log"
touch "$DOCKER_WORLD/containers/c-run-e/rm-fail-effective"

run_job
VAULTE="$SBHOME/.local/state/karakuri/egress-log/proje"
GZE="$(find "$VAULTE" -name 'access-*.log.gz')"
assert_eq "rm effective failure: exactly one vault file, not deleted again" "$(printf '%s\n' "$GZE" | grep -c .)" "1"
if [ -n "$GZE" ] && [ "$(gunzip -c "$GZE")" = "$(printf 'kept1\nkept2')" ]; then
	ok "rm effective failure: the vault file holds the original lines"
else
	ng "rm effective failure: the vault file holds the original lines"
fi
assert_false "rm effective failure: the stash file really is gone (rm had worked)" test -e "$DOCKER_WORLD/volumes/volE/access.log.export"
# docker exec が中身の rm には関係なく失敗を返しただけなので、こちら側は
# 確認できた成功として扱ってよい——result が ok のままであることが
# 「確かめられたときは成功にする」側の分岐を通った証拠になる。
assert_eq "rm effective failure: exits 0 (confirmed success, not a false failure)" "$RC" "0"
assert_true "rm effective failure: recorded as a normal successful export" status_has "volume.volE=running:proje:2"

echo "=== karakuri-proxy-log-export: rm fails and the recheck itself is unreadable — treated as a failure, not a success ==="

new_sandbox
install_docker_bin_for_job
add_volume volU proju
add_container c-run-u running fake-proxy-image
mount_volume c-run-u volU /var/log/squid
printf 'unknown1\nunknown2\n' >"$DOCKER_WORLD/volumes/volU/access.log"
touch "$DOCKER_WORLD/containers/c-run-u/rm-fail"
# このコンテナへ送る "if [ -e " 確認は、この実行で以下の順に4回ある
# （いずれも素通す必要がある）: 1) _process_running 冒頭の前回退避の有無
# （今回は無い） 2) _flush_file 冒頭での同じ確認（_process_running と
# 同じ理由で二重に確認する） 3) rotate 後、access.log が開き直ったかの
# 確認（_wait_for_present） 4) 新しい退避ができたあとの _flush_file 冒頭
# での有無確認（今回は在る）。5回目（rm 失敗後の確かめ直し）から
# 確認できなくする。
printf '4\n' >"$DOCKER_WORLD/containers/c-run-u/exists-check-fail-after"

run_job
VAULTU="$SBHOME/.local/state/karakuri/egress-log/proju"
assert_eq "unknown recheck: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "unknown recheck: recorded as export-failed, not a false success" status_has "volume.volU=export-failed:proju"
assert_eq "unknown recheck: the vault file is kept, not deleted on a guess" "$(find "$VAULTU" -name 'access-*.log.gz' 2>/dev/null | wc -l)" "1"
assert_true "unknown recheck: the stash file is still there (rm really had failed)" test -e "$DOCKER_WORLD/volumes/volU/access.log.export"

echo "=== karakuri-proxy-log-export: cannot confirm whether a leftover stash exists — does not read it without rotating first ==="

new_sandbox
install_docker_bin_for_job
add_volume volL projl
add_container c-run-l running fake-proxy-image
mount_volume c-run-l volL /var/log/squid
# 前回の mv が報告とは裏腹に実際には効いていた状態を作る。access.log は
# 無く、退避ファイルに内容が残っている。
printf 'leftoverL1\nleftoverL2\n' >"$DOCKER_WORLD/volumes/volL/access.log.export"
# 最初の呼び出し（_process_running 冒頭での退避ファイルの有無の確認）
# だけ確認できなくする——一過性の不調で、2回目（_flush_file 冒頭での
# 同じ確認）は本物の状態（present）を返す。1回目の結果だけを見て
# rotate を送らずに読み進めないことを確かめる。
printf '1\n' >"$DOCKER_WORLD/containers/c-run-l/exists-check-fail-until"

run_job
assert_eq "cannot confirm leftover: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "cannot confirm leftover: recorded as export-failed" status_has "volume.volL=export-failed:projl"
assert_false "cannot confirm leftover: nothing was written to the vault" test -d "$SBHOME/.local/state/karakuri/egress-log/projl"
assert_eq "cannot confirm leftover: the stash file is untouched, not read and removed without rotating" "$(cat "$DOCKER_WORLD/volumes/volL/access.log.export")" "$(printf 'leftoverL1\nleftoverL2')"
assert_false "cannot confirm leftover: access.log was never created (rotate was never sent)" test -e "$DOCKER_WORLD/volumes/volL/access.log"

echo "=== karakuri-proxy-log-export: leftover stash from a failed run ==="

new_sandbox
install_docker_bin_for_job
add_volume vol2 proj2
add_container c-proxy2 running fake-proxy-image
mount_volume c-proxy2 vol2 /var/log/squid
printf 'leftover1\nleftover2\n' >"$DOCKER_WORLD/volumes/vol2/access.log.export"
printf 'fresh1\n' >"$DOCKER_WORLD/volumes/vol2/access.log"

run_job
assert_eq "leftover stash: exits 0" "$RC" "0"
VAULT2="$SBHOME/.local/state/karakuri/egress-log/proj2"
assert_eq "leftover stash: two files are written (leftover + new)" "$(find "$VAULT2" -name 'access-*.log.gz' | wc -l)" "2"
ALL_CONTENT="$(for f in "$VAULT2"/access-*.log.gz; do gunzip -c "$f"; printf '\n'; done)"
if printf '%s' "$ALL_CONTENT" | grep -qx "leftover1" && printf '%s' "$ALL_CONTENT" | grep -qx "fresh1"; then
	ok "leftover stash: both the leftover and the fresh lines reached the vault"
else
	ng "leftover stash: both the leftover and the fresh lines reached the vault"
fi
assert_false "leftover stash: the stash file is cleared" test -e "$DOCKER_WORLD/volumes/vol2/access.log.export"
assert_true "leftover stash: the status line count includes the leftover's lines" status_has "volume.vol2=running:proj2:3"

echo "=== karakuri-proxy-log-export: stopped proxy ==="

new_sandbox
install_docker_bin_for_job
add_volume vol3 proj3
add_container c-old stopped fake-proxy-image
mount_volume c-old vol3
printf 'stopped1\nstopped2\n' >"$DOCKER_WORLD/volumes/vol3/access.log"

run_job
assert_eq "stopped: exits 0" "$RC" "0"
VAULT3="$SBHOME/.local/state/karakuri/egress-log/proj3"
GZ3="$(find "$VAULT3" -name 'access-*.log.gz')"
assert_eq "stopped: exactly one file is written" "$(printf '%s\n' "$GZ3" | grep -c .)" "1"
if [ -n "$GZ3" ] && [ "$(gunzip -c "$GZ3")" = "$(printf 'stopped1\nstopped2')" ]; then
	ok "stopped: the throwaway container's read reaches the vault"
else
	ng "stopped: the throwaway container's read reaches the vault"
fi
assert_false "stopped: access.log is cleared from the volume" test -e "$DOCKER_WORLD/volumes/vol3/access.log"
assert_false "stopped: the throwaway container is removed afterwards" test -d "$DOCKER_WORLD/containers/tw1"
assert_true "stopped: status records the volume" status_has "volume.vol3=stopped:proj3:2"

echo "=== karakuri-proxy-log-export: stopped proxy, leftover stash unreadable ==="

new_sandbox
install_docker_bin_for_job
add_volume volS projs
add_container c-old-s stopped fake-proxy-image
mount_volume c-old-s volS
printf 'stoppedline\n' >"$DOCKER_WORLD/volumes/volS/access.log"
printf 'unreadable\n' >"$DOCKER_WORLD/volumes/volS/access.log.export"
chmod 000 "$DOCKER_WORLD/volumes/volS/access.log.export"

run_job
chmod 644 "$DOCKER_WORLD/volumes/volS/access.log.export"
assert_eq "stopped unreadable stash: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "stopped unreadable stash: recorded as export-failed, not stopped/ok" status_has "volume.volS=export-failed:projs"
assert_true "stopped unreadable stash: overall result is partial, not ok" status_has "result=partial"
assert_true "stopped unreadable stash: the unreadable stash file is left in place" test -e "$DOCKER_WORLD/volumes/volS/access.log.export"

echo "=== karakuri-proxy-log-export: no readable container ==="

new_sandbox
install_docker_bin_for_job
add_volume vol4 proj4
# コンテナは一つも mount していない。

run_job
assert_eq "no container: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "no container: status records it" status_has "volume.vol4=no-container:proj4"
assert_true "no container: overall result is partial" status_has "result=partial"

echo "=== karakuri-proxy-log-export: invalid and duplicate labels ==="

new_sandbox
install_docker_bin_for_job
add_volume bad1 ""
add_volume bad2 "Has_Caps"
add_volume dupA "same-name"
add_volume dupB "same-name"
add_volume good1 "good"
add_container c-good running fake-proxy-image
mount_volume c-good good1 /var/log/squid
printf 'ok1\n' >"$DOCKER_WORLD/volumes/good1/access.log"

run_job
assert_eq "invalid/duplicate: exits non-zero (partial)" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "invalid label: recorded (empty value)" status_has "volume.bad1=invalid-label:"
assert_true "invalid label: recorded (uppercase/underscore)" status_has "volume.bad2=invalid-label:Has_Caps"
assert_true "duplicate label: both volumes are recorded" status_has "volume.dupA=duplicate-label:same-name"
assert_true "duplicate label: both volumes are recorded (2)" status_has "volume.dupB=duplicate-label:same-name"
assert_true "invalid/duplicate: the unaffected volume still exports" status_has "volume.good1=running:good:1"
assert_true "invalid/duplicate: overall result is partial" status_has "result=partial"
assert_true "invalid label: named on stderr" bash -c "printf '%s' \"$STDERR\" | grep -q 'bad1'"
assert_true "invalid label: value named on stderr" bash -c "printf '%s' \"$STDERR\" | grep -q 'Has_Caps'"
assert_true "duplicate label: named on stderr" bash -c "printf '%s' \"$STDERR\" | grep -q 'dupA'"
assert_true "duplicate label: value named on stderr" bash -c "printf '%s' \"$STDERR\" | grep -q 'same-name'"

echo "=== karakuri-proxy-log-export: status file shape ==="

new_sandbox
install_docker_bin_for_job
run_job
assert_eq "status shape: exits 0 with nothing to do" "$RC" "0"
RUN_START="$(awk -F= '$1=="run_start"{print $2}' "$(status_file)")"
RUN_END="$(awk -F= '$1=="run_end"{print $2}' "$(status_file)")"
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
if [[ "$RUN_START" =~ $ISO_RE ]]; then ok "status shape: run_start looks like ISO 8601 UTC"; else ng "status shape: run_start looks like ISO 8601 UTC (got '$RUN_START')"; fi
if [[ "$RUN_END" =~ $ISO_RE ]]; then ok "status shape: run_end looks like ISO 8601 UTC"; else ng "status shape: run_end looks like ISO 8601 UTC (got '$RUN_END')"; fi
assert_true "status shape: result is ok" status_has "result=ok"

echo "=== karakuri-proxy-log-export: docker unreachable ==="

new_sandbox
install_docker_bin_for_job
: >"$DOCKER_WORLD/down"
run_job
assert_eq "docker unreachable: exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero"
assert_true "docker unreachable: status is failed" status_has "result=failed"
assert_true "docker unreachable: stderr mentions docker" bash -c "printf '%s' \"$STDERR\" | grep -qi docker"

echo "=== karakuri-proxy-log-export: retention ==="

new_sandbox
install_docker_bin_for_job
mkdir -p "$SBHOME/.local/state/karakuri/egress-log/proj5"
OLD_TS="$(_past_ts $((400 * 86400)))"
NEW_TS="$(_past_ts $((10 * 86400)))"
# 境界の両側、365日のすぐ外と内。365日と1時間前・364日と23時間前にして
# いるのは、比較が日数への切り捨て経由だと両方とも「365日」に丸まって
# 境界のずれ（365日と数時間を「365日以内」と誤判定する）を検出できない
# ため——秒単位の比較でなければこの2つは両方を正しく判定できない。
JUST_OVER_TS="$(_past_ts $((365 * 86400 + 3600)))"
JUST_UNDER_TS="$(_past_ts $((364 * 86400 + 23 * 3600)))"
printf 'old\n' | gzip -c >"$SBHOME/.local/state/karakuri/egress-log/proj5/access-${OLD_TS}.log.gz"
printf 'new\n' | gzip -c >"$SBHOME/.local/state/karakuri/egress-log/proj5/access-${NEW_TS}.log.gz"
printf 'justover\n' | gzip -c >"$SBHOME/.local/state/karakuri/egress-log/proj5/access-${JUST_OVER_TS}.log.gz"
printf 'justunder\n' | gzip -c >"$SBHOME/.local/state/karakuri/egress-log/proj5/access-${JUST_UNDER_TS}.log.gz"

run_job
assert_eq "retention: exits 0" "$RC" "0"
assert_false "retention: the file older than 365 days is pruned" test -e "$SBHOME/.local/state/karakuri/egress-log/proj5/access-${OLD_TS}.log.gz"
assert_true "retention: the newer file is kept" test -e "$SBHOME/.local/state/karakuri/egress-log/proj5/access-${NEW_TS}.log.gz"
assert_false "retention: 365 days and 1 hour old is pruned (just past the boundary)" test -e "$SBHOME/.local/state/karakuri/egress-log/proj5/access-${JUST_OVER_TS}.log.gz"
assert_true "retention: 364 days and 23 hours old is kept (just inside the boundary)" test -e "$SBHOME/.local/state/karakuri/egress-log/proj5/access-${JUST_UNDER_TS}.log.gz"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
