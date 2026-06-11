#!/usr/bin/env node
// Genereert wk2026-forecast/index.html als volledig statische pagina
// (geen JavaScript nodig in de browser: CSS-only tabs + native <details>).
// Bron van waarheid: data.json (geverifieerde agent council-voorspelling).
// Gebruik: node build.js

const fs = require("fs");
const path = require("path");

const F = JSON.parse(fs.readFileSync(path.join(__dirname, "data.json"), "utf8"));

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const TABS = [
  ["verdict", "🏆", "Verdict"],
  ["poules", "📋", "Poules"],
  ["bracket", "⚔️", "Bracket"],
  ["nederland", "🇳🇱", "Oranje"],
  ["topscorers", "🥇", "Prijzen"],
  ["scorito", "🎯", "Scorito"],
];
const ROUNDS = [
  ["1/16e", "Ronde van 32", F.bracket.r32],
  ["1/8e", "Achtste finales", F.bracket.r16],
  ["KF", "Kwartfinales", F.bracket.qf],
  ["HF", "Halve finales", F.bracket.sf],
  ["Finale", "Finale & troostfinale", [F.bracket.final, F.bracket.thirdPlace].filter(Boolean)],
];

function parseScore(score) {
  const m = /^(\d+)\s*-\s*(\d+)\s*(.*)$/.exec(score || "");
  return m ? { h: m[1], a: m[2], suffix: (m[3] || "").trim() } : { h: "", a: "", suffix: score || "" };
}

/* ── Secties ─────────────────────────────────────────────── */

function verdictHtml() {
  const v = F.verdict, fin = F.bracket.final, sc = parseScore(fin.score);
  const favs = F.favorites.map(f => {
    const chip = /kampioen/i.test(f.endStation) ? "endchip win" : (f.team === "Nederland" ? "endchip nl" : "endchip");
    return `<div class="card">
      <div class="fav-head"><span class="f">${f.flag}</span><span class="nm">${esc(f.team)}</span><span class="odds">${esc(f.odds)}</span></div>
      <span class="${chip}">${esc(f.endStation)}</span>
      <p>${f.analysis}</p>
    </div>`;
  }).join("\n");
  return `<section class="tab" id="tab-verdict">
    <div class="hero">
      <div class="kicker">De voorspelling van de agent council</div>
      <div class="trophy" aria-hidden="true">🏆</div>
      <div class="name">${esc(v.champion)}</div>
      <div><span class="chip">Wereldkampioen 2026</span></div>
      <div class="scoreline">
        <div class="t"><span class="f">${fin.homeFlag}</span><span>${esc(fin.home)}</span></div>
        <div class="sc">${sc.h} – ${sc.a}</div>
        <div class="t"><span class="f">${fin.awayFlag}</span><span>${esc(fin.away)}</span></div>
      </div>
      <div class="meta">${esc(fin.label.replace(/^M\d+ · /, ""))}</div>
    </div>
    <div class="card goldc"><h3>Het oordeel van de council</h3><p class="bodytext">${v.summary}</p></div>
    <div class="card"><h3>Kernargumenten</h3><ol class="args">${v.keyArguments.map(a => `<li>${a}</li>`).join("")}</ol></div>
    <h2 class="section">De favorieten gewogen</h2>
    <div class="fav">${favs}</div>
  </section>`;
}

function poulesHtml() {
  const cards = F.groups.map(g => `<div class="card">
    <span class="gletter" aria-hidden="true">${g.letter}</span>
    <h3>Poule ${g.letter}</h3>
    ${g.teams.map(t => `<div class="grow ${t.status}${t.nl ? " nlrow" : ""}">
      <span class="pos">${t.pos}</span><span>${t.flag} ${esc(t.name)}</span><span class="pts">${t.pts} pt</span>
    </div>`).join("")}
    <div class="gnote">${g.analysis}</div>
  </div>`).join("\n");
  const thirds = F.bestThirds.map(t =>
    `<span class="${t.advances ? "in" : "uit"}">${t.flag} ${esc(t.team)} ${t.advances ? "✓" : "✕"}</span>`).join("");
  return `<section class="tab" id="tab-poules">
    <p class="lead">Voorspelde eindstanden van alle twaalf poules.</p>
    <div class="legend">
      <span><i style="background:var(--green)"></i>Top 2: direct door</span>
      <span><i style="background:var(--gold)"></i>Door als beste nummer 3</span>
      <span><i style="background:rgba(255,255,255,.25)"></i>Uitgeschakeld</span>
    </div>
    <p class="swipe-hint">← swipe door de poules →</p>
    <div class="rail">${cards}</div>
    <h2 class="section">De strijd om de beste nummers 3</h2>
    <p class="lead">Acht van de twaalf nummers 3 gaan door naar de ronde van 32.</p>
    <div class="card"><div class="thirds">${thirds}</div></div>
  </section>`;
}

