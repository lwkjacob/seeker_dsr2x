/*
    SEEKER DSR 2X — NUI front end.

    The 2X face carries two independent antenna rows. Everything display-side is therefore
    keyed by row ('top' = FRONT antenna, 'bottom' = REAR), and the Lua side sends one payload
    per row under `top` / `bottom` plus the shared PATROL SPEED window.
*/

const ROWS = ['top', 'bottom'];

/* Every lamp/arrow the Lua payload can address, per row. Names match the payload keys. */
const OVERLAY_KEYS = [
    'same', 'opp', 'xmit', 'front', 'rear', 'fast', 'lock',
    'targetFrontArrow', 'targetRearArrow',
    'fastFrontArrow', 'fastRearArrow',
];

/* ===== Seven-segment windows (font-based, Segment7Standard) ===== */

function createDigitDisplay() {
    const wrap = document.createElement('div');
    wrap.className = 'digit-display';
    const ghost = document.createElement('span');
    ghost.className = 'digit-ghost';
    ghost.textContent = '888';
    wrap.appendChild(ghost);
    const span = document.createElement('span');
    span.className = 'digit-text';
    span.textContent = '   ';
    wrap.appendChild(span);
    return wrap;
}

function updateDigitDisplay(wrap, str) {
    /* Right-aligned to 3 cells: the Lua side pre-pads legends that must sit left. */
    const text = String(str).padStart(3).slice(-3);
    const span = wrap.querySelector('.digit-text');
    if (span) span.textContent = text;
}

const container = document.getElementById('radar-container');

/* windows[row] = { target, middle }, plus the single shared patrol window. */
const windows = { top: {}, bottom: {} };
let patrolWindow = null;

function initWindows() {
    ROWS.forEach(row => {
        ['target', 'middle'].forEach(which => {
            const host = document.getElementById(`win-${row}-${which}`);
            if (!host) return;
            const wrap = createDigitDisplay();
            host.appendChild(wrap);
            windows[row][which] = wrap;
        });
    });
    const patrolHost = document.getElementById('win-patrol');
    if (patrolHost) {
        patrolWindow = createDigitDisplay();
        patrolHost.appendChild(patrolWindow);
    }
}
initWindows();

/* ===== Digit metrics ===== */
/* The glyphs used a font-size in `em`, which resolves against the root font size and so did
   NOT follow the head when it was resized — only the CSS transform scaled it. Each window
   instead declares --digit-ratio (glyph height as a fraction of that window's own height)
   and this resolves it to pixels whenever the box changes size. */
const WIN_IDS = ['win-top-target', 'win-top-middle', 'win-bottom-target', 'win-bottom-middle', 'win-patrol'];
/* Mirrors --digit-ratio on .win in style.css; only used if that property fails to resolve. */
const DEFAULT_DIGIT_RATIO = 1.06;

function winEls() {
    return WIN_IDS.map(id => document.getElementById(id)).filter(Boolean);
}

function applyDigitMetrics() {
    winEls().forEach(win => {
        const display = win.querySelector('.digit-display');
        if (!display) return;
        const ratio = parseFloat(getComputedStyle(win).getPropertyValue('--digit-ratio')) || DEFAULT_DIGIT_RATIO;
        /* offsetHeight is the layout box before the container's transform, which is what the
           ratio is defined against — the transform scales the result for free. */
        const h = win.offsetHeight;
        if (h > 0) display.style.fontSize = `${(h * ratio).toFixed(2)}px`;
    });
}

/* overlays[row][key] -> <img> */
const overlays = { top: {}, bottom: {} };
ROWS.forEach(row => {
    OVERLAY_KEYS.forEach(key => {
        overlays[row][key] = document.getElementById(`ov-${row}-${key}`);
    });
});

function setOverlay(row, key, active) {
    const el = overlays[row] && overlays[row][key];
    if (el) el.classList.toggle('active', !!active);
}

/* The head starts display:none, so it measures 0 until it is shown — the observer covers
   both that first reveal and every later drag-resize or scale change. */
if (window.ResizeObserver) {
    new ResizeObserver(applyDigitMetrics).observe(container);
}
applyDigitMetrics();

const radarPowerBtn = document.getElementById('btn-power-radar');
const plateReader = document.getElementById('plate-reader');
const plateFrontBg = document.getElementById('plate-front-bg');
const plateRearBg = document.getElementById('plate-rear-bg');
const plateFrontText = document.getElementById('plate-front-text');
const plateRearText = document.getElementById('plate-rear-text');
const plateFrontLocked = document.getElementById('plate-front-locked');
const plateRearLocked = document.getElementById('plate-rear-locked');

/* ===== Audio ===== */

/** Self-test pass cue (nui/sounds/<name>.wav). Swap the file or this name to change it. */
const SELF_TEST_PASS_SOUND = 'stupidfuckinghappysound';
/** Trim applied on top of master volume. 0.6 is about -4.4 dB; lower it further to taste. */
const SELF_TEST_PASS_GAIN = 0.6;

const sounds = {};
/* Front/Rear + Stationary/Opposite/Same + Closing/Away are the three words of the enunciator
   phrase. The middle word ships without a sample on a fresh install; playNextVoice skips any
   name that fails to load, so the phrase degrades to the two-word form rather than going
   silent. */
const SOUND_NAMES = [
    'XmitOn', 'XmitOff', 'Beep', 'alpr_hit', SELF_TEST_PASS_SOUND,
    'Front', 'Rear', 'Stationary', 'Opposite', 'Same', 'Closing', 'Away',
];

/* Lua sends some cue names lower-cased ('beep'); resolve case-insensitively so a cue can
   never go silent over a capitalisation mismatch. */
const SOUND_ALIASES = {};

function loadSounds() {
    SOUND_NAMES.forEach(name => {
        const audio = new Audio(`sounds/${name}.wav`);
        audio.preload = 'auto';
        audio.volume = 1.0;
        sounds[name] = audio;
        SOUND_ALIASES[name.toLowerCase()] = name;
        audio.load();
    });
}
loadSounds();

function resolveSound(name) {
    if (!name) return null;
    if (sounds[name]) return name;
    return SOUND_ALIASES[String(name).toLowerCase()] || null;
}

function playSound(rawName, vol = 1.0) {
    const name = resolveSound(rawName);
    if (!name) return;
    let audio = sounds[name];
    if (audio.error) {
        audio = new Audio(`sounds/${name}.wav`);
        audio.preload = 'auto';
        sounds[name] = audio;
    }
    /* Clamped: assigning outside 0..1 throws and would abort the caller mid-sequence. */
    audio.volume = Math.max(0, Math.min(1, vol));
    audio.currentTime = 0;
    audio.play().catch(() => {});
}

let voiceQueue = [];

function playVoiceSequence(names, vol = 1.0) {
    voiceQueue = [...names];
    playNextVoice(vol);
}

function playNextVoice(vol) {
    /* Looping rather than recursing: a phrase whose words are all missing would otherwise
       recurse once per word before unwinding. */
    while (voiceQueue.length > 0) {
        const name = resolveSound(voiceQueue.shift());
        if (!name) continue;
        const audio = sounds[name];
        /* A word with no sample on disk has .error set, and touching currentTime on it can
           throw. Step over it so the rest of the phrase still speaks. */
        if (!audio || audio.error) continue;
        audio.volume = Math.max(0, Math.min(1, vol));
        try { audio.currentTime = 0; } catch (e) { continue; }
        audio.onended = () => { setTimeout(() => playNextVoice(vol), 100); };
        audio.play().catch(() => { playNextVoice(vol); });
        return;
    }
}

