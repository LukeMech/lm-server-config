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
LMS_GITHUB_USER ({{github_token}} / {{github_user}} in `env` defaults).

A service is a directory of quadlets in /usr/share/containers/systemd/<name>/.
Everything lm-server needs to know about it comes from those files:

    unit        <name>-pod if there's a <name>.pod, else its .container(s)
    volumes     subdirectories, from `Volume=/var/lib/lm-server/volumes/<name>/<sub>:...`
    # lm-server: description <text>
    # lm-server: route <hostname> <url>        (Cloudflare route; repeatable)
    # lm-server: env <KEY>=<default value>     (repeatable)
    # lm-server: require <KEY>                 (must be set in lm-server.toml)

With no custom renderer below, [<name>] in lm-server.toml renders to
env/<name>/<name>.env (point the quadlet's EnvironmentFile= there):
`env` defaults < top-level keys (api_secret -> API_SECRET) < `env = {...}`;
`users = [...]` goes to env/<name>/users.json for provision/<name>.sh.
"""

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
# on the system disk; `storage = "/var/mnt/<disk>"` in its section bind-mounts
# <disk>/<service> there instead (lm-server moves the data on a change).
VOLUMES = "/var/lib/lm-server/volumes"
CACHE = "/var/lib/lm-server/cache"
GUAC_IMAGE = "docker.io/guacamole/guacamole:1.6.0"
CHECK_ONLY = False  # `check`: validate without side effects (no podman)

# Keys of a service section lm-server handles itself (never passed as env).
RESERVED = {"storage", "cpus", "memory", "env", "users"}

# Services that are part of the system rather than quadlets.
BUILTIN = {
    "cloudflared": {
        "desc": "Cloudflare Tunnel",
        "units": ["lm-server-cloudflared"],
        "routes": {"proxmox.lukemech.org": "https://localhost:9090"},
        "env": {},
        "require": ["TUNNEL_TOKEN"],
        "volumes": [],
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
        spec = {"desc": name, "units": units, "routes": {}, "env": {}, "require": [], "volumes": []}
        vol = re.compile(rf"^Volume={re.escape(VOLUMES)}/{re.escape(name)}(/[^:]*)?:")
        for f in files:
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
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

    def write(self, rel, text, mode="w"):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, mode, encoding="utf-8", newline="\n") as f:
            f.write(text)
        os.chmod(path, 0o600)

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
    folders = sec.get("syncthing_folders", {"keepass": "/mnt/disk_0/Keepass", "sync": "/mnt/disk_0/Sync"})
    for fid, path in folders.items():
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", fid) or not re.fullmatch(r"/mnt/(disk_0|docs)(/[^\s]*)?", path):
            raise ConfigError(f"{name}.syncthing_folders: '{fid}' -> '{path}' (path must be under /mnt/disk_0 or /mnt/docs, no spaces)")
    admin = need(sec, "filebrowser_admin", name)
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
    volumes(out, *(p[len("/mnt/"):] for p in folders.values()))


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
            volumes(out, *spec["volumes"])
            storage(sec, out, name)
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
