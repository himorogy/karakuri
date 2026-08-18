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
accepts validate_port "1" "22" "4588" "5432" "65535"
# 0 is refused like any other number that is not a port. It is not a spelling of
# "disabled" - leaving the field out is - so accepting it would mean accepting a
# value whose meaning nothing downstream agrees on.
rejects validate_port "" "0" "-1" "65536" "99999" "08" "22.5" "22abc" "1 2"

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
	"profile": ["anthropic", "npm", "github"],
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

# sshdPort is opt-in: an absent field is a policy (no inbound port at all), not a
# field waiting for a default. Both spellings of "absent" have to be accepted,
# and a port that was written down has to be a real one - the schema gate is the
# only place a value like 0 or "22" can still be stopped.
check_config "an omitted sshdPort" accept '{"version":1}'
check_config "a null sshdPort" accept '{"version":1,"sshdPort":null}'
check_config "an explicit sshdPort" accept '{"version":1,"sshdPort":4588}'
check_config "an sshdPort that happens to be 22" accept '{"version":1,"sshdPort":22}'
check_config "the highest sshdPort" accept '{"version":1,"sshdPort":65535}'
check_config "sshdPort 0" reject '{"version":1,"sshdPort":0}'
check_config "a negative sshdPort" reject '{"version":1,"sshdPort":-1}'
check_config "a non-integer sshdPort" reject '{"version":1,"sshdPort":22.5}'
check_config "a string sshdPort" reject '{"version":1,"sshdPort":"22"}'
check_config "an out of range sshdPort" reject '{"version":1,"sshdPort":65536}'
check_config "an array sshdPort" reject '{"version":1,"sshdPort":[22]}'

# Control characters have to die at the schema gate, because nothing below it
# can see them any more. `jq -r` emits \u0000 as a real NUL byte, and both
# command substitution and `read` drop it: the validators then judge a string
# the config does not contain. The danger is not the shell - it is that the
# value a human reviews in the diff is not the value that ends up in the ipset.
check_config "NUL in profile" reject '{"version":1,"profile":"default\u0000"}'
check_config "NUL in allowDomains" reject '{"version":1,"allowDomains":["attacker\u0000.example.com"]}'
check_config "NUL in allowCidrs" reject '{"version":1,"allowCidrs":["203.0.113.0/24\u0000"]}'
# The unknown field gate reads keys through `read` as well, so a NUL in a key
# passes it and the field is then silently absent: accepted, never applied.
check_config "NUL in a field name" reject '{"version":1,"allowDomains\u0000":["example.com"]}'
# A newline splits one array entry into two `read` iterations, a tab splits one
# entry at IFS and drops the remainder. Both are accepted today, and in both
# cases the entry list that takes effect differs from the one in the file.
check_config "newline in allowDomains" reject '{"version":1,"allowDomains":["example.com\nevil.example.com"]}'
check_config "tab in allowDomains" reject '{"version":1,"allowDomains":["example.com\tevil.example.com"]}'
check_config "DEL in allowDomains" reject '{"version":1,"allowDomains":["example.com\u007f"]}'
check_config "NUL in mode" reject '{"version":1,"mode":"enforce\u0000"}'

# A schema violation this specific reads as a JSON syntax complaint unless the
# message names the cause: the character is invisible in the diff by definition.
printf '%s' '{"version":1,"allowDomains":["attacker\u0000.example.com"]}' >"$TMPDIR_TEST/firewall.json"
rc=0
out="$(bash "$FIREWALL_SH" --check-config --config "$TMPDIR_TEST/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "control character"; then
	ok "the control character rejection names the cause"
else
	ng "the control character rejection names the cause (rc=$rc, out=$out)"
fi

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

# --- base profile bundles ----------------------------------------------------
#
# `profile` selects named bundles, and nothing is selected unless it says so.
# There is deliberately no name that means "all of them": a catch-all is how an
# allowlist ends up holding destinations nobody chose, because keeping the
# umbrella is always easier than working out which bundles are really used.

echo "profile bundles"
check_config "profile as an array" accept '{"version":1,"profile":["anthropic","npm"]}'
check_config "profile as a single bundle name" accept '{"version":1,"profile":"npm"}'
check_config "profile as an empty array" accept '{"version":1,"profile":[]}'
check_config "an omitted profile" accept '{"version":1}'
# Asking for the same bundle twice is a merge artefact, not an error. It must
# not be able to produce a policy that differs from asking once.
check_config "a repeated bundle name" accept '{"version":1,"profile":["github","github","npm"]}'
check_config "every bundle named individually" accept \
	'{"version":1,"profile":["anthropic","anthropic-updates","openai","npm","vscode","github"]}'
