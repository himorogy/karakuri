#!/usr/bin/env bash
#
# init-project-firewall.sh - allowlist based egress firewall for devcontainers
#
# Spec: packages/egress-guard/docs/spec.md
#
# Design notes that are easy to get wrong when editing this file:
#
#   * This script runs as root through a fixed-path sudoers entry with no
#     arguments allowed. It must therefore locate its own configuration and
#     must treat that configuration as attacker controlled data (see validate_*).
#   * The adversary in this threat model is the agent running in the container,
#     so a policy file the agent can write is not a policy. The apply path reads
#     only the root owned /etc/egress-guard/firewall.json; the copy in the repo
#     is source that takes effect on the next image build. See PROD_CONFIG.
#   * The base profile is embedded here on purpose. A bundled JSON inside
#     node_modules would be writable by the unprivileged user and would become a
#     privilege escalation path.
#   * Order matters. The container is closed BEFORE this script uses the
#     network: IPv6 goes to its final all-DROP state and IPv4 gets a bootstrap
#     table that permits only loopback, the assigned resolvers and the sessions
#     already open. The allowlist is then built with nothing but DNS, the real
#     IPv4 table replaces the bootstrap one, and only afterwards is the GitHub
#     meta API fetched. No step of the rebuild needs an open network, so an
#     abrupt kill at any point can only leave a closed policy behind.
#   * Each filter table is installed with iptables-restore in a single
#     transaction that carries the chain policies with it, so the chains are
#     never empty while the policy is ACCEPT. IPv4 and IPv6 cannot share one
#     transaction, which is why IPv6 is closed first and never reopened.
#   * The nat table is deliberately left alone. The Docker DNS DNAT rules live
#     there, and the unprivileged user cannot write to it, so flushing and
#     replaying those rules would add a fragile step with nothing to gain.
#   * Failure at any point in the apply phase leaves the container in "panic"
#     state (egress DROP) and exits non-zero. There is no code path that ends
#     with an open network.
#   * Wildcard domains (*.example.com) are rejected by the validator. DNS cannot
#     enumerate the subdomains of a zone, so a wildcard cannot be expanded into
#     addresses; accepting one would install a policy that silently blocks every
#     subdomain the author believed it allowed. Wildcards belong to the L7 proxy
#     described in the spec.
#   * DNS pinning stays enforced in audit mode. Legitimate traffic goes to the
#     assigned resolver anyway, and relaxing it would defeat the whole policy.
#   * The resolver is read from resolv.conf rather than hardcoded. The Docker
#     embedded resolver at 127.0.0.11 only exists on user defined networks; a
#     container on the default bridge is handed the host's resolver instead.
#
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="init-project-firewall.sh"
readonly SET_V4="egress-allow-v4"
readonly SET_V4_STAGING="egress-allow-v4-stg"

# Destinations that were not on the allowlist are recorded here, so that "what
# should I allow?" can be answered from inside the container.
#
# The `-j LOG` rules write to the kernel ring buffer, which a container cannot
# read (no CAP_SYSLOG) and which the kernel suppresses for non-initial network
# namespaces anyway (net.netfilter.nf_log_all_netns defaults to 0). This set
# does not depend on either. See docs/known-issues.md.
readonly SET_V4_AUDIT="egress-audit-v4"
readonly AUDIT_TIMEOUT=604800 # 7 days; entries age out on their own
readonly DOCKER_EMBEDDED_RESOLVER="127.0.0.11"
readonly DEFAULT_RESOLV_CONF="/etc/resolv.conf"

# Probes for the "external DNS is blocked" self check. The first one that is not
# also a configured resolver is used.
readonly -a DNS_PROBES=("8.8.8.8" "1.1.1.1" "9.9.9.9")

# Probes for the "unlisted host is blocked" self check. The first one that is
# not in the allowlist is used, so a project that allows one of these still
# passes verification.
readonly -a EGRESS_PROBES=("example.com" "example.net" "example.org")
readonly SUPPORTED_SCHEMA_VERSION=1
readonly LOG_LIMIT="5/min"
readonly LOG_BURST="10"
readonly MAX_CONFIG_BYTES=65536

# The one file the apply path reads. Root owned, outside the workspace, and not
# derived from the environment (env vars are not trustworthy under sudo).
#
# The adversary here is the agent inside the container, and sudoers lets it
# re-apply the policy at any time. If the file that re-apply reads were writable
# by the agent, an injected agent could disable the firewall in two steps:
# write {"allowDomains":["attacker.example"]} or {"mode":"audit"} - both
# syntactically valid, so every validator passes them - and run sudo. Root is
# never obtained, and the policy is gone anyway.
#
# Keeping the effective configuration root owned splits the two operations: the
# agent may re-resolve the policy as often as it likes (which is what makes the
# CDN address churn survivable), but changing the policy means editing the repo
# and rebuilding the image, which a human does.
readonly PROD_CONFIG="/etc/egress-guard/firewall.json"

# There is no search of any kind. The image build places the configuration at
# the path above; a script that went looking for one would have to assume a
# workspace layout (/workspace, /workspaces/<name>, ...) that varies per setup,
# and every location it agreed to look in would be another candidate for the
# agent to plant a policy in. To check a file that is not installed yet, name it
# with --config.

# --- base profile (package owned, common to every project) -------------------
#
# The base profile is a set of named bundles that `profile` selects from, and
# nothing is selected unless the configuration says so. An allowlist that
# contains entries nobody can justify is one nobody reviews, and a default that
# opens destinations the project never asked for is exactly how such entries get
# there. Omitting `profile` therefore means no base profile at all.
#
# PROFILE_BUNDLE_NAMES is the canonical order. It decides which domain the
# liveness check anchors on (see anchor_domain), so it is part of the observable
# behaviour and not merely cosmetic. Keep the members in the order a project is
# most likely to depend on them.
readonly -a PROFILE_BUNDLE_NAMES=(
	"anthropic"
	"anthropic-updates"
	"openai"
	"npm"
	"vscode"
	"github"
)

# The minimum Claude Code needs to talk to the service at all. One domain.
#
# Established by scanning the strings of the claude binary (v2.1.221, 285MB):
# api.anthropic.com appears 79 times. console.anthropic.com, sentry.io and
# statsig.com appear zero times, and none of the three was ever observed in an
# audit run either. All three came in with the thirteen domains inherited from
# the claude-code devcontainer and none of them meets this bundle's definition,
# so none of them is here. A project that turns out to need one can list it in
# allowDomains, and it can move into a bundle once something demonstrates it is
# required.
readonly -a BUNDLE_ANTHROPIC=(
	"api.anthropic.com"
)

# Where Claude Code fetches its own updates from. Found by running in audit mode
# and reading back the blocked destinations: 35.190.46.17 turned up in the audit
# set, and the SANs on the certificate it presents are these two names.
#
# Deliberately not part of the anthropic bundle. Updating is not needed to talk
# to the service - blocking it produces a message and the tool carries on
# working, which was measured rather than assumed - so a project that wants its
# version pinned should be able to drop one word instead of writing an exception
# to a bundle it otherwise wants whole.
#
# The .com name does not appear in the binary either, and is kept anyway: it
# resolves to the same address as the .ai one, so it costs the allowlist
# nothing, and it is what the policy will need if the name ever moves.
readonly -a BUNDLE_ANTHROPIC_UPDATES=(
	"downloads.claude.ai"
	"downloads.claude.com"
)

# What the codex CLI (v0.146.0) was measured to need. Found the same way as the
# update channel: audit mode, then the difference in egress-audit-v4 either side
# of a command. `codex login` produced 172.64.146.15, `codex exec` produced
# 172.64.155.209, and those are the A records of these two names.
#
# api.openai.com is NOT here. The API key path was not exercised, and a domain
# goes into a package owned bundle when it has been shown to be needed, not when
# it seems likely; a project on that path can list it in allowDomains.
#
# 172.64.144.52 turned up in the same window and is deliberately left out. It
# matches the A record of web-sandbox.oaiusercontent.com, but Cloudflare anycast
# addresses front many zones at once, so an address match is not evidence that
# the connection went to that host. A destination whose purpose cannot be stated
# does not go in a bundle.
readonly -a BUNDLE_OPENAI=(
	"auth.openai.com"
	"chatgpt.com"
)

readonly -a BUNDLE_NPM=(
	"registry.npmjs.org"
)

readonly -a BUNDLE_VSCODE=(
	"marketplace.visualstudio.com"
	"vscode.blob.core.windows.net"
	"update.code.visualstudio.com"
)

# Resolved on every run so that GitHub works even when the meta API cannot be
# reached; the meta ranges are added on top afterwards, and only when this
# bundle is selected.
readonly -a BUNDLE_GITHUB=(
	"github.com"
	"api.github.com"
	"codeload.github.com"
	"objects.githubusercontent.com"
	"raw.githubusercontent.com"
)