/* ===== Doppler ===== */
/* Pitch and volume scale linearly with every mph — no stepped threshold bands. Only one
   row drives the tone; the Lua side picks which (Config.dopplerSource). */
const DOPPLER_PITCH_SCALE = 0.87;  // <1 = lower overall pitch
const DOPPLER_GAIN_SCALE = 0.52;   // master output quieter
/* Smoothing time constants (s) for setTargetAtTime, which approaches its target
   exponentially: ~63% of the way in 1τ, ~95% in 3τ, ~99% in 5τ.

   Pitch is deliberately near-instant. When the TARGET window jumps between two very
   different speeds the tone should land on the new note more or less at once, the way real
   doppler audio does — it is not sweeping through the speeds in between, because nothing
   ever travelled at them. At 8ms it is within 95% in under a frame. The ramp is not there to
   be heard at all; it only exists so playbackRate does not step discontinuously, which is
   what stair-steps on a slow continuous change.

   Gain gets more, because a hard jump in gain IS audible — it puts a discontinuity in the
   waveform and clicks. 20ms is short enough to read as immediate and long enough not to. */
const DOPPLER_PITCH_SMOOTH_S = 0.008;
const DOPPLER_GAIN_SMOOTH_S = 0.02;

let dopplerCtx = null;
let dopplerBuffer = null;
let dopplerGain = null;
let dopplerSource = null;
let currentDopplerSpeed = null;

/* 0 mph -> pitchMin / volMin; at each maxSpeed -> pitchMax / volMax, FLAT above that speed.
   Lua overrides all six from Config on the first update; these are only the values in force
   for the handful of frames before it does, so keep them in step with shared/config.lua.
   The pitch ceiling is 100 on purpose — see Config.dopplerPitchMaxSpeedMph for why. */
let dopplerPitchMin = 0.7;
let dopplerPitchMax = 2.5;
let dopplerPitchMaxSpeedMph = 100;
let dopplerVolMin = 0.2;
let dopplerVolMax = 1.0;
let dopplerVolMaxSpeedMph = 150;

function dopplerLinearMap(speedMph) {
    const pMax = Math.max(dopplerPitchMaxSpeedMph, 1);
    const tP = Math.max(0, Math.min(speedMph, pMax)) / pMax;
    const pitch = dopplerPitchMin + tP * (dopplerPitchMax - dopplerPitchMin);

    const vMax = Math.max(dopplerVolMaxSpeedMph, 1);
    const tV = Math.max(0, Math.min(speedMph, vMax)) / vMax;
    const vol = dopplerVolMin + tV * (dopplerVolMax - dopplerVolMin);

    return { pitch, vol };
}

/** Lazily create the one shared AudioContext (browsers cap how many you may open). */
function getAudioCtx() {
    if (!dopplerCtx) {
        try {
            dopplerCtx = new (window.AudioContext || window.webkitAudioContext)();
        } catch (e) {
            return null;
        }
    }
    return dopplerCtx;
}

async function loadDopplerSound() {
    try {
        if (!getAudioCtx()) throw new Error('no AudioContext');
        const res = await fetch('sounds/doppler/0.wav');
        const arr = await res.arrayBuffer();
        dopplerBuffer = await dopplerCtx.decodeAudioData(arr);
        dopplerGain = dopplerCtx.createGain();
        dopplerGain.connect(dopplerCtx.destination);
    } catch (e) { console.warn('Doppler load failed:', e); }
}
loadDopplerSound();

function playDopplerStart(speedMph, masterVolume) {
    if (!dopplerCtx || !dopplerBuffer || !dopplerGain) return;
    const { pitch, vol: volMult } = dopplerLinearMap(speedMph);
    const src = dopplerCtx.createBufferSource();
    src.buffer = dopplerBuffer;
    src.loop = true;
    src.playbackRate.setValueAtTime(pitch * DOPPLER_PITCH_SCALE, dopplerCtx.currentTime);
    dopplerGain.gain.setValueAtTime(masterVolume * volMult * DOPPLER_GAIN_SCALE, dopplerCtx.currentTime);
    src.connect(dopplerGain);
    src.start(0);
    dopplerSource = src;
}

function stopDoppler() {
    if (dopplerSource) {
        dopplerSource.stop();
        dopplerSource.disconnect();
        dopplerSource = null;
    }
    currentDopplerSpeed = null;
}

function updateDoppler(speedMph, masterVolume = 1.0) {
    if (!dopplerCtx || !dopplerBuffer) return;
    const hasTarget = speedMph !== null && speedMph !== undefined && speedMph >= 0;

    if (!hasTarget) { stopDoppler(); return; }

    if (dopplerCtx.state === 'suspended') dopplerCtx.resume();

    const { pitch, vol: volMult } = dopplerLinearMap(speedMph);
    if (currentDopplerSpeed === null) playDopplerStart(speedMph, masterVolume);
    if (dopplerSource) {
        const now = dopplerCtx.currentTime;
        dopplerSource.playbackRate.setTargetAtTime(pitch * DOPPLER_PITCH_SCALE, now, DOPPLER_PITCH_SMOOTH_S);
        dopplerGain.gain.setTargetAtTime(masterVolume * volMult * DOPPLER_GAIN_SCALE, now, DOPPLER_GAIN_SMOOTH_S);
    }
    currentDopplerSpeed = speedMph;
}

/* ===== Rear Traffic Alert tone ===== */
/* The manual calls this an "English Horn" tone. Rather than ship another sample, it is
   synthesised: a sawtooth through a gentle lowpass is a serviceable double-reed timbre, and
   alternating two pitches gives the warble that makes it read as a warning rather than as the
   doppler tone it plays alongside. */
const ALERT_TONES_HZ = [587.33, 440.0];  // D5 / A4
const ALERT_STEP_MS = 190;
const ALERT_GAIN_SCALE = 0.18;

let alertOsc = null;
let alertGain = null;
let alertTimer = null;
let alertPhase = 0;

function stopTrafficAlert() {
    if (alertTimer) { clearInterval(alertTimer); alertTimer = null; }
    if (alertOsc) {
        try { alertOsc.stop(); } catch (e) { /* already stopped */ }
        alertOsc.disconnect();
        alertOsc = null;
    }
    if (alertGain) { alertGain.disconnect(); alertGain = null; }
}

function setTrafficAlert(active, vol = 1.0) {
    if (!active) { stopTrafficAlert(); return; }
    const ctx = getAudioCtx();
    if (!ctx) return;
    if (ctx.state === 'suspended') ctx.resume();

    if (alertOsc && alertGain) {
        // Already sounding — just retrack the level (BEEP volume can change mid-alert).
        alertGain.gain.setTargetAtTime(vol * ALERT_GAIN_SCALE, ctx.currentTime, 0.02);
        return;
    }

    alertGain = ctx.createGain();
    /* Ramped in from silence: starting an oscillator at full gain clicks. */
    alertGain.gain.setValueAtTime(0, ctx.currentTime);
    alertGain.gain.setTargetAtTime(vol * ALERT_GAIN_SCALE, ctx.currentTime, 0.02);

    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.setValueAtTime(2200, ctx.currentTime);

    alertOsc = ctx.createOscillator();
    alertOsc.type = 'sawtooth';
    alertPhase = 0;
    alertOsc.frequency.setValueAtTime(ALERT_TONES_HZ[0], ctx.currentTime);

    alertOsc.connect(filter);
    filter.connect(alertGain);
    alertGain.connect(ctx.destination);
    alertOsc.start();

    alertTimer = setInterval(() => {
        if (!alertOsc) return;
        alertPhase = (alertPhase + 1) % ALERT_TONES_HZ.length;
        alertOsc.frequency.setValueAtTime(ALERT_TONES_HZ[alertPhase], ctx.currentTime);
    }, ALERT_STEP_MS);
}

