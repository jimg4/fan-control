// Pure helpers for the fan-control panel. No QML here, so tests/model.test.cjs
// can load this file under Node.

// Must match daemon/fanctl.py.
var MODES = ["auto", "target", "manual", "system"]
var LIMITS = {
  manualRpm: [1000, 8000],
  targetTemp: [35, 90],
  rampStart: [30, 90],
  fullBlast: [40, 95]
}
var MIN_CURVE_SPAN = 5  // °C that rampStart and targetTemp stay below fullBlast
var MAX_NAME = 40       // characters of daemon-supplied text shown in one label
var MAX_ERROR = 200
var MAX_SENSORS = 32
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
  // Same rule as the daemon: the key just moved pushes full blast up,
  // otherwise full blast stands and the others come down to meet it.
  if (prefer === "rampStart" || prefer === "targetTemp")
    cfg.fullBlast = Math.min(LIMITS.fullBlast[1], Math.max(cfg.fullBlast, cfg[prefer] + MIN_CURVE_SPAN))
  cfg.rampStart = Math.min(cfg.rampStart, cfg.fullBlast - MIN_CURVE_SPAN)
  cfg.targetTemp = Math.min(cfg.targetTemp, cfg.fullBlast - MIN_CURVE_SPAN)
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

// Text from state.json or a subprocess, made safe for any Text sink: no
// control characters, no angle brackets for a rich-text parser to act on
// (swapped for look-alikes), and at most maxLength characters.
function safeText(value, maxLength) {
  if (value === null || value === undefined) return ""
  var text = String(value).replace(/[\u0000-\u001f\u007f]/g, "").replace(/</g, "\u2039").replace(/>/g, "\u203a")
  return text.length > maxLength ? text.slice(0, maxLength) : text
}

var SENSOR_ID = /^[a-z0-9-]{1,32}$/

// The daemon's sensor list, validated: known-shape ids, bounded names,
// numeric temperatures, and at most MAX_SENSORS entries.
function sanitizeSensors(list) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length && out.length < MAX_SENSORS; i++) {
    var s = list[i]
    if (!s || typeof s !== "object" || !SENSOR_ID.test(String(s.id))) continue
    var temp = Number(s.temp)
    if (!isFinite(temp)) continue
    out.push({ id: String(s.id), name: safeText(s.name || s.id, MAX_NAME), temp: temp })
  }
  return out
}

function sensorTemp(state, id) {
  var list = sanitizeSensors(state && state.sensors)
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i].temp
  return NaN
}

function sensorName(state, id) {
  var list = sanitizeSensors(state && state.sensors)
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i].name
  return safeText(id, MAX_NAME)
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
    MAX_NAME: MAX_NAME, MAX_ERROR: MAX_ERROR, MAX_SENSORS: MAX_SENSORS, safeText: safeText, sanitizeSensors: sanitizeSensors,
    isOnline: isOnline, parseState: parseState, clamp: clamp, normalizeConfig: normalizeConfig,
    mergeOverrides: mergeOverrides, fanPercent: fanPercent, curveRpm: curveRpm, isOverride: isOverride,
    barGlyph: barGlyph, sensorTemp: sensorTemp, sensorName: sensorName, pushSample: pushSample,
    slidersFor: slidersFor, sliderStep: sliderStep, sliderRange: sliderRange
  }
}
