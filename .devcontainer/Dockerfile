FROM node:24

ARG TZ
ENV TZ="$TZ"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  shellcheck \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
#
# PATH gets ${PNPM_HOME}/bin, not ${PNPM_HOME}. pnpm 10 placed global binaries
# directly under PNPM_HOME; pnpm 11 places them under bin/. Keeping the old
# layout makes `pnpm add -g` install to a directory that is not on PATH, and
# `pnpm bin -g` fails with "global bin directory is not in PATH".
ENV PNPM_HOME="/usr/local/share/pnpm"
ENV PATH="${PNPM_HOME}/bin:${PATH}"
RUN mkdir -p "${PNPM_HOME}/bin" && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspaces /home/node/.claude /home/node/.codex && \
  chown -R node:node /workspaces /home/node/.claude /home/node/.codex 

WORKDIR /workspaces

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install
## Starship prompt
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes
## ax
RUN set -eu; \
  curl -fsSL https://ax.yusuke.run/install -o /tmp/ax-install; \
  AX_INSTALL_DIR=/usr/local/bin sh /tmp/ax-install; \
  rm /tmp/ax-install; \
  ax --version

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
RUN npm install -g pnpm

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install the firewall script from the published package.
#
# The version is pinned deliberately. The script below is placed in root-owned
# /usr/local/bin and becomes the target of a passwordless sudo rule, so following
# a dist-tag would turn any package update into code execution as root inside the
# container.
#
# npm's global prefix (/usr/local/share/npm-global) is owned by node, so the
# install runs as node. Only the placement and the permissions need root.
RUN npm install -g @himorogy/egress-guard@0.1.1

# The policy that is actually enforced. It has to live outside the workspace and
# be owned by root: `node` can re-apply the firewall through sudo at any time, so
# a firewall.json `node` could write would let an injected agent set
# {"mode":"audit"} and turn enforcement off without ever obtaining root.
#
# Editing this file therefore means rebuilding the image, which is a step a human
# performs. See packages/egress-guard/docs/spec.md section 2.1.
#
# What is allowed is the union of the base profile bundles named in firewall.json
# and its allowDomains. That list is not restated here: this comment already went
# stale once, when the bundles replaced an explicit set of domains. Read it from
# the file, or from `init-project-firewall.sh --print-allowlist`, which resolves
# nothing and works from inside a container whose egress is already closed.
#
# The one entry that needs a reason is nodejs.org in allowDomains: node-gyp
# fetches headers there during setup. Note that the openai bundle covers the
# subscription path only (auth.openai.com, chatgpt.com); api.openai.com was never
# measured and is not in it. Add it to allowDomains if this project starts using
# the API key path.
COPY firewall.json /etc/egress-guard/firewall.json

USER root
# sudoers has to name a fixed path outside the workspace, so the script is copied
# out of the global node_modules rather than referenced there: a path under
# /usr/local/share/npm-global stays writable by node, and node must not be able to
# replace the file it is allowed to run through sudo.
RUN cp "$(npm root -g)/@himorogy/egress-guard/scripts/init-project-firewall.sh" \
    /usr/local/bin/init-project-firewall.sh && \
  chown root:root /usr/local/bin/init-project-firewall.sh && \
  chmod 755 /usr/local/bin/init-project-firewall.sh && \
  chown -R root:root /etc/egress-guard && \
  chmod 755 /etc/egress-guard && \
  chmod 644 /etc/egress-guard/firewall.json && \
  # The trailing "" is required. A sudoers Cmnd written without an argument list
  # permits ANY arguments, which would hand `node` the development options.
  printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-project-firewall.sh ""\n' \
    > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

USER node
