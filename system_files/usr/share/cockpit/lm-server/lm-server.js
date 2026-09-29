/* global cockpit */
"use strict";

let busy = false;
let lastError = null; // why the last run() failed (cockpit.spawn exception)
let configBase = null; // commit the editor text was loaded from (see below)
const buttons = () => document.querySelectorAll("button");

// Runs `lm-server <args>` as root and streams its output live into the log
// panel of the card the action belongs to. onData(chunk) may take over the
// output: it returns the part that still goes to the log.
function run(args, card, input, onData) {
    if (busy) return Promise.resolve(false);
    busy = true;
    lastError = null;
    const log = card.querySelector(".log");
    log.hidden = false;
    log.classList.remove("failed");
    log.textContent = "$ lm-server " + args.join(" ") + "\n";
    buttons().forEach(b => { b.disabled = true; });

    const proc = cockpit.spawn(["/usr/bin/lm-server", ...args], { superuser: "require", err: "out" });
    proc.stream(data => {
        if (onData) data = onData(data);
        if (!data) return;
        const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 4;
        log.textContent += data;
        if (atBottom) log.scrollTop = log.scrollHeight;
    });
    if (input !== undefined) proc.input(input);
    return proc
        .then(() => {
            log.textContent += "\n✔ done";
            return true;
        })
        .catch(ex => {
            lastError = ex;
            // Exit 3 (sync): applied, but some services were skipped -- see above.
            if (ex.exit_status === 3) {
                log.textContent += "\n⚠ done, some services skipped (see above)";
                return true;
            }
            if (ex.problem === "access-denied") {
                log.textContent += "\n✘ needs administrative access: turn it on with “Limited access” in Cockpit's top bar.";
                log.classList.add("failed");
                return false;
            }
            log.textContent += "\n✘ failed: " + (ex.message || ex);
            log.classList.add("failed");
            return false;
        })
        .finally(() => {
            log.scrollTop = log.scrollHeight;
            busy = false;
            buttons().forEach(b => { b.disabled = false; });
            // Nothing to save until a file was loaded.
            document.getElementById("config-save").disabled = configBase === null;
        });
}

const statusCard = document.querySelector('[data-run="status"]').closest(".card");
const refreshStatus = () => run(["status"], statusCard);

document.querySelectorAll("button[data-run]").forEach(button => {
    button.addEventListener("click", () => {
        if (button.dataset.confirm && !window.confirm(button.dataset.confirm)) return;
        const args = button.dataset.run.split(" ");
        run(args, button.closest(".card")).then(() => {
            if (["sync", "update", "prune-adhoc"].includes(args[0])) refreshStatus();
        });
    });
});

document.getElementById("setup").addEventListener("submit", event => {
    event.preventDefault();
    const form = event.target;
    const f = new FormData(form);
    // Empty fields keep the current setting (shown as the placeholder).
    const val = name => f.get(name) || form.elements[name].placeholder;
    const args = ["setup", "--repo", val("repo"), "--branch", f.get("branch"), "--token-stdin"];
    args.push("--config", val("config"));
    if (val("user")) args.push("--user", val("user"));
    run(args, form.closest(".card"), f.get("token") + "\n").then(() => refreshStatus()).then(setupLoad);
    form.elements.token.value = "";
});

// Current setup as the form's placeholders (`lm-server config source`).
function setupLoad() {
    const form = document.getElementById("setup");
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
        })
        .catch(() => { /* not set up yet, or no admin access: keep the defaults */ });
}

// ---- lm-server.toml editor
const configCard = document.getElementById("config");
const configText = document.getElementById("config-text");
const configSave = document.getElementById("config-save");

