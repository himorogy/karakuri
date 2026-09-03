#!/usr/bin/env bash
#
# 固定値の追従漏れを判定する。.github/workflows/monitor.yml から呼ばれる。
#
# 上流の最新値・advisory の照会結果・node の schedule.json は、いずれも
# 呼び出し側がネットワーク越しに取得し、この引数として渡す。ここでは取得を
# 行わない。ネットワークに依存する処理を判定から追い出すことで、判定そのもの
# を docker もネットワークも無い場所でテストできる形にしている。
#
# サブコマンドは4つ。
#   lag           <pinned> <latest>              -> 遅れの大きさと種別
#   advisory      <yes|no> <query_rc> <json>      -> advisory 照会の結果
#   node-schedule <schedule_json> <version> [today] -> maintenance/EOL までの日数
#   severity      <lag> <advisory>                -> alert / info（2値のみ）
set -eu

usage() {
	cat >&2 <<'EOF'
usage:
  pin-lag.sh lag <pinned> <latest>
  pin-lag.sh advisory <yes|no> <query_rc> <json>
  pin-lag.sh node-schedule <schedule_json> <version> [today]
  pin-lag.sh severity <lag> <advisory>
EOF
	exit 64
}

# v0.19.1 と 0.19.1 を同一視するための前置き剥がし。
strip_v() {
	printf '%s' "${1#v}"
}

cmd_lag() {
	local pinned="${1-}" latest="${2-}"

	if [ -z "$pinned" ]; then
		printf 'pinned-unreadable\n'
		return 1
	fi
	if [ -z "$latest" ]; then
		printf 'latest-unavailable\n'
		return 1
	fi

	local p l
	p="$(strip_v "$pinned")"
	l="$(strip_v "$latest")"

	if [ "$p" = "$l" ]; then
		printf 'none\n'
		return 0
	fi

	local IFS=.
	local -a pa la
	read -r -a pa <<<"$p"
	read -r -a la <<<"$l"

	local labels=(major minor patch)
	local i pv lv
	i=0
	while [ "$i" -lt 3 ]; do
		pv="${pa[$i]:-0}"
		lv="${la[$i]:-0}"
		case "$pv" in '' | *[!0-9]*) pv=0 ;; esac
		case "$lv" in '' | *[!0-9]*) lv=0 ;; esac
		if [ "$pv" -ne "$lv" ]; then
			printf '%s %s\n' "${labels[$i]}" "$((lv - pv))"
			return 0
		fi
		i=$((i + 1))
	done

	# major.minor.patch の3桁は一致するが文字列としては異なる版
	# （プレリリース識別子違い等）。patch 0 に丸めると「差があるのに 0 版
	# 遅れ」と読める文面になるため、種別を決められないことを示す別の語で返す。
	printf 'differs 0\n'
	return 0
}

cmd_advisory() {
	local applicable="${1-}" rc="${2-}" json="${3-}"

	if [ "$applicable" != yes ]; then
		printf 'not-checked\n'
		return 0
	fi

	case "$rc" in
		'' | *[!0-9]*)
			printf 'check-failed\n'
			return 1
			;;
	esac
	if [ "$rc" -ne 0 ]; then
		printf 'check-failed\n'
		return 1
	fi

	if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
		printf 'check-failed\n'
		return 1
	fi

	local count
	count="$(printf '%s' "$json" | jq 'length')"
	if [ "$count" -eq 0 ]; then
		printf 'checked-none\n'
		return 0
	fi
	printf 'checked-alert\n'
	return 0
}

cmd_node_schedule() {
	local schedule_json="${1-}" version="${2-}" today="${3-}"

	[ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

	local key="$version"
	case "$key" in v*) : ;; *) key="v${key}" ;; esac

	if [ -z "$schedule_json" ]; then
		printf 'schedule-unavailable\n'
		return 1
	fi

	local entry
	entry="$(printf '%s' "$schedule_json" | jq -c --arg k "$key" '.[$k] // empty' 2>/dev/null)" || entry=""
	if [ -z "$entry" ] || [ "$entry" = null ]; then
		printf 'schedule-unavailable\n'
		return 1
	fi

	local maintenance eol
	maintenance="$(printf '%s' "$entry" | jq -r '.maintenance // empty')"
	eol="$(printf '%s' "$entry" | jq -r '.end // empty')"
	if [ -z "$maintenance" ] || [ -z "$eol" ]; then
		printf 'schedule-unavailable\n'
		return 1
	fi

	local today_epoch maint_epoch eol_epoch
	today_epoch="$(date -u -d "$today" +%s)"
	maint_epoch="$(date -u -d "$maintenance" +%s)"
	eol_epoch="$(date -u -d "$eol" +%s)"

	printf '%s %s\n' "$(((maint_epoch - today_epoch) / 86400))" "$(((eol_epoch - today_epoch) / 86400))"
	return 0
}

# 深刻度は alert / info の2値のみ。lag（第1引数）は受け取るが判定には使わない
# — 遅れの大きさや種別だけでは深刻度を上げないという非対称を、severity が
# advisory 以外を一切見ない実装で担保している。
cmd_severity() {
	local advisory="${2-}"

	case "$advisory" in
		checked-alert)
			printf 'alert\n'
			;;
		*)
			printf 'info\n'
			;;
	esac
}

main() {
	[ $# -ge 1 ] || usage
	local sub="$1"
	shift
	case "$sub" in
		lag) cmd_lag "$@" ;;
		advisory) cmd_advisory "$@" ;;
		node-schedule) cmd_node_schedule "$@" ;;
		severity) cmd_severity "$@" ;;
		*) usage ;;
	esac
}

main "$@"
