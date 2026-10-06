/* global cockpit */
"use strict";

// Management page (menu "Management", package name "updates"): updates of the
// system image (bootc), containers (podman auto-update) and config (secrets
// repo) -- a summary with "Update all", then each in detail -- plus status,
// history, the lm-server.toml editor and the GitHub setup.
//
// Package name "updates": the Overview page's Health card shows the status
// of exactly that page (an allowlist in Cockpit), as a link to it. The shell
// preloads this page at login ("preload" in the manifest), so the check
// below runs in the background and the Health card line is there right away.

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const mb = n => (n / 1e6).toFixed(1) + " MB";
const shortDigest = d => (d || "").replace(/^sha256:/, "").slice(0, 12);
const shortRev = r => (r || "").slice(0, 7);
const root = { superuser: "require", err: "message" };

function ago(ts) {
    if (!ts) return "";
    const s = (Date.now() - new Date(ts)) / 1000;
    if (!(s >= 0)) return "";
    if (s < 90) return "just now";
    for (const [unit, len] of [["day", 86400], ["hour", 3600], ["minute", 60]]) {
        if (s >= len * 1.5 || unit === "minute") {
            const n = Math.round(s / len);
            return `${n} ${unit}${n === 1 ? "" : "s"} ago`;
        }
    }
}

// ---- State
const state = {
    sys: null, sysError: null, sysChecked: null, sysTimer: "",
    ctr: null, ctrError: null,
    cfg: null, cfgError: null,
    checking: false, checkedAt: null,
    run: null, // "Update all" in progress / last result: { steps: [...] }
};
let busy = false;
let lastError = null; // why the last run() failed (cockpit.spawn exception)
let configBase = null; // commit the editor text was loaded from (for save --base)

function setBusy(on) {
    busy = on;
    document.querySelectorAll("button[data-action]").forEach(b => { b.disabled = on; });
    // Nothing to save until a file was loaded.
    if (!on) $("config-save").disabled = configBase === null;
}
async function exclusive(fn) {
    if (busy) return;
    setBusy(true);
    try {
        return await fn();
    } finally {
        setBusy(false);
        render();
    }
}

// `lm-server <args>` as root, output streamed live into log (a <pre>).
// onData(chunk) may take over the output: it returns what still goes to the log.
// input: written to its stdin.
function run(args, log, onData, append, input) {
    lastError = null;
    log.hidden = false;
    log.classList.remove("failed");
    const head = "$ lm-server " + args.join(" ") + "\n";
    if (append) log.textContent += (log.textContent ? "\n" : "") + head;
    else log.textContent = head;
    const proc = cockpit.spawn(["/usr/bin/lm-server", ...args], { superuser: "require", err: "out" });
    if (input !== undefined) proc.input(input);
    proc.stream(data => {
        if (onData) data = onData(data);
        if (!data) return;
        const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 4;
        log.textContent += data;
        if (atBottom) log.scrollTop = log.scrollHeight;
    });
    return proc
        .then(() => {
            log.textContent += "\n✔ done\n";
            return true;
        })
        .catch(ex => {
            lastError = ex;
            // Exit 3 (sync): applied, but some services were skipped -- see above.
            if (ex.exit_status === 3) {
                log.textContent += "\n⚠ done, some services skipped (see above)\n";
                return true;
            }
            log.textContent += ex.problem === "access-denied"
                ? "\n✘ needs administrative access: turn it on with “Limited access” in Cockpit's top bar.\n"
                : "\n✘ failed: " + (ex.message || ex) + "\n";
            log.classList.add("failed");
            return false;
        })
        .finally(() => { log.scrollTop = log.scrollHeight; });
}

