# Migrating from Proxmox to lm-server

The whole move happens on the same machine. The ZFS pool is left untouched
until the very last phase, so until then you can always go back.

| Disk | Today (Proxmox) | Target (lm-server) |
|---|---|---|
| 120 GB SSD (`sda`) | Proxmox system | lm-server system (bootc) |
| 2 TB NVMe | `NVME_2TB` (LVM) | new LV `lmdata`, mounted at `/var/mnt/nvme`: staging area, then optionally Immich |
| 2×500 GB HDD (`sdb`, `sdc`) | ZFS `hdd-mirror`: `vm-102-disk-0` (Docker VM, Immich), `subvol-100-disk-0/1` (disk_0, docs) | mdraid RAID 1 + XFS at `/var/mnt/hdd`: disks (+ Immich) |

Placeholders used below:
- `<VG>`: the NVMe volume group
- `<pool>`: its thin pool, if there is one
- `10.0.0.1`: the Proxmox host as seen from VM 102

Check these values before running anything.

---

## 0. Dry run in a VM

1. On the current Proxmox, create a VM: 4 GB RAM, 2 cores, a 40 GB disk on
   `NVME_2TB`, booting the ISO from the latest release.
2. Install it. Point setup at the secrets repo with a **test** `lm-server.toml`:
   different passwords, **no `[cloudflared]`** (don't take over the production
   tunnel).
3. Check `lm-server status`, `lm-server services`, and Cockpit at
   `https://<vm-ip>:9090`. Web UIs listen on 127.0.0.1, so to open one use e.g.
   `ssh -L 2283:localhost:2283 <admin>@<vm-ip>`.
4. Rehearse step 6 with a copy of the Immich dump.

If something doesn't come up, `lm-server history` and `lm-server logs <service>`
show why.

## 1. Inventory (changes nothing)

On Proxmox:
```sh
zfs list -o name,used,refer,mountpoint -r hdd-mirror   # real size of the subvols and the zvol
vgs; lvs                                               # what is on the NVMe, how much is free
```

In VM 102, in the Immich `docker-compose.yml` directory:
```sh
cat .env        # note UPLOAD_LOCATION, DB_DATA_LOCATION, DB_PASSWORD, IMMICH_VERSION
grep -n "upload\|/data" docker-compose.yml
du -sh "$UPLOAD_LOCATION"
docker ps --format '{{.Names}}'   # name of the postgres container (default: immich_postgres)
```

In CT 100 (or from the host: `pct mount 100`, then look under `/var/lib/lxc/100/rootfs`):
```sh
find / -name cert.pem -path '*syncthing*' 2>/dev/null      # Syncthing config directory
find / \( -name database.db -o -name config.yaml \) 2>/dev/null | grep -i filebrowser
```

`Immich library + ~55 GB` must fit in the NVMe's free space now, and on the
500 GB mirror (~480 GB usable) later if Immich goes there.

## 2. Update Immich on the old server first

The new server runs `immich-server:release`, the newest release. A database
dump restores into the same or a newer version, so bring the old one up to
date first:

1. In `.env`, set `IMMICH_VERSION=release`.
2. In `docker-compose.yml`, the library volume must be `- ${UPLOAD_LOCATION}:/data`.
   If it's still `/usr/src/app/upload`, change it as the Immich release notes
   describe. Immich rewrites the paths in its database itself.
3. Run `docker compose pull && docker compose up -d`. Wait for the migrations
   and check that photos open.

## 3. Staging area on the NVMe (on Proxmox)

Create a new LV. The NVMe isn't reformatted, so what's already on it (e.g.
the win11 disk) stays. Size it from step 1.

```sh
# plain LVM:
lvcreate -L 800G -n lmdata <VG>
# or, if the VG is a thin pool ("twi" in lvs):
lvcreate -V 800G -T <VG>/<pool> -n lmdata

mkfs.xfs -L lmdata /dev/<VG>/lmdata
mkdir -p /mnt/lmdata && mount /dev/<VG>/lmdata /mnt/lmdata
mkdir -p /mnt/lmdata/disks/{disk_0,docs,syncthing/config,filebrowser} \
         /mnt/lmdata/immich/library /mnt/lmdata/_migration
```

The layout `<disk>/<service>/...` is exactly what lm-server's `storage`
expects, so nothing needs moving later.

## 4. Copy: first pass live, final pass stopped

The first pass runs while everything still works. The final pass only moves
what changed, so the downtime is minutes, not hours.

### First pass (services running)
```sh
# on Proxmox -- CT 100 is unprivileged; the new containers run as root, so owners become root
rsync -aH --info=progress2 --chown=0:0 /hdd-mirror/subvol-100-disk-0/ /mnt/lmdata/disks/disk_0/
rsync -aH --info=progress2 --chown=0:0 /hdd-mirror/subvol-100-disk-1/ /mnt/lmdata/disks/docs/

# in VM 102 -- over the network to the host
rsync -aH --info=progress2 "$UPLOAD_LOCATION"/ root@10.0.0.1:/mnt/lmdata/immich/library/
```

### Final pass (downtime starts)
```sh
# in VM 102: stop Immich but keep its database up for the dump
docker compose stop immich-server immich-machine-learning
docker exec -t immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > /tmp/immich-dump.sql.gz
docker compose down
rsync -aH --delete --info=progress2 "$UPLOAD_LOCATION"/ root@10.0.0.1:/mnt/lmdata/immich/library/
scp /tmp/immich-dump.sql.gz root@10.0.0.1:/mnt/lmdata/_migration/
```