/* ===== NUI messaging ===== */

/** Required for FiveM to decode a NUI POST body into a Lua table reliably. */
const NUI_JSON_HEADERS = { 'Content-Type': 'application/json; charset=UTF-8' };

function post(endpoint, body) {
    fetch(`https://${GetParentResourceName()}/${endpoint}`, {
        method: 'POST',
        headers: NUI_JSON_HEADERS,
        body: JSON.stringify(body || {}),
    }).catch(() => {});
}

function postRemoteAction(action, row, hold) {
    if (!action) return;
    post('remoteBtn', { action, row: row || null, hold: !!hold });
}

if (radarPowerBtn) {
    radarPowerBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        postRemoteAction('power');
    });
}

// Handshake so the client can re-send persisted display config after NUI boot.
post('nuiReady', {});

/* ===== Self test ===== */
/* Mirrors the sequence on manual pp.33-34, driven across both rows at once:
   segment test -> processor/memory/crystal checks -> input voltage and internal temperature
   -> speeds 10, 35, 65 -> per-antenna cable and electronics test -> PASS.

   `at` is ms from the start of the run; t/f/p are the literal 3-character window contents.
   Values are pre-padded to 3 so alignment is explicit — "S  " sits left in the FAST window so
   PAS|S reads as one word across the pair, where the default right-align would strand it.
   `byRow` overrides t/f for one row, which is what the antenna test needs: each row is its
   own antenna and the manual shows them tested and passed separately (Figs. 47-50). */
const ST_BLANK = '   ';
const ST_DEG_F = '°F '; // U+00B0 renders as the top four segments in Segment7
const SELF_TEST_STEPS = [
    { at: 0,    t: '888',    f: '888',    p: '888',   lamps: true },  // segment test: every segment + indicator
    { at: 1200, t: ST_BLANK, f: ST_BLANK, p: ST_BLANK, lamps: false },
    { at: 1400, t: 'Pro',    f: 'C  ',    p: ST_BLANK },              // processor check
    { at: 2000, t: 'ME',     f: 'n  ',    p: ST_BLANK },              // memory check
    { at: 2600, t: 'Crv',    f: 'S  ',    p: ST_BLANK },              // crystal accuracy check
    { at: 3200, t: 'bAt',    f: '139',    p: ST_BLANK },              // input voltage, 13.9 V
    { at: 4000, t: '107',    f: ST_DEG_F, p: ST_BLANK },              // internal temperature
    { at: 4800, t: ST_BLANK, f: ST_BLANK, p: ST_BLANK },
    { at: 5000, t: ' 10',    f: ST_BLANK, p: ' 10' },                 // speed display check
    { at: 5550, t: ' 35',    f: ST_BLANK, p: ' 35' },
    { at: 6100, t: ' 65',    f: ST_BLANK, p: ' 65' },
    { at: 6650, t: ST_BLANK, f: ST_BLANK, p: ST_BLANK },
    {   // antenna cable / electronics test, each row reporting its own antenna
        at: 6850, t: 'Ant', f: ST_BLANK, p: ST_BLANK,
        byRow: { top: { f: '  1' }, bottom: { f: '  2' } },
    },
    { at: 7700, t: 'PAS',    f: 'S  ',    p: ST_BLANK },              // "PASS", both antennas
];
const SELF_TEST_PASS_SOUND_AT = 7900;
/* Holds the PASS screen until the pass cue finishes. Mirrored by SELF_TEST_DURATION_MS in
   client/radar.lua, which is how Lua knows to stop measuring for the same span — change both. */
const SELF_TEST_END_AT = 8700;

let selfTestTimers = [];

/* True for the whole run. The sequence owns every window AND every lamp while it is up —
   without this the all-segments step is wiped by the next state update ~30 ms later, and the
   blanked screens behind the internal checks light back up. Lua mirrors the same window
   (displayTestUntil in client/radar.lua) so it stops measuring and goes silent for the duration;
   this flag is what protects the display itself. */
let selfTestActive = false;

function clearSelfTest() {
    selfTestTimers.forEach(clearTimeout);
    selfTestTimers = [];
    selfTestActive = false;
}

function runSelfTestSequence(vol) {
    /* Restart cleanly: without this a second TEST press interleaves its screens with the run
       already in progress (easy to hit, since power-on fires one too). */
    clearSelfTest();
    clearTimeout(tempDisplayTimer);
    tempDisplayActive = true;
    selfTestActive = true;
    stopDoppler();
    stopTrafficAlert();

    function showStep(step) {
        ROWS.forEach(row => {
            const over = (step.byRow && step.byRow[row]) || {};
            const t = over.t !== undefined ? over.t : step.t;
            const f = over.f !== undefined ? over.f : step.f;
            if (windows[row].target) updateDigitDisplay(windows[row].target, t);
            if (windows[row].middle) updateDigitDisplay(windows[row].middle, f);
            if (step.lamps !== undefined) {
                OVERLAY_KEYS.forEach(key => setOverlay(row, key, step.lamps));
            }
        });
        if (patrolWindow) updateDigitDisplay(patrolWindow, step.p);
    }

    function after(ms, fn) {
        selfTestTimers.push(setTimeout(fn, ms));
    }

    SELF_TEST_STEPS.forEach(step => {
        if (step.at <= 0) showStep(step); else after(step.at, () => showStep(step));
    });

    after(SELF_TEST_PASS_SOUND_AT, () => playSound(SELF_TEST_PASS_SOUND, vol * SELF_TEST_PASS_GAIN));
    after(SELF_TEST_END_AT, () => {
        tempDisplayActive = false;
        selfTestActive = false;
    });
}

/* ===== Lamp test ===== */
/* What power-on runs instead of the full self test: the segment-check step on its own, held.
   Every lamp lit and 888 in all five windows, then straight into normal operation. The full
   sequence is still there behind TEST and the settings menu.

   Mirrored by LAMP_TEST_DURATION_MS in client/radar.lua, which stops the radar measuring for
   the same span — change both. It reuses selfTestActive, so the same guards that stop a state
   update painting over the sequence apply here, and a power-off clears it the same way. */
const LAMP_TEST_MS = 3000;

function runLampTest() {
    clearSelfTest();
    clearTimeout(tempDisplayTimer);
    tempDisplayActive = true;
    selfTestActive = true;
    stopDoppler();
    stopTrafficAlert();

    ROWS.forEach(row => {
        if (windows[row].target) updateDigitDisplay(windows[row].target, '888');
        if (windows[row].middle) updateDigitDisplay(windows[row].middle, '888');
        OVERLAY_KEYS.forEach(key => setOverlay(row, key, true));
    });
    if (patrolWindow) updateDigitDisplay(patrolWindow, '888');

    selfTestTimers.push(setTimeout(() => {
        tempDisplayActive = false;
        selfTestActive = false;
    }, LAMP_TEST_MS));
}

/* ===== Plate reader ===== */

function clampPlateStyle(style) {
    let s = Number(style);
    if (Number.isNaN(s)) s = 0;
    if (s < 0) s = 0;
    if (s > 5) s = s % 6;
    return s;
}

function getPlateTextColor(style) {
    if (style === 1) return '#ffd34a'; // Yellow
    if (style === 2) return '#d3b247'; // Slightly darker yellow
    return '#111111';                  // Plate styles 0, 3, 4, 5 use black
}