function configLoad() {
    const log = configCard.querySelector(".log");
    const opts = { superuser: "require", err: "message" };
    return Promise.all([
        cockpit.spawn(["/usr/bin/lm-server", "config", "rev"], opts),
        cockpit.spawn(["/usr/bin/lm-server", "config", "show"], opts),
    ])
        .then(([rev, text]) => {
            configBase = rev.trim();
            configText.value = text;
            configSave.disabled = false;
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

document.getElementById("config-load").addEventListener("click", configLoad);
configSave.addEventListener("click", () => {
    if (!window.confirm("Commit and push this lm-server.toml to GitHub, then apply it?")) return;
    const args = ["config", "save", "--base", configBase];
    // On failure the edit stays in the box, to fix and retry.
    run(args, configCard, configText.value.replace(/\r\n/g, "\n")).then(ok => {
        if (ok) refreshStatus().then(configLoad);
    });
});

// ---- System image (bootc): status, deployments, updates with a progress bar
const sysCard = document.getElementById("system");
const sysEl = id => document.getElementById("sys-" + id);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const mb = n => (n / 1e6).toFixed(1) + " MB";
let sysHost = null; // `bootc status --format=json`
let sysChecked = null; // when "Check for updates" last ran
let sysTimer = ""; // next automatic update

function ago(ts) {
    if (!ts) return "";
    const s = (Date.now() - new Date(ts)) / 1000;
    if (s < 90) return "just now";
    for (const [unit, len] of [["day", 86400], ["hour", 3600], ["minute", 60]]) {
        if (s >= len * 1.5 || unit === "minute") {
            const n = Math.round(s / len);
            return `${n} ${unit}${n === 1 ? "" : "s"} ago`;
        }
    }
}
const shortDigest = d => (d || "").replace(/^sha256:/, "").slice(0, 12);
const version = img => img?.version || shortDigest(img?.imageDigest);

function sysRender() {
    const st = sysHost?.status || {};
    const booted = st.booted?.image, staged = st.staged, rollback = st.rollback;
    const update = st.booted?.cachedUpdate;
    const pending = update && update.imageDigest !== booted?.imageDigest &&
        update.imageDigest !== staged?.image?.imageDigest ? update : null;

    // Status lines (like cockpit-ostree's Status card)
    const lines = [];
    if (staged && !staged.downloadOnly) {
        lines.push(`<li class="info">⬆ Update <strong>${esc(version(staged.image))}</strong> downloaded — it applies on the next reboot. <button data-sys="reboot">Reboot now</button></li>`);
    } else if (pending) {
        lines.push(`<li class="info">⬆ Update available: <strong>${esc(version(pending))}</strong> (built ${esc(ago(pending.timestamp))})</li>`);
    } else {
        lines.push(`<li class="ok">✔ System is up to date${sysChecked ? " (checked " + esc(ago(sysChecked)) + ")" : ""}</li>`);
    }
    if (st.rollbackQueued) {
        lines.push(`<li class="warn">↩ The next reboot goes back to <strong>${esc(version(rollback?.image))}</strong>. <button data-sys="reboot">Reboot now</button></li>`);
    }
    if (st.booted?.incompatible) lines.push(`<li class="warn">⚠ The running deployment has local package changes (incompatible with image updates).</li>`);
    lines.push(`<li class="muted">${esc(sysTimer)}</li>`);
    sysEl("status").innerHTML = lines.join("");

    // Image source (like cockpit-ostree's OSTree source card)
    const ref = sysHost?.spec?.image || booted?.image || {};
    const [name, tag] = (ref.image || "").split(/:(?=[^:/]+$)/);
    // bootc: "containerPolicy" | "insecure" | { ostreeRemote: "<name>" }
    const sig = typeof ref.signature === "string" ? ref.signature : Object.keys(ref.signature || {})[0];
    const SIGS = { containerPolicy: "checked (policy.json, cosign)", insecure: "not checked", ostreeRemote: "ostree remote" };
    sysEl("source").innerHTML = `
        <dt>Image</dt><dd><code>${esc(name)}</code></dd>
        <dt>Tag</dt><dd>${esc(tag || "latest")}</dd>
        <dt>Transport</dt><dd>${esc(ref.transport)}</dd>
        <dt>Signature</dt><dd>${esc(SIGS[sig] || sig || "default (policy.json)")}</dd>`;

    // Deployments table, newest first
    const rows = [];
    const row = (img, badge, cls, action) => rows.push(`<tr>
        <td><strong>${esc(version(img))}</strong></td>
        <td><span class="badge ${cls}">${badge}</span></td>
        <td title="${esc(img?.timestamp)}">${esc(ago(img?.timestamp))}</td>
        <td><code>${esc(shortDigest(img?.imageDigest))}</code></td>
        <td class="row-actions">${action || ""}</td></tr>`);
    if (pending) row(pending, "Available", "info", `<button data-sys="download">Download</button>`);
    if (staged) row(staged.image, staged.downloadOnly ? "Downloaded" : "Next boot", "info", `<button data-sys="reboot">Reboot now</button>`);
    if (booted) row(booted, "Current", "ok");
    if (rollback) {
        row(rollback.image, st.rollbackQueued ? "Next boot" : "Previous", st.rollbackQueued ? "warn" : "",
            st.rollbackQueued ? "" : `<button data-sys="rollback">Roll back</button>`);
    }
    sysEl("deployments").innerHTML = rows.join("") || `<tr><td colspan="5" class="muted">No bootc deployments found.</td></tr>`;
}

function sysLoad() {
    const opts = { superuser: "require", err: "message" };
    const timer = cockpit.spawn(["systemctl", "show", "lm-server-upgrade.timer", "--property=ActiveState,NextElapseUSecRealtime"], { err: "ignore" })
        .then(out => {
            const p = Object.fromEntries(out.trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
            sysTimer = p.ActiveState === "active" && p.NextElapseUSecRealtime
                ? "Automatic updates: on — next " + p.NextElapseUSecRealtime
                : "Automatic updates: off ([updates] system = \"manual\")";
        })
        .catch(() => { sysTimer = ""; });
    return Promise.all([cockpit.spawn(["bootc", "status", "--format=json"], opts), timer])
        .then(([out]) => {
            sysHost = JSON.parse(out);
            sysRender();
        })
        .catch(ex => {
            sysEl("status").innerHTML = ex.problem === "access-denied"
                ? `<li class="warn">🔒 Needs administrative access (“Limited access” in Cockpit's top bar).</li>`
                : `<li class="warn">✘ ${esc(ex.message || ex)}</li>`;
        });
}

// Progress: `lm-server upgrade --progress` prints bootc's JSON Lines events
// between its normal output; they drive the bar, everything else is logged.
const STAGES = { pulling: "Downloading", importing: "Importing", staging: "Staging" };
let sysPartial = "";
function sysProgress(chunk) {
    const lines = (sysPartial + chunk).split("\n");
    sysPartial = lines.pop();
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
            sysBar("Starting…", 0, "", "");
            continue;
        }
        const stage = STAGES[ev.task] || ev.description || ev.task;
        const unit = ev.task === "pulling" ? "Layer" : "Step";
        const steps = ev.stepsTotal ? `${unit} ${Math.min(ev.steps + 1, ev.stepsTotal)} of ${ev.stepsTotal}` : "";
        // A running discrete step says what it does ("Staging image", ...).
        const running = ev.type === "ProgressSteps" && (ev.subtasks || []).find(t => !t.completed)?.description;
        if (ev.type === "ProgressBytes" && ev.bytesTotal) {
            sysBar(stage, ev.bytes / ev.bytesTotal, `${mb(ev.bytes)} / ${mb(ev.bytesTotal)}`, steps);
        } else {
            sysBar(stage, ev.stepsTotal ? ev.steps / ev.stepsTotal : 0, "", [steps, running].filter(Boolean).join(" · "));
        }
    }
    return text;
}
function sysBar(stage, fraction, amount, detail) {
    const pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
    sysEl("progress").hidden = false;
    sysEl("stage").textContent = stage;
    sysEl("amount").textContent = amount ? `${amount} · ${pct}%` : `${pct}%`;
    sysEl("detail").textContent = detail;
    sysEl("fill").style.width = pct + "%";
    sysCard.querySelector(".bar").setAttribute("aria-valuenow", pct);
}

function sysUpgrade(apply) {
    if (busy) return;
    if (apply && !window.confirm("Download the new system image and reboot into it now?")) return;
    sysPartial = "";
    sysBar("Checking…", 0, "", "");
    const args = ["upgrade", "--progress", ...(apply ? ["--apply"] : [])];
    run(args, sysCard, undefined, sysProgress).then(ok => {
        // --apply reboots right after staging: the connection just drops.
        const rebooting = apply && (ok || ["disconnected", "terminated"].includes(lastError?.problem));
        if (rebooting) sysBar("Rebooting…", 1, "", "The server restarts into the new image; reload this page in a minute.");
        else if (ok) sysBar("Done", 1, "", "Downloaded — it applies on the next reboot.");
        else sysEl("progress").hidden = true;
        if (!rebooting) return sysLoad();
    });
}

sysEl("check").addEventListener("click", () => {
    if (busy) return;
    run(["upgrade", "--check"], sysCard).then(ok => {
        if (ok) sysChecked = new Date();
        return sysLoad();
    });
});
sysEl("download").addEventListener("click", () => sysUpgrade(false));
sysEl("apply").addEventListener("click", () => sysUpgrade(true));
// Buttons drawn by sysRender (table rows, status lines)
sysCard.parentElement.addEventListener("click", event => {
    const action = event.target.closest("button[data-sys]")?.dataset.sys;
    if (!action) return;
    if (action === "download") sysUpgrade(false);
    if (action === "rollback" && window.confirm("Boot the previous system image on the next reboot?")) {
        run(["rollback"], sysCard).then(sysLoad);
    }
    if (action === "reboot" && window.confirm("Reboot the server now?")) {
        cockpit.spawn(["systemctl", "reboot"], { superuser: "require", err: "message" }).catch(() => {});
        sysBar("Rebooting…", 1, "", "Reload this page in a minute.");
    }
});

// Status first, then the history of automatic runs.
async function autoRun() {
    setupLoad();
    sysLoad();
    for (const b of document.querySelectorAll("button[data-auto]")) {
        await run(b.dataset.run.split(" "), b.closest(".card"));
    }
}
autoRun();

// ---- Admin access switched on in Cockpit's top bar ("Limited access"
// button): load what failed before. Current: "none" = limited, "init" = starting.
const superuser = cockpit.dbus(null, { bus: "internal" }).proxy("cockpit.Superuser", "/superuser");
let wasLimited = null;
superuser.addEventListener("changed", () => {
    if (superuser.Current === "init") return;
    const limited = superuser.Current === "none";
    if (wasLimited === true && !limited) autoRun();
    wasLimited = limited;
});
