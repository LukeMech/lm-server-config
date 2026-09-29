#!/usr/bin/python3
"""lm-server containers [--json]: the image every system container runs and
what `podman auto-update` would update it to.

Containers are the ones systemd runs from the image's quadlets (label
PODMAN_SYSTEMD_UNIT). For each: its image, the version it runs now
(org.opencontainers.image.version, build date, digest) and -- if the registry
has a newer one -- the same for that image. "Newer" is podman auto-update's
own verdict (--dry-run); skopeo only fetches the details of those images.
"""
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

VERSION_LABELS = ("org.opencontainers.image.version", "version")


def run(*cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def image_info(inspect):
    labels = inspect.get("Labels") or inspect.get("Config", {}).get("Labels") or {}
    return {
        "digest": inspect.get("Digest", ""),
        "created": inspect.get("Created", ""),
        "version": next((labels[k] for k in VERSION_LABELS if labels.get(k)), ""),
        "revision": labels.get("org.opencontainers.image.revision", ""),
    }


def containers():
    # --pod: fills in PodName (the service of a multi-container service)
    out = run("podman", "ps", "-a", "--pod", "--format", "json", timeout=60)
    if out.returncode:
        raise RuntimeError(out.stderr.strip() or "podman ps failed")
    result = []
    for c in json.loads(out.stdout or "[]"):
        labels = c.get("Labels") or {}
        unit = labels.get("PODMAN_SYSTEMD_UNIT")
        if not unit or c.get("IsInfra"):
            continue  # ad-hoc container, or a pod's infra (pause) container
        name = (c.get("Names") or [""])[0]
        result.append({
            "service": c.get("PodName") or unit.removesuffix(".service"),
            "container": name,
            "unit": unit,
            "id": c.get("Id", ""),
            "image": c.get("Image", ""),
            "image_id": c.get("ImageID", ""),
            "state": c.get("State", ""),
            "policy": labels.get("io.containers.autoupdate", ""),
            "update": None,  # "pending" | "false" | None (no auto-update policy / unknown)
            "current": {},
            "available": None,
            "error": "",
        })
    return result


def dry_run():
    """{container id or name: report} from podman auto-update --dry-run."""
    out = run("podman", "auto-update", "--dry-run", "--format", "json")
    reports = {}
    try:
        data = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        data = []
    for r in data or []:
        for key in ("ContainerID", "ContainerName", "Container"):
            if r.get(key):
                reports[r[key]] = r
    return reports, (out.stderr.strip() if out.returncode else "")


def remote(image):
    out = run("skopeo", "inspect", "--no-tags", "docker://" + image, timeout=120)
    if out.returncode:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "skopeo failed")
    return image_info(json.loads(out.stdout))


def main(argv):
    as_json = "--json" in argv
    try:
        items = containers()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as ex:
        print(f"lm-server: {ex}", file=sys.stderr)
        return 1

    with ThreadPoolExecutor(max_workers=8) as pool:
        check = pool.submit(dry_run)
        ids = sorted({c["image_id"] for c in items if c["image_id"]})
        local = dict(zip(ids, pool.map(lambda i: run("podman", "image", "inspect", i, timeout=60), ids)))
        reports, error = check.result()

        for c in items:
            out = local.get(c["image_id"])
            if out is not None and out.returncode == 0:
                c["current"] = image_info((json.loads(out.stdout) or [{}])[0])
            r = reports.get(c["id"]) or reports.get(c["id"][:12]) or reports.get(c["container"])
            if r:
                c["update"] = str(r.get("Updated", "")).lower()
            elif c["policy"] and error:
                c["error"] = error.splitlines()[-1]

        # Details of the images auto-update would pull (one lookup per image).
        pending = sorted({c["image"] for c in items if c["update"] == "pending"})
        found = {}
        for image, fut in [(i, pool.submit(remote, i)) for i in pending]:
            try:
                found[image] = fut.result()
            except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as ex:
                found[image] = {"error": str(ex)}
        for c in items:
            if c["image"] in found:
                c["available"] = found[c["image"]]

    items.sort(key=lambda c: (c["service"], c["container"]))
    if as_json:
        json.dump(items, sys.stdout, indent=1)
        print()
        return 0

    def ver(i):
        if not i:
            return "-"
        if i.get("error"):
            return "? (" + i["error"] + ")"
        return " ".join(x for x in (i.get("version"), i.get("created", "")[:10], i.get("digest", "")[7:19]) if x) or "-"

    print(f"{'SERVICE':<10} {'CONTAINER':<26} {'CURRENT':<34} AVAILABLE")
    for c in items:
        avail = ver(c["available"]) if c["update"] == "pending" else (
            "up to date" if c["update"] == "false" else (c["error"] or "not auto-updated"))
        print(f"{c['service']:<10} {c['container']:<26} {ver(c['current']):<34} {avail}")
    print(f"\n{sum(c['update'] == 'pending' for c in items)} of {len(items)} containers have an update"
          " (lm-server update pulls them).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
