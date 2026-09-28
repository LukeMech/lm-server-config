#!/bin/bash
#
# Prints name<TAB>epoch:version-release per package, sorted by name -- gpg-pubkey entries
# filtered out (rpm's per-key pseudo-package; a key rotation would look like a "change").
#
# Usage: list-packages.sh <image-ref>

set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref>}"

podman run --rm --entrypoint rpm "${IMAGE}" -qa --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\n' 2>/dev/null \
    | sed 's/\t(none):/\t/' \
    | grep -v $'^gpg-pubkey\t' \
    | sort -k1,1