check_config '"default" as a profile' reject '{"version":1,"profile":"default"}'
check_config '"default" alongside a bundle name' reject '{"version":1,"profile":["default","npm"]}'
# sentry.io and statsig.com were never shown to be required, so they are in no
# bundle at all. The name has to be gone with them: a bundle that is accepted
# and contributes nothing is worse than one that is refused.
check_config "the telemetry bundle" reject '{"version":1,"profile":["telemetry"]}'
check_config "an unknown bundle in an array" reject '{"version":1,"profile":["anthropic","wide-open"]}'
check_config "an unknown bundle on its own" reject '{"version":1,"profile":["wide-open"]}'
check_config "a non-string bundle name" reject '{"version":1,"profile":[1]}'
check_config "a nested array of bundle names" reject '{"version":1,"profile":[["npm"]]}'
# An empty name is not a bundle. Skipping it silently would mean accepting a
# profile and then not honouring it, which is the failure mode the unknown field
# gate exists to prevent.
check_config "an empty bundle name" reject '{"version":1,"profile":[""]}'
check_config "an empty profile string" reject '{"version":1,"profile":""}'
check_config "a null profile selects no bundle" accept '{"version":1,"profile":null}'

# Every configuration written before this change says "default", so this is the
# error the reader meets first. "unknown profile: default" would tell them their
# spelling was wrong rather than that the concept is gone, and would leave them
# guessing at what to write instead.
printf '%s' '{"version":1,"profile":"default"}' >"$TMPDIR_TEST/firewall.json"
rc=0
out="$(bash "$FIREWALL_SH" --check-config --config "$TMPDIR_TEST/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no longer exists'; then
	ok '"default" is refused with its own message, not the unknown-bundle one'
else
	ng "\"default\" is refused with its own message (rc=$rc, out=$out)"
fi
if printf '%s' "$out" | grep -q 'anthropic.*npm.*github'; then
	ok '"default" is refused with a worked example of what to write instead'
else
	ng "\"default\" is refused with a worked example (out=$out)"
fi
if printf '%s' "$out" | grep -q 'Available bundles'; then
	ok '"default" is refused with the list of bundles to choose from'
else
	ng "\"default\" is refused with the list of bundles (out=$out)"
fi
# The list has to be the real one. A bundle that exists but is never named in
# the message is a bundle nobody discovers, and this message is where a reader
# who has just lost "default" goes looking for what to write.
for b in anthropic anthropic-updates openai npm vscode github; do
	if printf '%s' "$out" | grep -q "Available bundles:.*$b"; then
		ok "the bundle list offered to the reader includes $b"
	else
		ng "the bundle list offered to the reader includes $b (out=$out)"
	fi
done

# The generic message earns its own check: it is what a typo produces, and it
# has to point at the same list.
printf '%s' '{"version":1,"profile":["anthropic-update"]}' >"$TMPDIR_TEST/firewall.json"
rc=0
out="$(bash "$FIREWALL_SH" --check-config --config "$TMPDIR_TEST/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'available bundles:.*anthropic-updates'; then
	ok "a near-miss bundle name is refused with the list of real ones"
else
	ng "a near-miss bundle name is refused with the list of real ones (rc=$rc, out=$out)"
fi

# --- --print-allowlist -------------------------------------------------------
#
# The listing is what an agent reads to find out where it may connect, so it has
# to be answerable without root and without egress - the container it is asked
# from is the one this script has already closed.

echo "--print-allowlist"

listing_for() { # <json> -> the listing on stdout, progress lines discarded
	local file="$TMPDIR_TEST/firewall.json"
	printf '%s' "$1" >"$file"
	bash "$FIREWALL_SH" --print-allowlist --config "$file" 2>/dev/null
}

# section_of <listing> <label> -> the indented entries under "<label>:"
section_of() {
	printf '%s\n' "$1" | awk -v label="$2:" '
		$0 == label { inside = 1; next }
		inside && /^  / { line = $0; sub(/^  /, "", line); print line; next }
		inside { inside = 0 }
	'
}

