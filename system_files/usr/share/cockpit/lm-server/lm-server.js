/* global cockpit */
"use strict";

let busy = false;
let configBase = null; // commit the editor text was loaded from (see below)
const buttons = () => document.querySelectorAll("button");

// Runs `lm-server <args>` as root and streams its output live into the log
// panel of the card the action belongs to.
function run(args, card, input) {
    if (busy) return Promise.resolve(false);
    busy = true;
    const log = card.querySelector(".log");
    log.hidden = false;
    log.classList.remove("failed");
    log.textContent = "$ lm-server " + args.join(" ") + "\n";
    buttons().forEach(b => { b.disabled = true; });

    const proc = cockpit.spawn(["/usr/bin/lm-server", ...args], { superuser: "require", err: "out" });
    proc.stream(data => {
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

document.getElementById("to-updates").addEventListener("click", () => cockpit.jump("/updates"));

// Setup form placeholders, then the status.
async function autoRun() {
    setupLoad();
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