function setPlateTextFit(el, textValue) {
    if (!el) return;
    let inner = el.querySelector('.plate-text-inner');
    if (!inner) {
        inner = document.createElement('span');
        inner.className = 'plate-text-inner';
        el.textContent = '';
        el.appendChild(inner);
    }

    const text = (textValue || '--------').toString().slice(0, 8).toUpperCase();
    inner.textContent = text;
    inner.style.lineHeight = '1';
    inner.style.maxWidth = 'none';
    el.style.fontSize = '';

    let layoutAttempts = 0;

    const fit = () => {
        layoutAttempts += 1;
        const cw = el.clientWidth;
        const ch = el.clientHeight;
        if ((cw < 12 || ch < 12) && layoutAttempts < 8) {
            requestAnimationFrame(fit);
            return;
        }
        if (cw < 12 || ch < 12) return;

        const maxW = cw - 8;
        const maxH = ch - 4;
        const minSize = 11;
        /* Cap keeps the glyphs from mushing; 34px fills most of the plate art. */
        const maxSize = 34;
        const len = Math.max(1, text.trim().length);
        const maxByWidth = Math.floor(maxW / (len * 0.68));
        const maxHGlyph = Math.max(12, Math.floor(maxH * 0.88));
        const rawStart = Math.min(maxSize, maxByWidth, maxHGlyph, Math.floor(maxH * 0.74));
        let size = Math.max(minSize, rawStart);
        for (; size >= minSize; size -= 1) {
            inner.style.fontSize = `${size}px`;
            /* Slightly wider tracking at larger sizes keeps the holes in 6/8/9/0 readable. */
            const trackEm = Math.min(0.14, Math.max(0.06, 0.055 + (8 - len) * 0.012));
            inner.style.letterSpacing = `${trackEm}em`;
            if (inner.offsetWidth <= maxW && inner.offsetHeight <= maxHGlyph) break;
        }
    };

    fit();
    requestAnimationFrame(fit);
}

function updatePlateReader(data) {
    if (!plateReader) return;

    if (data.plateReaderVisible !== undefined) {
        plateReader.classList.toggle('visible', !!data.plateReaderVisible || plateAdjustMode);
    }
    if (data.frontPlateStyle !== undefined && plateFrontBg) {
        const style = clampPlateStyle(data.frontPlateStyle);
        plateFrontBg.src = `images/plates/${style}.png`;
        if (plateFrontText) plateFrontText.style.color = getPlateTextColor(style);
    }
    if (data.rearPlateStyle !== undefined && plateRearBg) {
        const style = clampPlateStyle(data.rearPlateStyle);
        plateRearBg.src = `images/plates/${style}.png`;
        if (plateRearText) plateRearText.style.color = getPlateTextColor(style);
    }
    if (data.frontPlateText !== undefined) setPlateTextFit(plateFrontText, data.frontPlateText);
    if (data.rearPlateText !== undefined) setPlateTextFit(plateRearText, data.rearPlateText);
    if (data.frontPlateLocked !== undefined && plateFrontLocked) {
        plateFrontLocked.classList.toggle('active', !!data.frontPlateLocked);
    }
    if (data.rearPlateLocked !== undefined && plateRearLocked) {
        plateRearLocked.classList.toggle('active', !!data.rearPlateLocked);
    }
}

/* ===== Display update ===== */

let tempDisplayActive = false;
let tempDisplayTimer = null;

/** Applies one row payload: two windows plus that row's eleven lamps. */
function applyRowPayload(row, payload) {
    if (!payload) return;
    /* Calibration holds a static 888 in every window — live values would keep overwriting the
       test pattern the sizing is being judged against. */
    if (!tempDisplayActive && !winDebugActive) {
        if (payload.target !== undefined && windows[row].target) {
            updateDigitDisplay(windows[row].target, payload.target);
        }
        if (payload.middle !== undefined && windows[row].middle) {
            updateDigitDisplay(windows[row].middle, payload.middle);
        }
    }
    /* Temp legends leave the lamps alone — they are a message over a live display. A self-test
       does not: it drives the lamps itself, all on for the segment check then all off behind
       the internal checks. */
    if (selfTestActive) return;
    OVERLAY_KEYS.forEach(key => {
        if (payload[key] !== undefined) setOverlay(row, key, payload[key]);
    });
}

function updateDisplay(data) {
    if (!data) return;

    if (data.displayed !== undefined && !winDebugActive) {
        container.classList.toggle('visible', !!data.displayed);
    }
    if (!tempDisplayActive && !winDebugActive && data.patrolSpeed !== undefined && patrolWindow) {
        updateDigitDisplay(patrolWindow, data.patrolSpeed);
    }

    applyRowPayload('top', data.top);
    applyRowPayload('bottom', data.bottom);

    if (data.dopplerPitchMin !== undefined) dopplerPitchMin = Number(data.dopplerPitchMin);
    if (data.dopplerPitchMax !== undefined) dopplerPitchMax = Number(data.dopplerPitchMax);
    if (data.dopplerPitchMaxSpeedMph !== undefined && Number(data.dopplerPitchMaxSpeedMph) > 0) {
        dopplerPitchMaxSpeedMph = Number(data.dopplerPitchMaxSpeedMph);
    }
    if (data.dopplerVolMin !== undefined) dopplerVolMin = Number(data.dopplerVolMin);
    if (data.dopplerVolMax !== undefined) dopplerVolMax = Number(data.dopplerVolMax);
    if (data.dopplerVolMaxSpeedMph !== undefined && Number(data.dopplerVolMaxSpeedMph) > 0) {
        dopplerVolMaxSpeedMph = Number(data.dopplerVolMaxSpeedMph);
    }

    if (data.power === false) {
        /* Switched off mid-run: abort the test rather than let it keep painting a dead head. */
        if (selfTestActive) {
            clearSelfTest();
            tempDisplayActive = false;
        }
        /* Lua already sends a dark payload for both rows with no power, but the test above
           can have swallowed it — nothing on an unpowered face stays lit. */
        ROWS.forEach(row => OVERLAY_KEYS.forEach(key => setOverlay(row, key, false)));
        stopDoppler();
        stopTrafficAlert();
    } else if (selfTestActive) {
        /* Lua already withholds the tone for the duration, but a message queued before the
           test started can still be in flight — this makes the silence unconditional. */
        stopDoppler();
    } else if (data.dopplerSpeedMph !== undefined || data.dopplerVolume !== undefined) {
        updateDoppler(data.dopplerSpeedMph, data.dopplerVolume ?? 1.0);
    }

    updatePlateReader(data);
}

/** Lua sends 'top' / 'bot'; normalise to the element naming. */
function normaliseRow(row) {
    if (row === 'bot' || row === 'bottom' || row === 'rear') return 'bottom';
    if (row === 'top' || row === 'front') return 'top';
    return null;
}

/** Temporary legend flash (range, volume, MOV/STA mode, ...). A row-scoped flash touches
 *  only that row; anything else falls through to the patrol window. */
function showTempDisplay(data) {
    const dur = data.duration || 3000;
    tempDisplayActive = true;

    const row = normaliseRow(data.row);
    if (row) {
        if (data.target !== undefined && windows[row].target) updateDigitDisplay(windows[row].target, data.target);
        if (data.middle !== undefined && windows[row].middle) updateDigitDisplay(windows[row].middle, data.middle);
    } else {
        ROWS.forEach(r => {
            if (data.target !== undefined && windows[r].target) updateDigitDisplay(windows[r].target, data.target);
            if (data.middle !== undefined && windows[r].middle) updateDigitDisplay(windows[r].middle, data.middle);
        });
    }
    if (data.patrol !== undefined && patrolWindow) updateDigitDisplay(patrolWindow, data.patrol);

    clearTimeout(tempDisplayTimer);
    tempDisplayTimer = setTimeout(() => { tempDisplayActive = false; }, dur);
}

