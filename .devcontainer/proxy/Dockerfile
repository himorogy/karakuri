# egress-guard L7 proxy sidecar.
#
# Two build stages. `acl` turns the project's firewall.json into the two
# things the runtime stage needs (a domain allowlist, and the mode) without
# ever touching the network or netfilter - the same guarantee
# --print-proxy-acl gives at the command line. The runtime stage never sees
# firewall.json itself, only those two derived files.
#
# Build context: the same directory as the devcontainer's main Dockerfile,
# with this file and squid.conf copied into a proxy/ subdirectory of it
# (COPY resolves against the build context root, not against this file's own
# location - hence `proxy/squid.conf` below rather than `squid.conf`). See
# the compose example this package ships.
#
# No Docker Official Image exists for Squid, hence the second stage building
# it from a Debian base rather than FROM'ing one directly.

FROM node:24-bookworm-slim AS acl

RUN apt-get update \
	&& apt-get install -y --no-install-recommends jq \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# Pinned for the same reason the egress-guard README pins it in the main
# Dockerfile: this runs code at image build time, and a dist-tag would let a
# package update change what that code does without anyone choosing to.
# The version matters here beyond pinning as such - --print-proxy-acl below
# needs a version that has that flag, and package.json in this repo names
# the lowest one that does.
RUN npm install -g @himorogy/egress-guard@0.3.0

COPY firewall.json /firewall.json

RUN eg="$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
	&& "$eg" --check-config --config /firewall.json \
	&& "$eg" --print-proxy-acl --config /firewall.json >/allowed-domains.txt \
	&& jq -r '.mode // "enforce"' /firewall.json >/mode.txt

FROM debian:bookworm-slim

# --no-install-recommends keeps out cachemgr's cgi and the other pieces this
# CONNECT-only, no-ssl_bump configuration never exercises but that would
# otherwise still ship in the image.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends squid \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# read_only: true at the container level (see the compose example) means
# /var/spool/squid and /run have to exist before the tmpfs mounts land on
# top of them at startup; /var/log/squid is the mount point for the named
# volume the access log lives on. Nothing is written into the image layer.
RUN mkdir -p /var/spool/squid /var/log/squid /run

COPY proxy/squid.conf /etc/squid/squid.conf
COPY --from=acl /allowed-domains.txt /etc/squid/allowed-domains.txt
COPY --from=acl /mode.txt /tmp/mode.txt

# The one line mode changes (see squid.conf): enforce ships as written,
# audit flips that single deny to an allow. Baked in now because Squid does
# not re-read its configuration at runtime here - changing modes takes a
# rebuild, the same as changing the allowlist does.
#
# The grep after the sed is not redundant: if squid.conf's wording of that
# line ever changes, the sed would silently match nothing and this stage
# would go on to bake an enforce image for a mode: audit config. Failing the
# build here turns that into a build-time error instead of a quiet,
# unintended (if fail-closed) change in what an audit config ships.
RUN if [ "$(cat /tmp/mode.txt)" = "audit" ]; then \
	sed -i 's/^http_access deny !allowed$/http_access allow !allowed/' /etc/squid/squid.conf \
	&& grep -q '^http_access allow !allowed$' /etc/squid/squid.conf; \
	fi \
	&& rm -f /tmp/mode.txt

EXPOSE 3128

# Runs as proxy (uid 13) from the start rather than letting Squid drop
# privileges into it: with every capability dropped at the container level,
# Squid's own privilege-drop step has nothing to drop into and segfaults.
# http_port 3128 is unprivileged, so starting here costs nothing.
USER proxy

ENTRYPOINT ["squid", "-N", "-f", "/etc/squid/squid.conf"]
