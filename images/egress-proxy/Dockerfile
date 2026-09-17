# egress-proxy — prebuilt L7 sidecar image for egress-guard's `layer: "l7"`.
#
# squid の据え方 (非 root、-N、ACL の場所、mgr 拒否、dstdomain -n) はここに
# 焼き込み、利用側に残すのは firewall.json から ACL と mode を焼く操作
# (egress-proxy-bake) だけにする。詳しい経緯は
# docs/archive/egress-guard-design.md §2.23、squid.conf 自体の個々の設定行
# の理由はそのファイルのコメントを参照。
#
# 2 ステージ。builder は npm から egress-guard を取ってきて
# init-project-firewall.sh を取り出すためだけに存在し、firewall.json には
# 一切触れない (それは利用側が RUN egress-proxy-bake で行う)。
#
# ARG はファイル先頭のグローバルスコープに置く。監視 (.github/workflows/
# monitor.yml) が `^ARG EGRESS_GUARD_VERSION=` の形で読むため。
ARG EGRESS_GUARD_VERSION=0.4.0

FROM node:24-bookworm-slim AS builder

# Pinned for the same reason the egress-guard README pins it in the main
# Dockerfile: this runs code at image build time, and a dist-tag would let a
# package update change what that code does without anyone choosing to.
ARG EGRESS_GUARD_VERSION
RUN npm install -g @himorogy/egress-guard@${EGRESS_GUARD_VERSION} \
    && cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
        /usr/local/bin/init-project-firewall.sh \
    && chmod 755 /usr/local/bin/init-project-firewall.sh

FROM debian:bookworm-slim

# --no-install-recommends keeps out cachemgr's cgi and the other pieces this
# CONNECT-only, no-ssl_bump configuration never exercises but that would
# otherwise still ship in the image. jq is the only external command
# --print-proxy-acl and egress-proxy-bake use; bash is already part of the
# base image's essential set (init-project-firewall.sh has a bash shebang).
RUN apt-get update \
    && apt-get install -y --no-install-recommends squid jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# read_only: true at the container level (see 0036's compose example) means
# /var/spool/squid and /run have to exist before the tmpfs mounts land on
# top of them at startup; /var/log/squid is the mount point for the named
# volume the access log lives on. Nothing is written into the image layer.
RUN mkdir -p /var/spool/squid /var/log/squid /run

COPY --from=builder /usr/local/bin/init-project-firewall.sh /usr/local/bin/init-project-firewall.sh
COPY squid.conf /etc/squid/squid.conf
COPY bin/egress-proxy-bake /usr/local/bin/egress-proxy-bake

# allowed-domains.txt starts empty; egress-proxy-bake overwrites it (and
# possibly squid.conf) in the consuming image's own build. Both are
# proxy:proxy so that a `RUN egress-proxy-bake` placed after `USER proxy` in
# the consumer's Dockerfile can write them without needing write access to
# /etc/squid itself (egress-proxy-bake replaces file contents in place
# rather than renaming, precisely so this ownership is enough).
RUN chmod 755 /usr/local/bin/egress-proxy-bake \
    && touch /etc/squid/allowed-domains.txt \
    && chown proxy:proxy /etc/squid/allowed-domains.txt /etc/squid/squid.conf

EXPOSE 3128

# Runs as proxy (uid 13) from the start rather than letting Squid drop
# privileges into it: with every capability dropped at the container level,
# Squid's own privilege-drop step has nothing to drop into and segfaults.
# http_port 3128 is unprivileged, so starting here costs nothing. Consumers
# that add `RUN egress-proxy-bake` after `FROM` inherit this USER as-is.
USER proxy

ENTRYPOINT ["squid", "-N", "-f", "/etc/squid/squid.conf"]
