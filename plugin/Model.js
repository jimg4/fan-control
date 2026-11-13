// Pure helpers for the fan-control panel. No QML here, so tests/model.test.cjs
// can load this file under Node.

// Must match daemon/fanctl.py.
var MODES = ["auto", "target", "manual", "system"]
var LIMITS = {
  manualRpm: [1000, 8000],
  targetTemp: [45, 90],
  rampStart: [30, 90],
  fullBlast: [40, 95]
}
var MIN_CURVE_SPAN = 5
var DEFAULTS = { mode: "auto", sensor: "cpu", manualRpm: 3000, targetTemp: 70, rampStart: 55, fullBlast: 85 }

// The daemon writes state once a second; older than this means it stopped.
var STALE_SECONDS = 5

// Material Design glyphs from the Nerd Font.
var GLYPH = {
  off: "\u{f081d}",     // fan-off
  alert: "\u{f146c}",   // fan-alert
  smc: "\u{f171d}",     // fan-auto
  fan: "\u{f0210}"      // fan
}

function isOnline(state, nowSeconds) {
  if (!state || typeof state !== "object") return false
  var t = Number(state.time)
  return isFinite(t) && nowSeconds - t < STALE_SECONDS
}

function parseState(text) {
  var raw = String(text || "").trim()
  if (raw.length === 0 || raw.length > 256 * 1024 || raw.charAt(0) !== "{") return null
  try {
    var parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null
  } catch (e) {
    return null
  }
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Mirror the daemon's normalization so the panel never shows a value the
// daemon will refuse. `prefer` is the key the user just moved.
function normalizeConfig(raw, prefer) {
  var cfg = {}
  for (var key in DEFAULTS) cfg[key] = DEFAULTS[key]
  if (raw && typeof raw === "object") {
    for (var k in DEFAULTS) if (raw[k] !== undefined && raw[k] !== null) cfg[k] = raw[k]
  }
  if (MODES.indexOf(cfg.mode) < 0) cfg.mode = DEFAULTS.mode
  cfg.sensor = String(cfg.sensor)
  for (var name in LIMITS) {
    var n = Number(cfg[name])
    cfg[name] = isFinite(n) ? clamp(Math.round(n), LIMITS[name][0], LIMITS[name][1]) : DEFAULTS[name]
  }
  if (cfg.fullBlast - cfg.rampStart < MIN_CURVE_SPAN) {
    if (prefer === "rampStart") {
      cfg.fullBlast = Math.min(LIMITS.fullBlast[1], cfg.rampStart + MIN_CURVE_SPAN)
      cfg.rampStart = cfg.fullBlast - MIN_CURVE_SPAN
    } else {
      cfg.rampStart = Math.max(LIMITS.rampStart[0], cfg.fullBlast - MIN_CURVE_SPAN)
      cfg.fullBlast = cfg.rampStart + MIN_CURVE_SPAN
    }
  }
  return cfg
}

// Panel edits are applied optimistically and kept on top of the daemon's
// config until the daemon reports the same value back, or they expire.
function mergeOverrides(config, overrides, nowMs, ttlMs) {
  var merged = {}
  var live = {}
  var source = config || {}
  for (var key in source) merged[key] = source[key]
  for (var k in overrides || {}) {
    var o = overrides[k]
    if (!o || nowMs - o.at > ttlMs) continue
    if (source[k] === o.value) continue
    merged[k] = o.value
    live[k] = o
  }
  return { config: merged, overrides: live }
}

function fanPercent(rpm, min, max) {
  if (!(max > min)) return 0
  return Math.round(clamp((rpm - min) / (max - min), 0, 1) * 100)
}

function curveRpm(temp, rampStart, fullBlast, fanMin, fanMax) {
  if (temp <= rampStart) return fanMin
  if (temp >= fullBlast) return fanMax
  return fanMin + (temp - rampStart) / (fullBlast - rampStart) * (fanMax - fanMin)
}

function isOverride(reason) {
  return reason === "full-blast" || reason === "hard-limit" || reason === "sensor-lost"
}

function barGlyph(online, state) {
  if (!online) return GLYPH.off
  var control = state && state.control
  if (control && isOverride(control.reason)) return GLYPH.alert
  if (state && state.config && state.config.mode === "system") return GLYPH.smc
  return GLYPH.fan
}

function sensorTemp(state, id) {
  var list = state && Array.isArray(state.sensors) ? state.sensors : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) return Number(list[i].temp)
  return NaN
}

function sensorName(state, id) {
  var list = state && Array.isArray(state.sensors) ? state.sensors : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) return String(list[i].name || id)
  return String(id || "")
}

// Fixed-length ring of samples for the history chart.
function pushSample(list, value, max) {
  var next = (list || []).slice(Math.max(0, (list || []).length - max + 1))
  next.push(value)
  return next
}

// Which slider rows each mode shows, in order.
function slidersFor(mode) {
  if (mode === "auto") return ["rampStart", "fullBlast"]
  if (mode === "target") return ["targetTemp", "fullBlast"]
  if (mode === "manual") return ["manualRpm", "fullBlast"]
  return []
}

function sliderStep(key) {
  return key === "manualRpm" ? 100 : 1
}

// Slider bounds; RPM follows the fan's own range when known.
function sliderRange(key, fan) {
  if (key === "manualRpm") {
    var lo = fan && fan.min > 0 ? fan.min : 1200
    var hi = fan && fan.max > lo ? fan.max : 7200
    return [lo, hi]
  }
  return LIMITS[key]
}

if (typeof module !== "undefined") {
  module.exports = {
    MODES: MODES, LIMITS: LIMITS, DEFAULTS: DEFAULTS, GLYPH: GLYPH, STALE_SECONDS: STALE_SECONDS,
    isOnline: isOnline, parseState: parseState, clamp: clamp, normalizeConfig: normalizeConfig,
    mergeOverrides: mergeOverrides, fanPercent: fanPercent, curveRpm: curveRpm, isOverride: isOverride,
    barGlyph: barGlyph, sensorTemp: sensorTemp, sensorName: sensorName, pushSample: pushSample,
    slidersFor: slidersFor, sliderStep: sliderStep, sliderRange: sliderRange
  }
}
