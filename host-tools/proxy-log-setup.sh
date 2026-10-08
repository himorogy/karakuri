#!/usr/bin/env bash
#
# proxy-log-setup.sh — egress-proxy のアクセスログ書き出しジョブの
# install / uninstall / run（macOS）
#
# 作法は host-tools/loopback-setup.sh に揃える（配置前の突き合わせ、
# `launchctl bootout → bootstrap`、plist に KeepAlive を書かない）。
# 違うのは特権の要否だけである。ジョブが叩くのは利用者の docker socket
# なので root は要らず、LaunchDaemon ではなく LaunchAgent にし、sudo は
# 一切使わない（これはシェルオプションの話ではないので
# loopback-setup.sh の「シェルオプションについて」の注記はここには無い
# ——sudo を経由する操作が無いので set -e で素直に止めてよい）。

set -euo pipefail

HOME="${HOME:?proxy-log-setup.sh requires HOME to be set}"

LIBEXEC_DIR="${HOME}/.local/libexec/karakuri"
JOB_PATH="${LIBEXEC_DIR}/karakuri-proxy-log-export"
DOCKER_BIN_FILE="${LIBEXEC_DIR}/docker-bin"
INTERVAL_FILE="${LIBEXEC_DIR}/interval-hours"
DEFAULT_INTERVAL_HOURS=24

LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS_DIR}/com.karakuri.proxy-log-export.plist"
LOG_DIR="${HOME}/Library/Logs"
STDERR_LOG="${LOG_DIR}/com.karakuri.proxy-log-export.log"

PLIST_JOB_PLACEHOLDER="__KARAKURI_JOB_PATH__"
PLIST_LOG_PLACEHOLDER="__KARAKURI_STDERR_LOG__"

LAUNCHD_DOMAIN="gui/$(id -u)"
LAUNCHD_SERVICE="${LAUNCHD_DOMAIN}/com.karakuri.proxy-log-export"

# 配布物（proxy-log/ ディレクトリ）はこのスクリプトの隣にある前提。
# loopback-setup.sh の SELF_DIR / SRC_DIR と同じ考え方。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SELF_DIR}/proxy-log"

_err() {
	printf 'karakuri-proxy-log: %s\n' "$1" >&2
}

_die() {
	_err "$1"
	exit 1
}

# 対応 OS は macOS だけ。ジョブ本体が叩く docker Desktop の統合・launchd の
# LaunchAgent はどちらも macOS 固有であり、他 OS 向けの等価な仕組みは持たない
# （host-tools/loopback-setup.sh と同じ扱い）。
if [ "$(uname -s)" != "Darwin" ]; then
	printf 'karakuri-proxy-log: macOS only, doing nothing. No files were placed and no job was scheduled.\n' >&2
	exit 0
fi

usage() {
	cat >&2 <<'EOF'
Usage: karakuri-proxy-log <command>

  install [--interval <hours>]
               Install the LaunchAgent and the export job (run once, then after upgrades).
               <hours> is an integer from 1 to 168; the default is 24. Not carried over
               across reinstalls — pick it again on every upgrade.
  uninstall    Remove the LaunchAgent and the export job. The vault and status file are kept
  run          Run one export pass right now, in the foreground, ignoring the interval

This tool is macOS only. On any other OS it exits immediately without
touching anything.

No command here uses sudo: the job only talks to your own Docker socket.
EOF
	exit "${1:-1}"
}

# _check_plist_template <plist> — プレースホルダが両方とも入っているかを
# 確かめる。無ければ、そのファイルが期待する plist ではない（配布物が壊れて
# いる）ので、$HOME を埋め込めないまま配置してしまう前に止める。
_check_plist_template() {
	local src="$1"
	grep -q -- "$PLIST_JOB_PLACEHOLDER" "$src" ||
		_die "'${src}' is missing the ${PLIST_JOB_PLACEHOLDER} marker — that does not look like the com.karakuri.proxy-log-export plist. Refusing to install it"
	grep -q -- "$PLIST_LOG_PLACEHOLDER" "$src" ||
		_die "'${src}' is missing the ${PLIST_LOG_PLACEHOLDER} marker — that does not look like the com.karakuri.proxy-log-export plist. Refusing to install it"
}

