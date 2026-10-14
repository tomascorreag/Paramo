// Writes tests/fixtures/voice_plan_fixture.json: the lab's plan for every line the
// coordinator can say, plus a few rule edge cases, under the coordinator's voice.
// tests/test_voice.gd builds the same lines with the GDScript port (VoicePlan) and
// compares, so the game keeps speaking exactly what the lab was tuned on.
//
// Re-run after changing voice_lab/js/{phonemes,g2p,plan}.js, the inspect lines in
// assets/translations/paramo.csv, or voice_lab/voices/coordinator.json:
//   node voice_lab/tools/make_fixture.mjs
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const lab = path.join(root, "voice_lab/js");
for (const f of ["phonemes.js", "g2p.js", "plan.js"]) (0, eval)(fs.readFileSync(path.join(lab, f), "utf8"));
const VL = globalThis.VL;
const voice = JSON.parse(fs.readFileSync(path.join(root, "voice_lab/voices/coordinator.json"), "utf8")).settings;

// ---- every voiced string, composed like ActionInspect.line_for / the FTUE narrative
function csvRows() {
  const rows = {};
  for (const line of fs.readFileSync(path.join(root, "assets/translations/paramo.csv"), "utf8").split("\n").slice(1)) {
    if (!line.trim()) continue;
    const cells = [];
    let cur = "", quoted = false;
    for (const ch of line) {
      if (ch === '"') quoted = !quoted;
      else if (ch === "," && !quoted) { cells.push(cur); cur = ""; } else cur += ch;
    }
    cells.push(cur);
    rows[cells[0]] = { en: cells[1], es: cells[2] };
  }
  return rows;
}

function voicedLines() {
  const rows = csvRows();
  const species = {};
  const dir = path.join(root, "resources/objects");
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".tres"))) {
    const t = fs.readFileSync(path.join(dir, f), "utf8");
    const key = (t.match(/name_key = &"(FLORA_\w+)"/) || [])[1];
    if (key) species[key] = +((t.match(/name_gender = (\d)/) || [0, 0])[1]);
  }
  const sentenceCase = (s) => {
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c.toUpperCase() !== c) return s.slice(0, i) + c.toUpperCase() + s.slice(i + 1);
      if (c.toLowerCase() !== c) return s;
    }
    return s;
  };
  const templates = [
    ["NEW_1", "INDEFINITE", true], ["NEW_2", "INDEFINITE", true], ["NEW_3", "INDEFINITE", true],
    ["NEW_4", "INDEFINITE", true], ["KNOWN_1", "INDEFINITE", false], ["KNOWN_2", "INDEFINITE", false],
    ["KNOWN_3", "AT_THE", false],
  ];
  const out = { en: new Set(), es: new Set() };
  for (const loc of ["en", "es"]) {
    for (const k of ["NARRATIVE_WELCOME", "NARRATIVE_CHARGE", "NARRATIVE_CLOSING"]) out[loc].add(rows[k][loc]);
    for (const [nameKey, gender] of Object.entries(species)) {
      for (const [tpl, article, canExclaim] of templates) {
        const phrase = rows[`GRAMMAR_ARTICLE_${article}_${gender ? "F" : "M"}`][loc] + " " + rows[nameKey][loc];
        const clause = rows[`NARRATIVE_INSPECT_${tpl}`][loc].replace("{0}", phrase);
        for (const p of canExclaim ? ["STATEMENT", "EXCLAMATION"] : ["STATEMENT"]) {
          out[loc].add(sentenceCase(rows[`GRAMMAR_${p}`][loc].replace("{0}", clause)));
        }
      }
    }
  }
  out.en.add("Sing, car! Is the ear here? What a magic mountain.");
  out.es.add("¿Quieres plantar frailejones? ¡Qué chévere el páramo! Hoy, muy cuidado.");
  return out;
}

// ---- the lab plan, in the shape test_voice.gd reads
const lines = voicedLines();
const cases = [];
for (const lang of ["en", "es"]) {
  for (const text of lines[lang]) {
    const plan = VL.buildPlan(text, lang, voice);
    const fr = VL.buildFrames(plan, voice);
    cases.push({
      lang, text,
      duration: plan.duration,
      segments: plan.segments.map((s) => [s.sym, s.dur]),
      stressed: plan.syllables.map((s) => (s.stressed ? 1 : 0)),
      phrases: plan.phrases.map((p) => p.type),
      // every 4th frame keeps the file small and still covers every syllable
      f0: Array.from(fr.f0).filter((_, i) => i % 4 === 0).map((x) => Math.round(x * 100) / 100),
    });
  }
}
const target = path.join(root, "tests/fixtures/voice_plan_fixture.json");
fs.writeFileSync(target, JSON.stringify({ voice: "voice_lab/voices/coordinator.json", cases }) + "\n");
console.log(`wrote ${cases.length} lines to ${path.relative(root, target)}`);
