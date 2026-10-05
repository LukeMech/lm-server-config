#!/usr/bin/python3
"""image_sources.py [--apply]: containers whose image is the one a file upstream names.

A quadlet opts in with a label on its container:

    Label=lm-server.source=https://github.com/immich-app/immich/releases/download/{immich-server}/docker-compose.yml

{<container>} is the version (org.opencontainers.image.version) that container
runs now, so e.g. Immich's database follows the release of the Immich server
that auto-update brought in. The image is the first `image:` in that file of
the same repository as the container's (its tag; a digest there is dropped).
A different major -- the tag's part before the first "-", e.g. Postgres 14 --
is never switched to: that needs a data migration by hand. A version set in
lm-server.toml (`versions = { ... }`, a drop-in of its own) wins over the source.

Without --apply: what each such container runs and what its source names.
--apply (after `podman auto-update`): a container behind its source gets the
source's image as a quadlet drop-in, /etc/containers/systemd/<unit>.d/
image-source.conf, pulled before its service is restarted.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

LABEL = "lm-server.source"
DROPIN = "image-source.conf"
VERSION_LABELS = ("org.opencontainers.image.version", "version")
IMAGE_LINE = re.compile(r"""^\s*image:\s*["']?([^\s"'#]+)""", re.M)


def run(*cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def split(image):
    """repo, tag of an image reference (a digest dropped)."""
    image = image.split("@", 1)[0]
    repo, _, tag = image.rpartition(":")
    if not repo or "/" in tag:
        return image, "latest"
    return repo, tag


def versions():
    """{container name: version its image is labelled with}."""
    out = run("podman", "ps", "-a", "--format", "{{.Names}} {{.ImageID}}", timeout=60)
    names = dict(line.split(" ", 1) for line in out.stdout.splitlines() if " " in line)
    result = {}
    for name, image_id in names.items():
        o = run("podman", "image", "inspect", "--format", "{{json .Labels}}", image_id, timeout=60)
        labels = (json.loads(o.stdout or "null") or {}) if o.returncode == 0 else {}
        result[name] = next((labels[k] for k in VERSION_LABELS if labels.get(k)), "")
    return result


def resolve(template, vers):
    """The source URL with {<container>} filled in, or raise if one isn't known."""
    def fill(m):
        if not vers.get(m.group(1)):
            raise RuntimeError(f"version of {m.group(1)} unknown")
        return vers[m.group(1)]
    return re.sub(r"\{([^}]+)\}", fill, template)


def wanted(url, image):
    """The image of the same repository that the file at url names."""
    with urllib.request.urlopen(url, timeout=30) as r:
        text = r.read().decode()
    repo, tag = split(image)
    for ref in IMAGE_LINE.findall(text):
        r_repo, r_tag = split(ref)
        if r_repo == repo:
            if r_tag.split("-", 1)[0] != tag.split("-", 1)[0]:
                raise RuntimeError(f"source names {r_repo}:{r_tag} -- another major, migrate by hand")
            return f"{repo}:{r_tag}"
    raise RuntimeError(f"no {repo} image in the source")


def pinned(unit):
    """The container's image is set in lm-server.toml (a drop-in other than ours)."""
    d = f"/etc/containers/systemd/{unit.removesuffix('.service')}.container.d"
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".conf") and n != DROPIN)
    except OSError:
        return False
    for n in names:
        with open(os.path.join(d, n), encoding="utf-8") as f:
            if re.search(r"^Image=", f.read(), re.M):
                return True
    return False


def check(items, fetch=True):
    """Fills in source/wanted/pinned/error of each container dict (name, image,
    unit, labels) that has a source. fetch=False: only the source's URL."""
    sourced = [c for c in items if (c.get("labels") or {}).get(LABEL)]
    if not sourced:
        return []
    vers = versions()
    for c in sourced:
        c["source"], c["wanted"], c["error"] = "", "", ""
        c["pinned"] = pinned(c["unit"])
        try:
            c["source"] = resolve(c["labels"][LABEL], vers)
            if fetch and not c["pinned"]:
                c["wanted"] = wanted(c["source"], c["image"])
        except (RuntimeError, OSError, ValueError) as ex:
            c["error"] = str(ex)
    return sourced


def containers():
    out = run("podman", "ps", "-a", "--format", "json", timeout=60)
    if out.returncode:
        raise RuntimeError(out.stderr.strip() or "podman ps failed")
    return [{
        "name": (c.get("Names") or [""])[0],
        "image": c.get("Image", ""),
        "unit": (c.get("Labels") or {}).get("PODMAN_SYSTEMD_UNIT", ""),
        "labels": c.get("Labels") or {},
    } for c in json.loads(out.stdout or "[]")]


def apply(c):
    unit = c["unit"].removesuffix(".service")
    path = f"/etc/containers/systemd/{unit}.container.d/{DROPIN}"
    pull = run("podman", "pull", "-q", c["wanted"], timeout=1800)
    if pull.returncode:
        raise RuntimeError(f"pull {c['wanted']}: {pull.stderr.strip()}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# lm-server: the image {c['source']} names\n[Container]\nImage={c['wanted']}\n")
    for cmd in (("systemctl", "daemon-reload"), ("systemctl", "restart", c["unit"])):
        r = run(*cmd, timeout=1200)
        if r.returncode:
            raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip()}")


def main(argv):
    do_apply = "--apply" in argv
    rc = 0
    try:
        items = check(containers())
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as ex:
        print(f"lm-server: {ex}", file=sys.stderr)
        return 1
    for c in items:
        if c["pinned"]:
            print(f"{c['name']}: {c['image']} (set in lm-server.toml)")
        elif c["error"]:
            print(f"lm-server: {c['name']}: {c['error']}", file=sys.stderr)
            rc = 1
        elif c["wanted"] == c["image"]:
            print(f"{c['name']}: {c['image']} (as its source)")
        elif not do_apply:
            print(f"{c['name']}: {c['image']} -> {c['wanted']} (source: {c['source']})")
        else:
            print(f"lm-server: {c['name']}: {c['image']} -> {c['wanted']}", file=sys.stderr)
            try:
                apply(c)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as ex:
                print(f"lm-server: {c['name']}: {ex}", file=sys.stderr)
                rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
