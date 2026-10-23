"use strict";
// Schema-driven editor: field types, enums, help text and limits come from data/schema.json at
// runtime, so a new schema field shows up here without touching this file. Only the layout
// (which fields sit in which section) is written out below.
let SCHEMA, GAMES = [], STALE = [], AI = null, AIF = {}, CUR = null, GAME = null, DIRTY = false, SAVED = {}, ERRS = [], SECTION = "overview", validateTimer, CHOSEN_STORE = null;
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const LONG = /^(description|notes|reason|problem|fix|store_details|patches|follow_up)$/;
const BASES = ["game_exe", "game_root", "prefix_documents", "prefix_appdata", "prefix_localappdata", "prefix_public_documents", "prefix"];
const BASE_HELP = {
  game_exe: "the folder the game's .exe is in", game_root: "the game's top-level install folder",
  prefix_documents: "Documents in the Wine prefix", prefix_appdata: "AppData/Roaming in the prefix",
  prefix_localappdata: "AppData/Local in the prefix", prefix_public_documents: "Public Documents in the prefix",
  prefix: "the prefix itself (registry files)",
};
const LABELS = {
  id: "Store ID", id_source: "Where the ID came from", api: "Audio API", exe: "Executable", store_details: "Store details",
  extra_exe_folders: "Extra exe folders", companion_apps: "Companion apps", beta_branch: "Beta branch", fix_in_place: "Fix works in place",
  alsoft_ini: "alsoft.ini settings", only_if: "Only offer when…", follow_up: "Follow-up for the player", tested: "Verified", alsoft_tested: "alsoft.ini values verified", eax: "EAX",
  default_reverb: "Default reverb", "default-reverb": "Default reverb", versions: "EAX versions", tweaks: "Compatibility tweaks",
};
const SECTIONS = [
  ["overview", "Overview", ["name", "description", "released", "exe", "sources", "notes"]],
  ["stores", "Stores", ["stores"]],
  ["audio", "Audio & install", ["eax", "install"]],
  ["settings", "Game settings", ["game_config"]],
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
// A popover is drawn in the top layer, the same layer as an open dialog, so it can't end up behind one.
// Hiding then showing again puts it above a dialog that was opened after it was last shown.
function popUp(node) { if (node.matches(":popover-open")) node.hidePopover(); node.showPopover(); }
function popDown(node) { if (node.matches(":popover-open")) node.hidePopover(); }
function toast(msg, ms = 3500) { const t = $("#toast"); t.textContent = msg; popUp(t); clearTimeout(t._t); t._t = setTimeout(() => popDown(t), ms); }
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
  t.replaceChildren(...text.split("\n").map((line) => el("p", {}, line))); popUp(t);
  const r = target.getBoundingClientRect(), w = t.offsetWidth, h = t.offsetHeight;
  let x = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), innerWidth - w - 8);
  let y = r.bottom + 8; if (y + h > innerHeight - 8) y = Math.max(8, r.top - h - 8);
  t.style.left = x + "px"; t.style.top = y + "px";
}
const hideTip = () => popDown(TIP());
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
// "game_config/audio_settings/5" + "'reason' is a required property" -> game_config.audio_settings[5].reason
function problemPath(path, msg) {
  let p = path.split("/").filter((s) => s !== "(root)").map((s) => (/^\d+$/.test(s) ? `[${s}]` : "." + s)).join("").replace(/^\./, "");
  const m = msg.match(/^'(.+)' is a required property$/);
  return m ? (p ? p + "." : "") + m[1] : p;
}
function findByPath(p) {
  while (p) {
    const hit = [...document.querySelectorAll("[data-path]")].find((n) => n.dataset.path === p);
    if (hit) return hit;
    const q = p.replace(/(\[\d+\]|\.[^.\[]+)$/, "");
    if (q === p) break;
    p = q;
  }
  return null;
}
// Switches to the right tab, opens every collapsed card around the field, scrolls to it and flashes it.
function goToProblem(path, msg) {
  setSection(sectionOfPath(path));
  const target = findByPath(problemPath(path, msg));
  if (!target) return;
  for (let n = target; n; n = n.parentElement) if (n.tagName === "DETAILS") n.open = true;
  target.scrollIntoView({ block: "center", behavior: "smooth" });
  target.classList.remove("flash"); void target.offsetWidth; target.classList.add("flash");
  const input = target.querySelector("input:not([type=checkbox]), textarea, select");
  if (input && target.tagName !== "DETAILS") setTimeout(() => input.focus({ preventScroll: true }), 350);
}
// Finds {parent, key} for a path like game_config.audio_settings[2].reason. File names in a path hold dots
// (game_config.files.options.ini.format), so keys are matched against the object, not split on ".".
function pathRef(o, p) {
  let parent = null, key = null;
  p = p.replace(/^\./, "");
  while (p) {
    if (o == null || typeof o !== "object") return null;
    const idx = p.match(/^\[(\d+)\]/);
    let k, rest;
    if (idx) { k = +idx[1]; rest = p.slice(idx[0].length); }
    else {
      k = Object.keys(o).filter((k) => p === k || p.startsWith(k + ".") || p.startsWith(k + "[")).sort((x, y) => y.length - x.length)[0] ?? p.match(/^[^.\[]+/)[0];
      rest = p.slice(k.length);
    }
    parent = o; key = k; o = o[k]; p = rest.replace(/^\./, "");
  }
  return { parent, key };
}
const pathAt = (o, p) => { const r = p.replace(/^\./, "") ? pathRef(o, p) : null; return r ? r.parent[r.key] : (p ? undefined : o); };
// Puts a field back to its saved value (or removes it when it wasn't saved), keeping the scroll position.
function revertPath(p) {
  const r = pathRef(GAME, p); if (!r) return;
  const was = pathAt(SAVED, p);
  if (was === undefined) { if (Array.isArray(r.parent)) r.parent.splice(r.key, 1); else delete r.parent[r.key]; }
  else r.parent[r.key] = JSON.parse(JSON.stringify(was));
  changed(); const y = $("#main").scrollTop; renderPane(); $("#main").scrollTop = y;
}
async function revertAll() {
  if (!DIRTY || !(await askConfirm("Throw away all unsaved changes to this game?", "Revert", true))) return;
  GAME = JSON.parse(JSON.stringify(SAVED)); DIRTY = false;
  renderEdit(); $("#preview").textContent = JSON.stringify(SAVED, null, 2);
  showErrors((await api("/api/validate", "POST", SAVED)).errors);
}
// Marks each field whose value differs from the last saved (or opened) copy. A path like
// game_config.audio_settings[2].reason is looked up in both; lists and tables compare as a whole.
function markUnsaved() {
  const now = prune(GAME);
  const at = pathAt;
  const sig = JSON.stringify;
  const sectioned = (f) => ["ini", "gas_cfg", "wine_reg"].includes((((GAME.game_config || {}).files || {})[f] || {}).format);
  $$("[data-path]").forEach((f) => {
    const was = at(SAVED, f.dataset.path);
    f.classList.toggle("unsaved", sig(at(now, f.dataset.path)) !== sig(was));
    if (f.tagName === "DETAILS") { f.classList.toggle("revertable", f.classList.contains("unsaved") && was !== undefined); return; }
    // Controls made of several items (chips, ticks, list rows, the changes table) mark just the items that differ.
    const items = [...f.querySelectorAll(".chip, .chkrow, :scope > div > .row, tr")].filter((x) => x.tagName !== "TR" || x._row);
    f.classList.toggle("granular", items.length > 0);
    const old = [], saved = [].concat(was ?? []);
    if (f.querySelector("tr")) for (const [file, a] of Object.entries(was || {})) for (const [k, v] of Object.entries(a)) {
      if (sectioned(file) && v && typeof v === "object") for (const [k2, v2] of Object.entries(v)) old.push([file, k, k2, v2]); else old.push([file, "", k, v]);
    }
    for (const x of items) {
      let diff;
      if (x._row) {
        // Pair with the saved row of the same file and key, else the one in the same place, and mark only the cells that differ.
        const i = [...x.parentNode.querySelectorAll("tr")].filter((t) => t._row).indexOf(x);
        const m = old.find((o) => sig(o.slice(0, 3)) === sig(x._row.slice(0, 3))) || old[i];
        [...x.children].forEach((td, c) => {
          const d = c < 4 && (!m || sig(m[c]) !== sig(x._row[c]));
          if (c !== 3) return td.classList.toggle("chg", d);
          // Value cell: the type select and the text box mark separately.
          const kind = (v) => (typeof v === "string" ? "text" : String(v)), [sel, txt] = td.querySelectorAll("select, input");
          sel.classList.toggle("chg", !!d && (!m || kind(m[3]) !== kind(x._row[3])));
          txt.classList.toggle("chg", !!d && kind(x._row[3]) === "text" && (!m || m[3] !== x._row[3]));
        });
        continue;
      }
      else if (x.matches(".chip, .chkrow")) diff = x.querySelector("input").checked !== saved.includes(x.querySelector("span, code").textContent);
      else {
        // A list row's own boxes: a place is "base" + "path", a source is "title" + "address".
        const sv = Array.isArray(was) ? was[x._i] : undefined, p = f.dataset.path;
        const parts = /\.locations$/.test(p) ? (sv == null ? [] : [sv.split(":")[0], sv.split(":").slice(1).join(":")])
          : p === "sources" ? [sv && sv.title || "", sv && (sv.url ?? sv) || ""] : [sv];
        x.querySelectorAll("input, select").forEach((c, n) => c.classList.toggle("chg", sv === undefined || c.value !== String(parts[n] ?? "")));
        continue;
      }
      x.classList.toggle("chg", diff);
    }
  });
}
function changed() {
  const g = prune(GAME);
  DIRTY = JSON.stringify(g) !== JSON.stringify(SAVED); drawHeadStatus();
  markUnsaved();
  $("#preview").textContent = JSON.stringify(g, null, 2);
  clearTimeout(validateTimer);
  validateTimer = setTimeout(async () => showErrors((await api("/api/validate", "POST", g)).errors), 350);
}
function showErrors(errs) {
  ERRS = errs;
  const ul = $("#errors");
  ul.replaceChildren(...(errs.length ? errs.map((e) => {
    const i = e.indexOf(": "), path = i > 0 ? e.slice(0, i) : "", msg = i > 0 ? e.slice(i + 2) : e;
    return el("li", { title: "Go to the field with this problem", onclick: () => path && goToProblem(path, msg) }, path ? el("code", {}, path) : null, msg);
  }) : [el("li", { class: "ok" }, "✓ No problems")]));
  drawNav(); drawRailTab(); markErrors();
}
// Puts each problem on the field it belongs to (red outline and the message under it), so it shows even with
// the side bar closed. The side bar list still has them all.
function markErrors() {
  $$(".f.has-err").forEach((f) => { f.classList.remove("has-err"); f.querySelector(":scope>.errmsg")?.remove(); f.querySelector("[aria-invalid]")?.removeAttribute("aria-invalid"); });
  for (const e of ERRS) {
    const i = e.indexOf(": "), path = i > 0 ? e.slice(0, i) : "", msg = i > 0 ? e.slice(i + 2) : e;
    const hit = path && [...document.querySelectorAll("[data-path]")].find((n) => n.dataset.path === problemPath(path, msg));
    if (!hit || !hit.classList.contains("f")) continue;
    hit.classList.add("has-err");
    hit.querySelector("input:not([type=checkbox]), textarea, select")?.setAttribute("aria-invalid", "true");
    if (!hit.querySelector(":scope>.errmsg")) hit.append(el("div", { class: "errmsg" }, msg));
  }
}

// ---------------------------------------------------------------- form building
function field(label, control, { help, wide, extra, req } = {}) {
  const f = el("div", { class: "f" + (wide ? " wide" : "") });
  f.append(el("div", { class: "flabel" }, label, req ? el("span", { class: "req" }, "*") : null, helpIcon(help), el("span", { class: "grow" }), ...[].concat(extra || []), el("button", { type: "button", class: "icon rv", title: "Undo this change", "aria-label": "Undo this change", onclick: () => revertPath(f.dataset.path) }, "↺")), control);
  return f;
}
function aiButton(task, ctx, apply) {
  if (!AI || !AIF[task]) return null;
  return el("button", { type: "button", class: "btn sm", title: "Ask the AI to fill this in. You can edit what it writes.", onclick: async (e) => {
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
// One tick per row, for a short list whose names are long.
const checklist = (options, selected, onChange) => {
  const sel = new Set(selected);
  return el("div", { class: "checklist" }, options.map((o) => el("label", { class: "chkrow" },
    el("input", { type: "checkbox", checked: sel.has(o), onchange: (e) => { e.target.checked ? sel.add(o) : sel.delete(o); onChange(options.filter((x) => sel.has(x))); } }), el("code", {}, o))));
};
// The choices are OpenAL Soft's own lists (its alsoft.ini comments); the schema leaves the values free text, so one outside them stays selectable.
const ALSOFT_CHOICES = {
  boost: ["0", "3", "6", "9", "12"], sources: ["256", "512", "1024"], frequency: ["22050", "44100", "48000", "96000"],
  resampler: ["point", "linear", "spline", "gaussian", "bsinc12", "fast_bsinc12", "bsinc24", "fast_bsinc24"],
  "default-reverb": ["Generic", "PaddedCell", "Room", "Bathroom", "Livingroom", "Stoneroom", "Auditorium", "ConcertHall", "Cave", "Arena", "Hangar",
    "CarpetedHallway", "Hallway", "StoneCorridor", "Alley", "Forest", "City", "Mountains", "Quarry", "Plain", "ParkingLot", "SewerPipe", "Underwater", "Drugged", "Dizzy", "Psychotic"],
};
function choiceSelect(options, cur, set) {
  const all = cur && !options.includes(cur) ? [...options, cur] : options;
  const sel = el("select", { onchange: () => set(sel.value) }, [el("option", { value: "" }, "Not set"), ...all.map((o) => el("option", { selected: o === cur }, o))]);
  return sel;
}
// replaceChildren writes the word "null" for a null argument, so anything that may be empty goes through here.
const fill = (node, ...kids) => node.replaceChildren(...kids.flat().filter((k) => k != null && k !== false));
function grid(children) { return el("div", { class: "grid" }, children); }

// Every field carries its place in the entry (data-path, e.g. game_config.audio_settings[2].reason) so a
// problem in the list can be taken to it.
function node(schema, parent, key, path, label) {
  const e = fieldNode(schema, parent, key, path, label);
  if (e && e.dataset && path) e.dataset.path = path;
  return e;
}
function fieldNode(schema, parent, key, path, label) {
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
    const [b, ...r] = (v || "game_exe:").split(":");
    // Options can't show a tooltip, so the select itself explains the base it's showing.
    const base = el("select", { style: "flex:0 0 190px", title: BASE_HELP[b] || "", onchange: () => { base.dataset.tip = BASE_HELP[base.value] || ""; upd(base.value + ":" + p.value); } }, BASES.map((x) => el("option", { value: x, selected: x === b }, x)));
    const p = el("input", { value: r.join(":"), placeholder: "folder/file.cfg", oninput: () => upd(base.value + ":" + p.value) });
    return [base, p];
  }, "game_exe:", "Add a place to look"), { wide: true });
  if (/\.changes$/.test(path)) return F(changesEditor(parent, key), { wide: true });
  if (path === "sources") return F(listEditor(parent, key, (v, upd) => {
    const o = typeof v === "object" ? v : { title: "", url: v || "" };
    const t = el("input", { value: o.title, placeholder: "Title (optional)", "aria-label": "Source title", style: "flex:0 1 30%", oninput: () => upd(t.value ? { title: t.value, url: u.value } : u.value) });
    const checkUrl = () => u.classList.toggle("invalid", !!u.value && !/^https?:\/\/\S+$/.test(u.value));
    const u = el("input", { value: o.url, placeholder: "https://…", "aria-label": "Source address", style: "flex:1 1 60%", oninput: () => { checkUrl(); upd(t.value ? { title: t.value, url: u.value } : u.value); } });
    checkUrl();
    return [t, u];
  }, "", "Add a source"), { wide: true });

  if (s.enum) {
    const sel = el("select", { onchange: () => set(sel.value) }, [el("option", { value: "" }, s.default ? `Default (${s.default})` : "Not set"), ...s.enum.map((o) => el("option", { selected: o === cur }, o))]);
    return F(sel);
  }
  if (s.type === "boolean") return F(el("label", { class: "switch" }, el("input", { type: "checkbox", checked: !!cur, onchange: (e) => set(e.target.checked || undefined) }), el("span", { class: "muted" }, "Yes")));
  if (s.type === "integer") return F(el("input", { type: "number", value: cur ?? "", onchange: (e) => set(e.target.value === "" ? undefined : parseInt(e.target.value, 10)) }), { req: key === "id" });
  if (ALSOFT_CHOICES[key] && /\.alsoft_ini\./.test(path)) return F(choiceSelect(ALSOFT_CHOICES[key], cur, set));
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
    if (key === "exe") {
      inp.addEventListener("input", () => syncSessionExe(inp.value.trim()));
      extra.push(...exeBrowse((name) => { inp.value = name; set(name); syncSessionExe(name); }));
    }
    if (key === "description") extra.push(aiButton("description", () => ({ name: GAME.name, released: GAME.released }), (r) => { set(r.description); inp.value = r.description || ""; }));
    if (key === "notes") extra.push(aiButton("notes", () => ({ game: prune(GAME) }), (r) => { set(r.notes); inp.value = r.notes || ""; }));
    const f = F(inp, { extra, wide: long, req: key === "name" });
    f._input = inp;
    return f;
  }
  if (s.type === "array") {
    const it = resolve(s.items) || {};
    if (it.enum) return F(key === "tweaks" ? checklist(it.enum, cur || [], set) : chips(it.enum, cur || [], set), key === "tweaks" ? { wide: true } : {});
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
    box.replaceChildren(...arr().map((v, i) => Object.assign(el("div", { class: "row" }, ...rowFn(v, (nv) => { arr()[i] = nv; changed(); }),
      el("button", { type: "button", class: "icon", title: "Remove", onclick: () => { arr().splice(i, 1); changed(); draw(); } }, "✕")), { _i: i, _v: () => arr()[i] })),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn sm", onclick: () => { arr().push(blank === undefined ? undefined : blank); draw(); } }, "+ " + addLabel)));
  };
  draw(); return box;
}
const SET_OPEN = new WeakMap();
// A setting's fields in two columns: the text on the left, when it applies and what it changes on the right
// for the short ones; the changes table gets the whole width underneath.
function setBody(fields) {
  const by = (k) => fields.find((f) => f.dataset.path.endsWith("." + k));
  const left = ["title", "reason", "follow_up"].map(by).filter(Boolean), right = ["only_if", "tested"].map(by).filter(Boolean);
  const wide = by("changes"), rest = fields.filter((f) => ![...left, ...right, wide].includes(f));
  for (const f of [...left, ...right, ...rest]) f.classList.remove("wide");
  return [el("div", { class: "setcols" }, el("div", { class: "stack" }, left), el("div", { class: "stack" }, right, rest)), wide ? grid([wide]) : null];
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
        const n = node(sub, o, k, `${path}[${i}].${k}`);
        if (k === "title") { n.classList.add("wide"); n.querySelector("input").addEventListener("input", refresh); n.querySelector(".grow").after(aiButton("setting", () => ({ game: GAME.name, changes: o.changes, kind: key }), (r) => { o.title = (r.title || "").slice(0, 60); o.reason = r.reason; draw(); })); }
        return n;
      });
      // Open state follows the setting object, not its position, so moving or redrawing keeps it.
      if (!SET_OPEN.has(o)) { SET_OPEN.set(o, list.length <= 2 || !o.title); }
      const d = el("details", { class: "setcard", open: SET_OPEN.get(o) },
        el("summary", {}, stitle, cond, badge,
          el("span", { class: "sacts" },
            el("button", { type: "button", class: "icon rv", title: "Undo this setting's changes", "aria-label": "Undo changes", onclick: (e) => { e.preventDefault(); revertPath(d.dataset.path); } }, "↺"),
            el("button", { type: "button", class: "icon", "aria-label": "Move up", disabled: i === 0, title: "Move this setting up", onclick: (e) => { e.preventDefault(); [list[i - 1], list[i]] = [list[i], list[i - 1]]; changed(); draw(); } }, "↑"),
            el("button", { type: "button", class: "icon", "aria-label": "Move down", disabled: i === list.length - 1, title: "Move this setting down", onclick: (e) => { e.preventDefault(); [list[i + 1], list[i]] = [list[i], list[i + 1]]; changed(); draw(); } }, "↓"),
            (key === "audio_settings" || key === "optional_settings") ? el("button", { type: "button", class: "btn sm", title: key === "audio_settings" ? "Move this setting to the optional settings" : "Move this setting to the audio settings", onclick: (e) => { e.preventDefault(); const to = key === "audio_settings" ? "optional_settings" : "audio_settings"; parent[to] = parent[to] || []; parent[to].push(list.splice(i, 1)[0]); changed(); renderPane(); } }, key === "audio_settings" ? "→ Optional" : "→ Audio") : null,
            el("button", { type: "button", class: "icon", "aria-label": "Delete", title: "Delete this setting", onclick: async (e) => { e.preventDefault(); if (await askConfirm(`Delete “${o.title || "this setting"}”?`, "Delete", true)) { arr().splice(i, 1); changed(); draw(); } } }, "✕"))),
        el("div", { class: "setbody" }, setBody(fields)));
      d.addEventListener("toggle", () => SET_OPEN.set(o, d.open));
      d.dataset.path = `${path}[${i}]`;
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
      return el("div", { class: "filecard", "data-path": `${path}.${name}` },
        el("header", {}, el("input", { class: "filename", value: name, "aria-label": "File name", title: "The file's name in this profile. Settings that change it follow a rename.", onchange: async (e) => {
          const to = e.target.value.trim();
          if (!to || to === name) { e.target.value = name; return; }
          if (m()[to]) { e.target.value = name; await askConfirm(`${to} is already in this profile.`, "OK"); return; }
          const rekey = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k === name ? to : k, v]));
          parent[key] = rekey(m());
          const gc = GAME.game_config || {};
          for (const s of [...(gc.audio_settings || []), ...(gc.optional_settings || [])]) if (s.changes && s.changes[name]) s.changes = rekey(s.changes);
          changed(); renderPane();
        } }), el("button", { type: "button", class: "icon", title: "Remove this file from the profile. Settings that change it will need fixing.", "aria-label": `Remove ${name}`, onclick: async () => {
          const gc = GAME.game_config || {}, used = [...(gc.audio_settings || []), ...(gc.optional_settings || [])].filter((s) => s.changes && s.changes[name]).length;
          if (used && !(await askConfirm(`${used} setting${used === 1 ? " changes" : "s change"} ${name}. Remove it anyway? Those changes will need fixing.`, "Remove", true))) return;
          delete m()[name]; changed(); draw();
        } }, "✕")),
        grid(Object.entries(resolve(valueSchema).properties).map(([k, sub]) => node(sub, val, k, `${path}.${name}.${k}`))));
    })) : el("div", { class: "empty-note" }, "No config files yet."),
      el("div", { class: "addrow" }, el("button", { type: "button", class: "btn", onclick: async () => {
        const n = await askText("Add a config file", "File name, e.g. game.ini, Quake4Config.cfg, Profile000.gdb or system.reg", "Add"); if (!n) return;
        if (m()[n] && !(await askConfirm(`${n} is already in this profile. Replace it with an empty entry?`, "Replace", true))) return;
        m()[n] = { format: n.endsWith(".reg") ? "wine_reg" : n.endsWith(".gdb") ? "gadb" : n.endsWith(".ltx") ? "ltx" : n.endsWith(".gas") ? "gas_cfg" : "ini", locations: [n.endsWith(".reg") ? "prefix:" + n : "game_exe:" + n] }; changed(); draw();
      } }, "+ Add a config file")));
  };
  draw(); return box;
}
// changes: file -> [section ->] key -> value, edited as a flat table.
function changesEditor(setting, key) {
  const box = el("div");
  const files = () => (GAME.game_config && GAME.game_config.files) || {};
  const sectioned = (f) => ["ini", "gas_cfg", "wine_reg"].includes((files()[f] || {}).format);
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
    const sel = el("select", { style: "flex:0 0 84px", title: "text: set the value to the text you type.\ntrue or false: switch a flag on or off.\nnull: remove the key from the file.", onchange: () => { sel.value === "text" ? upd("") : upd(sel.value === "null" ? null : sel.value === "true"); draw(); } }, ["text", "true", "false", "null"].map((x) => el("option", { selected: x === mode }, x)));
    const inp = el("input", { value: typeof v === "string" ? v : "", placeholder: mode === "text" ? "value" : "", disabled: mode !== "text", oninput: () => upd(inp.value) });
    return el("div", { class: "row" }, sel, inp);
  };
  const draw = () => {
    const fnames = Object.keys(files());
    if (!fnames.length) { box.replaceChildren(el("div", { class: "empty-note" }, "Add a config file under “Config files” first.")); return; }
    box.replaceChildren(el("div", { class: "tblwrap" }, el("table", {}, el("tr", {}, ["File", "Section / registry key", "Key", "Value", ""].map((h) => el("th", {}, h))),
      ...R.map((r, i) => Object.assign(el("tr", {},
        el("td", {}, (() => { const s = el("select", { onchange: () => { r[0] = s.value; commit(); draw(); } }, [el("option", { value: "" }, "Choose…"), ...fnames.map((n) => el("option", { selected: n === r[0] }, n))]); return s; })()),
        el("td", {}, el("input", { value: r[1], disabled: !sectioned(r[0]), placeholder: sectioned(r[0]) ? "section" : "n/a", oninput: (e) => { r[1] = e.target.value; commit(); } })),
        el("td", {}, el("input", { value: r[2], placeholder: "key", oninput: (e) => { r[2] = e.target.value; commit(); } })),
        el("td", {}, val(r[3], (v) => { r[3] = v; commit(); })),
        el("td", {}, el("button", { type: "button", class: "icon", title: "Remove this change from the setting", onclick: () => { R.splice(i, 1); commit(); draw(); } }, "✕"))), { _row: r })))),
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
// Cards that sit side by side when the pane is wide enough and stack when it isn't.
const cols = (...cards) => el("div", { class: "cols" }, cards.flat());
// Adds a visible hint under a field (the ? tooltip is easy to miss and doesn't exist on touch screens).
function hint(f, text) { f.append(el("div", { class: "hint" }, text)); return f; }
function paneOverview() {
  const d = node(P().description, GAME, "description", "description"), n = node(P().notes, GAME, "notes", "notes");
  const rel = node(P().released, GAME, "released", "released"), exe = node(P().exe, GAME, "exe", "exe");
  const src = node(P().sources, GAME, "sources", "sources");
  // The card already names these two single-field cards, so the field's own label and ? would repeat it.
  for (const f of [n, src]) f.classList.add("solo");
  return [cols(
    card("Basics", "The name, a one-line description and the details used to recognise the game's install.",
      grid([node(P().name, GAME, "name", "name"), hint(rel, "A year, a year and month, or a full date."), hint(exe, "Just the file name, as in Game.exe."), hint(d, "One sentence that starts with the game's name.")])),
    card("Sources", P().sources.description, src),
  ), card("Notes", P().notes.description, hint(n, "Anything else a player should know. Keep it short."))];
}
function paneStores() {
  GAME.stores = GAME.stores || {};
  const sp = P().stores.properties, defs = resolve(sp.steam).properties;
  const only = { beta_branch: "steam", companion_apps: "steam", extra_exe_folders: "gog" };
  return [cols(["steam", "gog"].map((st) => {
    const name = st === "steam" ? "Steam" : "GOG";
    if (!GAME.stores[st]) return el("section", { class: "card" }, el("header", {}, el("h3", {}, name)),
      el("div", { class: "empty-note" }, `Not sold on ${name}. `, el("button", { type: "button", class: "btn sm", onclick: () => { GAME.stores[st] = {}; renderPane(); } }, `+ Add ${name} entry`)));
    const fields = Object.entries(defs).filter(([k]) => !only[k] || only[k] === st).map(([k, sub]) => node(sub, GAME.stores[st], k, `stores.${st}.${k}`));
    return el("section", { class: "card" }, el("header", {}, el("h3", {}, name), helpIcon(resolve(sp[st]).description || "A store's ID and notes for this game."), el("span", { class: "sp" }),
      el("button", { type: "button", class: "danger-link", onclick: async () => { if (await askConfirm(`Remove the ${name} entry?`, "Remove", true)) { delete GAME.stores[st]; changed(); renderPane(); } } }, `Remove ${name}`)), grid(fields));
  }))];
}
function paneAudio() {
  GAME.eax = GAME.eax || {}; GAME.install = GAME.install || {};
  const ep = P().eax.properties, ip = P().install.properties;
  return [cols(
    card("EAX", P().eax.description, grid(Object.entries(ep).map(([k, sub]) => node(sub, GAME.eax, k, `eax.${k}`)))),
    card("Install options", P().install.description, grid(Object.entries(ip).map(([k, sub]) => node(sub, GAME.install, k, `install.${k}`)))),
  )];
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
function renderPane() {
  const pane = $("#pane");
  if (SECTION === "capture") { pane.replaceChildren(el("div", { id: "capturebox" })); renderCapture(); return; }
  const build = { overview: paneOverview, stores: paneStores, audio: paneAudio, settings: paneSettings }[SECTION];
  pane.replaceChildren(...build());
  markErrors(); markUnsaved();
}
function drawNav() {
  const nav = $("#snav"); if (!nav) return;
  nav.setAttribute("role", "tablist");
  nav.replaceChildren(...SECTIONS.map(([id, label]) => {
    const n = id === "capture" ? 0 : ERRS.filter((e) => sectionOfPath(e.split(": ")[0]) === id).length;
    return el("button", { type: "button", role: "tab", "aria-selected": String(id === SECTION), class: id === SECTION ? "on" : "", onclick: () => setSection(id) }, label, n ? el("span", { class: "nb", title: `${n} problem${n === 1 ? "" : "s"} in this section` }, n) : null);
  }), el("span", { class: "sp" }), GACTIONS);
}
function setSection(id) { SECTION = id; drawNav(); renderPane(); $("#main").scrollTop = 0; }
function showTab(t) { if (t === "capture") setSection("capture"); else if (SECTION === "capture") setSection("overview"); }

// ---------------------------------------------------------------- header
function drawHeadStatus() {
  const d = $("#dirtybadge"); if (d) d.hidden = !DIRTY;
  const v = $("#revertbtn"); if (v) v.disabled = !DIRTY;
}
let GACTIONS = null;
function renderEdit() {
  $("#empty").hidden = true; $("#settings").hidden = true; $("#game").hidden = false;
  const folderLabel = { tested: "Tested", untested: "Untested", drafts: "Draft" }[CUR.folder];
  $("#ghead").replaceChildren(el("div", { class: "gtop" },
    el("div", { class: "gtitle" }, el("h1", {}, GAME.name || CUR.id),
      el("div", { class: "gmeta" }, el("span", { class: "badge " + CUR.folder, title: { tested: "Verified against a real install.", untested: "Included, but unverified.", drafts: "Incomplete or doubtful; never shipped." }[CUR.folder] }, folderLabel),
        el("code", {}, `${CUR.folder}/${CUR.id}.json`), el("span", { id: "buildbadge", class: "badge" }), el("span", { id: "dirtybadge", class: "badge dirty", hidden: !DIRTY }, "● Unsaved changes"))),
    null));
  // The actions sit in the sticky section bar (drawNav), so they stay in view while scrolling.
  GACTIONS =
    el("div", { class: "gactions" },
      AI && AIF.research ? el("button", { type: "button", class: "btn", onclick: research, title: "Fill in release date, executable, description and EAX details from what the AI knows. Check them against a source." }, "✨ Research") : null,
      el("select", { id: "promo", title: "Move this entry to another folder (tested, untested or draft)", onchange: promote }, [el("option", { value: "" }, "Move to…"), ...["drafts", "untested", "tested"].filter((x) => x !== CUR.folder).map((x) => el("option", {}, x))]),
      el("button", { type: "button", class: "btn", id: "submitbtn", title: "Send this profile to the project as a pull request", onclick: submitClicked }, "Submit…"),
      el("button", { type: "button", class: "btn", id: "revertbtn", disabled: !DIRTY, title: "Throw away every unsaved change and go back to the saved file", onclick: revertAll }, "Revert"),
      el("button", { type: "button", class: "btn primary", id: "savebtn", title: "Save (Ctrl+S). It shows what will change in the file first.", onclick: saveClicked }, "Save"));
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
// In-page replacements for the browser's confirm() and prompt() (resolve false / null on Cancel or Esc).
function askConfirm(message, okLabel = "OK", danger = false) {
  return new Promise((resolve) => {
    let answer = false;
    const dlg = dialog(...String(message).split("\n\n").map((t) => el("p", {}, t)), el("div", { class: "btns" }, el("span", { class: "sp" }),
      el("button", { type: "button", onclick: () => dlg.close() }, "Cancel"),
      el("button", { type: "button", class: danger ? "danger" : "primary", onclick: () => { answer = true; dlg.close(); } }, okLabel)));
    dlg.addEventListener("close", () => resolve(answer));
  });
}
// Save / Discard / Cancel for leaving a game with unsaved changes: "save", "discard" or null (stay).
function askUnsaved() {
  return new Promise((resolve) => {
    let answer = null;
    const pick = (v) => () => { answer = v; dlg.close(); };
    const dlg = dialog(el("p", {}, "This game has unsaved changes."), el("div", { class: "btns" }, el("span", { class: "sp" }),
      el("button", { type: "button", onclick: pick(null) }, "Cancel"),
      el("button", { type: "button", class: "danger", onclick: pick("discard") }, "Discard"),
      el("button", { type: "button", class: "primary", onclick: pick("save") }, "Save")));
    dlg.addEventListener("close", () => resolve(answer));
  });
}
function askText(title, hint = "", okLabel = "OK") {
  return new Promise((resolve) => {
    let answer = null;
    const input = el("input", { style: "width:100%", autofocus: true });
    const done = () => { answer = input.value.trim() || null; dlg.close(); };
    input.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); done(); } };
    const dlg = dialog(el("h3", {}, title), hint ? el("p", { class: "muted" }, hint) : null, input, el("div", { class: "btns" }, el("span", { class: "sp" }),
      el("button", { type: "button", onclick: () => dlg.close() }, "Cancel"), el("button", { type: "button", class: "primary", onclick: done }, okLabel)));
    dlg.addEventListener("close", () => resolve(answer));
    input.focus();
  });
}
async function saveClicked() {
  if (!GAME) return;
  if (SKIP_PREVIEW) return save();
  const r = await api(`/api/preview/${CUR.folder}/${CUR.id}`, "POST", prune(GAME));
  if (r.same) { DIRTY = false; SAVED = prune(GAME); markUnsaved(); drawHeadStatus(); return toast("Nothing to save: the file already matches"); }
  const skip = el("input", { type: "checkbox" });
  const lines = r.diff.split("\n").map((l) => el("div", { class: l.startsWith("+") && !l.startsWith("+++") ? "add" : l.startsWith("-") && !l.startsWith("---") ? "del" : "ctx" }, l || " "));
  const dlg = dialog(el("h3", {}, r.new_file ? "Create this file?" : "Write these changes?"), el("div", { class: "diff" }, lines),
    el("div", { class: "btns" }, el("label", { class: "switch muted" }, skip, "Don't ask again this session"), el("span", { class: "sp" }),
      el("button", { type: "button", onclick: () => dlg.close() }, "Cancel"),
      el("button", { type: "button", class: "primary", onclick: async () => { SKIP_PREVIEW = skip.checked; dlg.close(); await save(); } }, "Write file")));
}
async function save() {
  const r = await api(`/api/game/${CUR.folder}/${CUR.id}`, "PUT", prune(GAME));
  GAME = JSON.parse(r.json); delete GAME["$schema"]; DIRTY = false; SAVED = prune(GAME); renderEdit(); showErrors(r.errors);
  $("#preview").textContent = JSON.stringify(prune(GAME), null, 2);
  toast(r.errors.length ? `Saved, with ${r.errors.length} problem${r.errors.length === 1 ? "" : "s"} to fix` : "Saved ✓"); loadList();
}
// Submit…: checks the profile, shows what looks private, then sends it as a pull request (GitHub CLI) or opens GitHub with it filled in.
async function submitClicked() {
  if (!GAME) return;
  if (DIRTY) await save();
  const info = await api(`/api/submit/prepare/${CUR.folder}/${CUR.id}`, "POST", prune(GAME));
  const note = el("textarea", { rows: 3, style: "width:100%", placeholder: "Anything the reviewer should know (optional)" });
  const onInstall = el("input", { type: "checkbox" }), idsChecked = el("input", { type: "checkbox" }), okPrivate = el("input", { type: "checkbox" });
  let useBrowser = false;
  const go = el("button", { type: "button", class: "primary" }, "Send");
  const via = el("p", { class: "muted" });
  const drawVia = () => {
    via.replaceChildren(info.gh_user && !useBrowser
      ? `This opens a pull request on ${info.upstream} from your GitHub account (${info.gh_user}), with just ${info.name}'s profile. `
      : `This opens GitHub in your browser with the profile filled in, ready for you to send. `,
      "Your captured files stay on your computer.", " ",
      info.gh_user ? el("a", { href: "#", onclick: (e) => { e.preventDefault(); useBrowser = !useBrowser; drawVia(); } }, useBrowser ? "Use my GitHub login instead" : "Use the browser instead") : null);
  };
  drawVia();
  const refresh = () => { go.disabled = info.errors.length > 0 || (info.findings.length > 0 && !okPrivate.checked); };
  okPrivate.onchange = refresh;
  const dlg = dialog(el("h3", {}, `Send ${info.name} to the project?`), via,
    CUR.folder === "tested" ? null : el("p", { class: "muted" }, "It's added as untested, and stays that way until someone has tried it on a real install."),
    info.errors.length ? el("div", {}, el("p", {}, el("strong", {}, "Fix these first:")), el("ul", {}, info.errors.map((x) => el("li", {}, x)))) : null,
    info.findings.length ? el("div", {}, el("p", {}, el("strong", {}, "These look like they came from your computer:")),
      el("ul", {}, info.findings.map((f) => el("li", {}, el("code", {}, f.where), ` “${f.value}” ${f.why}`))),
      el("label", { class: "switch muted" }, okPrivate, "I've checked these and they're fine to share")) : null,
    note,
    el("label", { class: "switch muted" }, onInstall, "I checked this on my own install"),
    el("label", { class: "switch muted" }, idsChecked, "I checked the store IDs on the store's page"),
    el("div", { class: "btns" }, el("span", { class: "sp" }), el("button", { type: "button", onclick: () => dlg.close() }, "Cancel"), go));
  refresh();
  go.onclick = async () => {
    go.disabled = true; go.textContent = "Sending…";
    try {
      const r = await api(`/api/submit/${CUR.folder}/${CUR.id}`, "POST", { game: prune(GAME), note: note.value, checked_install: onInstall.checked, checked_ids: idsChecked.checked, via: useBrowser ? "browser" : "gh" });
      dlg.close(); submitDone(r);
    } catch (x) { go.disabled = false; go.textContent = "Send"; toast(x.message, 9000); }
  };
}
function submitDone(r) {
  if (r.mode === "gh") {
    const d = dialog(el("h3", {}, "Pull request opened"), el("p", {}, "Thank you! A maintainer will look at it. You can follow it here:"),
      el("p", {}, el("a", { href: r.url, target: "_blank", rel: "noopener" }, r.url)), el("div", { class: "btns" }, el("span", { class: "sp" }), el("button", { type: "button", class: "primary", onclick: () => d.close() }, "Done")));
    return;
  }
  const kids = [el("h3", {}, "GitHub is ready")];
  if (r.json) kids.push(el("p", {}, "This profile is too long to fill in by itself. Open GitHub, then paste the profile into the file."),
    el("button", { type: "button", class: "btn", onclick: async (e) => { try { await navigator.clipboard.writeText(r.json); e.target.textContent = "Copied ✓"; } catch { toast("Couldn't copy. Select the text in the JSON panel instead.", 6000); } } }, "Copy the profile"));
  else kids.push(el("p", {}, "The new file is filled in. Check it over, then press “Propose new file” on GitHub."));
  const d = dialog(...kids, el("div", { class: "btns" }, el("span", { class: "sp" }), el("button", { type: "button", onclick: () => d.close() }, "Close"),
    el("a", { class: "btn primary", href: r.url, target: "_blank", rel: "noopener" }, "Open GitHub")));
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
  current: ["In database", "game-database.json already has this game exactly as saved."],
  changed: ["Changed since last build", "The saved file has changes game-database.json doesn't have yet. Press “Rebuild database” to add them."],
  new: ["Not in database yet", "This game isn't in game-database.json yet. Press “Rebuild database” to add it."],
  draft: ["Draft", "Drafts are never added to game-database.json."],
};
const buildTip = (b) => BUILD_TEXT[b.state][1] + (b.fields && b.fields.length ? ` Differs in: ${b.fields.join(", ")}.` : "");
function drawRebuild() {
  const behind = GAMES.filter((g) => g.build && (g.build.state === "changed" || g.build.state === "new"));
  const n = behind.length + STALE.length, b = $("#rebuild");
  b.textContent = n ? `Rebuild database (${n})` : "Rebuild database";
  b.classList.toggle("warn", n > 0);
  b.dataset.tip = n ? `game-database.json is behind by ${behind.length} changed or new game${behind.length === 1 ? "" : "s"}${STALE.length ? `, ${STALE.length} removed` : ""}: ${behind.slice(0, 6).map((g) => g.name).join(", ")}${behind.length > 6 ? "…" : "."}` : "game-database.json is up to date. Rebuild remakes it from the game files.";
}
async function loadList() {
  const j = await api("/api/games"); GAMES = j.games; STALE = j.stale || []; AI = j.ai; AIF = j.ai_features || {};
  $("#aistate").textContent = AI ? `AI: ${AI === "api" ? "API key" : "Claude sign-in"}` : "AI off";
  $("#aistate").dataset.tip = AI ? "AI drafting is on, so the ✨ buttons work. Select to open Settings." : "AI is off. Select to open Settings and sign in, add an API key or turn it back on.";
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
        x.has_config ? el("span", { class: "tag", title: "This game has settings for its own config files" }, "cfg") : null)));
    box.append(d);
  }
  if (!box.children.length) box.append(el("p", { class: "muted" }, "No games match."));
}
async function openGame(folder, id) {
  if (DIRTY) {
    const choice = await askUnsaved();
    if (!choice) return;
    if (choice === "save") { try { await save(); } catch { return; } }
  }
  const j = await api(`/api/game/${folder}/${id}`);
  CUR = { folder, id }; GAME = j.game; SAVED = prune(GAME); CHOSEN_STORE = null; DIRTY = false; if (SECTION === "capture") SECTION = "overview";
  drawList(); showErrors(j.errors); renderEdit(); $("#main").scrollTop = 0;
  $("#preview").textContent = JSON.stringify(prune(GAME), null, 2);
}
async function addByName() {
  const name = await askText("Add a game by name", "", "Add"); if (!name) return;
  const id = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  try { await api("/api/new", "POST", { id, name }); await loadList(); openGame("untested", id); } catch (x) { toast(x.message, 6000); }
}
$("#filter").oninput = drawList;
$("#addinstalled").onclick = addInstalled;
$("#aistate").onclick = () => openSettings();
$("#aistate").onkeydown = (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openSettings(); } };
$("#settingsbtn").onclick = () => openSettings();