// ---- Loading what there is (no changes made)
function loadSystem() {
    const timer = cockpit.spawn(["systemctl", "show", "lm-server-upgrade.timer", "--property=ActiveState,NextElapseUSecRealtime"], { err: "ignore" })
        .then(out => {
            const p = Object.fromEntries(out.trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
            state.sysTimer = p.ActiveState === "active" && p.NextElapseUSecRealtime
                ? "Automatic updates: on — next " + p.NextElapseUSecRealtime
                : "Automatic updates: off ([updates] system = \"manual\")";
        })
        .catch(() => { state.sysTimer = ""; });
    return Promise.all([cockpit.spawn(["bootc", "status", "--format=json"], root), timer])
        .then(([out]) => { state.sys = JSON.parse(out); state.sysError = null; })
        .catch(ex => { state.sysError = ex; })
        .finally(render);
}

function loadContainers() {
    return cockpit.spawn(["/usr/bin/lm-server", "containers", "--json"], root)
        .then(out => { state.ctr = JSON.parse(out); state.ctrError = null; })
        .catch(ex => { state.ctrError = ex; })
        .finally(render);
}

// Quick refresh without the registries (containers that started, stopped,
// or got a new image since): the last check's verdict stays for every
// container still on the same image.
let ctrRefreshing = false;
function refreshContainers() {
    if (ctrRefreshing || busy || !state.ctr) return;
    ctrRefreshing = true;
    cockpit.spawn(["/usr/bin/lm-server", "containers", "--json", "--no-check"], root)
        .then(out => {
            const prev = Object.fromEntries(state.ctr.map(c => [c.container, c]));
            state.ctr = JSON.parse(out).map(c => {
                const old = prev[c.container];
                return old && old.image_id === c.image_id
                    ? { ...c, update: old.update, available: old.available, error: old.error }
                    : c;
            });
            renderContainers();
            renderSummary();
            publishStatus();
        })
        .catch(() => { /* keep what's shown */ })
        .finally(() => { ctrRefreshing = false; });
}
setInterval(() => { if (!cockpit.hidden) refreshContainers(); }, 30000);

function loadConfig() {
    return cockpit.spawn(["/usr/bin/lm-server", "config", "status"], root)
        .then(out => {
            const cfg = {};
            for (const line of out.split("\n")) {
                const i = line.indexOf("=");
                if (i > 0) cfg[line.slice(0, i)] = line.slice(i + 1);
            }
            state.cfg = cfg;
            state.cfgError = null;
        })
        .catch(ex => { state.cfgError = ex; })
        .finally(render);
}

// Asks every source whether there's something new. `bootc upgrade --check`
// only fetches the metadata; bootc status then shows it as cachedUpdate.
function checkAll() {
    state.checking = true;
    publishStatus();
    render();
    const sys = cockpit.spawn(["/usr/bin/lm-server", "system", "update", "--check"], root)
        .then(() => { state.sysChecked = new Date(); })
        .catch(() => { /* reported by loadSystem */ })
        .then(loadSystem);
    return Promise.all([sys, loadContainers(), loadConfig()]).finally(() => {
        state.checking = false;
        state.checkedAt = new Date();
        render();
    });
}

// ---- What's pending
const version = img => img?.version || shortDigest(img?.imageDigest);

function sysInfo() {
    const st = state.sys?.status || {};
    const booted = st.booted?.image, staged = st.staged;
    const update = st.booted?.cachedUpdate;
    const pending = update && update.imageDigest !== booted?.imageDigest &&
        update.imageDigest !== staged?.image?.imageDigest ? update : null;
    return { st, booted, staged: staged && !staged.downloadOnly ? staged : null, downloaded: staged?.downloadOnly ? staged : null, pending, rollback: st.rollback };
}
const ctrPending = () => (state.ctr || []).filter(c => c.update === "pending");
const cfgPending = () => state.cfg && state.cfg.REMOTE_REV && state.cfg.REMOTE_REV !== state.cfg.SYNCED_REV;

// Overview page, Health card: one line, a link to this page.
let lastStatus;
function publishStatus() {
    let status = null;
    const s = sysInfo();
    const parts = [];
    if (s.pending || s.downloaded) parts.push("system " + version((s.pending || s.downloaded.image)));
    const n = ctrPending().length;
    if (n) parts.push(n + (n === 1 ? " container" : " containers"));
    if (cfgPending()) parts.push("config");
    const known = state.sys || state.ctr || state.cfg;

    // While "Update all" runs, the running step says so.
    const step = state.run?.steps.find(st => st.state === "running");

    if (step) {
        status = { title: `Updating: ${step.label.toLowerCase()}…`, details: { pficon: "spinner" } };
    } else if (state.checking && !known) {
        status = { title: "Checking for updates…", details: { pficon: "spinner" } };
    } else if (s.staged) {
        status = { type: "warning", title: `System update ${version(s.staged.image)} downloaded — reboot to apply`, details: { pficon: "enhancement" } };
    } else if (parts.length) {
        status = { type: "info", title: "Updates available: " + parts.join(", "), details: { pficon: "enhancement" } };
    } else if (known && !state.sysError && !state.ctrError) {
        status = { title: "System, containers and config are up to date", details: { pficon: "check" } };
    }
    const json = JSON.stringify(status);
    if (json !== lastStatus) {
        lastStatus = json;
        cockpit.transport.control("notify", { page_status: status });
    }
}

// ---- Rendering
function problem(ex) {
    if (!ex) return "";
    return ex.problem === "access-denied"
        ? "🔒 Needs administrative access (“Limited access” in Cockpit's top bar)."
        : "✘ " + (ex.message || ex);
}

function render() {
    publishStatus();
    renderSummary();
    renderRun();
    renderSystem();
    renderContainers();
    renderConfig();
}

function tile(id, cls, stateText, lines, extra) {
    $(id).querySelector(".tile-body").innerHTML =
        `<div class="state ${cls}">${stateText}</div>` +
        lines.filter(Boolean).map(l => `<div class="muted">${l}</div>`).join("") + (extra || "");
}

function renderSummary() {
    $("checked").textContent = state.checking ? "Checking for updates…"
        : state.checkedAt ? "Last checked " + ago(state.checkedAt) + "." : "";

    // System
    const s = sysInfo();
    if (state.sysError && !state.sys) {
        tile("tile-system", "warn", esc(problem(state.sysError)), []);
    } else if (!state.sys) {
        tile("tile-system", "", "Loading…", []);
    } else {
        const running = s.booted ? `Running <strong>${esc(version(s.booted))}</strong> · built ${esc(ago(s.booted.timestamp))}` : "";
        if (s.staged) {
            tile("tile-system", "info", `⬆ ${esc(version(s.staged.image))} downloaded — reboot to apply`, [running],
                 `<button data-reboot>Reboot now</button>`);
        } else if (s.pending || s.downloaded) {
            const img = s.pending || s.downloaded.image;
            tile("tile-system", "info", `⬆ ${esc(version(img))} available`, [`Built ${esc(ago(img.timestamp))}`, running]);
        } else {
            tile("tile-system", "ok", "✔ Up to date", [running]);
        }
    }

    // Containers
    if (state.ctrError && !state.ctr) {
        tile("tile-containers", "warn", esc(problem(state.ctrError)), []);
    } else if (!state.ctr) {
        tile("tile-containers", "", "Checking…", []);
    } else {
        const pending = ctrPending();
        const total = state.ctr.length;
        if (pending.length) {
            const names = pending.slice(0, 4).map(c => `<li>${esc(c.container)}</li>`).join("") +
                (pending.length > 4 ? `<li>and ${pending.length - 4} more</li>` : "");
            tile("tile-containers", "info", `⬆ ${pending.length} of ${total} have a newer image`, [], `<ul class="muted">${names}</ul>`);
        } else {
            // (Running or not: the Services card, which stays current.)
            tile("tile-containers", "ok", `✔ All ${total} up to date`, []);
        }
    }

    // Config
    const c = state.cfg;
    if (state.cfgError && !c) {
        const notSetUp = /not configured/.test(state.cfgError.message || "");
        tile("tile-config", "warn", notSetUp ? "Not set up yet" : esc(problem(state.cfgError)), [notSetUp ? "Set up the GitHub repo below" : ""]);
    } else if (!c) {
        tile("tile-config", "", "Loading…", []);
    } else if (cfgPending()) {
        tile("tile-config", "info", `⬆ New commit ${esc(shortRev(c.REMOTE_REV))} on GitHub`,
             [`Applied ${esc(shortRev(c.SYNCED_REV) || "nothing yet")}${c.SYNCED_AT ? " · " + esc(ago(c.SYNCED_AT)) : ""}`]);
    } else {
        tile("tile-config", "ok", "✔ Up to date", [`Commit ${esc(shortRev(c.SYNCED_REV))} · synced ${esc(ago(c.SYNCED_AT))}`]);
    }
}

// Progress bar inside `el` (.stage/.amount/.fill/.progress-detail)
function bar(el, stage, fraction, amount, detail) {
    const pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
    el.hidden = false;
    el.querySelector(".stage").textContent = stage;
    el.querySelector(".amount").textContent = amount ? `${amount} · ${pct}%` : `${pct}%`;
    el.querySelector(".progress-detail").textContent = detail;
    el.querySelector(".fill").style.width = pct + "%";
    el.querySelector(".bar").setAttribute("aria-valuenow", pct);
}

// `lm-server system update --progress` prints bootc's JSON Lines events between its
// normal output; they drive the bar, everything else goes to the log.
const STAGES = { pulling: "Downloading", importing: "Importing", staging: "Staging" };
function progressParser(el) {
    let partial = "";
    return chunk => {
        const lines = (partial + chunk).split("\n");
        partial = lines.pop();
        let text = "";
        for (const line of lines) {
            let ev = null;
            if (line.startsWith("{")) {
                try { ev = JSON.parse(line); } catch (_) { /* not an event */ }
            }
            if (!ev?.type) {
                text += line + "\n";
                continue;
            }
            if (ev.type === "Start") {
                bar(el, "Starting…", 0, "", "");
                continue;
            }
            const stage = STAGES[ev.task] || ev.description || ev.task;
            const unit = ev.task === "pulling" ? "Layer" : "Step";
            const steps = ev.stepsTotal ? `${unit} ${Math.min(ev.steps + 1, ev.stepsTotal)} of ${ev.stepsTotal}` : "";
            // A running discrete step says what it does ("Staging image", ...).
            const running = ev.type === "ProgressSteps" && (ev.subtasks || []).find(t => !t.completed)?.description;
            if (ev.type === "ProgressBytes" && ev.bytesTotal) {
                bar(el, stage, ev.bytes / ev.bytesTotal, `${mb(ev.bytes)} / ${mb(ev.bytesTotal)}`, steps);
            } else {
                bar(el, stage, ev.stepsTotal ? ev.steps / ev.stepsTotal : 0, "", [steps, running].filter(Boolean).join(" · "));
            }
        }
        return text;
    };
}

// ---- Update all: config -> containers -> system image (staged for reboot)
const STEPS = [
    { key: "config", label: "Config", args: ["config", "pull"], busyText: "Applying lm-server.toml from GitHub…" },
    { key: "containers", label: "Containers", args: ["containers", "update"], busyText: "Pulling newer images, restarting what changed, cleaning up…" },
    { key: "system", label: "System image", args: ["system", "update", "--progress"], busyText: "Downloading the new image…" },
];
const ICONS = { waiting: "○", running: "◐", done: "✔", failed: "✘" };

function renderRun() {
    const r = state.run;
    $("run").hidden = !r;
    if (!r) return;
    $("run-steps").innerHTML = r.steps.map(st => `<li class="${st.state}">
        <span class="icon">${ICONS[st.state]}</span><strong>${esc(st.label)}</strong>
        <span class="detail">${esc(st.detail || "")}</span></li>`).join("") +
        (r.reboot ? `<li class="done"><span class="icon">↻</span><strong>Reboot</strong>
            <span class="detail">The new system image applies on the next reboot. <button data-reboot>Reboot now</button></span></li>` : "");
}

function updateAll() {
    if (!window.confirm("Apply the config from GitHub, update the containers (services with a new image restart) and download the new system image?")) return;
    return exclusive(async () => {
        const log = $("run-log");
        log.textContent = "";
        state.run = { steps: STEPS.map(s => ({ ...s, state: "waiting", detail: "" })) };
        for (const step of state.run.steps) {
            step.state = "running";
            step.detail = step.busyText;
            renderRun();
            publishStatus();
            const prog = $("run-progress");
            const onData = step.key === "system" ? progressParser(prog) : undefined;
            if (onData) bar(prog, "Checking…", 0, "", "");
            const ok = await run(step.args, log, onData, true);
            step.state = ok ? "done" : "failed";
            step.detail = ok ? "Done" : "Failed — see the log";
            if (!ok) log.closest("details").open = true;
            if (onData) prog.hidden = true;
            renderRun();
        }
        await Promise.all([loadSystem(), loadContainers(), loadConfig(), loadResources(false), loadHistory()]);
        state.checkedAt = new Date();
        state.run.reboot = !!sysInfo().staged;
        const sys = state.run.steps[2];
        if (sys.state === "done") sys.detail = state.run.reboot ? "Downloaded — applies on reboot" : "Already up to date";
    });
}

// ---- Details: system
function renderSystem() {
    if (state.sysError && !state.sys) {
        $("sys-status").innerHTML = `<li class="warn">${esc(problem(state.sysError))}</li>`;
        return;
    }
    if (!state.sys) return;
    const { st, booted, pending, rollback } = sysInfo();
    const staged = st.staged;

    const lines = [];
    if (staged && !staged.downloadOnly) {
        lines.push(`<li class="info">⬆ Update <strong>${esc(version(staged.image))}</strong> downloaded — it applies on the next reboot. <button data-reboot>Reboot now</button></li>`);
    } else if (pending) {
        lines.push(`<li class="info">⬆ Update available: <strong>${esc(version(pending))}</strong> (built ${esc(ago(pending.timestamp))})</li>`);
    } else {
        lines.push(`<li class="ok">✔ System is up to date${state.sysChecked ? " (checked " + esc(ago(state.sysChecked)) + ")" : ""}</li>`);
    }
    if (st.rollbackQueued) {
        lines.push(`<li class="warn">↩ The next reboot goes back to <strong>${esc(version(rollback?.image))}</strong>. <button data-reboot>Reboot now</button></li>`);
    }
    if (st.booted?.incompatible) lines.push(`<li class="warn">⚠ The running deployment has local package changes (incompatible with image updates).</li>`);
    lines.push(`<li class="muted">${esc(state.sysTimer)}</li>`);
    $("sys-status").innerHTML = lines.join("");

    const ref = state.sys?.spec?.image || booted?.image || {};
    const [name, tag] = (ref.image || "").split(/:(?=[^:/]+$)/);
    // bootc: "containerPolicy" | "insecure" | { ostreeRemote: "<name>" }
    const sig = typeof ref.signature === "string" ? ref.signature : Object.keys(ref.signature || {})[0];
    const SIGS = { containerPolicy: "checked (policy.json, cosign)", insecure: "not checked", ostreeRemote: "ostree remote" };
    $("sys-source").innerHTML = `
        <dt>Image</dt><dd><code>${esc(name)}</code></dd>
        <dt>Tag</dt><dd>${esc(tag || "latest")}</dd>
        <dt>Transport</dt><dd>${esc(ref.transport)}</dd>
        <dt>Signature</dt><dd>${esc(SIGS[sig] || sig || "default (policy.json)")}</dd>`;

    // Deployments, newest first
    const rows = [];
    const row = (img, badge, cls, action) => rows.push(`<tr>
        <td><strong>${esc(version(img))}</strong></td>
        <td><span class="badge ${cls}">${badge}</span></td>
        <td title="${esc(img?.timestamp)}">${esc(ago(img?.timestamp))}</td>
        <td><code>${esc(shortDigest(img?.imageDigest))}</code></td>
        <td class="row-actions">${action || ""}</td></tr>`);
    if (pending) row(pending, "Available", "info", `<button data-action="sys-download">Download</button>`);
    if (staged) row(staged.image, staged.downloadOnly ? "Downloaded" : "Next boot", "info", `<button data-reboot>Reboot now</button>`);
    if (booted) row(booted, "Current", "ok");
    if (rollback) {
        row(rollback.image, st.rollbackQueued ? "Next boot" : "Previous", st.rollbackQueued ? "warn" : "",
            st.rollbackQueued ? "" : `<button data-action="sys-rollback">Roll back</button>`);
    }
    $("sys-deployments").innerHTML = rows.join("") || `<tr><td colspan="5" class="muted">No bootc deployments found.</td></tr>`;
    if (busy) $("sys-deployments").querySelectorAll("button[data-action]").forEach(b => { b.disabled = true; });
}

function sysUpgrade(apply) {
    if (apply && !window.confirm("Download the new system image and reboot into it now?")) return;
    return exclusive(async () => {
        const prog = $("sys-progress");
        bar(prog, "Checking…", 0, "", "");
        const ok = await run(["system", "update", "--progress", ...(apply ? ["--apply"] : [])], $("system").querySelector(".log"), progressParser(prog));
        // --apply reboots right after staging: the connection just drops.
        const rebooting = apply && (ok || ["disconnected", "terminated"].includes(lastError?.problem));
        if (rebooting) return bar(prog, "Rebooting…", 1, "", "The server restarts into the new image; reload this page in a minute.");
        if (ok) bar(prog, "Done", 1, "", "Downloaded — it applies on the next reboot.");
        else prog.hidden = true;
        await loadSystem();
    });
}

// ---- Details: containers
function imgText(i) {
    if (!i) return "";
    if (i.error) return `<span class="sub">? ${esc(i.error)}</span>`;
    const v = i.version || shortDigest(i.digest) || "?";
    const sub = [i.created ? "built " + ago(i.created) : "", i.version ? shortDigest(i.digest) : ""].filter(Boolean).join(" · ");
    return `<strong title="${esc(i.digest)}">${esc(v)}</strong><span class="sub">${esc(sub)}</span>`;
}

function renderContainers() {
    const tbody = $("ctr-rows");
    if (state.ctrError && !state.ctr) {
        tbody.innerHTML = `<tr><td colspan="4" class="muted">${esc(problem(state.ctrError))}</td></tr>`;
        return;
    }
    if (!state.ctr) return;
    let prev = null;
    tbody.innerHTML = state.ctr.map(c => {
        let avail;
        // Following a file upstream (e.g. Immich's compose): a link to it.
        const src = c.source ? ` <a class="badge" href="${esc(c.source)}" target="_blank" rel="noopener noreferrer">Source</a>` : "";
        if (c.update === "pending") avail = `<span class="badge info">Update</span>${src} ${imgText(c.available)}`;
        else if (c.update === "false") avail = `<span class="badge ok">Up to date</span>${src}`;
        else if (c.error) avail = `<span class="badge warn">Unknown</span><span class="sub">${esc(c.error)}</span>`;
        else if (c.policy || c.source) avail = `<span class="badge">Not checked yet</span>${src}`;
        else avail = `<span class="badge">Not auto-updated</span>`;
        const first = c.service !== prev;
        prev = c.service;
        return `<tr class="${first ? "group" : ""}">
            <td>${first ? `<strong>${esc(c.service)}</strong>` : ""}</td>
            <td>${esc(c.container)}<span class="sub">${esc(c.image)}</span></td>
            <td>${imgText(c.current)}</td>
            <td>${avail}</td></tr>`;
    }).join("") || `<tr><td colspan="4" class="muted">No system containers.</td></tr>`;
}

// ---- Details: config
function renderConfig() {
    const c = state.cfg;
    if (state.cfgError && !c) {
        $("cfg-info").innerHTML = `<dt>Status</dt><dd>${esc(problem(state.cfgError))}</dd>`;
        return;
    }
    if (!c) return;
    // Repository, file and user: setup-info above (setupLoad).
    $("cfg-info").innerHTML = `
        <dt>Applied</dt><dd><code>${esc(shortRev(c.SYNCED_REV) || "—")}</code> ${c.SYNCED_AT ? esc(ago(c.SYNCED_AT)) : "never"}</dd>
        <dt>On GitHub</dt><dd><code>${esc(shortRev(c.REMOTE_REV))}</code> ${cfgPending() ? `<span class="badge info">New</span>` : `<span class="badge ok">Applied</span>`}</dd>`;
}

// ---- Services: CPU / memory / disk of each service vs. its limits
const iec = n => {
    if (n == null) return "—";
    for (const u of ["B", "K", "M", "G", "T"]) {
        if (n < 1024 || u === "T") return u === "B" ? `${n} B` : `${n.toFixed(n < 10 ? 1 : 0)} ${u}iB`;
        n /= 1024;
    }
};
let resources = null;
let host = null;
let resourcesRunning = false;

// with_disk: also measure data folders that aren't a filesystem of their own
// (du -- slow on big ones). Without it, the last measured values stay.
function loadResources(withDisk) {
    if (resourcesRunning) return Promise.resolve();
    resourcesRunning = true;
    const args = ["/usr/bin/lm-server", "services", "resources", "--json", ...(withDisk ? [] : ["--no-disk"])];
    return cockpit.spawn(args, root)
        .then(out => {
            const prev = Object.fromEntries((resources || []).map(r => [r.service, r]));
            ({ host, services: resources } = JSON.parse(out));
            for (const r of resources) {
                const old = prev[r.service]?.disk;
                if (r.disk.used == null && old?.used != null) r.disk = old;
            }
            renderResources();
        })
        .catch(ex => {
            if (!resources) $("svc-rows").innerHTML = `<tr><td colspan="5" class="muted">${esc(problem(ex))}</td></tr>`;
        })
        .finally(() => { resourcesRunning = false; });
}

// A value, and a bar when there's a limit to compare it with.
function meter(text, fraction, sub) {
    const bar = fraction == null ? ""
        : `<div class="bar${fraction > 0.9 ? " high" : ""}"><div class="fill" data-pct="${Math.min(100, Math.round(fraction * 100))}"></div></div>`;
    return `<div class="meter">${bar}<span>${text}</span>${sub ? `<span class="sub">${sub}</span>` : ""}</div>`;
}

const pct = x => `${(x * 100).toFixed(x < 0.1 ? 1 : 0)}%`;
const threads = n => `${+n.toFixed(1)} ${n === 1 ? "thread" : "threads"}`;

// The whole machine: CPU, RAM against what the limits hand out, disk I/O.
function renderHost() {
    if (!host) return;
    const tile = (id, html) => {
        const body = $(id).querySelector(".tile-body");
        body.classList.remove("muted");
        body.innerHTML = html;
    };
    const cpu = host.cpu_percent == null ? null : host.cpu_percent / 100;
    tile("host-cpu", meter(cpu == null ? "—" : `${pct(cpu)} of ${threads(host.cpus)}`, cpu,
        host.cpu_limits ? `limits add up to ${threads(host.cpu_limits)} (a limit caps a service, the threads are shared)` : ""));
    const used = host.memory_total ? host.memory_used / host.memory_total : null;
    const limits = host.memory_total ? host.memory_limits / host.memory_total : null;
    tile("host-memory", meter(`${iec(host.memory_used)} / ${iec(host.memory_total)}`, used,
        `limits add up to ${iec(host.memory_limits)}${limits == null ? "" : ` (${pct(limits)})`}; without file cache, like Cockpit's overview`));
    const rate = n => n == null ? "—" : `${iec(n)}/s`;
    tile("host-disks", host.disks.length ? `<div class="io">
        <span class="sub">Disk</span><span class="sub num">Read</span><span class="sub num">Write</span>
        ${host.disks.map(d => `<span class="dev">${esc(d.name)}<span class="sub">${esc(d.label)}</span></span>
            <span class="num">${rate(d.read)}</span><span class="num">${rate(d.write)}</span>`).join("")}
    </div>` : `<span class="muted">No disks found.</span>`);
}

function renderResources() {
    if (!resources) return;
    renderHost();
    $("svc-rows").innerHTML = resources.map(r => {
        const states = Object.values(r.units);
        let badge;
        if (!r.enabled) badge = `<span class="badge">Not configured</span>`;
        else if (states.every(s => s === "active")) badge = `<span class="badge ok">Running</span>`;
        else {
            // The pod and its containers: name the ones that aren't running.
            const down = Object.entries(r.units).filter(([, s]) => s !== "active");
            const label = down.some(([, s]) => s === "failed") ? "Failed"
                : down.some(([, s]) => s === "activating") ? "Starting" : "Stopped";
            badge = `<span class="badge warn">${label}</span><span class="sub">${esc(down.map(([u, s]) => `${u}: ${s}`).join(", "))}</span>`;
        }

        // CPU as a share of what it may use: its `cpus` (threads), or the
        // whole machine without a limit. (systemd counts 100% per thread.)
        const cores = r.cpu_limit || r.host_cpus || null;
        const cpuShare = r.cpu_percent == null || !cores ? null : r.cpu_percent / (cores * 100);
        const cpuText = cpuShare == null ? "—"
            : `${pct(cpuShare)} of ${r.cpu_limit ? threads(r.cpu_limit) : `all ${threads(cores)}`}`;
        const mem = r.memory_limit ? `${iec(r.memory)} / ${iec(r.memory_limit)}` : iec(r.memory);
        const d = r.disk;
        const diskText = d.size ? `${iec(d.used)} / ${iec(d.size)}` : d.error ? esc(d.error) : iec(d.used);
        const diskSub = { image: "own filesystem", storage: esc(d.folder), system: "system disk" }[d.kind];
        return `<tr>
            <td><strong>${esc(r.service)}</strong><span class="sub">${esc(r.description)}${r.builtin ? " · part of the system image, not a container" : ""}</span></td>
            <td>${badge}</td>
            <td>${meter(cpuText, r.cpu_limit ? cpuShare : null, r.enabled && !r.cpu_limit ? "no limit" : "")}</td>
            <td>${meter(mem, r.memory_limit && r.memory != null ? r.memory / r.memory_limit : null,
                [r.memory_cache ? `+ ${iec(r.memory_cache)} file cache` : "", r.enabled && !r.memory_limit ? "no limit" : ""].filter(Boolean).join(" · "))}</td>
            <td>${meter(diskText, d.size && d.used != null ? d.used / d.size : null, diskSub)}</td></tr>`;
    }).join("") || `<tr><td colspan="5" class="muted">No services.</td></tr>`;
    // Widths set here, not in the markup (Cockpit's CSP: no inline styles).
    $("services").querySelectorAll(".fill[data-pct]").forEach(f => { f.style.width = f.dataset.pct + "%"; });
}

// While the page is shown (Cockpit hides it in the background otherwise).
setInterval(() => { if (!cockpit.hidden) loadResources(false); }, 3000);

// ---- Automatic runs: the journal of the update/sync units, as a table
const HISTORY_LINE = /^(\d{4}-\d\d-\d\dT[\d:]+(?:[+-][\d:]+|Z)?) \S+ ([^\s[:]+)(?:\[\d+\])?: (.*)$/;
function loadHistory() {
    return cockpit.spawn(["/usr/bin/lm-server", "history", "300"], root)
        .then(out => {
            const rows = out.split("\n").map(l => l.match(HISTORY_LINE)).filter(Boolean).reverse();
            $("history-rows").innerHTML = rows.map(([, ts, src, msg]) => {
                const cls = /error|fail|✘/i.test(msg) ? "bad" : /warn|skipped/i.test(msg) ? "warn" : "";
                const when = new Date(ts);
                return `<tr class="${cls}"><td title="${esc(ts)}">${esc(when.toLocaleString())}</td>
                    <td>${esc(src)}</td><td>${esc(msg)}</td></tr>`;
            }).join("") || `<tr><td colspan="3" class="muted">Nothing yet.</td></tr>`;
        })
        .catch(ex => { $("history-rows").innerHTML = `<tr><td colspan="3" class="muted">${esc(problem(ex))}</td></tr>`; });
}

// ---- lm-server.toml editor
function configLoad() {
    const log = $("config").querySelector(".log");
    return Promise.all([
        cockpit.spawn(["/usr/bin/lm-server", "config", "rev"], root),
        cockpit.spawn(["/usr/bin/lm-server", "config", "show"], root),
    ])
        .then(([rev, text]) => {
            configBase = rev.trim();
            $("config-text").value = text;
            $("config-text").hidden = false;
            $("config-load").textContent = "Reload from GitHub";
            log.hidden = false;
            log.classList.remove("failed");
            log.textContent = "Loaded commit " + configBase.slice(0, 7) + ".";
        })
        .catch(ex => {
            log.hidden = false;
            log.classList.add("failed");
            log.textContent = "✘ could not load: " + (ex.message || ex);
        });
}

function configSave() {
    if (!window.confirm("Commit and push this lm-server.toml to GitHub, then apply it?")) return;
    // On failure the edit stays in the box, to fix and retry.
    return exclusive(async () => {
        const ok = await run(["config", "save", "--base", configBase], $("config").querySelector(".log"),
                             undefined, false, $("config-text").value.replace(/\r\n/g, "\n"));
        if (ok) await Promise.all([configLoad(), loadConfig(), loadResources(false)]);
    });
}

// ---- Secrets repo setup; the form shows the current setup as placeholders
function setupLoad() {
    const form = $("setup");
    const fields = { REPO: "repo", CONFIG: "config", GITHUB_USER: "user" };
    return cockpit.spawn(["/usr/bin/lm-server", "config", "source"], { superuser: "require", err: "ignore" })
        .then(out => {
            for (const line of out.split("\n")) {
                const i = line.indexOf("=");
                if (i < 0) continue;
                const key = line.slice(0, i), value = line.slice(i + 1);
                if (key === "BRANCH") form.elements.branch.value = value;
                else if (fields[key] && value) form.elements[fields[key]].placeholder = value;
            }
            const f = form.elements;
            $("setup-info").innerHTML = `
                <dt>Repository</dt><dd><code>${esc(f.repo.placeholder)}</code> (${esc(f.branch.value)})</dd>
                <dt>Config file</dt><dd><code>${esc(f.config.placeholder)}</code></dd>
                <dt>GitHub user</dt><dd>${esc(f.user.placeholder || "—")}</dd>`;
        })
        // Not set up yet (or no admin access): the form open, with the defaults.
        .catch(() => { $("setup").closest("details").open = true; });
}

$("setup").addEventListener("submit", event => {
    event.preventDefault();
    const form = event.target;
    const f = new FormData(form);
    // Empty fields keep the current setting (shown as the placeholder).
    const val = name => f.get(name) || form.elements[name].placeholder;
    const args = ["setup", "--repo", val("repo"), "--branch", f.get("branch"), "--token-stdin", "--config", val("config")];
    if (val("user")) args.push("--user", val("user"));
    const token = f.get("token") + "\n";
    form.elements.token.value = "";
    exclusive(async () => {
        await run(args, $("config").querySelector(".log"), undefined, false, token);
        await Promise.all([setupLoad(), loadConfig(), loadResources(false)]);
    });
});

// ---- Buttons (also the ones drawn by render())
function reboot() {
    if (!window.confirm("Reboot the server now?")) return;
    cockpit.spawn(["systemctl", "reboot"], root).catch(() => {});
    $("run").hidden = false;
    bar($("run-progress"), "Rebooting…", 1, "", "Reload this page in a minute.");
}

const ACTIONS = {
    check: () => exclusive(checkAll),
    all: updateAll,
    "sys-check": () => exclusive(async () => {
        if (await run(["system", "update", "--check"], $("system").querySelector(".log"))) state.sysChecked = new Date();
        await loadSystem();
    }),
    "sys-download": () => sysUpgrade(false),
    "sys-apply": () => sysUpgrade(true),
    "sys-rollback": () => {
        if (!window.confirm("Boot the previous system image on the next reboot?")) return;
        return exclusive(async () => {
            await run(["system", "rollback"], $("system").querySelector(".log"));
            await loadSystem();
        });
    },
    "ctr-check": () => exclusive(async () => {
        state.ctr = null;
        render();
        await loadContainers();
    }),
    "ctr-update": () => exclusive(async () => {
        await run(["containers", "update"], $("containers").querySelector(".log"));
        await Promise.all([loadContainers(), loadResources(false)]);
    }),
    "cfg-sync": () => exclusive(async () => {
        await run(["config", "pull"], $("config").querySelector(".log"));
        await Promise.all([loadConfig(), loadResources(false)]);
    }),
    "config-load": () => exclusive(configLoad),
    "config-save": configSave,
    prune: () => {
        if (!window.confirm("Remove every container not defined by the system image?")) return;
        return exclusive(async () => {
            await run(["containers", "remove-adhoc"], $("containers").querySelector(".log"));
            await loadResources(false);
        });
    },
    "ctr-cleanup": () => exclusive(async () => {
        await run(["containers", "cleanup"], $("containers").querySelector(".log"));
        await loadResources(false);
    }),
    resources: () => loadResources(true),
    history: loadHistory,
};

document.body.addEventListener("click", ev => {
    const button = ev.target.closest("button");
    // The setup form's button submits the form (handled there).
    if (!button || button.disabled || button.closest("form")) return;
    if (button.hasAttribute("data-reboot")) return reboot();
    const action = ACTIONS[button.dataset.action];
    if (action) action();
});

// ---- Server: fastfetch, as a terminal shows it
// fastfetch draws its logo first, then moves the cursor back up and to the
// right (ESC[nA, ESC[nC) for the lines beside it -- so its output is played
// onto a grid of cells (character + color), then each row becomes HTML.
const ANSI = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
    "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"];

function xterm256(n) {
    if (n < 16) return ANSI[n];
    if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v},${v},${v})`; }
    n -= 16;
    const c = v => (v ? 55 + v * 40 : 0);
    return `rgb(${c(Math.floor(n / 36))},${c(Math.floor(n / 6) % 6)},${c(n % 6)})`;
}

function terminalHtml(text) {
    const rows = [];
    let r = 0, col = 0, fg = null, bg = null, bold = false;
    const put = ch => {
        while (rows.length <= r) rows.push([]);
        const row = rows[r];
        while (row.length < col) row.push({ ch: " " });
        row[col++] = { ch, fg, bg, bold };
    };
    // A color: 30-37/90-97 (fg) or 40-47/100-107 (bg) from the 16, 38/48;5;n
    // from the 256, 38/48;2;r;g;b as is.
    const sgr = params => {
        const p = params.length ? params.split(";").map(Number) : [0];
        for (let i = 0; i < p.length; i++) {
            const v = p[i];
            let color;
            if (p[i + 1] === 5 && (v === 38 || v === 48)) { color = xterm256(p[i + 2]); i += 2; }
            else if (p[i + 1] === 2 && (v === 38 || v === 48)) { color = `rgb(${p[i + 2]},${p[i + 3]},${p[i + 4]})`; i += 4; }
            if (v === 0) { fg = bg = null; bold = false; }
            else if (v === 1) bold = true;
            else if (v === 22) bold = false;
            else if (v === 39) fg = null;
            else if (v === 49) bg = null;
            else if (v === 38) fg = color;
            else if (v === 48) bg = color;
            else if (v >= 30 && v <= 37) fg = ANSI[v - 30];
            else if (v >= 90 && v <= 97) fg = ANSI[v - 90 + 8];
            else if (v >= 40 && v <= 47) bg = ANSI[v - 40];
            else if (v >= 100 && v <= 107) bg = ANSI[v - 100 + 8];
        }
    };
    const re = /\x1b\[([0-9;?]*)([A-Za-z])|\x1b\][^\x07]*\x07|([\s\S])/g;
    let m;
    while ((m = re.exec(text))) {
        if (m[3] !== undefined) {
            if (m[3] === "\n") { r++; col = 0; }
            else if (m[3] === "\r") col = 0;
            else if (m[3] >= " ") put(m[3]);
            continue;
        }
        if (m[2] === undefined) continue; // OSC (e.g. a window title)
        const n = parseInt(m[1], 10) || 1;
        switch (m[2]) {
        case "m": sgr(m[1]); break;
        case "A": r = Math.max(0, r - n); break;
        case "B": r += n; break;
        case "C": col += n; break;
        case "D": col = Math.max(0, col - n); break;
        case "G": col = n - 1; break;
        }
    }
    // Colors as data-fg/data-bg, set by paintTerminal(): Cockpit's CSP drops
    // style="..." attributes, but not styles set from script.
    return rows.map(row => {
        let html = "", open = null;
        for (const cell of row) {
            const key = cell.fg || cell.bg || cell.bold ? `${cell.fg}|${cell.bg}|${cell.bold}` : null;
            if (key !== open) {
                if (open) html += "</span>";
                if (key) {
                    html += `<span${cell.bold ? ' class="b"' : ""}${cell.fg ? ` data-fg="${cell.fg}"` : ""}` +
                        `${cell.bg ? ` data-bg="${cell.bg}"` : ""}>`;
                }
                open = key;
            }
            html += esc(cell.ch);
        }
        return html + (open ? "</span>" : "");
    }).join("\n").replace(/\s+$/, "");
}

// The modules that mean something here (no shell, terminal, display or
// theme -- Cockpit's bridge would be all of those).
const FASTFETCH = ["fastfetch", "--pipe", "false", "--structure",
    "Title:Separator:OS:Host:Kernel:Uptime:Packages:CPU:GPU:Memory:Swap:Disk:LocalIp:Break:Colors"];

function paintTerminal(el) {
    el.querySelectorAll("[data-fg]").forEach(s => { s.style.color = s.dataset.fg; });
    el.querySelectorAll("[data-bg]").forEach(s => { s.style.backgroundColor = s.dataset.bg; });
}

// TERM: Cockpit's bridge has none, and without it fastfetch may leave its
// colors out even with --pipe false.
function loadFastfetch() {
    return cockpit.spawn(FASTFETCH, { err: "message", environ: ["TERM=xterm-256color", "COLORTERM=truecolor"] })
        .then(out => {
            $("fastfetch").innerHTML = terminalHtml(out);
            paintTerminal($("fastfetch"));
        })
        .catch(ex => { $("fastfetch").textContent = problem(ex); });
}
setInterval(() => { if (!cockpit.hidden) loadFastfetch(); }, 30000);

// ---- Start: check at load (also in the background, preloaded at login),
// again every hour, and when admin access gets switched on in the top bar.
function start() {
    loadFastfetch();
    exclusive(checkAll);
    setupLoad();
    loadResources(true);
    loadHistory();
}
start();
setInterval(() => { if (!busy) start(); }, 3600 * 1000);

// "Limited access" button: Current "none" = limited, "init" = starting.
const superuser = cockpit.dbus(null, { bus: "internal" }).proxy("cockpit.Superuser", "/superuser");
let wasLimited = null;
superuser.addEventListener("changed", () => {
    if (superuser.Current === "init") return;
    const limited = superuser.Current === "none";
    if (wasLimited === true && !limited) start();
    wasLimited = limited;
});
