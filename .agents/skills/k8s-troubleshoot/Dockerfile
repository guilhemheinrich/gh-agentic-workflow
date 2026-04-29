FROM bitnami/kubectl:latest AS kubectl-binary
FROM debian:bookworm-slim

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=kubectl-binary /opt/bitnami/kubectl/bin/kubectl /usr/local/bin/kubectl

RUN mkdir -p /home/.kube \
    && chmod g+rwX /home/.kube \
    && chown -R 1001:1001 /home

USER 1001

ENTRYPOINT ["kubectl"]
