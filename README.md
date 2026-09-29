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
  on the LAN). The **Management** page: *Update all* (config, containers,
  system image, each step's status and a progress bar from
  `bootc --progress-fd`), deployments and rollback, every container with the
  version it runs and the one available, status, the history of automatic
  runs, the config editor and GitHub setup. What's pending shows in the
  Overview page's Health card as a link to it. Stock Cockpit covers
  containers, VMs, **disks** and network.
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

## Disks

Every service keeps all of its data in one folder,
`/var/lib/lm-server/volumes/<service>/`. That's the Immich library and database,
the FileBrowser/Syncthing shares, the Guacamole DB, and so on. By
default the folder is on the system disk. To use a different disk for a
service, set `storage` in its section of `lm-server.toml`:

```toml
[disks]
storage = "/var/mnt/hdd-mirror/disks"    # HDD RAID 1, LV "disks"
[immich]
storage = "/var/mnt/hdd-mirror/immich"   # HDD RAID 1, LV "immich"
```

The service's data then lives in exactly that folder, bind-mounted in place of
`volumes/<service>/`. It can be a volume of its own mounted there (an LVM
logical volume, see below), which gives the service a fixed size, or a plain
folder on a disk (e.g. `/var/mnt/nvme/kuma`). Each service needs its own
folder: two services on the same one (or one inside the other) is a config
error. If you change `storage` later, the next sync stops the service,
copies its data to the new disk (only if the target is empty), and starts it
again. The old copy is never deleted automatically.

For `[disks]` that gives, with `shares = ["files"]`:

```
/var/mnt/hdd-mirror/disks/
  shares/files/     FileBrowser source "files" (Syncthing: files/Keepass,
                    files/Sync; documents in files/docs)
  app/syncthing/    Syncthing config + keys (device ID)
  app/filebrowser/  FileBrowser database
```

Both containers see the shares as `/shares/<name>`; in `lm-server.toml` you
only write `<share>/<folder>`.

**What happens on a `storage` change** (e.g. `/var/mnt/hdd-mirror/immich` →
`/var/mnt/nvme/immich`):
1. The service is stopped.
2. If the new folder is empty, the data is copied there (`rsync`,
   progress in Cockpit > Management > Automatic runs / `lm-server history`). If it
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
rsync -aHA --info=progress2 /var/lib/lm-server/volumes/immich/ /var/mnt/hdd-mirror/immich/
# edit [immich] storage = "/var/mnt/hdd-mirror/immich" (Cockpit editor or the repo)
lm-server sync      # target isn't empty -> no copy, just switch and start
```

`/var/lib/lm-server/volumes/<service>/` always shows the service's current
data, wherever it lives.

**CPU and RAM per service**: `cpus = 2` (cores, `0.5` works) and `memory = "4G"`
in a service's section cap all of its containers together, like the
cores/RAM of a Proxmox guest. They're applied live via the service's systemd
slice `lm-server-<service>.slice`. Leave them out for no limit;
`lm-server services` shows usage against the limit. Swap is **zram** (half of RAM,
zstd), configured in `/usr/lib/systemd/zram-generator.conf`.

Disks are set up once, by hand, in **Cockpit > Storage** (formatting wipes
them). Cockpit writes `/etc/fstab`, and bootc keeps `/etc` across upgrades.
Set the disks up **before** pointing `storage` at them: a sync against a path
that isn't mounted yet writes to the system disk (and warns about it).

- **HDD mirror**, split into a fixed-size volume per service:
  1. *Create MDRAID device*: RAID 1, both HDDs, name `hdd-mirror`.
  2. *Create LVM2 volume group* `hdd-mirror` on the new `/dev/md/hdd-mirror`.
  3. In the group, *Create new logical volume* twice, each formatted **XFS**
     and mounted at boot:
     - `immich`, 400 GB, mount point `/var/mnt/hdd-mirror/immich`
     - `disks`, 80 GB, mount point `/var/mnt/hdd-mirror/disks`

     Leave the rest of the group unallocated. XFS can grow (Cockpit: *Grow*,
     online) but never shrink, so spare space in the group is what lets either
     volume grow later.
  4. `storage = "/var/mnt/hdd-mirror/disks"` in `[disks]` and
     `storage = "/var/mnt/hdd-mirror/immich"` in `[immich]`. Each service sees
     its own volume, so FileBrowser shows ~80 GB as its maximum.
- **NVMe**: format the whole disk **XFS**, mount point `/var/mnt/nvme`. No RAID.

Suggested layout for this machine:

| Disk | Use |
|---|---|
| 120 GB SSD (`sda`) | system (bootc), small services on the default `storage` |
| 2×500 GB HDD, RAID 1 + LVM | `/var/mnt/hdd-mirror/immich` (400 GB), `/var/mnt/hdd-mirror/disks` (80 GB) |
| 2 TB NVMe | `/var/mnt/nvme`: scratch space, staging for moves and restores |

The NVMe is a single disk. Keep a backup of anything on it that you can't lose.

**Health and replacing a disk** (Cockpit > Storage): the RAID device page shows
its state (*Clean*, *Degraded*, *Recovering* with progress) and each member
disk. To replace a failed HDD: *Remove* it from the RAID there, swap the disk,
then *Add disk* on the same page; the rebuild starts on its own. Each drive's
page shows its SMART assessment and can run a self-test; from a shell,
`smartctl -a /dev/sdX`, `cat /proc/mdstat` and `mdadm --detail /dev/md/hdd-mirror`.
Fedora's `raid-check.timer` reads the whole mirror weekly and repairs mismatches
between the two disks. Unlike ZFS, mdraid + XFS has no checksums on the data,
so it can't tell which copy is right if a disk returns bad data without
reporting an error.

### Migrating from Proxmox

Step by step, including Immich, disk_0/docs, Syncthing, FileBrowser and the
ZFS `hdd-mirror`: **[MIGRATION.md](MIGRATION.md)**.

## First install

1. Download `lm-server-<tag>.iso` from the latest release. If it was split
   (>2 GB), join it with `cat lm-server-*.iso.part-* > lm-server.iso`, then check
   it against the `.sha256`.
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
storage = "/var/mnt/nvme/kuma"   # optional, like cpus / memory
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
