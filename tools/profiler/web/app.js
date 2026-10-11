"use strict";
// Schema-driven editor: field types, enums, help text and limits come from data/schema.json at
// runtime, so a new schema field shows up here without touching this file. Only the layout
// (which fields sit in which section) is written out below.
let SCHEMA, GAMES = [], STALE = [], AI = null, CUR = null, GAME = null, DIRTY = false, ERRS = [], SECTION = "overview", validateTimer;
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const LONG = /^(description|notes|reason|problem|fix|store_details|patches|follow_up)$/;
const BASES = ["game", "install", "prefix_documents", "prefix_appdata", "prefix_localappdata", "prefix_public_documents", "prefix"];
const BASE_HELP = {
  game: "the folder the game's exe is in", install: "the game's install root",
  prefix_documents: "Documents in the Wine prefix", prefix_appdata: "AppData/Roaming in the prefix",
  prefix_localappdata: "AppData/Local in the prefix", prefix_public_documents: "Public Documents in the prefix",
  prefix: "the prefix itself (registry files)",
};
const LABELS = {
  id: "Store ID", id_source: "Where the ID came from", api: "Audio API", exe: "Executable", store_details: "Store details",
  extra_exe_folders: "Extra exe folders", companion_apps: "Companion apps", beta_branch: "Beta branch", fix_in_place: "Fix works in place",
  alsoft_ini: "alsoft.ini settings", only_if: "Only offer when…", follow_up: "Follow-up for the player", eax: "EAX",
  default_reverb: "Default reverb", "default-reverb": "Default reverb", versions: "EAX versions", tweaks: "Compatibility tweaks",
};
const SECTIONS = [
  ["overview", "Overview", ["name", "description", "released", "exe"]],
  ["stores", "Stores", ["stores"]],
  ["audio", "Audio & install", ["eax", "install"]],
  ["settings", "Game settings", ["game_config"]],
  ["notes", "Notes & sources", ["sources", "notes"]],
  ["capture", "Capture", []],
];
const human = (k) => LABELS[k] || (k.replace(/[_-]/g, " ").replace(/^./, (c) => c.toUpperCase()));

function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v;
    else if (k === "title") e.dataset.tip = v; // our tooltip, not the browser's slow plain one
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e[k] = v;
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : document.createTextNode(k));
  return e;
}
async function api(path, method = "GET", body) {
  const r = await fetch(path, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
function toast(msg, ms = 3500) { const t = $("#toast"); t.textContent = msg; t.style.display = "block"; clearTimeout(t._t); t._t = setTimeout(() => (t.style.display = "none"), ms); }
function resolve(s) { while (s && s.$ref) s = s.$ref.slice(2).split("/").reduce((o, k) => o[k], SCHEMA); return s; }
const isEmpty = (v) => v === undefined || v === "" || (Array.isArray(v) && !v.length) || (v && typeof v === "object" && !Array.isArray(v) && !Object.keys(v).length);
function prune(v) {
  if (Array.isArray(v)) return v.map(prune).filter((x) => !isEmpty(x));
  if (v && typeof v === "object") { const o = {}; for (const [k, x] of Object.entries(v)) { const p = prune(x); if (!isEmpty(p)) o[k] = p; } return o; }
  return v;
}

// ---------------------------------------------------------------- tooltips
// One floating tip for everything with data-tip (the ? icons and button hints): readable size and
// contrast, wraps, stays inside the window, shows on hover and on keyboard focus.
const TIP = () => $("#tip");
function showTip(target) {
  const t = TIP(), text = target.dataset.tip; if (!text) return;
  t.textContent = text; t.style.display = "block";
  const r = target.getBoundingClientRect(), w = t.offsetWidth, h = t.offsetHeight;
  let x = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), innerWidth - w - 8);
  let y = r.bottom + 8; if (y + h > innerHeight - 8) y = Math.max(8, r.top - h - 8);
  t.style.left = x + "px"; t.style.top = y + "px";
}
const hideTip = () => (TIP().style.display = "none");
document.addEventListener("mouseover", (e) => { const n = e.target.closest("[data-tip]"); n ? showTip(n) : hideTip(); });
document.addEventListener("focusin", (e) => { const n = e.target.closest("[data-tip]"); n && showTip(n); });
document.addEventListener("focusout", hideTip);
document.addEventListener("scroll", hideTip, true);
document.addEventListener("click", (e) => { const n = e.target.closest(".qm"); n ? showTip(n) : hideTip(); });
const helpIcon = (text) => text ? el("button", { type: "button", class: "qm", "aria-label": "What is this?", title: text }, "?") : null;

