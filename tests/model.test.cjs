// Run: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const M = require(path.join(__dirname, "..", "Model.js"))

test("state older than the stale window is offline", () => {
  assert.equal(M.isOnline({ time: 100 }, 102), true)
  assert.equal(M.isOnline({ time: 100 }, 110), false)
  assert.equal(M.isOnline(null, 100), false)
  assert.equal(M.isOnline({ time: "x" }, 100), false)
})

test("parseState rejects junk", () => {
  assert.equal(M.parseState(""), null)
  assert.equal(M.parseState("[1]"), null)
  assert.equal(M.parseState("{oops"), null)
  assert.deepEqual(M.parseState('{"a":1}'), { a: 1 })
})

test("normalizeConfig matches the daemon's collision rules", () => {
  assert.deepEqual(
    [M.normalizeConfig({ rampStart: 84, fullBlast: 85 }, "rampStart")].map(c => [c.rampStart, c.fullBlast])[0],
    [84, 89])
  assert.deepEqual(
    [M.normalizeConfig({ rampStart: 55, fullBlast: 50 }, "fullBlast")].map(c => [c.rampStart, c.fullBlast])[0],
    [45, 50])
  assert.equal(M.normalizeConfig({ mode: "turbo" }).mode, "auto")
  assert.equal(M.normalizeConfig({ manualRpm: 1e9 }).manualRpm, 8000)
})

test("overrides win until the daemon agrees or they expire", () => {
  const cfg = { mode: "auto", manualRpm: 3000 }
  let r = M.mergeOverrides(cfg, { mode: { value: "manual", at: 0 } }, 1000, 4000)
  assert.equal(r.config.mode, "manual")
  assert.ok(r.overrides.mode)
  r = M.mergeOverrides({ mode: "manual" }, { mode: { value: "manual", at: 0 } }, 1000, 4000)
  assert.equal(r.overrides.mode, undefined)
  r = M.mergeOverrides(cfg, { mode: { value: "manual", at: 0 } }, 5000, 4000)
  assert.equal(r.config.mode, "auto")
})

test("curve and percent", () => {
  assert.equal(M.curveRpm(40, 55, 85, 1200, 7200), 1200)
  assert.equal(M.curveRpm(70, 55, 85, 1200, 7200), 4200)
  assert.equal(M.curveRpm(99, 55, 85, 1200, 7200), 7200)
  assert.equal(M.fanPercent(4200, 1200, 7200), 50)
  assert.equal(M.fanPercent(100, 1200, 7200), 0)
  assert.equal(M.fanPercent(100, 0, 0), 0)
})

test("bar glyph tracks state", () => {
  assert.equal(M.barGlyph(false, null), M.GLYPH.off)
  assert.equal(M.barGlyph(true, { control: { reason: "full-blast" }, config: { mode: "auto" } }), M.GLYPH.alert)
  assert.equal(M.barGlyph(true, { control: null, config: { mode: "system" } }), M.GLYPH.smc)
  assert.equal(M.barGlyph(true, { control: { reason: "curve" }, config: { mode: "auto" } }), M.GLYPH.fan)
})

test("pushSample keeps a bounded window", () => {
  let list = []
  for (let i = 0; i < 10; i++) list = M.pushSample(list, i, 4)
  assert.deepEqual(list, [6, 7, 8, 9])
})

test("sliders per mode", () => {
  assert.deepEqual(M.slidersFor("auto"), ["rampStart", "fullBlast"])
  assert.deepEqual(M.slidersFor("system"), [])
  assert.deepEqual(M.sliderRange("manualRpm", { min: 1200, max: 7200 }), [1200, 7200])
  assert.deepEqual(M.sliderRange("manualRpm", null), [1200, 7200])
})

test("sensor lookups", () => {
  const s = { sensors: [{ id: "cpu", name: "CPU Package", temp: 71.5 }] }
  assert.equal(M.sensorTemp(s, "cpu"), 71.5)
  assert.ok(Number.isNaN(M.sensorTemp(s, "gpu")))
  assert.equal(M.sensorName(s, "cpu"), "CPU Package")
})

test("normalizeConfig keeps the hold temperature below full blast", () => {
  let c = M.normalizeConfig({ targetTemp: 70, fullBlast: 65 }, "fullBlast")
  assert.deepEqual([c.targetTemp, c.fullBlast], [60, 65])
  c = M.normalizeConfig({ targetTemp: 88, fullBlast: 85 }, "targetTemp")
  assert.deepEqual([c.targetTemp, c.fullBlast], [88, 93])
  c = M.normalizeConfig({ targetTemp: 69, fullBlast: 65, rampStart: 47 })
  assert.deepEqual([c.rampStart, c.targetTemp, c.fullBlast], [47, 60, 65])
})

test("safeText neutralizes markup-shaped input and bounds length", () => {
  const out = M.safeText('<img src="https://example.invalid/tracker">', 64)
  assert.ok(!out.includes("<") && !out.includes(">"))
  assert.equal(M.safeText("a\u0000b\nc", 10), "abc")
  assert.equal(M.safeText("x".repeat(100), 10).length, 10)
  assert.equal(M.safeText(null, 10), "")
  assert.equal(M.safeText({ toString() { return "<b>" } }, 10), "‹b›")
})

test("sanitizeSensors drops bad ids, bounds names and the list", () => {
  const list = M.sanitizeSensors([
    { id: "cpu", name: "<b>CPU</b> Package", temp: 71.5 },
    { id: "../etc", name: "bad", temp: 1 },
    { id: "gpu", name: "y".repeat(200), temp: "60" },
    { id: "ssd", name: "SSD", temp: "hot" },
    null
  ])
  assert.deepEqual(list.map(s => s.id), ["cpu", "gpu"])
  assert.ok(!list[0].name.includes("<"))
  assert.equal(list[1].name.length, M.MAX_NAME)
  assert.equal(list[1].temp, 60)
  assert.equal(M.sanitizeSensors(Array.from({ length: 100 }, (_, i) => ({ id: "s" + i, name: "n", temp: 1 }))).length, M.MAX_SENSORS)
  assert.deepEqual(M.sanitizeSensors("nope"), [])
})

test("the tooltip sink never receives markup", () => {
  const state = { sensors: [{ id: "cpu", name: '<img src="https://example.invalid/t">', temp: 70 }] }
  assert.ok(!M.sensorName(state, "cpu").includes("<"))
  assert.ok(!M.sensorName(state, "<script>").includes("<"))
})