/* ===== Window calibration mode ===== */
/* Drag/scale the five digit windows against the base art and export the result as CSS to
   paste back into style.css as the new defaults. Entered with /seeker2x_windows.

   Everything is kept in percentages of .radar-inner so a calibration done at one head size
   is correct at every other one. */

const winDebugPanel = document.getElementById('win-debug-panel');
const winDebugSelLabel = document.getElementById('win-debug-sel');
const winDebugOutput = document.getElementById('win-debug-output');
const winDebugExportBtn = document.getElementById('win-debug-export');

let winDebugActive = false;
let winSelected = null;
let winDragging = null;
let winDragStartX = 0, winDragStartY = 0;
let winStartLeft = 0, winStartTop = 0;
/** id -> the CSS-authored values, captured before the first edit so R can restore them. */
const winDefaults = {};

function radarInner() {
    return container.querySelector('.radar-inner') || container;
}

function winRatioOf(win) {
    return parseFloat(getComputedStyle(win).getPropertyValue('--digit-ratio')) || DEFAULT_DIGIT_RATIO;
}

/** Tracking in em. Custom properties compute as-specified, so the raw "0.15em" comes back. */
function winTrackOf(win) {
    return parseFloat(getComputedStyle(win).getPropertyValue('--digit-track')) || 0.15;
}

function winMetrics(win) {
    return {
        left: parseFloat(win.style.left),
        top: parseFloat(win.style.top),
        width: parseFloat(win.style.width),
        height: parseFloat(win.style.height),
        ratio: winRatioOf(win),
        track: winTrackOf(win),
    };
}

function setWinMetrics(win, m) {
    if (m.left !== undefined) win.style.left = `${m.left.toFixed(2)}%`;
    if (m.top !== undefined) win.style.top = `${m.top.toFixed(2)}%`;
    if (m.width !== undefined) win.style.width = `${m.width.toFixed(2)}%`;
    if (m.height !== undefined) win.style.height = `${m.height.toFixed(2)}%`;
    if (m.ratio !== undefined) win.style.setProperty('--digit-ratio', m.ratio.toFixed(3));
    if (m.track !== undefined) win.style.setProperty('--digit-track', `${m.track.toFixed(3)}em`);
    applyDigitMetrics();
}

/** Copy the live layout into inline percentages so every later edit is a simple read/write. */
function normaliseWin(win) {
    const ib = radarInner().getBoundingClientRect();
    const wb = win.getBoundingClientRect();
    if (ib.width === 0 || ib.height === 0) return;
    /* Both rects carry the container's transform, so the ratios are scale-invariant. */
    win.style.left = `${((wb.left - ib.left) / ib.width * 100).toFixed(2)}%`;
    win.style.top = `${((wb.top - ib.top) / ib.height * 100).toFixed(2)}%`;
    win.style.width = `${(wb.width / ib.width * 100).toFixed(2)}%`;
    win.style.height = `${(wb.height / ib.height * 100).toFixed(2)}%`;
    win.style.setProperty('--digit-ratio', winRatioOf(win).toFixed(3));
    win.style.setProperty('--digit-track', `${winTrackOf(win).toFixed(3)}em`);
}

function selectWin(win) {
    winSelected = win;
    winEls().forEach(w => w.classList.toggle('win-selected', w === win));
    updateWinDebugLabel();
}

function updateWinDebugLabel() {
    if (!winDebugSelLabel) return;
    if (!winSelected) { winDebugSelLabel.textContent = 'none selected'; return; }
    const m = winMetrics(winSelected);
    winDebugSelLabel.textContent =
        `${winSelected.dataset.label}\n`
        + `left ${m.left.toFixed(2)}%  top ${m.top.toFixed(2)}%\n`
        + `w ${m.width.toFixed(2)}%  h ${m.height.toFixed(2)}%\n`
        + `glyph ${m.ratio.toFixed(3)}  track ${m.track.toFixed(3)}em`;
    winDebugSelLabel.style.whiteSpace = 'pre';
}

function setWindowDebug(active) {
    winDebugActive = !!active;
    container.classList.toggle('win-debug', winDebugActive);
    if (winDebugPanel) winDebugPanel.classList.toggle('active', winDebugActive);

    if (winDebugActive) {
        container.classList.add('visible');
        winEls().forEach(win => {
            normaliseWin(win);
            if (!winDefaults[win.id]) winDefaults[win.id] = winMetrics(win);
        });
        applyDigitMetrics();
        /* Fill every window so glyph size and centring can actually be judged. */
        winEls().forEach(win => {
            const wrap = win.querySelector('.digit-display');
            if (wrap) updateDigitDisplay(wrap, '888');
        });
        selectWin(winSelected && document.body.contains(winSelected) ? winSelected : winEls()[0]);
    } else {
        winEls().forEach(w => w.classList.remove('win-selected'));
        if (winDebugOutput) winDebugOutput.classList.remove('active');
    }
}

if (winDebugExportBtn) {
    winDebugExportBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        exportWindowCSS();
    });
}

function exportWindowCSS() {
    let css = '/* seeker_dsr2x window calibration — paste over the matching rules in style.css */\n';
    winEls().forEach(win => {
        const m = winMetrics(win);
        css += `#${win.id} {\n`
            + `    left: ${m.left.toFixed(2)}%;\n`
            + `    top: ${m.top.toFixed(2)}%;\n`
            + `    width: ${m.width.toFixed(2)}%;\n`
            + `    height: ${m.height.toFixed(2)}%;\n`
            + `    --digit-ratio: ${m.ratio.toFixed(3)};\n`
            + `    --digit-track: ${m.track.toFixed(3)}em;\n`
            + `}\n`;
    });
    if (winDebugOutput) {
        winDebugOutput.value = css;
        winDebugOutput.classList.add('active');
        winDebugOutput.focus();
        winDebugOutput.select();
    }
    console.log(css);
    return css;
}

winEls().forEach(win => {
    win.addEventListener('mousedown', (e) => {
        if (!winDebugActive) return;
        e.preventDefault();
        e.stopPropagation();
        selectWin(win);
        winDragging = win;
        winDragStartX = e.clientX;
        winDragStartY = e.clientY;
        const m = winMetrics(win);
        winStartLeft = m.left;
        winStartTop = m.top;
    });

    win.addEventListener('wheel', (e) => {
        if (!winDebugActive) return;
        e.preventDefault();
        e.stopPropagation();
        selectWin(win);
        const dir = e.deltaY > 0 ? -1 : 1;
        const m = winMetrics(win);
        if (e.altKey) {
            setWinMetrics(win, { track: Math.max(0, m.track + dir * 0.005) });
        } else if (e.shiftKey) {
            setWinMetrics(win, { width: Math.max(1, m.width + dir * 0.25) });
        } else if (e.ctrlKey) {
            setWinMetrics(win, { height: Math.max(1, m.height + dir * 0.25) });
        } else {
            setWinMetrics(win, { ratio: Math.max(0.05, m.ratio + dir * 0.01) });
        }
        updateWinDebugLabel();
    }, { passive: false });
});