// Theme is per browser, so it lives in localStorage; "system" removes the attribute and the stylesheet follows the OS.
const THEME_KEY = "eax-profiler-theme";
function getTheme() { try { const t = localStorage.getItem(THEME_KEY); return t === "light" || t === "dark" ? t : "system"; } catch { return "system"; } }
function setTheme(t) {
  try { if (t === "system") localStorage.removeItem(THEME_KEY); else localStorage.setItem(THEME_KEY, t); } catch { /* private window: applies for this tab only */ }
  if (t === "system") document.documentElement.removeAttribute("data-theme"); else document.documentElement.dataset.theme = t;
}

// The Settings view: appearance, AI sign-in (the claude command, or an Anthropic API key kept in a private file) and the AI switches.
const AI_FEATURES = [
  ["description", "Description", "Drafts the one-sentence description."],
  ["notes", "Notes", "Drafts the notes shown on the game's profile."],
  ["setting", "Setting titles and reasons", "Drafts a title and reason for each game setting."],
  ["research", "Research", "Fills in release date, executable, description and EAX details from what the AI knows. Check them against a source."],
];
const AI_EXPERIMENTAL = [
  ["classify", "Untick unrelated changes", "Marks captured changes that look unrelated to sound, so they start unticked."],
  ["suggest", "Suggest values", "Suggests alsoft.ini values and EAX details from the captured changes."],
];
let SETTINGS_TIMER;
async function openSettings() {
  $("#empty").hidden = true; $("#game").hidden = true; $("#settings").hidden = false; $("#main").scrollTop = 0;
  await drawSettings();
}
function closeSettings() {
  clearInterval(SETTINGS_TIMER); $("#settings").hidden = true;
  if (GAME && CUR) $("#game").hidden = false; else $("#empty").hidden = false;
  loadList();
}
async function drawSettings() {
  let st = await api("/api/ai/status");
  const root = $("#settings");
  const refresh = async () => { st = await api("/api/ai/status"); draw(); };
  const run = (fn, done) => async (e) => { e.target.disabled = true; try { await fn(); if (done) toast(done); } catch (x) { toast(x.message, 8000); } await refresh(); };
  const save = async (patch) => { try { await api("/api/ai/settings", "POST", patch); } catch (x) { toast(x.message, 8000); } await refresh(); };
  const toggle = (id, title, hint, on, onchange, off, extra) => el("div", { class: "srow" + (off ? " off" : "") + (extra ? " " + extra : "") },
    el("input", { type: "checkbox", id, checked: on, disabled: !!off, onchange: (e) => onchange(e.target.checked) }),
    el("label", { for: id }, el("b", {}, title), el("span", { class: "muted" }, hint)));
  function draw() {
    const cli = st.cli, inUse = st.env_key ? "env" : st.in_use, s = st.settings, masterOff = !s.enabled;
    const using = masterOff ? "Off, so everything below is switched off." : st.env_key ? "On, using the ANTHROPIC_API_KEY variable" : st.in_use === "api" ? "On, using your saved API key"
      : st.in_use === "cli" ? "On, using your Claude sign-in" : "Off. Sign in or add an API key to turn on the ✨ buttons";
    clearInterval(SETTINGS_TIMER);
    if (st.login.running) SETTINGS_TIMER = setInterval(refresh, 2000);
    const keyInput = el("input", { type: "password", placeholder: st.saved_key ? "Paste a new key to replace it" : "sk-ant-…", autocomplete: "off", spellcheck: false });
    const card = (title, on, hint, ...kids) => el("section", { class: "aicard" + (on && !masterOff ? " on" : "") },
      el("header", {}, el("h4", {}, title), on && !masterOff ? el("span", { class: "badge untested", style: "background:var(--ok-weak);color:var(--ok)" }, "In use") : null), el("p", { class: "muted" }, hint), ...kids);
    const theme = getTheme();
    const radio = (v, label) => el("label", { class: "chkrow" }, el("input", { type: "radio", name: "theme", checked: theme === v, onchange: () => setTheme(v) }), " " + label);
    root.replaceChildren(
      el("div", { class: "shead" }, el("h1", {}, "Settings"), el("button", { type: "button", class: "btn primary", onclick: closeSettings }, "Back")),
      el("section", {}, el("h2", {}, "Appearance"),
        el("p", { class: "muted" }, "Saved in this browser."),
        el("div", { class: "airow", style: "gap:18px" }, radio("light", "Light"), radio("dark", "Dark"), radio("system", "Match system"))),
      el("section", {}, el("h2", {}, "AI"),
        el("p", { class: "muted" }, "Lets the ✨ buttons fill in text and EAX details, which you should check against a source. To do that it sends Anthropic the game's name and, when drafting from captures, the file names, section names, keys and values of the changes you captured. Your home folder, user name and long numbers are hidden first."),
        toggle("ai-enabled", "Use AI", "Turn this off to hide every ✨ button and send nothing to Anthropic.", s.enabled, (v) => save({ enabled: v })),
        el("div", { class: "aistatus " + (inUse && !masterOff ? "on" : "off"), style: "margin-top:12px" }, el("span", { class: "dot" }), using),
        card("Claude sign-in", inUse === "cli", "Uses your Claude subscription, through the claude command's own sign-in.",
          !cli.installed ? el("p", { class: "bad" }, "Claude Code isn't installed, or the editor can't find it. Make sure the `claude` command works in a terminal, or use an API key instead.")
            : el("div", { class: "airow" },
              el("span", { class: "grow" }, st.login.running ? "Waiting for you to finish signing in, in your browser…" : cli.logged_in ? `Signed in${cli.email ? " as " + cli.email : ""}.` : "Not signed in."),
              cli.logged_in && !st.login.running
                ? el("button", { type: "button", class: "btn", onclick: run(() => api("/api/ai/cli", "POST", { action: "logout" }), "Signed out") }, "Sign out")
                : el("button", { type: "button", class: "btn primary", disabled: st.login.running, onclick: run(() => api("/api/ai/cli", "POST", { action: "login" })) }, "Sign in")),
          st.login.running && st.login.output ? el("pre", { class: "muted", style: "white-space:pre-wrap;word-break:break-all;font-size:12px;margin:8px 0 0" }, st.login.output) : null),
        card("Anthropic API key", inUse === "api" || inUse === "env", st.env_key ? "The ANTHROPIC_API_KEY variable is set, so it is used instead of a saved key." : `Pay-as-you-go. The key is kept in ${st.config}, readable only by you, and sent only to Anthropic.`,
          st.saved_key ? el("div", { class: "airow" }, el("span", { class: "grow" }, `Saved key ${st.saved_key}`), el("button", { type: "button", class: "btn sm", onclick: run(() => api("/api/ai/key/forget", "POST"), "Key removed") }, "Remove")) : null,
          el("div", { class: "airow" }, keyInput, el("button", { type: "button", class: "btn", onclick: run(async () => {
            const r = await api("/api/ai/key", "POST", { key: keyInput.value }); toast(r.checked ? "Key saved ✓" : r.note, 8000);
          }) }, st.saved_key ? "Replace key" : "Save and check"))),
        el("h2", {}, "Drafting"),
        el("p", { class: "muted" }, "Choose which ✨ buttons show."),
        ...AI_FEATURES.map(([id, title, hint]) => toggle("ai-" + id, title, hint, s.features[id], (v) => save({ features: { [id]: v } }), masterOff))),
      el("section", {}, el("h2", {}, "Experimental"),
        el("p", { class: "muted" }, "These work on captured changes and often get it wrong. They are off until you turn them on, and anything they change is only a suggestion to check."),
        ...AI_EXPERIMENTAL.map(([id, title, hint]) => toggle("ai-" + id, title, hint, s.features[id], (v) => save({ features: { [id]: v } }), masterOff))));
  }
  draw();
}
$("#rebuild").onclick = async () => { const r = await api("/api/rebuild", "POST"); toast(r.ok ? "game-database.json rebuilt ✓" : r.message, 8000); await loadList(); };
$("#cleanupbtn").onclick = () => openCleanup(GAME);
function toggleRail() { const l = $("#layout"); const hidden = getComputedStyle($("#rail")).display === "none"; l.classList.toggle("norail", !hidden); l.classList.toggle("rail-on", hidden); if (hidden) $("#rail").style.display = "block"; else $("#rail").style.display = ""; drawRailTab(); }
// The header's JSON button: pressed while the side bar is open, and carries the problem count.
function drawRailTab() {
  const b = $("#jsontoggle"); if (!b) return;
  b.classList.toggle("on", getComputedStyle($("#rail")).display !== "none");
  fill(b, "{ } JSON", ERRS.length ? el("span", { class: "nb" }, String(ERRS.length)) : null);
}
$("#jsontoggle").onclick = toggleRail;
$("#railclose").onclick = toggleRail;
window.addEventListener("resize", drawRailTab);
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
  const dlg = dialog(el("h3", {}, "Manage installs"), el("p", { class: "muted", style: "margin:0" }, "Remove what the script installed, or delete a game's Wine prefix, so you can test from scratch. Nothing is changed until you confirm."),
    el("div", { class: "ctools" }, search, sel), list, note, el("div", { class: "btns" }, el("button", { type: "button", onclick: () => dlg.close() }, "Close")));
  dlg.classList.add("wide");
  const draw = () => {
    const rows = data.entries.filter((e) => (view === "all" || e.state === "installed" || e.state === "orphan") && (e.name + " " + (e.dir || "")).toLowerCase().includes(q))
      .sort((a, b) => (mine(b) ? 1 : 0) - (mine(a) ? 1 : 0));
    list.replaceChildren(...(rows.length ? rows.map((e) => {
      const acts = [];
      if (e.can_remove_install) acts.push(el("button", { type: "button", class: "btn sm", onclick: () => confirmClean(e, "remove"), title: e.state === "installed" ? "Run the script's uninstall for this game." : "The game is gone from your library, so the files the script left are removed directly." }, "Remove install"));
      if (e.prefix_exists) acts.push(el("button", { type: "button", class: "btn sm", disabled: !e.can_reset, onclick: () => confirmClean(e, "prefix"), title: e.can_reset ? "Delete this game's Wine prefix. The launcher makes a new one on the next launch." : (e.reset_blocked || "Can't be reset.") }, "Delete prefix"));
      if (acts.length) acts.push(el("button", { type: "button", class: "btn sm primary", disabled: e.prefix_exists && !e.can_reset && !e.can_remove_install, onclick: () => confirmClean(e, "fresh"), title: "Uninstall the script from this game, delete its Wine prefix and clear its captured data, ready for a fresh test." }, "Start fresh"));
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
let LIB = [], SESS = null, POLL = null, DRAFT = null;
const STEPS = [
  ["pre", "Config files before the install"], ["installed", "After the install"], ["baseline", "Baseline run"],
  ["audio", "Changed options"], ["optional", "Other options (older capture)"],
];
const stepTitle = (label) => (label.startsWith("spk-") ? runName(label) : (STEPS.find(([k]) => k === label) || [0, label])[1]);
const tilde = (p) => (p || "").replace(/^\/home\/[^/]+/, "~");
async function viewStep(label) {
  const v = await api(`/api/session/${SESS.sid}/step/${label}`);
  const body = [];
  body.push(el("p", { class: "muted", style: "margin:0 0 8px" }, v.reference ? `Compared with: ${stepTitle(v.reference)}. Only keys that changed are listed.` : "This is the first snapshot, so there's nothing to compare it with. It lists the files being watched."));
  const drafted = label === "audio" || label === "optional" || label.startsWith("spk-");
  const why = (c) => (c.baseline ? "ignored: the baseline run shows the game rewrites this itself" : c.suspect_reason ? "left out: " + c.suspect_reason : c.expressible ? "kept" : "not allowed by the schema");
  if (v.reference) {
    if (!v.diffs.length) body.push(el("div", { class: "empty-note" }, "Nothing changed in the files the tool watches."));
    for (const f of v.diffs) {
      if (f.unparsed) body.push(el("p", {}, el("b", {}, f.file), ` changed, but no keys could be read from it (guessed format: ${f.format}).`));
      else if (f.binary_offsets) body.push(el("p", {}, el("b", {}, f.file), " changed, but it isn't a file the tool can read key by key."));
      else body.push(el("details", { class: "cfile", open: true }, el("summary", {}, `${f.file}  →  ${f.location || "(outside the known folders)"}  [${f.format}]`),
        el("div", { class: "tblwrap" }, el("table", {}, el("tr", {}, ["Section", "Key", "Was", "Now", drafted ? "In the draft" : null].filter(Boolean).map((h) => el("th", {}, h))),
          ...f.changes.map((c) => el("tr", {}, el("td", {}, categoryPicker(label, f, c, saveDrop)), el("td", {}, c.section), el("td", {}, c.key), el("td", { class: "muted" }, String(c.old)), el("td", {}, String(c.new)), drafted ? el("td", { class: (c.baseline || c.suspect_reason || !c.expressible) ? "muted" : "ok" }, why(c)) : null))))));
    }
    body.push(el("p", { class: "muted" }, (drafted ? "" : "This step isn't used for the draft; it shows what the install or the game does on its own. ") + "Some of Wine's own registry keys are hidden because they change on every run."));
  }
  body.push(el("details", {}, el("summary", {}, `Files watched (${v.files.length})`), el("ul", {}, v.files.map((f) => el("li", { style: "overflow-wrap:anywhere" }, tilde(f.path), f.location ? el("span", { class: "muted" }, `  (${f.location})`) : null)))));
  const dlg = dialog(el("h3", {}, `${stepTitle(label)}: what it captured`), el("div", { style: "max-height:62vh;overflow:auto" }, body), el("div", { class: "btns" }, el("button", { type: "button", onclick: () => dlg.close() }, "Close")));
  dlg.classList.add("wide");
}
const SPEAKERS = [
  ["headphones", "Headphones"], ["matrix", "Pro Logic (matrix)"], ["quad", "4.0 (quad)"],
  ["surround51", "5.1"], ["surround61", "6.1"], ["surround71", "7.1"], ["stereo", "Stereo"],
];
const runName = (label) => (label.startsWith("spk-") ? `${(SPEAKERS.find(([k]) => k === label.slice(4)) || [0, label])[1]} speaker run` : `${label === "audio" ? "options" : label} run`);
async function ensureLib() { if (!LIB.length) LIB = (await api("/api/library")).games; return LIB; }
// Every installed copy of the game (a game sold on Steam and GOG can have both); CHOSEN_STORE picks one.
const libMatches = (g) => LIB.filter((l) => g && g.stores && g.stores[l.store] && g.stores[l.store].id === l.id);
const libMatch = (g) => { const m = libMatches(g); return m.length > 1 ? m.find((l) => l.store === CHOSEN_STORE) || null : m[0]; };
const STORE_NAMES = { steam: "Steam", gog: "GOG" };
// Opening the tab brings back the game's saved steps; nothing runs until "Start capture".
let STARTING = false;
async function renderCapture() {
  await ensureLib();
  const mine = libMatch(GAME);
  if (mine && (!SESS || SESS.lib !== mine) && !STARTING) { STARTING = true; try { await startCapture(mine); } finally { STARTING = false; } }
  drawCapture();
}
function drawCapture() {
  const box = $("#capturebox"); if (!box) return;
  const copies = libMatches(GAME), mine = libMatch(GAME);
  if (SESS && SESS.lib !== mine) { SESS = null; clearInterval(POLL); }
  if (SESS && GAME && GAME.exe && !SESS.state.exe) setExe(GAME.exe).then(() => drawSteps());
  const picker = copies.length > 1 && !SESS ? el("div", { class: "exerow" }, el("label", {}, "Capture which copy?"),
    ...copies.map((l) => el("button", { type: "button", class: l.store === CHOSEN_STORE ? "primary" : "", onclick: async () => { CHOSEN_STORE = l.store; await startCapture(l); } }, STORE_NAMES[l.store] || l.store)),
    el("span", { class: "muted" }, "Installed in both; each copy is captured separately.")) : null;
  fill(box, picker,
    !GAME ? el("div", { class: "empty-note" }, "Open a game on the left, or add an installed one.")
      : !mine && copies.length > 1 ? el("div", { class: "empty-note" }, "Pick which copy to capture.")
      : !mine ? el("div", { class: "empty-note" }, `${GAME.name} isn't installed in Steam or Heroic (matched by store ID), so it can't be captured here.`)
      : null,
    el("div", { id: "steps" }));
  if (SESS) drawSteps();
}
async function captureCurrent() {
  if (!GAME) return toast("Open a game first");
  await ensureLib(); const g = libMatch(GAME);
  if (!g && libMatches(GAME).length > 1) { setSection("capture"); return toast("Installed in both stores: pick which copy to capture", 6000); }
  if (!g) return toast("Not installed in Steam or Heroic (matched by store ID)", 6000);
  if (DIRTY) await save();
  setSection("capture");
}
async function startCapture(g) {
  SESS = { lib: g, sid: `${g.store}-${g.id}`, state: { steps: {} }, job: { state: "idle" } };
  await refreshSession();
  if (!SESS.state.exe && GAME && GAME.exe) {
    try { await setExe(GAME.exe); } catch (e) { toast("Couldn't use this profile's exe name: " + e.message, 8000); }
  }
  DRAFT = SESS.state.draft || null; seedDrop(SESS.state.drop, SESS.state.cats);
  startPoll(); drawCapture();
}
// Installed games with no profile yet (matched by store ID against every entry, drafts included).
async function addInstalled() {
  await ensureLib();
  const have = (l) => GAMES.some((x) => x[l.store] === l.id);
  const todo = LIB.filter((l) => !have(l)).sort((a, b) => a.name.localeCompare(b.name));
  const q = el("input", { placeholder: "Search…" }), list = el("div", { class: "list" });
  const dlg = dialog(el("h3", {}, `Add a game (${todo.length} installed without a profile)`), q, list, el("div", { class: "btns" }, el("button", { type: "button", class: "danger-link", title: "Use this for a game that isn't installed here, or isn't in the list.", onclick: () => { dlg.close(); addByName(); } }, "Not in the list? Add it by name…"), el("span", { class: "sp" }), el("button", { type: "button", onclick: () => dlg.close() }, "Cancel")));
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
async function refreshSession() { const j = await api(`/api/session/${SESS.sid}`); SESS.state = j.session; SESS.job = j.job; SESS.live = j.live; }
// The browser only reveals the picked file's name, which is all the exe fields hold.
function exeBrowse(onPick) {
  const pick = el("input", { type: "file", accept: ".exe", hidden: true, onchange: () => {
    const f = pick.files[0]; if (!f) return;
    onPick(f.name); pick.value = "";
  } });
  return [pick, el("button", { type: "button", class: "btn sm", title: "Choose the game's .exe file to fill in its file name", onclick: () => pick.click() }, "Browse…")];
}
// An exe typed into the profile reaches the open capture session too.
let EXE_SYNC;
function syncSessionExe(exe) {
  if (!SESS) return;
  clearTimeout(EXE_SYNC);
  EXE_SYNC = setTimeout(async () => { if (SESS && SESS.state.exe !== exe) { await setExe(exe); drawSteps(); } }, 400);
}
async function setExe(exe) {
  await api(`/api/session/${SESS.sid}/exe`, "POST", { exe });
  if (exe && GAME && !GAME.exe) { GAME.exe = exe; changed(); }
  await refreshSession();
}
function startPoll() { clearInterval(POLL); POLL = setInterval(async () => { if (!SESS) return; const was = SESS.job.state; await refreshSession(); if (was === "running" || SESS.job.state === "running" || SESS.live) drawSteps(); }, 2000); }
const SPEAKER_SHORT = { headphones: "Headphones", matrix: "Pro Logic", quad: "4.0", surround51: "5.1", surround61: "6.1", surround71: "7.1", stereo: "Stereo" };
// One card per stage of the capture: what the tool does by itself, what the player does in the game, and the review.
function stage(num, done, title, desc, ...rest) {
  return el("div", { class: "stage" + (done ? " done" : "") }, el("div", { class: "num" }, done ? "✓" : num),
    el("div", { class: "sbody" }, el("div", { class: "shead" }, el("b", {}, title)), desc ? el("p", { class: "muted" }, desc) : null, ...rest));
}
function drawSteps() {
  const box = $("#steps"); if (!box) return;
  const st = SESS.state.steps, job = SESS.job, run = job.state === "running", live = SESS.live, exe = SESS.state.exe;
  // What the install needs from the profile: its exe and API, so it deploys the right engine in the right folder.
  const captureProfile = () => {
    const store = SESS.sid.split("-")[0];
    return { name: GAME.name, exe: GAME.exe || SESS.state.exe || "", api: GAME.eax && GAME.eax.api, versions: GAME.eax && GAME.eax.versions,
      extra_exe_folders: GAME.stores && GAME.stores[store] && GAME.stores[store].extra_exe_folders };
  };
  const act = (action) => async () => { try { await api(`/api/session/${SESS.sid}/action`, "POST", { action, profile: captureProfile() }); await refreshSession(); drawSteps(); } catch (x) { toast(x.message, 8000); } };
  const view = (k) => st[k] ? el("button", { type: "button", class: "btn sm", title: "Show what was captured at this step", onclick: () => viewStep(k).catch((x) => toast(x.message, 8000)) }, "View") : null;
  const status = (a) => job.action === a && job.state !== "idle" ? el("div", { class: "status " + job.state }, `${job.state === "error" ? "Problem: " : ""}${job.message}`) : null;
  const prepDone = !!(st.pre && st.installed);

  // ---- 1. prepare
  const prepRows = [["pre", "Config files recorded"], ["installed", "Fix installed with no prompts"], ["baseline", "Baseline run: the game starts and closes itself"]].map(([k, t]) =>
    el("div", { class: "chk" + (st[k] ? " on" : "") }, el("span", { class: "tick" }, st[k] ? "✓" : "○"), el("span", {}, t), st[k] ? el("span", { class: "meta" }, `${st[k].files} files`) : null, view(k)));
  const exeInput = el("input", { placeholder: "Game.exe", value: exe || "" });
  const exeRow = el("div", { class: "exerow" }, el("label", {}, "Game executable"), exeInput,
    ...exeBrowse(async (name) => { exeInput.value = name; await setExe(name); drawSteps(); }),
    el("button", { type: "button", class: "btn sm", onclick: async () => { await setExe(exeInput.value.trim()); drawSteps(); } }, "Save"),
    el("span", { class: "muted" }, exe ? "The tool watches for this to know when the game is open." : "Needed so the tool can tell when the game is running. The baseline run is skipped without it."));
  const s1 = stage(1, prepDone, "Prepare", "Runs by itself, no input needed. It records the config files, installs the fix, then starts the game once and closes it to learn what the game rewrites on its own.",
    exeRow, ...prepRows, status("prepare"),
    el("div", { class: "barrow" }, el("button", { type: "button", class: prepDone ? "" : "primary", disabled: run, onclick: act("prepare") }, prepDone ? "Redo prepare" : "Start capture")));

  // ---- 2. your turn
  const snap = (label, text, title) => el("button", { type: "button", class: st[label] ? "" : "primary", disabled: !live || !!live.snap || (label.startsWith("spk-") && !st.audio), title, onclick: act("snap:" + label) }, st[label] ? `${text} ✓ again` : text);
  const chips = SPEAKERS.map(([k]) => { const key = "spk-" + k; return el("span", { class: "chip" + (st[key] ? " on" : "") },
    el("button", { type: "button", disabled: !live || !!live.snap || !st.audio, title: st.audio ? "Pick this speaker setup in the game, then press this." : "Take the audio snapshot first.", onclick: act("snap:" + key) }, (st[key] ? "✓ " : "") + SPEAKER_SHORT[k]),
    st[key] ? el("button", { type: "button", class: "vw", title: "Show what was captured with this speaker layout", onclick: () => viewStep(key).catch((x) => toast(x.message, 8000)) }, "view") : null); });
  const left = live && live.snap ? Math.max(0, Math.ceil(live.until - Date.now() / 1000)) : 0;
  const s2body = !prepDone ? [el("p", { class: "muted" }, "Finish the preparation first.")]
    : !live ? [status("live"), el("div", { class: "barrow" }, el("button", { type: "button", class: "primary", disabled: run, onclick: act("live") }, st.audio ? "Open the game again" : "Open the game"),
        el("span", { class: "muted" }, "The game stays open while you take every snapshot below, so it starts once, not once per setting."))]
    : [el("ol", { class: "todo" },
        el("li", {}, "In the game, switch ON the EAX / hardware 3D audio options, and change any other options you want to offer (resolution, textures…). Then press ", snap("audio", "Snapshot: changed options", "Records the config files now and compares them with the baseline. You choose each change's category at the review.")),
        el("li", { class: "opt" }, "Optional: for each speaker setup the game offers, pick it in the game and press its button. Layouts that change the same values are merged for you.", el("div", { class: "chips" }, ...chips)),
        el("li", {}, "Done? ", el("button", { type: "button", onclick: act("stop"), title: "Ask the game to quit" }, "Close the game"))),
      live.snap ? el("div", { class: "status running" }, `Taking the “${stepTitle(live.snap)}” snapshot. Wine saves its registry about every 30 seconds, so leave the game as it is for up to ${left || "a few"} s.`) : status("live")];
  const keptRows = ["audio", "optional"].filter((k) => st[k] && !live).map((k) => el("div", { class: "chk on" }, el("span", { class: "tick" }, "✓"), el("span", {}, stepTitle(k)), el("span", { class: "meta" }, `${st[k].files} files`), view(k)));
  const s2 = stage(2, !!st.audio, "Your turn", "The only manual part: change the options in the game.", ...s2body, ...keptRows);

  // ---- 3. review
  const s3 = stage(3, !!DRAFT, "Review", "Compares the snapshots and drafts the game's settings. You can untick anything before it goes into the entry.",
    el("div", { class: "barrow" }, el("button", { type: "button", class: "primary", disabled: run || !st.audio || !!(live && live.snap), title: st.audio ? "" : "Take the audio snapshot first.", onclick: makeDraft }, DRAFT ? "Build again" : "Build settings from the captures")),
    el("div", { id: "draftbox" }));
  const hasData = Object.keys(st).length || DRAFT;
  const clear = hasData ? el("div", { class: "barrow" }, el("span", { class: "sp" }), el("button", { type: "button", class: "danger-link", disabled: run || !!live,
    title: live ? "Close the game first." : "Deletes this game's snapshots, draft and ticks. The game's profile and anything installed are left alone.",
    onclick: clearCapture }, "Clear this game's captured data")) : null;
  fill(box, clear, el("div", { class: "stages" }, s1, s2, s3));
  if (DRAFT) showDraft();
}
async function clearCapture() {
  if (!SESS || !(await askConfirm(`Delete all captured data for ${GAME.name || "this game"}?\n\nThis removes its snapshots, the drafted settings and your ticks. Its profile and anything installed are not touched.`, "Delete", true))) return;
  try { await api(`/api/session/${SESS.sid}/reset`, "POST"); DRAFT = null; DROP.clear(); CAT.clear(); await refreshSession(); drawSteps(); toast("Captured data cleared."); }
  catch (x) { toast(x.message, 8000); }
}
const DROP = new Set();
// The Review table's category choice per change ("audio" / "optional"), where it differs from the tool's guess.
const CAT = new Map();
// Remembers the ticks and categories in the session, so they survive a reload. Used by the review and by the step viewer.
const saveDrop = () => api(`/api/session/${SESS.sid}/drop`, "POST", { drop: [...DROP], cats: Object.fromEntries(CAT) }).catch(() => {});
const dropKey = (f, c) => [f.file, f.format, c.section, c.key].join("\0");
function seedDrop(saved, cats) {
  DROP.clear(); CAT.clear();
  for (const [k, v] of Object.entries(cats || {})) CAT.set(k, v);
  if (Array.isArray(saved)) return saved.forEach((k) => DROP.add(k));
  if (DRAFT) for (const list of Object.values(DRAFT.diffs)) for (const f of list) for (const c of f.changes) if (c.suspect_reason) DROP.add(dropKey(f, c));
}
async function makeDraft() {
  const box = $("#draftbox"); box.textContent = "Working…";
  DRAFT = await api(`/api/session/${SESS.sid}/draft`, "POST", { ai: true });
  seedDrop(null); drawSteps();
}
function showDraft() {
  const box = $("#draftbox"), d = DRAFT; if (!box || !d) return;
  // Unticking a whole file first is quicker than unticking dozens when only a few settings matter.
  const setFile = (f, keep) => { for (const c of f.changes) { const k = dropKey(f, c); keep ? DROP.delete(k) : DROP.add(k); } saveDrop(); showDraft(); };
  fill(box, el("div", { class: "blockhead" }, el("h2", {}, "Captured changes"), helpIcon("Tick the changes to keep. Changes that look like the game's own housekeeping start unticked, with the reason shown.")),
    ...Object.entries(d.diffs).flatMap(([label, list]) => [el("p", {}, el("b", {}, runName(label))), ...(list.length ? list.map((f) => el("details", { class: "cfile", open: true }, el("summary", {}, `${f.file}  →  ${f.location || "(outside known folders)"}  [${f.format}]`),
      el("div", { class: "barrow" }, el("button", { type: "button", class: "btn sm", onclick: () => setFile(f, false) }, "Untick all in this file"), el("button", { type: "button", class: "btn sm", onclick: () => setFile(f, true) }, "Tick all in this file")),
      el("div", { class: "tblwrap" }, el("table", {}, el("tr", {}, ["Keep", "Category", "Section", "Key", "Was", "Now", ""].map((h) => el("th", {}, h))), ...f.changes.map((c) => el("tr", {}, el("td", {}, el("input", { type: "checkbox", checked: c.expressible && !DROP.has(dropKey(f, c)), disabled: !c.expressible, title: "Keep this change when merging into the profile", onchange: (e) => { const k = dropKey(f, c); e.target.checked ? DROP.delete(k) : DROP.add(k); saveDrop(); } })), el("td", {}, c.section), el("td", {}, c.key), el("td", { class: "muted" }, String(c.old)), el("td", {}, String(c.new)), el("td", { class: c.expressible ? "muted" : "bad" }, c.expressible ? (c.suspect_reason ? "left out: " + c.suspect_reason : "") : "not allowed by schema"))))))) : [el("p", { class: "muted" }, "No changes.")])]),
    ...(d.skipped.length ? [el("div", { class: "blockhead" }, el("h2", {}, "Needs a human")), el("ul", {}, d.skipped.map((x) => el("li", {}, x)))] : []),
    d.ai && d.ai !== "ok" ? el("p", { class: "bad" }, d.ai) : null,
    suggestionsBlock(d.suggestions),
    el("div", { class: "barrow" }, el("button", { type: "button", class: "primary", onclick: () => merge(d.game_config, d.diffs) }, "Merge into the entry and review")));
}
// Speaker runs are always audio settings gated by speaker layout, so only the options run has a choice.
function categoryPicker(label, f, c, saveDrop) {
  if (label.startsWith("spk-")) return el("span", { class: "muted" }, "Audio");
  const k = dropKey(f, c), sel = el("select", { title: "Audio: needed for the sound fix.\nOptional: offered to the player as an extra.", onchange: () => { sel.value === (c.category || "optional") ? CAT.delete(k) : CAT.set(k, sel.value); saveDrop(); } },
    el("option", { value: "audio" }, "Audio"), el("option", { value: "optional" }, "Optional"));
  sel.value = CAT.get(k) || c.category || "optional";
  return sel;
}
function suggestionsBlock(sg) {
  if (!sg) return null;
  const items = [];
  for (const [sec, keys] of Object.entries(sg.alsoft_ini || {})) for (const [k, v] of Object.entries(keys))
    items.push([`alsoft.ini  [${sec}] ${k} = ${v}`, sg.reasons[`alsoft_ini.${sec}.${k}`], () => { GAME.install = GAME.install || {}; GAME.install.alsoft_ini = GAME.install.alsoft_ini || {}; (GAME.install.alsoft_ini[sec] = GAME.install.alsoft_ini[sec] || {})[k] = v; }]);
  if (sg.eax && sg.eax.api) items.push([`EAX API: ${sg.eax.api}`, sg.reasons["eax.api"], () => { GAME.eax = GAME.eax || {}; GAME.eax.api = sg.eax.api; }]);
  if (sg.eax && sg.eax.versions) items.push([`EAX versions: ${sg.eax.versions.join(", ")}`, sg.reasons["eax.versions"], () => { GAME.eax = GAME.eax || {}; GAME.eax.versions = sg.eax.versions; }]);
  if (!items.length) return el("p", { class: "muted" }, "The AI had no extra suggestions.");
  return el("div", {}, el("div", { class: "blockhead" }, el("h2", {}, "AI suggestions"), helpIcon("Check these against a source before using them. Nothing is applied until you press Apply.")), ...items.map(([t, r, apply]) => el("div", { class: "row" },
    el("span", { style: "flex:1" }, t, r ? el("div", { class: "muted" }, r) : null), el("button", { type: "button", class: "btn sm", onclick: (e) => { apply(); changed(); e.currentTarget.disabled = true; e.currentTarget.textContent = "Applied"; toast("Applied. See the Audio & install tab."); } }, "Apply"))));
}
// Removes the changes the user unticked (DROP holds file/format/section/key).
function applyDrops(gc) {
  const out = JSON.parse(JSON.stringify(gc));
  moveByCategory(out);
  for (const kind of ["audio_settings", "optional_settings"]) {
    if (!out[kind]) continue;
    out[kind] = out[kind].filter((st) => {
      for (const [file, body] of Object.entries(st.changes)) {
        const fmt = (out.files[file] || {}).format;
        const sectioned = ["ini", "gas_cfg", "wine_reg"].includes(fmt);
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
// Moves each change whose category the player flipped to the other list (speaker-gated settings stay put).
function moveByCategory(gc) {
  const into = (kind) => {
    gc[kind] = gc[kind] || [];
    let st = gc[kind].find((x) => !x.only_if);
    if (!st) gc[kind].push(st = { title: "TODO title", reason: "TODO reason", changes: {} });
    return st;
  };
  for (const [from, to] of [["audio_settings", "optional"], ["optional_settings", "audio"]]) {
    for (const st of (gc[from] || []).filter((x) => !x.only_if)) {
      for (const [file, body] of Object.entries(st.changes)) {
        const fmt = (gc.files[file] || {}).format, sectioned = ["ini", "gas_cfg", "wine_reg"].includes(fmt);
        const move = (sec, key, val) => {
          if (CAT.get([file, fmt, sec, key].join("\0")) !== to) return false;
          const dest = into(to === "audio" ? "audio_settings" : "optional_settings").changes;
          const t = dest[file] = dest[file] || {};
          (sectioned ? (t[sec] = t[sec] || {}) : t)[key] = val;
          return true;
        };
        for (const [a, v] of Object.entries(body)) {
          if (sectioned) { for (const [k, val] of Object.entries(v)) if (move(a, k, val)) delete v[k]; if (!Object.keys(v).length) delete body[a]; }
          else if (move("", a, v)) delete body[a];
        }
        if (!Object.keys(body).length) delete st.changes[file];
      }
    }
  }
}
async function merge(gc0) {
  const gc = applyDrops(gc0);
  if (!GAME) return toast("Open or create the game's entry first");
  const r = await api("/api/merge-config", "POST", { existing: prune(GAME).game_config || {}, new: gc });
  GAME.game_config = r.game_config;
  const p = r.report, bits = [`Merged ${p.added.length} setting${p.added.length === 1 ? "" : "s"}.`];
  if (p.skipped.length) bits.push(`Left out ${p.skipped.length} already in the entry: ${p.skipped.join(", ")}.`);
  if (p.trimmed.length) bits.push(`${p.trimmed.join("; ")}.`);
  if (p.conflicts.length) bits.push(`Check: ${p.conflicts.join("; ")}.`);
  if (p.files_differ.length) bits.push(`Kept the entry's own definition of ${p.files_differ.join(", ")}.`);
  bits.push(p.added.length ? "Check each title and reason, then Save." : "Nothing new to add.");
  changed(); setSection("settings"); toast(bits.join(" "), 14000);
}

// Tells the server this page is still open (it can stop itself once pings stop) and handles the Quit button.
const ping = () => fetch("/api/ping").catch(() => {});
ping(); setInterval(ping, 10000);
$("#quitbtn").onclick = async () => {
  if (!(await askConfirm(DIRTY ? "Quit the editor? You have unsaved changes, and they will be lost." : "Quit the editor?", "Quit", DIRTY))) return;
  await fetch("/api/quit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }).catch(() => {});
  document.body.replaceChildren(el("div", { class: "empty" }, el("h2", {}, "The editor has stopped."), el("p", {}, "You can close this tab. Start it again from the app menu or with tools/profiler/eax-profiler.")));
};

// The checkout the editor runs from, in the header next to the brand.
async function showVersion() {
  const v = await api("/api/version").catch(() => null), chip = $("#version");
  // An editor started before this existed has no such route; say so rather than show nothing.
  chip.textContent = v ? [v.build && `Build ${v.build}`, v.commit && `${v.branch} ${v.commit}`, v.dirty && "modified"].filter(Boolean).join(" · ") : "build unknown — restart the editor";
  chip.dataset.tip = v ? "Build number: how many commits have changed the editor. The branch and commit it's running from follow." : "This editor was started before it could report its build. Quit and open it again.";
  chip.hidden = !chip.textContent;
}
// A newer version upstream: the server fetched it at start-up; Update fast-forwards the checkout.
async function showUpdateBar() {
  const u = await api("/api/update").catch(() => null), bar = $("#updatebar");
  if (!u || !u.behind) return;
  const n = u.behind, what = `${n} newer change${n === 1 ? "" : "s"} available for the editor and the game database`;
  const close = el("button", { type: "button", class: "btn sm ghost", onclick: () => { bar.hidden = true; } }, "Later");
  if (!u.can_update) { fill(bar, el("span", {}, `${what}. ${u.reason}`), el("span", { class: "sp" }), close); bar.hidden = false; return; }
  const go = el("button", { type: "button", class: "btn sm primary", onclick: async () => {
    if (!(await askConfirm((DIRTY ? "You have unsaved changes, and they will be lost when you restart the editor. Save them first.\n\n" : "") + "Update now?\n\n" + u.subjects.map((x) => "• " + x).join("\n") + (n > u.subjects.length ? `\n…and ${n - u.subjects.length} more` : ""), "Update", DIRTY))) return;
    go.disabled = true; go.textContent = "Updating…";
    try {
      const r = await api("/api/update", "POST");
      fill(bar, el("span", {}, "Updated." + (r.build_ok ? "" : " The script couldn't be rebuilt; run ./build.sh.") + " Quit the editor and open it again to use the new version."), el("span", { class: "sp" }), el("button", { type: "button", class: "btn sm primary", onclick: () => $("#quitbtn").click() }, "Quit"));
    } catch (x) { go.disabled = false; go.textContent = "Update"; toast(x.message, 10000); }
  } }, "Update");
  fill(bar, el("span", {}, what + "."), el("span", { class: "sp" }), go, close); bar.hidden = false;
}
window.addEventListener("error", (e) => toast("JS error: " + e.message, 20000));
window.addEventListener("unhandledrejection", (e) => toast("Error: " + (e.reason && e.reason.message || e.reason), 20000));
(async () => {
  SCHEMA = await api("/api/schema"); await loadList(); showErrors([]); showVersion(); showUpdateBar();
  // The URL shortcuts (open a game, click a selector...) are for screenshots and tests. Any web
  // page can open this one with a query string, so they only work when the server is in debug mode.
  const debug = (await api("/api/debug")).debug;
  const q = new URLSearchParams(debug ? location.search : "");
  const o = q.get("open");
  if (o) await openGame(...o.split("/"));
  if (q.get("section")) setSection(q.get("section"));
  if (q.get("startcapture")) await captureCurrent();
  if (q.get("addsetting")) { GAME.game_config.audio_settings.push({ title: "", reason: "", changes: {} }); renderPane(); }
  if (q.get("click")) $$(q.get("click"))[+(q.get("n") || 0)].click();
  if (q.get("viewstep")) await viewStep(q.get("viewstep"));
  if (q.get("adddlg")) await addInstalled();
  if (q.get("cleanup")) await openCleanup(GAME);
  if (q.get("tipsel")) showTip($$(q.get("tipsel"))[0]);
  if (q.get("tipdemo")) showTip($$(".qm")[+q.get("tipdemo") - 1]);
  if (q.get("rail") === "0") $("#layout").classList.add("norail");
})();