// ---------------------------------------------------------------- validation display
function sectionOfPath(p) {
  const top = p.split(/[/.[]/)[0];
  const s = SECTIONS.find(([, , keys]) => keys.includes(top));
  return s ? s[0] : "overview";
}
function changed() {
  DIRTY = true; drawHeadStatus();
  const g = prune(GAME);
  $("#preview").textContent = JSON.stringify(g, null, 2);
  clearTimeout(validateTimer);
  validateTimer = setTimeout(async () => showErrors((await api("/api/validate", "POST", g)).errors), 350);
}
function showErrors(errs) {
  ERRS = errs;
  const ul = $("#errors");
  ul.replaceChildren(...(errs.length ? errs.map((e) => {
    const i = e.indexOf(": "), path = i > 0 ? e.slice(0, i) : "", msg = i > 0 ? e.slice(i + 2) : e;
    return el("li", { onclick: () => path && setSection(sectionOfPath(path)) }, path ? el("code", {}, path) : null, msg);
  }) : [el("li", { class: "ok" }, "✓ No problems")]));
  drawNav();
}

// ---------------------------------------------------------------- form building
function field(label, control, { help, wide, extra, req } = {}) {
  const f = el("div", { class: "f" + (wide ? " wide" : "") });
  f.append(el("div", { class: "flabel" }, label, req ? el("span", { class: "req" }, "*") : null, helpIcon(help), el("span", { class: "grow" }), ...[].concat(extra || [])), control);
  return f;
}
function aiButton(task, ctx, apply) {
  if (!AI) return null;
  return el("button", { type: "button", class: "btn sm", title: "Draft this with AI. You can edit the result.", onclick: async (e) => {
    e.preventDefault(); const b = e.currentTarget; b.disabled = true; b.textContent = "Drafting…";
    try { apply(await api("/api/ai", "POST", { task, context: ctx() })); changed(); } catch (x) { toast("AI: " + x.message, 6000); }
    b.disabled = false; b.textContent = "✨ Draft";
  } }, "✨ Draft");
}
function chips(options, selected, onChange) {
  const sel = new Set(selected);
  return el("div", { class: "chips" }, options.map((o) => el("label", { class: "chip" },
    el("input", { type: "checkbox", checked: sel.has(o), onchange: (e) => { e.target.checked ? sel.add(o) : sel.delete(o); onChange(options.filter((x) => sel.has(x))); } }),
    el("span", {}, o))));
}
// replaceChildren writes the word "null" for a null argument, so anything that may be empty goes through here.
const fill = (node, ...kids) => node.replaceChildren(...kids.flat().filter((k) => k != null && k !== false));
function grid(children) { return el("div", { class: "grid" }, children); }

function node(schema, parent, key, path, label) {
  const s = resolve(schema) || {};
  const lab = label ?? human(key), help = s.description;
  const set = (v) => { if (isEmpty(v)) delete parent[key]; else parent[key] = v; changed(); };
  const cur = parent[key];
  const F = (control, opts = {}) => field(lab, control, { help, ...opts });

  if (/\.speakers$/.test(path)) {
    const opts = resolve(s.anyOf[0]).enum;
    return F(chips(opts, [].concat(cur ?? []), (a) => set(a.length === 1 ? a[0] : a)), { wide: true });
  }
  if (/\.stores$/.test(path) && s.type === "array") return F(chips(resolve(s.items).enum, cur || [], set));
  if (/\.locations$/.test(path)) return F(listEditor(parent, key, (v, upd) => {
    const [b, ...r] = (v || "game:").split(":");
    const base = el("select", { style: "flex:0 0 190px", onchange: () => upd(base.value + ":" + p.value) }, BASES.map((x) => el("option", { value: x, selected: x === b, title: BASE_HELP[x] }, x)));
    const p = el("input", { value: r.join(":"), placeholder: "folder/file.cfg", oninput: () => upd(base.value + ":" + p.value) });
    return [base, p];
  }, "game:", "Add a place to look"), { wide: true });
  if (/\.changes$/.test(path)) return F(changesEditor(parent, key), { wide: true });
  if (path === "sources") return F(listEditor(parent, key, (v, upd) => {
    const o = typeof v === "object" ? v : { title: "", url: v || "" };
    const t = el("input", { value: o.title, placeholder: "Title (optional)", style: "flex:0 0 38%", oninput: () => upd(t.value ? { title: t.value, url: u.value } : u.value) });
    const u = el("input", { value: o.url, placeholder: "https://…", oninput: () => upd(t.value ? { title: t.value, url: u.value } : u.value) });
    return [t, u];
  }, "", "Add a source"), { wide: true });

  if (s.enum) {
    const sel = el("select", { onchange: () => set(sel.value) }, [el("option", { value: "" }, s.default ? `Default (${s.default})` : "Not set"), ...s.enum.map((o) => el("option", { selected: o === cur }, o))]);
    return F(sel);
  }
  if (s.type === "boolean") return F(el("label", { class: "switch" }, el("input", { type: "checkbox", checked: !!cur, onchange: (e) => set(e.target.checked || undefined) }), el("span", { class: "muted" }, "Yes")));
  if (s.type === "integer") return F(el("input", { type: "number", value: cur ?? "", onchange: (e) => set(e.target.value === "" ? undefined : parseInt(e.target.value, 10)) }), { req: key === "id" });
  if (s.type === "string") {
    const long = LONG.test(key);
    const inp = el(long ? "textarea" : "input", { value: cur ?? "", maxLength: s.maxLength || 1e6, oninput: (e) => { set(e.target.value); count(); } });
    if (key === "released") inp.placeholder = "YYYY-MM-DD";
    if (key === "exe") inp.placeholder = "Game.exe";
    if (key === "name") inp.placeholder = "Game name as the store lists it";
    const counter = s.maxLength ? el("span", { class: "counter" }) : null;
    const count = () => { if (counter) { const n = inp.value.length; counter.textContent = `${n}/${s.maxLength}`; counter.classList.toggle("over", n > s.maxLength - 5); } };
    count();
    const extra = [counter];
    if (key === "description") extra.push(aiButton("description", () => ({ name: GAME.name, released: GAME.released }), (r) => { set(r.description); inp.value = r.description || ""; }));
    if (key === "notes") extra.push(aiButton("notes", () => ({ game: prune(GAME) }), (r) => { set(r.notes); inp.value = r.notes || ""; }));
    const f = F(inp, { extra, wide: long, req: key === "name" });
    f._input = inp;
    return f;
  }
  if (s.type === "array") {
    const it = resolve(s.items) || {};
    if (it.enum) return F(chips(it.enum, cur || [], set));
    if (it.type === "object") return F(cards(parent, key, it, path), { wide: true });
    return F(listEditor(parent, key, (v, upd) => [el("input", { value: v ?? "", placeholder: it.type === "integer" ? "Number" : "", oninput: (e) => upd(it.type === "integer" ? parseInt(e.target.value, 10) || undefined : e.target.value) })], it.type === "integer" ? undefined : "", "Add"), { wide: true });
  }
  if (s.type === "object" && s.properties) {
    parent[key] = parent[key] || {};
    const g = el("div", { class: "group" }, el("div", { class: "flabel" }, lab, helpIcon(help)),
      grid(Object.entries(s.properties).filter(([k]) => k !== "$schema").map(([k, sub]) => node(sub, parent[key], k, path ? path + "." + k : k))));
    return g;
  }
  return F(el("span", { class: "muted" }, "(unsupported)"));
}
function listEditor(parent, key, rowFn, blank, addLabel = "Add") {
  const box = el("div");
  const arr = () => (parent[key] = parent[key] || []);
  const draw = () => {
    box.replaceChildren(...arr().map((v, i) => el("div", { class: "row" }, ...rowFn(v, (nv) => { arr()[i] = nv; changed(); }),
      el("button", { type: "button", class: "icon", title: "Remove", onclick: () => { arr().splice(i, 1); changed(); draw(); } }, "✕"))),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn sm", onclick: () => { arr().push(blank === undefined ? undefined : blank); draw(); } }, "+ " + addLabel)));
  };
  draw(); return box;
}
function settingSummaryCount(o) { return Object.values(o.changes || {}).reduce((n, f) => n + Object.values(f).reduce((m, v) => m + (v && typeof v === "object" ? Object.keys(v).length : 1), 0), 0); }
function cards(parent, key, itemSchema, path) {
  const box = el("div");
  const arr = () => (parent[key] = parent[key] || []);
  const draw = () => {
    const list = arr();
    box.replaceChildren(...(list.length ? list.map((o, i) => {
      const stitle = el("span", { class: "stitle" }), badge = el("span", { class: "pill" }), cond = el("span", { class: "pill" });
      const refresh = () => {
        stitle.textContent = o.title || "Untitled setting"; stitle.classList.toggle("untitled", !o.title);
        const n = settingSummaryCount(o); badge.textContent = `${n} change${n === 1 ? "" : "s"}`;
        const c = o.only_if ? [].concat(o.only_if.stores || [], o.only_if.speakers || []).join(", ") : ""; cond.textContent = c ? "only if " + c : ""; cond.hidden = !c;
      };
      const fields = Object.entries(itemSchema.properties).map(([k, sub]) => {
        const n = node(sub, o, k, path + "[]." + k);
        if (k === "title") { n.classList.add("wide"); n.querySelector("input").addEventListener("input", refresh); n.querySelector(".grow").after(aiButton("setting", () => ({ game: GAME.name, changes: o.changes, kind: key }), (r) => { o.title = (r.title || "").slice(0, 60); o.reason = r.reason; draw(); })); }
        return n;
      });
      const d = el("details", { class: "setcard", open: list.length <= 2 || !o.title },
        el("summary", {}, stitle, cond, badge, el("button", { type: "button", class: "icon", title: "Delete this setting", onclick: (e) => { e.preventDefault(); if (confirm(`Delete “${o.title || "this setting"}”?`)) { arr().splice(i, 1); changed(); draw(); } } }, "✕")),
        el("div", { class: "setbody" }, grid(fields)));
      d.addEventListener("input", refresh); d.addEventListener("change", refresh); refresh();
      return d;
    }) : [el("div", { class: "empty-note" }, "None yet. Capture the game to draft some, or add one by hand.")]),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn", onclick: () => { arr().push({ title: "", reason: "", changes: {} }); changed(); draw(); } }, "+ Add a setting")));
  };
  draw(); return box;
}
function fileCards(parent, key, valueSchema, path) {
  const box = el("div");
  const m = () => (parent[key] = parent[key] || {});
  const draw = () => {
    const names = Object.keys(m());
    box.replaceChildren(names.length ? el("div", { class: "filegrid" }, names.map((name) => {
      const val = m()[name];
      return el("div", { class: "filecard" },
        el("header", {}, el("h4", {}, name), el("button", { type: "button", class: "icon", title: "Remove this file (settings that use it will need fixing)", onclick: () => { delete m()[name]; changed(); draw(); } }, "✕")),
        grid(Object.entries(resolve(valueSchema).properties).map(([k, sub]) => node(sub, val, k, path + "." + k))));
    })) : el("div", { class: "empty-note" }, "No config files yet."),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn", onclick: () => {
        const n = prompt("Config file name, e.g. game.ini, Quake4Config.cfg, Profile000.gdb or system.reg:"); if (!n) return;
        m()[n] = { format: n.endsWith(".reg") ? "wine_reg" : n.endsWith(".gdb") ? "gadb" : "ini", locations: [n.endsWith(".reg") ? "prefix:" + n : "game:" + n] }; changed(); draw();
      } }, "+ Add a config file")));
  };
  draw(); return box;
}
// changes: file -> [section ->] key -> value, edited as a flat table.
function changesEditor(setting, key) {
  const box = el("div");
  const files = () => (GAME.game_config && GAME.game_config.files) || {};
  const sectioned = (f) => ["ini", "wine_reg"].includes((files()[f] || {}).format);
  const rows = () => {
    const out = [];
    for (const [f, a] of Object.entries(setting[key] || {})) for (const [k, v] of Object.entries(a)) {
      if (sectioned(f) && v && typeof v === "object") for (const [k2, v2] of Object.entries(v)) out.push([f, k, k2, v2]); else out.push([f, "", k, v]);
    }
    return out;
  };
  let R = rows();
  const commit = () => {
    const o = {};
    for (const [f, s, k, v] of R) { if (!f || !k) continue; const t = (o[f] = o[f] || {}); if (s) (t[s] = t[s] || {})[k] = v; else t[k] = v; }
    setting[key] = o; changed();
  };
  const val = (v, upd) => {
    const mode = v === null ? "null" : v === true ? "true" : v === false ? "false" : "text";
    const sel = el("select", { style: "flex:0 0 84px", title: "text: a value. true / false: turn a flag on or off. null: delete the key.", onchange: () => { sel.value === "text" ? upd("") : upd(sel.value === "null" ? null : sel.value === "true"); draw(); } }, ["text", "true", "false", "null"].map((x) => el("option", { selected: x === mode }, x)));
    const inp = el("input", { value: typeof v === "string" ? v : "", placeholder: mode === "text" ? "value" : "", disabled: mode !== "text", oninput: () => upd(inp.value) });
    return el("div", { class: "row" }, sel, inp);
  };
  const draw = () => {
    const fnames = Object.keys(files());
    if (!fnames.length) { box.replaceChildren(el("div", { class: "empty-note" }, "Add a config file under “Config files” first.")); return; }
    box.replaceChildren(el("div", { class: "tblwrap" }, el("table", {}, el("tr", {}, ["File", "Section / registry key", "Key", "Value", ""].map((h) => el("th", {}, h))),
      ...R.map((r, i) => el("tr", {},
        el("td", {}, (() => { const s = el("select", { onchange: () => { r[0] = s.value; commit(); draw(); } }, [el("option", { value: "" }, "Choose…"), ...fnames.map((n) => el("option", { selected: n === r[0] }, n))]); return s; })()),
        el("td", {}, el("input", { value: r[1], disabled: !sectioned(r[0]), placeholder: sectioned(r[0]) ? "section" : "n/a", oninput: (e) => { r[1] = e.target.value; commit(); } })),
        el("td", {}, el("input", { value: r[2], placeholder: "key", oninput: (e) => { r[2] = e.target.value; commit(); } })),
        el("td", {}, val(r[3], (v) => { r[3] = v; commit(); })),
        el("td", {}, el("button", { type: "button", class: "icon", title: "Remove this change", onclick: () => { R.splice(i, 1); commit(); draw(); } }, "✕")))))),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn sm", onclick: () => { R.push([fnames[0] || "", "", "", ""]); draw(); } }, "+ Add a change")));
  };
  draw(); return box;
}

// ---------------------------------------------------------------- sections
const P = () => SCHEMA.properties;
const card = (title, help, ...body) => el("section", { class: "card" }, el("header", {}, el("h3", {}, title), helpIcon(help)), ...body);
function blockHead(title, help, count, ...actions) {
  return el("div", { class: "blockhead" }, el("h2", {}, title), helpIcon(help), count != null ? el("span", { class: "pill" }, count) : null, el("span", { class: "sp" }), ...actions);
}
function paneOverview() {
  return [card("Basics", "The name, a one-line description and the details used to recognise the game's install.",
    grid([node(P().name, GAME, "name", "name"), node(P().released, GAME, "released", "released"), node(P().exe, GAME, "exe", "exe"), node(P().description, GAME, "description", "description")]))];
}
function paneStores() {
  GAME.stores = GAME.stores || {};
  const sp = P().stores.properties, defs = resolve(sp.steam).properties;
  const only = { beta_branch: "steam", companion_apps: "steam", extra_exe_folders: "gog" };
  return ["steam", "gog"].map((st) => {
    const name = st === "steam" ? "Steam" : "GOG";
    if (!GAME.stores[st]) return el("section", { class: "card" }, el("header", {}, el("h3", {}, name)),
      el("div", { class: "empty-note" }, `Not sold on ${name}. `, el("button", { type: "button", class: "btn sm", onclick: () => { GAME.stores[st] = {}; renderPane(); } }, `+ Add ${name} entry`)));
    const fields = Object.entries(defs).filter(([k]) => !only[k] || only[k] === st).map(([k, sub]) => node(sub, GAME.stores[st], k, `stores.${st}.${k}`));
    return el("section", { class: "card" }, el("header", {}, el("h3", {}, name), helpIcon(resolve(sp[st]).description || "A store's ID and notes for this game."), el("span", { class: "sp" }),
      el("button", { type: "button", class: "danger-link", onclick: () => { if (confirm(`Remove the ${name} entry?`)) { delete GAME.stores[st]; changed(); renderPane(); } } }, `Remove ${name}`)), grid(fields));
  });
}
function paneAudio() {
  GAME.eax = GAME.eax || {}; GAME.install = GAME.install || {};
  const ep = P().eax.properties, ip = P().install.properties;
  return [
    card("EAX", P().eax.description, grid(Object.entries(ep).map(([k, sub]) => node(sub, GAME.eax, k, `eax.${k}`)))),
    card("Install options", P().install.description, grid(Object.entries(ip).map(([k, sub]) => node(sub, GAME.install, k, `install.${k}`)))),
  ];
}
function paneSettings() {
  GAME.game_config = GAME.game_config || {};
  const gp = P().game_config.properties, gc = GAME.game_config, n = (a) => (a || []).length;
  return [
    blockHead("Config files", "The game's own config files that settings can change, and where to find each one.", Object.keys(gc.files || {}).length),
    fileCards(gc, "files", gp.files.additionalProperties, "game_config.files"),
    blockHead("Audio settings", gp.audio_settings.description, n(gc.audio_settings)),
    cards(gc, "audio_settings", resolve(gp.audio_settings.items), "game_config.audio_settings"),
    blockHead("Optional settings", gp.optional_settings.description, n(gc.optional_settings)),
    cards(gc, "optional_settings", resolve(gp.optional_settings.items), "game_config.optional_settings"),
  ];
}
function paneNotes() {
  return [card("Sources", P().sources.description, node(P().sources, GAME, "sources", "sources")),
    card("Notes", P().notes.description, node(P().notes, GAME, "notes", "notes"))];
}
function renderPane() {
  const pane = $("#pane");
  if (SECTION === "capture") { pane.replaceChildren(el("div", { id: "capturebox" })); renderCapture(); return; }
  const build = { overview: paneOverview, stores: paneStores, audio: paneAudio, settings: paneSettings, notes: paneNotes }[SECTION];
  pane.replaceChildren(...build());
}
function drawNav() {
  const nav = $("#snav"); if (!nav) return;
  nav.replaceChildren(...SECTIONS.map(([id, label]) => {
    const n = id === "capture" ? 0 : ERRS.filter((e) => sectionOfPath(e.split(": ")[0]) === id).length;
    return el("button", { type: "button", class: id === SECTION ? "on" : "", onclick: () => setSection(id) }, label, n ? el("span", { class: "nb", title: `${n} problem${n === 1 ? "" : "s"} in this section` }, n) : null);
  }));
}
function setSection(id) { SECTION = id; drawNav(); renderPane(); $("#main").scrollTop = 0; }
function showTab(t) { if (t === "capture") setSection("capture"); else if (SECTION === "capture") setSection("overview"); }

// ---------------------------------------------------------------- header
function drawHeadStatus() {
  const d = $("#dirtybadge"); if (d) d.hidden = !DIRTY;
}
function renderEdit() {
  $("#empty").hidden = true; $("#game").hidden = false;
  const folderLabel = { tested: "Tested", untested: "Untested", drafts: "Draft" }[CUR.folder];
  $("#ghead").replaceChildren(el("div", { class: "gtop" },
    el("div", { class: "gtitle" }, el("h1", {}, GAME.name || CUR.id),
      el("div", { class: "gmeta" }, el("span", { class: "badge " + CUR.folder, title: { tested: "Checked against a real install.", untested: "Shipped, but not checked on a real install yet.", drafts: "Incomplete or doubtful; never shipped." }[CUR.folder] }, folderLabel),
        el("code", {}, `${CUR.folder}/${CUR.id}.json`), el("span", { id: "buildbadge", class: "badge" }), el("span", { id: "dirtybadge", class: "badge dirty", hidden: !DIRTY }, "● Unsaved changes"))),
    el("div", { class: "gactions" },
      el("button", { type: "button", class: "btn", onclick: captureCurrent, title: "Capture this game's settings: snapshot, install the fix, you change the options in-game, then it works out what changed." }, "Capture this game"),
      AI ? el("button", { type: "button", class: "btn", onclick: research, title: "Fill in release date, executable, description and EAX details from what the AI knows. Check them against a source." }, "✨ Research") : null,
      el("select", { id: "promo", title: "Move this entry to another folder (tested, untested or draft)", onchange: promote }, [el("option", { value: "" }, "Move to…"), ...["drafts", "untested", "tested"].filter((x) => x !== CUR.folder).map((x) => el("option", {}, x))]),
      el("button", { type: "button", class: "btn primary", id: "savebtn", title: "Save (Ctrl+S): shows what will change in the file first", onclick: saveClicked }, "Save"))));
  drawNav(); renderPane(); drawBuildBadge();
}
function drawBuildBadge() {
  const el_ = $("#buildbadge"), g = CUR && GAMES.find((x) => x.id === CUR.id && x.folder === CUR.folder);
  if (!el_ || !g || !g.build || g.build.state === "draft") { if (el_) el_.hidden = true; return; }
  el_.hidden = false; el_.className = "badge build-" + g.build.state; el_.textContent = BUILD_TEXT[g.build.state][0]; el_.dataset.tip = buildTip(g.build);
}
let SKIP_PREVIEW = false;
function dialog(...kids) {
  const dlg = el("dialog", { class: "dlg" }, ...kids);
  document.body.append(dlg); dlg.onclose = () => dlg.remove(); dlg.showModal(); return dlg;
}
async function saveClicked() {
  if (!GAME) return;
  if (SKIP_PREVIEW) return save();
  const r = await api(`/api/preview/${CUR.folder}/${CUR.id}`, "POST", prune(GAME));
  if (r.same) { DIRTY = false; drawHeadStatus(); return toast("Nothing to save: the file already matches"); }
  const skip = el("input", { type: "checkbox" });
  const lines = r.diff.split("\n").map((l) => el("div", { class: l.startsWith("+") && !l.startsWith("+++") ? "add" : l.startsWith("-") && !l.startsWith("---") ? "del" : "ctx" }, l || " "));
  const dlg = dialog(el("h3", {}, r.new_file ? "Create this file?" : "Write these changes?"), el("div", { class: "diff" }, lines),
    el("div", { class: "btns" }, el("label", { class: "switch muted" }, skip, "Don't ask again this session"), el("span", { class: "sp" }),
      el("button", { type: "button", onclick: () => dlg.close() }, "Cancel"),
      el("button", { type: "button", class: "primary", onclick: async () => { SKIP_PREVIEW = skip.checked; dlg.close(); await save(); } }, "Write file")));
}
async function save() {
  const r = await api(`/api/game/${CUR.folder}/${CUR.id}`, "PUT", prune(GAME));
  GAME = JSON.parse(r.json); delete GAME["$schema"]; DIRTY = false; renderEdit(); showErrors(r.errors);
  $("#preview").textContent = JSON.stringify(prune(GAME), null, 2);
  toast(r.errors.length ? `Saved, with ${r.errors.length} problem${r.errors.length === 1 ? "" : "s"} to fix` : "Saved ✓"); loadList();
}
async function promote(e) {
  const to = e.target.value; if (!to) return;
  if (DIRTY) await save();
  await api("/api/promote", "POST", { id: CUR.id, from: CUR.folder, to }); CUR.folder = to; renderEdit(); loadList(); toast(`Moved to ${to}`);
}
async function research() {
  const r = await api("/api/ai", "POST", { task: "research", context: { name: GAME.name } });
  if (r.released) GAME.released = r.released; if (r.exe) GAME.exe = r.exe; if (r.description) GAME.description = r.description;
  GAME.eax = GAME.eax || {}; if (r.api) GAME.eax.api = r.api; if (r.eax_versions) GAME.eax.versions = r.eax_versions;
  renderEdit(); changed(); toast(r.uncertain && r.uncertain.length ? "Please check: " + r.uncertain.join(", ") : "Filled in. Verify against a source before saving.", 6000);
}

// ---------------------------------------------------------------- sidebar
// How a saved game file stands against the built game-database.json.
const BUILD_TEXT = {
  current: ["In database", "The saved file matches game-database.json."],
  changed: ["Changed since last build", "The saved file differs from game-database.json. Press “Rebuild database” to update it."],
  new: ["Not in database yet", "This game isn't in game-database.json yet. Press “Rebuild database” to add it."],
  draft: ["Draft", "Drafts are never put in game-database.json."],
};
const buildTip = (b) => BUILD_TEXT[b.state][1] + (b.fields && b.fields.length ? ` Differs in: ${b.fields.join(", ")}.` : "");
function drawRebuild() {
  const behind = GAMES.filter((g) => g.build && (g.build.state === "changed" || g.build.state === "new"));
  const n = behind.length + STALE.length, b = $("#rebuild");
  b.textContent = n ? `Rebuild database (${n})` : "Rebuild database";
  b.classList.toggle("warn", n > 0);
  b.dataset.tip = n ? `game-database.json is behind: ${behind.length} changed or new game${behind.length === 1 ? "" : "s"}${STALE.length ? `, ${STALE.length} removed` : ""}. ${behind.slice(0, 6).map((g) => g.name).join(", ")}${behind.length > 6 ? "…" : ""}` : "game-database.json is up to date. Rebuild regenerates it from the per-game files.";
}
async function loadList() {
  const j = await api("/api/games"); GAMES = j.games; STALE = j.stale || []; AI = j.ai;
  $("#aistate").textContent = AI ? `AI: ${AI === "api" ? "API key" : "claude CLI"}` : "AI off";
  $("#aistate").dataset.tip = AI ? "AI drafting is available (✨ buttons)." : "Set ANTHROPIC_API_KEY or log in to the claude command to turn on the ✨ drafting buttons.";
  drawList(); drawRebuild();
  if (GAME && CUR) drawBuildBadge();
}
const OPEN = { untested: true, tested: true, drafts: false };
function drawList() {
  const q = $("#filter").value.toLowerCase(), box = $("#list"); box.replaceChildren();
  for (const folder of ["untested", "tested", "drafts"]) {
    const g = GAMES.filter((x) => x.folder === folder && (x.name + x.id).toLowerCase().includes(q));
    if (!g.length) continue;
    const d = el("details", { open: q ? true : OPEN[folder], ontoggle: (e) => { if (!q) OPEN[folder] = e.target.open; } },
      el("summary", {}, el("span", { class: "dot " + folder }), folder, el("span", { class: "cnt" }, g.length)),
      ...g.map((x) => el("div", { class: "item" + (CUR && CUR.id === x.id ? " on" : ""), onclick: () => openGame(x.folder, x.id) }, el("span", { class: "nm" }, x.name), x.build && (x.build.state === "changed" || x.build.state === "new") ? el("span", { class: "tag warn", title: buildTip(x.build) }, x.build.state === "new" ? "not built" : "changed") : null,
        x.has_config ? el("span", { class: "tag", title: "Has game settings" }, "cfg") : null)));
    box.append(d);
  }
  if (!box.children.length) box.append(el("p", { class: "muted" }, "No games match."));
}
async function openGame(folder, id) {
  if (DIRTY && !confirm("Discard unsaved changes?")) return;
  const j = await api(`/api/game/${folder}/${id}`);
  CUR = { folder, id }; GAME = j.game; DIRTY = false; if (SECTION === "capture") SECTION = "overview";
  drawList(); showErrors(j.errors); renderEdit(); $("#main").scrollTop = 0;
  $("#preview").textContent = JSON.stringify(prune(GAME), null, 2);
}
async function addByName() {
  const name = prompt("Game name:"); if (!name) return;
  const id = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  try { await api("/api/new", "POST", { id, name }); await loadList(); openGame("untested", id); } catch (x) { toast(x.message, 6000); }
}
$("#filter").oninput = drawList;
$("#addinstalled").onclick = addInstalled;
$("#rebuild").onclick = async () => { const r = await api("/api/rebuild", "POST"); toast(r.ok ? "game-database.json rebuilt ✓" : r.message, 8000); await loadList(); };
$("#cleanupbtn").onclick = () => openCleanup(GAME);
$("#jsontoggle").onclick = () => { const l = $("#layout"); const hidden = getComputedStyle($("#rail")).display === "none"; l.classList.toggle("norail", !hidden); l.classList.toggle("rail-on", hidden); if (hidden) $("#rail").style.display = "block"; else $("#rail").style.display = ""; };
document.addEventListener("keydown", (e) => { if ((e.ctrlKey || e.metaKey) && e.key === "s") { e.preventDefault(); saveClicked(); } });
window.addEventListener("beforeunload", (e) => { if (DIRTY) { e.preventDefault(); e.returnValue = ""; } });

// ---------------------------------------------------------------- clean up
const CSTATE = { installed: "Installed", orphan: "Left behind", removed: "Removed", clean: "Prefix only", gone: "Prefix only" };
const mb = (n) => (n >= 1e9 ? (n / 1e9).toFixed(1) + " GB" : Math.round(n / 1e6) + " MB");
async function openCleanup(game) {
  let data = (await api("/api/cleanup")), q = "", view = "installs";
  const mine = (e) => game && game.stores && game.stores[e.store] && game.stores[e.store].id === e.id;
  const search = el("input", { placeholder: "Search…" });
  const sel = el("select", {}, [["installs", "Installed or left behind by the script"], ["all", "Everything, including prefixes only"]].map(([v, t]) => el("option", { value: v }, t)));
  const list = el("div", { class: "list" }), note = el("div", { class: "muted", style: "min-height:20px" });
  const dlg = dialog(el("h3", {}, "Clean up"), el("p", { class: "muted", style: "margin:0" }, "Remove what the script installed, or delete a game's Wine prefix, so you can test from scratch. Nothing is changed until you confirm."),
    el("div", { class: "ctools" }, search, sel), list, note, el("div", { class: "btns" }, el("button", { type: "button", onclick: () => dlg.close() }, "Close")));
  dlg.classList.add("wide");
  const draw = () => {
    const rows = data.entries.filter((e) => (view === "all" || e.state === "installed" || e.state === "orphan") && (e.name + " " + (e.dir || "")).toLowerCase().includes(q))
      .sort((a, b) => (mine(b) ? 1 : 0) - (mine(a) ? 1 : 0));
    list.replaceChildren(...(rows.length ? rows.map((e) => {
      const acts = [];
      if (e.can_remove_install) acts.push(el("button", { type: "button", class: "btn sm", onclick: () => confirmClean(e, "remove"), title: e.state === "installed" ? "Run the script's uninstall for this game." : "The game is gone from your library, so the files the script left are removed directly." }, "Remove install"));
      if (e.prefix_exists) acts.push(el("button", { type: "button", class: "btn sm", disabled: !e.can_reset, onclick: () => confirmClean(e, "prefix"), title: e.can_reset ? "Delete this game's Wine prefix. The launcher makes a new one on the next launch." : (e.reset_blocked || "Can't be reset.") }, "Delete prefix"));
      if (acts.length) acts.push(el("button", { type: "button", class: "btn sm primary", disabled: e.prefix_exists && !e.can_reset && !e.can_remove_install, onclick: () => confirmClean(e, "fresh"), title: "Remove the install, delete the prefix and reset the capture session, ready for a fresh test." }, "Start fresh"));
      const bits = [];
      if (e.files.length) bits.push(`${e.files_present} of ${e.files.length} files left` + (e.backups ? `, ${e.backups} backup${e.backups === 1 ? "" : "s"} to put back` : ""));
      bits.push(e.prefix_exists ? "has a Wine prefix" : "no Wine prefix");
      return el("div", { class: "crow" + (mine(e) ? " mine" : "") },
        el("div", { class: "info" }, el("div", { class: "nm" }, e.name, el("span", { class: "badge " + e.state }, CSTATE[e.state]), el("span", { class: "tag" }, e.store), mine(e) ? el("span", { class: "badge dirty" }, "open game") : null),
          el("div", { class: "sub" }, bits.join(" · ")), e.dir ? el("div", { class: "sub" }, (e.dir || "").replace(/^\/home\/[^/]+/, "~")) : null),
        el("div", { class: "acts" }, acts));
    }) : [el("p", { class: "muted", style: "padding:14px" }, "Nothing to clean up here.")]));
    note.textContent = data.launchers.steam || data.launchers.heroic ? `${data.launchers.steam ? "Steam" : "Heroic"} is running. Removing an install then leaves that launcher's launch-option override in place.` : "";
  };
  const reload = async () => { data = await api("/api/cleanup"); draw(); };
  search.oninput = () => { q = search.value.toLowerCase(); draw(); };
  sel.onchange = () => { view = sel.value; draw(); };
  draw(); search.focus();

  async function confirmClean(e, action) {
    const plan = await api("/api/cleanup/plan", "POST", { eid: e.eid, action });
    if (plan.blocked) return toast(plan.blocked, 8000);
    const body = plan.steps.map((s) => el("div", {}, el("h4", {}, s.title), (s.warnings || []).map((w) => el("div", { class: "warn" }, w)), el("ul", {}, s.items.map((i) => el("li", { class: i.startsWith("SKIP") ? "muted" : "" }, i)))));
    const go = el("button", { type: "button", class: "danger" }, { remove: "Remove install", prefix: "Delete prefix", fresh: "Start fresh" }[action]);
    const c = dialog(el("h3", {}, plan.title), el("div", { class: "plan" }, body, plan.also_session ? el("p", { class: "muted" }, "The capture session for this game is reset too.") : null),
      el("div", { class: "btns" }, el("button", { type: "button", onclick: () => c.close() }, "Cancel"), go));
    go.onclick = async () => {
      go.disabled = true; go.textContent = "Working…";
      await api("/api/cleanup/run", "POST", { eid: e.eid, action });
      let st; do { await new Promise((r) => setTimeout(r, 700)); st = await api("/api/cleanup/status"); } while (st.state === "running");
      c.close();
      if (st.state === "error") toast("Problem: " + st.message, 12000); else toast(st.message.split("\n").join(" · "), 9000);
      if (action === "fresh" || action === "prefix") { if (SESS && SESS.lib && String(SESS.lib.id) === String(e.id)) { SESS = null; clearInterval(POLL); } }
      await reload(); if (SECTION === "capture") drawCapture();
    };
  }
}

// ---------------------------------------------------------------- capture
let LIB = [], SESS = null, POLL = null;
const STEPS = [
  ["pre", "Snapshot the config files", "Records every config file and the registry before anything changes. Launches the game once first if it has never run."],
  ["installed", "Install the fix (no prompts)", "Runs the installer with canned answers and no game settings, then records the files again."],
  ["baseline", "Baseline run (optional)", "Start the game and quit without changing anything. Options the game rewrites on its own are then ignored."],
  ["audio", "Audio run: your turn", "The game starts. Switch ON the EAX / hardware 3D audio options, then quit the game."],
  ["optional", "Optional run (optional)", "Same again for quality-of-life options such as resolution or textures. These become optional settings."],
];
const SPEAKERS = [
  ["headphones", "Headphones"], ["matrix", "Pro Logic (matrix)"], ["quad", "4.0 (quad)"],
  ["surround51", "5.1"], ["surround61", "6.1"], ["surround71", "7.1"], ["stereo", "Stereo"],
];
const runName = (label) => (label.startsWith("spk-") ? `${(SPEAKERS.find(([k]) => k === label.slice(4)) || [0, label])[1]} speaker run` : `${label} run`);
async function ensureLib() { if (!LIB.length) LIB = (await api("/api/library")).games; return LIB; }
const libMatch = (g) => LIB.find((l) => g && g.stores && g.stores[l.store] && g.stores[l.store].id === l.id);
async function renderCapture() { await ensureLib(); drawCapture(); }
function drawCapture() {
  const box = $("#capturebox"); if (!box) return;
  const mine = libMatch(GAME);
  if (SESS && SESS.lib !== mine) { SESS = null; clearInterval(POLL); }
  fill(box, 
    !GAME ? el("div", { class: "empty-note" }, "Open a game on the left, or add an installed one.")
      : !mine ? el("div", { class: "empty-note" }, `${GAME.name} isn't installed in Steam or Heroic (matched by store ID), so it can't be captured here.`)
      : !SESS ? el("div", { class: "empty-note" }, "Press “Capture this game” at the top of the page to start. Your earlier capture steps for this game, if any, come back when you do.") : null,
    el("div", { id: "steps" }));
  if (SESS) drawSteps();
}
async function captureCurrent() {
  if (!GAME) return toast("Open a game first");
  await ensureLib(); const g = libMatch(GAME);
  if (!g) return toast("Not installed in Steam or Heroic (matched by store ID)", 6000);
  if (DIRTY) await save();
  setSection("capture"); await startCapture(g);
}
async function startCapture(g) {
  SESS = { lib: g, sid: `${g.store}-${g.id}`, state: { steps: {} }, job: { state: "idle" } };
  await refreshSession();
  if (!SESS.state.exe) {
    const exe = (GAME && GAME.exe) || prompt(`Executable to watch for (e.g. Game.exe) for ${g.name}:`) || "";
    await api(`/api/session/${SESS.sid}/exe`, "POST", { exe });
    if (exe && GAME && !GAME.exe) { GAME.exe = exe; changed(); }
    await refreshSession();
  }
  startPoll(); drawCapture();
}
// Installed games with no profile yet (matched by store ID against every entry, drafts included).
async function addInstalled() {
  await ensureLib();
  const have = (l) => GAMES.some((x) => x[l.store] === l.id);
  const todo = LIB.filter((l) => !have(l)).sort((a, b) => a.name.localeCompare(b.name));
  const q = el("input", { placeholder: "Search…" }), list = el("div", { class: "list" });
  const dlg = dialog(el("h3", {}, `Add a game (${todo.length} installed without a profile)`), q, list, el("div", { class: "btns" }, el("button", { type: "button", class: "danger-link", title: "For a game that isn't installed here, or isn't in the list", onclick: () => { dlg.close(); addByName(); } }, "Not in the list? Add it by name…"), el("span", { class: "sp" }), el("button", { type: "button", onclick: () => dlg.close() }, "Cancel")));
  const draw = () => list.replaceChildren(...(todo.filter((l) => l.name.toLowerCase().includes(q.value.toLowerCase())).map((l) =>
    el("div", { class: "item", onclick: async () => {
      dlg.close();
      try {
        const slug = l.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || String(l.id);
        const r = await api("/api/new", "POST", { id: slug, name: l.name, store: l.store, store_id: l.id });
        await loadList(); await openGame("untested", r.id); await captureCurrent();
      } catch (x) { toast(x.message, 6000); }
    } }, el("span", { class: "nm" }, l.name), el("span", { class: "tag" }, l.store))).concat(todo.length ? [] : [el("p", { class: "muted", style: "padding:12px" }, "Every installed game already has a profile.")])));
  q.oninput = draw; draw(); q.focus();
}
async function refreshSession() { const j = await api(`/api/session/${SESS.sid}`); SESS.state = j.session; SESS.job = j.job; }
function startPoll() { clearInterval(POLL); POLL = setInterval(async () => { if (!SESS) return; const was = SESS.job.state; await refreshSession(); if (was === "running" || SESS.job.state === "running") drawSteps(); }, 2000); }
function drawSteps() {
  const box = $("#steps"); if (!box) return; const st = SESS.state.steps, run = SESS.job.state === "running";
  const jobText = SESS.job.state === "idle" ? "" : `${SESS.job.state === "running" ? "Working: " : SESS.job.state === "error" ? "Problem: " : "Done: "}${SESS.job.message}`;
  fill(box, 
    el("p", { class: "muted" }, `Watching for ${SESS.state.exe || "an unknown exe"}. The only manual part is the audio run (and the optional run): change the options in the game, then quit it.`),
    el("div", { class: "steps" }, ...STEPS.map(([k, t, d], i) => el("div", { class: "step" + (st[k] ? " done" : "") },
      el("div", { class: "num" }, st[k] ? "✓" : i + 1), el("div", { class: "body" }, el("b", {}, t), el("span", {}, d)),
      st[k] ? el("span", { class: "meta" }, `${st[k].files} files`) : null,
      el("button", { type: "button", class: st[k] ? "" : "primary", disabled: run, onclick: async () => { try { await api(`/api/session/${SESS.sid}/action`, "POST", { action: k }); await refreshSession(); drawSteps(); } catch (x) { toast(x.message, 8000); } } }, st[k] ? "Redo" : "Run")))),
    el("div", { class: "blockhead" }, el("h3", {}, "Speaker layouts (optional)"), helpIcon("Do this for each speaker setup the game's own audio options offer. Choose that layout in the game, quit, and the tool records what changed against the audio run. Skip any the game doesn't have. Layouts that change the same values are merged for you.")),
    el("div", { class: "steps" }, ...SPEAKERS.map(([k, name]) => { const key = "spk-" + k;
      return el("div", { class: "step" + (st[key] ? " done" : "") }, el("div", { class: "num" }, st[key] ? "✓" : "♪"),
        el("div", { class: "body" }, el("b", {}, name), el("span", {}, "Set this in the game's audio options, then quit.")),
        st[key] ? el("span", { class: "meta" }, `${st[key].files} files`) : null,
        el("button", { type: "button", disabled: run || !st.audio, title: st.audio ? "" : "Do the audio run first", onclick: async () => { try { await api(`/api/session/${SESS.sid}/action`, "POST", { action: key }); await refreshSession(); drawSteps(); } catch (x) { toast(x.message, 8000); } } }, st[key] ? "Redo" : "Run")); })),
    jobText ? el("div", { class: "status " + SESS.job.state }, jobText) : null,
    el("div", { class: "barrow" }, el("button", { type: "button", class: "primary", disabled: run || !st.audio, title: "Compare the snapshots and draft the game's settings. You can untick anything before merging.", onclick: makeDraft }, "Build settings from the captures"),
      el("span", { class: "sp" }), el("button", { type: "button", class: "danger-link", onclick: async () => { if (confirm("Delete this capture session and its snapshots?")) { await api(`/api/session/${SESS.sid}/reset`, "POST"); await refreshSession(); drawSteps(); } } }, "Reset session")),
    el("div", { id: "draftbox" }));
}
const DROP = new Set();
async function makeDraft() {
  DROP.clear();
  const box = $("#draftbox"); box.textContent = "Working…";
  const d = await api(`/api/session/${SESS.sid}/draft`, "POST", { ai: true });
  for (const list of Object.values(d.diffs)) for (const f of list) for (const c of f.changes) if (c.suspect_reason) DROP.add([f.file, f.format, c.section, c.key].join("\0"));
  fill(box, el("div", { class: "blockhead" }, el("h2", {}, "Captured changes"), helpIcon("Tick the changes to keep. Ones that look like the game's own bookkeeping start unticked, with the reason shown.")),
    ...Object.entries(d.diffs).flatMap(([label, list]) => [el("p", {}, el("b", {}, runName(label))), ...(list.length ? list.map((f) => el("details", { class: "cfile", open: true }, el("summary", {}, `${f.file}  →  ${f.location || "(outside known folders)"}  [${f.format}]`),
      el("div", { class: "tblwrap" }, el("table", {}, el("tr", {}, ["Keep", "Section", "Key", "Was", "Now", ""].map((h) => el("th", {}, h))), ...f.changes.map((c) => el("tr", {}, el("td", {}, el("input", { type: "checkbox", checked: c.expressible && !c.suspect_reason, disabled: !c.expressible, title: "Include when merging", onchange: (e) => { const k = [f.file, f.format, c.section, c.key].join("\0"); e.target.checked ? DROP.delete(k) : DROP.add(k); } })), el("td", {}, c.section), el("td", {}, c.key), el("td", { class: "muted" }, String(c.old)), el("td", {}, String(c.new)), el("td", { class: c.expressible ? "muted" : "bad" }, c.expressible ? (c.suspect_reason ? "left out: " + c.suspect_reason : "") : "not allowed by schema"))))))) : [el("p", { class: "muted" }, "No changes.")])]),
    ...(d.skipped.length ? [el("div", { class: "blockhead" }, el("h2", {}, "Needs a human")), el("ul", {}, d.skipped.map((x) => el("li", {}, x)))] : []),
    d.ai && d.ai !== "ok" ? el("p", { class: "bad" }, d.ai) : null,
    suggestionsBlock(d.suggestions),
    el("div", { class: "barrow" }, el("button", { type: "button", class: "primary", onclick: () => merge(d.game_config, d.diffs) }, "Merge into the entry and review")));
}
function suggestionsBlock(sg) {
  if (!sg) return null;
  const items = [];
  for (const [sec, keys] of Object.entries(sg.alsoft_ini || {})) for (const [k, v] of Object.entries(keys))
    items.push([`alsoft.ini  [${sec}] ${k} = ${v}`, sg.reasons[`alsoft_ini.${sec}.${k}`], () => { GAME.install = GAME.install || {}; GAME.install.alsoft_ini = GAME.install.alsoft_ini || {}; (GAME.install.alsoft_ini[sec] = GAME.install.alsoft_ini[sec] || {})[k] = v; }]);
  if (sg.eax && sg.eax.api) items.push([`EAX API: ${sg.eax.api}`, sg.reasons["eax.api"], () => { GAME.eax = GAME.eax || {}; GAME.eax.api = sg.eax.api; }]);
  if (sg.eax && sg.eax.versions) items.push([`EAX versions: ${sg.eax.versions.join(", ")}`, sg.reasons["eax.versions"], () => { GAME.eax = GAME.eax || {}; GAME.eax.versions = sg.eax.versions; }]);
  if (!items.length) return el("p", { class: "muted" }, "The AI had no extra suggestions.");
  return el("div", {}, el("div", { class: "blockhead" }, el("h2", {}, "AI suggestions"), helpIcon("Check these against a source before applying. Nothing is applied for you.")), ...items.map(([t, r, apply]) => el("div", { class: "row" },
    el("span", { style: "flex:1" }, t, r ? el("div", { class: "muted" }, r) : null), el("button", { type: "button", class: "btn sm", onclick: (e) => { apply(); changed(); e.currentTarget.disabled = true; e.currentTarget.textContent = "Applied"; toast("Applied. See the Audio & install tab."); } }, "Apply"))));
}
// Removes the changes the user unticked (DROP holds file/format/section/key).
function applyDrops(gc) {
  const out = JSON.parse(JSON.stringify(gc));
  for (const kind of ["audio_settings", "optional_settings"]) {
    if (!out[kind]) continue;
    out[kind] = out[kind].filter((st) => {
      for (const [file, body] of Object.entries(st.changes)) {
        const fmt = (out.files[file] || {}).format;
        const sectioned = ["ini", "wine_reg"].includes(fmt);
        for (const [a, v] of Object.entries(body)) {
          if (sectioned) { for (const k of Object.keys(v)) if (DROP.has([file, fmt, a, k].join("\0"))) delete v[k]; if (!Object.keys(v).length) delete body[a]; }
          else if (DROP.has([file, fmt, "", a].join("\0"))) delete body[a];
        }
        if (!Object.keys(body).length) delete st.changes[file];
      }
      return Object.keys(st.changes).length;
    });
    if (!out[kind].length) delete out[kind];
  }
  const used = new Set(["audio_settings", "optional_settings"].flatMap((k) => (out[k] || []).flatMap((st) => Object.keys(st.changes))));
  for (const f of Object.keys(out.files)) if (!used.has(f)) delete out.files[f];
  return out;
}
function merge(gc0) {
  const gc = applyDrops(gc0);
  if (!GAME) return toast("Open or create the game's entry first");
  GAME.game_config = GAME.game_config || { files: {} };
  GAME.game_config.files = Object.assign(GAME.game_config.files || {}, gc.files);
  for (const k of ["audio_settings", "optional_settings"]) if (gc[k]) GAME.game_config[k] = (GAME.game_config[k] || []).concat(gc[k]);
  changed(); setSection("settings"); toast("Merged. Check each title and reason, then Save.", 6000);
}

window.addEventListener("error", (e) => toast("JS error: " + e.message, 20000));
window.addEventListener("unhandledrejection", (e) => toast("Error: " + (e.reason && e.reason.message || e.reason), 20000));
(async () => {
  SCHEMA = await api("/api/schema"); await loadList(); showErrors([]);
  const q = new URLSearchParams(location.search), o = q.get("open");
  if (o) await openGame(...o.split("/"));
  if (q.get("section")) setSection(q.get("section"));
  if (q.get("startcapture")) await captureCurrent();
  if (q.get("addsetting")) { GAME.game_config.audio_settings.push({ title: "", reason: "", changes: {} }); renderPane(); }
  if (q.get("adddlg")) await addInstalled();
  if (q.get("cleanup")) await openCleanup(GAME);
  if (q.get("tipdemo")) showTip($$(".qm")[+q.get("tipdemo") - 1]);
  if (q.get("rail") === "0") $("#layout").classList.add("norail");
})();
