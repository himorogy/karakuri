#!/usr/bin/env bash
#
# Validation tests for init-project-firewall.sh.
#
# Only the parts that run without root and without touching netfilter are
# covered here: the firewall.json schema gate and the string validators that
# stand between attacker controlled JSON and ipset/iptables. Rule application
# and self verification need a real devcontainer and are checked by running the
# script itself.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FIREWALL_SH="$SCRIPT_DIR/init-project-firewall.sh"

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

accepts() { # <validator> <value...>
	local fn="$1"
	shift
	local value
	for value in "$@"; do
		if "$fn" "$value"; then
			ok "$fn accepts '$value'"
		else
			ng "$fn rejected '$value' but should accept it"
		fi
	done
}

rejects() { # <validator> <value...>
	local fn="$1"
	shift
	local value
	for value in "$@"; do
		if "$fn" "$value"; then
			ng "$fn accepted '$value' but should reject it"
		else
			ok "$fn rejects '$value'"
		fi
	done
}

# --- unit level --------------------------------------------------------------

# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=init-project-firewall.sh
source "$FIREWALL_SH"
set +e

echo "validate_domain"
accepts validate_domain \
	"example.com" \
	"sub.example.com" \
	"api.anthropic.com" \
	"a-b.example.co.jp" \
	"ep-cool-name-123456.ap-southeast-1.aws.neon.tech"
# Wildcards are rejected in every form. DNS cannot enumerate the subdomains of a
# zone, so accepting one would mean accepting a policy that silently blocks the
# subdomains the author believed it allowed.
# SC2016: the single quotes are the point, these are literal injection payloads.
# shellcheck disable=SC2016
rejects validate_domain \
	"" \
	"*" \
	"*.*" \
	"*.com" \
	"*.co.*" \
	"example.*" \
	"*.neon.tech" \
	"*.sub.example.com" \
	"exa mple.com" \
	'example.com; id' \
	'$(id).com' \
	'`id`.com' \
	"example.com
evil.com" \
	"a..b.com" \
	"-example.com" \
	"example-.com" \
	"example" \
	"127.0.0.1"

echo "validate_cidr"
accepts validate_cidr \
	"203.0.113.0/24" \
	"203.0.113.5/32" \
	"8.8.8.0/24" \
	"140.82.112.0/20"
rejects validate_cidr \
	"" \
	"0.0.0.0/0" \
	"::/0" \
	"1.0.0.0/7" \
	"10.0.0.0/8" \
	"10.1.2.0/24" \
	"172.16.0.0/12" \
	"172.20.5.0/24" \
	"192.168.1.0/24" \
	"127.0.0.0/8" \
	"169.254.0.0/16" \
	"100.64.0.0/10" \
	"100.0.0.0/8" \
	"203.0.113.0" \
	"203.0.113.0/33" \
	"256.0.0.0/24" \
	"010.0.0.1/24" \
	'203.0.113.0/24 -j ACCEPT'

echo "validate_port"
accepts validate_port "1" "22" "5432" "65535"
rejects validate_port "" "0" "-1" "65536" "08" "22abc" "1 2"

echo "ranges_overlap"
if ranges_overlap "100.0.0.0" 8 "100.64.0.0" 10; then
	ok "ranges_overlap detects a supernet containing the CGNAT range"
else
	ng "ranges_overlap missed 100.0.0.0/8 vs 100.64.0.0/10"
fi
if ranges_overlap "203.0.113.0" 24 "10.0.0.0" 8; then
	ng "ranges_overlap reported an overlap between disjoint ranges"
else
	ok "ranges_overlap separates disjoint ranges"
fi

# --- ownership of the enforced configuration ---------------------------------
#
# The agent inside the container can re-apply the policy through sudoers, so a
# configuration it can write is not a configuration: it would only have to write
# {"mode":"audit"} and run sudo. The apply path therefore reads a root owned
# file, and checks that it really is one - bind mounting a workspace file over
# /etc/egress-guard/firewall.json is the realistic way to get this wrong.
#
# `die` exits, so each call runs in a subshell.

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

echo "assert_config_is_root_owned"

owned_ok() { # <label> <path>
	if (assert_config_is_root_owned "$2") >/dev/null 2>&1; then
		ok "$1"
	else
		ng "$1"
	fi
}

owned_ng() { # <label> <path> <expected message>
	local out rc=0
	out="$( (assert_config_is_root_owned "$2") 2>&1 )" || rc=$?
	if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "$3"; then
		ok "$1"
	else
		ng "$1 (rc=$rc, out=$out)"
	fi
}

printf '%s' '{"version":1}' >"$TMPDIR_TEST/user-owned.json"
owned_ng "a config owned by the unprivileged user is refused" \
	"$TMPDIR_TEST/user-owned.json" "must be owned by root"

# /etc/passwd stands in for a correctly placed config: root owned and 644.
if [ -f /etc/passwd ] && [ "$(stat -c %u /etc/passwd)" = "0" ]; then
	owned_ok "a root owned, non-writable config is accepted" /etc/passwd
else
	ng "no root owned file was available to test the accepting case"
fi

# root owned but mode 666: ownership alone is not enough.
if [ -c /dev/null ] && [ "$(stat -c %u /dev/null)" = "0" ] &&
	[ "$((0$(stat -c %a /dev/null) & 022))" -ne 0 ]; then
	owned_ng "a root owned but world writable config is refused" \
		/dev/null "must not be group or world writable"
else
	ng "no root owned world writable file was available to test the mode check"
fi

owned_ok "an absent config is not an error (base profile only)" ""

