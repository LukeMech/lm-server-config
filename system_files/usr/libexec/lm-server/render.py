#!/usr/bin/python3
"""lm-server config renderer.

Turns the one config file of the private secrets repo (lm-server.toml) into
the files the quadlets and provision scripts read:

    <out>/host/host.env, <out>/host/authorized_keys
    <out>/<service>/...            one directory per service in the config

Usage:
    render.py services              name<TAB>units<TAB>routes<TAB>description
    render.py render <toml> <out>   exit 0 ok, 1 some service invalid (see
                                    <out>/.errors/<service>), 2 unreadable config
    render.py check <toml>          same checks and exit codes, writes nothing

The GitHub credentials from `lm-server setup` come in as LMS_GITHUB_TOKEN /
LMS_GITHUB_USER (default token for the web apps' private repos).
"""

import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tomllib

# Every service keeps all of its data in VOLUMES/<service>/. By default that's
# on the system disk; `storage = "/var/mnt/<disk>"` in its section bind-mounts
# <disk>/<service> there instead (lm-server moves the data on a change).
VOLUMES = "/var/lib/lm-server/volumes"
CACHE = "/var/lib/lm-server/cache"
GUAC_IMAGE = "docker.io/guacamole/guacamole:1.6.0"
CHECK_ONLY = False  # `check`: validate without side effects (no podman)

# Every service this image can run. "units" are what `lm-server start/stop`
# acts on (a pod unit starts/stops all of its containers).
SERVICES = {
    "cloudflared": {
        "desc": "Cloudflare Tunnel",
        "units": ["cloudflared"],
        "routes": {"proxmox.lukemech.org": "https://localhost:9090"},
    },
    "disks": {
        "desc": "FileBrowser Quantum + Syncthing",
        "units": ["disks-pod"],
        "routes": {
            "disk.lukemech.org": "http://localhost:8001",
            "syncdisks.lukemech.org": "http://localhost:8384",
        },
    },
    "toolbox": {
        "desc": "toolbox.lukemech.org",
        "units": ["toolbox"],
        "routes": {"toolbox.lukemech.org": "http://localhost:6600"},
        "app": {"APP_REPO": "LukeMech-PlayStore/toolbox-website", "APP_MODULE": "server:app", "APP_PORT": "6600"},
    },
    "website": {
        "desc": "lukemech.org",
        "units": ["website"],
        "routes": {"lukemech.org": "http://localhost:3000"},
        "app": {"APP_REPO": "LukeMech/website", "APP_MODULE": "main:app", "APP_PORT": "3000"},
    },
    "exp": {
        "desc": "exp.lukemech.org (CV)",
        "units": ["exp"],
        "routes": {"exp.lukemech.org": "http://localhost:7999"},
        "app": {
            "APP_REPO": "LukeMech/CV",
            "APP_MODULE": "server:app",
            "APP_PORT": "7999",
            "APP_PIP_PACKAGES": "rendercv[full]",
            "APP_BUILD_CMD": "rendercv render Łukasz_Błaszczyk_CV_EN.yaml",
        },
    },
    "convert": {
        "desc": "ConvertX",
        "units": ["convert"],
        "routes": {"convert.lukemech.org": "http://localhost:3001"},
    },
    "immich": {
        "desc": "Immich",
        "units": ["immich-pod"],
        "routes": {"immich.lukemech.org": "http://localhost:2283"},
    },
    "remote": {
        "desc": "Apache Guacamole",
        "units": ["remote-pod"],
        "routes": {"remote.lukemech.org": "http://localhost:8443"},
    },
    "sugar": {
        "desc": "Nightscout",
        "units": ["sugar-pod"],
        "routes": {"sugar.lukemech.org": "http://localhost:1337"},
    },
}


class ConfigError(Exception):
    pass


def need(sec, key, where):
    value = sec.get(key)
    if value in (None, "", [], {}):
        raise ConfigError(f"{where}.{key} is not set")
    return value


