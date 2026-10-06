#!/usr/bin/python3
"""lm-server containers [--json] [--no-check]: the image every system container runs and
what `podman auto-update` would update it to.

Containers are the ones systemd runs from the image's quadlets (label
PODMAN_SYSTEMD_UNIT). For each: its image, the version it runs now
(org.opencontainers.image.version, build date, digest) and -- if the registry
has a newer one -- the same for that image. "Newer" is podman auto-update's
own test, made for every image at once instead of one after another: the
digest of the manifest the registry serves for the tag (skopeo --raw: the
manifest list's, for a multi-arch image) is not one this image was pulled as.
A container with a source (image_sources.py) is compared with the image its
source names instead ("source": the file's URL).
"""
import hashlib
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import image_sources

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
            "labels": labels,
            "policy": labels.get("io.containers.autoupdate", ""),
            "update": None,  # "pending" | "false" | None (no auto-update policy / unknown)
            "current": {},
            "available": None,
            "source": "",
            "error": "",
        })
    return result


def remote_digest(image):
    """Digest of the manifest the registry serves for image's tag -- what
    podman auto-update compares with the local image's."""
    out = subprocess.run(["skopeo", "inspect", "--raw", "docker://" + image], capture_output=True, timeout=120)
    if out.returncode:
        err = out.stderr.decode(errors="replace").strip()
        raise RuntimeError(err.splitlines()[-1] if err else "skopeo failed")
    return "sha256:" + hashlib.sha256(out.stdout).hexdigest()


def local_digests(inspect):
    """Every digest the local image is known by (its own, and the repo
    digests of what it was pulled as, e.g. a manifest list's)."""
    found = {inspect.get("Digest", "")}
    found.update(d.rsplit("@", 1)[-1] for d in inspect.get("RepoDigests") or [])
    return found - {""}


def remote(image):
    out = run("skopeo", "inspect", "--no-tags", "docker://" + image, timeout=120)
    if out.returncode:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "skopeo failed")
    return image_info(json.loads(out.stdout))


def main(argv):
    as_json = "--json" in argv
    # --no-check: only what runs here (quick, no registry): "update" stays null.
    check_registry = "--no-check" not in argv
    try:
        items = containers()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as ex:
        print(f"lm-server: {ex}", file=sys.stderr)
        return 1

    with ThreadPoolExecutor(max_workers=12) as pool:
        # Everything that talks to a registry (or GitHub) at once.
        tags = sorted({c["image"] for c in items if c["policy"] == "registry"}) if check_registry else []
        digests = {i: pool.submit(remote_digest, i) for i in tags}
        sources = pool.submit(image_sources.check, items, check_registry)
        ids = sorted({c["image_id"] for c in items if c["image_id"]})
        local = dict(zip(ids, pool.map(lambda i: run("podman", "image", "inspect", i, timeout=60), ids)))
        sourced = sources.result()

        for c in items:
            out = local.get(c["image_id"])
            data = (json.loads(out.stdout) or [{}])[0] if out is not None and out.returncode == 0 else {}
            if data:
                c["current"] = image_info(data)
            fut = digests.get(c["image"])
            if fut is None:
                continue
            try:
                c["update"] = "false" if fut.result() in local_digests(data) else "pending"
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as ex:
                c["error"] = str(ex)
        # A source naming another image beats the registry's verdict on this one.
        for c in sourced:
            if c["wanted"] and c["wanted"] != c["image"]:
                c["update"] = "pending"

        # Details of the images auto-update would pull (one lookup per image).
        target = lambda c: c.get("wanted") or c["image"]
        pending = sorted({target(c) for c in items if c["update"] == "pending"})
        found = {}
        for image, fut in [(i, pool.submit(remote, i)) for i in pending]:
            try:
                found[image] = fut.result()
            except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as ex:
                found[image] = {"error": str(ex)}
        for c in items:
            if c["update"] == "pending" and target(c) in found:
                c["available"] = dict(found[target(c)], image=target(c))
            for k in ("labels", "wanted", "pinned"):
                c.pop(k, None)

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
            ("up to date" + (" (source)" if c["source"] else "")) if c["update"] == "false"
            else (c["error"] or "not auto-updated"))
        print(f"{c['service']:<10} {c['container']:<26} {ver(c['current']):<34} {avail}")
    print(f"\n{sum(c['update'] == 'pending' for c in items)} of {len(items)} containers have an update"
          " (lm-server containers update pulls them).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
