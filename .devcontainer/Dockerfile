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
ENV PNPM_HOME="/usr/local/share/pnpm"
ENV PATH="${PNPM_HOME}:${PATH}"
RUN mkdir -p "${PNPM_HOME}" && \
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

# Copy and set up firewall script.
#
# This is a copy of packages/egress-guard/scripts/init-project-firewall.sh, kept
# in sync by hand. sudoers has to name a fixed path outside the workspace, so it
# cannot point into node_modules and the package cannot be consumed as a
# dependency until it is published.
COPY init-project-firewall.sh /usr/local/bin/

# The policy that is actually enforced. It has to live outside the workspace and
# be owned by root: `node` can re-apply the firewall through sudo at any time, so
# a firewall.json `node` could write would let an injected agent set
# {"mode":"audit"} and turn enforcement off without ever obtaining root.
#
# Editing this file therefore means rebuilding the image, which is a step a human
# performs. See packages/egress-guard/docs/spec.md section 2.1.
#
# It allows chatgpt.com, api.openai.com and auth.openai.com for the codex CLI,
# and nodejs.org because node-gyp fetches headers there during setup. Drop what
# this project does not use.
COPY firewall.json /etc/egress-guard/firewall.json

USER root
RUN chown root:root /usr/local/bin/init-project-firewall.sh && \
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
