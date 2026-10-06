#!/usr/bin/python3
"""lm-server containers cleanup: removes the images nothing uses any more.

An image stays if a container (running or not) uses it, or if a quadlet names
it (Image= in the image's quadlets or their drop-ins in /etc, e.g. a version
from lm-server.toml) -- so a service that is stopped or disabled right now
doesn't have to pull it again. Everything else goes: the images a container
update replaced, tags no quadlet uses any more (valkey:8-bookworm after the
switch to 9-alpine), dangling <none> layers, images of ad-hoc containers that
are gone. Runs after every container update (lm-server containers update,
podman-auto-update.service).
"""
import glob
import json
import subprocess
import sys

QUADLET_DIRS = ("/usr/share/containers/systemd", "/etc/containers/systemd")


def run(*cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def quadlet_images():
    names = set()
    for d in QUADLET_DIRS:
        for pattern in ("**/*.container", "**/*.d/*.conf"):
            for path in glob.glob(f"{d}/{pattern}", recursive=True):
                try:
                    with open(path, encoding="utf-8") as f:
                        for line in f:
                            if line.startswith("Image="):
                                names.add(line[len("Image="):].strip())
                except OSError:
                    pass
    return names


def main():
    out = run("podman", "images", "--format", "json", timeout=60)
    if out.returncode:
        print(f"lm-server: {out.stderr.strip() or 'podman images failed'}", file=sys.stderr)
        return 1
    images = json.loads(out.stdout or "[]")
    ps = run("podman", "ps", "-a", "--format", "json", timeout=60)
    used = {c.get("ImageID", "") for c in json.loads(ps.stdout or "[]")} if ps.returncode == 0 else None
    if used is None:
        print("lm-server: cannot list containers -- nothing removed", file=sys.stderr)
        return 1
    keep = quadlet_images()

    removed, freed = [], 0
    for img in images:
        iid = img.get("Id", "")
        names = img.get("Names") or []
        if img.get("Containers") or iid in used or any(n in keep for n in names):
            continue
        r = run("podman", "rmi", iid, timeout=120)
        if r.returncode == 0:
            removed.append(", ".join(names) or f"<none> {iid[:12]}")
            freed += img.get("Size", 0) or 0
        else:
            print(f"lm-server: kept {', '.join(names) or iid[:12]}: {(r.stderr.strip().splitlines() or [''])[-1]}",
                  file=sys.stderr)
    run("podman", "image", "prune", "-f", timeout=300)  # layers left dangling by the above

    for name in removed:
        print(f"removed {name}")
    print(f"{len(removed)} unused image(s) removed, {freed / 1e6:.0f} MB freed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
