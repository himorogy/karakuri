#!/usr/bin/env bash
#
# Rule application tests for init-project-firewall.sh.
#
# The script is run end to end against recording stubs for iptables, ipset, dig
# and friends, so the generated filter tables and the command sequence can be
# asserted without root and without touching the host's netfilter state. What
# this covers is exactly what the config validator tests cannot: rule ordering,
# policy handling, the atomic swap, audit mode and repeated runs.
#
# SC2016: stub bodies are single quoted on purpose - they must reach the stub
# file unexpanded and only run when the script under test invokes them.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FIREWALL_SH="$SCRIPT_DIR/init-project-firewall.sh"

PASS=0
FAIL=0
SKIP=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

ng() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
}

# Skipped cases are counted and reported. A case that quietly disappears reads
# as coverage that is not there - the same failure mode this suite has had
# before (see docs/verification-record.md section 5).
skip() { # <label> <reason>
	SKIP=$((SKIP + 1))
	printf '  SKIP %s (%s)\n' "$1" "$2"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"

# --- stubs -------------------------------------------------------------------
#
# Every stub appends its argv to $FW_LOG. State that has to survive across
# invocations (which ipsets exist) lives in $FW_STATE.

make_stub() { # <name> <body>
	local name="$1" body="$2"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'printf "%s\n" "$(basename "$0") $*" >>"$FW_LOG"'
		printf '%s\n' "$body"
	} >"$BIN/$name"
	chmod +x "$BIN/$name"
}

make_stub id 'if [ "${1:-}" = "-u" ]; then echo 0; fi; exit 0'

make_stub ip '
case "$*" in
	*"route show default"*)
		[ -n "${FW_NO_GATEWAY:-}" ] || echo "default via 172.17.0.1 dev eth0"
		;;
	*"-6 addr show"*) : ;;
esac
exit 0'

make_stub iptables 'exit 0'

# A strict `aggregate`. The Debian build silently discards address families it
# does not understand, so the host's copy would hide an IPv6 prefix reaching it;
# this one refuses the input instead, which is the behaviour the jq filter in
# add_github_meta_ranges has to make impossible to trigger.
#
# Each input line is logged as `aggregate< <line>`. aggregate is an external
# command on the far side of the validation boundary, so "what reached it" is
# assertable in its own right and not only inferable from what came back.
make_stub aggregate '
buf=""
while IFS= read -r line; do
	printf "aggregate< %s\n" "$line" >>"$FW_LOG"
	case "$line" in
		[0-9]*.*) buf="$buf$line
" ;;
		*) echo "aggregate: unsupported prefix: $line" >&2; exit 1 ;;
	esac
done
printf "%s" "$buf"
exit 0'

# Every IPv4 table is kept separately so the bootstrap, the final and the panic
# table can each be asserted: filter-v4.<tag>.1, .2, ... with filter-v4.<tag>
# holding the last one that was ACCEPTED.
#
# A rejected restore must not advance filter-v4.<tag>. netfilter applies a table
# atomically or not at all, so after a failure the previously accepted table is
# still the effective one. A stub that copied first and failed afterwards would
# report the refused table as if it were live, and every "falls back to X"
# assertion would pass without checking anything.
#
# The input is still read to completion (the writing end sees no SIGPIPE) and
# still kept as filter-v4.<tag>.<n>, because the assertions that inspect what
# the script generated need the refused table too.
make_stub iptables-restore '
run="$(cat "$FW_STATE/run")"
n=$(( $(cat "$FW_STATE/v4count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FW_STATE/v4count"
cat >"$FW_STATE/filter-v4.$run.$n"
case ",${FW_FAIL_RESTORE:-}," in *",$n,"*) exit 1 ;; esac
cp "$FW_STATE/filter-v4.$run.$n" "$FW_STATE/filter-v4.$run"
exit 0'

make_stub ip6tables 'exit 0'

make_stub ip6tables-restore '
cat >"$FW_STATE/filter-v6.$(cat "$FW_STATE/run")"
exit 0'

make_stub iptables-save '
echo "-A OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j DOCKER_OUTPUT"
exit 0'

make_stub ipset '
case "${1:-}" in
	create)
		name="$2"; [ "$name" = "-exist" ] && name="$3"
		touch "$FW_STATE/set.$name"
		;;
	destroy) rm -f "$FW_STATE/set.${2:-}" ;;
	swap)
		[ -f "$FW_STATE/set.$2" ] || exit 1
		[ -f "$FW_STATE/set.$3" ] || exit 1
		;;
	add)
		for a; do last="$a"; done
		echo "$last" >>"$FW_STATE/entries"
		;;
	list) echo "Number of entries: 7" ;;
	test)
		# Approximates real ipset membership: an exact hit, or the network
		# address of a CIDR that was added (self_verify tests a CIDR by its
		# network address).
		for a; do last="$a"; done
		[ -f "$FW_STATE/entries" ] || exit 1
		while IFS= read -r e; do
			[ "$e" = "$last" ] && exit 0
			[ "${e%%/*}" = "$last" ] && exit 0
		done <"$FW_STATE/entries"
		exit 1
		;;
esac
exit 0'

# Stubbed so the resolver fallback inside resolve_domain can never reach the
# real network and make these tests depend on the host's DNS.
#
# host.docker.internal is answered here rather than by `dig`, which is what
# happens on the default bridge: Docker Desktop writes it into /etc/hosts, so it
# resolves through NSS and not through the nameserver.
make_stub getent '
case "$*" in
	*host.docker.internal*)
		[ -n "${FW_NO_HOST_INTERNAL:-}" ] && exit 2
		if [ -n "${FW_HOST_INTERNAL_PUBLIC:-}" ]; then
			echo "8.8.8.8 STREAM host.docker.internal"
			exit 0
		fi
		echo "192.168.65.2 STREAM host.docker.internal"
		exit 0
		;;
esac
exit 2'

# A healthy network: name resolution works, the meta API answers, and the
# unlisted host is unreachable. Reinstallable, because the failure scenarios
# below replace these stubs.
healthy_net_stubs() {
	# Answers for anything except a pinned external-DNS probe, which must look
	# like a blocked query.
	#
	# Several addresses on purpose: a single-line answer hides the SIGPIPE that a
	# `... | head -n1` consumer causes under `set -o pipefail`.
	make_stub dig '
name=""
for arg in "$@"; do
	case "$arg" in
		@*) exit 9 ;;
		+*|-*|A) ;;
		*) name="$arg" ;;
	esac
done
case "$name" in
	example.com) echo "198.51.100.1" ;;
	example.net) echo "198.51.100.2" ;;
	example.org) echo "198.51.100.3" ;;
	host.docker.internal) ;;
	private.example.com)
		# A zone that answers with addresses inside FORBIDDEN_CIDRS. Only the
		# public one may reach the allowlist.
		echo "169.254.169.254"; echo "192.168.1.5"; echo "203.0.113.55"
		;;
	allprivate.example.com) echo "169.254.169.254" ;;
	rotate.example.com)
		# A CDN behind DNS round robin: the answer set moves between the run
		# that builds the allowlist and the run that verifies it, keeping only
		# one address in common.
		n=$(( $(cat "$FW_STATE/rotate" 2>/dev/null || echo 0) + 1 ))
		echo "$n" >"$FW_STATE/rotate"
		if [ "$n" = "1" ]; then
			echo "203.0.113.20"; echo "203.0.113.21"; echo "203.0.113.22"
		else
			echo "203.0.113.90"; echo "203.0.113.91"; echo "203.0.113.22"
		fi
		;;
	*) echo "203.0.113.7"; echo "203.0.113.8"; echo "203.0.113.9" ;;
esac
exit 0'

	# The meta API answers with IPv6 prefixes too. They must never reach
	# `aggregate` or ipset.
	make_stub curl '
case "$*" in
	*api.github.com/meta*)
		echo "{\"web\":[\"140.82.112.0/20\",\"2606:50c0:8000::/40\"],\"api\":[\"192.30.252.0/22\"],\"git\":[\"143.55.64.0/20\"]}"
		exit 0
		;;
	*example.*) exit 7 ;;