function matchHtml(m, isFinal) {
  const sc = parseScore(m.score);
  const row = (team, flag, goals) => {
    const win = team === m.winner;
    return `<span class="row ${win ? "win" : "lose"}${team === "Nederland" ? " nlteam" : ""}">
      <span class="f" aria-hidden="true">${flag}</span><span class="n">${esc(team)}${win ? " ✓" : ""}</span><span class="s">${goals}</span>
    </span>`;
  };
  return `<details class="m${isFinal ? " finalcard" : ""}">
    <summary>
      <span class="lbl"><span>${esc(m.label)}${sc.suffix ? " · " + esc(sc.suffix) : ""}</span><span class="chev" aria-hidden="true">▾</span></span>
      ${row(m.home, m.homeFlag, sc.h)}
      ${row(m.away, m.awayFlag, sc.a)}
    </summary>
    ${m.note ? `<div class="note">${m.note}</div>` : ""}
  </details>`;
}

function bracketHtml() {
  const seg = ROUNDS.map(([short], i) => `<label for="r-${i}">${esc(short)}</label>`).join("");
  const panes = ROUNDS.map(([_, full, matches], i) => `<div class="round-pane" id="pane-${i}">
    <p class="lead">${esc(full)} — tik op een wedstrijd voor de onderbouwing.</p>
    <div class="matches">${matches.map(m => matchHtml(m, full.startsWith("Finale") && m === F.bracket.final)).join("\n")}</div>
  </div>`).join("\n");
  return `<section class="tab" id="tab-bracket">
    <div class="seg" role="tablist" aria-label="Toernooironde">${seg}</div>
    ${panes}
    <p class="tap-hint">Het pad van 🇳🇱 Oranje is oranje gemarkeerd, winnaars goud.</p>
  </section>`;
}

function nederlandHtml() {
  const nl = F.netherlands;
  const steps = nl.path.map(step => {
    const sc = parseScore(step.result);
    const badge = sc.h === sc.a ? "G" : (step.win ? "W" : "V");
    return `<div class="tl-step">
      <span class="tl-badge ${badge}">${badge}</span>
      <div class="tl-round">${esc(step.round)}</div>
      <div class="tl-fix">${esc(step.fixture)}<span class="res">${esc(step.result)}</span></div>
      <div class="tl-why">${step.why}</div>
    </div>`;
  }).join("\n");
  return `<section class="tab" id="tab-nederland">
    <div class="card nl-hero">
      <div class="flag" aria-hidden="true">🇳🇱</div>
      <div class="fin">${esc(nl.finish)}</div>
      <p class="bodytext">${nl.summary}</p>
    </div>
    <h2 class="section">Het pad van Oranje</h2>
    <div class="card"><div class="tl">${steps}</div></div>
    <div class="card"><h3>Selectie &amp; vorm</h3><p class="bodytext">${nl.squadNotes}</p></div>
  </section>`;
}

