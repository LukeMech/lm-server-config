# Anaconda's defaults on the lm-server ISO.
#
# Installs the image embedded in the ISO (image-builder copies it into the
# installer's container storage) and tracks GHCR for updates. The installer
# only asks for the disk and the network. Everything else comes from
# lm-server.toml at first boot: timezone and hostname ([host]), and the
# admin ([host] admin_user / admin_password_hash) for Cockpit and sudo. Root
# stays locked; the first-boot prompt on tty1 needs no login.
# Recovery if the config never applies: boot with
#   systemd.setenv=SYSTEMD_SULOGIN_FORCE=1 systemd.unit=rescue.target
bootc --source-imgref containers-storage:ghcr.io/lukemech/lm-server:latest --target-imgref ghcr.io/lukemech/lm-server:latest

rootpw --lock
timezone Etc/UTC --utc
lang en_US.UTF-8
keyboard us

# Track the image with signature verification (policy.json + cosign key in
# the image), so `bootc upgrade` / `lm-server system update` pull signed images
# from GHCR: ostree-image-signed instead of the ostree-unverified-registry bootc
# install writes. That's all `bootc switch --mutate-in-place
# --enforce-container-sigpolicy` does, but in Anaconda's %post chroot it fails
# ("Switching: No such file or directory", seen on Fedora 44's Anaconda in
# lm-desktop-config) -- and without --erroronfail, silently. So edit the
# deployment's origin directly on the installed disk (/mnt/sysimage, Anaconda's
# physical root) and fail the install if it doesn't stick.
%post --nochroot --erroronfail
set -eu
found=0
for origin in /mnt/sysimage/ostree/deploy/*/deploy/*.origin; do
    [ -f "${origin}" ] || continue
    found=1
    sed -i -e 's#^container-image-reference=ostree-unverified-registry:#container-image-reference=ostree-image-signed:docker://#' \
        -e 's#^container-image-reference=ostree-unverified-image:#container-image-reference=ostree-image-signed:#' "${origin}"
    grep -q '^container-image-reference=ostree-image-signed:docker://ghcr.io/lukemech/lm-server:latest$' "${origin}"
    echo "${origin}: $(grep '^container-image-reference=' "${origin}")"
done
[ "${found}" = 1 ]
%end