esac
exit 0'
}

healthy_net_stubs

# --- driver ------------------------------------------------------------------

run_firewall() { # <run-tag> [config-json]
	local tag="$1" config="${2:-}"
	FW_STATE="$WORK/state"
	mkdir -p "$FW_STATE"
	printf '%s' "$tag" >"$FW_STATE/run"
	rm -f "$FW_STATE/v4count" "$FW_STATE/entries" "$FW_STATE/rotate"
	FW_LOG="$WORK/log.$tag"
	: >"$FW_LOG"

	local -a env_args=(
		"FW_LOG=$FW_LOG" "FW_STATE=$FW_STATE" "PATH=$BIN:$PATH"
		"FW_FAIL_RESTORE=${FW_FAIL_RESTORE:-}"
		"FW_NO_GATEWAY=${FW_NO_GATEWAY:-}"
		"FW_NO_HOST_INTERNAL=${FW_NO_HOST_INTERNAL:-}"
		"FW_HOST_INTERNAL_PUBLIC=${FW_HOST_INTERNAL_PUBLIC:-}"
	)
	local -a opts=("--resolv-conf" "${FW_RESOLV_CONF:-$WORK/resolv.conf}")
	if [ -n "$config" ]; then
		printf '%s' "$config" >"$WORK/firewall.json"
		opts+=("--config" "$WORK/firewall.json")
	fi
	env "${env_args[@]}" bash "$FIREWALL_SH" "${opts[@]}" >"$WORK/out.$tag" 2>&1
	printf '%s' "$?" >"$WORK/rc.$tag"
}

# The default bridge case: the container is handed the host's resolver rather
# than the Docker embedded one. This is what a devcontainer started without
# --network actually gets, so it is the default for these tests.
printf 'nameserver 192.168.65.7\n' >"$WORK/resolv.conf"
printf 'nameserver 127.0.0.11\n' >"$WORK/resolv.embedded.conf"
printf 'nameserver fd00::1\n' >"$WORK/resolv.v6only.conf"
: >"$WORK/resolv.empty.conf"

v4_table() { cat "$WORK/state/filter-v4.$1" 2>/dev/null; }
v4_table_n() { cat "$WORK/state/filter-v4.$1.$2" 2>/dev/null; }
v6_table() { cat "$WORK/state/filter-v6.$1" 2>/dev/null; }

# line_of <table-file-content> <pattern> -> 1-based line number, or empty
line_of() {
	printf '%s\n' "$1" | grep -n -- "$2" | head -n1 | cut -d: -f1
}

# The arity checks are not pedantry: an extra argument (a stray `--` meant for
# grep, say) silently shifts the pattern out of position and turns the assertion
# into one that passes on anything.
assert_contains() { # <label> <haystack> <pattern>
	[ "$#" -eq 3 ] || {
		ng "assert_contains got $# arguments, expected 3: ${1:-?}"
		return
	}
	if printf '%s\n' "$2" | grep -q -- "$3"; then
		ok "$1"
	else
		ng "$1 (missing: $3)"
	fi
}

assert_absent() { # <label> <haystack> <pattern>
	[ "$#" -eq 3 ] || {
		ng "assert_absent got $# arguments, expected 3: ${1:-?}"
		return
	}
	if printf '%s\n' "$2" | grep -q -- "$3"; then
		ng "$1 (unexpectedly present: $3)"
	else
		ok "$1"
	fi
}

# Structural check on a generated iptables-restore table.
#
# This is what catches a rule that got split across several lines - the failure
# mode that "$*" under IFS=$'\n\t' produces and that a grep for one expected
# substring will happily miss.
assert_well_formed_table() { # <label> <table>
	[ "$#" -eq 2 ] || {
		ng "assert_well_formed_table got $# arguments, expected 2: ${1:-?}"
		return
	}
	local label="$1" table="$2" line n=0 problems=""

	while IFS= read -r line; do
		n=$((n + 1))
		[ -n "$line" ] || continue
		case "$line" in
		'*'* | ':'* | 'COMMIT') continue ;;
		'-A '*)
			case "$line" in
			*' -j '*) ;;
			*) problems="$problems line $n has no target: '$line';" ;;
			esac
			;;
		*) problems="$problems line $n is not a table directive or rule: '$line';" ;;
		esac
	done < <(printf '%s\n' "$table")

	if [ "$n" -eq 0 ]; then
		ng "$label (table is empty)"
	elif [ -n "$problems" ]; then
		ng "$label ($problems)"
	else
		ok "$label"
	fi
}

assert_before() { # <label> <haystack> <first> <second>
	[ "$#" -eq 4 ] || {
		ng "assert_before got $# arguments, expected 4: ${1:-?}"
		return
	}
	local a b
	a="$(line_of "$2" "$3")"
	b="$(line_of "$2" "$4")"
	if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
		ok "$1"
	else
		ng "$1 (first=${a:-none} second=${b:-none})"
	fi
}

# --- enforce mode ------------------------------------------------------------

echo "enforce mode"
# The bundles are named because nothing is selected unless a configuration says
# so. This run is the one that asserts the whole table, the GitHub meta path and
# the ordering of the rebuild, so it wants a policy with something in it.
run_firewall enforce '{"version":1,"profile":["anthropic","npm","github"],"allowDomains":["registry.example.com"],"allowCidrs":["203.0.113.0/24"],"allowHostPorts":[5432]}'

RC="$(cat "$WORK/rc.enforce")"
if [ "$RC" = "0" ]; then
	ok "exits 0"
else
	ng "exits 0 (got $RC)"
	sed 's/^/    /' "$WORK/out.enforce" >&2
fi

LOG_ENFORCE="$WORK/log.enforce"
T4="$(v4_table enforce)"
assert_well_formed_table "every rule in the IPv4 table is a single well-formed line" "$T4"
assert_contains "INPUT policy is DROP" "$T4" '^:INPUT DROP'
assert_contains "FORWARD policy is DROP" "$T4" '^:FORWARD DROP'
assert_contains "OUTPUT policy is DROP" "$T4" '^:OUTPUT DROP'
assert_contains "loopback is accepted" "$T4" '^-A OUTPUT -o lo -j ACCEPT'
assert_contains "the assigned resolver is accepted on udp/53" "$T4" '-d 192.168.65.7/32 -p udp --dport 53 -j ACCEPT'
assert_contains "the assigned resolver is accepted on tcp/53" "$T4" '-d 192.168.65.7/32 -p tcp --dport 53 -j ACCEPT'
assert_absent "no resolver is hardcoded" "$T4" '127.0.0.11'
assert_contains "other udp/53 is dropped" "$T4" '-A OUTPUT -p udp --dport 53 -j DROP'
assert_contains "other tcp/53 is dropped" "$T4" '-A OUTPUT -p tcp --dport 53 -j DROP'
assert_before "DNS pinning precedes the OUTPUT ESTABLISHED accept" "$T4" \
	'^-A OUTPUT -p udp --dport 53 -j DROP' \
	'^-A OUTPUT -m conntrack --ctstate ESTABLISHED'
assert_before "the allowlist accept precedes the final REJECT" "$T4" \
	'match-set egress-allow-v4 dst -j ACCEPT' \
	'^-A OUTPUT -j REJECT'
assert_contains "unmatched egress is rejected" "$T4" '^-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited'
assert_contains "blocked destinations are recorded" "$T4" \
	'^-A OUTPUT -j SET --add-set egress-audit-v4 dst --exist'
assert_before "the allowlist accept precedes the recorder" "$T4" \
	'match-set egress-allow-v4 dst -j ACCEPT' \
	'^-A OUTPUT -j SET --add-set egress-audit-v4'
assert_before "the recorder precedes the REJECT" "$T4" \
	'^-A OUTPUT -j SET --add-set egress-audit-v4' \
	'^-A OUTPUT -j REJECT'
assert_contains "the audit set is created but never destroyed" "$(cat "$LOG_ENFORCE")" \
	'^ipset create -exist egress-audit-v4 hash:ip family inet timeout 604800'
assert_absent "the audit set survives across runs" "$(cat "$LOG_ENFORCE")" \
	'^ipset destroy egress-audit-v4$'