function topscorersHtml() {
  const ts = F.topscorers;
  const pod = [[ts[1], "p2", "🥈"], [ts[0], "p1", "🥇"], [ts[2], "p3", "🥉"]].map(([t, cls, medal]) =>
    `<div class="pod ${cls}">
      <div class="medal" aria-hidden="true">${medal}</div>
      <div class="pf" aria-hidden="true">${t.flag}</div>
      <div class="pn">${esc(t.player)}</div>
      <div class="pg">${t.goals}</div><div class="pgl">goals</div>
    </div>`).join("");
  const rows = ts.map(t => `<div class="ts-row">
      <span class="rk">${t.rank}</span>
      <div class="ts-main">
        <div class="ts-name">${t.flag} ${esc(t.player)} <small>· ${esc(t.team)}</small></div>
        <div class="ts-note">${t.note}</div>
      </div>
      <span class="ts-goals">${t.goals}</span>
    </div>`).join("\n");
  const awards = F.awards.map(a => `<div class="card">
      <h3>${esc(a.title)}</h3>
      <div class="who">${esc(a.winner)} · ${esc(a.team)}</div>
      <p>${a.why}</p>
    </div>`).join("\n");
  return `<section class="tab" id="tab-topscorers">
    <h2 class="section" style="margin-top:6px">🥇 Gouden Schoen</h2>
    <div class="podium">${pod}</div>
    <div class="card">${rows}</div>
    <h2 class="section">Individuele prijzen</h2>
    <div class="awards">${awards}</div>
  </section>`;
}

function scoritoHtml() {
  const s = F.scorito;
  const groups = Object.entries(s.picks).map(([pos, picks]) => {
    const m = /^(.*?)\s*\((.*?)\)\s*$/.exec(pos);
    const title = m ? m[1] : pos, mult = m ? m[2] : "";
    const items = picks.map(p => `<li>
        <div><span class="pp">${p.flag} ${esc(p.player)}</span><span class="pt2"> · ${esc(p.team)}</span></div>
        <div class="pw">${p.why}</div>
      </li>`).join("");
    return `<div class="card"><h3>${esc(title)}${mult ? `<span class="mult">${esc(mult)}</span>` : ""}</h3><ul class="picks">${items}</ul></div>`;
  }).join("\n");
  return `<section class="tab" id="tab-scorito">
    <div class="card"><h3>Spelregels in het kort</h3><p class="bodytext">${F.scoritoRules}</p></div>
    <div class="card accent"><h3 style="color:var(--oranje)">⭐ Gouden tip</h3><p class="bodytext">${s.captain}</p></div>
    <h2 class="section">Ronde-strategie</h2>
    <div class="card"><ol class="steps">${s.strategy.map(x => `<li>${x}</li>`).join("")}</ol></div>
    <h2 class="section">De picks</h2>
    <div class="pickgrid">${groups}</div>
  </section>`;
}

/* ── CSS-only interactiviteit ────────────────────────────── */

const tabStateCss = TABS.map(([id]) =>
  `#t-${id}:checked ~ main #tab-${id}{display:block;animation:rise .3s ease}
#t-${id}:checked ~ nav label[for="t-${id}"]{color:var(--oranje)}
#t-${id}:checked ~ nav label[for="t-${id}"] .ico{transform:translateY(-2px) scale(1.08)}`).join("\n");

const tabDesktopCss = TABS.map(([id]) =>
  `#t-${id}:checked ~ nav label[for="t-${id}"]{background:rgba(255,107,26,.12)}
#t-${id}:checked ~ nav label[for="t-${id}"] .ico{transform:none}`).join("\n");

const roundStateCss = ROUNDS.map((_, i) =>
  `#r-${i}:checked ~ main #pane-${i}{display:block;animation:rise .25s ease}
#r-${i}:checked ~ main .seg label[for="r-${i}"]{color:#200f02;background:linear-gradient(135deg,var(--oranje),#ff9b4a);border-color:transparent}`).join("\n");

