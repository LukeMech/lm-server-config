# lm-server

The home server (formerly Proxmox + LXC + a Docker VM) as **one AlmaLinux bootc
image**. GitHub Actions builds it, you install it from the ISO on the
[releases page](https://github.com/LukeMech/lm-server-config/releases), and it updates
atomically from GHCR, the same way as [immutable-sbc](https://github.com/LukeMech/immutable-sbc).

- **System**: `ghcr.io/lukemech/lm-server` (AlmaLinux 10 bootc, cosign-signed).
  An upgrade downloads the new image and switches to it on reboot. The previous
  image stays available for rollback.
- **Services**: podman [quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  baked into the image. Their container images update separately from the system.
- **Web UI**: Cockpit (`proxmox.lukemech.org` via the tunnel, or `https://<ip>:9090`
  on the LAN). The **Management** page: *Update all* (config, containers,
  system image, each step's status and a progress bar from
  `bootc --progress-fd`), deployments and rollback, every container with the
  version it runs and the one available, status, the history of automatic
  runs, the config editor and GitHub setup. What's pending shows in the
  Overview page's Health card as a link to it. Stock Cockpit covers
  containers, VMs, **disks**, network, metrics history (PCP) and the
  performance profile (tuned, set to `powersave`).
- **Config**: one file, `lm-server.toml`, in the private **lm-server-config-secrets**
  repo. At first boot the server asks for GitHub credentials to fetch it.
  [`lm-server-config-secrets/`](lm-server-config-secrets/) is the template.

## Services

Each service is one systemd unit. Multi-container services are a **pod**, so
`lm-server restart immich` (i.e. `immich-pod.service`) restarts all of their
containers together. The quadlets live in one folder per service:
[system_files/usr/share/containers/systemd/](system_files/usr/share/containers/systemd/).

| Service | Unit | Containers | Route → local |
|---|---|---|---|
| cloudflared | `lm-server-cloudflared` | — (part of the system: RPM + systemd unit, updated with the image) | — |
| disks | `disks-pod` | filebrowser, syncthing | disk → `:8001`, syncdisks → `:8384` |
| toolbox | `toolbox` | lm-server-webapp | toolbox → `:6600` |
| website | `website` | lm-server-webapp | lukemech.org → `:3000` |
| exp | `exp` | lm-server-webapp (+ RenderCV) | exp → `:7999` |
| convert | `convert` | convertx | convert → `:3001` |
| immich | `immich-pod` | server, machine-learning, postgres, valkey | immich → `:2283` |
| remote | `remote-pod` | guacamole, guacd, postgres | remote → `:8443` |
| sugar | `sugar-pod` | nightscout, mongo | sugar → `:1337` |

Every quadlet has to name a container image; there's no multi-container compose
file. The pod is what makes a service one unit, and the containers inside it
talk over `127.0.0.1`. Only [`lm-server-webapp`](images/webapp) is our own image:
a generic runner for the three Flask sites. It clones the site repo at start
(private ones with the token), pulls every 3 minutes, and restarts on a new
commit. Everything else is an upstream image.

**Cloudflare Tunnel routes**: set these in the dashboard. `lm-server routes`
prints the same table.

| Hostname | Service |
|---|---|
| proxmox.lukemech.org | `https://localhost:9090` (No TLS Verify) |
| disk.lukemech.org | `http://localhost:8001` |
| syncdisks.lukemech.org | `http://localhost:8384` |
| toolbox.lukemech.org | `http://localhost:6600` |
| lukemech.org | `http://localhost:3000` |
| exp.lukemech.org | `http://localhost:7999` |
| convert.lukemech.org | `http://localhost:3001` |
| immich.lukemech.org | `http://localhost:2283` |
| remote.lukemech.org | `http://localhost:8443` |
| sugar.lukemech.org | `http://localhost:1337` |

**Isolation**:
- Every service has its own podman network.
- Web UIs are published on 127.0.0.1 only (reached through cloudflared). The LAN
  only gets SSH, Cockpit, the Syncthing sync ports and Immich
  (`http://<server-ip>:2283`, e.g. for the mobile app at home).
- SELinux labels every volume `:Z`. The shared data disk is `:z`.
- `NoNewPrivileges` on everything.
- The web apps also run with `UserNS=auto`, a read-only root filesystem and no
  capabilities.

**Ad-hoc containers** (created in Cockpit or with `podman run`) are removed at
every boot, which includes every system upgrade. Turn this off with
`adhoc_ephemeral = false`.

## Updates

Cockpit > **Management** > *Update all* runs the three below in this order: config,
containers, then the system image (downloaded; it switches on the next reboot).

| What | How | When |
|---|---|---|
| System image | `lm-server upgrade [--check\|--apply]`, `lm-server rollback`, Cockpit | `[updates] system`, default `"manual"` |
| Containers | `lm-server update [--dry-run]` (`podman auto-update`, rolls back a service that fails to restart), `lm-server containers` (running vs. available versions), Cockpit | `[updates] containers`, default `"daily"` |
| Configs (lm-server.toml) | `lm-server config pull` (= `sync`), `lm-server config status`, Cockpit *Sync configs* | `[updates] config`, default `"hourly"`; `"manual"` = at boot + on demand |

**Editing the config from Cockpit**: *Configuration (lm-server.toml)* loads
the file from the secrets repo. *Save, push & apply* checks it, commits and
pushes it to GitHub, then applies it right away (`lm-server config show|save`
on the CLI). Pushing needs the token to have *Contents: Read and write* on the
secrets repo. With a read-only token, edit in GitHub and use *Sync configs*.
If someone changed the repo meanwhile, the save is refused. Reload and redo the edit.

Schedules are systemd timers, not cron. They take calendar expressions like
`"daily"`, `"Sun 04:00"` or `"*-*-01 03:00"`. Check one with
`systemd-analyze calendar "Sun 04:00"`. `lm-server status` shows the next run of
each timer, and Cockpit > Management > *Automatic runs* shows what they did.

### Upgrading from Fedora (v44.x) to AlmaLinux (v10.x)

A server installed from a Fedora release (`v44.*`) can't just upgrade to an
AlmaLinux one (`v10.*`). The new deployment never finalizes. After the reboot
the server is back on Fedora, and `ostree-boot-complete.service` fails with:

```
ostree-finalize-staged.service failed on previous boot: Finalizing deployment:
Finalizing SELinux policy: failed to run semodule: Child process exited with code 1
```

The Fedora side runs the finalizing, and its systemd has no `/usr/sbin` in
`PATH` (Fedora merged it into `/usr/bin`). AlmaLinux has `semodule` only in
`/usr/sbin`, so it isn't found (`journalctl -b -1 -u ostree-finalize-staged`:
`execvp semodule: No such file or directory`). Once, before the upgrade, give
that service a `PATH` with `/usr/sbin`:

```sh
sudo mkdir -p /etc/systemd/system/ostree-finalize-staged.service.d
printf '[Service]\nEnvironment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin\n' |
  sudo tee /etc/systemd/system/ostree-finalize-staged.service.d/10-path.conf
sudo systemctl daemon-reload
sudo lm-server upgrade --apply
```

It has to be in place before `upgrade --apply`, because the service starts
when the new deployment is staged. After the reboot on AlmaLinux, the drop-in
is no longer needed:
`sudo rm -r /etc/systemd/system/ostree-finalize-staged.service.d`.
`lm-server rollback` still goes back to Fedora.

## NVIDIA GPU

The image carries NVIDIA's driver for the X99 machine's GTX 1050 (Pascal):
the proprietary 580 branch from RPM Fusion, the last one with Pascal (Linux
580.x is the same R580 branch as Windows' 580-582.xx). On a machine without
an NVIDIA card it never loads. `nvidia-smi` shows the card.

The kernel module isn't compiled in the system image's build. A separate
image, `ghcr.io/lukemech/lm-server-deps` ([deps/](deps/), built by
[build-deps.yml](.github/workflows/build-deps.yml), same idea as
immutable-sbc's), resolves AlmaLinux's current kernel, builds the kmod for it
(akmods) and carries both as RPMs, with the driver userspace of the same
version and the container toolkit. The system image swaps the base image's
kernel for exactly that one ([00-pre-build.sh](build_files/00-pre-build.sh), before anything else in the build) and
installs the rest ([40-nvidia.sh](build_files/40-nvidia.sh)), so module and
kernel always match. The deps image is rebuilt on a change in `deps/` (the
system build of the same push waits for it) and every two weeks, a day before
the system image; a scheduled run publishes only if the kernel or the driver
changed.

Containers get it through CDI: `nvidia-cdi-refresh` writes `/run/cdi/nvidia.yaml`
at every boot (only with the card present) and lets containers use
`/dev/nvidia*` (SELinux boolean `container_use_xserver_devices`). For Immich:

```toml
[immich]
gpu = "nvidia"   # machine learning on CUDA, the server for NVENC transcoding
```

Machine learning switches to its `-cuda` image. Transcoding on the card is
switched on in Immich itself: Administration > Video Transcoding > Hardware
Acceleration > NVENC. With `gpu` set on a machine without the card, Immich
won't start.

## Disks

Every service keeps all of its data in one folder,
`/var/lib/lm-server/volumes/<service>/`. That's the Immich library and database,
the FileBrowser/Syncthing shares, the Guacamole DB, and so on. Two keys in its
section of `lm-server.toml` say where that data lives and how much of it
there may be:

```toml
[immich]
disk = "/var/mnt/hdd-mirror/immich"   # where: this folder (default: the system disk)
storage = "400G"                      # how much: a filesystem of exactly this size
```

- **`disk`**: the data lives in exactly that folder, bind-mounted in place of
  `volumes/<service>/`: a disk or LV mounted there, or a plain folder on a disk
  (e.g. `/var/mnt/nvme/kuma`). Each service needs its own folder: two services
  on the same one (or one inside the other) is a config error. Older configs
  wrote this as `storage = "/var/mnt/..."`, which still works.
- **`storage`**: the data goes into a filesystem of that size: an ext4 image
  file, `<service>.img`, in the `disk` folder (or in `/var/lib/lm-server/disks/`
  without one), loop-mounted at `volumes/<service>/`. When it's full, only that
  service notices, never the system disk or the other services. The space is
  reserved up front. A bigger value later grows it live; a smaller one is
  refused (logged), since ext4 can't shrink while in use. No LVM needed: one
  filesystem on the HDD mirror holds each service's image.

If you change either key later, the next sync stops the service, copies its
data to the new place (only if the target is empty; into a new `storage` only
if it fits with 10% to spare), and starts it again. The old copy is never
deleted automatically.

For `[disks]` the data looks like this, with `shares = ["files"]`:

```
shares/files/     FileBrowser source "files" (Syncthing: files/Keepass,
                  files/Sync; documents in files/docs)
app/syncthing/    Syncthing config + keys (device ID)
app/filebrowser/  FileBrowser database
```

Both containers see the shares as `/shares/<name>`; in `lm-server.toml` you
only write `<share>/<folder>`. With `storage = "80G"`, FileBrowser shows 80 GB as
its maximum.

**What happens on a change** (e.g. `disk` from `/var/mnt/hdd-mirror/immich` to
`/var/mnt/nvme/immich`):
1. The service is stopped.
2. If the new place is empty, the data is copied there (`rsync`,
   progress in Cockpit > Management > Automatic runs / `lm-server history`). If it
   already holds data, nothing is copied and that data is used as is.
3. The new place is mounted at `volumes/<service>/` and the service starts again.
4. The old copy stays where it was. Delete it by hand once everything works.

If the disk behind `disk` isn't mounted at boot, the service doesn't start
(`RequiresMountsFor`), so nothing gets written to the wrong disk. If the disk is
**replaced with an empty one** mounted at the same path, the service starts
empty, like a fresh install. Restore its data first (see below).

**Moving data by hand**, e.g. for a large library over several sessions, or
when restoring a backup (without `storage`; with it, let the sync copy):

```sh
lm-server stop immich
rsync -aHA --info=progress2 /var/lib/lm-server/volumes/immich/ /var/mnt/hdd-mirror/immich/
# edit [immich] disk = "/var/mnt/hdd-mirror/immich" (Cockpit editor or the repo)
lm-server sync      # target isn't empty -> no copy, just switch and start
```

`/var/lib/lm-server/volumes/<service>/` always shows the service's current
data, wherever it lives.

**CPU and RAM per service**: `cpus = 2` (cores, `0.5` works) and `memory = "4G"`
in a service's section cap all of its containers together, like the
cores/RAM of a Proxmox guest. They're applied live via the service's systemd
slice `lm-server-<service>.slice` (cgroups, the kernel's own limits; podman
isn't involved). Leave them out for no limit. Cockpit > Management > Services
(or `lm-server resources`) shows each service's CPU, RAM and disk against its
limits. Swap is **zram** (half of RAM, zstd), configured in
`/usr/lib/systemd/zram-generator.conf`.

Disks are set up once, by hand, in **Cockpit > Storage** (formatting wipes
them). Cockpit writes `/etc/fstab`, and bootc keeps `/etc` across upgrades.
Set the disks up **before** pointing `disk` at them: a sync against a path
that isn't mounted yet writes to the system disk (and warns about it).

- **HDD mirror**:
  1. *Create MDRAID device*: RAID 1, both HDDs, name `hdd-mirror`.
  2. Format `/dev/md/hdd-mirror` **XFS**, mount point `/var/mnt/hdd-mirror`,
     mounted at boot.
  3. `disk = "/var/mnt/hdd-mirror/immich"` + `storage = "400G"` in `[immich]`,
     `disk = "/var/mnt/hdd-mirror/disks"` + `storage = "80G"` in `[disks]`.
     Each gets a filesystem of that size; the rest of the mirror stays free
     for growing them.

  (Alternative: LVM on the mirror with one logical volume per service mounted
  at its folder. Then leave `storage` out: the volume's size is the limit.)
- **NVMe**: format the whole disk **XFS**, mount point `/var/mnt/nvme`. No RAID.

Suggested layout for this machine:

| Disk | Use |
|---|---|
| 120 GB SSD (`sda`) | system (bootc), the small services (their own `storage` each, no `disk`) |
| 2×500 GB HDD, RAID 1 | `/var/mnt/hdd-mirror`: immich (400 GB), disks (80 GB) |
| 2 TB NVMe | `/var/mnt/nvme`: scratch space, staging for moves and restores |

The NVMe is a single disk. Keep a backup of anything on it that you can't lose.

**Health and replacing a disk** (Cockpit > Storage): the RAID device page shows
its state (*Clean*, *Degraded*, *Recovering* with progress) and each member
disk. To replace a failed HDD: *Remove* it from the RAID there, swap the disk,
then *Add disk* on the same page; the rebuild starts on its own. Each drive's
page shows its SMART assessment and can run a self-test; from a shell,
`smartctl -a /dev/sdX`, `cat /proc/mdstat` and `mdadm --detail /dev/md/hdd-mirror`.
mdadm's `raid-check.timer` reads the whole mirror weekly and repairs mismatches
between the two disks. Unlike ZFS, mdraid + XFS has no checksums on the data,
so it can't tell which copy is right if a disk returns bad data without
reporting an error.

### Migrating from Proxmox

Step by step, including Immich, disk_0/docs, Syncthing, FileBrowser and the
ZFS `hdd-mirror`: **[MIGRATION.md](MIGRATION.md)**.

## Virtual machines

Cockpit > Virtual machines creates and runs x86_64 VMs with KVM (full speed):
Windows, other Linux distributions, anything that can't be a container.

`virt-install` is there too, for VMs scripted from a shell.

Only the host's architecture: AlmaLinux ships no QEMU for other architectures
(ARM64, RISC-V), so there are no emulated VMs.

## First install

1. Download `lm-server-<tag>.iso` and its `.sha256` from the latest release.
   An ISO of 2 GiB or more is attached in parts: join them under the original
   name, `cat lm-server-<tag>.iso.part-* > lm-server-<tag>.iso` (Windows:
   `copy /b <part-00> + <part-01> lm-server-<tag>.iso`), then
   `sha256sum -c lm-server-<tag>.iso.sha256`. The release notes have the
   exact commands.
2. The installer only asks for the system disk and the network (a static IP).
   Timezone, hostname and accounts all come from the config.
3. After the reboot, tty1 asks for the secrets repo (no login needed):
   owner/name, branch, the path of the config file in the repo (default
   `lm-server.toml`), GitHub username and a **fine-grained token** with
   *Contents: read-only*. GitHub doesn't accept account passwords for git.
   Until this succeeds there's no account to log in with, and the prompt comes
   back at every boot.
4. The server fetches `lm-server.toml` and applies `[host]`: it creates the
   admin (`admin_user` / `admin_password_hash`) for Cockpit and sudo, plus SSH
   keys. Then it starts the configured services and creates their users.
   Once signed in, the admin's `sudo` doesn't ask for the password again
   (`/etc/sudoers.d/lm-server-wheel`), so Cockpit's *Administrative access*
   switches on without a prompt; the browser remembers it for the next login.

Locked out (the config never applied)? In the GRUB menu, press `e` and add
`systemd.setenv=SYSTEMD_SULOGIN_FORCE=1 systemd.unit=rescue.target` to the
`linux` line. That boots to a root shell. Then run `lm-server setup`, then
`systemctl default`.

## CLI

```
lm-server status | history [N] | routes | services
lm-server setup | sync [--force] (= config pull) | config show | config save < lm-server.toml
lm-server upgrade [--check|--apply] | rollback | update [--dry-run]
lm-server start|stop|restart|logs <service>
lm-server prune-adhoc
```

## Repository

```
Containerfile, build_files/            system image (numbered hooks, like immutable-sbc)
system_files/                          copied onto / of the system image
  usr/share/containers/systemd/<svc>/  quadlets, one folder per service = the service catalog
  usr/libexec/lm-server/render.py      lm-server.toml -> per-service env/config files
                                       (generic; custom code only for disks/immich/remote)
  usr/libexec/lm-server/provision/     creates users (APIs / SQL / CLI) on config change
  usr/share/cockpit/lm-server/         the Cockpit page
  usr/bin/lm-server                    the CLI
images/webapp/                         our own service image
iso/                                   installer ISO: Anaconda as a bootable container
                                       (+ kickstart), built with image-builder
lm-server-config-secrets/                     TEMPLATE of the private secrets repo
scripts/                               release changelog helpers (from immutable-sbc)
```

CI: [build.yml](.github/workflows/build.yml) builds the system image, pushes and
signs it, publishes release `v10.YYYYMMDD[.N]` with a package + commit changelog,
and attaches the ISO ([build-iso.yml](.github/workflows/build-iso.yml): the
installer container from `iso/` + the image as its payload, image-builder's
`bootc-generic-iso`).
[build-images.yml](.github/workflows/build-images.yml) builds `images/*`.
The repo secret **`SIGNING_SECRET`** is required: the cosign key matching
`system_files/etc/pki/containers/lukemech-cosign.pub`. The server refuses unsigned
`ghcr.io/lukemech/*` images.

Local: `just build`, `just build-image webapp`, `just build-iso`.

### Adding a service

A plain service is **one folder of quadlets + one section in lm-server.toml**.
No code changes and no config beyond those. lm-server picks the service up
from the folder. Example, Uptime Kuma at `status.lukemech.org`:

`system_files/usr/share/containers/systemd/kuma/kuma.container`
```ini
# lm-server: description Uptime Kuma
# lm-server: route status.lukemech.org http://localhost:3002
# lm-server: env UPTIME_KUMA_PORT=3001
[Unit]
Description=kuma: Uptime Kuma
ConditionPathExists=/var/lib/lm-server/env/kuma/enabled
RequiresMountsFor=/var/lib/lm-server/volumes/kuma

[Container]
ContainerName=kuma
Image=docker.io/louislam/uptime-kuma:2
AutoUpdate=registry
Network=kuma.network
PublishPort=127.0.0.1:3002:3001
EnvironmentFile=/var/lib/lm-server/env/kuma/kuma.env
Volume=/var/lib/lm-server/volumes/kuma:/app/data:Z
NoNewPrivileges=true

[Service]
Slice=lm-server-kuma.slice
Restart=always
TimeoutStartSec=900
```
`system_files/usr/share/containers/systemd/kuma/kuma.network`
```ini
[Network]
NetworkName=lm-server-kuma
```
`lm-server.toml`
```toml
[kuma]
disk = "/var/mnt/nvme/kuma"   # optional, like storage / cpus / memory
# any key becomes an env var: admin_email = "..." -> ADMIN_EMAIL
```

What lm-server reads from the folder:
- **unit**: `<name>-pod` if there's a `<name>.pod`, otherwise the container.
- **data folders**: every `Volume=/var/lib/lm-server/volumes/<name>/...`.
- **directives** in comments:
  - `# lm-server: description <text>`
  - `# lm-server: route <host> <url>`
  - `# lm-server: env KEY=default` (`{{github_token}}` / `{{github_user}}` are
    filled in with the setup credentials)
  - `# lm-server: require KEY` (must be set in lm-server.toml)

The section renders to `env/<name>/<name>.env`. Values, lowest priority first:
directive defaults, then top-level keys, then `env = { ... }`. `users = [...]`
goes to `env/<name>/users.json`.

Rules for the quadlets:
- Every unit needs `ConditionPathExists=…/env/<name>/enabled` and
  `Slice=lm-server-<name>.slice`.
- Web UIs publish on `127.0.0.1`.
- For several containers, add `<name>.pod` (with the `PublishPort=`s and
  `Network=`) and give each container `Pod=<name>.pod` plus
  `[Install] WantedBy=<name>-pod.service`. `immich/` and `sugar/` are
  working examples.
- If users have to be created through an API, add
  `system_files/usr/libexec/lm-server/provision/<name>.sh`. It runs after every
  config change of that service.
- A custom renderer in `render.py` (`CUSTOM`) is only needed for generated
  config files or several env files. disks, immich and remote have one.

Then push. CI builds the image, and `lm-server upgrade` + reboot brings the
service to the server.
