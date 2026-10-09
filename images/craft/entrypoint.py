#!/usr/bin/python3
"""Serve one Storytold Crafting App, or the hub in front of them, with nginx.

App (CRAFT_REPO set):
    CRAFT_REPO             owner/name on GitHub, e.g. storytold/pdfcraft
    CRAFT_PORT             listen port (127.0.0.1 -- the hub proxies to it)
    <NAME>_VERSION         pin a release, e.g. PDFCRAFT_VERSION=0.4.0
                           (default: the latest one)
    CRAFT_UPDATE_INTERVAL  seconds between release checks, default 21600

    The release's <name>-web-<version>.zip is checked against its
    SHA256SUMS.txt and unpacked to /data/<tag>/; /data/current points at the
    one served. A new release is unpacked next to it and the link swapped,
    without a restart. The previous release is kept, older ones removed.
    Without GitHub at start, the release already in /data is served.

Hub (CRAFT_ROUTES set):
    CRAFT_ROUTES           "<path>=<port> ...", e.g. "pdf=8081 photo=8082":
                           /<path>/ is proxied to 127.0.0.1:<port>
    CRAFT_PORT             listen port (all interfaces -- the pod publishes it)

    / is the page that lists the apps (/usr/share/lm-server-craft/hub).
"""

import gzip
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

DATA = "/data"
CONF = "/tmp/nginx.conf"
HUB = "/usr/share/lm-server-craft/hub"
# Files nginx sends precompressed (gzip_static); the .wasm is most of an app.
COMPRESS = re.compile(r"\.(wasm|js|mjs|html|css|json|svg|webmanifest)$")

NGINX_HEAD = """\
worker_processes 1;
pid /tmp/nginx.pid;
error_log stderr warn;
daemon off;
events {{ worker_connections 512; }}
http {{
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    server_tokens off;
    sendfile on;
    absolute_redirect off;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    gzip on;
    gzip_static on;
    gzip_vary on;
    gzip_types application/wasm application/javascript text/javascript text/css application/json image/svg+xml application/manifest+json;
    server {{
        listen {listen};
"""

# Asset names carry a content hash (pdfcraft-web-a5e9b1d863d1ae9b_bg.wasm):
# cached for good. Everything else (index.html, sw.js, craft.json) is
# revalidated on every load, so a new release shows up at once.
NGINX_APP = """\
        root {root};
        index index.html;
        location / {{
            add_header X-Content-Type-Options nosniff always;
            add_header Cache-Control "no-cache" always;
            try_files $uri $uri/ =404;
        }}
        location ~ "-[0-9a-f]{{16}}(_bg)?\\.(wasm|js)$" {{
            add_header X-Content-Type-Options nosniff always;
            add_header Cache-Control "public, max-age=31536000, immutable" always;
        }}
    }}
}}
"""

NGINX_HUB_ROUTE = """\
        location = /{path} {{ return 301 /{path}/; }}
        location /{path}/ {{
            proxy_pass http://127.0.0.1:{port}/;
            proxy_http_version 1.1;
            # Streamed through: a wasm of 60 MB isn't held in /tmp (RAM).
            proxy_buffering off;
        }}
"""

NGINX_HUB_TAIL = """\
        root {root};
        location = / {{
            add_header Cache-Control "no-cache" always;
            try_files /index.html =404;
        }}
        location / {{
            add_header Cache-Control "no-cache" always;
            try_files $uri =404;
        }}
    }}
}}
"""


def log(msg):
    print(f"craft: {msg}", file=sys.stderr, flush=True)


def get(url, accept=None):
    req = urllib.request.Request(url, headers={"User-Agent": "lm-server-craft"})
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "lm-server-craft"})
    sha = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=60) as resp, open(dest, "wb") as fh:
        while chunk := resp.read(1 << 20):
            sha.update(chunk)
            fh.write(chunk)
    return sha.hexdigest()


def release(repo, version):
    """The release to serve: (tag, web zip asset, SHA256SUMS.txt asset)."""
    api = f"https://api.github.com/repos/{repo}/releases"
    if version:
        tag = version if version.startswith("v") else f"v{version}"
        rel = json.loads(get(f"{api}/tags/{tag}", "application/vnd.github+json"))
    else:
        rel = json.loads(get(f"{api}/latest", "application/vnd.github+json"))
    assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
    web = [n for n in assets if re.fullmatch(r"[\w.-]+-web-[\w.-]+\.zip", n)]
    if len(web) != 1 or "SHA256SUMS.txt" not in assets:
        raise RuntimeError(f"{repo} {rel['tag_name']}: no web build (or no SHA256SUMS.txt) in the release")
    return rel["tag_name"], (web[0], assets[web[0]]), assets["SHA256SUMS.txt"]


