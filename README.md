# lm-server

The home server (formerly Proxmox + LXC + a Docker VM) as **one Fedora bootc
image**. GitHub Actions builds it, you install it from the ISO on the
[releases page](https://github.com/LukeMech/lm-server-config/releases), and it updates
atomically from GHCR, the same way as [immutable-sbc](https://github.com/LukeMech/immutable-sbc).

- **System**: `ghcr.io/lukemech/lm-server` (Fedora bootc 44, cosign-signed).
  An upgrade downloads the new image and switches to it on reboot. The previous
  image stays available for rollback.
- **Services**: podman [quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  baked into the image. Their container images update separately from the system.
- **Web UI**: Cockpit (`proxmox.lukemech.org` via the tunnel, or `https://<ip>:9090`
  on the LAN). The **lm-server** page covers system and container updates with a
  live log, the history of automatic runs, config sync, and GitHub setup.
  Stock Cockpit covers containers, VMs, **disks** and network.
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
| cloudflared | `cloudflared` | cloudflared (host network) | — |
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
  only gets SSH, Cockpit and the Syncthing sync ports.
- SELinux labels every volume `:Z`. The shared data disk is `:z`.
- `NoNewPrivileges` on everything.
- The web apps also run with `UserNS=auto`, a read-only root filesystem and no
  capabilities.

**Ad-hoc containers** (created in Cockpit or with `podman run`) are removed at
every boot, which includes every system upgrade. Turn this off with
`adhoc_ephemeral = false`.

## Updates

| What | How | When |
|---|---|---|
| System image | `lm-server upgrade [--check\|--apply]`, `lm-server rollback`, Cockpit | `[updates] system`, default `"manual"` |
| Containers | `lm-server update [--dry-run]` (`podman auto-update`, rolls back a service that fails to restart), Cockpit | `[updates] containers`, default `"daily"` |
| Configs | `lm-server sync`, Cockpit | every 5 min |

Schedules are systemd timers, not cron. They take calendar expressions like
`"daily"`, `"Sun 04:00"` or `"*-*-01 03:00"`. Check one with
`systemd-analyze calendar "Sun 04:00"`. `lm-server status` shows the next run of
each timer, and Cockpit > lm-server > *Automatic runs* shows what they did.

## Disks

The data disk is mounted at **`/var/mnt/data`**. Services use these folders on it:
`disk_0/`, `docs/` (FileBrowser and Syncthing) and `immich/`. They are created
automatically. Set the disk up in **Cockpit > Storage**:
1. For a mirror, create a RAID device (MDRAID, RAID 1) from the two disks.
2. Format it (XFS) with mount point `/var/mnt/data`.

Cockpit writes `/etc/fstab`, and bootc keeps `/etc` across upgrades. Until a
disk is mounted there, the folders sit on the system disk.

### Migrating from Proxmox (ZFS `hdd-mirror`)

`hdd-mirror` is a ZFS mirror holding `subvol-100-disk-0/1` (disk_0, docs) and
`vm-102-disk-0` (the Docker VM, which holds the Immich data). Fedora has no ZFS.
The recommended path is to switch the mirror to mdraid + XFS in place, one disk
at a time. Take a **backup first**: redundancy is gone during the copy.

1. On Proxmox, stop CT 100 and VM 102, then run `zpool detach hdd-mirror <disk2>`.
   The pool keeps running on one disk.
2. Create a degraded RAID 1 on disk 2 and format it:
   `mdadm --create /dev/md0 --level=1 --raid-devices=2 <disk2> missing`, then
   `mkfs.xfs /dev/md0` and mount it (e.g. `/mnt/new`).
3. Copy the data:
   - `rsync -aHAX /hdd-mirror/subvol-100-disk-0/ /mnt/new/disk_0/`, and the same
     for `disk-1` → `docs/`.
   - For Immich, mount the VM disk read-only (`/dev/zvol/hdd-mirror/vm-102-disk-0`)
     and copy the library to `/mnt/new/immich/`.
   - Dump the databases in VM 102 (see below).
4. Install lm-server. In Cockpit > Storage, mount `md0` at `/var/mnt/data`.
5. Once everything works, `zpool destroy`, then
   `mdadm --add /dev/md0 <disk1>`. The mirror rebuilds itself.

The pool is 96.5% full (466 of 483 GB). The 400 GB VM disk holds much less
real data, but check `du` inside VM 102 before copying.

Other state:

| Old | New |
|---|---|
| CT 100 syncthing config | `/var/lib/lm-server/data/disks/syncthing/` (**with `cert.pem`/`key.pem`**, to keep the device ID) |
| CT 100 filebrowser db | `/var/lib/lm-server/data/disks/filebrowser/database.db` |
| VM 102 immich DB | dump → restore (Immich docs: *Backup and restore*) |
| VM 102 guacamole DB | `pg_dump` → restore into `remote-db` (keeps connections) |
| VM 102 nightscout | `mongodump` → `mongorestore` into `sugar-mongo` |
| VM 102 convertx | `/var/lib/lm-server/data/convert/` |
| VM 104 win11 | `qemu-img convert` → qcow2, import in Cockpit > Virtual machines |

Stop a service while copying its data (`lm-server stop <svc>`), then start it again.

## First install

1. Download `lm-server-<tag>.iso` from the latest release. If it was split
   (>2 GB), join it with `cat lm-server-*.iso.part-* > lm-server.iso`, then check
   it against the `.sha256`.
2. In the installer, set the system disk, network (a static IP), timezone and an
   admin user.
3. After the reboot, tty1 asks for the secrets repo: owner/name, branch, GitHub
   username and a **fine-grained token** with *Contents: read-only*. GitHub doesn't
   accept account passwords for git. You can skip this step and do it later in
   Cockpit > lm-server.
4. The server fetches `lm-server.toml`, applies `[host]`, then starts the
   configured services and creates their users.

## CLI

```
lm-server status | history [N] | routes | services
lm-server setup | sync [--force]
lm-server upgrade [--check|--apply] | rollback | update [--dry-run]
lm-server start|stop|restart|logs <service>
lm-server prune-adhoc
```

## Repository

```
Containerfile, build_files/            system image (numbered hooks, like immutable-sbc)
system_files/                          copied onto / of the system image
  usr/share/containers/systemd/<svc>/  quadlets, one folder per service
  usr/libexec/lm-server/render.py      lm-server.toml -> per-service env/config files,
                                       + the service catalog (units, routes)
  usr/libexec/lm-server/provision/     creates users (APIs / SQL / CLI) on config change
  usr/share/cockpit/lm-server/         the Cockpit page
  usr/bin/lm-server                    the CLI
images/webapp/                         our own service image
disk_config/                           bootc-image-builder configs (ISO, qcow2)
lm-server-config-secrets/                     TEMPLATE of the private secrets repo
scripts/                               release changelog helpers (from immutable-sbc)
```

CI: [build.yml](.github/workflows/build.yml) builds the system image, pushes and
signs it, publishes release `v44.YYYYMMDD[.N]` with a package + commit changelog,
and attaches the ISO ([build-iso.yml](.github/workflows/build-iso.yml)).
[build-images.yml](.github/workflows/build-images.yml) builds `images/*`.
The repo secret **`SIGNING_SECRET`** is required: the cosign key matching
`system_files/etc/pki/containers/lukemech-cosign.pub`. The server refuses unsigned
`ghcr.io/lukemech/*` images.

Local: `just build`, `just build-image webapp`, `just build-iso`, `just build-qcow2 && just run-vm`.

**Adding a service**:
1. Create a quadlet folder in `system_files/usr/share/containers/systemd/<svc>/`.
   Add `ConditionPathExists=/var/lib/lm-server/env/<svc>/enabled`, and give
   pod members `[Install] WantedBy=<svc>-pod.service`.
2. Add an entry to `SERVICES` and a `r_<svc>` function in `render.py`.
3. If the service has users, add `provision/<svc>.sh`.
4. Add a `[<svc>]` section to the template.