assert_contains "drops are logged" "$T4" 'fw-drop: '
# A LOG rule with no match would log every packet on the chain and spend the
# rate limit on ordinary traffic instead of on the drops it exists to record.
assert_contains "the DNS drop log is scoped to udp/53" "$T4" \
	'-A OUTPUT -p udp --dport 53 -m limit .* --log-prefix "fw-dns-drop: "'
assert_contains "the DNS drop log is scoped to tcp/53" "$T4" \
	'-A OUTPUT -p tcp --dport 53 -m limit .* --log-prefix "fw-dns-drop: "'
assert_contains "the sshd port is reachable" "$T4" '-A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT'
assert_contains "the configured host port is allowed" "$T4" '-A OUTPUT -d 172.17.0.1/32 -p tcp --dport 5432 -j ACCEPT'
# Docker Desktop answers on an address that is not the default gateway, so the
# gateway alone would leave a host-local database unreachable.
assert_contains "host.docker.internal is allowed on the same port" "$T4" \
	'-A OUTPUT -d 192.168.65.2/32 -p tcp --dport 5432 -j ACCEPT'
assert_absent "the host network is not allowed wholesale" "$T4" '172.17.0.0/24'

# The DNS DROPs sit in front of the allowlist, so an attempt to reach an
# external nameserver never reaches the recorder at the bottom of the chain.
# Without a recorder of its own, the clearest tunnelling signal there is would
# leave no trace anywhere a container can read.
assert_contains "external DNS attempts are recorded (udp)" "$T4" \
	'^-A OUTPUT -p udp --dport 53 -j SET --add-set egress-audit-v4 dst --exist'
assert_contains "external DNS attempts are recorded (tcp)" "$T4" \
	'^-A OUTPUT -p tcp --dport 53 -j SET --add-set egress-audit-v4 dst --exist'
assert_before "the resolver accept precedes the DNS recorder" "$T4" \
	'-d 192.168.65.7/32 -p udp --dport 53 -j ACCEPT' \
	'^-A OUTPUT -p udp --dport 53 -j SET'
assert_before "the DNS recorder precedes the DNS drop" "$T4" \
	'^-A OUTPUT -p udp --dport 53 -j SET' \
	'^-A OUTPUT -p udp --dport 53 -j DROP'

T6="$(v6_table enforce)"
assert_well_formed_table "every rule in the IPv6 table is a single well-formed line" "$T6"
assert_contains "IPv6 OUTPUT policy is DROP" "$T6" '^:OUTPUT DROP'
assert_contains "IPv6 INPUT policy is DROP" "$T6" '^:INPUT DROP'
assert_contains "IPv6 drops are logged" "$T6" 'fw-drop6: '
assert_absent "IPv6 has no allowlist accept" "$T6" 'match-set'
# Not left to the DROP policy. A silent drop makes an allowed host that also has
# a AAAA record reachable only after a timeout, and how long that takes depends
# on whether the client implements Happy Eyeballs. IPv4 refuses unlisted
# destinations explicitly; IPv6 has to do the same.
assert_contains "IPv6 egress is refused, not silently dropped" "$T6" \
	'^-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited'
assert_before "the IPv6 log precedes the reject" "$T6" \
	'fw-drop6: ' \
	'^-A OUTPUT -j REJECT'

echo "close before build"
# The bootstrap table is the first thing installed; nothing may touch the
# network before it is in place.
TB="$(v4_table_n enforce 1)"
assert_well_formed_table "every rule in the bootstrap table is a single well-formed line" "$TB"
assert_contains "the bootstrap table drops OUTPUT" "$TB" '^:OUTPUT DROP'
assert_contains "the bootstrap table drops INPUT" "$TB" '^:INPUT DROP'
assert_contains "the bootstrap table pins DNS" "$TB" '-A OUTPUT -p udp --dport 53 -j DROP'
assert_contains "the bootstrap table allows the assigned resolver" "$TB" \
	'-d 192.168.65.7/32 -p udp --dport 53 -j ACCEPT'
assert_absent "the bootstrap table has no allowlist" "$TB" 'match-set'
assert_absent "the bootstrap table does not open the host gateway" "$TB" '172.17.0.1'
# The SET target depends on an optional kernel module. The final table has a
# fallback for a rejected transaction; a rejected bootstrap is fatal, so it must
# not carry the rule at all.
assert_absent "the bootstrap table has no recorder" "$TB" 'SET --add-set'

LOG="$WORK/log.enforce"
assert_contains "the staging set is built, not the live one" "$(cat "$LOG")" \
	'^ipset add -exist egress-allow-v4-stg'
assert_contains "the allowlist is swapped in atomically" "$(cat "$LOG")" \
	'^ipset swap egress-allow-v4-stg egress-allow-v4$'
assert_contains "the configured CIDR reaches the set" "$(cat "$LOG")" \
	'^ipset add -exist egress-allow-v4-stg 203.0.113.0/24$'
assert_absent "no per-rule iptables mutation is used" "$(cat "$LOG")" '^iptables -[AFPX]'
assert_before "IPv6 is closed before anything else is applied" "$(cat "$LOG")" \
	'^ip6tables-restore' \
	'^iptables-restore'
assert_before "IPv4 is closed before the first name resolution" "$(cat "$LOG")" \
	'^iptables-restore' \
	'^dig '
assert_before "IPv4 is closed before the first outbound fetch" "$(cat "$LOG")" \
	'^iptables-restore' \
	'^curl '
assert_before "the allowlist is complete before the swap" "$(cat "$LOG")" \
	'^ipset add -exist egress-allow-v4-stg 203.0.113.0/24$' \
	'^ipset swap'
assert_before "the bootstrap table is installed before the swap" "$(cat "$LOG")" \
	'^iptables-restore' \
	'^ipset swap'
assert_contains "the second table is the one carrying the allowlist" \
	"$(v4_table_n enforce 2)" 'match-set egress-allow-v4 dst -j ACCEPT'
assert_contains "the GitHub meta ranges are added to the live set" "$(cat "$LOG")" \
	'^ipset add -exist egress-allow-v4 140.82.112.0/20$'
# `select(test("^[0-9]"))` would let these through to `aggregate`, whose
# behaviour on IPv6 input depends on which build is installed.
assert_absent "IPv6 meta prefixes never reach the set" "$(cat "$LOG")" '2606:'
assert_before "the meta API is only fetched after the final table is live" "$(cat "$LOG")" \
	'^ipset swap' \
	'^curl .*api.github.com/meta'
assert_contains "a valid meta range does reach aggregate" "$(cat "$LOG")" \
	'^aggregate< 140\.82\.112\.0/20$'

# --- the meta API is outside the validation boundary -------------------------
#
# The response arrives over TLS from GitHub, so the agent cannot write it, and
# the set is additive - the worst case is fewer ranges, not wider ones. What is
# still required is that the boundary hold: the jq filter selects an address
# family, it does not decide what is a CIDR, so the check has to happen before
# anything external is handed the value.

echo "meta ranges are checked before aggregate is handed them"
make_stub curl '
case "$*" in
	*api.github.com/meta*)
		echo "{\"web\":[\"140.82.112.0/20\",\"10.0.0.0/8\"],\"api\":[\"999999999999999999999999.1.1.1/32\"],\"git\":[\"143.55.64.0/20\"]}"
		exit 0
		;;
	*example.*) exit 7 ;;
esac
exit 0'
run_firewall metabounds '{"version":1,"profile":["github"]}'
healthy_net_stubs
META_LOG="$(cat "$WORK/log.metabounds")"

if [ "$(cat "$WORK/rc.metabounds")" = "0" ]; then
	ok "an unusable meta entry does not fail the run"
else
	ng "an unusable meta entry does not fail the run (rc=$(cat "$WORK/rc.metabounds"))"
	sed 's/^/    /' "$WORK/out.metabounds" >&2
fi
assert_absent "a private meta range never reaches aggregate" "$META_LOG" \
	'^aggregate< 10\.0\.0\.0/8$'
assert_absent "a malformed meta prefix never reaches aggregate" "$META_LOG" \
	'^aggregate< 999'
