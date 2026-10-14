/*
 * Vendored for voice_lab only (never shipped with the game).
 * Bundled with esbuild from npm: klatt-syn@1.0.9, dsp-collection@1.0.1, pink-trombone-mod@0.1.0.
 *
 * klatt-syn, dsp-collection: MIT License, Copyright (c) 2019 Christian d'Heureuse, chdh@inventec.ch
 * pink-trombone-mod: MIT License, Copyright 2017 Neil Thapen (modularized by Christian d'Heureuse)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
 * associated documentation files (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions: The above copyright notice and this
 * permission notice shall be included in all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
 */
(() => {
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __esm = (fn, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
    } catch (e) {
      throw err = [e], e;
    }
  };
  var __commonJS = (cb, mod) => function __require() {
    try {
      return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
    } catch (e) {
      throw mod = 0, e;
    }
  };

  // node_modules/dsp-collection/dist/utils/ArrayUtils.js
  function maxAbs(a) {
    if (a.length == 0) {
      return NaN;
    }
    let maxAbsVal = a[0];
    for (let p2 = 1; p2 < a.length; p2++) {
      const v = Math.abs(a[p2]);
      if (v > maxAbsVal) {
        maxAbsVal = v;
      }
    }
    return maxAbsVal;
  }
  function rms(a) {
    const n = a.length;
    if (n == 0) {
      return NaN;
    }
    let acc = 0;
    for (let i = 0; i < n; i++) {
      acc += a[i] ** 2;
    }
    return Math.sqrt(acc / n);
  }
  var init_ArrayUtils = __esm({
    "node_modules/dsp-collection/dist/utils/ArrayUtils.js"() {
    }
  });

  // node_modules/dsp-collection/dist/utils/DspUtils.js
  function adjustSignalLevel(signal, options) {
    const n = signal.length;
    if (!n) {
      return;
    }
    let rmsFactor = Infinity;
    if (options.targetRms) {
      const rms2 = rms(signal);
      if (rms2) {
        rmsFactor = options.targetRms / rms2;
      }
    }
    let maxLevelFactor = Infinity;
    if (options.targetMaxLevel) {
      const maxAbs2 = maxAbs(signal);
      if (maxAbs2) {
        maxLevelFactor = options.targetMaxLevel / maxAbs2;
      }
    }
    const factor = Math.min(rmsFactor, maxLevelFactor);
    if (isFinite(factor) && Math.abs(factor - 1) > 1e-6) {
      for (let i = 0; i < n; i++) {
        signal[i] *= factor;
      }
    }
    const clippingLevel = options.clippingLevel ?? 0;
    if (clippingLevel) {
      for (let i = 0; i < n; i++) {
        const v = signal[i];
        if (v > clippingLevel) {
          signal[i] = clippingLevel;
        } else if (v < -clippingLevel) {
          signal[i] = -clippingLevel;
        }
      }
    }
  }
  var init_DspUtils = __esm({
    "node_modules/dsp-collection/dist/utils/DspUtils.js"() {
      init_ArrayUtils();
    }
  });

  // node_modules/klatt-syn/dist/DemoParms.js
  var init_DemoParms = __esm({
    "node_modules/klatt-syn/dist/DemoParms.js"() {
    }
  });

  // node_modules/klatt-syn/dist/Klatt.js
  function getWhiteNoise() {
    return Math.random() * 2 - 1;
  }
  function performFrequencyModulation(f0, flutterLevel, time) {
    if (flutterLevel <= 0) {
      return f0;
    }
    const w = 2 * Math.PI * time;
    const a = Math.sin(12.7 * w) + Math.sin(7.1 * w) + Math.sin(4.7 * w);
    return f0 * (1 + a * flutterLevel / 50);
  }
  function dbToLin(db) {
    if (db <= -99 || isNaN(db)) {
      return 0;
    } else {
      return Math.pow(10, db / 20);
    }
  }
  function setTiltFilter(tiltFilter, tiltDb) {
    if (!tiltDb) {
      tiltFilter.setPassthrough();
    } else {
      tiltFilter.set(3e3, dbToLin(-tiltDb));
    }
  }
  function setNasalFormantCasc(nasalFormantCasc, fParms) {
    if (fParms.nasalFormantFreq && fParms.nasalFormantBw) {
      nasalFormantCasc.set(fParms.nasalFormantFreq, fParms.nasalFormantBw);
    } else {
      nasalFormantCasc.setPassthrough();
    }
  }
  function setNasalAntiformantCasc(nasalAntiformantCasc, fParms) {
    if (fParms.nasalAntiformantFreq && fParms.nasalAntiformantBw) {
      nasalAntiformantCasc.set(fParms.nasalAntiformantFreq, fParms.nasalAntiformantBw);
    } else {
      nasalAntiformantCasc.setPassthrough();
    }
  }
  function setOralFormantCasc(oralFormantCasc, fParms, i) {
    const f = i < fParms.oralFormantFreq.length ? fParms.oralFormantFreq[i] : NaN;
    const bw = i < fParms.oralFormantBw.length ? fParms.oralFormantBw[i] : NaN;
    if (f && bw) {
      oralFormantCasc.set(f, bw);
    } else {
      oralFormantCasc.setPassthrough();
    }
  }
  function setNasalFormantPar(nasalFormantPar, fParms) {
    if (fParms.nasalFormantFreq && fParms.nasalFormantBw && dbToLin(fParms.nasalFormantDb)) {
      nasalFormantPar.set(fParms.nasalFormantFreq, fParms.nasalFormantBw);
      nasalFormantPar.adjustPeakGain(dbToLin(fParms.nasalFormantDb));
    } else {
      nasalFormantPar.setMute();
    }
  }
  function setOralFormantPar(oralFormantPar, mParms, fParms, i) {
    const formant = i + 1;
    const f = i < fParms.oralFormantFreq.length ? fParms.oralFormantFreq[i] : NaN;
    const bw = i < fParms.oralFormantBw.length ? fParms.oralFormantBw[i] : NaN;
    const db = i < fParms.oralFormantDb.length ? fParms.oralFormantDb[i] : NaN;
    const peakGain = dbToLin(db);
    if (f && bw && peakGain) {
      oralFormantPar.set(f, bw);
      const w = 2 * Math.PI * f / mParms.sampleRate;
      const diffGain = Math.sqrt(2 - 2 * Math.cos(w));
      const filterGain = formant >= 2 ? peakGain / diffGain : peakGain;
      oralFormantPar.adjustPeakGain(filterGain);
    } else {
      oralFormantPar.setMute();
    }
  }
  function generateSound(mParms, fParmsA) {
    const generator = new Generator(mParms);
    let outBufLen = 0;
    for (const fParms of fParmsA) {
      outBufLen += Math.round(fParms.duration * mParms.sampleRate);
    }
    const outBuf = new Float64Array(outBufLen);
    let outBufPos = 0;
    for (const fParms of fParmsA) {
      const frameLen = Math.round(fParms.duration * mParms.sampleRate);
      const frameBuf = outBuf.subarray(outBufPos, outBufPos + frameLen);
      generator.generateFrame(fParms, frameBuf);
      outBufPos += frameLen;
    }
    return outBuf;
  }
  var LpFilter1, Resonator, AntiResonator, DifferencingFilter, LpNoiseSource, ImpulsiveGlottalSource, NaturalGlottalSource, maxOralFormants, Generator;
  var init_Klatt = __esm({
    "node_modules/klatt-syn/dist/Klatt.js"() {
      init_DspUtils();
      init_DemoParms();
      LpFilter1 = class {
        constructor(sampleRate) {
          this.sampleRate = sampleRate;
          this.y1 = 0;
          this.passthrough = true;
          this.muted = false;
        }
        set(f, g, extraGain = 1) {
          if (f <= 0 || f >= this.sampleRate / 2 || g <= 0 || g >= 1 || !isFinite(f) || !isFinite(g) || !isFinite(extraGain)) {
            throw new Error("Invalid filter parameters.");
          }
          const w = 2 * Math.PI * f / this.sampleRate;
          const q = (1 - g ** 2 * Math.cos(w)) / (1 - g ** 2);
          this.b = q - Math.sqrt(q ** 2 - 1);
          this.a = (1 - this.b) * extraGain;
          this.passthrough = false;
          this.muted = false;
        }
        setPassthrough() {
          this.passthrough = true;
          this.muted = false;
          this.y1 = 0;
        }
        setMute() {
          this.passthrough = false;
          this.muted = true;
          this.y1 = 0;
        }
        getTransferFunctionCoefficients() {
          if (this.passthrough) {
            return [[1], [1]];
          }
          if (this.muted) {
            return [[0], [1]];
          }
          return [[this.a], [1, -this.b]];
        }
        step(x) {
          if (this.passthrough) {
            return x;
          }
          if (this.muted) {
            return 0;
          }
          const y = this.a * x + this.b * this.y1;
          this.y1 = y;
          return y;
        }
      };
      Resonator = class {
        constructor(sampleRate) {
          this.sampleRate = sampleRate;
          this.y1 = 0;
          this.y2 = 0;
          this.passthrough = true;
          this.muted = false;
        }
        set(f, bw, dcGain = 1) {
          if (f < 0 || f >= this.sampleRate / 2 || bw <= 0 || dcGain <= 0 || !isFinite(f) || !isFinite(bw) || !isFinite(dcGain)) {
            throw new Error("Invalid resonator parameters.");
          }
          this.r = Math.exp(-Math.PI * bw / this.sampleRate);
          const w = 2 * Math.PI * f / this.sampleRate;
          this.c = -(this.r ** 2);
          this.b = 2 * this.r * Math.cos(w);
          this.a = (1 - this.b - this.c) * dcGain;
          this.passthrough = false;
          this.muted = false;
        }
        setPassthrough() {
          this.passthrough = true;
          this.muted = false;
          this.y1 = 0;
          this.y2 = 0;
        }
        setMute() {
          this.passthrough = false;
          this.muted = true;
          this.y1 = 0;
          this.y2 = 0;
        }
        adjustImpulseGain(newA) {
          this.a = newA;
        }
        adjustPeakGain(peakGain) {
          if (peakGain <= 0 || !isFinite(peakGain)) {
            throw new Error("Invalid resonator peak gain.");
          }
          this.a = peakGain * (1 - this.r);
        }
        getTransferFunctionCoefficients() {
          if (this.passthrough) {
            return [[1], [1]];
          }
          if (this.muted) {
            return [[0], [1]];
          }
          return [[this.a], [1, -this.b, -this.c]];
        }
        step(x) {
          if (this.passthrough) {
            return x;
          }
          if (this.muted) {
            return 0;
          }
          const y = this.a * x + this.b * this.y1 + this.c * this.y2;
          this.y2 = this.y1;
          this.y1 = y;
          return y;
        }
      };
      AntiResonator = class {
        constructor(sampleRate) {
          this.sampleRate = sampleRate;
          this.x1 = 0;
          this.x2 = 0;
          this.passthrough = true;
          this.muted = false;
        }
        set(f, bw) {
          if (f <= 0 || f >= this.sampleRate / 2 || bw <= 0 || !isFinite(f) || !isFinite(bw)) {
            throw new Error("Invalid anti-resonator parameters.");
          }
          const r = Math.exp(-Math.PI * bw / this.sampleRate);
          const w = 2 * Math.PI * f / this.sampleRate;
          const c0 = -(r * r);
          const b0 = 2 * r * Math.cos(w);
          const a0 = 1 - b0 - c0;
          if (a0 == 0) {
            this.a = 0;
            this.b = 0;
            this.c = 0;
            return;
          }
          this.a = 1 / a0;
          this.b = -b0 / a0;
          this.c = -c0 / a0;
          this.passthrough = false;
          this.muted = false;
        }
        setPassthrough() {
          this.passthrough = true;
          this.muted = false;
          this.x1 = 0;
          this.x2 = 0;
        }
        setMute() {
          this.passthrough = false;
          this.muted = true;
          this.x1 = 0;
          this.x2 = 0;
        }
        getTransferFunctionCoefficients() {
          if (this.passthrough) {
            return [[1], [1]];
          }
          if (this.muted) {
            return [[0], [1]];
          }
          return [[this.a, this.b, this.c], [1]];
        }
        step(x) {
          if (this.passthrough) {
            return x;
          }
          if (this.muted) {
            return 0;
          }
          const y = this.a * x + this.b * this.x1 + this.c * this.x2;
          this.x2 = this.x1;
          this.x1 = x;
          return y;
        }
      };
      DifferencingFilter = class {
        constructor() {
          this.x1 = 0;
        }
        getTransferFunctionCoefficients() {
          return [[1, -1], [1]];
        }
        step(x) {
          const y = x - this.x1;
          this.x1 = x;
          return y;
        }
      };
      LpNoiseSource = class {
        constructor(sampleRate) {
          const oldB = 0.75;
          const oldSampleRate = 1e4;
          const f = 1e3;
          const g = (1 - oldB) / Math.sqrt(1 - 2 * oldB * Math.cos(2 * Math.PI * f / oldSampleRate) + oldB ** 2);
          const extraGain = 2.5 * (sampleRate / 1e4) ** 0.33;
          this.lpFilter = new LpFilter1(sampleRate);
          this.lpFilter.set(f, g, extraGain);
        }
        getNext() {
          const x = getWhiteNoise();
          return this.lpFilter.step(x);
        }
      };
      ImpulsiveGlottalSource = class {
        constructor(sampleRate) {
          this.sampleRate = sampleRate;
          this.resonator = void 0;
        }
        startPeriod(openPhaseLength) {
          if (!openPhaseLength) {
            this.resonator = void 0;
            return;
          }
          if (!this.resonator) {
            this.resonator = new Resonator(this.sampleRate);
          }
          const bw = this.sampleRate / openPhaseLength;
          this.resonator.set(0, bw);
          this.resonator.adjustImpulseGain(1);
          this.positionInPeriod = 0;
        }
        getNext() {
          if (!this.resonator) {
            return 0;
          }
          const pulse = this.positionInPeriod == 1 ? 1 : this.positionInPeriod == 2 ? -1 : 0;
          this.positionInPeriod++;
          return this.resonator.step(pulse);
        }
      };
      NaturalGlottalSource = class {
        constructor() {
          this.startPeriod(0);
        }
        startPeriod(openPhaseLength) {
          this.openPhaseLength = openPhaseLength;
          this.x = 0;
          const amplification = 5;
          this.b = -amplification / openPhaseLength ** 2;
          this.a = -this.b * openPhaseLength / 3;
          this.positionInPeriod = 0;
        }
        getNext() {
          if (this.positionInPeriod++ >= this.openPhaseLength) {
            this.x = 0;
            return 0;
          }
          this.a += this.b;
          this.x += this.a;
          return this.x;
        }
      };
      maxOralFormants = 6;
      Generator = class {
        constructor(mParms) {
          this.mParms = mParms;
          this.fState = {};
          this.absPosition = 0;
          this.tiltFilter = new LpFilter1(mParms.sampleRate);
          this.flutterTimeOffset = Math.random() * 1e3;
          this.outputLpFilter = new Resonator(mParms.sampleRate);
          this.outputLpFilter.set(0, mParms.sampleRate / 2);
          this.initGlottalSource();
          this.aspirationSourceCasc = new LpNoiseSource(mParms.sampleRate);
          this.aspirationSourcePar = new LpNoiseSource(mParms.sampleRate);
          this.fricationSourcePar = new LpNoiseSource(mParms.sampleRate);
          this.nasalFormantCasc = new Resonator(mParms.sampleRate);
          this.nasalAntiformantCasc = new AntiResonator(mParms.sampleRate);
          this.oralFormantCasc = Array(maxOralFormants);
          for (let i = 0; i < maxOralFormants; i++) {
            this.oralFormantCasc[i] = new Resonator(mParms.sampleRate);
          }
          this.nasalFormantPar = new Resonator(mParms.sampleRate);
          this.oralFormantPar = Array(maxOralFormants);
          for (let i = 0; i < maxOralFormants; i++) {
            this.oralFormantPar[i] = new Resonator(mParms.sampleRate);
          }
          this.differencingFilterPar = new DifferencingFilter();
        }
        generateFrame(fParms, outBuf) {
          if (fParms == this.fParms) {
            throw new Error("FrameParms structure must not be re-used.");
          }
          this.newFParms = fParms;
          for (let outPos = 0; outPos < outBuf.length; outPos++) {
            if (!this.pState || this.pState.positionInPeriod >= this.pState.periodLength) {
              this.startNewPeriod();
            }
            outBuf[outPos] = this.computeNextOutputSignalSample();
            this.pState.positionInPeriod++;
            this.absPosition++;
          }
          if (isNaN(fParms.gainDb) && fParms.agcRmsLevel > 0) {
            adjustSignalLevel(outBuf, { targetRms: fParms.agcRmsLevel, targetMaxLevel: 0.99 });
          }
        }
        computeNextOutputSignalSample() {
          const fParms = this.fParms;
          const fState = this.fState;
          const pState = this.pState;
          let voice = this.glottalSource();
          voice = this.tiltFilter.step(voice);
          if (pState.positionInPeriod < pState.openPhaseLength) {
            voice += getWhiteNoise() * fState.breathinessLin;
          }
          const cascadeOut = fParms.cascadeEnabled ? this.computeCascadeBranch(voice) : 0;
          const parallelOut = fParms.parallelEnabled ? this.computeParallelBranch(voice) : 0;
          let out = cascadeOut + parallelOut;
          out = this.outputLpFilter.step(out);
          out *= fState.gainLin;
          return out;
        }
        computeCascadeBranch(voice) {
          const fParms = this.fParms;
          const fState = this.fState;
          const pState = this.pState;
          const cascadeVoice = voice * fState.cascadeVoicingLin;
          const currentAspirationMod = pState.positionInPeriod >= pState.periodLength / 2 ? fParms.cascadeAspirationMod : 0;
          const aspiration = this.aspirationSourceCasc.getNext() * fState.cascadeAspirationLin * (1 - currentAspirationMod);
          let v = cascadeVoice + aspiration;
          v = this.nasalAntiformantCasc.step(v);
          v = this.nasalFormantCasc.step(v);
          for (let i = 0; i < maxOralFormants; i++) {
            v = this.oralFormantCasc[i].step(v);
          }
          return v;
        }
        computeParallelBranch(voice) {
          const fParms = this.fParms;
          const fState = this.fState;
          const pState = this.pState;
          const parallelVoice = voice * fState.parallelVoicingLin;
          const currentAspirationMod = pState.positionInPeriod >= pState.periodLength / 2 ? fParms.parallelAspirationMod : 0;
          const aspiration = this.aspirationSourcePar.getNext() * fState.parallelAspirationLin * (1 - currentAspirationMod);
          const source = parallelVoice + aspiration;
          const sourceDifference = this.differencingFilterPar.step(source);
          const currentFricationMod = pState.positionInPeriod >= pState.periodLength / 2 ? fParms.fricationMod : 0;
          const fricationNoise = this.fricationSourcePar.getNext() * fState.fricationLin * (1 - currentFricationMod);
          const source2 = sourceDifference + fricationNoise;
          let v = 0;
          v += this.nasalFormantPar.step(source);
          v += this.oralFormantPar[0].step(source);
          for (let i = 1; i < maxOralFormants; i++) {
            const alternatingSign = i % 2 == 0 ? 1 : -1;
            v += alternatingSign * this.oralFormantPar[i].step(source2);
          }
          v += fState.parallelBypassLin * source2;
          return v;
        }
        startNewPeriod() {
          if (this.newFParms) {
            this.fParms = this.newFParms;
            this.newFParms = void 0;
            this.startUsingNewFrameParameters();
          }
          if (!this.pState) {
            this.pState = {};
          }
          const pState = this.pState;
          const mParms = this.mParms;
          const fParms = this.fParms;
          const flutterTime = this.absPosition / mParms.sampleRate + this.flutterTimeOffset;
          pState.f0 = performFrequencyModulation(fParms.f0, fParms.flutterLevel, flutterTime);
          pState.periodLength = pState.f0 > 0 ? Math.round(mParms.sampleRate / pState.f0) : 1;
          pState.openPhaseLength = pState.periodLength > 1 ? Math.round(pState.periodLength * fParms.openPhaseRatio) : 0;
          pState.positionInPeriod = 0;
          this.startGlottalSourcePeriod();
        }
        startUsingNewFrameParameters() {
          const mParms = this.mParms;
          const fParms = this.fParms;
          const fState = this.fState;
          fState.breathinessLin = dbToLin(fParms.breathinessDb);
          fState.gainLin = dbToLin(fParms.gainDb || 0);
          setTiltFilter(this.tiltFilter, fParms.tiltDb);
          fState.cascadeVoicingLin = dbToLin(fParms.cascadeVoicingDb);
          fState.cascadeAspirationLin = dbToLin(fParms.cascadeAspirationDb);
          setNasalFormantCasc(this.nasalFormantCasc, fParms);
          setNasalAntiformantCasc(this.nasalAntiformantCasc, fParms);
          for (let i = 0; i < maxOralFormants; i++) {
            setOralFormantCasc(this.oralFormantCasc[i], fParms, i);
          }
          fState.parallelVoicingLin = dbToLin(fParms.parallelVoicingDb);
          fState.parallelAspirationLin = dbToLin(fParms.parallelAspirationDb);
          fState.fricationLin = dbToLin(fParms.fricationDb);
          fState.parallelBypassLin = dbToLin(fParms.parallelBypassDb);
          setNasalFormantPar(this.nasalFormantPar, fParms);
          for (let i = 0; i < maxOralFormants; i++) {
            setOralFormantPar(this.oralFormantPar[i], mParms, fParms, i);
          }
        }
        initGlottalSource() {
          switch (this.mParms.glottalSourceType) {
            case 0: {
              this.impulsiveGSource = new ImpulsiveGlottalSource(this.mParms.sampleRate);
              this.glottalSource = () => this.impulsiveGSource.getNext();
              break;
            }
            case 1: {
              this.naturalGSource = new NaturalGlottalSource();
              this.glottalSource = () => this.naturalGSource.getNext();
              break;
            }
            case 2: {
              this.glottalSource = getWhiteNoise;
              break;
            }
            default: {
              throw new Error("Undefined glottal source type.");
            }
          }
        }
        startGlottalSourcePeriod() {
          switch (this.mParms.glottalSourceType) {
            case 0: {
              this.impulsiveGSource.startPeriod(this.pState.openPhaseLength);
              break;
            }
            case 1: {
              this.naturalGSource.startPeriod(this.pState.openPhaseLength);
              break;
            }
            default: {
            }
          }
        }
      };
    }
  });

  // node_modules/pink-trombone-mod/Utils.js
  function clamp(x, min, max) {
    return x < min ? min : x > max ? max : x;
  }
  function moveTowards(current, target, amountUp, amountDown) {
    return current < target ? Math.min(current + amountUp, target) : Math.max(current - amountDown, target);
  }
  function createBiquadIirFilter(b0, b1, b2, a0, a1, a2) {
    const nb0 = b0 / a0;
    const nb1 = b1 / a0;
    const nb2 = b2 / a0;
    const na1 = a1 / a0;
    const na2 = a2 / a0;
    let x1 = 0;
    let x2 = 0;
    let y1 = 0;
    let y2 = 0;
    return (x) => {
      const y = nb0 * x + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2;
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      return y;
    };
  }
  function createBandPassFilter(f0, q, sampleRate) {
    const w0 = 2 * Math.PI * f0 / sampleRate;
    const alpha = Math.sin(w0) / (2 * q);
    const b0 = alpha;
    const b1 = 0;
    const b2 = -alpha;
    const a0 = 1 + alpha;
    const a1 = -2 * Math.cos(w0);
    const a2 = 1 - alpha;
    return createBiquadIirFilter(b0, b1, b2, a0, a1, a2);
  }
  function createBufferedWhiteNoiseSource(bufferSize) {
    const buf = new Float64Array(bufferSize);
    for (let i2 = 0; i2 < bufferSize; i2++) {
      buf[i2] = 2 * Math.random() - 1;
    }
    let i = 0;
    return () => {
      if (i >= bufferSize) {
        i = 0;
      }
      return buf[i++];
    };
  }
  function createFilteredNoiseSource(f0, q, sampleRate, bufferSize) {
    const whiteNoise = createBufferedWhiteNoiseSource(bufferSize);
    const filter = createBandPassFilter(f0, q, sampleRate);
    return () => filter(whiteNoise());
  }
  var init_Utils = __esm({
    "node_modules/pink-trombone-mod/Utils.js"() {
    }
  });

  // node_modules/pink-trombone-mod/NoiseGenerator.js
  function setSeed(seed0) {
    let seed = seed0;
    if (seed > 0 && seed < 1) {
      seed *= 65536;
    }
    seed = Math.floor(seed);
    if (seed < 256) {
      seed |= seed << 8;
    }
    for (var i = 0; i < 256; i++) {
      var v;
      if (i & 1) {
        v = p[i] ^ seed & 255;
      } else {
        v = p[i] ^ seed >> 8 & 255;
      }
      perm[i] = perm[i + 256] = v;
      gradP[i] = gradP[i + 256] = grad3[v % 12];
    }
  }
  function simplex2(xin, yin) {
    var n0, n1, n2;
    const s = (xin + yin) * f2;
    let i = Math.floor(xin + s);
    let j = Math.floor(yin + s);
    const t = (i + j) * g2;
    const x0 = xin - i + t;
    const y0 = yin - j + t;
    let i1, j1;
    if (x0 > y0) {
      i1 = 1;
      j1 = 0;
    } else {
      i1 = 0;
      j1 = 1;
    }
    const x1 = x0 - i1 + g2;
    const y1 = y0 - j1 + g2;
    const x2 = x0 - 1 + 2 * g2;
    const y2 = y0 - 1 + 2 * g2;
    i &= 255;
    j &= 255;
    const gi0 = gradP[i + perm[j]];
    const gi1 = gradP[i + i1 + perm[j + j1]];
    const gi2 = gradP[i + 1 + perm[j + 1]];
    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 < 0) {
      n0 = 0;
    } else {
      t0 *= t0;
      n0 = t0 * t0 * gi0.dot2(x0, y0);
    }
    let t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 < 0) {
      n1 = 0;
    } else {
      t1 *= t1;
      n1 = t1 * t1 * gi1.dot2(x1, y1);
    }
    let t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 < 0) {
      n2 = 0;
    } else {
      t2 *= t2;
      n2 = t2 * t2 * gi2.dot2(x2, y2);
    }
    return 70 * (n0 + n1 + n2);
  }
  function simplex1(x) {
    return simplex2(x * 1.2, -x * 0.7);
  }
  var Grad, grad3, p, perm, gradP, f2, g2;
  var init_NoiseGenerator = __esm({
    "node_modules/pink-trombone-mod/NoiseGenerator.js"() {
      Grad = class {
        constructor(x, y, z) {
          this.x = x;
          this.y = y;
          this.z = z;
        }
        dot2(x, y) {
          return this.x * x + this.y * y;
        }
        dot3(x, y, z) {
          return this.x * x + this.y * y + this.z * z;
        }
      };
      grad3 = [
        new Grad(1, 1, 0),
        new Grad(-1, 1, 0),
        new Grad(1, -1, 0),
        new Grad(-1, -1, 0),
        new Grad(1, 0, 1),
        new Grad(-1, 0, 1),
        new Grad(1, 0, -1),
        new Grad(-1, 0, -1),
        new Grad(0, 1, 1),
        new Grad(0, -1, 1),
        new Grad(0, 1, -1),
        new Grad(0, -1, -1)
      ];
      p = [
        151,
        160,
        137,
        91,
        90,
        15,
        131,
        13,
        201,
        95,
        96,
        53,
        194,
        233,
        7,
        225,
        140,
        36,
        103,
        30,
        69,
        142,
        8,
        99,
        37,
        240,
        21,
        10,
        23,
        190,
        6,
        148,
        247,
        120,
        234,
        75,
        0,
        26,
        197,
        62,
        94,
        252,
        219,
        203,
        117,
        35,
        11,
        32,
        57,
        177,
        33,
        88,
        237,
        149,
        56,
        87,
        174,
        20,
        125,
        136,
        171,
        168,
        68,
        175,
        74,
        165,
        71,
        134,
        139,
        48,
        27,
        166,
        77,
        146,
        158,
        231,
        83,
        111,
        229,
        122,
        60,
        211,
        133,
        230,
        220,
        105,
        92,
        41,
        55,
        46,
        245,
        40,
        244,
        102,
        143,
        54,
        65,
        25,
        63,
        161,
        1,
        216,
        80,
        73,
        209,
        76,
        132,
        187,
        208,
        89,
        18,
        169,
        200,
        196,
        135,
        130,
        116,
        188,
        159,
        86,
        164,
        100,
        109,
        198,
        173,
        186,
        3,
        64,
        52,
        217,
        226,
        250,
        124,
        123,
        5,
        202,
        38,
        147,
        118,
        126,
        255,
        82,
        85,
        212,
        207,
        206,
        59,
        227,
        47,
        16,
        58,
        17,
        182,
        189,
        28,
        42,
        223,
        183,
        170,
        213,
        119,
        248,
        152,
        2,
        44,
        154,
        163,
        70,
        221,
        153,
        101,
        155,
        167,
        43,
        172,
        9,
        129,
        22,
        39,
        253,
        19,
        98,
        108,
        110,
        79,
        113,
        224,
        232,
        178,
        185,
        112,
        104,
        218,
        246,
        97,
        228,
        251,
        34,
        242,
        193,
        238,
        210,
        144,
        12,
        191,
        179,
        162,
        241,
        81,
        51,
        145,
        235,
        249,
        14,
        239,
        107,
        49,
        192,
        214,
        31,
        181,
        199,
        106,
        157,
        184,
        84,
        204,
        176,
        115,
        121,
        50,
        45,
        127,
        4,
        150,
        254,
        138,
        236,
        205,
        93,
        222,
        114,
        67,
        29,
        24,
        72,
        243,
        141,
        128,
        195,
        78,
        66,
        215,
        61,
        156,
        180
      ];
      perm = new Array(512);
      gradP = new Array(512);
      setSeed(Date.now());
      f2 = 0.5 * (Math.sqrt(3) - 1);
      g2 = (3 - Math.sqrt(3)) / 6;
    }
  });

  // node_modules/pink-trombone-mod/Glottis.js
  var Glottis;
  var init_Glottis = __esm({
    "node_modules/pink-trombone-mod/Glottis.js"() {
      init_Utils();
      init_Utils();
      init_NoiseGenerator();
      Glottis = class {
        constructor(sampleRate) {
          this.alwaysVoice = true;
          this.autoWobble = true;
          this.isTouched = false;
          this.targetTenseness = 0.6;
          this.targetFrequency = 140;
          this.vibratoAmount = 5e-3;
          this.vibratoFrequency = 6;
          this.sampleCount = 0;
          this.intensity = 0;
          this.loudness = 1;
          this.smoothFrequency = 140;
          this.timeInWaveform = 0;
          this.newTenseness = 0.6;
          this.oldTenseness = 0.6;
          this.newFrequency = 140;
          this.oldFrequency = 140;
          this.sampleRate = sampleRate;
          this.aspirationNoiseSource = createFilteredNoiseSource(500, 0.5, sampleRate, 32768);
          this.setupWaveform(0);
        }
        step(lambda) {
          const time = this.sampleCount / this.sampleRate;
          if (this.timeInWaveform > this.waveformLength) {
            this.timeInWaveform -= this.waveformLength;
            this.setupWaveform(lambda);
          }
          const out1 = this.normalizedLFWaveform(this.timeInWaveform / this.waveformLength);
          const aspirationNoise = this.aspirationNoiseSource();
          const aspiration1 = this.intensity * (1 - Math.sqrt(this.targetTenseness)) * this.getNoiseModulator() * aspirationNoise;
          const aspiration2 = aspiration1 * (0.2 + 0.02 * simplex1(time * 1.99));
          const out = out1 + aspiration2;
          this.sampleCount++;
          this.timeInWaveform += 1 / this.sampleRate;
          return out;
        }
        getNoiseModulator() {
          const voiced = 0.1 + 0.2 * Math.max(0, Math.sin(Math.PI * 2 * this.timeInWaveform / this.waveformLength));
          return this.targetTenseness * this.intensity * voiced + (1 - this.targetTenseness * this.intensity) * 0.3;
        }
        adjustParameters(deltaTime) {
          const delta = deltaTime * this.sampleRate / 512;
          const oldTime = this.sampleCount / this.sampleRate;
          const newTime = oldTime + deltaTime;
          this.adjustIntensity(delta);
          this.calculateNewFrequency(newTime, delta);
          this.calculateNewTenseness(newTime);
        }
        calculateNewFrequency(time, delta) {
          if (this.intensity == 0) {
            this.smoothFrequency = this.targetFrequency;
          } else if (this.targetFrequency > this.smoothFrequency) {
            this.smoothFrequency = Math.min(this.smoothFrequency * (1 + 0.1 * delta), this.targetFrequency);
          } else if (this.targetFrequency < this.smoothFrequency) {
            this.smoothFrequency = Math.max(this.smoothFrequency / (1 + 0.1 * delta), this.targetFrequency);
          }
          this.oldFrequency = this.newFrequency;
          this.newFrequency = Math.max(10, this.smoothFrequency * (1 + this.calculateVibrato(time)));
        }
        calculateNewTenseness(time) {
          this.oldTenseness = this.newTenseness;
          this.newTenseness = Math.max(0, this.targetTenseness + 0.1 * simplex1(time * 0.46) + 0.05 * simplex1(time * 0.36));
          if (!this.isTouched && this.alwaysVoice) {
            this.newTenseness += (3 - this.targetTenseness) * (1 - this.intensity);
          }
        }
        adjustIntensity(delta) {
          if (this.isTouched || this.alwaysVoice) {
            this.intensity += 0.13 * delta;
          } else {
            this.intensity -= 0.05 * delta;
          }
          this.intensity = clamp(this.intensity, 0, 1);
        }
        calculateVibrato(time) {
          let vibrato = 0;
          vibrato += this.vibratoAmount * Math.sin(2 * Math.PI * time * this.vibratoFrequency);
          vibrato += 0.02 * simplex1(time * 4.07);
          vibrato += 0.04 * simplex1(time * 2.15);
          if (this.autoWobble) {
            vibrato += 0.2 * simplex1(time * 0.98);
            vibrato += 0.4 * simplex1(time * 0.5);
          }
          return vibrato;
        }
        setupWaveform(lambda) {
          const frequency = this.oldFrequency * (1 - lambda) + this.newFrequency * lambda;
          const tenseness = this.oldTenseness * (1 - lambda) + this.newTenseness * lambda;
          this.waveformLength = 1 / frequency;
          this.loudness = Math.pow(Math.max(0, tenseness), 0.25);
          const rd = clamp(3 * (1 - tenseness), 0.5, 2.7);
          const ra = -0.01 + 0.048 * rd;
          const rk = 0.224 + 0.118 * rd;
          const rg = rk / 4 * (0.5 + 1.2 * rk) / (0.11 * rd - ra * (0.5 + 1.2 * rk));
          const ta = ra;
          const tp = 1 / (2 * rg);
          const te = tp + tp * rk;
          const epsilon = 1 / ta;
          const shift = Math.exp(-epsilon * (1 - te));
          const delta = 1 - shift;
          const rhsIntegral = (1 / epsilon * (shift - 1) + (1 - te) * shift) / delta;
          const totalLowerIntegral = rhsIntegral - (te - tp) / 2;
          const totalUpperIntegral = -totalLowerIntegral;
          const omega = Math.PI / tp;
          const s = Math.sin(omega * te);
          const y = -Math.PI * s * totalUpperIntegral / (tp * 2);
          const z = Math.log(y);
          const alpha = z / (tp / 2 - te);
          const e0 = -1 / (s * Math.exp(alpha * te));
          this.alpha = alpha;
          this.e0 = e0;
          this.epsilon = epsilon;
          this.shift = shift;
          this.delta = delta;
          this.te = te;
          this.omega = omega;
        }
        normalizedLFWaveform(t) {
          let output;
          if (t > this.te) {
            output = (-Math.exp(-this.epsilon * (t - this.te)) + this.shift) / this.delta;
          } else {
            output = this.e0 * Math.exp(this.alpha * t) * Math.sin(this.omega * t);
          }
          return output * this.intensity * this.loudness;
        }
      };
    }
  });

  // node_modules/pink-trombone-mod/Tract.js
  var Tract;
  var init_Tract = __esm({
    "node_modules/pink-trombone-mod/Tract.js"() {
      init_Utils();
      init_Utils();
      Tract = class {
        constructor(glottis, tractSampleRate) {
          this.n = 44;
          this.bladeStart = 10;
          this.tipStart = 32;
          this.lipStart = 39;
          this.noseLength = 28;
          this.noseStart = this.n - this.noseLength + 1;
          this.glottalReflection = 0.75;
          this.lipReflection = -0.85;
          this.sampleCount = 0;
          this.time = 0;
          this.transients = [];
          this.turbulencePoints = [];
          this.glottis = glottis;
          this.tractSampleRate = tractSampleRate;
          this.fricationNoiseSource = createFilteredNoiseSource(1e3, 0.5, tractSampleRate, 32768);
          this.diameter = new Float64Array(this.n);
          this.right = new Float64Array(this.n);
          this.left = new Float64Array(this.n);
          this.reflection = new Float64Array(this.n);
          this.newReflection = new Float64Array(this.n);
          this.junctionOutputRight = new Float64Array(this.n);
          this.junctionOutputLeft = new Float64Array(this.n + 1);
          this.maxAmplitude = new Float64Array(this.n);
          this.noseRight = new Float64Array(this.noseLength);
          this.noseLeft = new Float64Array(this.noseLength);
          this.noseJunctionOutputRight = new Float64Array(this.noseLength);
          this.noseJunctionOutputLeft = new Float64Array(this.noseLength + 1);
          this.noseReflection = new Float64Array(this.noseLength);
          this.noseDiameter = new Float64Array(this.noseLength);
          this.noseMaxAmplitude = new Float64Array(this.noseLength);
          this.newReflectionLeft = 0;
          this.newReflectionRight = 0;
          this.newReflectionNose = 0;
        }
        calculateNoseReflections() {
          const a = new Float64Array(this.noseLength);
          for (let i = 0; i < this.noseLength; i++) {
            a[i] = Math.max(1e-6, this.noseDiameter[i] ** 2);
          }
          for (let i = 1; i < this.noseLength; i++) {
            this.noseReflection[i] = (a[i - 1] - a[i]) / (a[i - 1] + a[i]);
          }
        }
        calculateNewBlockParameters() {
          this.calculateMainTractReflections();
          this.calculateNoseJunctionReflections();
        }
        calculateMainTractReflections() {
          const a = new Float64Array(this.n);
          for (let i = 0; i < this.n; i++) {
            a[i] = this.diameter[i] ** 2;
          }
          for (let i = 1; i < this.n; i++) {
            this.reflection[i] = this.newReflection[i];
            const sum = a[i - 1] + a[i];
            this.newReflection[i] = Math.abs(sum) > 1e-6 ? (a[i - 1] - a[i]) / sum : 1;
          }
        }
        calculateNoseJunctionReflections() {
          this.reflectionLeft = this.newReflectionLeft;
          this.reflectionRight = this.newReflectionRight;
          this.reflectionNose = this.newReflectionNose;
          const velumA = this.noseDiameter[0] ** 2;
          const an0 = this.diameter[this.noseStart] ** 2;
          const an1 = this.diameter[this.noseStart + 1] ** 2;
          const sum = an0 + an1 + velumA;
          this.newReflectionLeft = Math.abs(sum) > 1e-6 ? (2 * an0 - sum) / sum : 1;
          this.newReflectionRight = Math.abs(sum) > 1e-6 ? (2 * an1 - sum) / sum : 1;
          this.newReflectionNose = Math.abs(sum) > 1e-6 ? (2 * velumA - sum) / sum : 1;
        }
        step(glottalOutput, lambda) {
          this.processTransients();
          this.addTurbulenceNoise();
          this.junctionOutputRight[0] = this.left[0] * this.glottalReflection + glottalOutput;
          this.junctionOutputLeft[this.n] = this.right[this.n - 1] * this.lipReflection;
          for (let i = 1; i < this.n; i++) {
            const r = this.reflection[i] * (1 - lambda) + this.newReflection[i] * lambda;
            const w = r * (this.right[i - 1] + this.left[i]);
            this.junctionOutputRight[i] = this.right[i - 1] - w;
            this.junctionOutputLeft[i] = this.left[i] + w;
          }
          {
            const i = this.noseStart;
            let r = this.newReflectionLeft * (1 - lambda) + this.reflectionLeft * lambda;
            this.junctionOutputLeft[i] = r * this.right[i - 1] + (1 + r) * (this.noseLeft[0] + this.left[i]);
            r = this.newReflectionRight * (1 - lambda) + this.reflectionRight * lambda;
            this.junctionOutputRight[i] = r * this.left[i] + (1 + r) * (this.right[i - 1] + this.noseLeft[0]);
            r = this.newReflectionNose * (1 - lambda) + this.reflectionNose * lambda;
            this.noseJunctionOutputRight[0] = r * this.noseLeft[0] + (1 + r) * (this.left[i] + this.right[i - 1]);
          }
          for (let i = 0; i < this.n; i++) {
            const right = this.junctionOutputRight[i] * 0.999;
            const left = this.junctionOutputLeft[i + 1] * 0.999;
            this.right[i] = right;
            this.left[i] = left;
            const amplitude = Math.abs(right + left);
            this.maxAmplitude[i] = Math.max(this.maxAmplitude[i] *= 0.9999, amplitude);
          }
          const lipOutput = this.right[this.n - 1];
          this.noseJunctionOutputLeft[this.noseLength] = this.noseRight[this.noseLength - 1] * this.lipReflection;
          for (let i = 1; i < this.noseLength; i++) {
            const w = this.noseReflection[i] * (this.noseRight[i - 1] + this.noseLeft[i]);
            this.noseJunctionOutputRight[i] = this.noseRight[i - 1] - w;
            this.noseJunctionOutputLeft[i] = this.noseLeft[i] + w;
          }
          for (let i = 0; i < this.noseLength; i++) {
            const right = this.noseJunctionOutputRight[i];
            const left = this.noseJunctionOutputLeft[i + 1];
            this.noseRight[i] = right;
            this.noseLeft[i] = left;
            const amplitude = Math.abs(right + left);
            this.noseMaxAmplitude[i] = Math.max(this.noseMaxAmplitude[i] *= 0.9999, amplitude);
          }
          const noseOutput = this.noseRight[this.noseLength - 1];
          this.sampleCount++;
          this.time = this.sampleCount / this.tractSampleRate;
          return lipOutput + noseOutput;
        }
        processTransients() {
          for (let i = this.transients.length - 1; i >= 0; i--) {
            const trans = this.transients[i];
            const timeAlive = this.time - trans.startTime;
            if (timeAlive > trans.lifeTime) {
              this.transients.splice(i, 1);
              continue;
            }
            const amplitude = trans.strength * Math.pow(2, -trans.exponent * timeAlive);
            this.right[trans.position] += amplitude / 2;
            this.left[trans.position] += amplitude / 2;
          }
        }
        addTurbulenceNoise() {
          const fricativeAttackTime = 0.1;
          for (const p2 of this.turbulencePoints) {
            if (p2.position < 2 || p2.position > this.n) {
              continue;
            }
            if (p2.diameter <= 0) {
              continue;
            }
            let intensity;
            if (isNaN(p2.endTime)) {
              intensity = clamp((this.time - p2.startTime) / fricativeAttackTime, 0, 1);
            } else {
              intensity = clamp(1 - (this.time - p2.endTime) / fricativeAttackTime, 0, 1);
            }
            if (intensity <= 0) {
              continue;
            }
            const turbulenceNoise = 0.66 * this.fricationNoiseSource() * intensity * this.glottis.getNoiseModulator();
            this.addTurbulenceNoiseAtPosition(turbulenceNoise, p2.position, p2.diameter);
          }
        }
        addTurbulenceNoiseAtPosition(turbulenceNoise, position, diameter) {
          const i = Math.floor(position);
          const delta = position - i;
          const thinness0 = clamp(8 * (0.7 - diameter), 0, 1);
          const openness = clamp(30 * (diameter - 0.3), 0, 1);
          const noise0 = turbulenceNoise * (1 - delta) * thinness0 * openness;
          const noise1 = turbulenceNoise * delta * thinness0 * openness;
          if (i + 1 < this.n) {
            this.right[i + 1] += noise0 / 2;
            this.left[i + 1] += noise0 / 2;
          }
          if (i + 2 < this.n) {
            this.right[i + 2] += noise1 / 2;
            this.left[i + 2] += noise1 / 2;
          }
        }
      };
    }
  });

  // node_modules/pink-trombone-mod/TractShaper.js
  var gridOffset, TractShaper;
  var init_TractShaper = __esm({
    "node_modules/pink-trombone-mod/TractShaper.js"() {
      init_Utils();
      gridOffset = 1.7;
      TractShaper = class {
        constructor(tract) {
          this.movementSpeed = 15;
          this.velumOpenTarget = 0.4;
          this.velumClosedTarget = 0.01;
          this.lastObstruction = -1;
          this.tract = tract;
          this.targetDiameter = new Float64Array(tract.n);
          this.tongueIndex = 12.9;
          this.tongueDiameter = 2.43;
          this.shapeNose(true);
          tract.calculateNoseReflections();
          this.shapeNose(false);
          this.shapeMainTract();
        }
        shapeMainTract() {
          const tract = this.tract;
          for (let i = 0; i < tract.n; i++) {
            const d = this.getRestDiameter(i);
            tract.diameter[i] = d;
            this.targetDiameter[i] = d;
          }
        }
        getRestDiameter(i) {
          const tract = this.tract;
          if (i < 7) {
            return 0.6;
          }
          if (i < tract.bladeStart) {
            return 1.1;
          }
          if (i >= tract.lipStart) {
            return 1.5;
          }
          const t = 1.1 * Math.PI * (this.tongueIndex - i) / (tract.tipStart - tract.bladeStart);
          const fixedTongueDiameter = 2 + (this.tongueDiameter - 2) / 1.5;
          let curve = (1.5 - fixedTongueDiameter + gridOffset) * Math.cos(t);
          if (i == tract.bladeStart - 2 || i == tract.lipStart - 1) {
            curve *= 0.8;
          }
          if (i == tract.bladeStart || i == tract.lipStart - 2) {
            curve *= 0.94;
          }
          return 1.5 - curve;
        }
        adjustTractShape(deltaTime) {
          const tract = this.tract;
          const amount = deltaTime * this.movementSpeed;
          let newLastObstruction = -1;
          for (let i = 0; i < tract.n; i++) {
            const diameter = tract.diameter[i];
            const targetDiameter = this.targetDiameter[i];
            if (diameter <= 0) {
              newLastObstruction = i;
            }
            let slowReturn;
            if (i < tract.noseStart) {
              slowReturn = 0.6;
            } else if (i >= tract.tipStart) {
              slowReturn = 1;
            } else {
              slowReturn = 0.6 + 0.4 * (i - tract.noseStart) / (tract.tipStart - tract.noseStart);
            }
            tract.diameter[i] = moveTowards(diameter, targetDiameter, slowReturn * amount, 2 * amount);
          }
          if (this.lastObstruction > -1 && newLastObstruction == -1 && tract.noseDiameter[0] < 0.223) {
            this.addTransient(this.lastObstruction);
          }
          this.lastObstruction = newLastObstruction;
          tract.noseDiameter[0] = moveTowards(tract.noseDiameter[0], this.velumTarget, amount * 0.25, amount * 0.1);
        }
        addTransient(position) {
          const tract = this.tract;
          const transient = {
            position,
            startTime: tract.time,
            lifeTime: 0.2,
            strength: 0.3,
            exponent: 200
          };
          tract.transients.push(transient);
        }
        shapeNose(velumOpen) {
          const tract = this.tract;
          this.velumTarget = velumOpen ? this.velumOpenTarget : this.velumClosedTarget;
          for (let i = 0; i < tract.noseLength; i++) {
            let diameter;
            const d = 2 * (i / tract.noseLength);
            if (i == 0) {
              diameter = this.velumTarget;
            } else if (d < 1) {
              diameter = 0.4 + 1.6 * d;
            } else {
              diameter = 0.5 + 1.5 * (2 - d);
            }
            diameter = Math.min(diameter, 1.9);
            tract.noseDiameter[i] = diameter;
          }
        }
      };
    }
  });

  // node_modules/pink-trombone-mod/Synthesizer.js
  var maxBlockLength, Synthesizer;
  var init_Synthesizer = __esm({
    "node_modules/pink-trombone-mod/Synthesizer.js"() {
      init_Glottis();
      init_Tract();
      init_TractShaper();
      maxBlockLength = 512;
      Synthesizer = class {
        constructor(sampleRate) {
          this.sampleRate = sampleRate;
          this.glottis = new Glottis(sampleRate);
          const tractSampleRate = 2 * sampleRate;
          this.tract = new Tract(this.glottis, tractSampleRate);
          this.tractShaper = new TractShaper(this.tract);
        }
        reset() {
          this.calculateNewBlockParameters(0);
        }
        synthesize(buf) {
          let p2 = 0;
          while (p2 < buf.length) {
            const blockLength = Math.min(maxBlockLength, buf.length - p2);
            const blockBuf = buf.subarray(p2, p2 + blockLength);
            this.synthesizeBlock(blockBuf);
            p2 += blockLength;
          }
        }
        synthesizeBlock(buf) {
          const n = buf.length;
          const deltaTime = n / this.sampleRate;
          this.calculateNewBlockParameters(deltaTime);
          for (let i = 0; i < n; i++) {
            const lambda1 = i / n;
            const lambda2 = (i + 0.5) / n;
            const glottalOutput = this.glottis.step(lambda1);
            const vocalOutput1 = this.tract.step(glottalOutput, lambda1);
            const vocalOutput2 = this.tract.step(glottalOutput, lambda2);
            buf[i] = (vocalOutput1 + vocalOutput2) * 0.125;
          }
        }
        calculateNewBlockParameters(deltaTime) {
          this.glottis.adjustParameters(deltaTime);
          this.tractShaper.adjustTractShape(deltaTime);
          this.tract.calculateNewBlockParameters();
        }
      };
    }
  });

  // entry.js
  var require_entry = __commonJS({
    "entry.js"() {
      init_Klatt();
      init_Synthesizer();
      init_Glottis();
      init_TractShaper();
      window.VoiceLabVendor = { generateKlatt: generateSound, PinkTromboneSynthesizer: Synthesizer, PinkTromboneGlottis: Glottis, PinkTromboneTractShaper: TractShaper };
    }
  });
  require_entry();
})();
