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

The GitHub credentials from `lm-server config setup` come in as LMS_GITHUB_TOKEN /
LMS_GITHUB_USER ({{github_token}} / {{github_user}} in `env` defaults).

A service is a directory of quadlets in /usr/share/containers/systemd/<name>/.
Everything lm-server needs to know about it comes from those files:

    unit        <name>-pod if there's a <name>.pod, else its .container(s)
    volumes     subdirectories, from `Volume=/var/lib/lm-server/volumes/<name>/<sub>:...`
    # lm-server: description <text>
    # lm-server: route <hostname>[/<path>] <url>  (Cloudflare route; repeatable)
    # lm-server: env <KEY>=<default value>     (repeatable)
    # lm-server: require <KEY>                 (must be set in lm-server.toml)

With no custom renderer below, [<name>] in lm-server.toml renders to
env/<name>/<name>.env (point the quadlet's EnvironmentFile= there):
`env` defaults < top-level keys (api_secret -> API_SECRET) < `env = {...}`;
`users = [...]` goes to env/<name>/users.json for provision/<name>.sh.
`versions = { <container> = "<tag>" }` (its name without "<name>-", e.g. db
for remote-db) runs that tag of the quadlet's image instead of its own;
a container left out keeps the quadlet's tag.

A renderer may also write quadlet/<unit>.conf (e.g. immich-server.container.conf):
lm-server installs it as a drop-in of that quadlet,
/etc/containers/systemd/<unit>.d/lm-server-<service>.conf.
"""

import glob
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tomllib

QUADLETS = os.environ.get("LMS_QUADLET_DIR", "/usr/share/containers/systemd")
# Every service keeps all of its data in VOLUMES/<service>/. By default that's
# on the system disk; `disk = "/var/mnt/<path>"` in its section bind-mounts
# exactly that folder there instead, `storage = "80G"` makes it a filesystem
# of that size (lm-server moves the data on a change).
VOLUMES = "/var/lib/lm-server/volumes"
CACHE = "/var/lib/lm-server/cache"
CHECK_ONLY = False  # `check`: validate without side effects (no podman)

# Keys of a service section lm-server handles itself (never passed as env).
RESERVED = {"storage", "disk", "cpus", "memory", "env", "users", "versions"}

# Services that are part of the system rather than quadlets.
BUILTIN = {
    "cloudflared": {
        "desc": "Cloudflare Tunnel",
        "units": ["lm-server-cloudflared"],
        "routes": {"proxmox.lukemech.org": "https://localhost:9090"},
        "env": {},
        "require": ["TUNNEL_TOKEN"],
        "volumes": [],
        "images": {},
    },
}

DIRECTIVE = re.compile(r"^#\s*lm-server:\s*([a-z-]+)\s*(.*?)\s*$")


class ConfigError(Exception):
    pass


def catalog():
    """All services: BUILTIN + one per quadlet directory."""
    services = {k: dict(v) for k, v in BUILTIN.items()}
    if not os.path.isdir(QUADLETS):
        return services
    for name in sorted(os.listdir(QUADLETS)):
        d = os.path.join(QUADLETS, name)
        if not os.path.isdir(d) or name.endswith(".d"):
            continue
        files = sorted(os.listdir(d))
        pods = [f[: -len(".pod")] for f in files if f.endswith(".pod")]
        containers = [f[: -len(".container")] for f in files if f.endswith(".container")]
        units = [f"{pods[0]}-pod"] if pods else containers
        if not units:
            continue
        # images: {key in `versions`: (quadlet file, its Image=)}
        spec = {"desc": name, "units": units, "routes": {}, "env": {}, "require": [], "volumes": [], "images": {}}
        vol = re.compile(rf"^Volume={re.escape(VOLUMES)}/{re.escape(name)}(/[^:]*)?:")
        for f in files:
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if f.endswith(".container") and line.startswith("Image="):
                        key = f[: -len(".container")].removeprefix(f"{name}-") or name
                        spec["images"][key] = (f, line[len("Image="):])
                        continue
                    m = vol.match(line)
                    if m:
                        sub = (m.group(1) or "").strip("/") or "."
                        if sub not in spec["volumes"]:
                            spec["volumes"].append(sub)
                        continue
                    m = DIRECTIVE.match(line)
                    if not m:
                        continue
                    key, arg = m.groups()
                    if key == "description":
                        spec["desc"] = arg
                    elif key == "route" and len(arg.split()) == 2:
                        host, url = arg.split()
                        spec["routes"][host] = url
                    elif key == "env" and "=" in arg:
                        k, v = arg.split("=", 1)
                        spec["env"][k.strip()] = v.strip()
                    elif key == "require" and arg:
                        spec["require"].append(arg)
                    else:
                        raise SystemExit(f"{d}/{f}: bad directive: {line}")
        services[name] = spec
    return services


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
    """users = [{...}, ...] -> list of dicts with the required fields."""
    result = sec.get("users", [])
    if not isinstance(result, list):
        raise ConfigError(f"{where}.users must be a list of tables")
    for i, user in enumerate(result):
        if not isinstance(user, dict):
            raise ConfigError(f"{where}.users[{i}] must be a table")
        for field in fields:
            need(user, field, f"{where}.users[{i}]")
    return result


class Out:
    def __init__(self, root):
        self.root = root

    def write(self, rel, text, mode="w", public=False):
        """public: readable by any user -- for files a container reads as a
        non-root user (never secrets)."""
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, mode, encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.chmod(path, 0o644 if public else 0o600)
        if public:
            os.chmod(os.path.dirname(path), 0o755)

    def json(self, rel, obj):
        self.write(rel, json.dumps(obj, ensure_ascii=False, indent=2) + "\n")


def volumes(out, *subdirs):
    """Extra subdirectories of VOLUMES/<service> to create (appends)."""
    out.write("volumes", "".join(f"{d}\n" for d in subdirs), mode="a")


def limits(sec, out, where):
    """Optional `cpus = 2` / `memory = "4G"`: systemd limits of lm-server-<svc>.slice
    (all of the service's containers together). Always written, so removing a
    key lifts the limit again."""
    props = ["MemoryMax=infinity", "CPUQuota="]
    mem = sec.get("memory")
    if mem is not None:
        mem = str(mem).upper()
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)?[KMGT]?", mem):
            raise ConfigError(f"{where}.memory must look like \"512M\" or \"4G\" (got '{sec['memory']}')")
        props[0] = f"MemoryMax={mem}"
    cpus = sec.get("cpus")
    if cpus is not None:
        if isinstance(cpus, bool) or not isinstance(cpus, (int, float)) or cpus <= 0:
            raise ConfigError(f"{where}.cpus must be a number of cores, e.g. 2 or 0.5")
        props[1] = f"CPUQuota={round(cpus * 100)}%"
    out.write("limits", "".join(f"{p}\n" for p in props))


def is_path(v):
    return isinstance(v, str) and v.startswith("/")


def location(sec, out, where, taken):
    """Optional `disk = "/var/mnt/<path>"`: the folder holding this service's
    data (older configs: `storage = "/var/mnt/..."`, still understood).

    Used as is (e.g. an LV mounted at /var/mnt/hdd-mirror/immich, or a folder
    on a disk). `taken` maps the folders already claimed to their service: two
    services can't share one, nor sit inside each other's."""
    path = sec.get("disk", "")
    if not path and is_path(sec.get("storage")):
        path = sec["storage"]
    if not path:
        return
    if not is_path(path):
        raise ConfigError(f"{where}.disk is where the data lives, a folder under /var/mnt"
                          f" (got '{path}'; a size goes in storage = \"...\")")
    if path.startswith("/mnt/"):
        path = "/var" + path  # /mnt is a symlink to /var/mnt on bootc
    path = posixpath.normpath(path)
    if not re.fullmatch(r"/var/(mnt|srv)/[^\s]+", path):
        raise ConfigError(f"{where}.disk must be a folder under /var/mnt (got '{path}')")
    for other, p in taken.items():
        if path == p or path.startswith(p + "/") or p.startswith(path + "/"):
            raise ConfigError(f"{where}.disk '{path}' overlaps [{other}] disk '{p}' -- give each service its own folder")
    taken[where] = path
    out.write("storage", f"{path}\n")  # rendered name kept from the old key


SIZE_UNITS = {"M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def size(sec, out, where):
    """Optional `storage = "80G"`: the service's data in a filesystem of exactly
    that size (an image file in its `disk` folder, or on the system disk), so
    when it's full only this service notices. Can be raised later, not lowered."""
    value = sec.get("storage")
    if value is None or is_path(value):
        return
    m = re.fullmatch(r"([0-9]+)([MGT])", str(value).upper())
    if not m or int(m[1]) * SIZE_UNITS[m[2]] < 256 << 20:
        raise ConfigError(f"{where}.storage must be a size of at least 256M, like \"512M\" or \"80G\" (got '{value}')")
    out.write("disk", f"{m[1]}{m[2]}\n")  # rendered as "disk" (the size)


TAG = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")


def versions(sec, where):
    result = sec.get("versions", {})
    if not isinstance(result, dict):
        raise ConfigError(f'{where}.versions must be a table, e.g. {{ db = "16" }}')
    return result


def image(spec, sec, key, where):
    """The image the `key` container runs: its quadlet's, with the tag from
    `versions` if that names one."""
    base = spec["images"][key][1]
    tag = versions(sec, where).get(key)
    if tag is None:
        return base
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        raise ConfigError(f'{where}.versions.{key} must be an image tag, e.g. "16" or "latest" (got \'{tag}\')')
    repo = base.split("@", 1)[0]
    if ":" in repo.rsplit("/", 1)[-1]:
        repo = repo.rsplit(":", 1)[0]
    return f"{repo}:{tag}"


def images(spec, sec, out, where):
    """versions = { ... } -> an Image= drop-in for each container it names
    (unless the service's renderer has set that container's image itself)."""
    for key in versions(sec, where):
        if key not in spec["images"]:
            known = ", ".join(sorted(spec["images"])) or "none"
            raise ConfigError(f"{where}.versions.{key}: no such container (these are: {known})")
        rel = f"quadlet/{spec['images'][key][0]}.conf"
        path = os.path.join(out.root, rel)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                if re.search(r"^Image=", f.read(), re.M):
                    continue
        out.write(rel, f"[Container]\nImage={image(spec, sec, key, where)}\n", mode="a")


# ---------------------------------------------------------------- renderers


def r_generic(name, spec, sec, out, ctx):
    """env defaults < top-level keys < env table -> <name>.env; users -> users.json."""
    subst = {"github_token": sec.get("github_token", ctx["token"]), "github_user": sec.get("github_user", ctx["user"])}
    env = {k: re.sub(r"\{\{(\w+)\}\}", lambda m: scalar(subst.get(m.group(1), "")), v) for k, v in spec["env"].items()}
    for key, value in sec.items():
        if key in RESERVED:
            continue
        if isinstance(value, (dict, list)):
            raise ConfigError(f"{name}.{key}: only plain values here (use env = {{ ... }} for more)")
        env[key.upper()] = scalar(value)
    env.update(extra_env(sec, name))
    for key in spec["require"]:
        if not scalar(env.get(key, "")):
            raise ConfigError(f"{name}.{key.lower()} is not set")
    out.write(f"{name}.env", env_file(env))
    if "users" in sec:
        out.json("users.json", users(sec, name, []))


# Services that need more than an env file (generated configs, several env
# files, DB schema). Everything else uses r_generic.


def r_disks(name, spec, sec, out, ctx):
    # Shares: folders VOLUMES/disks/shares/<name>, at /shares/<name> in both
    # containers. FileBrowser shows each one; Syncthing folders live in them.
    shares = sec.get("shares", ["files"])
    if not isinstance(shares, list) or not shares or len(set(shares)) != len(shares) or not all(
        isinstance(s, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", s) and s not in (".", "..") for s in shares
    ):
        raise ConfigError(f'{name}.shares must be a list of distinct folder names, e.g. ["files", "docs"]')
    folders = {}
    for fid, rel in sec.get("syncthing_folders", {}).items():
        parts = rel.split("/") if isinstance(rel, str) else []
        if (
            not re.fullmatch(r"[A-Za-z0-9_.-]+", fid)
            or not parts
            or parts[0] not in shares
            or any(p in ("", ".", "..") or re.search(r"\s", p) for p in parts)
        ):
            raise ConfigError(
                f"{name}.syncthing_folders: '{fid}' -> '{rel}' (must be <share>/<folder> with <share> one of "
                f"{', '.join(shares)}; no spaces)"
            )
        folders[fid] = f"/shares/{rel}"
    admin = need(sec, "filebrowser_admin", name)
    q = json.dumps  # a JSON string is a valid YAML scalar
    sources = "".join(
        f"""    - path: {q("/shares/" + s)}
      name: {q(s)}
      config:
        defaultEnabled: true
"""
        for s in shares
    )
    out.write(
        "filebrowser/config.yaml",
        f"""server:
  port: 80
  baseURL: "/"
  database: /home/filebrowser/data/database.db
  sources:
{sources}auth:
  adminUsername: {q(admin)}
  adminPassword: {q(need(sec, "filebrowser_password", name))}
  methods:
    password:
      enabled: true
frontend:
  name: {q(sec.get("filebrowser_name", "disk.lukemech.org"))}
""",
    )
    out.json("filebrowser-users.json", [u for u in users(sec, name, ["login", "password"]) if u["login"] != admin])
    out.json(
        "syncthing.json",
        {"user": need(sec, "syncthing_user", name), "password": need(sec, "syncthing_password", name), "folders": folders},
    )
    volumes(out, *(f"shares/{s}" for s in shares), *(p[1:] for p in folders.values()))


def r_immich(name, spec, sec, out, ctx):
    db_password = need(sec, "db_password", name)
    if not re.fullmatch(r"[A-Za-z0-9]+", db_password):
        raise ConfigError(f"{name}.db_password: letters and digits only (Immich requirement)")
    env = dict(extra_env(sec, name))
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
    admin = need(sec, "admin", name)
    for field in ("email", "password"):
        need(admin, field, f"{name}.admin")
    out.json("admin.json", {"email": admin["email"], "password": admin["password"], "name": admin.get("name", "Admin")})
    out.json("users.json", users(sec, name, ["email", "password"]))
    gpu = sec.get("gpu")
    if gpu is not None and gpu != "nvidia":
        raise ConfigError(f"{name}.gpu: only \"nvidia\" (or leave it out for the CPU; got '{gpu}')")
    # Only where the card can be handed over: on a machine without one, or an
    # image without its driver, Immich runs on the CPU as if gpu weren't set
    # (a CDI device that doesn't exist would keep its containers from starting).
    if gpu and not CHECK_ONLY and not nvidia_card():
        print(f"warning: {name}.gpu = \"nvidia\": no NVIDIA card or driver here -- running on the CPU", file=sys.stderr)
        gpu = None
    if gpu:
        # The card through CDI (/run/cdi/nvidia.yaml, from nvidia-cdi-refresh
        # at boot): machine learning on CUDA (its -cuda image), the server for
        # NVENC video transcoding (Immich > Administration > Video Transcoding
        # > Hardware Acceleration: NVENC).
        cdi = (
            "[Unit]\n"
            "Wants=nvidia-cdi-refresh.service\n"
            "After=nvidia-cdi-refresh.service\n\n"
            "[Container]\n"
            "AddDevice=nvidia.com/gpu=all\n"
        )
        # Its -cuda image, of the tag in `versions` (or the quadlet's).
        out.write(
            "quadlet/immich-machine-learning.container.conf",
            cdi + f"Image={image(spec, sec, 'machine-learning', name)}-cuda\n",
        )
        out.write("quadlet/immich-server.container.conf", cdi)


def nvidia_card():
    """An NVIDIA card in the machine (PCI vendor 0x10de) and its driver in the
    image (nvidia-ctk, for the CDI spec): what `gpu = "nvidia"` needs."""
    if not shutil.which("nvidia-ctk"):
        return False
    for vendor in glob.glob("/sys/bus/pci/devices/*/vendor"):
        try:
            with open(vendor, encoding="ascii") as f:
                if f.read().strip() == "0x10de":
                    return True
        except OSError:
            pass
    return False


def r_remote(name, spec, sec, out, ctx):
    db_password = need(sec, "db_password", name)
    out.write("database.env", env_file({"POSTGRES_DB": "guacamole_db", "POSTGRES_USER": "guacamole", "POSTGRES_PASSWORD": db_password}))
    env = dict(extra_env(sec, name))
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
    out.json("users.json", users(sec, name, ["login", "password"]))
    if CHECK_ONLY:
        return
    # DB schema, generated once per Guacamole version by the image's own script
    # (only read when the database is created: a later version's schema
    # changes are applied by hand, from its release notes).
    guac = image(spec, sec, "guacamole", name)
    cache = os.path.join(CACHE, f"guacamole-initdb-{guac.rsplit(':', 1)[1]}.sql")
    if not os.path.exists(cache) or os.path.getsize(cache) == 0:
        os.makedirs(CACHE, exist_ok=True)
        sql = subprocess.run(
            ["podman", "run", "--rm", guac, "/opt/guacamole/bin/initdb.sh", "--postgresql"],
            check=True, capture_output=True, text=True,
        ).stdout
        with open(cache, "w", encoding="utf-8") as f:
            f.write(sql)
    # Read by the postgres user of the DB container (schema only, no secrets).
    with open(cache, encoding="utf-8") as f:
        out.write("initdb/001-guacamole-schema.sql", f.read(), public=True)


CUSTOM = {"disks": r_disks, "immich": r_immich, "remote": r_remote}

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
        "CONFIG_UPDATES": updates.get("config", "hourly"),
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
    services = catalog()
    # The tunnel belongs to the host: [host] cloudflare_tunnel_token drives the
    # cloudflared service (an explicit [cloudflared] section still works too).
    token = cfg.get("host", {}).get("cloudflare_tunnel_token", "")
    if isinstance(token, str) and token.startswith("CHANGE_ME"):
        print("warning: host.cloudflare_tunnel_token is still CHANGE_ME -- no tunnel", file=sys.stderr)
    elif token and "cloudflared" not in cfg:
        cfg["cloudflared"] = {"tunnel_token": token}
    for key in cfg:
        if key not in services and key not in ("host", "updates"):
            print(f"warning: unknown section [{key}] ignored (no such service in this image)", file=sys.stderr)

    ctx = {"token": os.environ.get("LMS_GITHUB_TOKEN", ""), "user": os.environ.get("LMS_GITHUB_USER", "")}
    taken = {}  # storage folders claimed so far
    r_host(cfg, Out(os.path.join(out_root, "host")))
    status = 0
    for name, spec in services.items():
        if name not in cfg:
            continue
        target = os.path.join(out_root, name)
        out = Out(target)
        try:
            sec = cfg[name]
            if not isinstance(sec, dict):
                raise ConfigError(f"[{name}] must be a table")
            no_placeholders(sec, name)
            CUSTOM.get(name, r_generic)(name, spec, sec, out, ctx)
            images(spec, sec, out, name)
            volumes(out, *spec["volumes"])
            location(sec, out, name, taken)
            size(sec, out, name)
            limits(sec, out, name)
            os.makedirs(target, mode=0o700, exist_ok=True)
        except (ConfigError, subprocess.CalledProcessError, OSError) as e:
            shutil.rmtree(target, ignore_errors=True)
            Out(os.path.join(out_root, ".errors")).write(name, f"{e}\n")
            print(f"{name}: {e}", file=sys.stderr)
            status = 1
    return status


def cmd_services():
    for name, spec in catalog().items():
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
