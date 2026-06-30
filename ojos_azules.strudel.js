// Ojos Azules (Huayno) — simplified loop for game ambience
// Source: "Cajita de Musica Argentina" arrangement (verified via OMR + web).
// Key: A minor. Loop = Theme A + Theme B (the two verse phrases), 22 quarters.
// Units below are sixteenths (quarter=4); every layer sums to 88 => locked sync.
// 1 cycle = the whole loop (~18s); it repeats seamlessly. Melody is faithful to
// the score (mixed 2/4+3/4 phrasing kept); accompaniment is cleaned/simplified.
setcpm(72 / 22)   // 1 quarter = 72 BPM

// Organic huayno percussion — acoustic samples from the Dirt library, with
// per-hit randomized dynamics, pitch wobble, and sample-variant rotation.
samples('bubo:waveforms')

// Melody (flute) — Theme A then Theme B, exact rhythms from the score.
// Plays complete only once every 4 loops; the other 3 randomly skip ~40% of
// notes (dropped notes leave silence, so timing stays locked to the other layers).
const melodyNotes = note(`
  e5@2 e5@2 e5@2 g5@2   e5@4 d5@2 e5@2   c5@4 c5@2 d5@1 e5@3 e5@2   d5@4 b4@2 c5@2   a4@8
  c5@2 c5@2 c5@2 a4@2   g4@4 c5@2 d5@2   e5@4 c5@2 d5@1 e5@3 e5@2   d5@4 b4@2 c5@2   a4@8
`)
const melody = melodyNotes
  .degradeBy(0.11)              // 3 of 4 loops: drop notes at random
  .every(4, x => melodyNotes)  // every 4th loop: full melody
  .sound("gm_pan_flute").gain(0.4).attack(0.005).release(0.2).room(0.35).add(note(rand.range(-12.2, -11.8)))

// Chords — ritmo de huayno as a SINGLE-NOTE riff (no chords): the cell is a
// corchea + dos semicorcheas (eighth + two sixteenths). Per beat: the root on
// the downbeat (bam, an eighth) + the 3rd & 5th as the two sixteenths (ba, da).
// Looped it reads "...ba-da-BAM...". Harmony: Am E7 Am C E7 Am | Am G7 C E7 Am.
const chords = note(`
  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1
  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1
  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1   c4@2 e4@1 g4@1
  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1
  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1
  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1
  g3@2 b3@1 d4@1   g3@2 b3@1 d4@1
  c4@2 e4@1 g4@1   c4@2 e4@1 g4@1   c4@2 e4@1 g4@1
  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1
  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1
`).sound("gm_acoustic_guitar_nylon").gain(0.2).attack(0.001).release(0.14).cutoff(1600).resonance(6).room(0.4).add(note(12))//.octave(choose(0,1))

// Bass — chord roots on the beat
const bass = note(`
  a2@4 a2@4   e2@4 e2@4   a2@4 a2@4 c3@4   e2@4 e2@4   a2@4 a2@4
  a2@4 a2@4   g2@4 g2@4   c3@4 c3@4 c3@4   e2@4 e2@4   a2@4 a2@4
`).sound("gm_acoustic_bass").gain(0.75).release(0.3).add(note(-12))



// Bombo — round low kick on every beat (the anchor; kept solid)
const bombo = sound("bd").bank("AkaiMPC60").fast(11)
  .speed(0.9)
  .gain(rand.range(0.3, 0.5)).room(0.2)

// Wood "ti-ki" gallop on the off-beats (triplet lilt), pitch + sample varied
const ticks = sound("~ bd bd").fast(22)
  .gain(rand.range(0.15, 0.2))
  .speed(rand.range(0.94, 1.08)).room(0.15)

// Open hat on each bar's downbeat + a kick pickup that turns the loop
const accents = sound(`
  cr@8 oh@8 oh@12 rd@8 rd@8
  oh@8 oh@8 oh@12 rd@8 rd@4 bd@2 bd@2
`).gain(rand.range(0.05, 0.1)).room(0.3)

// Sesquialtera (3:2 hemiola) — the Andean "tripleta": a wood triplet (6/8 feel)
// against a metallic duple (3/4 feel), one cell per 2 beats. The cross-rhythm
// between the two — not a straight pulse — is what reads as huayno.
const sesq = stack(
  sound("sh*3").gain(rand.range(0.1, 0.2)).speed(rand.range(0.96, 1.06)).octave(2), // the "3"
  sound("sh*2").gain(rand.range(0.2, 0.4)).speed(rand.range(1.15, 1.25))                     // the "2"
).fast(22).room(0.2).degradeBy(0.25)

stack(bass, chords, melody, bombo, ticks, accents, sesq)