/** Drag handler, called from the shared mousemove below. */
function dragDebugWindow(e) {
    const ib = radarInner().getBoundingClientRect();
    if (ib.width === 0 || ib.height === 0) return;
    setWinMetrics(winDragging, {
        left: winStartLeft + (e.clientX - winDragStartX) / ib.width * 100,
        top: winStartTop + (e.clientY - winDragStartY) / ib.height * 100,
    });
    updateWinDebugLabel();
}

document.addEventListener('keydown', (e) => {
    if (!winDebugActive || !winSelected) return;

    const NUDGE = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
    if (NUDGE[e.key]) {
        e.preventDefault();
        const step = (e.shiftKey ? 1.0 : 0.1);
        const m = winMetrics(winSelected);
        setWinMetrics(winSelected, {
            left: m.left + NUDGE[e.key][0] * step,
            top: m.top + NUDGE[e.key][1] * step,
        });
        updateWinDebugLabel();
        return;
    }

    // A: push the selected window's SIZE onto all five, leaving each one's position alone.
    if (e.key === 'a' || e.key === 'A') {
        e.preventDefault();
        const m = winMetrics(winSelected);
        winEls().forEach(w => setWinMetrics(w, {
            width: m.width, height: m.height, ratio: m.ratio, track: m.track,
        }));
        updateWinDebugLabel();
        return;
    }

    if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        const d = winDefaults[winSelected.id];
        if (d) setWinMetrics(winSelected, d);
        updateWinDebugLabel();
    }
});

/* ===== Layout: radar head ===== */

/* Scaling is the scroll wheel and only the scroll wheel. There used to be a drag handle in
   the bottom-right corner too, which set width and height independently — so it stretched the
   head out of proportion to its artwork instead of scaling it, and it sat there as a grey box
   on the world any time the remote was open. */
let isDragging = false;
let dragStartX, dragStartY, startLeft, startTop;
let isPlateDragging = false;
let plateDragStartX, plateDragStartY, plateStartLeft, plateStartTop;

let scale = 1.0;
let plateScale = 1.0;

/* Size is not part of a saved layout any more. The head's box comes from the stylesheet, at
   the artwork's own aspect ratio, and scale is the only thing that changes it — so a saved
   width and height could only ever carry forward a stretch from the old drag handle, with
   nothing left in the UI able to undo it. Older saves still have the fields; they are read
   and ignored. */
function applyPosition(x, y, scaleVal) {
    if (x !== undefined && y !== undefined) {
        container.style.right = 'auto';
        container.style.bottom = 'auto';
        container.style.left = (typeof x === 'number' && x <= 1) ? `${x * 100}%` : `${x}px`;
        container.style.top = (typeof y === 'number' && y <= 1) ? `${y * 100}%` : `${y}px`;
    }
    if (scaleVal !== undefined) {
        scale = scaleVal;
        container.style.transform = `scale(${scale})`;
    }
}

function savePosition() {
    /* The on-screen rect, which includes the transform — that is where the head actually is. */
    const rect = container.getBoundingClientRect();
    post('saveDisplay', {
        x: rect.left / window.innerWidth,
        y: rect.top / window.innerHeight,
        scale: scale,
    });
}

function applyPlatePosition(x, y, width, height, scaleVal) {
    if (!plateReader) return;
    if (x !== undefined && y !== undefined) {
        plateReader.style.left = (typeof x === 'number' && x <= 1) ? `${x * 100}%` : `${x}px`;
        plateReader.style.top = (typeof y === 'number' && y <= 1) ? `${y * 100}%` : `${y}px`;
        plateReader.style.right = 'auto';
        plateReader.style.bottom = 'auto';
    }
    if (width !== undefined) plateReader.style.width = `${width}px`;
    if (height !== undefined) plateReader.style.height = `${height}px`;
    if (scaleVal !== undefined) {
        plateScale = scaleVal;
        plateReader.style.transform = `scale(${plateScale})`;
        plateReader.style.transformOrigin = 'top left';
    }
}

function getPlatePositionData() {
    if (!plateReader) return null;
    const rect = plateReader.getBoundingClientRect();
    return {
        x: rect.left / window.innerWidth,
        y: rect.top / window.innerHeight,
        /* offset* = layout box before CSS transform; rect.* includes scale and skews saves. */
        width: Math.round(plateReader.offsetWidth),
        height: Math.round(plateReader.offsetHeight),
        scale: plateScale,
    };
}

function savePlatePosition() {
    requestAnimationFrame(() => {
        const data = getPlatePositionData();
        if (data) post('savePlateDisplay', data);
    });
}

let adjustMode = false;
let plateAdjustMode = false;
let remoteOpen = false;

/* Radar / plate move+scale: explicit move command OR while the remote overlay is open.
   Window calibration takes over the head's own pointer handling, so it locks both out —
   otherwise dragging a digit window would drag the whole head with it. */
function canLayoutDragRadar() { return (adjustMode || remoteOpen) && !winDebugActive; }
function canLayoutDragPlate() { return (plateAdjustMode || remoteOpen) && !winDebugActive; }

container.addEventListener('mousedown', (e) => {
    if (!canLayoutDragRadar()) return;
    if (e.target.closest && e.target.closest('#btn-power-radar')) return;
    isDragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    const rect = container.getBoundingClientRect();
    startLeft = rect.left;
    startTop = rect.top;
});

container.addEventListener('wheel', (e) => {
    if (!canLayoutDragRadar()) return;
    e.preventDefault();
    scale = Math.max(0.5, Math.min(2, scale + (e.deltaY > 0 ? -0.05 : 0.05)));
    container.style.transform = `scale(${scale})`;
    savePosition();
}, { passive: false });

function setAdjustMode(active) {
    adjustMode = active;
    if (active) plateAdjustMode = false;
    const hint = document.getElementById('adjust-hint');
    if (hint) hint.style.display = active ? 'block' : 'none';
    if (container) container.classList.toggle('nui-adjusting', !!active);
}

function setPlateAdjustMode(active) {
    plateAdjustMode = active;
    if (active) adjustMode = false;
    const hint = document.getElementById('adjust-hint');
    if (hint) hint.style.display = active ? 'block' : 'none';
    if (plateReader) {
        plateReader.classList.toggle('adjusting', !!active);
        if (active) plateReader.classList.add('visible');
    }
}

if (plateReader) {
    plateReader.addEventListener('mousedown', (e) => {
        if (!canLayoutDragPlate()) return;
        e.preventDefault();
        isPlateDragging = true;
        plateDragStartX = e.clientX;
        plateDragStartY = e.clientY;
        const rect = plateReader.getBoundingClientRect();
        plateStartLeft = rect.left;
        plateStartTop = rect.top;
    });

    plateReader.addEventListener('wheel', (e) => {
        if (!canLayoutDragPlate()) return;
        e.preventDefault();
        plateScale = Math.max(0.5, Math.min(2, plateScale + (e.deltaY > 0 ? -0.05 : 0.05)));
        plateReader.style.transform = `scale(${plateScale})`;
        plateReader.style.transformOrigin = 'top left';
        savePlatePosition();
    }, { passive: false });
}

/* ===== Layout: remote ===== */

const remoteOverlay = document.getElementById('remote-overlay');
const remoteWrap = document.getElementById('remote-wrap');

let remoteAdjustMode = false;
let remoteScale = 1.0;
let isRemoteDragging = false;
let remoteDragStartX, remoteDragStartY, remoteStartLeft, remoteStartTop;

/* The remote overlay is display:none while closed, so it measures 0x0 and any centring done
   then would pin it to the top-left corner. Centring is deferred until it is on screen. */
let remoteNeedsCenter = false;