assert_contains "the usable ranges still reach aggregate" "$META_LOG" \
	'^aggregate< 140\.82\.112\.0/20$'
assert_absent "the private meta range is not allowed" "$META_LOG" \
	'^ipset add -exist egress-allow-v4 10\.0\.0\.0/8$'
assert_contains "the usable ranges are still allowed" "$META_LOG" \
	'^ipset add -exist egress-allow-v4 140\.82\.112\.0/20$'
# Two entries were dropped. A count that only says how many were allowed reads
# as "that was all of them", which is the one thing it must not mean here.
assert_contains "the dropped entries are reported" "$(cat "$WORK/out.metabounds")" \
	'2 GitHub meta entries did not pass CIDR validation'

echo "a meta response that cannot be read to the end says so"
# A shape the presence check accepts but the extraction cannot process: jq dies
# partway. Adding nothing is the correct outcome (the set is additive and the
# GitHub hosts are already in it from DNS), but reporting it as an ordinary run
# is not - as a process substitution the failure was invisible, and the run
# announced the ranges it happened to get as though that were the whole list.
make_stub curl '
case "$*" in
	*api.github.com/meta*)
		echo "{\"web\":{\"a\":1},\"api\":[\"140.82.112.0/20\"],\"git\":[]}"
		exit 0
		;;
	*example.*) exit 7 ;;
esac
exit 0'
run_firewall metatruncated '{"version":1,"profile":["github"]}'
healthy_net_stubs

if [ "$(cat "$WORK/rc.metatruncated")" = "0" ]; then
	ok "an unreadable meta response does not fail the run"
else
	ng "an unreadable meta response does not fail the run (rc=$(cat "$WORK/rc.metatruncated"))"
	sed 's/^/    /' "$WORK/out.metatruncated" >&2
fi
assert_contains "an unreadable meta response is reported" "$(cat "$WORK/out.metatruncated")" \
	'could not be read to the end'

# --- idempotency -------------------------------------------------------------

echo "idempotency"
run_firewall second '{"version":1,"profile":["anthropic","npm","github"],"allowDomains":["registry.example.com"],"allowCidrs":["203.0.113.0/24"],"allowHostPorts":[5432]}'
if [ "$(cat "$WORK/rc.second")" = "0" ]; then
	ok "a second consecutive run exits 0"
else
	ng "a second consecutive run exits 0 (got $(cat "$WORK/rc.second"))"
	sed 's/^/    /' "$WORK/out.second" >&2
fi
if [ "$(v4_table enforce)" = "$(v4_table second)" ]; then
	ok "the second run produces an identical IPv4 table"
else
	ng "the second run produces an identical IPv4 table"
fi
if [ "$(v6_table enforce)" = "$(v6_table second)" ]; then
	ok "the second run produces an identical IPv6 table"
else
	ng "the second run produces an identical IPv6 table"
fi

# --- audit mode --------------------------------------------------------------

echo "audit mode"
run_firewall audit '{"version":1,"mode":"audit"}'
if [ "$(cat "$WORK/rc.audit")" = "0" ]; then
	ok "audit mode exits 0"
else
	ng "audit mode exits 0 (got $(cat "$WORK/rc.audit"))"
	sed 's/^/    /' "$WORK/out.audit" >&2
fi
TA="$(v4_table audit)"
assert_well_formed_table "every rule in the audit table is a single well-formed line" "$TA"
assert_contains "audit leaves OUTPUT on ACCEPT" "$TA" '^:OUTPUT ACCEPT'
assert_contains "audit logs what would be dropped" "$TA" 'fw-audit: '
assert_absent "audit does not REJECT" "$TA" '^-A OUTPUT -j REJECT'
assert_contains "audit keeps INPUT on DROP" "$TA" '^:INPUT DROP'
assert_contains "audit still pins DNS" "$TA" '-A OUTPUT -p udp --dport 53 -j DROP'
assert_contains "audit still drops IPv6" "$(v6_table audit)" '^:OUTPUT DROP'
assert_contains "audit still refuses IPv6 egress" "$(v6_table audit)" \
	'^-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited'
assert_contains "audit records blocked destinations too" "$TA" \
	'^-A OUTPUT -j SET --add-set egress-audit-v4 dst --exist'

# --- failure path ------------------------------------------------------------

echo "panic on a failed self verification"
# The rules go in, but an unlisted host stays reachable: the environment is not
# what the policy assumes, so the run must not be reported as a success.
make_stub curl '
case "$*" in
	*api.github.com/meta*)
		echo "{\"web\":[\"140.82.112.0/20\"],\"api\":[\"192.30.252.0/22\"],\"git\":[\"143.55.64.0/20\"]}"
		;;
esac
exit 0'
run_firewall verifyfail '{"version":1}'
if [ "$(cat "$WORK/rc.verifyfail")" != "0" ]; then
	ok "a failed self verification exits non-zero"
else
	ng "a failed self verification exits non-zero"
fi
assert_contains "the unlisted host check is what failed" "$(cat "$WORK/out.verifyfail")" \
	'verify FAILED: unlisted host is blocked'
assert_contains "a failed self verification falls back to the panic table" \
	"$(v4_table verifyfail)" '^:OUTPUT DROP'

echo "recorder fallback"
healthy_net_stubs
# The SET target needs a kernel module that may be missing. When the table is
# rejected the run must drop the recorder and carry on, not fail.
FW_FAIL_RESTORE=2
run_firewall recorderfallback '{"version":1}'
unset FW_FAIL_RESTORE
if [ "$(cat "$WORK/rc.recorderfallback")" = "0" ]; then
	ok "a rejected recorder rule falls back instead of failing"
else
	ng "a rejected recorder rule falls back instead of failing (got $(cat "$WORK/rc.recorderfallback"))"
	sed 's/^/    /' "$WORK/out.recorderfallback" >&2
fi
assert_contains "the fallback is reported" "$(cat "$WORK/out.recorderfallback")" \
	'retrying without the blocked-destination recorder'
assert_contains "the rejected table did carry the recorder" \
	"$(v4_table_n recorderfallback 2)" '^-A OUTPUT -j SET --add-set egress-audit-v4'
assert_absent "the retried table has no recorder" \
	"$(v4_table_n recorderfallback 3)" 'SET --add-set'
assert_contains "the retried table is otherwise complete" \
	"$(v4_table_n recorderfallback 3)" '^-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited'

echo "panic on a rejected filter table"
# When even the table without the recorder is refused, the run must not leave
# the bootstrap table in place as if it had succeeded.
FW_FAIL_RESTORE=2,3
run_firewall restorefail '{"version":1}'
unset FW_FAIL_RESTORE
if [ "$(cat "$WORK/rc.restorefail")" != "0" ]; then
	ok "a rejected filter table exits non-zero"
else
	ng "a rejected filter table exits non-zero"
fi
assert_contains "the rejection is reported" "$(cat "$WORK/out.restorefail")" \
	'iptables-restore rejected the generated filter table'
assert_contains "a rejected filter table falls back to the panic table" \
	"$(v4_table restorefail)" '^-A OUTPUT -p tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT'
# The panic table is the fourth restore of the run (bootstrap, final with
# recorder, final without, panic). Naming the count keeps the case above honest:
# if the panic restore stopped being attempted, the assertion would still find
# an sshd rule in whatever table happened to be last.
if [ "$(cat "$WORK/state/v4count")" = "4" ]; then
	ok "the panic table is a restore of its own, not the last rejected one"
else
	ng "the panic table is a restore of its own (v4count=$(cat "$WORK/state/v4count"))"
fi

echo "a rejected panic table leaves the bootstrap table in place"
# The panic restore can be refused too - it is piped into iptables-restore with
# no check on the result. What matters for I2 is what remains: netfilter keeps
# the last table it accepted, which here is the bootstrap table, and that one is
# already closed except for DNS to the assigned resolver. The run must still
# exit non-zero.
#
# This case is why the iptables-restore stub records only accepted tables. With
# the copy done before the failure check, the refused panic table would show up
# as the effective one and this assertion would read the opposite of the truth.
FW_FAIL_RESTORE=2,3,4
run_firewall panicfail '{"version":1}'
unset FW_FAIL_RESTORE
if [ "$(cat "$WORK/rc.panicfail")" != "0" ]; then
	ok "a rejected panic table still exits non-zero"