says() { # <label> <listing> <expected line>
	if printf '%s\n' "$2" | grep -qxF -- "$3"; then
		ok "$1"
	else
		ng "$1 (missing line: $3)"
	fi
}

# Every bundle at once, which is the largest base profile that can be asked for.
# Sorted, because that is the order the listing prints them in. sentry.io and
# statsig.com are absent by design: they belong to no bundle any more.
ALL_BUNDLES="api.anthropic.com
api.github.com
auth.openai.com
chatgpt.com
codeload.github.com
downloads.claude.ai
downloads.claude.com
github.com
marketplace.visualstudio.com
objects.githubusercontent.com
raw.githubusercontent.com
registry.npmjs.org
update.code.visualstudio.com
vscode.blob.core.windows.net"

ALL_LISTING="$(listing_for '{"version":1,"profile":["anthropic","anthropic-updates","openai","npm","vscode","github"]}')"
if [ "$(section_of "$ALL_LISTING" domains)" = "$ALL_BUNDLES" ]; then
	ok "naming every bundle lists exactly the domains those six bundles hold"
else
	ng "naming every bundle lists exactly the domains those six bundles hold"
	printf '%s\n' "$(section_of "$ALL_LISTING" domains)" | sed 's/^/    /' >&2
fi
# The domains that were dropped, and the ones that were never let in. They are
# the reason a stale policy can look correct: nothing else in the listing
# changes when one of them silently reappears.
#
# sentry.io, statsig.com and console.anthropic.com came in with the thirteen
# domains inherited from the claude-code devcontainer and appear zero times in
# the claude binary. api.openai.com was never exercised, so it has not been
# shown to be needed. web-sandbox.oaiusercontent.com had its address observed,
# but a Cloudflare anycast address fronts many zones, so the match is not
# evidence of what was connected to.
for gone in sentry.io statsig.com console.anthropic.com api.openai.com web-sandbox.oaiusercontent.com; do
	if printf '%s\n' "$ALL_LISTING" | grep -qF "$gone"; then
		ng "$gone is in no bundle"
	else
		ok "$gone is in no bundle"
	fi
done

# The new default. A project that says nothing gets nothing, and the listing has
# to say so rather than quietly showing a policy the project never chose.
OMITTED_LISTING="$(listing_for '{"version":1}')"
says "an omitted profile selects no bundle" "$OMITTED_LISTING" "profile: (none)"
if [ "$(section_of "$OMITTED_LISTING" domains)" = "(none)" ]; then
	ok "an omitted profile installs no base domain at all"
else
	ng "an omitted profile installs no base domain at all"
	printf '%s\n' "$(section_of "$OMITTED_LISTING" domains)" | sed 's/^/    /' >&2
fi
if [ "$OMITTED_LISTING" = "$(listing_for '{"version":1,"profile":[]}')" ]; then
	ok "an omitted profile is the same policy as an empty one"
else
	ng "an omitted profile is the same policy as an empty one"
fi

# Each bundle holds what it says it holds. Checked one at a time, because a
# bundle that quietly gained a domain would still satisfy an assertion made
# against the union.
bundle_holds() { # <bundle> <domains, newline separated>
	local got
	got="$(section_of "$(listing_for "{\"version\":1,\"profile\":[\"$1\"]}")" domains)"
	if [ "$got" = "$2" ]; then
		ok "the $1 bundle holds exactly its documented domains"
	else
		ng "the $1 bundle holds exactly its documented domains (got: $got)"
	fi
}
bundle_holds anthropic "api.anthropic.com"
bundle_holds anthropic-updates "downloads.claude.ai
downloads.claude.com"
bundle_holds openai "auth.openai.com
chatgpt.com"
bundle_holds npm "registry.npmjs.org"
bundle_holds vscode "marketplace.visualstudio.com
update.code.visualstudio.com
vscode.blob.core.windows.net"
bundle_holds github "api.github.com
codeload.github.com
github.com
objects.githubusercontent.com
raw.githubusercontent.com"

DUPED_LISTING="$(listing_for '{"version":1,"profile":["npm","github","npm","github"]}')"
PLAIN_LISTING="$(listing_for '{"version":1,"profile":["npm","github"]}')"
if [ "$DUPED_LISTING" = "$PLAIN_LISTING" ]; then
	ok "a repeated bundle name produces the same listing as naming it once"
else
	ng "a repeated bundle name produces the same listing as naming it once"
