// Ojos Azules (Huayno) - Cajita de Musica Argentina [OMR draft] -- generated from sources/CAJITAHUAYNOOjosazulesGENERAL.mxl by xml_to_strudel.py
// 5 part(s), bpm=72, total=178.5 quarters. Meter-agnostic: notes laid by exact duration, whole piece = 1 cycle.
setcpm(0.40336)

// Flute
const p_Flute = note(`
  e5@6 e5@6 e5@6 g5@6
  e5@12 d5@6 e5@6
  g4@12 c5@12
  d5@12 b4@6 c5@6
  a4@24
  ~@120 c5@6 c5@6 c5@6 a4@6
  g4@12 c5@6 d5@6
  e5@12 c5@6 d5@3 e5@9 e5@6
  d5@12 b4@6 c5@6
  a4@24
  ~@48 g4@12
  ~@84 e5@6 e5@6 e5@6 g5@6
  e5@12 d5@6 e5@6
  c5@12 c5@6 d5@3 e5@9 e5@6
  d5@12 b4@6 c5@6
  a4@24
  e5@6 e5@6 e5@6 g5@6
  e5@12 d5@6 e5@6
  c5@12 c5@6 d5@3 e5@9 e5@6
  d5@12 b4@6 c5@6
  a4@24
  c5@6 c5@6 c5@6 a4@6
  g4@12 c5@6 d5@6
  e5@12 c5@6 d5@3 e5@9 e5@6
  d5@12 b4@6 c5@6
  a4@24
  c5@6 c5@6 c5@6 a4@6
  g4@12 c5@6 d5@6
  e5@12 c5@6 d5@3 e5@9 e5@6
  d5@12 b4@6 c5@6
  a4@24
  ~@264 e6@6 e6@6 e6@6 g6@6
  e6@12 d6@6 e6@6
  c6@12 c6@6 d6@3 e6@9 e6@6
  d6@12 b5@6 c6@6
  a5@24
  e6@6 e6@6 e6@6 g6@6
  e6@12 d6@6 e6@6
  c6@12 c6@6 d6@3 e6@9 e6@6
  d6@12 b5@6 c6@6
  a5@24
  c6@6 c6@6 c6@6 a5@6
  g5@12 c6@6 d6@6
  e6@12 c6@6 d6@3 e6@9 e6@6
  d6@12 b5@6 c6@6
  a5@24 c6@6 c6@6 c6@6 a5@6
  g5@12 c6@6 d6@6
  e6@12 c6@6 d6@3 e6@9 e6@6
  d6@12 b5@6 c6@6
  a5@36
  b5@6 c6@6
  a5@48
  ~@234
`)
  .sound("triangle").gain(0.9).release(0.25).room(0.3)