else
	ng "a rejected panic table still exits non-zero"
fi
assert_contains "the effective table is still the bootstrap table" \
	"$(v4_table panicfail)" '^-A OUTPUT -p udp --dport 53 -j DROP'
assert_absent "the refused panic table did not take effect" \
	"$(v4_table panicfail)" 'sport 22'
# Closed is the point, not merely "not the panic table".
assert_contains "the bootstrap table still drops by default" \
	"$(v4_table panicfail)" '^:OUTPUT DROP'

echo "panic on a failed rebuild"
# No resolver at all: the allowlist cannot be built, and the run must end closed
# rather than leaving whatever policy happened to be in place.
#
# A bundle is named on purpose. The liveness check needs a domain to anchor on,
# and a configuration that asks for none has nothing to fail against - that case
# is covered separately, under "base profile bundles".
make_stub dig 'exit 9'
make_stub curl 'exit 7'
run_firewall panic '{"version":1,"profile":["anthropic"]}'
if [ "$(cat "$WORK/rc.panic")" != "0" ]; then
	ok "a rebuild failure exits non-zero"
else
	ng "a rebuild failure exits non-zero"
fi
assert_contains "the rebuild failure is reported" "$(cat "$WORK/out.panic")" \
	'the anchor domain did not resolve (api.anthropic.com)'
TP="$(v4_table panic)"
assert_well_formed_table "every rule in the panic table is a single well-formed line" "$TP"
assert_contains "the panic table drops OUTPUT" "$TP" '^:OUTPUT DROP'
assert_contains "the panic table drops INPUT" "$TP" '^:INPUT DROP'
assert_absent "the panic table keeps no outbound ESTABLISHED" "$TP" \
	'^-A OUTPUT -m conntrack'
assert_absent "the panic table has no allowlist" "$TP" 'match-set'
assert_contains "the panic table is applied to IPv6 too" "$(v6_table panic)" '^:OUTPUT DROP'
# Deliberately different from the final table: the panic tables drop silently on
# both families. Fast failure is worth an explicit refusal in normal operation,
# but the panic table is the state where the fewest assumptions should hold.
assert_absent "the IPv6 panic table has no reject rule" "$(v6_table panic)" 'REJECT'

# --- probe selection ----------------------------------------------------------

echo "self verification probes"
healthy_net_stubs
# Allowing the default egress probe host must not break verification: the check
# has to fall through to a probe that really is outside the allowlist.
run_firewall probeallowed '{"version":1,"profile":["anthropic"],"allowDomains":["example.com"]}'
if [ "$(cat "$WORK/rc.probeallowed")" = "0" ]; then
	ok "allowing the default egress probe still verifies"
else
	ng "allowing the default egress probe still verifies (got $(cat "$WORK/rc.probeallowed"))"
	sed 's/^/    /' "$WORK/out.probeallowed" >&2
fi
assert_contains "verification falls through to another probe host" \
	"$(cat "$WORK/out.probeallowed")" 'unlisted host is blocked (example.net)'
assert_absent "the allowed probe host is not used" \
	"$(cat "$WORK/out.probeallowed")" 'unlisted host is blocked (example.com)'

# --- DNS rotation --------------------------------------------------------------

echo "self verification under DNS rotation"
# A large CDN hands out a different subset of its addresses on every query. If
# verification compares one address picked at build time against one picked at
# verify time, a perfectly correct policy fails at random - and a failed
# verification takes the container down with it.
run_firewall rotation '{"version":1,"profile":["anthropic"],"allowDomains":["rotate.example.com"]}'
if [ "$(cat "$WORK/rc.rotation")" = "0" ]; then
	ok "a rotating answer set still verifies"
else
	ng "a rotating answer set still verifies (got $(cat "$WORK/rc.rotation"))"
	sed 's/^/    /' "$WORK/out.rotation" >&2
fi
assert_contains "the domain check passed on an overlapping address" \
	"$(cat "$WORK/out.rotation")" \
	'verify OK: firewall.json domain rotate.example.com is in the allowlist'

# --- host gateway --------------------------------------------------------------

echo "host gateway detection"
# No default route, but host.docker.internal resolves: allowHostPorts must still
# reach the host rather than abort the run.
FW_NO_GATEWAY=1
run_firewall nogw '{"version":1,"allowHostPorts":[5432]}'
unset FW_NO_GATEWAY
if [ "$(cat "$WORK/rc.nogw")" = "0" ]; then
	ok "a missing default route falls back to host.docker.internal"
else
	ng "a missing default route falls back to host.docker.internal (got $(cat "$WORK/rc.nogw"))"
	sed 's/^/    /' "$WORK/out.nogw" >&2
fi
assert_contains "the fallback opens the resolved host address" "$(v4_table nogw)" \
	'-A OUTPUT -d 192.168.65.2/32 -p tcp --dport 5432 -j ACCEPT'
assert_contains "the fallback is reported" "$(cat "$WORK/out.nogw")" \
	'falling back to host.docker.internal'

# Neither route nor name: allowHostPorts cannot be honoured, and silently
# dropping a requested allowance would be worse than failing.
FW_NO_GATEWAY=1
FW_NO_HOST_INTERNAL=1
run_firewall nohost '{"version":1,"allowHostPorts":[5432]}'
unset FW_NO_GATEWAY FW_NO_HOST_INTERNAL
if [ "$(cat "$WORK/rc.nohost")" != "0" ]; then
	ok "an unresolvable host exits non-zero"
else
	ng "an unresolvable host exits non-zero"
fi
assert_contains "the unresolvable host is reported" "$(cat "$WORK/out.nohost")" \
	'neither the default gateway nor host.docker.internal'

# --- forbidden addresses from DNS -----------------------------------------------

echo "forbidden addresses from DNS"
# allowCidrs is checked against FORBIDDEN_CIDRS, but a DNS answer was not. An
# allowed domain whose zone is attacker controlled could therefore answer
# 169.254.169.254 and put the cloud metadata service into the allowlist - and
# the agent picks the moment to re-apply, so it also picks the rebinding window.
run_firewall dnsprivate '{"version":1,"profile":["anthropic"],"allowDomains":["private.example.com"]}'
if [ "$(cat "$WORK/rc.dnsprivate")" = "0" ]; then
	ok "a domain with mixed public and private answers exits 0"
else
	ng "a domain with mixed public and private answers exits 0 (got $(cat "$WORK/rc.dnsprivate"))"
	sed 's/^/    /' "$WORK/out.dnsprivate" >&2
fi
assert_contains "the public address from that domain is allowed" \
	"$(cat "$WORK/log.dnsprivate")" '^ipset add -exist egress-allow-v4-stg 203.0.113.55$'
# Anchored on `ipset add`: the log also records the `ipset test` calls that self
# verification makes, and a bare grep for the address would match those instead.
assert_absent "the metadata service address is not allowed" \
	"$(cat "$WORK/log.dnsprivate")" '^ipset add .* 169\.254\.169\.254$'
assert_absent "the RFC1918 address is not allowed" \
	"$(cat "$WORK/log.dnsprivate")" '^ipset add .* 192\.168\.1\.5$'
assert_contains "the rejected addresses are reported" "$(cat "$WORK/out.dnsprivate")" \
	'which is in a forbidden range'

# A domain that resolves to nothing but forbidden addresses is the same case as
# one that does not resolve: warn and carry on, do not fail the run.
run_firewall dnsallprivate '{"version":1,"profile":["anthropic"],"allowDomains":["allprivate.example.com"]}'
if [ "$(cat "$WORK/rc.dnsallprivate")" = "0" ]; then
	ok "a domain with only private answers does not fail the run"
else
	ng "a domain with only private answers does not fail the run (got $(cat "$WORK/rc.dnsallprivate"))"
	sed 's/^/    /' "$WORK/out.dnsallprivate" >&2
