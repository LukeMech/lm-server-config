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

# Re-point the installed system at the registry with signature verification
# (policy.json + cosign key in the image), so `bootc upgrade` /
# `lm-server upgrade` pull signed images from GHCR.
%post
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry ghcr.io/lukemech/lm-server:latest
%end
