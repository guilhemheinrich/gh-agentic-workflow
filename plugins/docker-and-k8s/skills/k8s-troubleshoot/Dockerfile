# kubectl runner. Pin the version: pass --build-arg KUBECTL_VERSION=<vX.Y.Z>
# matching the cluster (within one minor version). Never use a floating tag.
FROM debian:bookworm-slim

ARG KUBECTL_VERSION=v1.31.4
ARG TARGETARCH=amd64

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq \
    && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl.sha256 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/.kube \
    && chmod g+rwX /home/.kube \
    && chown -R 1001:1001 /home

USER 1001

ENTRYPOINT ["kubectl"]