fi
assert_contains "the all-forbidden domain is reported" "$(cat "$WORK/out.dnsallprivate")" \
	'resolved only to forbidden addresses'
assert_absent "nothing from the all-forbidden domain reaches the set" \
	"$(cat "$WORK/log.dnsallprivate")" '^ipset add .* 169\.254\.169\.254$'
# Self verification must not turn a warn-and-continue case into a panic: the
# domain has no allowlistable address, so there is nothing to check.
assert_contains "the all-forbidden domain is skipped by self verification" \
	"$(cat "$WORK/out.dnsallprivate")" 'verify SKIP: none of the 1 firewall.json domains resolved'

# --- host address sanity ---------------------------------------------------------

echo "host address sanity"
# host.docker.internal is the one name whose answer may be a private address, so
# it cannot go through the check above. It still must not open a port on an
# arbitrary internet host: a public answer means the name was intercepted.
FW_HOST_INTERNAL_PUBLIC=1
run_firewall hostpublic '{"version":1,"allowHostPorts":[5432]}'
unset FW_HOST_INTERNAL_PUBLIC
if [ "$(cat "$WORK/rc.hostpublic")" = "0" ]; then
	ok "a public host.docker.internal answer does not fail the run"
else
	ng "a public host.docker.internal answer does not fail the run (got $(cat "$WORK/rc.hostpublic"))"
	sed 's/^/    /' "$WORK/out.hostpublic" >&2
fi
assert_absent "no port is opened on the public address" "$(v4_table hostpublic)" \
	'8.8.8.8'
assert_contains "the gateway is still opened" "$(v4_table hostpublic)" \
	'-A OUTPUT -d 172.17.0.1/32 -p tcp --dport 5432 -j ACCEPT'
assert_contains "the refusal is reported" "$(cat "$WORK/out.hostpublic")" \
	'not a private address'

# --- panic on a preflight failure -------------------------------------------------

echo "panic on a preflight failure"
# The apply phase starts before the configuration is read. On a first boot the
# "previous" policy is ACCEPT everything, so exiting on a config error without
# applying anything would leave the container wide open.
run_firewall badconfig '{"version":1,"allowCidrs":["0.0.0.0/0"]}'
if [ "$(cat "$WORK/rc.badconfig")" != "0" ]; then
	ok "a rejected configuration exits non-zero"
else
	ng "a rejected configuration exits non-zero"
fi
assert_contains "the rejection is reported" "$(cat "$WORK/out.badconfig")" \
	'rejected allowCidrs entry'
assert_contains "a rejected configuration falls back to the panic table" \
	"$(v4_table badconfig)" '^:OUTPUT DROP'
assert_absent "the panic table after a config error has no allowlist" \
	"$(v4_table badconfig)" 'match-set'
assert_contains "IPv6 is closed too after a config error" \
	"$(v6_table badconfig)" '^:OUTPUT DROP'

# allowHostPorts that cannot be honoured is a failure inside the apply phase and
# must end closed rather than with the bootstrap table still live.
FW_NO_GATEWAY=1
FW_NO_HOST_INTERNAL=1
run_firewall nohostpanic '{"version":1,"allowHostPorts":[5432]}'
unset FW_NO_GATEWAY FW_NO_HOST_INTERNAL
assert_contains "an unresolvable host falls back to the panic table" \
	"$(v4_table nohostpanic)" '^-A OUTPUT -p tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT'
assert_absent "that panic table has no allowlist" \
	"$(v4_table nohostpanic)" 'match-set'

# --- configuration source -------------------------------------------------------

echo "configuration source"
# The adversary in this threat model is the agent inside the container, and it
# can re-apply the policy whenever it likes. A firewall.json under the workspace
# is therefore source, not policy: if the apply path read it, an injected agent
# could write {"mode":"audit"} and disable enforcement in two steps without ever
# obtaining root.
WS="$WORK/fakeworkspace"
mkdir -p "$WS/.devcontainer"
printf '%s' '{"version":1,"mode":"audit","allowDomains":["attacker.example"]}' \
	>"$WS/.devcontainer/firewall.json"

# These cases can only run where /etc/egress-guard/firewall.json is absent.
#
# The apply path takes the installed policy the moment it exists, and the path
# is fixed on purpose - there is no override to point it somewhere else for a
# test run. So on a machine that has egress-guard installed, the workspace copy
# is never reached no matter what the script does with the working directory,
# and every assertion below would pass without testing anything. That was
# confirmed by mutation: a build patched to search ./.devcontainer/firewall.json
# still passed all of them here.
#
# Rewriting the expectations to match the installed config does not help - it
# turns the block green while leaving it just as blind. Skipping is the honest
# option, and CI runs without the file, so the coverage is not lost there.
PROD_CONFIG="/etc/egress-guard/firewall.json"
prod_config_present=0
[ -r "$PROD_CONFIG" ] && prod_config_present=1
skip_installed() { # <label>
	skip "$1" "$PROD_CONFIG exists, so the workspace copy is unreachable either way"
}

# The repo copy is checked by naming it. There is no search: a script that went
# looking would have to assume a workspace layout, and every location it agreed
# to look in would be another place the agent could plant a policy.
rc=0
out="$(bash "$FIREWALL_SH" --check-config --config "$WS/.devcontainer/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "--check-config validates a named repo copy"
else
	ng "--check-config validates a named repo copy (rc=$rc)"
fi
assert_contains "--check-config says which file it read" "$out" \
	"reading $WS/.devcontainer/firewall.json"

# Run from inside the workspace with no --config at all: still nothing found,
# because there is no search to find it with.
rc=0
out="$(cd "$WS" && bash "$FIREWALL_SH" --check-config 2>&1)" || rc=$?
# The exit code belongs to the installed policy when there is one, and this case
# is about what is NOT read rather than about that file's contents.
if [ "$prod_config_present" -eq 1 ]; then
	skip_installed "--check-config without --config exits 0"
	skip_installed "--check-config does not search the working directory"
elif [ "$rc" -eq 0 ]; then
	ok "--check-config without --config exits 0"
	assert_contains "--check-config does not search the working directory" "$out" \
		'no firewall.json found'
else
	ng "--check-config without --config exits 0 (rc=$rc)"
fi

# With no configuration installed at all, the listing is the base profile and
# nothing else - the same treatment read_config gives an absent file. Which,
# since nothing is selected unless a configuration selects it, is empty.
rc=0
out="$(cd "$WS" && bash "$FIREWALL_SH" --print-allowlist 2>/dev/null)" || rc=$?
if [ "$prod_config_present" -eq 1 ]; then
	skip_installed "--print-allowlist without a configuration exits 0"
	skip_installed "--print-allowlist falls back to an empty base profile"
	skip_installed "--print-allowlist does not read the workspace copy"
elif [ "$rc" -eq 0 ]; then
	ok "--print-allowlist without a configuration exits 0"
	assert_contains "--print-allowlist falls back to an empty base profile" "$out" \
		'^profile: (none)$'
	assert_absent "--print-allowlist does not read the workspace copy" "$out" \
		'attacker\.example'
else
	ng "--print-allowlist without a configuration exits 0 (rc=$rc)"
fi

FW_STATE="$WORK/state"
mkdir -p "$FW_STATE"
printf '%s' srcsplit >"$FW_STATE/run"
rm -f "$FW_STATE/v4count" "$FW_STATE/entries" "$FW_STATE/rotate"
: >"$WORK/log.srcsplit"
rc=0
out="$(cd "$WS" && env "FW_LOG=$WORK/log.srcsplit" "FW_STATE=$FW_STATE" "PATH=$BIN:$PATH" \
	bash "$FIREWALL_SH" --resolv-conf "$WORK/resolv.conf" 2>&1)" || rc=$?
if [ "$prod_config_present" -eq 1 ]; then
	# Same reasoning as above: with a policy installed, this run applies THAT
	# policy, and whether it exits 0 says nothing about the workspace copy.
	skip_installed "applying from a workspace with a firewall.json exits 0"
elif [ "$rc" -eq 0 ]; then
	ok "applying from a workspace with a firewall.json exits 0"
else
	ng "applying from a workspace with a firewall.json exits 0 (rc=$rc)"
	printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
