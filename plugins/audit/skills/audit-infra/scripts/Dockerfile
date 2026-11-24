# audit-infra toolbox: the only image the header/TLS/DNS collectors need.
# Built automatically on first use by collect-headers.sh, tls-and-dns.sh and scan-iac.sh:
#   docker build -t audit-infra-toolbox:1 skills/audit-infra/scripts/
FROM alpine:3.20
RUN apk add --no-cache curl jq openssl bind-tools ca-certificates
USER 65534:65534
WORKDIR /tmp