def no_placeholders(obj, where):
    """Template values never go live."""
    if isinstance(obj, str) and obj.startswith("CHANGE_ME"):
        raise ConfigError(f"{where} is still CHANGE_ME")
    if isinstance(obj, dict):
        for k, v in obj.items():
            no_placeholders(v, f"{where}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            no_placeholders(v, f"{where}[{i}]")


def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def env_file(values):
    """podman --env-file format: KEY=value, taken literally, no quoting."""
    lines = []
    for key, value in values.items():
        value = scalar(value)
        if "\n" in value:
            raise ConfigError(f"{key}: value contains a newline")
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def extra_env(sec, where):
    env = sec.get("env", {})
    if not isinstance(env, dict):
        raise ConfigError(f"{where}.env must be a table")
    return env


def users(sec, where, fields):
    """[[<service>.users]] tables -> list of dicts with the required fields."""
    result = []
    for i, user in enumerate(sec.get("users", [])):
        for field in fields:
            need(user, field, f"{where}.users[{i}]")
        result.append(user)
    return result


class Out:
    def __init__(self, root):
        self.root = root

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.chmod(path, 0o600)

    def json(self, rel, obj):
        self.write(rel, json.dumps(obj, ensure_ascii=False, indent=2) + "\n")


def volumes(out, *subdirs):
    """Subdirectories of VOLUMES/<service> the containers mount."""
    out.write("volumes", "".join(f"{d}\n" for d in subdirs))


def storage(sec, out, where):
    """Optional `storage = "/var/mnt/<disk>"`: the disk holding this service's data."""
    path = sec.get("storage", "")
    if not path:
        return
    if path.startswith("/mnt/"):
        path = "/var" + path  # /mnt is a symlink to /var/mnt on bootc
    path = posixpath.normpath(path)
    if not re.fullmatch(r"/var/(mnt|srv)/[^\s]+", path):
        raise ConfigError(f"{where}.storage must be a mounted disk under /var/mnt (got '{path}')")
    out.write("storage", f"{path}/{where}\n")


# ---------------------------------------------------------------- services


def r_cloudflared(sec, out, ctx):
    out.write("cloudflared.env", env_file({"TUNNEL_TOKEN": need(sec, "tunnel_token", "cloudflared")}))


def r_disks(sec, out, ctx):
    w = "disks"
    folders = sec.get("syncthing_folders", {"keepass": "/mnt/disk_0/Keepass", "sync": "/mnt/disk_0/Sync"})
    for fid, path in folders.items():
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", fid) or not re.fullmatch(r"/mnt/(disk_0|docs)(/[^\s]*)?", path):
            raise ConfigError(f"{w}.syncthing_folders: '{fid}' -> '{path}' (path must be under /mnt/disk_0 or /mnt/docs, no spaces)")
    admin = need(sec, "filebrowser_admin", w)
    q = json.dumps  # a JSON string is a valid YAML scalar
    out.write(
        "filebrowser/config.yaml",
        f"""server:
  port: 80
  baseURL: "/"
  database: /home/filebrowser/data/database.db
  sources:
    - path: /mnt/disk_0
      name: disk_0
      config:
        defaultEnabled: true
    - path: /mnt/docs
      name: docs
      config:
        defaultEnabled: true
auth:
  adminUsername: {q(admin)}
  adminPassword: {q(need(sec, "filebrowser_password", w))}
  methods:
    password:
      enabled: true
frontend:
  name: {q(sec.get("filebrowser_name", "disk.lukemech.org"))}
""",
    )
    out.json("filebrowser-users.json", [u for u in users(sec, w, ["login", "password"]) if u["login"] != admin])
    out.json(
        "syncthing.json",
        {
            "user": need(sec, "syncthing_user", w),
            "password": need(sec, "syncthing_password", w),
            "folders": folders,
        },
    )
    volumes(out, "filebrowser", "syncthing", "disk_0", "docs", *(p[len("/mnt/"):] for p in folders.values()))


def r_webapp(name):
    def render(sec, out, ctx):
        env = dict(SERVICES[name]["app"])
        env["APP_BRANCH"] = sec.get("branch", "main")
        env["APP_GITHUB_TOKEN"] = sec.get("github_token", ctx["token"])
        env["APP_GITHUB_USER"] = sec.get("github_user", ctx["user"])
        env.update(extra_env(sec, name))
        out.write("app.env", env_file(env))
        volumes(out, ".")

    return render


def r_convert(sec, out, ctx):
    env = {"ACCOUNT_REGISTRATION": "false", "HTTP_ALLOWED": "false"}
    env.update(extra_env(sec, "convert"))
    env["JWT_SECRET"] = need(sec, "jwt_secret", "convert")
    out.write("convertx.env", env_file(env))
    out.json("users.json", users(sec, "convert", ["email", "password"]))
    volumes(out, ".")


def r_immich(sec, out, ctx):
    w = "immich"
    db_password = need(sec, "db_password", w)
    if not re.fullmatch(r"[A-Za-z0-9]+", db_password):
        raise ConfigError(f"{w}.db_password: letters and digits only (Immich requirement)")
    env = dict(extra_env(sec, w))
    env.update(
        {
            "DB_HOSTNAME": "127.0.0.1",
            "DB_USERNAME": "postgres",
            "DB_PASSWORD": db_password,
            "DB_DATABASE_NAME": "immich",
            "REDIS_HOSTNAME": "127.0.0.1",
            "IMMICH_MACHINE_LEARNING_URL": "http://127.0.0.1:3003",
        }
    )
    out.write("server.env", env_file(env))
    out.write("database.env", env_file({"POSTGRES_USER": "postgres", "POSTGRES_DB": "immich", "POSTGRES_PASSWORD": db_password}))
    admin = need(sec, "admin", w)
    for field in ("email", "password"):
        need(admin, field, f"{w}.admin")
    out.json("admin.json", {"email": admin["email"], "password": admin["password"], "name": admin.get("name", "Admin")})
    out.json("users.json", users(sec, w, ["email", "password"]))
    volumes(out, "library", "postgres", "model-cache")


def r_remote(sec, out, ctx):
    w = "remote"
    db_password = need(sec, "db_password", w)
    out.write("database.env", env_file({"POSTGRES_DB": "guacamole_db", "POSTGRES_USER": "guacamole", "POSTGRES_PASSWORD": db_password}))
    env = dict(extra_env(sec, w))
    env.update(
        {
            "GUACD_HOSTNAME": "127.0.0.1",
            "POSTGRESQL_HOSTNAME": "127.0.0.1",
            "POSTGRESQL_DATABASE": "guacamole_db",
            "POSTGRESQL_USERNAME": "guacamole",
            "POSTGRESQL_PASSWORD": db_password,
            "WEBAPP_CONTEXT": "ROOT",
        }
    )
    out.write("guacamole.env", env_file(env))
    out.json("users.json", users(sec, w, ["login", "password"]))
    if CHECK_ONLY:
        return
    # DB schema, generated once per Guacamole version by the image's own script.
    cache = os.path.join(CACHE, f"guacamole-initdb-{GUAC_IMAGE.rsplit(':', 1)[1]}.sql")
    if not os.path.exists(cache) or os.path.getsize(cache) == 0:
        os.makedirs(CACHE, exist_ok=True)
        sql = subprocess.run(
            ["podman", "run", "--rm", GUAC_IMAGE, "/opt/guacamole/bin/initdb.sh", "--postgresql"],
            check=True, capture_output=True, text=True,
        ).stdout
        with open(cache, "w", encoding="utf-8") as f:
            f.write(sql)
    with open(cache, encoding="utf-8") as f:
        out.write("initdb/001-guacamole-schema.sql", f.read())
    volumes(out, "postgres")


def r_sugar(sec, out, ctx):
    api_secret = need(sec, "api_secret", "sugar")
    if len(api_secret) < 12:
        raise ConfigError("sugar.api_secret must be at least 12 characters")
    env = {
        "MONGO_CONNECTION": "mongodb://127.0.0.1:27017/nightscout",
        "PORT": "1337",
        "NODE_ENV": "production",
        "INSECURE_USE_HTTP": "true",
    }
    env.update(extra_env(sec, "sugar"))
    env["API_SECRET"] = api_secret
    out.write("nightscout.env", env_file(env))
    volumes(out, "mongo")


RENDER = {
    "cloudflared": r_cloudflared,
    "disks": r_disks,
    "toolbox": r_webapp("toolbox"),
    "website": r_webapp("website"),
    "exp": r_webapp("exp"),
    "convert": r_convert,
    "immich": r_immich,
    "remote": r_remote,
    "sugar": r_sugar,
}

# ---------------------------------------------------------------- host


def r_host(cfg, out):
    host = cfg.get("host", {})
    updates = cfg.get("updates", {})
    env = {
        "HOSTNAME": host.get("hostname", ""),
        "TIMEZONE": host.get("timezone", ""),
        "ADMIN_USER": host.get("admin_user", ""),
        "ADMIN_PASSWORD_HASH": host.get("admin_password_hash", ""),
        "COCKPIT_ORIGINS": " ".join(host.get("cockpit_origins", [])),
        "SYSTEM_UPDATES": updates.get("system", "manual"),
        "CONTAINER_UPDATES": updates.get("containers", "daily"),
        "ADHOC_EPHEMERAL": scalar(updates.get("adhoc_ephemeral", True)),
    }
    out.write("host.env", env_file(env))
    out.write("authorized_keys", "".join(f"{k.strip()}\n" for k in host.get("ssh_keys", [])))


def cmd_render(toml_path, out_root):
    try:
        with open(toml_path, "rb") as f:
            cfg = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"cannot read {toml_path}: {e}", file=sys.stderr)
        return 2
    for key in cfg:
        if key not in SERVICES and key not in ("host", "updates"):
            print(f"warning: unknown section [{key}] ignored", file=sys.stderr)

    ctx = {"token": os.environ.get("LMS_GITHUB_TOKEN", ""), "user": os.environ.get("LMS_GITHUB_USER", "")}
    r_host(cfg, Out(os.path.join(out_root, "host")))
    status = 0
    for name, render in RENDER.items():
        if name not in cfg:
            continue
        target = os.path.join(out_root, name)
        try:
            sec = cfg[name]
            no_placeholders(sec, name)
            render(sec, Out(target), ctx)
            storage(sec, Out(target), name)
            os.makedirs(target, mode=0o700, exist_ok=True)
        except (ConfigError, subprocess.CalledProcessError, OSError) as e:
            shutil.rmtree(target, ignore_errors=True)
            Out(os.path.join(out_root, ".errors")).write(name, f"{e}\n")
            print(f"{name}: {e}", file=sys.stderr)
            status = 1
    return status


def cmd_services():
    for name, spec in SERVICES.items():
        routes = " ".join(f"{h}={u}" for h, u in spec["routes"].items())
        print(f"{name}\t{' '.join(spec['units'])}\t{routes}\t{spec['desc']}")
    return 0


def cmd_check(toml_path):
    global CHECK_ONLY
    import tempfile
    CHECK_ONLY = True
    with tempfile.TemporaryDirectory() as tmp:
        rc = cmd_render(toml_path, tmp)
    if rc == 0:
        print("config OK", file=sys.stderr)
    return rc


def main(argv):
    if argv[1:2] == ["services"]:
        return cmd_services()
    if argv[1:2] == ["check"] and len(argv) == 3:
        return cmd_check(argv[2])
    if argv[1:2] == ["render"] and len(argv) == 4:
        return cmd_render(argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