if [ "$prod_config_present" -eq 1 ]; then
	skip_installed "the apply path ignores the workspace copy"
	skip_installed "the workspace copy is never read while applying"
	skip_installed "the workspace copy cannot relax the policy"
	skip_installed "the workspace allowlist entry is never allowed"
else
	assert_contains "the apply path ignores the workspace copy" "$out" \
		'no firewall.json found'
	assert_absent "the workspace copy is never read while applying" "$out" \
		"reading $WS/.devcontainer/firewall.json"
	# The decisive check: mode=audit from the workspace file would have left
	# OUTPUT on ACCEPT.
	assert_contains "the workspace copy cannot relax the policy" "$(v4_table srcsplit)" \
		'^:OUTPUT DROP'
	assert_absent "the workspace allowlist entry is never allowed" "$out" \
		'allowed attacker.example'
fi

# --- resolver detection -------------------------------------------------------

echo "resolver detection"
healthy_net_stubs

# User defined network: the Docker embedded resolver is present and should be
# the one pinned.
FW_RESOLV_CONF="$WORK/resolv.embedded.conf"
run_firewall embedded '{"version":1}'
if [ "$(cat "$WORK/rc.embedded")" = "0" ]; then
	ok "the embedded resolver case exits 0"
else
	ng "the embedded resolver case exits 0 (got $(cat "$WORK/rc.embedded"))"
	sed 's/^/    /' "$WORK/out.embedded" >&2
fi
assert_contains "the embedded resolver is pinned" "$(v4_table embedded)" \
	'-d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT'
assert_absent "the embedded resolver case does not warn about the network" \
	"$(cat "$WORK/out.embedded")" 'not on a user defined Docker network'

# Default bridge: the host resolver is pinned and the weaker setup is called out.
FW_RESOLV_CONF="$WORK/resolv.conf"
assert_contains "the default bridge case warns about the network" \
	"$(cat "$WORK/out.enforce")" 'not on a user defined Docker network'

# No usable resolver: fail closed rather than leave DNS open.
FW_RESOLV_CONF="$WORK/resolv.v6only.conf"
run_firewall v6only '{"version":1}'
if [ "$(cat "$WORK/rc.v6only")" != "0" ]; then
	ok "an IPv6-only resolv.conf exits non-zero"
else
	ng "an IPv6-only resolv.conf exits non-zero"
fi
assert_contains "the IPv6-only case explains itself" "$(cat "$WORK/out.v6only")" \
	'only non-IPv4 nameservers'

FW_RESOLV_CONF="$WORK/resolv.empty.conf"
run_firewall noresolver '{"version":1}'
if [ "$(cat "$WORK/rc.noresolver")" != "0" ]; then
	ok "a resolv.conf with no nameserver exits non-zero"
else
	ng "a resolv.conf with no nameserver exits non-zero"
fi
assert_contains "the missing resolver case explains itself" \
	"$(cat "$WORK/out.noresolver")" 'no nameserver found'

# The apply phase now starts before the resolver check, so a missing resolver
# closes the container instead of leaving whatever policy was there. On a first
# boot that previous policy is ACCEPT everything.
assert_contains "a missing resolver falls back to the panic table" \
	"$(v4_table noresolver)" '^:OUTPUT DROP'
assert_absent "the panic table after a resolver failure has no allowlist" \
	"$(v4_table noresolver)" 'match-set'

FW_RESOLV_CONF="$WORK/resolv.conf"

# --- argument handling under sudo --------------------------------------------

echo "options under sudo"
# A sudoers Cmnd written without an argument list permits any arguments, so the
# script has to refuse the development options itself rather than trust it.
for opt in "--config /tmp/attacker.json" "--check-config"; do
	rc=0
	# shellcheck disable=SC2086 # the option string is split on purpose
	out="$(SUDO_USER=node SUDO_UID=1000 bash "$FIREWALL_SH" $opt 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not accepted through sudo"; then
		ok "'$opt' is refused when invoked through sudo"
	else
		ng "'$opt' is refused when invoked through sudo (rc=$rc)"
	fi
done

# --- script placement ----------------------------------------------------------

echo "script placement under sudo"
# The sudoers entry names a fixed path. If that entry pointed into node_modules,
# the unprivileged user could rewrite the script and have it run as root. The
# check replaces a manual `ls -l` after every rebuild, so it has to fire on the
# real production path: sudo, no arguments.
FW_STATE="$WORK/state"
mkdir -p "$FW_STATE"
printf '%s' placement >"$FW_STATE/run"
rm -f "$FW_STATE/v4count" "$FW_STATE/entries" "$FW_STATE/rotate"
: >"$WORK/log.placement"
rc=0
out="$(env "FW_LOG=$WORK/log.placement" "FW_STATE=$FW_STATE" "PATH=$BIN:$PATH" \
	SUDO_USER=node SUDO_UID=1000 bash "$FIREWALL_SH" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
	ok "a script the unprivileged user owns is refused under sudo"
else
	ng "a script the unprivileged user owns is refused under sudo (rc=$rc)"
fi
assert_contains "the refusal names the escalation path" "$out" \
	'privilege escalation path'

# Without sudo it is a development run from a checkout, which must keep working.
run_firewall placementdev '{"version":1}'
if [ "$(cat "$WORK/rc.placementdev")" = "0" ]; then
	ok "the same script runs fine when not invoked through sudo"
else
	ng "the same script runs fine when not invoked through sudo (got $(cat "$WORK/rc.placementdev"))"
	sed 's/^/    /' "$WORK/out.placementdev" >&2
fi

# --- base profile bundles -------------------------------------------------------
#
# `profile` selects named bundles, and selects nothing unless it says so. What
# used to be safe to assume - api.anthropic.com is always allowed, GitHub is
# always in the policy - is now derived from the configuration, and a
# configuration that says nothing gets nothing.

echo "base profile bundles"
healthy_net_stubs

# Every bundle at once. sentry.io and statsig.com are absent on purpose: they
# were never shown to be required and now belong to no bundle, so the largest
# base profile that can be asked for is these eleven domains.
ALL_BUNDLE_DOMAINS=(
	api.anthropic.com console.anthropic.com
	registry.npmjs.org
	marketplace.visualstudio.com vscode.blob.core.windows.net update.code.visualstudio.com
	github.com api.github.com codeload.github.com
	objects.githubusercontent.com raw.githubusercontent.com
)
run_firewall bundleall '{"version":1,"profile":["anthropic","npm","vscode","github"]}'
if [ "$(cat "$WORK/rc.bundleall")" = "0" ]; then
	ok "naming every bundle exits 0"
else
	ng "naming every bundle exits 0 (got $(cat "$WORK/rc.bundleall"))"
	sed 's/^/    /' "$WORK/out.bundleall" >&2
fi
missing=""
for d in "${ALL_BUNDLE_DOMAINS[@]}"; do
	grep -q " A $d\$" "$WORK/log.bundleall" || missing="$missing $d"
done
if [ -z "$missing" ]; then
	ok "every bundle domain is resolved when every bundle is named"
else
	ng "every bundle domain is resolved when every bundle is named (missing:$missing)"
fi
# The set is additive and DNS is the only thing standing between a bundle
# definition and the allowlist, so a domain that quietly came back would be
# allowed without anyone having asked for it.
for gone in sentry.io statsig.com; do
	assert_absent "$gone is resolved by no bundle" "$(cat "$WORK/log.bundleall")" " A $gone\$"
done

# The new default, and the case every new user meets first: a configuration that
# names no profile and no domain. It must not die - there is simply nothing to
# anchor the liveness check on, which is a policy, not a failure.
run_firewall bundleomitted '{"version":1}'
if [ "$(cat "$WORK/rc.bundleomitted")" = "0" ]; then
	ok "an omitted profile with no allowDomains exits 0"
else
	ng "an omitted profile with no allowDomains exits 0 (got $(cat "$WORK/rc.bundleomitted"))"
	sed 's/^/    /' "$WORK/out.bundleomitted" >&2
fi
assert_absent "an omitted profile resolves no base domain" \
	"$(cat "$WORK/log.bundleomitted")" ' A api\.anthropic\.com$'