function remoteIsMeasurable() {
    return !!remoteWrap && remoteWrap.getBoundingClientRect().width > 0;
}

/** Centre from the measured flex-centred box, so it lands centred at any resolution rather
 *  than at a fraction tuned for one aspect ratio. */
function centerRemote() {
    if (!remoteWrap) return;
    remoteWrap.classList.remove('positioned');
    remoteWrap.style.left = '';
    remoteWrap.style.top = '';
    remoteWrap.style.transform = '';

    const rect = remoteWrap.getBoundingClientRect();
    if (rect.width === 0) {
        // Hidden: leave it flex-centred (a correct fallback) and finish when it opens.
        remoteNeedsCenter = true;
        return;
    }

    remoteWrap.classList.add('positioned');
    /* .positioned switches transform-origin to top left, so offset by half the growth to
       keep a scaled remote visually centred. */
    remoteWrap.style.left = `${rect.left - (remoteScale - 1) * rect.width / 2}px`;
    remoteWrap.style.top = `${rect.top - (remoteScale - 1) * rect.height / 2}px`;
    remoteWrap.style.transform = `scale(${remoteScale})`;
    remoteNeedsCenter = false;
}

function applyRemotePosition(x, y, width, scaleVal) {
    if (!remoteWrap) return;
    if (width !== undefined) remoteWrap.style.width = `${width}px`;
    if (scaleVal !== undefined) remoteScale = scaleVal;

    if (typeof x === 'number' && typeof y === 'number') {
        remoteNeedsCenter = false;
        remoteWrap.classList.add('positioned');
        remoteWrap.style.left = x <= 1 ? `${x * 100}%` : `${x}px`;
        remoteWrap.style.top = y <= 1 ? `${y * 100}%` : `${y}px`;
        remoteWrap.style.right = 'auto';
        remoteWrap.style.bottom = 'auto';
        remoteWrap.style.transform = `scale(${remoteScale})`;
    } else {
        centerRemote();
    }
}

function saveRemotePosition() {
    // Never persist a measurement taken while hidden — it would save 0,0.
    if (!remoteIsMeasurable()) return;
    const rect = remoteWrap.getBoundingClientRect();
    post('saveRemoteDisplay', {
        x: rect.left / window.innerWidth,
        y: rect.top / window.innerHeight,
        /* offsetWidth = layout box before transform; rect.width includes scale and would
           compound it on every reload. Height follows the image aspect, so it isn't stored. */
        width: Math.round(remoteWrap.offsetWidth),
        scale: remoteScale,
    });
}

/** save:false is used by the reset path, which must not immediately re-write the KVP it
 *  just deleted. */
function setRemoteAdjustMode(active, { save = true } = {}) {
    remoteAdjustMode = !!active;
    if (remoteWrap) remoteWrap.classList.toggle('adjusting', remoteAdjustMode);
    if (!remoteAdjustMode) {
        isRemoteDragging = false;
        if (save) saveRemotePosition();
    }
}

