// Grapheme-to-phoneme front ends. Spanish (es-CO) is close to rule-complete
// because its spelling is close to phonemic. English (en-GB, non-rhotic) is
// a rough letter/digraph rule set plus a small dictionary of very common words:
// enough for babble that "follows" the text, not a real TTS front end.
//
// Output: tokens, each either
//   { type: "word", text, phones: [{ sym, ci, accent }], func, wh, lastLetter, stressHint }
//   { type: "punct", ch, ci }
// `ci` is the source character index (drives the typewriter preview).
(function () {
  "use strict";

  const FUNC_WORDS = {
    en: new Set(("a an the to of and or but in on at for with from by is are was were be been it its as " +
                 "that this i you he she we they me him her us them my your his our their do does did have " +
                 "has had will would can could should so if am").split(" ")),
    es: new Set(("el la los las un una unos unas de del y o e u en con por para que se me te lo le les " +
                 "nos mi mis tu tus su sus al a sin").split(" ")),
  };

  // Interrogatives that make a question a wh-question (falling contour).
  const WH = {
    en: new Set(["what", "where", "when", "why", "who", "whom", "whose", "which", "how"]),
    es: new Set(["qué", "quién", "quiénes", "cómo", "dónde", "adónde", "cuándo", "cuál", "cuáles",
                 "cuánto", "cuánta", "cuántos", "cuántas", "por qué"]),
  };

  const ACCENTED = { "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u" };
  const isSpVowelLetter = (c) => "aeiouáéíóúü".includes(c);
  const baseLetter = (c) => ACCENTED[c] || c;

  // ---------------------------------------------------------------- Spanish
  function spanishWord(w, ci0) {
    const out = [];
    const push = (sym, ci, accent) => out.push({ sym, ci: ci0 + ci, accent: !!accent });
    const n = w.length;
    for (let i = 0; i < n; i++) {
      const c = w[i], nx = w[i + 1] || "", nx2 = w[i + 2] || "";
      const front = (ch) => ch !== "" && "eéií".includes(ch);
      if (isSpVowelLetter(c)) {
        push(baseLetter(c), i, c in ACCENTED && c !== "ü");
        continue;
      }
      switch (c) {
        case "c":
          if (nx === "h") { push("ch", i); i++; }
          else if (front(nx)) push("s", i);
          else push("k", i);
          break;
        case "q":
          push("k", i);
          if (nx === "u") i++;
          break;
        case "g":
          if (front(nx)) push("x", i);
          else if (nx === "u" && front(nx2)) { push("g", i); i++; }
          else push("g", i);
          break;
        case "l":
          if (nx === "l") { push("J", i); i++; } else push("l", i);
          break;
        case "r": {
          const prev = w[i - 1] || "";
          if (nx === "r") { push("rr", i); i++; }
          else if (i === 0 || "nls".includes(prev)) push("rr", i);
          else push("r", i);
          break;
        }
        case "ñ": push("ny", i); break;
        case "j": push("x", i); break;
        case "z": push("s", i); break;   // seseo
        case "v": push("b", i); break;
        case "h": break;                 // silent
        case "x": push("k", i); push("s", i); break;
        case "y":
          if (n === 1 || i === n - 1) push("i", i);   // "y", "hoy", "muy"
          else push("J", i);
          break;
        case "w": push("w", i); break;
        default:
          if ("bdfkmnpst".includes(c)) push(c, i);
      }
    }
    // Unaccented i/u next to another vowel become glides (diphthongs).
    const isV = (p) => p && "aeiou".includes(p.sym) && p.sym.length === 1;
    for (let k = 0; k < out.length; k++) {
      const p = out[k];
      if ((p.sym !== "i" && p.sym !== "u") || p.accent) continue;
      const nx = out[k + 1], pv = out[k - 1];
      if ((isV(nx) && nx.sym !== p.sym) || (isV(pv) && pv.sym !== p.sym)) {
        p.sym = p.sym === "i" ? "j" : "w";
      }
    }
    // b/d/g lenite to approximants after anything but a nasal (and d after l).
    for (let k = 1; k < out.length; k++) {
      const p = out[k], pv = out[k - 1];
      const afterNasal = ["m", "n", "ny", "ng"].includes(pv.sym);
      if (afterNasal) continue;
      if (p.sym === "b") p.sym = "B";
      else if (p.sym === "g") p.sym = "G";
      else if (p.sym === "d" && pv.sym !== "l") p.sym = "D";
    }
    // n before a labial or velar assimilates.
    for (let k = 0; k + 1 < out.length; k++) {
      if (out[k].sym !== "n") continue;
      const nx = out[k + 1].sym;
      if (["p", "b", "B", "m"].includes(nx)) out[k].sym = "m";
      else if (["k", "g", "G", "x"].includes(nx)) out[k].sym = "ng";
    }
    return out;
  }

  // ---------------------------------------------------------------- English
  // Hand-written entries for the commonest words, where the rules below fail.
  const EN_DICT = {
    the: "dh ax", a: "ax", i: "aa j", you: "j uw", to: "t uw", of: "ax v", and: "ae n d",
    is: "ih z", are: "aa", was: "w ao z", what: "w ao t", one: "w ah n", two: "t uw",
    have: "h ae v", do: "d uw", does: "d ah z", said: "s eh d", there: "dh eh aX",
    their: "dh eh aX", where: "w eh aX", here: "h ih aX", beautiful: "b j uw t ih f ax l", my: "m aa j", by: "b aa j",
    he: "h iy", she: "sh iy", we: "w iy", me: "m iy", be: "b iy", no: "n ax w", go: "g ax w",
    so: "s ax w", oh: "ax w", hello: "h ax l ax w", water: "w ao t ax", fire: "f aa j ax",
    people: "p iy p ax l", come: "k ah m", some: "s ah m", done: "d ah n", love: "l ah v",
    who: "h uw", why: "w aa j", how: "h aa w", now: "n aa w", know: "n ax w", eye: "aa j",
    could: "k uh d", would: "w uh d", should: "sh uh d", put: "p uh t", good: "g uh d",
    look: "l uh k", book: "b uh k", any: "eh n iy", many: "m eh n iy", again: "ax g eh n",
    very: "v eh R iy", yes: "j eh s", okay: "ax w k ey j", ok: "ax w k ey j",
    flower: "f l aa w ax", flowers: "f l aa w ax z", plant: "p l aa n t", plants: "p l aa n t s",
    mountain: "m aa w n t ax n", rain: "R ey j n", today: "t ax d ey j", they: "dh ey j",
    from: "f R ao m", for: "f ao", your: "j ao", our: "aa w ax", were: "w er", been: "b iy n",
  };
  // Words whose stress the suffix/prefix rules get wrong: syllable index.
  const EN_STRESS = { hello: 1, again: 1, okay: 1, ok: 1, today: 1, about: 1, above: 1, along: 1 };
  const DH_WORDS = new Set(["the", "this", "that", "these", "those", "they", "them", "their", "there",
                            "then", "than", "though", "thus", "with", "other", "mother", "father", "brother"]);

  function englishWord(w, ci0) {
    if (EN_DICT[w]) {
      return EN_DICT[w].split(" ").map((sym) => ({ sym, ci: ci0, accent: false }));
    }
    const out = [];
    const push = (sym, ci) => out.push({ sym, ci: ci0 + ci, accent: false });
    const n = w.length;
    // c !== "": "aeiou".includes("") is true, which made "past the end" read as a vowel.
    const isV = (c) => c !== "" && "aeiou".includes(c);
    const isVy = (c, i) => isV(c) || (c === "y" && i > 0);
    const at = (i) => w[i] || "";
    const lastSym = () => (out.length ? out[out.length - 1].sym : "");

    // Silent final e: "make", "hope" (but not "he", "the", "be").
    const silentE = n > 2 && w[n - 1] === "e" && !isV(w[n - 2]) && w[n - 2] !== "l";
    // Magic-e: V C e# lengthens V. Also V C es# / V C ed#.
    let magicIdx = -1;
    {
      const m = w.match(/([aeiou])([^aeiouwy])e[sd]?$/);
      if (m && n > 2) magicIdx = w.length - m[0].length;
    }

    for (let i = 0; i < n; i++) {
      const c = w[i], nx = at(i + 1), nx2 = at(i + 2), pv = at(i - 1);
      // ---- multi-letter units first
      const rest = w.slice(i);
      if (rest.startsWith("tion") || rest.startsWith("sion")) { push("sh", i); push("ax", i + 1); push("n", i + 3); i += 3; continue; }
      if (rest.startsWith("tch")) { push("ch", i); i += 2; continue; }
      if (rest.startsWith("dge")) { push("jh", i); i += 2; continue; }
      if (rest.startsWith("igh")) { push("aa", i); push("j", i); i += 2; continue; }
      if (rest.startsWith("ough")) { push("ao", i); i += 3; continue; }
      if (i === n - 2 && rest === "le" && n > 3 && !isV(pv)) { push("ax", i); push("l", i); i += 1; continue; }
      if (i === n - 2 && rest === "ed" && n > 3) {
        const p = lastSym();
        if (p === "t" || p === "d") { push("ih", i); push("d", i + 1); }
        else if (["p", "k", "f", "s", "sh", "ch", "th"].includes(p)) push("t", i + 1);
        else push("d", i + 1);
        i += 1; continue;
      }
      if (c === "c" && nx === "h") { push("ch", i); i++; continue; }
      if (c === "s" && nx === "h") { push("sh", i); i++; continue; }
      if (c === "t" && nx === "h") { push(DH_WORDS.has(w) ? "dh" : "th", i); i++; continue; }
      if (c === "p" && nx === "h") { push("f", i); i++; continue; }
      if (c === "w" && nx === "h") { push("w", i); i++; continue; }
      if (c === "c" && nx === "k") { push("k", i); i++; continue; }
      if (c === "q" && nx === "u") { push("k", i); push("w", i + 1); i++; continue; }
      if (i === 0 && c === "w" && nx === "r") { push("R", i); i++; continue; }
      if (i === 0 && c === "k" && nx === "n") { push("n", i); i++; continue; }
      if (c === "g" && nx === "h") { i++; continue; }
      if (c === "n" && nx === "g" && !isV(nx2)) { push("ng", i); i++; continue; }
      if (c === "n" && nx === "k") { push("ng", i); continue; }

      // ---- vowels (with r-colouring dropped: en-GB is non-rhotic)
      if (isV(c) || (c === "y" && i > 0)) {
        if (c === "e" && i === n - 1 && silentE) continue;
        if (c === "e" && i === n - 1 && n <= 3) { push("iy", i); continue; }
        // two-letter vowel units
        const two = c + nx;
        const vv = { ee: "iy", ea: "iy", ie: "iy", ei: "iy", oo: "uw", ai: "ey j", ay: "ey j", oi: "ao j",
                     oy: "ao j", au: "ao", aw: "ao", oa: "ow w", ue: "j uw", ew: "j uw", ui: "uw", ou: "aa w",
                     ow: (i + 2 === n && n > 3) ? "ow w" : "aa w", ey: "ey j" }[two];
        if (vv && c !== "y") {
          const afterR = at(i + 2) === "r" && !isVy(at(i + 3), i + 3);
          if (afterR) {
            const rv = { ea: "ih aX", ee: "ih aX", ai: "eh aX", oo: "ao", ou: "ao", oa: "ao" }[two] || vv;
            rv.split(" ").forEach((s) => push(s, i));
            i += 2; continue;
          }
          vv.split(" ").forEach((s) => push(s, i));
          i += 1; continue;
        }
        // r-coloured single vowel
        if (nx === "r" && !isVy(nx2, i + 2)) {
          const rv = { a: "aa", e: "er", i: "er", o: "ao", u: "er", y: "er" }[c];
          rv.split(" ").forEach((s) => push(s, i));
          i += 1; continue;
        }
        if (c === "y") {
          // word-final y: "happy" -> iy, "my/fly/sky" (one vowel letter) -> aa j
          if (i === n - 1) {
            const otherVowel = /[aeiou]/.test(w.slice(0, i));
            if (otherVowel) push("iy", i); else { push("aa", i); push("j", i); }
          } else if (!isV(pv) && i > 0) push("ih", i);
          else push("j", i);
          continue;
        }
        if (i === magicIdx) {
          ({ a: "ey j", e: "iy", i: "aa j", o: "ax w", u: "j uw" })[c].split(" ").forEach((s) => push(s, i));
          continue;
        }
        if (c === "a" && (rest.startsWith("all") || rest.startsWith("alk") || lastSym() === "w")) { push("ao", i); continue; }
        push({ a: "ae", e: "eh", i: "ih", o: "ao", u: "ah" }[c], i);
        continue;
      }

      // ---- single consonants
      if (c === pv && !isV(c)) continue;  // doubled consonant
      switch (c) {
        case "c": push((nx !== "" && "eiy".includes(nx)) ? "s" : "k", i); break;
        case "g":
          if (nx === "e" && i === n - 2) push("jh", i);
          else push("g", i);
          break;
        case "j": push("jh", i); break;
        case "x": push("k", i); push("s", i); break;
        case "y": push("j", i); break;
        case "r": push("R", i); break;
        case "s": {
          const prevSym = lastSym();
          const voicedPrev = prevSym && !["p", "t", "k", "f", "th", "s", "sh", "ch"].includes(prevSym);
          if ((i === n - 1 && voicedPrev && n > 2) || (isV(pv) && isV(nx) && i > 0)) push("z", i);
          else push("s", i);
          break;
        }
        default:
          if ("bdfhklmnptvwz".includes(c)) push(c, i);
      }
    }
    return out;
  }

  function englishStressHint(w) {
    if (w in EN_STRESS) return { index: EN_STRESS[w] };
    if (/(tion|sion|cian|ic|ical)$/.test(w)) return { fromEnd: /ical$/.test(w) ? 2 : 1 };
    if (/(ity|ety)$/.test(w)) return { fromEnd: 2 };
    if (w.length > 4 && /^(be|de|re|un|ex|con|com|pre|a)[^aeiou]/.test(w)) return { index: 1 };
    return { index: 0 };
  }

  // ---------------------------------------------------------------- tokenizer
  function tokenize(text, lang) {
    const tokens = [];
    const re = /([\p{L}']+)|([.,;:!?¿¡…\-—])/gu;
    let m;
    const lower = text.toLowerCase();
    while ((m = re.exec(lower)) !== null) {
      if (m[1]) {
        const raw = m[1].replace(/'/g, "");
        if (!raw) continue;
        const ci0 = m.index;
        // English copy borrows Spanish words ("páramo"); its rules only know plain vowels.
        const phones = lang === "es" ? spanishWord(raw, ci0)
                                     : englishWord(raw.replace(/[áéíóúü]/g, (c) => ACCENTED[c]), ci0);
        if (!phones.length) continue;
        tokens.push({
          type: "word", text: raw, phones, ci: ci0, end: ci0 + m[1].length,
          func: FUNC_WORDS[lang].has(raw),
          wh: WH[lang].has(raw),
          lastLetter: baseLetter(raw[raw.length - 1]),
          stressHint: lang === "en" ? englishStressHint(raw) : null,
        });
      } else {
        tokens.push({ type: "punct", ch: m[2], ci: m.index });
      }
    }
    // Spanish "por qué" is a two-word interrogative.
    for (let k = 0; k + 1 < tokens.length; k++) {
      if (tokens[k].text === "por" && tokens[k + 1].text === "qué") tokens[k].wh = true;
    }
    return tokens;
  }

  Object.assign(globalThis.VL, { tokenize, FUNC_WORDS });
})();
