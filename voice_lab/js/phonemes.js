// Phoneme inventory shared by every engine. One entry per sound the two
// grapheme-to-phoneme front ends can emit.
//
// F: F1/F2/F3 in Hz for an adult male; voices scale them by `formantScale`.
//   English vowels: Hillenbrand et al. 1995 men's means (American English;
//   the RP set from Wells 1962 could not be fetched). NURSE has its F3 raised
//   to 2400 because en-GB is non-rhotic and Hillenbrand's 1710 is r-coloured.
//   Spanish vowels: Bradlow 1995 F1/F2; F3 is an estimate (not in that data).
//   Consonant loci and liquids/glides are textbook approximations, not measured.
// pt: Pink Trombone articulation. tongue = [index, diameter] (zakaton's table,
//   https://github.com/zakaton/Pink-Trombone), con = [index, touch diameter]
//   for a constriction, lips = add a rounding constriction, nasal = open velum.
//   Values not in zakaton's table are guesses tuned by ear in this lab.
// fric: noise band [centre Hz, bandwidth Hz, gain] for the noise-driven sounds.
(function () {
  "use strict";

  const LOCI = {
    lab: [250, 900, 2200],
    den: [250, 1500, 2600],
    alv: [250, 1700, 2600],
    post: [250, 1900, 2500],
    pal: [250, 2200, 2900],
    vel: [250, 1900, 2300],
  };

  // Pink Trombone constriction index per place of articulation.
  const PT_PLACE = { lab: 41, den: 38, alv: 36, post: 31, pal: 27, vel: 20 };

  // Burst band per place: [centre, bandwidth, gain].
  const BURST = {
    lab: [1100, 2200, 0.55],
    den: [4500, 3000, 0.6],
    alv: [4000, 2500, 0.7],
    post: [3000, 1500, 0.75],
    pal: [3200, 1500, 0.7],
    vel: [2000, 900, 0.8],
  };

  const P = {};
  function def(sym, o) {
    P[sym] = Object.assign({ sym, voiced: true, place: null, F: null, pt: {}, fric: null }, o);
  }
  function vowel(sym, F, tongue, lips, ipa) {
    def(sym, { cls: "vowel", F, pt: { tongue, lips: !!lips }, ipa });
  }

  // English (ARPAbet-like names so they never collide with the Spanish five).
  vowel("iy", [342, 2322, 3000], [27.2, 2.2], false, "i");
  vowel("ih", [429, 2033, 2686], [26.11, 2.87], false, "ɪ");
  vowel("ey", [476, 2089, 2691], [23.5, 2.9], false, "e");
  vowel("eh", [587, 1802, 2604], [19.4, 3.43], false, "ɛ");
  vowel("ae", [591, 1930, 2595], [14.93, 2.78], false, "æ");
  vowel("aa", [756, 1308, 2534], [12.75, 2.3], false, "ɑ");
  vowel("ao", [655, 1023, 2521], [17.7, 2.05], true, "ɔ");
  vowel("ah", [621, 1181, 2547], [17.8, 2.46], false, "ʌ");
  vowel("uh", [469, 1122, 2434], [21.5, 2.45], true, "ʊ");
  vowel("uw", [379, 992, 2355], [22.8, 2.05], true, "u");
  vowel("ow", [497, 910, 2459], [17.7, 2.2], true, "o");
  vowel("er", [474, 1379, 2400], [20.7, 2.8], false, "ɜ");
  vowel("ax", [500, 1500, 2500], [20.7, 2.8], false, "ə");

  // Spanish.
  vowel("a", [638, 1353, 2500], [13.5, 2.5], false, "a");
  vowel("e", [458, 1814, 2600], [23.0, 3.0], false, "e");
  vowel("i", [286, 2147, 2900], [27.2, 2.2], false, "i");
  vowel("o", [460, 1019, 2450], [17.7, 2.3], true, "o");
  vowel("u", [322, 992, 2350], [22.8, 2.05], true, "u");

  // Centring offglide for en-GB "there", "here", "near": a schwa that does not make a syllable.
  def("aX", { cls: "glide", place: null, F: [500, 1500, 2500], pt: { tongue: [20.7, 2.8] }, ipa: "ə̯" });

  // Glides and liquids.
  def("j", { cls: "glide", place: "pal", F: [280, 2250, 2900], pt: { tongue: [28, 2.0] }, ipa: "j" });
  def("w", { cls: "glide", place: "lab", F: [300, 750, 2300], pt: { tongue: [22, 2.0], lips: true, lipD: 0.85 }, ipa: "w" });
  def("l", { cls: "liquid", place: "alv", F: [360, 1350, 2700], pt: { con: [33, 1.0] }, ipa: "l" });
  def("R", { cls: "liquid", place: "post", F: [350, 1100, 1600], pt: { con: [30, 1.15], lips: true }, ipa: "ɹ" });
  def("r", { cls: "tap", place: "alv", F: LOCI.alv, pt: { con: [36, 0.2] }, ipa: "ɾ" });
  def("rr", { cls: "trill", place: "alv", F: LOCI.alv, pt: { con: [36, 0.3] }, ipa: "r" });

  // Nasals.
  def("m", { cls: "nasal", place: "lab", F: [280, 1000, 2200], pt: { con: [PT_PLACE.lab, 0], nasal: true }, ipa: "m" });
  def("n", { cls: "nasal", place: "alv", F: [280, 1700, 2600], pt: { con: [PT_PLACE.alv, 0], nasal: true }, ipa: "n" });
  def("ny", { cls: "nasal", place: "pal", F: [280, 2200, 2900], pt: { con: [PT_PLACE.pal, 0], nasal: true }, ipa: "ɲ" });
  def("ng", { cls: "nasal", place: "vel", F: [280, 1900, 2300], pt: { con: [PT_PLACE.vel, 0], nasal: true }, ipa: "ŋ" });

  // Stops.
  for (const [sym, place, voiced] of [["p", "lab", false], ["b", "lab", true], ["t", "alv", false],
                                      ["d", "alv", true], ["k", "vel", false], ["g", "vel", true]]) {
    def(sym, { cls: "stop", place, voiced, F: LOCI[place], pt: { con: [PT_PLACE[place], 0] }, ipa: sym });
  }

  // Fricatives.
  def("f", { cls: "fric", place: "lab", voiced: false, fric: [4500, 6000, 0.28], pt: { con: [41, 0.5] }, ipa: "f" });
  def("v", { cls: "fric", place: "lab", voiced: true, fric: [4500, 6000, 0.18], pt: { con: [41, 0.55] }, ipa: "v" });
  def("th", { cls: "fric", place: "den", voiced: false, fric: [5500, 6000, 0.22], pt: { con: [38, 0.5] }, ipa: "θ" });
  def("dh", { cls: "fric", place: "den", voiced: true, fric: [5500, 6000, 0.12], pt: { con: [38, 0.6] }, ipa: "ð" });
  def("s", { cls: "fric", place: "alv", voiced: false, fric: [6500, 2500, 0.8], pt: { con: [36, 0.6] }, ipa: "s" });
  def("z", { cls: "fric", place: "alv", voiced: true, fric: [6500, 2500, 0.45], pt: { con: [36, 0.6] }, ipa: "z" });
  def("sh", { cls: "fric", place: "post", voiced: false, fric: [3000, 1600, 0.85], pt: { con: [31, 0.6], lips: true }, ipa: "ʃ" });
  def("zh", { cls: "fric", place: "post", voiced: true, fric: [3000, 1600, 0.45], pt: { con: [31, 0.6], lips: true }, ipa: "ʒ" });
  def("x", { cls: "fric", place: "vel", voiced: false, fric: [1700, 900, 0.5], pt: { con: [20, 0.5] }, ipa: "x" });
  def("J", { cls: "fric", place: "pal", voiced: true, fric: [3300, 1500, 0.2], pt: { con: [27, 0.65] }, ipa: "ʝ" });
  def("h", { cls: "aspirate", place: null, voiced: false, ipa: "h" });

  // Affricates.
  def("ch", { cls: "affric", place: "post", voiced: false, fric: [3000, 1600, 0.85], pt: { con: [31, 0] }, ipa: "tʃ" });
  def("jh", { cls: "affric", place: "post", voiced: true, fric: [3000, 1600, 0.45], pt: { con: [31, 0] }, ipa: "dʒ" });

  // Spanish lenited b/d/g between vowels: voiced approximants.
  def("B", { cls: "approx", place: "lab", F: LOCI.lab, fric: [1500, 3000, 0.05], pt: { con: [41, 0.9] }, ipa: "β" });
  def("D", { cls: "approx", place: "den", F: LOCI.den, fric: [4000, 4000, 0.05], pt: { con: [38, 0.9] }, ipa: "ð" });
  def("G", { cls: "approx", place: "vel", F: LOCI.vel, fric: [1800, 1500, 0.05], pt: { con: [20, 0.9] }, ipa: "ɣ" });

  for (const p of Object.values(P)) {
    if (!p.F && p.place) p.F = LOCI[p.place];
  }

  // Base durations in ms at speed 1.
  const DUR = { vowel: 95, glide: 55, liquid: 60, tap: 25, trill: 85, nasal: 65, stop: 70,
                fric: 85, affric: 95, aspirate: 60, approx: 50 };

  const VOWELS = {
    en: ["iy", "ih", "ey", "eh", "ae", "aa", "ao", "ah", "uh", "uw", "ow", "er", "ax"],
    es: ["a", "e", "i", "o", "u"],
  };

  globalThis.VL = globalThis.VL || {};
  Object.assign(globalThis.VL, { PHONES: P, LOCI, PT_PLACE, BURST, DUR, VOWELS });
})();