# A root owned symlink would pass every check below it: stat follows the link,
# so the checks would describe the target while the writable link decides which
# target that is.
ln -sf /etc/passwd "$TMPDIR_TEST/link.json"
owned_ng "a symlink is refused even when it points at a root owned file" \
	"$TMPDIR_TEST/link.json" "must not be a symlink"

# A directory the unprivileged user can write to lets it unlink the file and put
# its own in place, which no check on the file alone can catch.
mkdir -p "$TMPDIR_TEST/dir"
printf '%s' '{"version":1}' >"$TMPDIR_TEST/dir/firewall.json"
owned_ng "a config in a non-root owned directory is refused" \
	"$TMPDIR_TEST/dir/firewall.json" "must be owned by root"

# --- end to end schema gate --------------------------------------------------

check_config() { # <label> <expected: accept|reject> <json>
	local label="$1" expected="$2" json="$3"
	local file="$TMPDIR_TEST/firewall.json"
	printf '%s' "$json" >"$file"

	local out rc=0
	out="$(bash "$FIREWALL_SH" --check-config --config "$file" 2>&1)" || rc=$?

	if [ "$expected" = "accept" ]; then
		if [ "$rc" -eq 0 ]; then
			ok "config accepted: $label"
		else
			ng "config should be accepted: $label ($out)"
		fi
	else
		if [ "$rc" -ne 0 ]; then
			ok "config rejected: $label"
		else
			ng "config should be rejected: $label"
		fi
	fi
}

echo "--check-config"
check_config "minimal" accept '{"version":1}'
check_config "full" accept '{
	"version": 1,
	"profile": "default",
	"mode": "enforce",
	"allowDomains": ["ep-cool-name-123456.ap-southeast-1.aws.neon.tech", "registry.example.com"],
	"allowCidrs": ["203.0.113.0/24"],
	"allowHostPorts": [5432]
}'
check_config "audit mode" accept '{"version":1,"mode":"audit"}'
check_config "not JSON" reject 'not json at all'
check_config "not an object" reject '[1,2,3]'
check_config "missing version" reject '{"mode":"enforce"}'
check_config "unknown version" reject '{"version":2}'
check_config "string version" reject '{"version":"1"}'
check_config "unknown field" reject '{"version":1,"allowEverything":true}'
check_config "unknown profile" reject '{"version":1,"profile":"wide-open"}'
check_config "unknown mode" reject '{"version":1,"mode":"off"}'
check_config "bare wildcard domain" reject '{"version":1,"allowDomains":["*"]}'
check_config "TLD wildcard" reject '{"version":1,"allowDomains":["*.com"]}'
check_config "subdomain wildcard" reject '{"version":1,"allowDomains":["*.example.com"]}'
check_config "shell metacharacters" reject '{"version":1,"allowDomains":["a.com; id"]}'
check_config "default route CIDR" reject '{"version":1,"allowCidrs":["0.0.0.0/0"]}'
check_config "RFC1918 CIDR" reject '{"version":1,"allowCidrs":["192.168.0.0/16"]}'
check_config "tailscale CGNAT CIDR" reject '{"version":1,"allowCidrs":["100.64.0.0/10"]}'
check_config "short prefix CIDR" reject '{"version":1,"allowCidrs":["1.0.0.0/4"]}'
check_config "non-array allowDomains" reject '{"version":1,"allowDomains":"example.com"}'
check_config "non-string domain" reject '{"version":1,"allowDomains":[1]}'
check_config "out of range port" reject '{"version":1,"allowHostPorts":[70000]}'
check_config "non-integer port" reject '{"version":1,"allowHostPorts":[5432.5]}'
check_config "bad sshdPort" reject '{"version":1,"sshdPort":0}'

# "rejected allowDomains entry: *.example.com" on its own reads like a syntax
# complaint. The author needs to be told what to write instead.
printf '%s' '{"version":1,"allowDomains":["*.example.com"]}' >"$TMPDIR_TEST/firewall.json"
rc=0
out="$(bash "$FIREWALL_SH" --check-config --config "$TMPDIR_TEST/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "wildcards are not supported"; then
	ok "the wildcard rejection explains what to write instead"
else
	ng "the wildcard rejection explains what to write instead (rc=$rc, out=$out)"
fi

# --- shipped templates -------------------------------------------------------
#
# The templates are what users copy into .devcontainer/, so a template the
# validator rejects would break every project that starts from it.

echo "templates"
TEMPLATE_DIR="$(cd "$(dirname "$0")/../templates" && pwd)"
found_templates=0
for template in "$TEMPLATE_DIR"/*.json; do
	[ -f "$template" ] || continue
	found_templates=$((found_templates + 1))
	rc=0
	out="$(bash "$FIREWALL_SH" --check-config --config "$template" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "template $(basename "$template") is valid"
	else
		ng "template $(basename "$template") is valid ($out)"
	fi
done
if [ "$found_templates" -gt 0 ]; then
	ok "$found_templates templates were checked"
else
	ng "no templates were found under $TEMPLATE_DIR"
fi

# The audit template must actually select audit mode, and the default one must
# not: shipping a template that silently leaves egress open would be worse than
# shipping none.
if grep -q '"mode": *"audit"' "$TEMPLATE_DIR/firewall.audit.json"; then
	ok "the audit template selects audit mode"
else
	ng "the audit template selects audit mode"
fi
if grep -q '"mode": *"enforce"' "$TEMPLATE_DIR/firewall.json"; then
	ok "the default template selects enforce mode"
else
	ng "the default template selects enforce mode"
fi

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
