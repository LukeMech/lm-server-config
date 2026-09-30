#!/usr/bin/python3
"""lm-server resources [--json] [--no-disk]: per service, what it may use and
what it uses now.

CPU and memory are those of lm-server-<svc>.slice (all of the service's
containers together; limits = `cpus` / `memory` in lm-server.toml). CPU is
measured over one second. Memory is what the service really holds (its
cgroup's memory.current minus inactive_file, the cache the kernel drops first
-- like `docker stats`); memory_cache is its whole page cache, reclaimed as
needed. Disk is its data folder, volumes/<svc>: used and
size when it's a filesystem of its own (`storage = "80G"`, or a `disk` folder
that is a mount), else only what's used (du -- slow on big folders;
--no-disk skips those).

Also the whole machine ("host"): CPU busy over the same second, RAM used
(MemTotal - MemAvailable, as Cockpit's overview), the sum of the services'
limits, and the read/write rate of every disk and RAID array.

--json: {"host": {...}, "services": [...]}.
"""
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

STATE = "/var/lib/lm-server"
PROPS = "Id,ActiveState,MemoryCurrent,MemoryMax,CPUUsageNSec,CPUQuotaPerSecUSec,TasksCurrent,ControlGroup"


def run(*cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def catalog():
    out = run("/usr/libexec/lm-server/render.py", "services")
    for line in out.stdout.splitlines():
        name, units, _routes, desc = (line.split("\t") + ["", "", ""])[:4]
        yield name, units.split(), desc


def show(units, props=PROPS):
    """systemctl show for several units: {Id: {prop: value}}."""
    if not units:
        return {}
    out = run("systemctl", "show", "-p", props, *units)
    result, cur = {}, {}
    for line in out.stdout.splitlines() + [""]:
        if not line:
            if cur.get("Id"):
                result[cur["Id"]] = cur
            cur = {}
            continue
        k, _, v = line.partition("=")
        cur[k] = v
    return result


def number(v):
    return int(v) if v and v.isdigit() else None


def seconds(v):
    """systemd time span ("2s", "500ms", "1min 30s", "infinity") in seconds."""
    if not v or v == "infinity":
        return None
    units = {"us": 1e-6, "ms": 1e-3, "s": 1, "min": 60, "h": 3600}
    total = 0.0
    for part in v.split():
        num = part.rstrip("abcdefghijklmnopqrstuvwxyz")
        total += float(num) * units.get(part[len(num):] or "s", 1)
    return total


def memory_stat(cgroup):
    """A cgroup's memory.stat: {key: bytes}."""
    try:
        with open(f"/sys/fs/cgroup{cgroup}/memory.stat") as f:
            return {k: int(v) for k, v in (l.split() for l in f)}
    except (OSError, ValueError):
        return {}


def cpu_times():
    """/proc/stat: (busy, total) jiffies of all CPUs."""
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    idle = v[3] + (v[4] if len(v) > 4 else 0)  # idle + iowait
    total = sum(v[:8])  # without guest time (already in user/nice)
    return total - idle, total


def meminfo():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            info[k] = int(v.split()[0]) * 1024
    return info


def block_devices():
    """Whole disks and RAID arrays (no partitions, loop, zram, LVM): {name: label}."""
    devs = {}
    for name in sorted(os.listdir("/sys/block")):
        base = f"/sys/block/{name}"
        if os.path.exists(f"{base}/device"):
            try:
                with open(f"{base}/device/model") as f:
                    devs[name] = f.read().strip()
            except OSError:
                devs[name] = ""
        elif os.path.isdir(f"{base}/md"):
            try:
                with open(f"{base}/md/level") as f:
                    devs[name] = f.read().strip().upper()
            except OSError:
                devs[name] = "RAID"
    return devs


def diskstats():
    """/proc/diskstats: {name: (bytes read, bytes written)} (sectors are 512 B)."""
    out = {}
    with open("/proc/diskstats") as f:
        for line in f:
            v = line.split()
            out[v[2]] = (int(v[5]) * 512, int(v[9]) * 512)
    return out


def disk(svc, with_du):
    vol = f"{STATE}/volumes/{svc}"
    info = {"path": vol, "used": None, "size": None, "kind": "system"}
    if not os.path.isdir(vol):
        return info
    unit = f"/etc/systemd/system/{run('systemd-escape', '-p', '--suffix=mount', vol).stdout.strip()}"
    what = ""
    if os.path.exists(unit):
        with open(unit) as f:
            what = next((l.split("=", 1)[1].strip() for l in f if l.startswith("What=")), "")
    if not what:
        # A storage image: mounted from its /etc/fstab entry (see lm-server).
        tag = f"# lm-server {svc}: "
        try:
            with open("/etc/fstab") as f:
                what = next((l[len(tag):].split()[0] for l in f if l.startswith(tag)), "")
        except OSError:
            pass
    if what.endswith(".img"):
        info.update(kind="image", image=what)
    elif what:
        info.update(kind="storage", folder=what)
    # A filesystem of its own (image, or a storage folder that is a mount point).
    own = os.path.ismount(vol) and (info["kind"] == "image" or os.path.ismount(what))
    if own:
        st = os.statvfs(vol)
        info["size"] = st.f_blocks * st.f_frsize
        info["used"] = (st.f_blocks - st.f_bfree) * st.f_frsize
    elif with_du:
        try:
            out = run("du", "-sxb", vol, timeout=120)
            info["used"] = int(out.stdout.split()[0]) if out.stdout else None
        except subprocess.TimeoutExpired:
            info["error"] = "too big to measure quickly"
    return info


def main(argv):
    as_json = "--json" in argv
    with_du = "--no-disk" not in argv
    services = list(catalog())
    units = sorted({u + ".service" for _, us, _ in services for u in us})
    # A pod's unit stays active while one of its containers fails: the
    # containers count too (the units the pod wants -- quadlet adds them).
    members = {}
    for pod, info in show([u for u in units if u.endswith("-pod.service")], "Id,Wants").items():
        members[pod] = [w for w in info.get("Wants", "").split() if w.endswith(".service")]
    slices = [f"lm-server-{name}.slice" for name, _, _ in services]

    with ThreadPoolExecutor(max_workers=6) as pool:
        disks = {name: pool.submit(disk, name, with_du) for name, _, _ in services}
        before = show(slices)
        cpu0, io0 = cpu_times(), diskstats()
        t0 = time.monotonic()
        time.sleep(1)
        after = show(slices + units + sorted({m for ms in members.values() for m in ms}))
        cpu1, io1 = cpu_times(), diskstats()
        dt = time.monotonic() - t0

        result = []
        for name, us, desc in services:
            sl = f"lm-server-{name}.slice"
            a, b = after.get(sl, {}), before.get(sl, {})
            cpu = None
            if number(a.get("CPUUsageNSec")) is not None and number(b.get("CPUUsageNSec")) is not None:
                cpu = (number(a["CPUUsageNSec"]) - number(b["CPUUsageNSec"])) / 1e9 / dt * 100
            current = number(a.get("MemoryCurrent"))
            stat = memory_stat(a.get("ControlGroup", "")) if current is not None else {}
            memory = None if current is None else max(0, current - stat.get("inactive_file", 0))
            result.append({
                "service": name,
                "description": desc,
                "enabled": os.path.exists(f"{STATE}/env/{name}/enabled"),
                # Not a container: a program of the system image with its own
                # unit (cloudflared) -- updated with the image, not by podman.
                "builtin": all(u.startswith("lm-server-") for u in us),
                "units": {x.removesuffix(".service"): after.get(x, {}).get("ActiveState", "unknown")
                          for u in us for x in [u + ".service", *members.get(u + ".service", [])]},
                "cpu_percent": None if cpu is None else round(cpu, 1),  # 100 = one core
                "cpu_limit": seconds(a.get("CPUQuotaPerSecUSec")),       # cores
                "host_cpus": os.cpu_count(),
                "memory": memory,
                "memory_cache": stat.get("file"),
                "memory_limit": number(a.get("MemoryMax")),
                "tasks": number(a.get("TasksCurrent")),
                "disk": disks[name].result(),
            })

    busy, ticks = cpu1[0] - cpu0[0], cpu1[1] - cpu0[1]
    mem = meminfo()
    enabled = [r for r in result if r["enabled"]]

    def rate(name, i):
        return round((io1[name][i] - io0[name][i]) / dt) if name in io0 and name in io1 else None

    host = {
        "cpus": os.cpu_count(),
        "cpu_percent": round(busy / ticks * 100, 1) if ticks > 0 else None,  # 100 = all threads
        "cpu_limits": sum(r["cpu_limit"] or 0 for r in enabled),
        "memory_total": mem.get("MemTotal"),
        "memory_used": mem.get("MemTotal", 0) - mem.get("MemAvailable", 0),
        "memory_limits": sum(r["memory_limit"] or 0 for r in enabled),
        "disks": [{"name": name, "label": label, "read": rate(name, 0), "write": rate(name, 1)}
                  for name, label in block_devices().items()],
    }

    if as_json:
        json.dump({"host": host, "services": result}, sys.stdout, indent=1)
        print()
        return 0

    def iec(n):
        if n is None:
            return "-"
        for unit in ("B", "K", "M", "G", "T"):
            if n < 1024 or unit == "T":
                return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
            n /= 1024

    cpu = "-" if host["cpu_percent"] is None else f"{host['cpu_percent']:.0f}%"
    print(f"CPU {cpu} of {host['cpus']} threads (limits: {host['cpu_limits']:g}), "
          f"RAM {iec(host['memory_used'])} / {iec(host['memory_total'])} (limits: {iec(host['memory_limits'])})")
    for d in host["disks"]:
        print(f"  {d['name']:<10} read {iec(d['read']):>7}/s  write {iec(d['write']):>7}/s  {d['label']}")
    print()
    print(f"{'SERVICE':<12} {'STATE':<10} {'CPU':>7} {'LIMIT':>6}  {'MEMORY':>7} {'LIMIT':>7}  {'DISK':>7} {'SIZE':>7}")
    for r in result:
        states = set(r["units"].values())
        state = "active" if states == {"active"} else ("-" if not r["enabled"] else ",".join(sorted(states)))
        cpu = "-" if r["cpu_percent"] is None else f"{r['cpu_percent']:.0f}%"
        lim = "-" if r["cpu_limit"] is None else f"{r['cpu_limit']:g} thr"
        d = r["disk"]
        print(f"{r['service']:<12} {state:<10} {cpu:>7} {lim:>6}  {iec(r['memory']):>7} {iec(r['memory_limit']):>7}"
              f"  {iec(d['used']):>7} {iec(d['size']):>7}")
    print("\nCPU: 100% = one thread busy; LIMIT = cpus (threads). MEMORY without reclaimable cache. Limits: cpus / memory / storage in lm-server.toml.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