// PianoRH
const p_PianoRH = note(`
  ~@120 [g4,e5]@6 [g4,e5]@6 [g4,e5]@6 [c5,g5]@6
  [g4,e5]@12 [g4,d5]@6 [g4,e5]@6
  [e4,c5]@12 [e4,c5]@6 [f4,d5]@3 e5@3 [g4,e5]@6 [g4,e5]@3 [g4,e5]@3
  [f4,d5]@12 [d4,b4]@6 [e4,c5]@6
  [c4,a4]@24
  ~@132 [f4,c5]@6 [f4,c5]@6 [f4,c5]@6 [c4,a4]@6
  [c4,g4]@12 [f4,c5]@6 [f4,d5]@6
  ~@24 [f4,d5]@12 [d4,b4]@6 [e4,c5]@6
  a4@24
  ~@24 [a3,c4]@9 [a3,c4]@3 a3@9 a3@3
  a3@9 a3@3 [b3,d4]@9 [b3,d4]@3
  [c4,e4]@9 [c4,e4]@3 [c4,e4]@9 [c4,e4]@3 [c4,e4]@9 [c4,e4]@3
  [b3,d4]@9 [b3,d4]@3 b3@6 [c4,d4]@6 e4@6
  ~@12 [a3,c4]@12 a3@3
  [a3,c4]@9 [a3,c4]@3 a3@9 a3@3
  a3@9 a3@3 [b3,d4]@9 [b3,d4]@3
  g4@12 [c4,e4]@9 [c4,e4]@3
  [b3,d4]@9 [b3,d4]@3 [b3,d4]@6 [c4,e4]@6
  ~@9 a3@3 [a3,c4]@12 a3@6 a3@3
  [a3,c4]@9 [a3,c4]@3 [a3,c4]@9 [a3,c4]@3
  b3@6 b3@3 b3@3 [b3,c4]@6 [b3,d4]@6
  [c4,e4]@9 [c4,e4]@3 [c4,e4]@9 [c4,e4]@12 [c4,e4]@3
  [b3,d4]@9 [b3,d4]@3 [b3,d4]@6 [c4,e4]@6
  ~@9 a3@3 [a3,c4]@9 [a3,c4]@3
  [a3,c4]@9 [a3,c4]@3 [a3,c4]@9 [a3,c4]@3
  b3@6 b3@3 b3@3 [b3,c4]@6 [b3,d4]@6
  [c4,e4]@9 [c4,e4]@3 [c4,e4]@9 [c4,e4]@12 [c4,e4]@3
  [b3,d4]@9 [b3,d4]@3 [b3,d4]@6 [c4,e4]@6
  ~@12 [c4,a4]@4 [c4,c5]@2 [e4,c5]@2 [e4,a4]@4 c4@6
  [c4,e4,g4]@4 [c4,e4]@4 [c4,d4,e4]@4 [b3,e4]@4 [b3,d4]@4 [b3,c4]@4 c4@2
  c4@4 a3@4 ~@4 c4@4 [b3,d4]@4 [c4,e4]@4
  [c4,e4,a4]@4 [c4,e4,g4]@4 [c4,e4]@4 [b3,d4]@4 [b3,g4]@4 [b3,e4]@4 e4@12
  c4@3 d4@4 [d4,e4]@4 [d4,g4]@4
  [c4,f4,b4]@4 [c4,f4,a4]@4 [c4,f4]@4 [c4,a4]@4 [d4,b4]@4 c5@4
  e4@4 [c4,e4,a4]@2 [c4,a4]@6 [c4,e4]@4 e4@2 [e4,a4]@6 b4@6
  [e4,a4,c5]@4 [e4,a4,b4]@4 [e4,a4,c5]@4 [e4,a4,d5]@12
  ~@117 c4@3 e4@3
  ~@21 a3@3 [a3,e4]@3
  ~@21 a3@3 [a3,e4]@3 ~@6 a3@3 e4@3
  ~@21 f3@3 [f3,c4]@3 ~@6 a3@3 d4@3
  ~@6 a3@3 c4@3 [a3,e4]@4 [a3,a4]@2 [c4,a4]@2 [c4,b4]@4 d4@6
  ~@3 [c4,a4,c5]@6 [c4,a4,c5]@3 ~@3 [b3,g4,b4]@6 [b3,g4,b4]@3
  ~@3 [a3,f4,a4]@6 [a3,f4,a4]@3 ~@3 [g3,e4,g4]@6 [g3,e4,g4]@3
  ~@3 [a3,f4,a4]@6 [a3,f4,a4]@3 ~@3 [a3,f4,a4]@6 [a3,f4,a4]@3 ~@3 [g3,e4,g4]@6 [g3,e4,g4]@3
  ~@3 [f3,d4,f4]@6 [f3,d4,f4]@3 ~@3 [a3,c4,e4]@9 [a3,c4,e4]@3
  ~@9 e4@3 [e4,a4]@4 [e4,c5]@4 [e4,e5]@4
  ~@3 [c4,a4,c5]@12 [c4,a4,c5]@4 [f4,a4,c5]@4 [a4,c5]@4
  [c4,a4,c5]@9 [c4,a4,c5]@3 [c4,a4,c5]@6 [d4,b4,d5]@6
  [e4,c5,e5]@12 [c5,e5]@12 ~@6 e4@4 g4@4 c5@4
  [b4,d5]@12 a4@4 e5@4 a5@4
  ~@6 [a4,c5]@3 [a4,e5]@3 [a4,c5]@3 [g4,b4]@4 [f4,a4]@4 [e4,g4]@4 [c4,a4,c5]@12 [c4,a4,c5]@4 [f4,a4,c5]@4 [a4,c5]@4
  [c4,a4,c5]@9 [c4,a4,c5]@3 [c4,a4,c5]@6 [d4,b4,d5]@6
  [e4,c5,e5]@12 [e4,c5,e5]@4 [g4,c5,e5]@4 [c5,e5]@4 [e4,c5,e5]@9 [e4,c5,e5]@3
  [b4,d5]@12 ~@18 a4@4 e5@4 a5@4
  ~@3 [c4,a4,c5]@3 [c4,a4,c5]@3 [c4,a4,c5]@3 [b3,g4,b4]@3 [b3,g4,b4]@3 [b3,g4,b4]@3
  ~@6 [a3,f4,a4]@3 [a3,f4,a4]@3 [a3,f4,a4]@3 ~@3 [g3,e4,g4]@3 [g3,e4,g4]@3 [g3,e4,g4]@3
  ~@3 [a3,f4,a4]@3 [a3,f4,a4]@3 [a3,f4,a4]@3 [g3,e4,g4]@6 [g3,e4,g4]@3
  ~@6 [f3,d4,f4]@3 [f3,d4,f4]@3 [f3,d4,f4]@3 [a3,d4,e4]@6 [a3,d4,e4]@3
  ~@3 [c4,a4]@6 [c4,a4]@6 a4@12
  c4@24
  ~@88
`)
  .sound("sawtooth").gain(0.45).release(0.25).room(0.3)

