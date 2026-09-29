// "Updates" card on Cockpit's Overview page. Cockpit has no way for a package
// to add a card there, so build_files/10-cockpit.sh adds this script to the
// Overview's index.html (cockpit-system). It reads the status the Updates page
// publishes (page_status of "updates", in sessionStorage -- that page is
// preloaded at login and checks in the background), shows it next to the
// Health card, and its buttons jump to the Updates page, which does the work
// and shows the progress. If anything here doesn't match (a newer Cockpit),
// the card just doesn't appear; the one-line status in the Health card stays.
(function () {
    "use strict";
    const cockpit = window.cockpit;
    if (!cockpit) return;

    const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    const ICONS = { ok: "✔", info: "⬆", warn: "⚠", busy: "…" };
    const ROWS = [["system", "System image"], ["containers", "Containers"], ["config", "Config"]];

    function status() {
        try {
            const all = JSON.parse(sessionStorage.getItem("cockpit:page_status") || "{}");
            return all?.[cockpit.transport.host]?.updates || null;
        } catch (_) {
            return null;
        }
    }

    function build(gallery) {
        // Same classes as the stock cards (PatternFly version independent).
        const ref = gallery.querySelector(".system-usage") || gallery.querySelector(".system-health");
        const cls = (sel, fallback) => ref?.querySelector(sel)?.className || fallback;
        const card = document.createElement("article");
        card.id = "lms-updates-card";
        card.className = (ref ? ref.className.replace(/\bsystem-(usage|health)\b/, "") : "pf-v6-c-card") + " lms-updates-card";
        card.innerHTML = `
            <div class="${cls("[class$='c-card__title']", "pf-v6-c-card__title")}">
                <h2 class="${cls("[class$='c-card__title-text']", "pf-v6-c-card__title-text")}">Updates</h2>
            </div>
            <div class="${cls("[class$='c-card__body']", "pf-v6-c-card__body")}">
                <table class="${cls("table", "pf-v6-c-table pf-m-grid-md pf-m-compact")}"><tbody></tbody></table>
                <p class="lms-summary"></p>
            </div>
            <div class="${cls("[class$='c-card__footer']", "pf-v6-c-card__footer")} lms-footer">
                <button type="button" class="pf-v6-c-button pf-m-primary pf-m-small" data-lms="all"><span class="pf-v6-c-button__text">Update all</span></button>
                <a href="#" class="pf-v6-c-button pf-m-link pf-m-inline" data-lms="details"><span class="pf-v6-c-button__text">Show details</span></a>
            </div>`;
        card.addEventListener("click", ev => {
            const action = ev.target.closest("[data-lms]")?.dataset.lms;
            if (!action) return;
            ev.preventDefault();
            if (action === "details") return cockpit.jump("/updates#/details");
            if (!window.confirm("Apply the config from GitHub, update the containers (services with a new image restart) and download the new system image?")) return;
            // The Updates page runs it (and shows the progress).
            cockpit.jump("/updates#/run-all");
        });
        return card;
    }

    function render(card) {
        const st = status();
        const parts = st?.details?.parts || {};
        const row = ([key, label]) => {
            const p = parts[key];
            const cell = p
                ? `<span class="lms-state lms-${esc(p.state)}">${ICONS[p.state] || ""} ${esc(p.text)}</span>`
                : `<span class="lms-state">—</span>`;
            return `<tr><th scope="row">${esc(label)}</th><td>${cell}</td></tr>`;
        };
        card.querySelector("tbody").innerHTML = ROWS.map(row).join("");
        card.querySelector(".lms-summary").textContent = st?.title ||
            "Not checked yet: needs administrative access (“Limited access” in the top bar).";
    }

    let card = null;
    function place() {
        const gallery = document.querySelector(".ct-system-overview");
        if (!gallery) return;
        if (!card) card = build(gallery);
        const health = gallery.querySelector(":scope > .system-health");
        if (card.parentNode !== gallery) {
            gallery.insertBefore(card, health ? health.nextSibling : null);
            document.documentElement.classList.add("lms-updates-card-on");
            render(card);
        }
    }

    cockpit.transport.wait(() => {
        // React renders the Overview later (and may re-render it): keep the card in.
        new MutationObserver(place).observe(document.body, { childList: true, subtree: true });
        place();
        window.addEventListener("storage", ev => {
            if (ev.key === "cockpit:page_status" && card) render(card);
        });
    });
})();