# bundle_domains <name> -> prints the bundle's domains, one per line
#
# Returns non-zero for a name that is not a bundle, which is what makes the
# lookup double as the validator for a `profile` entry.
#
# A case statement rather than an associative array or a nameref: the bundle
# name comes out of attacker controlled JSON, and `local -n ref="BUNDLE_$name"`
# would turn that string into a variable name to dereference.
bundle_domains() {
	case "$1" in
	anthropic) printf '%s\n' "${BUNDLE_ANTHROPIC[@]}" ;;
	anthropic-updates) printf '%s\n' "${BUNDLE_ANTHROPIC_UPDATES[@]}" ;;
	openai) printf '%s\n' "${BUNDLE_OPENAI[@]}" ;;
	npm) printf '%s\n' "${BUNDLE_NPM[@]}" ;;
	vscode) printf '%s\n' "${BUNDLE_VSCODE[@]}" ;;
	github) printf '%s\n' "${BUNDLE_GITHUB[@]}" ;;
	*) return 1 ;;
	esac
	return 0
}

# The default gateway is not always the address the host answers on. Docker
# Desktop routes host.docker.internal to a separate address, so allowHostPorts
# has to permit both or a local database on the host stays unreachable.
readonly HOST_INTERNAL_NAME="host.docker.internal"

# Ranges a host address may fall in. Anything else means the name was answered
# by something other than Docker, and opening a port there would be a hole to an
# arbitrary destination rather than to the host.
readonly -a HOST_TARGET_RANGES=(
	"10.0.0.0/8"
	"100.64.0.0/10"
	"169.254.0.0/16"
	"172.16.0.0/12"
	"192.168.0.0/16"
)

# Ranges that must never appear in allowCidrs. Beyond RFC1918 this also covers
# the Tailscale CGNAT range, which is the actual lateral movement risk on the
# host side.
readonly -a FORBIDDEN_CIDRS=(
	"0.0.0.0/8"
	"10.0.0.0/8"
	"100.64.0.0/10"
	"127.0.0.0/8"
	"169.254.0.0/16"
	"172.16.0.0/12"
	"192.168.0.0/16"
	"224.0.0.0/4"
	"240.0.0.0/4"
)

# --- output helpers ----------------------------------------------------------

info() {
	local IFS=' '
	printf '%s\n' "[firewall] $*"
}
warn() {
	local IFS=' '
	printf '%s\n' "[firewall] WARNING: $*" >&2
}
err() {
	local IFS=' '
	printf '%s\n' "[firewall] ERROR: $*" >&2
}

# Renders an array for a human readable message. The global IFS is $'\n\t', so
# "${arr[*]}" at a call site would join the elements with newlines.
join_sp() {
	local IFS=' '
	printf '%s' "$*"
}

# Same, with ", " between the items.
#
# Joined by hand rather than through IFS: "${arr[*]}" uses only the FIRST
# character of IFS, so an IFS of ", " would separate with a bare comma.
join_comma() {
	local out="" item
	for item in "$@"; do
		[ -z "$out" ] || out="$out, "
		out="$out$item"
	done
	printf '%s' "$out"
}

# First line of a multi-line string.
#
# Deliberately not `... | head -n1`: head closes the pipe after one line, the
# writer upstream dies of SIGPIPE, and under `set -o pipefail` that takes the
# whole command substitution - and with `set -e`, the script - down with it.
first_line() {
	printf '%s' "${1%%$'\n'*}"
}

die() {
	err "$*"
	exit 1
}

# --- state -------------------------------------------------------------------

CONFIG_FILE=""
RESOLV_CONF="$DEFAULT_RESOLV_CONF"
MODE="enforce"
APPLY_PHASE=0
IPV6_CONTROL=0
AUDIT_RECORDER=1
declare -a RESOLVERS=()

# The `profile` field as written, before bundle names are expanded. Empty by
# default, which is also what an omitted field means: a run with no
# configuration file at all and one whose configuration omits `profile` install
# the same (empty) base profile.
declare -a PROFILE_INPUT=()

# Filled in by resolve_profile: the selected bundles and their domains, both in
# PROFILE_BUNDLE_NAMES order with duplicates removed.
declare -a PROFILE_BUNDLES=()
declare -a PROFILE_DOMAINS=()

declare -a CFG_DOMAINS=()
declare -a CFG_CIDRS=()
declare -a CFG_HOST_PORTS=()
# Empty means no listening sshd, which is the default and what an omitted
# `sshdPort` means. There is no built-in port any more: SSH into this container
# goes through `docker exec sshd -i`, which owns no listening socket and is not
# reachable through the network stack, so nothing needs an inbound port opened
# for it.
#
# An inbound port is not a small concession. A permitted inbound connection
# becomes an ESTABLISHED conntrack entry, and the OUTPUT chain accepts
# ESTABLISHED before it consults the allowlist - so every byte the container
# writes back on that connection leaves without passing the allowlist at all.
# That is a reverse channel out of the container, which is precisely what this
# script exists to prevent. Setting `sshdPort` is the declaration that this one
# hole is wanted; the default is not to have it.
SSHD_PORT=""
HOST_GATEWAY=""
declare -a HOST_TARGETS=()

# --- fail closed -------------------------------------------------------------

# Panic table: everything dropped except loopback, plus - only when the
# configuration asked for a listening sshd - the replies of an already
# established inbound session on that port. Outbound ESTABLISHED is NOT kept -
# that would let an exfil connection opened before the failure keep running,
# which is exactly what this script exists to prevent. Interactive access
# through `docker exec` does not use the network stack and survives regardless.
#
# This table is also applied on failures that happen BEFORE the configuration
# has been read (a rejected schema, for instance), and there SSHD_PORT is still
# empty, so no sshd rule is emitted. That is deliberate: at that point no port
# has been agreed on, and inventing one would open an inbound hole the
# configuration never asked for.
emit_panic_filter() {
	printf '%s\n' "*filter"
	printf '%s\n' ":INPUT DROP [0:0]"
	printf '%s\n' ":FORWARD DROP [0:0]"
	printf '%s\n' ":OUTPUT DROP [0:0]"
	printf '%s\n' "-A INPUT -i lo -j ACCEPT"
	printf '%s\n' "-A OUTPUT -o lo -j ACCEPT"
	if [ -n "$SSHD_PORT" ]; then
		printf '%s\n' "-A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT"
		printf '%s\n' "-A OUTPUT -p tcp --sport $SSHD_PORT -m conntrack --ctstate ESTABLISHED -j ACCEPT"
	fi
	printf '%s\n' "COMMIT"
}

emit_panic_filter6() {
	printf '%s\n' "*filter"
	printf '%s\n' ":INPUT DROP [0:0]"
	printf '%s\n' ":FORWARD DROP [0:0]"
	printf '%s\n' ":OUTPUT DROP [0:0]"
	printf '%s\n' "-A INPUT -i lo -j ACCEPT"
	printf '%s\n' "-A OUTPUT -o lo -j ACCEPT"
	printf '%s\n' "COMMIT"
}

# Any failure once the apply phase has been entered must not leave the container
# with an open network, no matter how far the rebuild got.
on_exit() {
	local rc=$?
	trap - EXIT
	if [ "$rc" -eq 0 ]; then
		exit 0
	fi
	set +e
	if [ "$APPLY_PHASE" = "1" ]; then
		err "applying panic policy (egress DROP) after failure"
		emit_panic_filter | iptables-restore 2>/dev/null
		# Attempted unconditionally rather than only when IPV6_CONTROL is set:
		# the apply phase now starts before the IPv6 check runs, so a failure in
		# between would otherwise leave IPv6 untouched. A missing ip6tables makes
		# this a no-op.
		emit_panic_filter6 | ip6tables-restore 2>/dev/null
		ipset destroy "$SET_V4_STAGING" 2>/dev/null
	fi
	exit "$rc"
}

# --- generic validation helpers ---------------------------------------------

ipv4_to_int() {
	local IFS=.
	# shellcheck disable=SC2086 # deliberate split of a validated dotted quad
	set -- $1
	printf '%s\n' "$((($1 << 24) + ($2 << 16) + ($3 << 8) + $4))"
}

# Leading zeros are rejected: bash arithmetic would read "010" as octal, which
# turns a validation check into a silently different value.
is_ipv4() {
	local ip="$1" octet
	local quad='(0|[1-9][0-9]{0,2})'
	[[ "$ip" =~ ^$quad\.$quad\.$quad\.$quad$ ]] || return 1
	local IFS=.
	for octet in $ip; do
		[ "$octet" -le 255 ] || return 1
	done
	return 0
}

