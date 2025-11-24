# syntax=docker/dockerfile:1.6

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo \
    LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    ORCA_HOME=/opt/jma/weborca

# Install base utilities and configure locale/timezone
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        tzdata \
        locales \
        postgresql-client \
    && locale-gen ja_JP.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Add ORCA apt keyring and repository definition
RUN mkdir -p /etc/apt/keyrings \
    && wget https://ftp.orca.med.or.jp/pub/ubuntu/archive.key -O /etc/apt/keyrings/jma.asc \
    && chmod 644 /etc/apt/keyrings/jma.asc \
    && cd /etc/apt/sources.list.d \
    && wget https://ftp.orca.med.or.jp/pub/ubuntu/jma-receipt-weborca-jammy10.list

# Install WebORCA packages and clean up
RUN apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get install -y --no-install-recommends \
        jma-receipt-weborca \
    && rm -rf /var/lib/apt/lists/*

# Optional: pre-flight module install + version list (best-effort, will be a no-op if already provisioned)
RUN if command -v weborca-install >/dev/null 2>&1; then \
        yes | weborca-install || true; \
        weborca-install -l || true; \
    fi

# Copy configuration overrides
COPY --chown=orca:orca jma-receipt.env /opt/jma/weborca/app/etc/jma-receipt.env
COPY --chown=orca:orca example/receipt_route.ini /opt/jma/weborca/app/etc/receipt_route.ini
RUN chmod 640 /opt/jma/weborca/app/etc/receipt_route.ini

# Copy entrypoint helper
COPY start-weborca.sh /usr/local/bin/start-weborca.sh
RUN chmod +x /usr/local/bin/start-weborca.sh

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/start-weborca.sh"]
