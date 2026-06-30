// Headless check that a Strudel mini-notation pattern parses and yields the
// expected note/timing haps. Usage: node verify.mjs '<pattern string>' [cycles]
import { mini } from '@strudel/mini';
import '@strudel/core';

const pat = process.argv[2];
const cycles = Number(process.argv[3] ?? 2);
try {
  const p = mini(pat);
  const haps = p.queryArc(0, cycles);
  console.log(`OK parsed. ${haps.length} haps over ${cycles} cycle(s):`);
  for (const h of haps) {
    const b = h.whole?.begin ?? h.part.begin;
    const e = h.whole?.end ?? h.part.end;
    console.log(`  ${String(h.value).padEnd(14)} ${b.valueOf().toFixed(4)} -> ${e.valueOf().toFixed(4)}  (dur ${(e.valueOf()-b.valueOf()).toFixed(4)})`);
  }
} catch (err) {
  console.error('PARSE ERROR:', err.message);
  process.exit(1);
}
