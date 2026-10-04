# lm-server: the whole server (the former Proxmox node) as one bootc image.
#
# Every service is a podman quadlet baked into /usr/share/containers/systemd/,
# so it ships with -- and is versioned by -- this image. The service *container
# images* themselves are pulled from their registries and updated
# independently (podman auto-update). Configs/logins come from the private
# lm-server-config-secrets repo at runtime, never from this image.

# Build scripts bind-mounted into the build, never copied into the image.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# AlmaLinux 10 (RHEL 10 rebuild): 10-year lifecycle, minor releases (10.x)
# follow automatically under this tag. Floating tag on purpose (same reasoning
# as immutable-sbc: a pinned digest 404s once quay.io garbage-collects it).
# Never :latest -- that is still AlmaLinux 9.
FROM quay.io/almalinuxorg/almalinux-bootc:10 AS base

# Prebuilt kernel + NVIDIA RPMs (deps/, built and pushed by build-deps.yml).
# Only bind-mounted at build time, never pulled by a server. Floating tag:
# it follows AlmaLinux's kernel.
FROM ghcr.io/lukemech/lm-server-deps:latest AS deps

FROM base

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=deps,source=/rpms,target=/deps-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

RUN bootc container lint
