# syntax=docker/dockerfile:1

# Build arguments are injected by .github/workflows/build.yml from
# scripts/resolve-versions.sh. The defaults only matter for local builds.
ARG GO_VERSION=1.27.3
ARG ALPINE_VERSION=3.24

# ---- build stage -------------------------------------------------------------
# Runs on the build host's native platform and cross-compiles for the target
# platform, so multi-arch builds never compile under QEMU emulation.
# The Debian-based golang image already ships git, so no package install is
# needed and the build has exactly two network dependencies: the Tailscale
# repository and the Go module proxy.
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS build

ARG TS_VERSION=v1.104.5
WORKDIR /src
# Clone the exact tag so the module graph (go.mod, go.sum) is upstream's own.
RUN git clone --depth 1 --branch "${TS_VERSION}" https://github.com/tailscale/tailscale.git .

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    export GOOS="${TARGETOS}" GOARCH="${TARGETARCH}"; \
    case "${TARGETVARIANT}" in v6) export GOARM=6 ;; v7) export GOARM=7 ;; esac; \
    commit="$(git rev-parse HEAD)"; \
    short="$(printf '%.9s' "${commit}")"; \
    ver="${TS_VERSION#v}"; \
    # Same stamping upstream's build uses, so `derper --version` prints
    # "1.104.5-t73a48057a" instead of "1.104.5-ERR-BuildInfo".
    go build -trimpath \
      -ldflags "-s -w \
        -X tailscale.com/version.longStamp=${ver}-t${short} \
        -X tailscale.com/version.shortStamp=${ver} \
        -X tailscale.com/version.gitCommitStamp=${commit}" \
      -o /out/derper ./cmd/derper; \
    go version > /out/go-version.txt

# ---- runtime stage -----------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

# alpine already ships ca-certificates-bundle (needed for ACME / Let's Encrypt
# and --verify-client-url). Keep the image shell-equipped for debugging.
RUN mkdir -p /var/lib/derper /app/certs

COPY --from=build /out/derper /usr/local/bin/derper
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ARG TS_VERSION
ARG GO_VERSION
LABEL org.opencontainers.image.title="derper" \
      org.opencontainers.image.description="Tailscale DERP relay server (cmd/derper) built from upstream source" \
      io.tailscale.derper.version="${TS_VERSION}" \
      io.tailscale.derper.go-version="${GO_VERSION}"

# DERP private key lives in /var/lib/derper (derper's default for root);
# ACME certificates go to /app/certs (see docker-entrypoint.sh).
VOLUME ["/var/lib/derper", "/app/certs"]
EXPOSE 80/tcp 443/tcp 3478/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
