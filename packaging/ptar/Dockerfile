# syntax=docker/dockerfile:1
#
# Builder image for plakar plugin packages (.ptar).
#
# `plakar pkg build` clones a plugin repository, runs its Makefile and wraps the
# result into a .ptar; it therefore needs git, make and a Go toolchain next to
# the plakar binary.  This image bundles all four, with plakar built from the
# surrounding working tree so a package is always assembled by the code under
# review rather than by whatever plakar happens to be installed on the host.
#
# The build context is the repository root:
#
#     docker build -f packaging/ptar/Dockerfile -t plakar-ptar-builder:local .
#
# See packaging/ptar/README.md for the wrappers that do this for you.

# Go 1.26.2 is the floor: that is what the webdav connector's go.mod requires.
# Bump this when a plugin asks for a newer toolchain -- GOTOOLCHAIN is pinned to
# `local` below so the build fails loudly instead of silently downloading one.
ARG GO_IMAGE=golang:1.26.5-alpine3.23

FROM ${GO_IMAGE} AS plakar

RUN apk add --no-cache ca-certificates git make

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# Static, like the release build.  -buildvcs=false keeps .git out of the build
# context: the only thing it feeds is the revision suffix on a -devel version
# string, and PLAKAR_REVISION below records that instead.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /plakar .

FROM ${GO_IMAGE} AS builder

# git clones the plugin sources, make drives their build, ca-certificates lets
# both talk HTTPS to the forge and the module proxy.
RUN apk add --no-cache ca-certificates git make

# Module and build caches live in a single tree so one volume covers both, and
# world writable so a `docker run --user` with an arbitrary uid still works
# (docker seeds a fresh named volume from the image directory, permissions
# included).
ENV GOMODCACHE=/gocache/mod \
    GOCACHE=/gocache/build \
    GOTOOLCHAIN=local \
    RECIPE_DIR=/recipes \
    OUT_DIR=/out
RUN mkdir -p /gocache/mod /gocache/build /out && chmod -R 0777 /gocache /out

COPY --from=plakar /plakar /usr/local/bin/plakar
COPY packaging/ptar/recipes/ /recipes/
COPY packaging/ptar/build-ptar.sh /usr/local/bin/build-ptar
RUN chmod 0755 /usr/local/bin/build-ptar && \
    plakar -configdir /tmp/c -cachedir /tmp/c -datadir /tmp/c version && \
    rm -rf /tmp/c

# Recorded rather than stamped into the binary, see -buildvcs=false above.
ARG PLAKAR_REVISION=unknown
LABEL org.opencontainers.image.title="plakar ptar builder" \
      org.opencontainers.image.source="https://github.com/PlakarKorp/plakar" \
      org.opencontainers.image.revision="${PLAKAR_REVISION}"

WORKDIR /out
ENTRYPOINT ["build-ptar"]
