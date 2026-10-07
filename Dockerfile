# Screenshot image: python:3.12-slim + uv + Node 22 + playwright-chromium (npm)
FROM node:22-slim AS node-src

FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /uvx /usr/local/bin/
COPY --from=mikefarah/yq:4 /usr/bin/yq /usr/local/bin/yq

# Node comes from the official image so it is v22, not Debian's older nodejs package
COPY --from=node-src /usr/local/bin/node /usr/local/bin/node
COPY --from=node-src /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

ARG DEBIAN_FRONTEND=noninteractive

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make git curl wget unzip sudo jq \
        zsh procps less htop lsof \
        libmagic1 libmagic-dev \
        ca-certificates gnupg \
        imagemagick fonts-liberation \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0 \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# npm deps: playwright-chromium (provides playwright-core cli used by the MCP server) + autoconsent.
# The MCP server resolves its browser from PLAYWRIGHT_BROWSERS_PATH, so the bundled Chromium is installed there.
WORKDIR /app
COPY package.json package-lock.json* ./
ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
RUN npm install --omit=dev \
    && node /app/node_modules/playwright-core/cli.js install chromium \
    && test -f /app/node_modules/playwright-chromium/cli.js

RUN mkdir -p /usr/local/lib/screenshot

COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root install.sh /install.sh
COPY --chown=root:root uninstall.sh /uninstall.sh
COPY --chown=root:root ssc.py /app/ssc.py
COPY --chown=root:root url2capture.sh /usr/local/lib/screenshot/url2capture.sh

# Pre-warm the uv script environment so the first capture does not resolve deps
RUN uv run --script /app/ssc.py --help > /dev/null

ENV HOME=/root
ENV SHELL=/bin/bash
ENV SCREENSHOTS_DIR=/screenshots
ENV PDFS_DIR=/pdfs

COPY .bashrc /root/.bashrc
COPY .bash_aliases /root/.bash_aliases
RUN chmod +x /entrypoint.sh /install.sh /uninstall.sh \
    /usr/local/lib/screenshot/url2capture.sh

VOLUME ["/screenshots", "/pdfs", "/html"]
ENTRYPOINT ["/entrypoint.sh"]
