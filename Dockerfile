# Stage 1: system deps - Playwright Chromium deps + imagemagick convert
FROM node:22-slim AS system-deps

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0 \
    fonts-liberation ca-certificates \
    curl \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: npm deps
FROM system-deps AS npm-deps

WORKDIR /app
COPY package.json package-lock.json* ./
# Skip bundled Chromium download - we use the system binary set via PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm ci --omit=dev || npm install @duckduckgo/autoconsent

# Stage 3: final runtime image
FROM npm-deps AS runtime

ENV HOME=/root
ENV SHELL=/bin/bash
# Point playwright-core at the apt-installed Chromium so no bundled browser is needed
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

COPY .bashrc /root/.bashrc
COPY .bash_aliases /root/.bash_aliases
COPY entrypoint.sh /entrypoint.sh
COPY install.sh /install.sh
COPY uninstall.sh /uninstall.sh
COPY url2capture.sh /usr/local/lib/screenshot/url2capture.sh
RUN chmod +x /entrypoint.sh /install.sh /uninstall.sh \
    /usr/local/lib/screenshot/url2capture.sh

VOLUME ["/screenshots", "/pdfs", "/html"]
ENTRYPOINT ["/entrypoint.sh"]