const css = `
  :root {
    --bg0: #070b14; --card: rgba(255,255,255,.045); --card-brd: rgba(255,255,255,.09);
    --text: #eef2fa; --soft: #c2cbdc; --muted: #8e9bb5;
    --oranje: #ff6b1a; --gold: #ffc83d; --teal: #2dd4bf; --green: #34d399; --red: #f87171;
    --top-off: 58px; --radius: 18px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html { scroll-behavior: smooth; }
  body {
    background-color: var(--bg0);
    background-image:
      radial-gradient(60rem 40rem at 110% -10%, rgba(255,200,61,.07), transparent 60%),
      radial-gradient(50rem 36rem at -20% 30%, rgba(255,107,26,.08), transparent 60%),
      radial-gradient(46rem 40rem at 80% 110%, rgba(45,212,191,.06), transparent 60%);
    background-attachment: fixed;
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    line-height: 1.6; -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: transparent;
    min-height: 100dvh;
  }
  .pitch-lines {
    position: fixed; inset: 0; pointer-events: none; z-index: 0; opacity: .045;
    background:
      radial-gradient(circle at 50% 34%, transparent 117px, #fff 118px, #fff 120px, transparent 121px),
      linear-gradient(#fff, #fff) 0 34% / 100% 2px no-repeat;
  }
  .vh { position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none; }

  .appbar {
    position: sticky; top: 0; z-index: 30;
    background: rgba(7,11,20,.78);
    backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
    border-bottom: 1px solid rgba(255,255,255,.06);
  }
  .appbar-inner { max-width: 1080px; margin: 0 auto; display: flex; align-items: center; gap: 10px; padding: 9px 16px; }
  .logo { font-size: 1.45rem; filter: drop-shadow(0 0 8px rgba(255,200,61,.45)); }
  .appbar-text strong { display: block; font-size: .95rem; letter-spacing: .05em; }
  .appbar-text small { display: block; font-size: .65rem; color: var(--muted); max-width: 56vw; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .appbar .champ {
    margin-left: auto; font-size: .72rem; font-weight: 700; color: var(--gold);
    border: 1px solid rgba(255,200,61,.35); background: rgba(255,200,61,.08);
    padding: 4px 11px; border-radius: 999px; white-space: nowrap;
  }

  nav {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 40;
    display: flex; justify-content: space-around;
    background: rgba(9,13,23,.93);
    backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
    border-top: 1px solid rgba(255,255,255,.08);
    padding: 5px max(8px, env(safe-area-inset-left)) calc(5px + env(safe-area-inset-bottom)) max(8px, env(safe-area-inset-right));
  }
  nav label {
    display: flex; flex-direction: column; align-items: center; gap: 2px; cursor: pointer;
    color: var(--muted); font-size: .6rem; font-weight: 600; letter-spacing: .02em;
    padding: 6px 6px; border-radius: 12px; min-width: 46px; min-height: 44px;
    transition: color .2s; user-select: none;
  }
  nav label .ico { font-size: 1.3rem; line-height: 1.15; transition: transform .18s; }
  nav label:active .ico { transform: scale(.88); }
${tabStateCss}

  main { position: relative; z-index: 1; max-width: 1080px; margin: 0 auto; padding: 16px 16px calc(92px + env(safe-area-inset-bottom)); }
  footer { position: relative; z-index: 1; text-align: center; color: var(--muted); font-size: .74rem; padding: 8px 20px calc(96px + env(safe-area-inset-bottom)); max-width: 720px; margin: 0 auto; }

  @media (min-width: 768px) {
    :root { --top-off: 112px; }
    nav { position: sticky; top: 53px; bottom: auto; justify-content: center; gap: 6px; border-top: 0; border-bottom: 1px solid rgba(255,255,255,.07); padding: 8px 16px; }
    nav label { flex-direction: row; gap: 8px; font-size: .85rem; padding: 9px 16px; min-height: 0; }
    nav label .ico { font-size: 1.05rem; }
${tabDesktopCss}
    main { padding-bottom: 60px; }
    footer { padding-bottom: 36px; }
  }

  section.tab { display: none; }
  @keyframes rise { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
  @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }

  .card { background: var(--card); border: 1px solid var(--card-brd); border-radius: var(--radius); padding: 17px 18px; margin-bottom: 13px; }
  .card.accent { border-color: rgba(255,107,26,.4); background: linear-gradient(160deg, rgba(255,107,26,.13), rgba(255,107,26,.02) 55%), var(--card); }
  .card.goldc { border-color: rgba(255,200,61,.35); background: linear-gradient(160deg, rgba(255,200,61,.1), transparent 60%), var(--card); }
  h2.section { font-size: 1.12rem; margin: 26px 0 12px; display: flex; align-items: center; gap: 9px; }
  h2.section::after { content: ""; flex: 1; height: 1px; background: linear-gradient(90deg, rgba(255,255,255,.16), transparent); }
  h3 { font-size: 1rem; margin-bottom: 8px; color: var(--gold); }
  .lead { color: var(--muted); font-size: .9rem; margin-bottom: 14px; }
  .bodytext { font-size: .92rem; color: var(--soft); }

  .hero {
    position: relative; text-align: center; overflow: hidden;
    padding: 34px 18px 26px; margin-bottom: 16px;
    border: 1px solid rgba(255,200,61,.32); border-radius: 26px;
    background:
      radial-gradient(120% 90% at 50% 0%, rgba(255,200,61,.17), rgba(255,200,61,.03) 55%, transparent),
      linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.012));
  }
  .hero .kicker { font-size: .66rem; letter-spacing: .24em; color: var(--gold); font-weight: 700; text-transform: uppercase; }
  .hero .trophy { font-size: clamp(3rem, 14vw, 4.2rem); margin: 8px 0 0; filter: drop-shadow(0 6px 24px rgba(255,200,61,.35)); animation: float 5s ease-in-out infinite; }
  @keyframes float { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-6px); } }
  .hero .name {
    font-size: clamp(2.4rem, 12vw, 3.8rem); font-weight: 900; letter-spacing: -.02em; line-height: 1.08;
    background: linear-gradient(180deg, #fff 30%, #ffd96b); -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  .hero .chip { display: inline-block; margin-top: 10px; font-size: .74rem; font-weight: 800; color: #221703; background: linear-gradient(135deg, var(--gold), #ffaa2b); padding: 6px 15px; border-radius: 999px; letter-spacing: .04em; }
  .scoreline { display: flex; justify-content: center; align-items: center; gap: 14px; margin-top: 20px; }
  .scoreline .t { display: flex; flex-direction: column; align-items: center; gap: 1px; font-size: .82rem; font-weight: 700; min-width: 72px; }
  .scoreline .t .f { font-size: 1.7rem; }
  .scoreline .sc { font-size: 1.45rem; font-weight: 900; font-variant-numeric: tabular-nums; letter-spacing: .04em; background: rgba(255,255,255,.07); border: 1px solid var(--card-brd); padding: 5px 16px; border-radius: 13px; }
  .hero .meta { margin-top: 11px; color: var(--muted); font-size: .76rem; letter-spacing: .04em; }

  ol.args { list-style: none; counter-reset: a; }
  ol.args li { counter-increment: a; position: relative; padding: 10px 0 10px 42px; border-bottom: 1px dashed rgba(255,255,255,.08); font-size: .9rem; color: var(--soft); }
  ol.args li:last-child { border-bottom: 0; padding-bottom: 2px; }
  ol.args li::before { content: counter(a, decimal-leading-zero); position: absolute; left: 0; top: 10px; font-weight: 800; color: var(--gold); font-size: .92rem; opacity: .95; }

  .fav { display: grid; gap: 12px; }
  @media (min-width: 680px) { .fav { grid-template-columns: 1fr 1fr; } }
  .fav .card { margin: 0; }
  .fav-head { display: flex; align-items: center; gap: 10px; margin-bottom: 7px; }
  .fav-head .f { font-size: 1.7rem; }
  .fav-head .nm { font-weight: 800; font-size: 1rem; }
  .fav-head .odds { margin-left: auto; font-size: .68rem; color: var(--muted); border: 1px solid var(--card-brd); padding: 3px 9px; border-radius: 999px; white-space: nowrap; }
  .endchip { display: inline-block; font-size: .68rem; font-weight: 700; padding: 3px 11px; border-radius: 999px; margin-bottom: 8px; background: rgba(45,212,191,.12); color: var(--teal); }
  .endchip.win { background: rgba(255,200,61,.15); color: var(--gold); }
  .endchip.nl { background: rgba(255,107,26,.15); color: var(--oranje); }
  .fav p { font-size: .87rem; color: var(--soft); }

  .legend { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 12px; font-size: .72rem; color: var(--muted); }
  .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 5px; vertical-align: -1px; }
  .rail {
    display: grid; grid-auto-flow: column; grid-auto-columns: min(85vw, 330px); gap: 12px;
    overflow-x: auto; scroll-snap-type: x mandatory; -webkit-overflow-scrolling: touch;
    padding: 2px 16px 14px; margin: 0 -16px; scrollbar-width: none;
  }
  .rail::-webkit-scrollbar { display: none; }
  .rail > .card { scroll-snap-align: center; margin: 0; position: relative; overflow: hidden; }
  .swipe-hint { text-align: center; color: var(--muted); font-size: .7rem; margin-bottom: 6px; }
  @media (min-width: 900px) {
    .rail { grid-auto-flow: row; grid-template-columns: repeat(3, 1fr); overflow: visible; margin: 0; padding: 0 0 6px; }
    .swipe-hint { display: none; }
  }
  .gletter { position: absolute; right: -8px; top: -30px; font-size: 6.4rem; font-weight: 900; color: rgba(255,255,255,.04); pointer-events: none; user-select: none; }
  .grow { display: flex; align-items: center; gap: 10px; padding: 7px 0; border-bottom: 1px solid rgba(255,255,255,.06); font-size: .92rem; position: relative; }
  .grow:last-of-type { border-bottom: 0; }
  .grow .pos { width: 23px; height: 23px; border-radius: 50%; display: grid; place-items: center; font-size: .68rem; font-weight: 800; background: rgba(255,255,255,.07); color: var(--muted); flex-shrink: 0; }
  .grow.advance .pos { background: rgba(52,211,153,.17); color: var(--green); }
  .grow.third .pos { background: rgba(255,200,61,.16); color: var(--gold); }
  .grow.out { opacity: .48; }
  .grow .pts { margin-left: auto; font-weight: 800; font-variant-numeric: tabular-nums; }
  .grow.nlrow { background: linear-gradient(90deg, rgba(255,107,26,.16), transparent 80%); border-radius: 10px; padding-left: 8px; margin-left: -8px; }
  .gnote { color: var(--muted); font-size: .8rem; margin-top: 10px; }
  .thirds { display: flex; flex-wrap: wrap; gap: 8px; }
  .thirds span { font-size: .74rem; font-weight: 600; padding: 5px 12px; border-radius: 999px; border: 1px solid; }
  .thirds .in { color: var(--gold); border-color: rgba(255,200,61,.35); background: rgba(255,200,61,.07); }
  .thirds .uit { color: var(--red); border-color: rgba(248,113,113,.28); background: rgba(248,113,113,.05); opacity: .7; }

  .seg {
    position: sticky; top: var(--top-off); z-index: 20;
    display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none;
    padding: 8px 16px 10px; margin: 0 -16px 12px;
    background: linear-gradient(rgba(7,11,20,.96), rgba(7,11,20,.82));
    backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
  }
  .seg::-webkit-scrollbar { display: none; }
  .seg label {
    font-size: .78rem; font-weight: 700; cursor: pointer; user-select: none;
    color: var(--muted); background: rgba(255,255,255,.05); border: 1px solid var(--card-brd);
    padding: 8px 15px; border-radius: 999px; white-space: nowrap; min-height: 38px;
    display: inline-flex; align-items: center; transition: color .15s, background .15s;
  }
  .round-pane { display: none; }
${roundStateCss}
  .matches { display: grid; gap: 10px; }
  @media (min-width: 720px) { .matches { grid-template-columns: 1fr 1fr; } }
  .m { background: var(--card); border: 1px solid var(--card-brd); border-radius: 16px; padding: 12px 14px; transition: border-color .2s; }
  .m:hover { border-color: rgba(255,107,26,.55); }
  .m summary { cursor: pointer; list-style: none; }
  .m summary::-webkit-details-marker { display: none; }
  .m .lbl { font-size: .64rem; letter-spacing: .07em; text-transform: uppercase; color: var(--muted); display: flex; align-items: center; gap: 6px; }
  .m .lbl .chev { margin-left: auto; transition: transform .25s; font-size: .75rem; }
  .m[open] .lbl .chev { transform: rotate(180deg); }
  .m .row { display: flex; align-items: center; gap: 9px; padding: 5px 0 2px; font-size: .95rem; }
  .m .row .f { font-size: 1.3rem; }
  .m .row .n { font-weight: 600; }
  .m .row.win .n { font-weight: 800; color: var(--gold); }
  .m .row.lose { opacity: .52; }
  .m .row.nlteam .n { color: var(--oranje); }
  .m .row .s { margin-left: auto; font-weight: 800; font-size: 1.05rem; font-variant-numeric: tabular-nums; min-width: 18px; text-align: right; }
  .m .note { margin-top: 9px; padding-top: 9px; border-top: 1px dashed rgba(255,255,255,.1); color: var(--soft); font-size: .84rem; animation: fadeIn .25s ease; }
  .m.finalcard { border-color: rgba(255,200,61,.45); background: linear-gradient(160deg, rgba(255,200,61,.13), transparent 60%), var(--card); }
  .tap-hint { color: var(--muted); font-size: .72rem; text-align: center; margin-top: 10px; }

  .nl-hero { border-color: rgba(255,107,26,.45); background: radial-gradient(100% 120% at 0% 0%, rgba(255,107,26,.2), transparent 55%), var(--card); }
  .nl-hero .flag { font-size: 2.6rem; line-height: 1; }
  .nl-hero .fin { font-size: 1.25rem; font-weight: 900; margin: 6px 0 8px; color: var(--oranje); }
  .tl { margin: 4px 0 0 6px; }
  .tl-step { position: relative; padding: 0 0 20px 36px; }
  .tl-step::before { content: ""; position: absolute; left: 11px; top: 27px; bottom: 0; width: 2px; background: rgba(255,255,255,.1); }
  .tl-step:last-child { padding-bottom: 2px; }
  .tl-step:last-child::before { display: none; }
  .tl-badge { position: absolute; left: 0; top: 2px; width: 23px; height: 23px; border-radius: 50%; display: grid; place-items: center; font-size: .62rem; font-weight: 900; }
  .tl-badge.W { background: rgba(52,211,153,.18); color: var(--green); box-shadow: 0 0 0 1px rgba(52,211,153,.45); }
  .tl-badge.G { background: rgba(142,155,181,.15); color: #b6c2da; box-shadow: 0 0 0 1px rgba(142,155,181,.4); }
  .tl-badge.V { background: rgba(248,113,113,.17); color: var(--red); box-shadow: 0 0 0 1px rgba(248,113,113,.5); }
  .tl-round { font-size: .64rem; text-transform: uppercase; letter-spacing: .09em; color: var(--muted); }
  .tl-fix { font-weight: 800; margin: 2px 0; font-size: .96rem; }
  .tl-fix .res { color: var(--gold); margin-left: 7px; font-variant-numeric: tabular-nums; }
  .tl-why { font-size: .84rem; color: var(--soft); }

  .podium { display: grid; grid-template-columns: 1fr 1.12fr 1fr; gap: 8px; align-items: end; margin: 4px 0 16px; }
  .pod { text-align: center; padding: 14px 6px 12px; border-radius: 16px; border: 1px solid var(--card-brd); background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.015)); }
  .pod .medal { font-size: 1.35rem; }
  .pod .pf { font-size: 1.45rem; margin-top: 2px; }
  .pod .pn { font-weight: 800; font-size: .8rem; line-height: 1.25; margin-top: 3px; }
  .pod .pg { font-size: 1.55rem; font-weight: 900; margin-top: 2px; font-variant-numeric: tabular-nums; color: #cbd5e1; }
  .pod .pgl { font-size: .6rem; color: var(--muted); text-transform: uppercase; letter-spacing: .08em; }
  .pod.p1 { min-height: 178px; border-color: rgba(255,200,61,.5); background: linear-gradient(180deg, rgba(255,200,61,.17), rgba(255,200,61,.02)); }
  .pod.p1 .pg { color: var(--gold); font-size: 2.1rem; }
  .pod.p2 { min-height: 148px; }
  .pod.p3 { min-height: 138px; }
  .pod.p3 .pg { color: #e8a06a; }
  .ts-row { display: flex; gap: 12px; align-items: flex-start; padding: 12px 0; border-bottom: 1px solid rgba(255,255,255,.07); }
  .ts-row:last-child { border-bottom: 0; }
  .ts-row .rk { font-weight: 900; color: var(--muted); width: 20px; text-align: center; padding-top: 2px; font-variant-numeric: tabular-nums; }
  .ts-main { flex: 1; }
  .ts-name { font-weight: 800; font-size: .95rem; }
  .ts-name small { color: var(--muted); font-weight: 600; }
  .ts-note { font-size: .82rem; color: var(--soft); margin-top: 2px; }
  .ts-goals { font-weight: 900; font-size: 1.35rem; color: var(--gold); font-variant-numeric: tabular-nums; }
  .awards { display: grid; gap: 12px; }
  @media (min-width: 720px) { .awards { grid-template-columns: repeat(3, 1fr); } .awards .card { margin: 0; } }
  .awards .who { font-weight: 800; font-size: 1.02rem; margin-bottom: 4px; }
  .awards p { font-size: .84rem; color: var(--soft); }

  ol.steps { list-style: none; counter-reset: s; }
  ol.steps li { counter-increment: s; position: relative; padding: 9px 0 9px 38px; border-bottom: 1px dashed rgba(255,255,255,.08); font-size: .88rem; color: var(--soft); }
  ol.steps li:last-child { border-bottom: 0; }
  ol.steps li::before { content: counter(s); position: absolute; left: 0; top: 9px; width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-size: .72rem; font-weight: 800; color: var(--oranje); background: rgba(255,107,26,.13); }
  .pickgrid { display: grid; gap: 12px; }
  @media (min-width: 800px) { .pickgrid { grid-template-columns: repeat(3, 1fr); } .pickgrid .card { margin: 0; } }
  ul.picks { list-style: none; }
  ul.picks li { padding: 9px 0; border-bottom: 1px solid rgba(255,255,255,.07); font-size: .87rem; }
  ul.picks li:last-child { border-bottom: 0; }
  ul.picks .pp { font-weight: 800; }
  ul.picks .pt2 { color: var(--muted); font-size: .76rem; }
  ul.picks .pw { color: var(--soft); font-size: .82rem; margin-top: 2px; }
  .mult { display: inline-block; font-size: .66rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: rgba(255,200,61,.14); color: var(--gold); margin-left: 7px; vertical-align: 2px; }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation: none !important; transition: none !important; }
    html { scroll-behavior: auto; }
  }
`;

