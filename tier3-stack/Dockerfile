# Tools image of the tier 3 stack (ADR-0003 section 1): every cluster command runs in here, never on the host.
FROM alpine:3.24.3

ARG KUBECTL_VERSION=v1.36.4
ARG FLUX_VERSION=2.9.5

RUN apk add --no-cache curl openssl git jq yq ca-certificates

# TARGETARCH is amd64 or arm64, the same spelling both vendors use in their release file names.
ARG TARGETARCH
RUN set -eu; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/kubectl; \
    base="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"; \
    archive="flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo "/tmp/${archive}" "${base}/${archive}"; \
    curl -fsSLo /tmp/flux-checksums.txt "${base}/flux_${FLUX_VERSION}_checksums.txt"; \
    (cd /tmp && grep " ${archive}\$" flux-checksums.txt | sha256sum -c -); \
    tar -xzf "/tmp/${archive}" -C /usr/local/bin flux; \
    rm -f /tmp/flux*; \
    git config --system safe.directory /repo

RUN adduser -D -u 10001 tier3
USER tier3

# /repo and /kubeconfig are mounted read-only, so everything writable lives under /tmp.
ENV HOME=/tmp \
    KUBECACHEDIR=/tmp/.kube-cache \
    KUBECONFIG=/kubeconfig/kubeconfig.yaml

ENTRYPOINT ["/repo/tier3-stack/cluster.sh"]