if (remoteWrap) {
    /* Enter on a double-click of the remote body — deliberately not a button, so ordinary
       presses are untouched. Exit on a double-click anywhere, since .adjusting makes the
       buttons inert and the event lands on the wrap either way. */
    remoteWrap.addEventListener('dblclick', (e) => {
        if (!remoteOpen) return;
        if (!remoteAdjustMode && e.target.closest && e.target.closest('.remote-btn')) return;
        e.preventDefault();
        e.stopPropagation();
        setRemoteAdjustMode(!remoteAdjustMode);
    });

    remoteWrap.addEventListener('mousedown', (e) => {
        if (!remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        isRemoteDragging = true;
        remoteDragStartX = e.clientX;
        remoteDragStartY = e.clientY;
        const rect = remoteWrap.getBoundingClientRect();
        remoteStartLeft = rect.left;
        remoteStartTop = rect.top;
    });

    remoteWrap.addEventListener('wheel', (e) => {
        if (!remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        remoteScale = Math.max(0.5, Math.min(2, remoteScale + (e.deltaY > 0 ? -0.05 : 0.05)));
        remoteWrap.style.transform = `scale(${remoteScale})`;
        saveRemotePosition();
    }, { passive: false });
}

/* ===== Shared pointer handling ===== */

document.addEventListener('mousemove', (e) => {
    if (isDragging) {
        container.style.left = `${startLeft + (e.clientX - dragStartX)}px`;
        container.style.top = `${startTop + (e.clientY - dragStartY)}px`;
        container.style.right = 'auto';
        container.style.bottom = 'auto';
    }
    if (isPlateDragging && plateReader) {
        plateReader.style.left = `${plateStartLeft + (e.clientX - plateDragStartX)}px`;
        plateReader.style.top = `${plateStartTop + (e.clientY - plateDragStartY)}px`;
        plateReader.style.right = 'auto';
        plateReader.style.bottom = 'auto';
    }
    if (isRemoteDragging && remoteWrap) {
        remoteWrap.style.left = `${remoteStartLeft + (e.clientX - remoteDragStartX)}px`;
        remoteWrap.style.top = `${remoteStartTop + (e.clientY - remoteDragStartY)}px`;
        remoteWrap.style.right = 'auto';
        remoteWrap.style.bottom = 'auto';
    }
    if (debugDragging) dragDebugButton(e);
    if (winDragging) dragDebugWindow(e);
});

document.addEventListener('mouseup', () => {
    if (isDragging) savePosition();
    if (isPlateDragging) savePlatePosition();
    if (isRemoteDragging) { isRemoteDragging = false; saveRemotePosition(); }
    winDragging = null;
    isDragging = false;
    isPlateDragging = false;
    if (debugDragging) {
        console.log(`#${debugDragging.id} { top: ${parseFloat(debugDragging.style.top).toFixed(1)}%; left: ${parseFloat(debugDragging.style.left).toFixed(1)}%; }`);
        debugDragging = null;
    }
});

/* ===== Remote buttons ===== */

let debugMode = false;
let debugDragging = null;
let debugDragStartX = 0, debugDragStartY = 0;
let debugBtnStartLeft = 0, debugBtnStartTop = 0;

/** Half-second hold threshold; overwritten by Config.holdThresholdMs at init. */
let holdThresholdMs = 500;

function showRemote(show, debug) {
    remoteOpen = show;
    // Closing must not leave adjust mode armed for the next time it opens.
    if (!show && remoteAdjustMode) setRemoteAdjustMode(false);
    debugMode = !!debug;
    if (remoteOverlay) remoteOverlay.classList.toggle('active', show);
    // Now that it is laid out, finish any centring deferred while hidden.
    if (show && remoteNeedsCenter) centerRemote();
    if (remoteWrap && debug !== undefined) remoteWrap.classList.toggle('debug', !!debug);
    const exportBtn = document.getElementById('debug-export');
    if (exportBtn) exportBtn.style.display = debug ? 'block' : 'none';
    /* While the remote is open, drag/scale the head and plate reader directly. */
    if (container) container.classList.toggle('remote-layout-drag', !!show);
    if (plateReader) plateReader.classList.toggle('remote-layout-drag', !!show);
}

/* Press tracking for the dual-function keys. The hold action fires the instant the threshold
   passes — the hardware does not wait for the release — and the release is then swallowed so
   one press never sends both actions. */
const pressState = new WeakMap();

function beginPress(btn) {
    const holdAction = btn.dataset.holdAction;
    const state = { holdFired: false, timer: null };
    if (holdAction) {
        state.timer = setTimeout(() => {
            state.holdFired = true;
            btn.classList.add('holding');
            postRemoteAction(holdAction, btn.dataset.row, true);
        }, holdThresholdMs);
    }
    pressState.set(btn, state);
}

function endPress(btn, fire) {
    const state = pressState.get(btn);
    pressState.delete(btn);
    btn.classList.remove('holding');
    if (!state) return;
    clearTimeout(state.timer);
    if (fire && !state.holdFired) {
        postRemoteAction(btn.dataset.action, btn.dataset.row, false);
    }
}

document.querySelectorAll('.remote-btn').forEach(btn => {
    btn.addEventListener('mousedown', (e) => {
        if (debugMode) {
            e.preventDefault();
            e.stopPropagation();
            debugSelect(btn, e);
            return;
        }
        if (remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        beginPress(btn);
    });

    btn.addEventListener('mouseup', (e) => {
        if (debugMode || remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        endPress(btn, true);
    });

    /* Dragging off the button cancels the press without firing, same as a real key. */
    btn.addEventListener('mouseleave', () => {
        if (debugMode || remoteAdjustMode) return;
        endPress(btn, false);
    });

    btn.addEventListener('click', (e) => {
        // Presses are handled on mousedown/mouseup; block the synthesised click.
        e.preventDefault();
        e.stopPropagation();
    });

    // Scroll on a button in debug mode: shift=width, ctrl=height, plain=both.
    btn.addEventListener('wheel', (e) => {
        if (!debugMode) return;
        e.preventDefault();
        e.stopPropagation();
        const wrapRect = remoteWrap.getBoundingClientRect();
        const step = e.deltaY > 0 ? -1 : 1;
        const rect = btn.getBoundingClientRect();
        if (e.shiftKey || (!e.shiftKey && !e.ctrlKey)) {
            btn.style.width = `${Math.max(2, rect.width / wrapRect.width * 100 + step)}%`;
        }
        if (e.ctrlKey || (!e.shiftKey && !e.ctrlKey)) {
            btn.style.height = `${Math.max(2, rect.height / wrapRect.height * 100 + step)}%`;
        }
    }, { passive: false });
});

function debugSelect(btn, e) {
    document.querySelectorAll('.remote-btn').forEach(b => b.classList.remove('debug-selected'));
    btn.classList.add('debug-selected');
    debugDragging = btn;
    debugDragStartX = e.clientX;
    debugDragStartY = e.clientY;
    const wrapRect = remoteWrap.getBoundingClientRect();
    const btnRect = btn.getBoundingClientRect();
    debugBtnStartLeft = btnRect.left - wrapRect.left;
    debugBtnStartTop = btnRect.top - wrapRect.top;
}

function dragDebugButton(e) {
    const wrapRect = remoteWrap.getBoundingClientRect();
    debugDragging.style.left = `${(debugBtnStartLeft + (e.clientX - debugDragStartX)) / wrapRect.width * 100}%`;
    debugDragging.style.top = `${(debugBtnStartTop + (e.clientY - debugDragStartY)) / wrapRect.height * 100}%`;
}

function exportButtonCSS() {
    const wrapRect = remoteWrap.getBoundingClientRect();
    let css = '';
    document.querySelectorAll('.remote-btn').forEach(btn => {
        const rect = btn.getBoundingClientRect();
        const left = ((rect.left - wrapRect.left) / wrapRect.width * 100).toFixed(1);
        const top = ((rect.top - wrapRect.top) / wrapRect.height * 100).toFixed(1);
        const w = (rect.width / wrapRect.width * 100).toFixed(1);
        const h = (rect.height / wrapRect.height * 100).toFixed(1);
        css += `${('#' + btn.id).padEnd(16)}{ top: ${top}%; left: ${left}%; width: ${w}%; height: ${h}%; }\n`;
    });
    const output = document.getElementById('debug-output');
    if (output) {
        output.value = css;
        output.style.display = 'block';
        output.select();
    }
    console.log(css);
}

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    // Window calibration is modal over everything else on the head.
    if (winDebugActive) {
        setWindowDebug(false);
        post('exitWindowDebug', {});
        return;
    }
    // Exit layout adjust first so the remote overlay can stay open.
    if (adjustMode) {
        setAdjustMode(false);
        post('exitAdjustMode', {});
    } else if (plateAdjustMode) {
        const data = getPlatePositionData();
        setPlateAdjustMode(false);
        post('exitPlateAdjustMode', data || {});
    } else if (remoteAdjustMode) {
        // Finish repositioning first so ESC doesn't also close the remote.
        setRemoteAdjustMode(false);
    } else if (remoteOpen) {
        showRemote(false);
        post('closeRemote', {});
    }
});

/* ===== Messages from Lua ===== */

window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data._type) return;

    switch (data._type) {
        case 'init':
            if (typeof data.holdThresholdMs === 'number' && data.holdThresholdMs > 0) {
                holdThresholdMs = data.holdThresholdMs;
            }
            if (data.display) {
                const d = data.display;
                scale = d.scale || 1;
                applyPosition(d.x, d.y, scale);
            }
            if (data.plateDisplay) {
                const p = data.plateDisplay;
                plateScale = p.scale || 1;
                applyPlatePosition(p.x, p.y, p.width, p.height, plateScale);
            }
            if (data.remoteDisplay) {
                const r = data.remoteDisplay;
                applyRemotePosition(r.x, r.y, r.width, r.scale || 1);
            }
            break;

        case 'update':
            updateDisplay(data);
            break;

        case 'resetDisplay':
            if (data.display) {
                const d = data.display;
                scale = d.scale || 1;
                applyPosition(d.x, d.y, scale);
            }
            break;

        case 'resetRemoteDisplay': {
            const r = data.remoteDisplay || {};
            if (remoteAdjustMode) setRemoteAdjustMode(false, { save: false });
            applyRemotePosition(r.x, r.y, r.width, r.scale || 1);
            break;
        }

        case 'adjustMode':
            setAdjustMode(true);
            break;

        case 'plateAdjustMode':
            setPlateAdjustMode(true);
            break;

        case 'windowDebug':
            setWindowDebug(data.active !== false);
            break;

        case 'audio':
            playSound(data.name, data.vol ?? 1.0);
            break;

        case 'multiBeep': {
            const count = data.count || 1;
            const vol = data.vol ?? 1.0;
            let i = 0;
            const interval = setInterval(() => {
                playSound('Beep', vol);
                if (++i >= count) clearInterval(interval);
            }, 180);
            break;
        }

        case 'selfTest':
            runSelfTestSequence(data.vol ?? 1.0);
            break;

        case 'lampTest':
            runLampTest();
            break;

        /* Three words: antenna, then mode, then direction — "front, opposite, closing".
           Ten combinations are reachable; a missing middle sample degrades to two words. */
        case 'voiceEnunciator': {
            const MODE_WORD = { stationary: 'Stationary', opposite: 'Opposite', same: 'Same' };
            const names = [];
            if (data.antenna) names.push(data.antenna === 'front' ? 'Front' : 'Rear');
            if (data.mode && MODE_WORD[data.mode]) names.push(MODE_WORD[data.mode]);
            if (data.direction) names.push(data.direction === 'closing' ? 'Closing' : 'Away');
            if (names.length > 0) playVoiceSequence(names, data.vol ?? 1.0);
            break;
        }

        case 'trafficAlert':
            setTrafficAlert(!!data.active, data.vol ?? 1.0);
            break;

        case 'tempDisplay':
            showTempDisplay(data);
            break;

        case 'showRemote':
            showRemote(true, data.debug);
            break;

        case 'hideRemote':
            showRemote(false);
            break;
    }
});