cmd_install() {
	local interval_hours="$DEFAULT_INTERVAL_HOURS"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--interval)
			[ "$#" -ge 2 ] || _die "--interval requires a value"
			interval_hours="$2"
			shift 2
			;;
		*)
			usage 1
			;;
		esac
	done

	case "$interval_hours" in
	'' | *[!0-9]*)
		_die "--interval must be an integer between 1 and 168 (got '${interval_hours}') — nothing was placed"
		;;
	0[0-9]*)
		# 先頭0は、ここでの範囲検査（test -lt/-gt）もジョブ本体の算術展開も
		# 10進ではなく8進として読む。08・09 はそもそも無効な8進数として
		# 算術エラーになり、010 は黙って8として扱われる——どちらも拒否し、
		# 先頭0の綴り自体を無効とする。
		_die "--interval must not have a leading zero (got '${interval_hours}') — nothing was placed"
		;;
	esac
	if [ "$interval_hours" -lt 1 ] || [ "$interval_hours" -gt 168 ]; then
		_die "--interval must be an integer between 1 and 168 (got '${interval_hours}') — nothing was placed"
	fi

	# 特権は要らないが、docker の絶対パス解決と配布物の存在確認は実際に
	# 置く前に済ませる。loopback-setup.sh の「検証は先、変更は後」と同じ順序。
	local docker_path
	docker_path="$(command -v docker 2>/dev/null || true)"
	[ -n "$docker_path" ] ||
		_die "cannot find 'docker' on PATH. Install Docker Desktop (or otherwise put 'docker' on PATH) and run install again — nothing was placed. launchd does not inherit a login shell's PATH, so this path is resolved once here and reused by every scheduled run"

	local src_job="${SRC_DIR}/karakuri-proxy-log-export"
	local src_plist="${SRC_DIR}/com.karakuri.proxy-log-export.plist"
	[ -f "$src_job" ] ||
		_die "cannot find '${src_job}'. The 'proxy-log' directory is expected next to this script — copy the whole host-tools/ directory, not just this file"
	[ -f "$src_plist" ] ||
		_die "cannot find '${src_plist}'. The 'proxy-log' directory is expected next to this script — copy the whole host-tools/ directory, not just this file"
	_check_plist_template "$src_plist"

	install -d -m 0755 "$LIBEXEC_DIR"
	install -m 0755 "$src_job" "$JOB_PATH"
	printf 'job: installed %s\n' "$JOB_PATH"

	local docker_tmp
	docker_tmp="$(mktemp "${LIBEXEC_DIR}/.docker-bin.XXXXXX")"
	printf '%s' "$docker_path" >"$docker_tmp"
	mv "$docker_tmp" "$DOCKER_BIN_FILE"
	printf 'docker: resolved %s\n' "$docker_path"

	local interval_tmp
	interval_tmp="$(mktemp "${LIBEXEC_DIR}/.interval-hours.XXXXXX")"
	printf '%s' "$interval_hours" >"$interval_tmp"
	mv "$interval_tmp" "$INTERVAL_FILE"
	printf 'interval: %s hour(s)\n' "$interval_hours"

	install -d -m 0755 "$LOG_DIR"
	install -d -m 0755 "$LAUNCH_AGENTS_DIR"

	local plist_tmp
	plist_tmp="$(mktemp "${TMPDIR:-/tmp}/karakuri-proxy-log-plist.XXXXXX")"
	sed -e "s#${PLIST_JOB_PLACEHOLDER}#${JOB_PATH}#g" -e "s#${PLIST_LOG_PLACEHOLDER}#${STDERR_LOG}#g" \
		"$src_plist" >"$plist_tmp"
	install -m 0644 "$plist_tmp" "$PLIST_PATH"
	rm -f "$plist_tmp"
	printf 'launchd: installed %s\n' "$PLIST_PATH"

	# 入れ直しに備えて一度外してから入れる。失敗（まだ読み込まれていない）
	# は正常な経路なので握る。loopback-setup.sh の install と同じ理由。
	launchctl bootout "$LAUNCHD_DOMAIN" "$PLIST_PATH" 2>/dev/null || true

	if launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_PATH"; then
		printf 'launchd: bootstrapped com.karakuri.proxy-log-export\n'
		return 0
	fi

	_err "'launchctl bootstrap ${LAUNCHD_DOMAIN} ${PLIST_PATH}' failed. The most likely reason is that the job is already bootstrapped: 'bootout' can return before launchd has finished unloading it. Check with 'launchctl print ${LAUNCHD_SERVICE}'; if it is there, run 'launchctl bootout ${LAUNCHD_SERVICE}' and then 'proxy-log-setup.sh install' again. Everything else above was placed — only the schedule is not active"
	return 1
}

cmd_uninstall() {
	[ "$#" -eq 0 ] || usage 1

	launchctl bootout "$LAUNCHD_DOMAIN" "$PLIST_PATH" 2>/dev/null || true

	if [ -f "$PLIST_PATH" ]; then
		rm -f "$PLIST_PATH"
		printf 'launchd: removed %s\n' "$PLIST_PATH"
	else
		printf 'launchd: %s was not installed\n' "$PLIST_PATH"
	fi

	if [ -f "$JOB_PATH" ]; then
		rm -f "$JOB_PATH"
		printf 'job: removed %s\n' "$JOB_PATH"
	else
		printf 'job: %s was not installed\n' "$JOB_PATH"
	fi

	rm -f "$DOCKER_BIN_FILE"
	rm -f "$INTERVAL_FILE"

	printf 'the vault and status file are kept — remove them by hand under %s if you want the collected logs gone too\n' "${HOME}/.local/state/karakuri/egress-log"
	return 0
}

cmd_run() {
	[ "$#" -eq 0 ] || usage 1
	[ -x "$JOB_PATH" ] ||
		_die "no job is installed at '${JOB_PATH}'. Run 'proxy-log-setup.sh install' first"
	"$JOB_PATH"
}

[ "$#" -ge 1 ] || usage 1

cmd="$1"
shift

case "$cmd" in
install) cmd_install "$@" ;;
uninstall) cmd_uninstall "$@" ;;
run) cmd_run "$@" ;;
-h | --help | help) usage 0 ;;
*)
	_err "unknown command '${cmd}'"
	usage 1
	;;
esac