def install(repo, tag, web, sums_url):
    """Download, verify and unpack a release to DATA/<tag>."""
    name, url = web
    sums = get(sums_url).decode()
    expected = next(
        (line.split()[0] for line in sums.splitlines() if line.split()[1:] and line.split()[-1].lstrip("*") == name),
        None,
    )
    if not expected:
        raise RuntimeError(f"{name} is not in SHA256SUMS.txt")
    with tempfile.TemporaryDirectory(dir=DATA, prefix=".new-") as tmp:
        zpath = os.path.join(tmp, name)
        log(f"{repo}: downloading {name}")
        if download(url, zpath) != expected:
            raise RuntimeError(f"{name}: checksum mismatch")
        out = os.path.join(tmp, "site")
        with zipfile.ZipFile(zpath) as z:
            z.extractall(out)  # zipfile drops absolute paths and `..`
        os.remove(zpath)
        # The zip holds one folder, <name>-web-<version>/.
        entries = os.listdir(out)
        root = os.path.join(out, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(out, entries[0])) else out
        if not os.path.isfile(os.path.join(root, "index.html")):
            raise RuntimeError(f"{name}: no index.html")
        for dirpath, _, files in os.walk(root):
            for f in files:
                if COMPRESS.search(f):
                    src = os.path.join(dirpath, f)
                    with open(src, "rb") as fi, gzip.open(src + ".gz", "wb", compresslevel=9) as fo:
                        shutil.copyfileobj(fi, fo)
        with open(os.path.join(root, "craft.json"), "w") as fh:
            json.dump({"repo": repo, "version": tag.lstrip("v"), "tag": tag}, fh)
        os.rename(root, os.path.join(DATA, tag))
    log(f"{repo}: {tag} unpacked")


def switch(tag):
    """Point DATA/current at <tag> (atomically) and drop all but the previous."""
    link = os.path.join(DATA, "current")
    previous = os.readlink(link) if os.path.islink(link) else None
    if previous == tag:
        return
    tmp = os.path.join(DATA, ".current")
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(tag, tmp)
    os.replace(tmp, link)
    for entry in os.listdir(DATA):
        path = os.path.join(DATA, entry)
        if entry not in ("current", tag, previous) and os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
    log(f"serving {tag}" + (f" (was {previous})" if previous else ""))


def update(repo, version):
    tag, web, sums = release(repo, version)
    if not os.path.isfile(os.path.join(DATA, tag, "craft.json")):
        shutil.rmtree(os.path.join(DATA, tag), ignore_errors=True)
        install(repo, tag, web, sums)
    switch(tag)


def nginx(conf):
    with open(CONF, "w") as fh:
        fh.write(conf)
    subprocess.run(["nginx", "-t", "-q", "-e", "stderr", "-c", CONF], check=True)
    return subprocess.Popen(["nginx", "-e", "stderr", "-c", CONF])


def run(proc, every=None, task=None):
    """Wait on nginx; run task every `every` seconds meanwhile."""
    def stop(*_):
        proc.terminate()
        proc.wait()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        try:
            rc = proc.wait(timeout=every)
            sys.exit(rc or 1)
        except subprocess.TimeoutExpired:
            pass
        try:
            task()
        except Exception as e:  # keep serving what's there
            log(f"update check failed: {e}")


def app():
    repo = os.environ["CRAFT_REPO"]
    port = int(os.environ["CRAFT_PORT"])
    version = os.environ.get(f"{repo.rsplit('/', 1)[-1].upper()}_VERSION", "").strip()
    every = int(os.environ.get("CRAFT_UPDATE_INTERVAL", "21600"))
    try:
        update(repo, version)
    except Exception as e:
        if not os.path.isdir(os.path.join(DATA, "current")):
            log(f"{repo}: {e} -- nothing to serve yet")
            sys.exit(1)  # systemd restarts it after RestartSec
        log(f"{repo}: {e} -- serving the release already here")
    root = os.path.join(DATA, "current")
    proc = nginx(NGINX_HEAD.format(listen=f"127.0.0.1:{port}") + NGINX_APP.format(root=root))
    log(f"{repo}: listening on 127.0.0.1:{port}")
    run(proc, every, lambda: update(repo, version))


def hub():
    port = int(os.environ["CRAFT_PORT"])
    conf = NGINX_HEAD.format(listen=port)
    for route in os.environ["CRAFT_ROUTES"].split():
        path, _, target = route.partition("=")
        if not re.fullmatch(r"[a-z0-9-]+", path) or not target.isdigit():
            raise SystemExit(f"craft: bad CRAFT_ROUTES entry: {route}")
        conf += NGINX_HUB_ROUTE.format(path=path, port=target)
    conf += NGINX_HUB_TAIL.format(root=HUB)
    proc = nginx(conf)
    log(f"hub: listening on :{port}")
    run(proc)


if __name__ == "__main__":
    if os.environ.get("CRAFT_ROUTES"):
        hub()
    elif os.environ.get("CRAFT_REPO"):
        app()
    else:
        raise SystemExit("craft: set CRAFT_REPO (an app) or CRAFT_ROUTES (the hub)")