```sh
# on Proxmox: CT 100
pct stop 100
rsync -aH --delete --info=progress2 --chown=0:0 /hdd-mirror/subvol-100-disk-0/ /mnt/lmdata/disks/disk_0/
rsync -aH --delete --info=progress2 --chown=0:0 /hdd-mirror/subvol-100-disk-1/ /mnt/lmdata/disks/docs/
pct mount 100
rsync -a --chown=0:0 /var/lib/lxc/100/rootfs/<syncthing-config-dir>/ /mnt/lmdata/disks/syncthing/config/
cp /var/lib/lxc/100/rootfs/<path>/database.db /mnt/lmdata/disks/filebrowser/database.db
pct unmount 100
```

- **Syncthing**: copy the whole config directory, including `cert.pem` and
  `key.pem`. The new server then has the **same device ID** and your devices
  reconnect by themselves. Folder paths (`/mnt/disk_0/Keepass`, `/mnt/disk_0/Sync`)
  are the same inside the new container.
- **Immich**: keep the old `DB_PASSWORD` from `.env`. The dump overwrites the
  `postgres` password, so the new config must use the same one.

Do not touch the ZFS pool. Then run `poweroff`.

## 5. Install lm-server

1. Boot the ISO. In the installer's disk selection, **select only the 120 GB SSD
   (`sda`)**. NVMe and HDDs must stay untouched. Set network and timezone.
   There's no user step: the admin comes from `[host]` in `lm-server.toml`, so
   make sure `admin_user` / `admin_password_hash` are filled in.
2. In the secrets repo's `lm-server.toml`:
   - **comment out `[immich]` for now** (it's restored in step 6);
   - set `[disks] storage = "/var/mnt/nvme"`;
   - fill in the rest, including `[cloudflared]` with the existing tunnel token.
3. After the reboot, give tty1 the repo and the token.
4. Cockpit > **Storage**: activate the NVMe VG if needed. On LV `lmdata`, choose
   **Mount**: mount point `/var/mnt/nvme`, mount at boot. **Do not format it.**
5. Run `lm-server config pull`. `disks` starts from `/var/mnt/nvme/disks`; it
   isn't empty, so nothing is copied, just bind-mounted.

The first start of `disks` takes a while: SELinux labels ~55 GB of files, once.
Then check FileBrowser (the old users are in the copied DB), and Syncthing
(same device ID, folders, devices connecting).

## 6. Restore the Immich database

```sh
# 1. The Immich server must not start before its database is restored:
sudo systemctl mask immich-server.service immich-machine-learning.service
```

2. Uncomment `[immich]`, with `storage = "/var/mnt/nvme"` and
   `db_password = "<the OLD password from .env>"`. Run `lm-server config pull`.
   Only the (empty) database and Valkey start.

```sh
# 3. Restore the dump (Immich's documented procedure, podman flavour):
gunzip -c /var/mnt/nvme/_migration/immich-dump.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | sudo podman exec -i immich-database psql --dbname=postgres --username=postgres

# 4. Server back:
sudo systemctl unmask immich-server.service immich-machine-learning.service
lm-server restart immich
lm-server logs immich -f   # database migrations, then "Immich Server is listening"
```

Check photos, albums and users. The admin and users come from the dump, so
provisioning just skips creating them. The machine-learning models download
again on first use.

## 7. Switch the Cloudflare routes

In the tunnel's *Published application routes*, change each *Service* to
`http://localhost:<port>`. Get the table from `lm-server routes` or the README.
Set `proxmox.lukemech.org` to `https://localhost:9090` with **No TLS Verify**.

## 8. After a few days: from the NVMe to the HDD mirror

Until this step, the ZFS HDDs are an untouched backup. They're readable from
any live USB with ZFS. Once everything works:

1. Cockpit > Storage: wipe both HDDs, then create an **MDRAID** device from
   them (RAID 1). Format it **XFS**, mount point `/var/mnt/hdd`, mount at boot.
   You don't have to wait for the RAID resync to finish; you can copy
   during it.
2. In `lm-server.toml`, set `storage = "/var/mnt/hdd"` in `[disks]` (and in
   `[immich]` if it goes there too). Then run `lm-server config pull`. lm-server
   stops each service, copies its data (rsync; progress in Cockpit >
   *Automatic runs*), and starts it from the mirror.
3. When it all checks out, delete the leftovers on the NVMe:
   `/var/mnt/nvme/disks`, `/var/mnt/nvme/immich` (if Immich moved),
   `/var/mnt/nvme/_migration`.

Keeping Immich on the NVMe is also fine: it's faster, and the mirror holds
`disks`. Either way, keep a separate backup of the photos. RAID 1 doesn't
protect against deleting something by mistake.

## VM 104 (win11)

```sh
# on Proxmox, before step 5 (or later, from the NVMe LV if it lives there):
qemu-img convert -p -O qcow2 <path-or-/dev/<VG>/vm-104-disk-0> /mnt/lmdata/_migration/win11.qcow2
```

On lm-server, go to Cockpit > Virtual machines > Import VM and pick the
qcow2 file. Use UEFI firmware and add a TPM if Windows asks for it.