assert_absent "an omitted profile does not reach the meta API" \
	"$(cat "$WORK/log.bundleomitted")" 'api\.github\.com/meta'
assert_contains "an omitted profile still installs a closed table" \
	"$(v4_table bundleomitted)" '^-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited'
assert_contains "an omitted profile still pins DNS" \
	"$(v4_table bundleomitted)" '^-A OUTPUT -p udp --dport 53 -j DROP'
assert_contains "the missing anchor is reported rather than fatal" \
	"$(cat "$WORK/out.bundleomitted")" 'DNS liveness could not be checked'

# "default" is gone. Every configuration written before this change says it, so
# the message has to explain what to write instead rather than read as a typo.
run_firewall bundledefault '{"version":1,"profile":"default"}'
if [ "$(cat "$WORK/rc.bundledefault")" != "0" ]; then
	ok '"default" is refused by the apply path too'
else
	ng '"default" is refused by the apply path too'
fi
assert_contains '"default" is refused with its own message' \
	"$(cat "$WORK/out.bundledefault")" 'no longer exists'
assert_contains '"default" is refused with a worked example' \
	"$(cat "$WORK/out.bundledefault")" 'anthropic.*npm.*github'
# A configuration error inside the apply phase closes the container. On a first
# boot the policy it would otherwise leave behind is ACCEPT everything.
assert_contains '"default" falls back to the panic table' \
	"$(v4_table bundledefault)" '^:OUTPUT DROP'

# A project that only needs the registry should not be carrying a model API and
# five GitHub hosts in its policy just to get it.
run_firewall bundlenpm '{"version":1,"profile":["npm"]}'
if [ "$(cat "$WORK/rc.bundlenpm")" = "0" ]; then
	ok "a single bundle profile exits 0"
else
	ng "a single bundle profile exits 0 (got $(cat "$WORK/rc.bundlenpm"))"
	sed 's/^/    /' "$WORK/out.bundlenpm" >&2
fi
assert_contains "the selected bundle is resolved" "$(cat "$WORK/log.bundlenpm")" \
	' A registry\.npmjs\.org$'
assert_absent "a bundle that was not selected is never resolved" \
	"$(cat "$WORK/log.bundlenpm")" ' A api\.anthropic\.com$'
assert_absent "the github bundle that was not selected is never resolved" \
	"$(cat "$WORK/log.bundlenpm")" ' A github\.com$'

# Skipping the meta fetch is not the same as failing it. A run that deliberately
# left GitHub out must not warn that the meta API is unreachable, or the warning
# stops meaning anything on the runs where it matters.
assert_absent "the meta API is not fetched without the github bundle" \
	"$(cat "$WORK/log.bundlenpm")" 'api\.github\.com/meta'
assert_absent "no meta failure is reported for a deliberate skip" \
	"$(cat "$WORK/out.bundlenpm")" 'GitHub meta API unavailable'
assert_contains "the meta API is still fetched when github is selected" \
	"$(cat "$WORK/log.bundleall")" 'api\.github\.com/meta'

# The liveness check and the reachability check anchor on the first domain the
# configuration actually asks for. Anchored on api.anthropic.com they would fail
# on every correct policy that leaves the anthropic bundle out.
assert_contains "self verification anchors on a domain of the selected bundle" \
	"$(cat "$WORK/out.bundlenpm")" 'allowed host is reachable (registry.npmjs.org)'
assert_absent "self verification does not reach for an unselected bundle's domain" \
	"$(cat "$WORK/out.bundlenpm")" 'api.anthropic.com'

# With no bundle at all the anchor falls back to the first configured domain.
run_firewall anchorcfg '{"version":1,"profile":[],"allowDomains":["registry.acme.test"]}'
if [ "$(cat "$WORK/rc.anchorcfg")" = "0" ]; then
	ok "an empty profile with a configured domain exits 0"
else
	ng "an empty profile with a configured domain exits 0 (got $(cat "$WORK/rc.anchorcfg"))"
	sed 's/^/    /' "$WORK/out.anchorcfg" >&2
fi
assert_contains "the anchor falls back to allowDomains" "$(cat "$WORK/out.anchorcfg")" \
	'allowed host is reachable (registry.acme.test)'
assert_absent "an empty profile resolves no base domain" \
	"$(cat "$WORK/log.anchorcfg")" ' A registry\.npmjs\.org$'

# Nothing to resolve at all is a legitimate policy (CIDRs and host ports only).
# There is then no way to tell a dead network from an empty allowlist, so the
# checks are skipped and said to be skipped - not failed, and not silently
# dropped either.
run_firewall anchornone '{"version":1,"profile":[],"allowCidrs":["203.0.113.0/24"]}'
if [ "$(cat "$WORK/rc.anchornone")" = "0" ]; then
	ok "a profile-less, domain-less policy exits 0"
else
	ng "a profile-less, domain-less policy exits 0 (got $(cat "$WORK/rc.anchornone"))"
	sed 's/^/    /' "$WORK/out.anchornone" >&2
fi
assert_contains "the missing anchor is reported when the allowlist is built" \
	"$(cat "$WORK/out.anchornone")" 'DNS liveness could not be checked'
assert_contains "self verification says it skipped the DNS check" \
	"$(cat "$WORK/out.anchornone")" 'verify SKIP: DNS resolution'
assert_contains "self verification says it skipped the reachability check" \
	"$(cat "$WORK/out.anchornone")" 'verify SKIP: allowed host reachability'
assert_contains "the configured CIDR is still allowed" "$(cat "$WORK/log.anchornone")" \
	'^ipset add -exist egress-allow-v4-stg 203\.0\.113\.0/24$'

# A dead network still fails closed, and the message names the domain that was
# actually tried rather than one the policy never asked for.
make_stub dig 'exit 9'
make_stub curl 'exit 7'
run_firewall anchordead '{"version":1,"profile":["npm"]}'
healthy_net_stubs
if [ "$(cat "$WORK/rc.anchordead")" != "0" ]; then
	ok "a dead network still fails a bundle-selected policy"
else
	ng "a dead network still fails a bundle-selected policy"
fi
assert_contains "the liveness failure names the anchor that was tried" \
	"$(cat "$WORK/out.anchordead")" \
	'the anchor domain did not resolve (registry.npmjs.org)'
assert_contains "a dead network falls back to the panic table" \
	"$(v4_table anchordead)" '^:OUTPUT DROP'

# --- --print-allowlist -----------------------------------------------------------

echo "--print-allowlist"
# The listing exists to be readable from inside a container whose egress is
# already closed, by a user who is not root. That only holds if it resolves
# nothing and fetches nothing - and the stub log is the only way to prove it
# rather than assert it.
FW_STATE="$WORK/state"
mkdir -p "$FW_STATE"
printf '%s' printonly >"$FW_STATE/run"
rm -f "$FW_STATE/v4count" "$FW_STATE/entries" "$FW_STATE/rotate"
: >"$WORK/log.printonly"
printf '%s' '{"version":1,"profile":["npm","github"],"allowDomains":["registry.example.com"]}' \
	>"$WORK/print.json"
rc=0
out="$(env "FW_LOG=$WORK/log.printonly" "FW_STATE=$FW_STATE" "PATH=$BIN:$PATH" \
	bash "$FIREWALL_SH" --print-allowlist --config "$WORK/print.json" 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "--print-allowlist exits 0"
else
	ng "--print-allowlist exits 0 (rc=$rc)"
fi
if [ ! -s "$WORK/log.printonly" ]; then
	ok "--print-allowlist invokes no external command that touches the network or netfilter"
else
	ng "--print-allowlist invokes no external command ($(tr '\n' ';' <"$WORK/log.printonly"))"
fi
assert_contains "the listing names the selected bundles" "$out" '^profile: npm, github$'
assert_contains "the listing merges the configured domain in" "$out" '^  registry\.example\.com$'
assert_contains "the listing warns that the meta ranges are not in it" "$out" \
	'GitHub meta API'

# --- result ------------------------------------------------------------------

if [ "$SKIP" -gt 0 ]; then
	printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
else
	printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