# True when the single address falls inside one of FORBIDDEN_CIDRS.
#
# allowCidrs is checked against these ranges, but a DNS answer was not, which
# left a hole: an allowed domain whose zone is attacker controlled (or simply
# poisoned) could answer 169.254.169.254 and put the cloud metadata service into
# the allowlist. The agent can re-apply at will, so it also gets to choose when
# the rebinding lands.
is_forbidden_ipv4() {
	local ip="$1" forbidden f_net f_len
	for forbidden in "${FORBIDDEN_CIDRS[@]}"; do
		f_net="${forbidden%/*}"
		f_len="${forbidden#*/}"
		if ranges_overlap "$ip" 32 "$f_net" "$f_len"; then
			return 0
		fi
	done
	return 1
}

# True when the address is one a host could plausibly answer on.
#
# host.docker.internal is the one name whose answer is deliberately allowed to
# be a private address, so it cannot go through is_forbidden_ipv4. It still must
# not open a port on an arbitrary internet host: a public answer means the name
# was intercepted, not that the host moved.
is_plausible_host_address() {
	local ip="$1" range r_net r_len
	for range in "${HOST_TARGET_RANGES[@]}"; do
		r_net="${range%/*}"
		r_len="${range#*/}"
		if ranges_overlap "$ip" 32 "$r_net" "$r_len"; then
			return 0
		fi
	done
	return 1
}

# ranges_overlap <net_a> <len_a> <net_b> <len_b>
ranges_overlap() {
	local a_start a_end b_start b_end
	a_start="$(ipv4_to_int "$1")"
	b_start="$(ipv4_to_int "$3")"
	a_end=$((a_start + (1 << (32 - $2)) - 1))
	b_end=$((b_start + (1 << (32 - $4)) - 1))
	[ "$a_start" -le "$b_end" ] && [ "$b_start" -le "$a_end" ]
}