// PianoLH
const p_PianoLH = note(`
  ~@120 c4@6 c4@6 c4@6 e4@6
  c4@12 b3@6 c4@6
  a3@12 a3@6 b3@3 c4@9 c4@6
  b3@12 e3@12
  a3@24
  ~@132 a3@6 a3@6 a3@6 f3@6
  e3@12 a3@6 b3@6
  b2@24
  b3@12 e3@12
  a2@24
  ~@24 a2@6 [a2,e3]@12 [a2,e3]@6
  a2@6 [a2,e3]@6 e2@6 [e2,e3]@6
  a2@6 [a2,e3]@6 c3@6 [c3,g3]@12 [c3,g3]@6
  e2@12 [e2,e3]@12 e3@6
  a2@6 [a2,e3]@12 [a2,e3]@6
  ~@9 e3@12 e3@6
  a2@6 [a2,e3]@6 e2@6 [e2,e3]@6
  b2@12 [a2,b2]@6 [a2,b2,e3]@6
  ~@6 e3@18
  ~@6 e3@12 e3@6
  ~@9 f2@6 [f2,c3]@12 [f2,c3]@6
  g2@6 [g2,f3]@12 [g2,f3]@6
  ~@6 g3@12 g3@6 c3@12
  ~@6 e3@18
  ~@6 e3@12 e3@6
  f2@6 [f2,c3]@12 [f2,c3]@6
  g2@6 [g2,f3]@12 [g2,f3]@6
  ~@6 g3@12 g3@6 c3@12
  ~@6 e3@18
  ~@6 e3@3 [e3,a3]@15
  ~@6 f2@4 [f2,c3]@4 [f2,a3]@4 g2@6 [g2,e3]@6
  ~@2 a2@6 [a2,e3]@3 [a2,a3]@15
  d3@6 [d3,f3]@6 g2@6 [g2,f3]@6
  c3@12 g3@3 [b2,g3]@3 b2@9
  a2@6 [a2,f3]@18
  a2@6 [a2,e3]@3 [a2,a3]@3 [a2,a3]@6 [g2,a3]@6
  ~@6 f2@12 e2@12
  a2@24
  a2@24
  a2@24
  ~@24 a2@12 e3@9
  ~@6 f2@12 c3@9
  ~@6 f2@12 c3@9 ~@6 f2@12
  d2@12 a2@9 ~@6 e2@3 [e2,b2]@6 e2@3
  ~@6 e3@6 e3@6 e3@6
  ~@6 a2@3 [a2,e3]@3 [a2,e3]@6 g2@3 [g2,e3]@3 [g2,e3]@6
  f2@3 [f2,c3]@3 [f2,c3]@6 e2@3 [e2,c3]@3 [e2,c3]@6
  f2@3 [f2,c3]@3 [f2,c3]@6 f2@3 [f2,c3]@3 [f2,c3]@6 e2@3 [e2,c3]@3 [e2,c3]@6
  d2@3 [d2,a2]@3 [d2,a2]@6 e2@3 [e2,b2]@3 [e2,b2]@6
  ~@3 a2@6 [a2,e3]@3 [a2,e3,c4]@15 [e3,c4]@3
  f2@6 [f2,c3]@3 [f2,a3]@15
  g2@6 [g2,f3]@18
  c3@24 g3@3 c4@15
  e3@6 [e3,b3]@3 [e3,d4]@15
  a2@6 a2@3 [a2,e3]@12 [a2,e3]@3 e3@3 f2@6 [f2,c3]@3 [f2,a3]@15
  g2@6 [g2,f3]@18
  ~@6 g3@3 c4@15 c3@12
  e3@24 b3@3 d4@15
  a2@3 [a2,e3]@3 [a2,e3]@6 [g2,e3]@6 [g2,e3]@3 g2@3
  f2@3 [f2,c3]@3 [f2,c3]@6 e2@3 [e2,c3]@3 [e2,c3]@6
  f2@3 [f2,c3]@3 [f2,c3]@6 [e2,c3]@6 [e2,c3]@3 e2@3
  d2@3 [d2,a2]@3 [d2,a2]@6 [e2,b2]@6 [e2,b2]@3 e2@3
  [a2,e3]@6 [a2,e3]@6 e3@12
  a2@24
  ~@88
`)
  .sound("square").gain(0.45).release(0.25).room(0.3)

