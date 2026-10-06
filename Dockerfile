# Stage 1: system deps
FROM node:22-slim AS system-deps

RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 git \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 vim file \
    libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0 imagemagick plocate \
    procps lsof iproute2 net-tools curl wget dnsutils iputils-ping strace htop jq less \
    && updatedb && rm -rf /var/lib/apt/lists/*

# Stage 2: npm deps
FROM system-deps AS npm-deps

WORKDIR /app
COPY package.json package-lock.json* ./
# Make sure dev/peer deps or direct installs include autoconsent
RUN npm ci --omit=dev || npm install @duckduckgo/autoconsent

# Stage 3: final runtime image
FROM npm-deps AS runtime

ENV HOME=/root
ENV SHELL=/bin/bash

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