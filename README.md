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
| Configs (lm-server.toml) | `lm-server config pull` (= `sync`), Cockpit *Sync configs* | `[updates] config`, default `"hourly"`; `"manual"` = at boot + on demand |

**Editing the config from Cockpit**: *Configuration (lm-server.toml)* loads
the file from the secrets repo. *Save, push & apply* checks it, commits and
pushes it to GitHub, then applies it right away (`lm-server config show|save`
on the CLI). Pushing needs the token to have *Contents: Read and write* on the
secrets repo. With a read-only token, edit in GitHub and use *Sync configs*.
If someone changed the repo meanwhile, the save is refused. Reload and redo the edit.

Schedules are systemd timers, not cron. They take calendar expressions like
`"daily"`, `"Sun 04:00"` or `"*-*-01 03:00"`. Check one with
`systemd-analyze calendar "Sun 04:00"`. `lm-server status` shows the next run of
each timer, and Cockpit > lm-server > *Automatic runs* shows what they did.

## Disks

Every service keeps all of its data in one folder,
`/var/lib/lm-server/volumes/<service>/`. That's the Immich library and database,
FileBrowser/Syncthing's `disk_0/` and `docs/`, the Guacamole DB, and so on. By
default the folder is on the system disk. To use a different disk for a
service, set `storage` in its section of `lm-server.toml`:

```toml
[disks]
storage = "/var/mnt/hdd"   # HDD mirror
[immich]
storage = "/var/mnt/nvme"  # 2 TB NVMe
```

The service's data then lives in `<disk>/<service>/`, bind-mounted in place of
its folder. If you change `storage` later, the next sync stops the service,
copies its data to the new disk (only if the target is empty), and starts it
again. The old copy is never deleted automatically.

**What happens on a `storage` change** (e.g. `/var/mnt/hdd` → `/var/mnt/nvme`):
1. The service is stopped.
2. If `<new disk>/<service>/` is empty, the data is copied there (`rsync`,
   progress in Cockpit > lm-server > Automatic runs / `lm-server history`). If it
   already holds data, nothing is copied and that data is used as is.
3. The folder is bind-mounted from the new place and the service starts again.
4. The old copy stays where it was. Delete it by hand once everything works.

If the disk behind `storage` isn't mounted at boot, the service doesn't start
(`RequiresMountsFor`), so nothing gets written to the wrong disk. If the disk is
**replaced with an empty one** mounted at the same path, the service starts
empty, like a fresh install. Restore its data first (see below).

**Moving data by hand**, e.g. for a large library over several sessions, or
when restoring a backup:

```sh
lm-server stop immich
rsync -aHA --info=progress2 /var/lib/lm-server/volumes/immich/ /var/mnt/nvme/immich/
# edit [immich] storage = "/var/mnt/nvme" (Cockpit editor or the repo)
lm-server sync      # target isn't empty -> no copy, just switch and start
```

`/var/lib/lm-server/volumes/<service>/` always shows the service's current
data, wherever it lives.

**CPU and RAM per service**: `cpus = 2` (cores, `0.5` works) and `memory = "4G"`
in a service's section cap all of its containers together, like the
cores/RAM of a Proxmox guest. They're applied live via the service's systemd
slice `lm-server-<service>.slice`. Leave them out for no limit;
`lm-server services` shows usage against the limit. Swap is **zram** (half of RAM,
max 8 GiB, zstd), configured in `/usr/lib/systemd/zram-generator.conf`.

Disks are set up in **Cockpit > Storage**. Cockpit writes `/etc/fstab`, and
bootc keeps `/etc` across upgrades.
- **NVMe**: format XFS, mount point `/var/mnt/nvme`.
- **HDD mirror**: create a RAID device (MDRAID, RAID 1) from both disks, format
  it XFS, mount point `/var/mnt/hdd`.

Suggested layout for this machine:

| Disk | Use |
|---|---|
| 120 GB SSD (`sda`) | system (bootc), small services on the default `storage` |
| 2 TB NVMe | `/var/mnt/nvme`: Immich (fast, room for the library) |
| 2×500 GB HDD, RAID 1 | `/var/mnt/hdd`: disks (Keepass/Sync, redundant) |

The NVMe is a single disk. Keep a backup of anything on it that you can't lose.

### Migrating from Proxmox

Step by step, including Immich, disk_0/docs, Syncthing, FileBrowser and the
ZFS `hdd-mirror`: **[MIGRATION.md](MIGRATION.md)**.

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
lm-server setup | sync [--force] (= config pull) | config show | config save < lm-server.toml
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