fi

SUBSET_LISTING="$(listing_for '{"version":1,"profile":["anthropic","npm"]}')"
says "the selected bundles are named in order" "$SUBSET_LISTING" "profile: anthropic, npm"
if [ "$(section_of "$SUBSET_LISTING" domains)" = "api.anthropic.com
registry.npmjs.org" ]; then
	ok "a subset lists only the domains of the bundles it asked for"
else
	ng "a subset lists only the domains of the bundles it asked for"
	printf '%s\n' "$(section_of "$SUBSET_LISTING" domains)" | sed 's/^/    /' >&2
fi
# The bundles that were left out have to be genuinely gone, not merely unlisted.
assert_missing() { # <label> <listing> <string>
	if printf '%s\n' "$2" | grep -qF -- "$3"; then
		ng "$1 (unexpectedly present: $3)"
	else
		ok "$1"
	fi
}
assert_missing "a bundle that was not selected contributes nothing" \
	"$SUBSET_LISTING" "sentry.io"
# The update channel is its own bundle precisely so that it can be left out
# while the service itself is allowed. If it leaked into the anthropic bundle,
# pinning a version would stop being a matter of dropping one word.
assert_missing "the anthropic bundle does not carry the update channel" \
	"$SUBSET_LISTING" "downloads.claude.ai"
assert_missing "the anthropic bundle does not carry the .com update host either" \
	"$SUBSET_LISTING" "downloads.claude.com"
# One vendor's bundle must not open another vendor's destinations. A project
# that runs only one of the two agents should be able to see that in its policy.
assert_missing "selecting anthropic does not allow the openai hosts" \
	"$SUBSET_LISTING" "auth.openai.com"
assert_missing "selecting anthropic does not allow chatgpt.com" \
	"$SUBSET_LISTING" "chatgpt.com"
OPENAI_LISTING="$(listing_for '{"version":1,"profile":["openai"]}')"
assert_missing "selecting openai does not allow the anthropic hosts" \
	"$OPENAI_LISTING" "api.anthropic.com"
assert_missing "selecting openai does not allow the update channel" \
	"$OPENAI_LISTING" "downloads.claude.ai"
assert_missing "the github bundle that was not selected contributes nothing" \
	"$SUBSET_LISTING" "github.com"

EMPTY_LISTING="$(listing_for '{"version":1,"profile":[]}')"
says "an empty profile selects no bundle" "$EMPTY_LISTING" "profile: (none)"
says "an empty profile has no domains" "$EMPTY_LISTING" "  (none)"
if [ -z "$(section_of "$EMPTY_LISTING" domains)" ] ||
	[ "$(section_of "$EMPTY_LISTING" domains)" = "(none)" ]; then
	ok "an empty profile lists no base domain at all"
else
	ng "an empty profile lists no base domain at all"
fi

MERGED_LISTING="$(listing_for '{"version":1,"profile":["npm"],"allowDomains":["registry.npmjs.org","alpha.example.com"],"allowCidrs":["203.0.113.0/24"],"allowHostPorts":[5432]}')"
if [ "$(section_of "$MERGED_LISTING" domains)" = "alpha.example.com
registry.npmjs.org" ]; then
	ok "bundle and allowDomains entries are merged, sorted and deduplicated"
else
	ng "bundle and allowDomains entries are merged, sorted and deduplicated"
	printf '%s\n' "$(section_of "$MERGED_LISTING" domains)" | sed 's/^/    /' >&2
fi
says "configured CIDRs are listed" "$MERGED_LISTING" "  203.0.113.0/24"
says "configured host ports are listed" "$MERGED_LISTING" "  5432"
says "the mode is stated" "$MERGED_LISTING" "mode: enforce"
says "audit mode is stated as such" \
	"$(listing_for '{"version":1,"mode":"audit"}')" "mode: audit"

# The meta ranges only exist after a fetch, and the listing deliberately does
# not perform one. Saying so is the difference between an incomplete answer and
# a wrong one - but only when the github bundle is actually in play.
assert_missing "no GitHub note when the github bundle is not selected" \
	"$SUBSET_LISTING" "GitHub meta API"
if printf '%s\n' "$ALL_LISTING" | grep -qF "GitHub meta API"; then
	ok "the GitHub note appears when the github bundle is selected"
else
	ng "the GitHub note appears when the github bundle is selected"
fi

# A listing is never produced from a file an apply would refuse: the same
# validator runs first.
rc=0
printf '%s' '{"version":1,"allowCidrs":["0.0.0.0/0"]}' >"$TMPDIR_TEST/firewall.json"
out="$(bash "$FIREWALL_SH" --print-allowlist --config "$TMPDIR_TEST/firewall.json" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "rejected allowCidrs entry"; then
	ok "--print-allowlist refuses a configuration an apply would refuse"
else
	ng "--print-allowlist refuses a configuration an apply would refuse (rc=$rc)"
fi

# Progress lines belong on stderr. The listing is meant to be parsed, and a
# "[firewall] reading ..." line in the middle of it would not be.
printf '%s' '{"version":1,"profile":["npm"]}' >"$TMPDIR_TEST/firewall.json"
out="$(bash "$FIREWALL_SH" --print-allowlist --config "$TMPDIR_TEST/firewall.json" 2>/dev/null)"
assert_missing "stdout carries no progress lines" "$out" "[firewall]"

# The development options are refused under sudo, and --print-allowlist is one
# of them: the unprivileged user is the adversary, so it must not get to point
# any mode of this script at a file of its own.
rc=0
out="$(SUDO_USER=node SUDO_UID=1000 bash "$FIREWALL_SH" --print-allowlist 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not accepted through sudo"; then
	ok "--print-allowlist is refused when invoked through sudo"
else
	ng "--print-allowlist is refused when invoked through sudo (rc=$rc)"
fi

# --- anchor domain -----------------------------------------------------------
#
# The liveness check used to be "api.anthropic.com must resolve", which stopped
# being defensible the moment a project could leave that bundle out. It now
# anchors on the first domain the configuration actually asks for.

echo "anchor_domain"
anchor_is() { # <label> <expected> <profile domains> <config domains>
	local got
	got="$(
		PROFILE_DOMAINS=()
		CFG_DOMAINS=()
		if [ -n "$3" ]; then
			IFS=' ' read -r -a PROFILE_DOMAINS <<<"$3"
		fi
		if [ -n "$4" ]; then
			IFS=' ' read -r -a CFG_DOMAINS <<<"$4"
		fi
		anchor_domain
	)"
	if [ "$got" = "$2" ]; then
		ok "$1"
	else
		ng "$1 (got '$got', expected '$2')"
	fi
}

anchor_is "the anchor is the first base profile domain" \
	"api.anthropic.com" "api.anthropic.com registry.npmjs.org" "db.example.com"
# anthropic-updates sits after anthropic in the canonical order, so a profile
# that takes the update channel without the service anchors on the update host.
anchor_is "the anchor follows the canonical bundle order" \
	"downloads.claude.ai" "downloads.claude.ai downloads.claude.com" ""
anchor_is "a vendor bundle on its own anchors on that vendor" \
	"auth.openai.com" "auth.openai.com chatgpt.com" "db.example.com"
anchor_is "with no bundle selected the anchor falls back to allowDomains" \
	"db.example.com" "" "db.example.com other.example.com"
anchor_is "with nothing to resolve there is no anchor" "" "" ""

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

# --- every firewall.json example the repository shows a reader ----------------
#
# The schema is the one thing here that a reader copies rather than calls, so an
# example that no longer validates is a defect in the same sense a broken
# function is: whoever pastes it gets a container that boots into the panic
# table. Three rounds of adding bundles produced exactly that, in the templates
# and in the README, and both were caught by eye - which is to say, they were
# caught the one time somebody happened to look.
#
# So every example is collected from where it actually lives and put through the
# real validator. Nothing is transcribed into this file: a copy of the examples
# here would be one more thing to keep in step, and it would go stale in the
# same way and just as quietly.

echo "documented examples"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BLOCK_DIR="$TMPDIR_TEST/blocks"
STRIPPED_DIR="$TMPDIR_TEST/blocks-stripped"
mkdir -p "$BLOCK_DIR" "$STRIPPED_DIR"

# extract_blocks <markdown file> <prefix>
#
# Writes every fenced json/jsonc block to $BLOCK_DIR/<prefix>.<n>.<lang>. The
# language tag is kept in the name because it decides how the block is handled
# below, and the fence is the only place it is recorded.
#
# SC2016: the awk program is single quoted on purpose - $0 and friends belong to
# awk, not to the shell.
# shellcheck disable=SC2016
extract_blocks() {
	awk -v outdir="$BLOCK_DIR" -v prefix="$2" '
		!inblock && $0 ~ /^[ \t]*```json$/ {
			n++; file = outdir "/" prefix "." n ".json"; inblock = 1; next
		}
		!inblock && $0 ~ /^[ \t]*```jsonc$/ {
			n++; file = outdir "/" prefix "." n ".jsonc"; inblock = 1; next
		}
		inblock && $0 ~ /^[ \t]*```[ \t]*$/ { inblock = 0; close(file); next }
		inblock { print >> file }
	' "$1"
}

for md in "$PKG_ROOT/README.md" "$PKG_ROOT"/docs/*.md; do
	[ -f "$md" ] || continue
	extract_blocks "$md" "$(basename "$md" .md)"
done

examples_checked=0
doc_examples=0
commented_examples=0

check_example() { # <label> <path>
	local out rc=0
	out="$(bash "$FIREWALL_SH" --check-config --config "$2" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "configuration is valid"; then
		ok "example validates: $1"
	else
		ng "example validates: $1 (rc=$rc, out=$out)"
	fi
	examples_checked=$((examples_checked + 1))
}

# The templates are the examples a reader copies wholesale.
for template in "$TEMPLATE_DIR"/*.json; do
	[ -f "$template" ] || continue
	check_example "templates/$(basename "$template")" "$template"
done

# This repository's own policy. It is the example a reader meets before any
# documentation, because it is the file they are already looking at.
DEVCONTAINER_CONFIG="$REPO_ROOT/.devcontainer/firewall.json"
if [ -f "$DEVCONTAINER_CONFIG" ]; then
	check_example ".devcontainer/firewall.json" "$DEVCONTAINER_CONFIG"
else
	ng "no .devcontainer/firewall.json under $REPO_ROOT; the repository's own policy went unchecked"
fi

# Not every json block is a firewall.json. devcontainer.json fragments and
# Feature options are in there too, and they are not even complete objects.
# Mentioning "version" is what makes a block one of ours.
for block in "$BLOCK_DIR"/*; do
	[ -f "$block" ] || continue
	grep -q '"version"' "$block" || continue
	name="$(basename "$block")"
	doc_examples=$((doc_examples + 1))

	case "$name" in
	*.jsonc)
		# Comments come off the way a reader takes them off: whole lines whose
		# first non-blank characters are //. Deliberately NOT `s|//.*||`, which
		# would swallow the rest of any line holding an https:// URL - the
		# example would then be repaired by the test that is supposed to judge
		# it, and the day a URL appears in one, this would go quietly wrong.
		stripped="$STRIPPED_DIR/$name.json"
		sed '/^[[:space:]]*\/\//d' "$block" >"$stripped"
		check_example "$name (comments stripped)" "$stripped"

		# The README tells the reader that pasting the block with its comments
		# still in gives them a container in the panic table. That claim is only
		# worth printing if it is true.
		if grep -q '^[[:space:]]*//' "$block"; then
			commented_examples=$((commented_examples + 1))
			rc=0
			out="$(bash "$FIREWALL_SH" --check-config --config "$block" 2>&1)" || rc=$?
			if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "is not valid JSON"; then
				ok "example is refused with its comments left in: $name"
			else
				ng "example is refused with its comments left in: $name (rc=$rc, out=$out)"
			fi
		fi
		;;
	*)
		check_example "$name" "$block"
		;;
	esac
done

# A count, because the failure this section exists to prevent has a silent form:
# an extractor that stops matching finds nothing, and a suite that checked
# nothing looks exactly like a suite where everything passed.
if [ "$examples_checked" -gt 0 ]; then
	ok "$examples_checked firewall.json examples were checked"
else
	ng "no firewall.json example was found anywhere; the extraction is broken"
fi
# Counted separately: the templates and .devcontainer/firewall.json would keep
# the total above zero on their own, so the total cannot show that the fenced
# blocks are still being found.
if [ "$doc_examples" -gt 0 ]; then
	ok "$doc_examples of them came from fenced blocks in README.md and docs/"
else
	ng "no fenced firewall.json example was extracted from the documentation"
fi
if [ "$commented_examples" -gt 0 ]; then
	ok "$commented_examples commented example(s) were confirmed to be refused"
else
	ng "no commented jsonc example was found, so the 'comments are refused' claim went unchecked"
fi

# --- result ------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
