#!/bin/sh
# Builds the age image the script encrypts the configuration archive with (#32), and pushes it as
# one index for linux/amd64 and linux/arm64, the two platforms GitLab's own images ship for.
#
# No Docker daemon: the CI runner is not privileged, so instead of `docker build` the static age
# binary is appended as a single layer onto distroless/static with crane. age is built from source
# with `go install`, whose module checksums are checked against the public Go checksum database
# (sum.golang.org), so no separate signature tool is needed.
#
# Usage: IMAGE=<registry>/<path>/age AGE_VERSION=v1.3.2 ci/build-age-image.sh
# The last line printed is the index digest; the script pins the image by it (AGE_IMAGE).
set -eu
: "${IMAGE:?}" "${AGE_VERSION:?}"
BASE=${BASE:-gcr.io/distroless/static-debian13:nonroot}
export CGO_ENABLED=0 GOFLAGS=-trimpath

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
manifests=""
for arch in amd64 arm64; do
    GOOS=linux GOARCH=$arch go install -ldflags=-s "filippo.io/age/cmd/age@$AGE_VERSION"
    # go install puts a cross-compiled binary under bin/<os>_<arch>, a native one under bin.
    bin=$(go env GOPATH)/bin/linux_$arch/age
    [ -f "$bin" ] || bin=$(go env GOPATH)/bin/age
    mkdir -p "$work/$arch"
    install -m 0755 "$bin" "$work/$arch/age"
    tar -C "$work/$arch" --owner=0 --group=0 --numeric-owner -cf "$work/$arch.tar" age
    crane append --platform "linux/$arch" -b "$BASE" -f "$work/$arch.tar" -t "$IMAGE:$AGE_VERSION-$arch"
    crane mutate "$IMAGE:$AGE_VERSION-$arch" --entrypoint /age -t "$IMAGE:$AGE_VERSION-$arch"
    manifests="$manifests -m $IMAGE:$AGE_VERSION-$arch"
done
# shellcheck disable=SC2086
crane index append $manifests -t "$IMAGE:$AGE_VERSION"
echo "$IMAGE@$(crane digest "$IMAGE:$AGE_VERSION")"
