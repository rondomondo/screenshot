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
        curl \
        chromium \
        imagemagick libwebp-dev fonts-liberation fonts-noto fonts-noto-color-emoji \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

# npm deps: playwright-chromium + autoconsent. Skip bundled Chromium download; use the system
# binary via PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH instead (~630 MB saving).
WORKDIR /app
COPY package.json package-lock.json* ./
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
RUN npm install --omit=dev \
    && test -f /app/node_modules/playwright-chromium/cli.js \
    && test -f /app/node_modules/playwright-core/cli.js

RUN mkdir -p /usr/local/lib/screenshot

COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root install.sh /install.sh
COPY --chown=root:root uninstall.sh /uninstall.sh
COPY --chown=root:root ssc.py /app/ssc.py
COPY --chown=root:root url2capture.sh /usr/local/lib/screenshot/url2capture.sh

# Bake the image version into url2capture.sh so installed copies default to the correct tag.
ARG SCREENSHOT_VERSION
RUN if [ -n "$SCREENSHOT_VERSION" ]; then \
      sed -i "s/IMAGE_TAG:-latest/IMAGE_TAG:-${SCREENSHOT_VERSION}/" /usr/local/lib/screenshot/url2capture.sh; \
    fi

# Pre-warm the uv script environment so the first capture does not resolve deps.
# Drop download caches (archive, index, sdists, wheels) but keep environments-v2 so the
# pre-warmed venv survives and the first runtime invocation stays fast without a network hit.
RUN uv run --script /app/ssc.py --help > /dev/null \
    && rm -rf /root/.cache/uv/archive-v0 \
              /root/.cache/uv/simple-v16 \
              /root/.cache/uv/sdists-v9 \
              /root/.cache/uv/wheels-v5

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
