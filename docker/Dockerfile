FROM ubuntu:24.04

ARG WGCF_VERSION=2.2.31

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates conntrack curl dnsutils iproute2 iputils-ping \
       jq nftables procps python3 tcpdump wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch=$(dpkg --print-architecture); \
    case "${arch}" in \
      amd64) asset="wgcf_${WGCF_VERSION}_linux_amd64" ;; \
      arm64) asset="wgcf_${WGCF_VERSION}_linux_arm64" ;; \
      *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    workdir=$(mktemp -d); \
    curl -fL "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/${asset}" -o "${workdir}/${asset}"; \
    curl -fL "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/checksums.txt" -o "${workdir}/checksums.txt"; \
    cd "${workdir}"; \
    grep -F "  ${asset}" checksums.txt > selected-checksum.txt; \
    sha256sum -c selected-checksum.txt; \
    install -m 0755 "${asset}" /usr/local/bin/wgcf; \
    rm -rf "${workdir}"

WORKDIR /app
COPY native/scripts/ /app/scripts/
COPY docker/bin/ /app/bin/
RUN chmod 0755 /app/scripts/*.sh /app/bin/*.sh

ENTRYPOINT ["/app/bin/entrypoint.sh"]
HEALTHCHECK --interval=60s --timeout=20s --start-period=20s --retries=3 \
  CMD ["/app/bin/healthcheck.sh"]
