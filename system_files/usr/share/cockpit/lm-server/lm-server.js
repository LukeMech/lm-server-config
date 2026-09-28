/* global cockpit */
"use strict";

let busy = false;
const buttons = () => document.querySelectorAll("button");

// Runs `lm-server <args>` as root and streams its output live into the log
// panel of the card the action belongs to.
function run(args, card, input) {
    if (busy) return Promise.resolve();
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
        .then(() => { log.textContent += "\n✔ done"; })
        .catch(ex => {
            log.textContent += "\n✘ failed: " + (ex.message || ex);
            log.classList.add("failed");
        })
        .finally(() => {
            log.scrollTop = log.scrollHeight;
            busy = false;
            buttons().forEach(b => { b.disabled = false; });
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
    const args = ["setup", "--repo", f.get("repo"), "--branch", f.get("branch"), "--token-stdin"];
    if (f.get("subdir")) args.push("--subdir", f.get("subdir"));
    if (f.get("user")) args.push("--user", f.get("user"));
    run(args, form.closest(".card"), f.get("token") + "\n").then(refreshStatus);
    form.elements.token.value = "";
});

// Status first, then the history of automatic runs.
(async () => {
    for (const b of document.querySelectorAll("button[data-auto]")) {
        await run(b.dataset.run.split(" "), b.closest(".card"));
    }
})();
