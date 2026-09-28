set dotenv-filename := "image-template.env"
set dotenv-load

export image_name := env_var("IMAGE_NAME")
export registry := env_var("REGISTRY")
export repo_organization := env_var("REPO_ORGANIZATION")
export repo_name := env_var("REPO_NAME")
export image_desc := env_var("IMAGE_DESC")
export image_keywords := env_var("IMAGE_KEYWORDS")
export image_logo_url := env_var("IMAGE_LOGO_URL")
export default_tag := env_var("DEFAULT_TAG")
export bib_image := env_var("BIB_IMAGE")

alias build-vm := build-qcow2

[private]
default:
    @just --list

# Check Just syntax
[group('Just')]
check:
    just --unstable --fmt --check -f Justfile

# Fix Just syntax
[group('Just')]
fix:
    just --unstable --fmt -f Justfile

# Remove local build output
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    rm -rf output/ _build*/ changelog.md

# Build the system image (Containerfile)
[group('Build')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euox pipefail
    LABELS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        LABELS+=("--label" "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ repo_name }}/blob/${GIT_SHA}/Containerfile")
        LABELS+=("--label" "org.opencontainers.image.version={{ default_tag }}.$(date +%Y%m%d)-${GIT_SHA}")
    fi
    LABELS+=("--label" "io.artifacthub.package.keywords={{ image_keywords }}")
    LABELS+=("--label" "io.artifacthub.package.logo-url={{ image_logo_url }}")
    LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("--label" "org.opencontainers.image.description={{ image_desc }}")
    LABELS+=("--label" "org.opencontainers.image.title={{ image_name }}")
    LABELS+=("--label" "org.opencontainers.image.vendor={{ repo_organization }}")
    podman build "${LABELS[@]}" --pull=newer --tag "${target_image}:${tag}" --file Containerfile .

# Build a service image from images/<name>/ (-> lm-server-<name>)
[group('Build')]
build-image $name $tag=default_tag:
    #!/usr/bin/env bash
    set -euox pipefail
    podman build --pull=newer \
        --label "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ repo_name }}" \
        --label "org.opencontainers.image.title={{ image_name }}-${name}" \
        --tag "{{ image_name }}-${name}:${tag}" "images/${name}"

# Split the system image into content-based layers for smaller updates
# (same as immutable-sbc: chunkah, not rpm-ostree build-chunked-oci).
[group('Build')]
rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -xeuo pipefail
    CHUNKAH_IMAGE="quay.io/coreos/chunkah:latest"
    CHUNKAH_CONFIG_FILE="$(mktemp)"
    CHUNKAH_OUTPUT_DIR="$(mktemp -d ./"${target_image}"_chunkah_XXXXXX)"
    trap 'rm -f "${CHUNKAH_CONFIG_FILE}"; rm -rf "${CHUNKAH_OUTPUT_DIR}"' EXIT
    podman inspect "${target_image}:${tag}" > "${CHUNKAH_CONFIG_FILE}"
    podman run --rm \
      --mount=type=image,src="${target_image}:${tag}",target=/chunkah \
      -v "${CHUNKAH_CONFIG_FILE}:/chunkah-config.json:ro,Z" \
      -v "${CHUNKAH_OUTPUT_DIR}:/run/out:Z" \
      "${CHUNKAH_IMAGE}" \
      build --verbose --compressed --max-layers 128 --prune /sysroot/ \
      --label ostree.commit- --label ostree.final-diffid- \
      --config /chunkah-config.json \
      --output oci:/run/out/chunked
    CHUNKED_IMAGE="$(podman pull "oci:${CHUNKAH_OUTPUT_DIR}/chunked")"
    podman tag "${CHUNKED_IMAGE}" "${target_image}:${tag}"

# Tags for a published build: latest, <date>, latest-<sha>, ...
[group('Utility')]
generate-build-tags $tag=default_tag:
    #!/usr/bin/env bash
    set -eou pipefail
    DATE=$(date +%Y%m%d)
    BUILD_TAGS=("${tag}" "${DATE}" "${tag}-${DATE}")
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        BUILD_TAGS+=("${tag}-${GIT_SHA}" "${DATE}-${GIT_SHA}")
    fi
    echo "${BUILD_TAGS[@]}"

# Copies a user-podman image into root's storage (bootc-image-builder runs rootful)
_rootful_load_image $target_image $tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    if [[ "${UID}" -eq 0 ]]; then exit 0; fi
    if podman image exists "${target_image}:${tag}"; then
        COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
        sudo TMPDIR="${COPYTMP}" podman image scp "${UID}@localhost::${target_image}:${tag}" "root@localhost::${target_image}:${tag}"
        rm -rf "${COPYTMP}"
    else
        sudo podman pull "${target_image}:${tag}"
    fi

# bootc-image-builder: <type> is iso (anaconda-iso) | qcow2 | raw
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${type}" == iso ]] && type=anaconda-iso
    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)
    sudo podman run --rm -it --privileged --pull=newer --net=host \
      --security-opt label=type:unconfined_t \
      -v "$(pwd)/${config}:/config.toml:ro" \
      -v "${BUILDTMP}:/output" \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" --type "${type}" --use-librepo=True "${target_image}:${tag}"
    mkdir -p output
    sudo mv -f "${BUILDTMP}"/* output/
    sudo rmdir "${BUILDTMP}"
    sudo chown -R "${USER}:${USER}" output/

# Installer ISO (from the local image, or from GHCR with target_image=ghcr.io/lukemech/lm-server)
[group('Disk images')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# QCOW2 for testing in a VM
[group('Disk images')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Boot the qcow2 in a throwaway VM (web console on http://localhost:8006+)
[group('Disk images')]
run-vm $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail
    image_file="output/qcow2/disk.qcow2"
    [[ -f "${image_file}" ]] || just build-qcow2 "${target_image}" "${tag}"
    port=8006
    while grep -q ":${port}" <<< "$(ss -tunalp)"; do port=$(( port + 1 )); done
    echo "Connect to http://localhost:${port}"
    podman run --rm --privileged --pull=newer \
      --publish "127.0.0.1:${port}:8006" \
      --env "CPU_CORES=4" --env "RAM_SIZE=8G" --env "DISK_SIZE=64G" \
      --device=/dev/kvm \
      --volume "${PWD}/${image_file}:/boot.qcow2" \
      docker.io/qemux/qemu

# shellcheck every script (incl. the extension-less ones in system_files)
lint:
    #!/usr/bin/env bash
    set -eou pipefail
    command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
    find . -path ./.git -prune -o -type f \( -name '*.sh' -o -path '*/usr/bin/lm-server' \) -print0 |
        xargs -0 shellcheck -x -e SC1091

# shfmt every script
format:
    #!/usr/bin/env bash
    set -eou pipefail
    find . -path ./.git -prune -o -type f -name '*.sh' -print0 | xargs -0 shfmt --write -i 4