/* ── Pagina ──────────────────────────────────────────────── */

const tabRadios = TABS.map(([id], i) =>
  `<input type="radio" name="tab" id="t-${id}" class="vh"${i === 0 ? " checked" : ""}>`).join("\n");
const roundRadios = ROUNDS.map((_, i) =>
  `<input type="radio" name="round" id="r-${i}" class="vh"${i === 0 ? " checked" : ""}>`).join("\n");
const navLabels = TABS.map(([id, ico, label]) =>
  `<label for="t-${id}"><span class="ico" aria-hidden="true">${ico}</span><span class="lbl">${esc(label)}</span></label>`).join("\n");

const html = `<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<meta name="theme-color" content="#070b14">
<meta name="description" content="WK 2026 — de complete voorspelling van de agent council: wereldkampioen, alle poules, het volledige bracket, het pad van Oranje, topscorers en Scorito-advies.">
<title>WK 2026 — De Grote Voorspelling</title>
<style>${css}</style>
</head>
<body>
<div class="pitch-lines" aria-hidden="true"></div>
${tabRadios}
${roundRadios}
<header class="appbar">
  <div class="appbar-inner">
    <span class="logo" aria-hidden="true">⚽</span>
    <div class="appbar-text">
      <strong>WK 2026 · De Grote Voorspelling</strong>
      <small>${esc(F.meta.subtitle)}</small>
    </div>
    <span class="champ">🏆 ${esc(F.verdict.champion)}</span>
  </div>
</header>
<nav aria-label="Secties">
${navLabels}
</nav>
<main>
${verdictHtml()}
${poulesHtml()}
${bracketHtml()}
${nederlandHtml()}
${topscorersHtml()}
${scoritoHtml()}
</main>
<footer>${esc(F.meta.disclaimer)} · Gegenereerd: ${esc(F.meta.generatedAt)}</footer>
</body>
</html>
`;

fs.writeFileSync(path.join(__dirname, "index.html"), html);
console.log(`index.html gegenereerd: ${html.length} tekens, 100% statisch (geen <script>)`);
