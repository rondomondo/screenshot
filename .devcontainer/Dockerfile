FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /uvx /usr/local/bin/

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        make \
        docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