# A domain must be plain ASCII host syntax. Wildcards are rejected outright.
#
# DNS offers no way to enumerate the subdomains of a zone, so a wildcard cannot
# be turned into addresses. Accepting one would install a policy that does not
# do what it says: the apex would be allowed and every subdomain silently
# blocked. In a security setting "accepted but not honoured" is the worst
# property to have, and a warning does not stop the author from believing the
# subdomains are permitted. See docs/spec.md section 9.1.
validate_domain() {
	local d="$1"
	[ -n "$d" ] || return 1
	[ "${#d}" -le 253 ] || return 1
	[[ "$d" == *"*"* ]] && return 1
	[[ "$d" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
	[[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || return 1
	return 0
}

validate_cidr() {
	local cidr="$1" net len forbidden f_net f_len
	[[ "$cidr" =~ ^[0-9.]+/[1-9][0-9]?$ ]] || return 1
	net="${cidr%/*}"
	len="${cidr#*/}"
	is_ipv4 "$net" || return 1
	[ "$len" -ge 8 ] && [ "$len" -le 32 ] || return 1
	for forbidden in "${FORBIDDEN_CIDRS[@]}"; do
		f_net="${forbidden%/*}"
		f_len="${forbidden#*/}"
		if ranges_overlap "$net" "$len" "$f_net" "$f_len"; then
			return 1
		fi
	done
	return 0
}

validate_port() {
	[[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
	[ "$1" -le 65535 ]
}

# --- base profile selection --------------------------------------------------

# Expands PROFILE_INPUT into PROFILE_BUNDLES and PROFILE_DOMAINS.
#
# There is no name that means "all of them". A catch-all is how an allowlist
# acquires destinations nobody chose - it is always easier to keep the umbrella
# than to work out which bundles a project really uses - and the whole value of
# an allowlist is that every entry was chosen.
resolve_profile() {
	PROFILE_BUNDLES=()
	PROFILE_DOMAINS=()

	local -a requested=()
	local name
	for name in "${PROFILE_INPUT[@]:-}"; do
		[ -n "$name" ] || continue
		# Its own message rather than the generic one. Every existing
		# configuration says "default", so this is the error the reader meets
		# first, and "unknown profile: default" would tell them their spelling
		# was wrong rather than that the concept is gone.
		[ "$name" != "default" ] ||
			die "profile \"default\" no longer exists; list the bundles this project actually needs, e.g. \"profile\": [\"anthropic\", \"npm\", \"github\"]. Available bundles: $(join_comma "${PROFILE_BUNDLE_NAMES[@]}"). Omitting profile now selects no base profile at all."
		# The lookup is the validator: a name with no bundle behind it would
		# otherwise silently contribute nothing, which is the failure mode the
		# unknown-field gate exists to prevent one level up.
		bundle_domains "$name" >/dev/null ||
			die "unknown profile: $name (available bundles: $(join_comma "${PROFILE_BUNDLE_NAMES[@]}"))"
		requested+=("$name")
	done

	# Walking the canonical order and keeping what was asked for does the
	# deduplication and the ordering in one pass, so ["github","github"] and
	# ["github"] cannot produce different policies.
	local bundle req domain
	for bundle in "${PROFILE_BUNDLE_NAMES[@]}"; do
		for req in "${requested[@]:-}"; do
			[ "$req" = "$bundle" ] || continue
			PROFILE_BUNDLES+=("$bundle")
			while read -r domain; do
				[ -n "$domain" ] || continue
				PROFILE_DOMAINS+=("$domain")
			done < <(bundle_domains "$bundle")
			break
		done
	done

	info "base profile: $(profile_label)"
	return 0
}

# Renders the selected bundles for a human readable message.
profile_label() {
	if [ "${#PROFILE_BUNDLES[@]}" -eq 0 ]; then
		printf '%s' "(none)"
		return 0
	fi
	join_comma "${PROFILE_BUNDLES[@]}"
}

# profile_has_bundle <name>
profile_has_bundle() {
	local want="$1" bundle
	for bundle in "${PROFILE_BUNDLES[@]:-}"; do
		[ "$bundle" = "$want" ] && return 0
	done
	return 1
}

# The one domain whose failure to resolve means the container has no working
# network, rather than that one service is having a bad day.
#
# It used to be api.anthropic.com, which stopped being defensible once the
# anthropic bundle became something a project can leave out: a policy that never
# asked for that domain would have failed the liveness check every time. The
# anchor is now the first domain the selected bundles contribute, falling back to
# the first configured domain when no bundle is selected at all. Both lists are
# in a fixed order, so the anchor is a property of the configuration and not of
# the run.
#
# Prints nothing when there is no domain to anchor on. That is a legitimate
# configuration (CIDRs and host ports only), so the callers skip the check rather
# than fail it.
anchor_domain() {
	if [ "${#PROFILE_DOMAINS[@]}" -gt 0 ]; then
		printf '%s' "${PROFILE_DOMAINS[0]}"
		return 0
	fi
	if [ "${#CFG_DOMAINS[@]}" -gt 0 ]; then
		printf '%s' "${CFG_DOMAINS[0]}"
		return 0
	fi
	return 0
}

# --- configuration -----------------------------------------------------------

# assert_config_is_root_owned <path>
#
# The configuration that is actually enforced must not be writable by the
# unprivileged user; if it were, the agent could rewrite the policy and re-apply
# it through the sudoers entry. Bind mounting a workspace file over
# /etc/egress-guard/firewall.json is the realistic way to get this wrong, so it
# is checked rather than assumed.
# The containing directory is checked too: a directory the unprivileged user can
# write to lets it unlink the file and put its own there, which no check on the
# file alone can catch.
#
# This is not a defence against a racing attacker. The file is opened again by
# stat and by every jq invocation, so a sufficiently fast swap between the check
# and the reads would win. Closing that would need an fd held across all reads,
# which bash cannot express. What the check does buy is catching the realistic
# misconfiguration - a workspace file bind mounted over the fixed path - before
# it becomes policy.
assert_config_is_root_owned() {
	local path="$1" dir uid mode
	[ -n "$path" ] || return 0

	# Symlinks are resolved by stat, so a root owned link pointing at a file the
	# user controls would pass every check below.
	[ ! -L "$path" ] ||
		die "$path must not be a symlink"

	dir="$(dirname "$path")"
	uid="$(stat -c %u "$dir")"
	[ "$uid" = "0" ] ||
		die "$dir must be owned by root (found uid $uid); a writable directory lets the file be replaced"
	mode="$(stat -c %a "$dir")"
	[ "$((0${mode} & 022))" -eq 0 ] ||
		die "$dir must not be group or world writable (mode $mode)"

	uid="$(stat -c %u "$path")"
	[ "$uid" = "0" ] ||
		die "$path must be owned by root (found uid $uid). It is the enforced policy; the writable copy belongs in the repo and takes effect on image rebuild."

	mode="$(stat -c %a "$path")"
	[ "$((0${mode} & 022))" -eq 0 ] ||
		die "$path must not be group or world writable (mode $mode)"
	return 0
}

read_config() {
	if [ -z "$CONFIG_FILE" ]; then
		info "no firewall.json found, using base profile only"
		resolve_profile
		return 0
	fi

	local size
	size="$(stat -c %s "$CONFIG_FILE")"
	[ "$size" -le "$MAX_CONFIG_BYTES" ] ||
		die "$CONFIG_FILE is larger than $MAX_CONFIG_BYTES bytes"

	info "reading $CONFIG_FILE"

	jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "$CONFIG_FILE is not valid JSON"
	jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null ||
		die "$CONFIG_FILE must contain a JSON object"

	# Control characters have to die here, before any value is read into a shell
	# variable, because below this line they cannot be seen any more. `jq -r`
	# writes a JSON \u0000 escape out as a real NUL byte, and neither command
	# substitution nor `read` can carry one: the validators would then be judging
	# a string the file does not contain. A newline splits one array entry into
	# two `read` iterations and a tab splits one at IFS, with the same result.
	#
	# The risk is not shell injection - the validators still see whatever reaches
	# them. It is that the value a human reviews in the diff stops being the value
	# that ends up in the ipset, and human review is what I1 leans on. Keys are
	# checked too: a NUL in one passes the unknown field gate below, and the field
	# is then silently absent - accepted, never applied.
	jq -e '
		([.. | strings] + [paths | .[] | strings])
		| all(explode | all(. > 31 and . != 127))
	' "$CONFIG_FILE" >/dev/null ||
		die "$CONFIG_FILE contains a control character in a string or field name; these are invisible in a diff and are dropped before validation, so what you review would not be what takes effect"

	# Reject unknown top level keys so that a typo in a future field name can
	# never be silently ignored.
	local key
	while read -r key; do
		case "$key" in
		version | profile | mode | allowDomains | allowCidrs | allowHostPorts | sshdPort) ;;
		*) die "unknown field in $CONFIG_FILE: $key" ;;
		esac
	done < <(jq -r 'keys[]' "$CONFIG_FILE")

	jq -e '
		((.version | type) == "number")
		and ((.version | floor) == .version)
		and ((.profile // [])
			| if type == "string" then . != ""
				elif type == "array" then all(.[]; (type == "string") and (. != ""))
				else false end)
		and ((.mode // "enforce") | . == "enforce" or . == "audit")
		and ((.allowDomains // []) | (type == "array") and all(.[]; type == "string"))
		and ((.allowCidrs // []) | (type == "array") and all(.[]; type == "string"))
		and ((.allowHostPorts // []) | (type == "array")
			and all(.[]; (type == "number") and (floor == .)))
		and ((.sshdPort == null)
			or (((.sshdPort | type) == "number") and ((.sshdPort | floor) == .sshdPort)))
	' "$CONFIG_FILE" >/dev/null || die "$CONFIG_FILE does not match the schema"

	local version
	version="$(jq -r '.version' "$CONFIG_FILE")"
	[ "$version" = "$SUPPORTED_SCHEMA_VERSION" ] ||
		die "unsupported schema version: $version (expected $SUPPORTED_SCHEMA_VERSION)"

	# A bare string is read as a one element list, so the two spellings of
	# "select this one bundle" cannot drift apart. An absent field and an empty
	# array both come out empty, which is the same thing under this schema: no
	# base profile.
	PROFILE_INPUT=()
	local entry
	while read -r entry; do
		PROFILE_INPUT+=("$entry")
	done < <(jq -r '
		(.profile // [])
		| if type == "array" then .[] else . end
	' "$CONFIG_FILE")

	MODE="$(jq -r '.mode // "enforce"' "$CONFIG_FILE")"

	while read -r entry; do
		[ -n "$entry" ] || continue
		# Worth its own message: "rejected: *.example.com" on its own reads like a
		# syntax complaint, and the author needs to know what to write instead.
		if [[ "$entry" == *"*"* ]]; then
			die "rejected allowDomains entry: $entry - wildcards are not supported. DNS cannot enumerate the subdomains of a zone, so a wildcard cannot be expanded into addresses. List the host names you need instead; run in audit mode and read ipset $SET_V4_AUDIT to find out which ones those are."
		fi
		validate_domain "$entry" || die "rejected allowDomains entry: $entry"
		CFG_DOMAINS+=("$entry")
	done < <(jq -r '(.allowDomains // [])[]' "$CONFIG_FILE")

	while read -r entry; do
		[ -n "$entry" ] || continue
		validate_cidr "$entry" ||
			die "rejected allowCidrs entry: $entry (too broad, private, or malformed)"
		CFG_CIDRS+=("$entry")
	done < <(jq -r '(.allowCidrs // [])[]' "$CONFIG_FILE")

	while read -r entry; do
		[ -n "$entry" ] || continue
		validate_port "$entry" || die "rejected allowHostPorts entry: $entry"
		CFG_HOST_PORTS+=("$entry")
	done < <(jq -r '(.allowHostPorts // [])[]' "$CONFIG_FILE")

	# `empty` rather than a default: an omitted field leaves SSHD_PORT empty and
	# no inbound port is opened at all. Only a port that was actually written
	# down is validated, and it is validated exactly as before - 0 is not a way
	# to spell "disabled", it is a port number that does not exist, and it is
	# refused. Leaving the field out is how the port is disabled.
	SSHD_PORT="$(jq -r '.sshdPort // empty' "$CONFIG_FILE")"
	if [ -n "$SSHD_PORT" ]; then
		validate_port "$SSHD_PORT" || die "rejected sshdPort: $SSHD_PORT"
	fi

	# Last, so that a bundle name nobody recognises is reported after the fields
	# that can be checked without knowing what a bundle is.
	resolve_profile

	info "config ok: mode=$MODE domains=${#CFG_DOMAINS[@]} cidrs=${#CFG_CIDRS[@]} hostPorts=${#CFG_HOST_PORTS[@]}"
	return 0
}

# --- environment checks ------------------------------------------------------

have_ip6tables() {
	command -v ip6tables >/dev/null 2>&1 &&
		command -v ip6tables-restore >/dev/null 2>&1 &&
		ip6tables -L -n >/dev/null 2>&1
}

# The kernel exposes /proc/net/if_inet6 only when the IPv6 stack is loaded, and
# an empty file means not even a link local address exists.
ipv6_stack_active() {
	[ -e /proc/net/if_inet6 ] || return 1
	[ -s /proc/net/if_inet6 ]
}

# A missing ip6tables is NOT evidence that IPv6 is unreachable: the binary can
# be absent, or the nft backend broken, while the stack routes traffic happily.
# Skipping is only safe when the stack itself is gone.
require_ipv6_control() {
	if have_ip6tables; then
		IPV6_CONTROL=1
		return 0
	fi
	if ipv6_stack_active; then
		die "IPv6 is active but ip6tables is unusable; refusing to leave IPv6 egress unfiltered"
	fi
	IPV6_CONTROL=0
	warn "IPv6 stack is not present in this container; skipping ip6tables"
}

# The sudoers entry names a fixed path. This checks that the file actually
# sitting at that path is the root owned one - that the entry does not point
# into a directory the unprivileged user can write to, with node_modules being
# the classic mistake.
#
# Against a deliberately planted script this proves nothing: the planted copy
# would simply not contain the check. What it catches is the honest
# misconfiguration, which is the realistic one, and it removes the need for the
# reader to verify the placement by hand after every rebuild.
#
# Only meaningful under sudo. A root shell running the script straight from a
# checkout is a development case, not a deployment.
assert_script_is_root_owned() {
	[ -n "${SUDO_USER:-}${SUDO_UID:-}" ] || return 0

	local path uid mode
	path="${BASH_SOURCE[0]}"
	[ -e "$path" ] || return 0

	uid="$(stat -c %u "$path")"
	[ "$uid" = "0" ] ||
		die "$path must be owned by root (found uid $uid). The sudoers entry points at a file the unprivileged user can write, which is a privilege escalation path: copy the script to /usr/local/bin at image build time."

	mode="$(stat -c %a "$path")"
	[ "$((0${mode} & 022))" -eq 0 ] ||
		die "$path must not be group or world writable (mode $mode)"
	return 0
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "must run as root (sudo /usr/local/bin/$SCRIPT_NAME)"
}

require_commands() {
	local cmd
	for cmd in iptables iptables-restore ipset jq curl dig ip; do
		command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
	done
	command -v aggregate >/dev/null 2>&1 || warn "aggregate not found, GitHub ranges will not be compacted"
}

# DNS is pinned to the resolvers the container was actually given, which is not
# always the Docker embedded one: 127.0.0.11 only appears on user defined
# networks, while a container on the default bridge gets the host's resolver
# written straight into resolv.conf. Pinning to whatever is configured keeps the
# property that matters - queries may only go to the assigned resolver, never to
# an arbitrary external nameserver.
#
# resolv.conf is root owned and written by Docker; the unprivileged user cannot
# point this at a resolver of its choosing. Addresses are validated anyway
# before they reach iptables.
detect_resolvers() {
	local addr declared=0

	while read -r addr; do
		declared=$((declared + 1))
		is_ipv4 "$addr" || continue
		RESOLVERS+=("$addr")
	done < <(awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF" 2>/dev/null)

	if [ "${#RESOLVERS[@]}" -eq 0 ]; then
		if [ "$declared" -gt 0 ]; then
			die "$RESOLV_CONF declares only non-IPv4 nameservers; IPv6 egress is dropped by design, so name resolution would break"
		fi
		die "no nameserver found in $RESOLV_CONF; refusing to run without a resolver to pin DNS to"
	fi

	local resolver
	for resolver in "${RESOLVERS[@]}"; do
		if [ "$resolver" = "$DOCKER_EMBEDDED_RESOLVER" ]; then
			info "DNS pinned to the Docker embedded resolver ($resolver)"
			return 0
		fi
	done

	# Reachable over the network rather than through the container's own
	# namespace, so it is worth saying out loud.
	warn "DNS pinned to $(join_sp "${RESOLVERS[@]}") (not the Docker embedded resolver)."
	warn "This container is not on a user defined Docker network. See the README for the stronger setup."
}

# --- allowlist construction --------------------------------------------------

# The live set is only ever referenced by name from the rules; its contents are
# rebuilt in a staging set and swapped in atomically. Nothing observes a
# partially populated allowlist, and the rebuild does not depend on the previous
# contents, which is what makes repeated runs converge.
prepare_allowset() {
	# On the very first run the live set has to exist before any rule can
	# reference it. Creating it empty is harmless: the rules are not installed
	# until after the swap.
	ipset create -exist "$SET_V4" hash:net family inet maxelem 262144
	ipset destroy "$SET_V4_STAGING" 2>/dev/null || true
	ipset create "$SET_V4_STAGING" hash:net family inet maxelem 262144

	# Deliberately NOT recreated: the point is to accumulate across runs. Entries
	# expire on their own through the set's timeout.
	if ! ipset create -exist "$SET_V4_AUDIT" hash:ip family inet \
		timeout "$AUDIT_TIMEOUT" maxelem 65536 2>/dev/null; then
		warn "could not create $SET_V4_AUDIT; blocked destinations will not be recorded"
		AUDIT_RECORDER=0
	fi
}

commit_allowset() {
	ipset swap "$SET_V4_STAGING" "$SET_V4"
	ipset destroy "$SET_V4_STAGING"
}

allowset_add() {
	local entry="$1"
	ipset add -exist "$SET_V4_STAGING" "$entry"
}

# resolve_domain <name> -> prints validated IPv4 addresses, one per line
resolve_domain() {
	local name="$1" out=""
	out="$(dig +short +time=2 +tries=1 A "$name" 2>/dev/null || true)"
	if [ -z "$out" ] && command -v getent >/dev/null 2>&1; then
		out="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true)"
	fi
	local ip
	while read -r ip; do
		[ -n "$ip" ] || continue
		is_ipv4 "$ip" || continue
		printf '%s\n' "$ip"
	done < <(printf '%s\n' "$out")
}

# add_domain <name> -> 0 when at least one address was added
add_domain() {
	local name="$1" added=0 rejected=0 ip

	while read -r ip; do
		# A name is not allowed to smuggle a private address into the allowlist.
		# allowCidrs is checked against the same ranges; without this the DNS
		# path would be a way around that check.
		if is_forbidden_ipv4 "$ip"; then
			warn "$name resolved to $ip, which is in a forbidden range; that address is not allowed"
			rejected=1
			continue
		fi
		allowset_add "$ip"
		added=1
	done < <(resolve_domain "$name")

	if [ "$added" = "0" ]; then
		if [ "$rejected" = "1" ]; then
			warn "$name resolved only to forbidden addresses, skipping"
		else
			warn "failed to resolve $name, skipping"
		fi
		return 1
	fi
	info "allowed $name"
	return 0
}

# Runs after the real table is in place, because reaching the meta API needs the
# egress that only that table grants. Purely additive and best effort: the core
# GitHub hosts are already in the set from DNS, so a failure here costs the
# extra ranges and nothing else.
add_github_meta_ranges() {
	local meta cidr count=0
	meta="$(curl -fsS --connect-timeout 5 --max-time 15 https://api.github.com/meta 2>/dev/null || true)"

	if [ -z "$meta" ] || ! jq -e '.web and .api and .git' >/dev/null 2>&1 <<<"$meta"; then
		warn "GitHub meta API unavailable; only the DNS resolved GitHub hosts are allowed"
		return 0
	fi

	# The jq filter selects the address family: `^[0-9]` alone would let
	# 2606:...-style IPv6 prefixes through. It is a filter, not a validator - a
	# string like 999999999999999999.1.1.1/32 passes it too - so nothing here is
	# trusted beyond "this is meant to be an IPv4 prefix".
	#
	# Reading the whole extraction into a variable first is what makes a partial
	# response visible. As a process substitution feeding `while read`, a jq that
	# died halfway just ended the loop, and the run reported the ranges it did get
	# as though that were all of them.
	local raw jq_rc=0
	raw="$(printf '%s' "$meta" |
		jq -r '(.web + .api + .git)[] | select(type == "string") | select(test("^[0-9]+[.]"))')" ||
		jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		warn "the GitHub meta response could not be read to the end; allowing only the ranges that were readable"
	fi

	# validate_cidr runs BEFORE aggregate, not after. aggregate is an external
	# command with build-dependent behaviour, and handing it input it does not
	# understand makes the outcome depend on which one is installed.
	local -a ranges=()
	local rejected=0
	while read -r cidr; do
		[ -n "$cidr" ] || continue
		if validate_cidr "$cidr"; then
			ranges+=("$cidr")
		else
			rejected=$((rejected + 1))
		fi
	done <<<"$raw"

	local compacted
	if [ "${#ranges[@]}" -eq 0 ]; then
		compacted=""
	elif command -v aggregate >/dev/null 2>&1; then
		local agg_rc=0
		compacted="$(printf '%s\n' "${ranges[@]}" | aggregate -q)" || agg_rc=$?
		if [ "$agg_rc" -ne 0 ]; then
			warn "aggregate failed on the GitHub meta ranges; allowing them uncompacted"
			compacted="$(printf '%s\n' "${ranges[@]}")"
		fi
	else
		compacted="$(printf '%s\n' "${ranges[@]}")"
	fi

	# Re-validated on the way out. aggregate merges prefixes, so its output is not
	# the input, and only checked values may reach the set.
	while read -r cidr; do
		[ -n "$cidr" ] || continue
		if validate_cidr "$cidr"; then
			ipset add -exist "$SET_V4" "$cidr"
			count=$((count + 1))
		else
			rejected=$((rejected + 1))
		fi
	done <<<"$compacted"

	info "allowed $count GitHub ranges from the meta API"
	# Silence here would read as "everything on offer was allowed". The set is
	# additive and the core hosts are already in it from DNS, so a short list is
	# survivable - being unable to tell it apart from a complete one is not.
	if [ "$rejected" -gt 0 ]; then
		warn "$rejected GitHub meta entries did not pass CIDR validation and were not allowed"
	fi
}

# Name resolution only. Everything here works under the bootstrap policy, which
# permits the Docker resolver and nothing else.
build_allowlist() {
	local domain anchor resolved_anchor=0
	anchor="$(anchor_domain)"

	for domain in "${PROFILE_DOMAINS[@]:-}"; do
		[ -n "$domain" ] || continue
		if add_domain "$domain"; then
			[ "$domain" = "$anchor" ] && resolved_anchor=1
		fi
	done

	for domain in "${CFG_DOMAINS[@]:-}"; do
		[ -n "$domain" ] || continue
		if add_domain "$domain"; then
			[ "$domain" = "$anchor" ] && resolved_anchor=1
		fi
	done

	# Checked after both lists rather than after the base profile, because with
	# no bundle selected the anchor comes from allowDomains and does not exist
	# yet at the earlier point.
	if [ -n "$anchor" ]; then
		[ "$resolved_anchor" = "1" ] ||
			die "the anchor domain did not resolve ($anchor); the container has no working network"
	else
		# A policy of nothing but CIDRs and host ports has no name to resolve, so
		# there is no way to tell a dead network from an empty allowlist. Saying
		# so is better than inventing a domain to probe.
		warn "no domain is configured, so DNS liveness could not be checked"
	fi

	local cidr
	for cidr in "${CFG_CIDRS[@]:-}"; do
		[ -n "$cidr" ] || continue
		allowset_add "$cidr"
		info "allowed $cidr"
	done
}

# --- rule application --------------------------------------------------------

# log_line <chain> <prefix> [match...]
#
# The match has to be repeated from the rule being logged. A LOG rule with no
# match logs every packet on the chain and burns the rate limit on ordinary
# traffic, which hides the very drops it is meant to record.
log_line() {
	local chain="$1" prefix="$2"
	shift 2
	# The global IFS is $'\n\t', so "$*" would join the match with newlines and
	# split one rule across several lines. Join with spaces explicitly.
	local IFS=' '
	local match=""
	[ "$#" -gt 0 ] && match="$* "
	printf '%s\n' "-A $chain ${match}-m limit --limit $LOG_LIMIT --limit-burst $LOG_BURST -j LOG --log-prefix \"$prefix\" --log-level 4"
}

# emit_dns_pinning <with_recorder>
emit_dns_pinning() {
	local with_recorder="$1"

	# Only the assigned resolvers may be queried; port 53 to anywhere else is a
	# tunnelling attempt. A query to the Docker embedded resolver leaves through
	# lo and is already accepted by the loopback rule, so the explicit rule below
	# covers the DNAT'ed path.
	local resolver
	for resolver in "${RESOLVERS[@]}"; do
		printf '%s\n' "-A OUTPUT -d $resolver/32 -p udp --dport 53 -j ACCEPT"
		printf '%s\n' "-A OUTPUT -d $resolver/32 -p tcp --dport 53 -j ACCEPT"
	done

	# These DROPs sit in front of the allowlist, so without a recorder of their
	# own an attempt to reach an external nameserver would leave no trace at all
	# - and that attempt is the single most interesting signal the set can hold.
	# Only packets that got past the resolver ACCEPTs above reach this point.
	if [ "$with_recorder" = "1" ]; then
		printf '%s\n' "-A OUTPUT -p udp --dport 53 -j SET --add-set $SET_V4_AUDIT dst --exist"
		printf '%s\n' "-A OUTPUT -p tcp --dport 53 -j SET --add-set $SET_V4_AUDIT dst --exist"
	fi

	log_line OUTPUT "fw-dns-drop: " -p udp --dport 53
	printf '%s\n' "-A OUTPUT -p udp --dport 53 -j DROP"
	log_line OUTPUT "fw-dns-drop: " -p tcp --dport 53
	printf '%s\n' "-A OUTPUT -p tcp --dport 53 -j DROP"
}

# Installed before the script uses the network at all, so that every name
# resolution and every fetch this run performs already happens under a closed
# policy. It permits exactly what the rebuild needs: loopback, the Docker
# resolver and the sessions that are already open.
emit_bootstrap_v4() {
	printf '%s\n' "*filter"
	printf '%s\n' ":INPUT DROP [0:0]"
	printf '%s\n' ":FORWARD DROP [0:0]"
	printf '%s\n' ":OUTPUT DROP [0:0]"
	printf '%s\n' "-A INPUT -i lo -j ACCEPT"
	printf '%s\n' "-A OUTPUT -o lo -j ACCEPT"
	# No recorder here. The SET target depends on an optional kernel module, and
	# a rejected bootstrap transaction is fatal - the final table has a fallback,
	# this one does not.
	emit_dns_pinning 0
	printf '%s\n' "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
	printf '%s\n' "-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
	if [ -n "$SSHD_PORT" ]; then
		printf '%s\n' "-A INPUT -p tcp --dport $SSHD_PORT -m conntrack --ctstate NEW -j ACCEPT"
	fi
	printf '%s\n' "COMMIT"
}

emit_filter_v4() {
	local out_policy="DROP"
	[ "$MODE" = "audit" ] && out_policy="ACCEPT"

	printf '%s\n' "*filter"
	printf '%s\n' ":INPUT DROP [0:0]"
	printf '%s\n' ":FORWARD DROP [0:0]"
	printf '%s\n' ":OUTPUT $out_policy [0:0]"

	printf '%s\n' "-A INPUT -i lo -j ACCEPT"
	printf '%s\n' "-A OUTPUT -o lo -j ACCEPT"

	# DNS pinning comes before the generic ESTABLISHED accept on purpose: a
	# conntrack entry created before this script ran would otherwise keep an
	# external DNS tunnel alive across the policy change.
	emit_dns_pinning "$AUDIT_RECORDER"

	printf '%s\n' "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
	printf '%s\n' "-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

	# Inbound: nothing new is accepted unless the configuration named an sshd
	# port, in which case that one port is opened; everything else is covered by
	# the established rule above. An accepted inbound connection also makes the
	# container's replies on it ESTABLISHED, and the OUTPUT accept above lets
	# those out without consulting the allowlist, so the open port is a channel
	# out as much as in. That is why it has to be asked for.
	if [ -n "$SSHD_PORT" ]; then
		printf '%s\n' "-A INPUT -p tcp --dport $SSHD_PORT -m conntrack --ctstate NEW -j ACCEPT"
	fi

	# Host gateway is closed by default; the host carries the Tailscale network
	# so a blanket allow would be a lateral movement path.
	if [ "${#CFG_HOST_PORTS[@]}" -gt 0 ] && [ "${#HOST_TARGETS[@]}" -gt 0 ]; then
		local target port
		for target in "${HOST_TARGETS[@]}"; do
			for port in "${CFG_HOST_PORTS[@]}"; do
				printf '%s\n' "-A OUTPUT -d $target/32 -p tcp --dport $port -j ACCEPT"
			done
		done
	fi

	printf '%s\n' "-A OUTPUT -m set --match-set $SET_V4 dst -j ACCEPT"

	# Non-terminating: the packet carries on to the LOG/REJECT rules below. Only
	# destinations that got past the allowlist reach this point, so the set ends
	# up holding exactly the addresses a policy author needs to look at.
	if [ "$AUDIT_RECORDER" = "1" ]; then
		printf '%s\n' "-A OUTPUT -j SET --add-set $SET_V4_AUDIT dst --exist"
	fi

	if [ "$MODE" = "audit" ]; then
		# Log what would have been dropped, but let it through so the policy can
		# be grown from real traffic.
		log_line OUTPUT "fw-audit: "
	else
		log_line OUTPUT "fw-drop: "
		printf '%s\n' "-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited"
	fi

	printf '%s\n' "COMMIT"
}

emit_filter_v6() {
	printf '%s\n' "*filter"
	printf '%s\n' ":INPUT DROP [0:0]"
	printf '%s\n' ":FORWARD DROP [0:0]"
	printf '%s\n' ":OUTPUT DROP [0:0]"
	printf '%s\n' "-A INPUT -i lo -j ACCEPT"
	printf '%s\n' "-A OUTPUT -o lo -j ACCEPT"
	printf '%s\n' "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

	# No IPv6 allowlist by design: the ipset is v4 only and every v6 destination
	# is refused, in audit mode too. Logged so an audit run still shows what
	# tried to leave over v6.
	log_line OUTPUT "fw-drop6: "

	# REJECT rather than relying on the DROP policy, which is what IPv4 does for
	# unlisted destinations. A silent DROP makes an allowed host that also has a
	# AAAA record reachable only after a timeout: address selection (RFC 6724)
	# tries IPv6 first, gets no answer, and how long the client waits before
	# falling back to IPv4 depends on whether it implements Happy Eyeballs. That
	# hands the reachability of a correctly allowed host to the client library.
	# An explicit refusal makes the fallback immediate and costs nothing - the
	# ICMPv6 is generated locally and delivered to the local socket, so nothing
	# reaches the wire.
	#
	# The chain policy stays DROP so that a rejected transaction still fails
	# closed. The panic table keeps the silent drop on both families: fast
	# failure is worth an explicit refusal in normal operation, but the panic
	# table is the state where the fewest assumptions should hold.
	printf '%s\n' "-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited"
	printf '%s\n' "COMMIT"
}

# Phase one: shut the container before this script sends a single packet.
#
# IPv6 goes straight to its final state because it has no allowlist to build,
# which also removes the gap that would otherwise exist between the IPv4 and
# IPv6 transactions - the two families cannot be switched in one transaction
# with iptables. IPv4 gets the bootstrap table until the allowlist is ready.
close_network() {
	if [ "$IPV6_CONTROL" = "1" ]; then
		emit_filter_v6 | ip6tables-restore ||
			die "ip6tables-restore rejected the generated filter table"
	fi

	emit_bootstrap_v4 | iptables-restore ||
		die "iptables-restore rejected the bootstrap filter table"

	info "network closed; building the allowlist under the bootstrap policy"
}

# Phase two: swap the finished allowlist in and install the real table.
#
# iptables-restore replaces only the tables named in its input, so nat and
# mangle - and with them Docker's DNS DNAT - are untouched. The swap happens
# while the bootstrap table is live, and that table does not reference the set,
# so no rule ever sees a half built allowlist.
apply_rules() {
	commit_allowset

	# The SET target is the one part of the table that depends on an optional
	# kernel module. If it is unavailable the whole transaction is rejected, so
	# fall back to a table without the recorder rather than fail the run.
	if ! emit_filter_v4 | iptables-restore 2>/dev/null; then
		if [ "$AUDIT_RECORDER" = "1" ]; then
			warn "the filter table was rejected; retrying without the blocked-destination recorder"
			AUDIT_RECORDER=0
		fi
		emit_filter_v4 | iptables-restore ||
			die "iptables-restore rejected the generated filter table"
	fi

	if [ "${#CFG_HOST_PORTS[@]}" -gt 0 ] && [ "${#HOST_TARGETS[@]}" -gt 0 ]; then
		info "allowed host $(join_sp "${HOST_TARGETS[@]}") on ports: $(join_sp "${CFG_HOST_PORTS[@]}")"
	fi
}

detect_host_gateway() {
	# awk without `exit` and no `head`: both would close the pipe early and kill
	# the writer with SIGPIPE under `set -o pipefail`.
	HOST_GATEWAY="$(first_line "$(ip route show default 2>/dev/null | awk '/^default/ {print $3}')")"
	if [ -n "$HOST_GATEWAY" ] && ! is_ipv4 "$HOST_GATEWAY"; then
		HOST_GATEWAY=""
	fi
	# Not fatal on its own: host.docker.internal may still resolve. The decision
	# is made in resolve_host_targets, once both candidates are known.
	if [ -z "$HOST_GATEWAY" ] && [ "${#CFG_HOST_PORTS[@]}" -gt 0 ]; then
		warn "the default gateway could not be detected; falling back to $HOST_INTERNAL_NAME for allowHostPorts"
	fi
}

# Addresses that allowHostPorts opens. Runs under the bootstrap policy, after
# the network is closed: host.docker.internal comes from /etc/hosts on the
# default bridge and from the embedded resolver on a user defined network, and
# both paths are available there.
resolve_host_targets() {
	HOST_TARGETS=()
	[ "${#CFG_HOST_PORTS[@]}" -gt 0 ] || return 0

	[ -n "$HOST_GATEWAY" ] && HOST_TARGETS+=("$HOST_GATEWAY")

	local ip known
	while read -r ip; do
		[ -n "$ip" ] || continue
		if ! is_plausible_host_address "$ip"; then
			warn "$HOST_INTERNAL_NAME resolved to $ip, which is not a private address; refusing to open a port there"
			continue
		fi
		for known in "${HOST_TARGETS[@]}"; do
			[ "$known" = "$ip" ] && continue 2
		done
		HOST_TARGETS+=("$ip")
		info "host gateway candidate $ip ($HOST_INTERNAL_NAME)"
	done < <(resolve_domain "$HOST_INTERNAL_NAME")

	[ "${#HOST_TARGETS[@]}" -gt 0 ] ||
		die "allowHostPorts is set but neither the default gateway nor $HOST_INTERNAL_NAME could be resolved"
}

# --- self verification -------------------------------------------------------

VERIFY_FAILED=0

verify_step() {
	local label="$1" expect="$2" # expect = pass | fail
	shift 2
	local rc=0
	"$@" >/dev/null 2>&1 || rc=$?

	if { [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; } ||
		{ [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; }; then
		info "verify OK: $label"
	else
		err "verify FAILED: $label (exit=$rc, expected $expect)"
		VERIFY_FAILED=1
	fi
}

has_global_ipv6() {
	# `grep -q` exits on the first match and would SIGPIPE the writer, so buffer
	# the output first.
	local out
	out="$(ip -6 addr show scope global 2>/dev/null || true)"
	case "$out" in
	*inet6*) return 0 ;;
	*) return 1 ;;
	esac
}

# `dig` exits 0 on NXDOMAIN and SERVFAIL alike, so exit status alone proves
# nothing. Success means an actual address came back.
dns_answers() {
	local server="$1" name="$2" out
	if [ -n "$server" ]; then
		out="$(dig +short +time=2 +tries=1 "@$server" A "$name" 2>/dev/null || true)"
	else
		out="$(dig +short +time=2 +tries=1 A "$name" 2>/dev/null || true)"
	fi
	local line
	while read -r line; do
		is_ipv4 "$line" && return 0
	done < <(printf '%s\n' "$out")
	return 1
}

# Addresses of a name that are eligible for the allowlist, i.e. exactly what
# add_domain would have installed.
#
# Self verification has to use this rather than resolve_domain: a domain whose
# answers are all in a forbidden range is a warn-and-continue case when the
# allowlist is built, so treating it as a verification failure here would turn
# the same situation into a panic.
allowlistable_addresses() {
	local name="$1" ip
	while read -r ip; do
		[ -n "$ip" ] || continue
		is_forbidden_ipv4 "$ip" && continue
		printf '%s\n' "$ip"
	done < <(resolve_domain "$name")
}

# True when at least one of the given addresses is in the allowlist.
#
# Deliberately not "the first address must be in the set". A large CDN behind
# DNS round robin returns a different subset of its addresses on every query, so
# comparing one address picked at build time against one picked at verify time
# fails at random on a policy that is entirely correct - and a failed
# verification takes the container down with it.
any_in_allowset() {
	local ip
	while read -r ip; do
		[ -n "$ip" ] || continue
		if ipset test "$SET_V4" "$ip" >/dev/null 2>&1; then
			return 0
		fi
	done < <(printf '%s\n' "$1")
	return 1
}

# Prints the first probe host whose addresses are all outside the allowlist, or
# nothing when every candidate turns out to be allowed.
pick_blocked_probe() {
	local candidate ip
	for candidate in "${EGRESS_PROBES[@]}"; do
		local blocked=1 resolved=0
		while read -r ip; do
			[ -n "$ip" ] || continue
			resolved=1
			if ipset test "$SET_V4" "$ip" >/dev/null 2>&1; then
				blocked=0
				break
			fi
		done < <(resolve_domain "$candidate")
		if [ "$resolved" = "1" ] && [ "$blocked" = "1" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 0
}

self_verify() {
	info "running self verification"

	# The same anchor the allowlist was built against, so that a policy which
	# left the anthropic bundle out is not checked against a domain it never
	# asked for.
	local anchor
	anchor="$(anchor_domain)"

	if [ -n "$anchor" ]; then
		verify_step "DNS via the assigned resolver returns an answer" pass \
			dns_answers "" "$anchor"
	else
		warn "verify SKIP: DNS resolution (no domain is configured to resolve)"
	fi

	# Probing a configured resolver would prove nothing, so pick one that is not.
	local probe="" candidate resolver
	for candidate in "${DNS_PROBES[@]}"; do
		for resolver in "${RESOLVERS[@]}"; do
			[ "$candidate" = "$resolver" ] && continue 2
		done
		probe="$candidate"
		break
	done
	if [ -n "$probe" ]; then
		verify_step "external DNS (dig @$probe) returns nothing" fail \
			dns_answers "$probe" "${EGRESS_PROBES[0]}"
	else
		warn "verify SKIP: every DNS probe address is also a configured resolver"
	fi
	if [ -n "$anchor" ]; then
		verify_step "allowed host is reachable ($anchor)" pass \
			curl -sS -o /dev/null --connect-timeout 5 --max-time 15 "https://$anchor/"
	else
		warn "verify SKIP: allowed host reachability (no domain is configured to reach)"
	fi

	if [ "$MODE" = "enforce" ]; then
		# The probe has to be a host that is genuinely outside the allowlist.
		# Hardcoding one breaks the moment a project adds it to allowDomains -
		# a correct configuration would then fail the self check.
		local egress_probe=""
		egress_probe="$(pick_blocked_probe)"
		if [ -n "$egress_probe" ]; then
			verify_step "unlisted host is blocked ($egress_probe)" fail \
				curl -sS -o /dev/null --connect-timeout 5 --max-time 10 "https://$egress_probe"
		else
			warn "verify SKIP: every egress probe host is in the allowlist, so none can prove that unlisted hosts are blocked"
		fi
	else
		info "verify SKIP: unlisted host reachability (audit mode allows it by design)"
	fi

	# Project specific entries are checked against the ipset rather than by
	# connecting: they are frequently non HTTP services (databases and such).
	local domain checked=0 configured=0 addrs
	for domain in "${CFG_DOMAINS[@]:-}"; do
		[ -n "$domain" ] || continue
		configured=1
		[ "$checked" = "1" ] && break
		addrs="$(allowlistable_addresses "$domain")"
		[ -n "$addrs" ] || continue
		verify_step "firewall.json domain $domain is in the allowlist" pass \
			any_in_allowset "$addrs"
		checked=1
	done
	if [ "$configured" = "1" ] && [ "$checked" = "0" ]; then
		# Not a failure: per spec a domain that will not resolve is a warn and
		# continue case. It must be visible rather than silently skipped.
		warn "verify SKIP: none of the ${#CFG_DOMAINS[@]} firewall.json domains resolved, so none could be checked"
	fi

	local cidr
	for cidr in "${CFG_CIDRS[@]:-}"; do
		[ -n "$cidr" ] || continue
		verify_step "firewall.json cidr $cidr is in the allowlist" pass \
			ipset test "$SET_V4" "${cidr%/*}"
		break
	done

	if has_global_ipv6; then
		verify_step "IPv6 egress is blocked" fail \
			curl -6 -sS -o /dev/null --connect-timeout 5 --max-time 10 https://example.com
	else
		info "verify SKIP: IPv6 egress (no global IPv6 address on this container)"
	fi

	[ "$VERIFY_FAILED" -eq 0 ] || die "self verification failed; the policy is in place but the environment is not as expected"
	info "self verification passed"
}

# --- allowlist listing --------------------------------------------------------

# print_list <label>, entries on stdin one per line
#
# Prints a section of the listing. An empty section is spelled out as "(none)"
# rather than left blank, so that "nothing is configured here" and "the output
# was cut off" cannot look the same to whoever is reading it.
#
# Entries arrive on stdin rather than as arguments because the caller's arrays
# are frequently empty, and "${arr[@]}" under `set -u` is the kind of expansion
# that turns an empty section into a stray blank entry.
print_list() {
	local label="$1" line count=0
	printf '%s:\n' "$label"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		printf '  %s\n' "$line"
		count=$((count + 1))
	done
	[ "$count" -gt 0 ] || printf '  %s\n' "(none)"
	return 0
}

# Writes the policy that an apply would install, without applying anything.
#
# This resolves no names and fetches nothing: the whole point is that an agent
# can ask what it is allowed to reach without that question itself needing
# egress, and without root. What it cannot show is the GitHub meta ranges, which
# only exist after a fetch - hence the note at the bottom.
print_allowlist() {
	printf 'mode: %s\n' "$MODE"
	printf 'profile: %s\n' "$(profile_label)"

	# The two sources are merged, sorted and deduplicated: which of them a domain
	# came from is not something the reader can act on, and a project that also
	# lists a bundle domain should not see it twice.
	printf '%s\n' "${PROFILE_DOMAINS[@]:-}" "${CFG_DOMAINS[@]:-}" |
		LC_ALL=C sort -u | print_list "domains"

	# CIDRs and host ports keep the order they were written in. There is no
	# second source to merge them with, and an author looking for the entry they
	# added finds it where they put it.
	printf '%s\n' "${CFG_CIDRS[@]:-}" | print_list "cidrs"
	printf '%s\n' "${CFG_HOST_PORTS[@]:-}" | print_list "hostPorts"

	if profile_has_bundle github; then
		printf '\n'
		printf '%s\n' "Note: when the github bundle is selected, CIDR ranges from the GitHub meta API"
		printf '%s\n' "are also allowed at apply time. They are not listed here."
	fi
	return 0
}

# --- entry point -------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [--check-config] [--print-allowlist] [--config <path>]
                                [--resolv-conf <path>]

  (no arguments)      apply the firewall policy (requires root). The policy is
                      read from $PROD_CONFIG and
                      nowhere else; there is no search.
  --check-config      validate the configuration and exit without touching any
                      rule (safe to run unprivileged)
  --print-allowlist   print the policy that an apply would install and exit.
                      Resolves nothing and fetches nothing, so it works from
                      inside a container whose egress is already closed.
  --config <path>     read this file instead of the fixed one. Combined with
                      --check-config this validates the copy in the repo before
                      an image rebuild installs it.
  --resolv-conf <p>   read resolvers from this file instead of $DEFAULT_RESOLV_CONF

These options exist for development and testing, and are refused when the script
is invoked through sudo. In production the configuration is always the root
owned file at the fixed path: a firewall.json the container's own user can write
is not a policy, because the user is the adversary this script defends against.
The copy in the repo is the source for it and takes effect on image rebuild.

The sudoers entry must spell out the empty argument list:

  node ALL=(root) NOPASSWD: /usr/local/bin/$SCRIPT_NAME ""

A Cmnd written without arguments permits ANY arguments in sudoers, which is the
opposite of what this script wants.
EOF
}

main() {
	local check_only=0 print_only=0 config_from_option=0

	# Belt and braces for the sudoers rule above: even if it is written without
	# the empty argument list, the options stay out of reach of the unprivileged
	# user, and the configuration keeps coming from the fixed path.
	if [ "$#" -gt 0 ] && [ -n "${SUDO_USER:-}${SUDO_UID:-}" ]; then
		die "options are not accepted through sudo; run $SCRIPT_NAME with no arguments"
	fi

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--check-config)
			check_only=1
			shift
			;;
		--print-allowlist)
			print_only=1
			shift
			;;
		--config)
			[ "$#" -ge 2 ] || die "--config requires a path"
			CONFIG_FILE="$2"
			config_from_option=1
			shift 2
			;;
		--resolv-conf)
			[ "$#" -ge 2 ] || die "--resolv-conf requires a path"
			RESOLV_CONF="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
		esac
	done

	command -v jq >/dev/null 2>&1 || die "required command not found: jq"

	# Installed before anything touches the network. It only acts once
	# APPLY_PHASE is set, so --check-config and a run by the wrong user still
	# exit without modifying any rule.
	trap on_exit EXIT

	# Without --config both modes read the same fixed file, so --check-config
	# reports on exactly what an apply would use. Nothing is searched for.
	[ -n "$CONFIG_FILE" ] || { [ -f "$PROD_CONFIG" ] && CONFIG_FILE="$PROD_CONFIG"; }

	if [ "$check_only" = "1" ]; then
		[ -z "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "no such file: $CONFIG_FILE"
		read_config
		info "configuration is valid (${CONFIG_FILE:-base profile only})"
		exit 0
	fi

	if [ "$print_only" = "1" ]; then
		[ -z "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "no such file: $CONFIG_FILE"
		# The configuration goes through exactly the same validation as an apply,
		# so a listing is never produced from a file that would be refused. Its
		# progress lines go to stderr: the listing is meant to be read by whatever
		# asked for it, and mixing the two would make it parse-hostile.
		read_config >&2
		print_allowlist
		exit 0
	fi

	require_root
	require_commands

	# From here on, any failure ends in the panic policy rather than in an open
	# network - and that deliberately includes the configuration.
	#
	# The apply phase used to start after the configuration had been read and
	# validated, on the reasoning that a config error should not disturb a
	# container whose rules were already in place. That reasoning only holds on a
	# re-apply. On the very first boot the "previous" policy is the default
	# ACCEPT everything, so exiting early left the container wide open - the one
	# outcome this script exists to prevent. A rejected configuration now closes
	# the container instead. `--check-config` exists so that a typo is caught
	# before the image is rebuilt.
	APPLY_PHASE=1

	assert_script_is_root_owned

	# Only the fixed path is verified: --config is a development escape hatch
	# that sudo already refuses, so requiring root ownership there would only
	# get in the way of checking a file before it is installed.
	[ "$config_from_option" = "1" ] || assert_config_is_root_owned "$CONFIG_FILE"
	[ -z "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "no such file: $CONFIG_FILE"
	read_config

	detect_resolvers
	require_ipv6_control

	detect_host_gateway
	prepare_allowset

	# Close first, build second: from this point on the container cannot reach
	# anything but the Docker resolver, so no part of the rebuild depends on an
	# open network and an abrupt kill can only leave a closed policy behind.
	close_network
	build_allowlist
	resolve_host_targets
	apply_rules

	# Only now, with the real table live, is api.github.com reachable - and only
	# when the github bundle put it in the allowlist in the first place. Calling
	# it unconditionally would warn that the meta API is unavailable on every run
	# of a policy that deliberately left GitHub out, which trains the reader to
	# ignore the one message that means the ranges really are missing.
	if profile_has_bundle github; then
		add_github_meta_ranges
	fi

	info "policy applied (mode=$MODE, entries=$(ipset list "$SET_V4" | awk '/^Number of entries/ {print $NF}'))"
	if [ "$AUDIT_RECORDER" = "1" ]; then
		info "blocked destinations are recorded in ipset $SET_V4_AUDIT (ipset list $SET_V4_AUDIT)"
	fi

	self_verify

	info "firewall configuration complete"
}

# Sourcing the script exposes the validation helpers to the test suite without
# applying anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
