FROM mcr.microsoft.com/devcontainers/typescript-node:22

# ---- 社内 CA 証明書（任意） ----------------------------------------------
# Netskope などの TLS インスペクションを挟む環境向け。
# .devcontainer/certs/ に .pem か .crt を置くと自動で取り込みます。
# 置かなくてもビルドは通ります（ディレクトリごとコピーするため空でも失敗しません）。
COPY certs/ /tmp/extra-certs/
RUN set -eux; \
    found=0; \
    for f in /tmp/extra-certs/*.pem /tmp/extra-certs/*.crt; do \
      [ -e "$f" ] || continue; \
      base="$(basename "$f")"; \
      cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
      found=1; \
    done; \
    if [ "$found" = "1" ]; then update-ca-certificates; fi; \
    rm -rf /tmp/extra-certs

# 追加した CA を Node / AWS CLI / Python にも見せる。
# システムのバンドルを指すので、証明書を置かない環境でも安全に動きます。
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# ---- Session Manager plugin ----------------------------------------------
# `aws ecs execute-command` でコンテナに入るのに必要。AWS CLI には同梱されていません。
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" ;; \
      arm64) url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/session-manager-plugin.deb "$url"; \
    dpkg -i /tmp/session-manager-plugin.deb; \
    rm -f /tmp/session-manager-plugin.deb

# ---- uv / uvx -------------------------------------------------------------
# serena MCP サーバーの起動に必要
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | sh; \
    mv /root/.local/bin/uv /usr/local/bin/uv; \
    mv /root/.local/bin/uvx /usr/local/bin/uvx