// Guitar
const p_Guitar = note(`
  ~@120 c6@6 c6@6 c6@6 e6@6
  c6@12 b5@6 c6@6
  a5@12 a5@6 b5@3 c6@9 c6@6
  b5@12 b5@6 c6@6
  a5@24
  ~@120 a5@6 a5@6 a5@6 f5@6
  e5@12 a5@6 b5@6
  c6@12 a5@6 b5@3 c6@9 c6@6
  b5@12 b5@6 c6@6
  ~@48 a3@6 e4@3 c5@3 a3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 e3@6 e4@3 b4@3
  a3@6 e4@3 c5@3 c4@6 g4@3 e5@3
  e3@6 e4@3 b4@3 e3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 a3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 a3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 e3@6 e4@3 b4@3
  g4@12 a3@6 e4@3 c5@3
  e3@6 e4@3 b4@3 e3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 a3@6 e4@3 c5@3
  f3@6 c4@3 a4@3 f3@6 c4@3 a4@3
  g3@6 d4@3 b4@3 g3@6 d4@3 b4@3
  c4@6 g4@3 e5@3 c4@6 g4@3 e5@3
  e3@6 e4@3 b4@3 e3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 a3@6 e4@3 c5@3
  f3@6 c4@3 a4@3 f3@6 c4@3 a4@3
  g3@6 d4@3 b4@3 g3@6 d4@3 b4@3
  c4@6 g4@3 e5@3 c4@6 g4@3 e5@3
  e3@6 e4@3 b4@3 e3@6 e4@3 c5@3
  a3@6 e4@3 c5@3 e5@4 a5@4 e5@4
  e5@4 c5@4 b4@4 c5@4 b4@4 a4@8
  e4@4 ~@4 a4@4 b4@4 c5@4
  c5@4 b4@4 g4@4 f4@4 b4@4 c5@4
  c5@12 d5@4 g5@4 b5@4
  d6@4 c6@4 a5@4 c6@4 d6@4 e6@10
  c6@12 a5@4 c6@4 d6@4
  e6@4 d6@4 e6@4 d6@4 c6@4 a5@76
  ~@828 [a3,e4,a4,c5]@6 [a3,e4,a4,c5]@6 [a3,e4,a4,c5]@12
  ~@36
`)
  .sound("sine").gain(0.45).release(0.25).room(0.3)

// Perc
const p_Perc = sound(`
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@12 bd@12
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@4 bd@4 bd@4 bd@12
  bd@12 bd@6 bd@6
  bd@4 bd@4 bd@4 bd@4 bd@4 bd@4
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@12 bd@12
  bd@12 bd@12
  bd@12 bd@6 bd@6
  bd@24
  bd@12 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@4 bd@4 bd@4 bd@4 bd@4 bd@4
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@12 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@6
  bd@12
  ~@180 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@4 bd@4 bd@4 bd@4 bd@4 bd@4
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  ~@4 bd@4 bd@4 bd@4 bd@4 bd@4
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@4 bd@4 bd@4
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@4 bd@4 bd@4
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@4 bd@4 bd@4 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@3 bd@3 bd@6 bd@3 bd@3
  bd@6 bd@6 bd@6 bd@4 bd@4 bd@4
  bd@6 bd@6 bd@12
  ~@264
`).gain(0.45).room(0.2)

stack(
  p_Flute,
  p_PianoRH,
  p_PianoLH,
  p_Guitar,
  p_Perc
)