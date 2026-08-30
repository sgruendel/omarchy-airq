const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Model.js starts with the QML directive `.pragma library`, which is not
// valid JavaScript. Strip it and evaluate the file with a `module` global so
// its own export guard fills module.exports.
function loadModel() {
  const file = path.join(__dirname, "..", "Model.js")
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library[^\n]*\n/, "")
  const module = { exports: {} }
  new Function("module", "exports", source)(module, module.exports)
  return module.exports
}

const Model = loadModel()

// Captured from a physical air-Q /data/ endpoint using this disposable password.
const deviceResponse = fs.readFileSync(
  path.join(__dirname, "fixtures", "device-response.json"), "utf8")
const deviceResponsePassword = "password"

function samplePayload() {
  return {
    co2: [654.3, 12],
    temperature: [22.16, 0.1],
    humidity: [45.24, 0.5],
    radon: [42.4, 8],
    tvoc: [220.6, 15],
    health: 935,
    performance: 872,
    Status: "OK",
    timestamp: 1756600000000
  }
}

test("decrypts a response captured from a real device", () => {
  const parsed = Model.parseDataResponse(deviceResponse, deviceResponsePassword)

  assert.deepEqual(parsed, {
    tvoc: [8.9, 1.3],
    performance: 800,
    mold: [36.5, 20],
    humidity_abs: [12.617, 0.77],
    health: 994,
    measuretime: 1960,
    timestamp: 1788077138000,
    dHdt: 0,
    DeviceID: "c06df91b49d6dd86fb5013c1c7b7216f",
    Status: "OK",
    pressure_rel: [1016.44, 2.23],
    humidity: [72.082, 7.63],
    radon: [12.9, 9],
    pressure: [991.09, 1],
    temperature: [20.146, 1.05],
    uptime: 41,
    dewpt: [15.417, 0.96]
  })
})

test("rejects a wrong password, malformed envelopes, and oversized input", () => {
  assert.equal(Model.parseDataResponse(deviceResponse, "wrong-password"), null)
  assert.equal(Model.parseDataResponse(deviceResponse, ""), null)
  assert.equal(Model.parseDataResponse("not json", "device-password"), null)
  assert.equal(Model.parseDataResponse("{}", "device-password"), null)
  assert.equal(Model.parseDataResponse(JSON.stringify({ content: 42 }), "device-password"), null)
  assert.equal(Model.parseDataResponse(JSON.stringify({ content: "A".repeat(70000) }), "device-password"), null)
  assert.equal(Model.decryptContent("AAAA", "device-password"), "")
})

test("reads scalar and [value, uncertainty] sensor readings", () => {
  const data = { co2: [654.3, 12], health: 935, broken: "n/a" }

  assert.equal(Model.number(data, "co2"), 654.3)
  assert.equal(Model.number(data, "health"), 935)
  assert.ok(Number.isNaN(Model.number(data, "missing")))
  assert.ok(Number.isNaN(Model.number(data, "broken")))
  assert.ok(Number.isNaN(Model.number(null, "co2")))
  assert.equal(Model.uncertainty(data, "co2"), 12)
  assert.ok(Number.isNaN(Model.uncertainty(data, "health")))
})

test("formats rounded readings, scores, and index percentages", () => {
  const data = { temperature: [22.16, 0.1], health: 935 }

  assert.equal(Model.rounded(22.16, 1), "22.2")
  assert.equal(Model.rounded(NaN, 1), "—")
  assert.equal(Model.reading(data, "temperature", 1, "°C"), "22.2 °C")
  assert.equal(Model.reading(data, "missing", 1, "°C"), "—")
  assert.equal(Model.score(data, "health"), "93.5%")
  assert.equal(Model.indexPercent(data, "health"), 93.5)
})

test("classifies health index and radon states at their thresholds", () => {
  assert.equal(Model.indexState(80, 80, 60), "green")
  assert.equal(Model.indexState(79.9, 80, 60), "yellow")
  assert.equal(Model.indexState(59.9, 80, 60), "red")
  assert.equal(Model.indexState(NaN, 80, 60), "unavailable")

  assert.equal(Model.radonState(50, 100), "Good")
  assert.equal(Model.radonState(100, 100), "Elevated")
  assert.equal(Model.radonState(300, 100), "High")
  assert.equal(Model.radonState(150, NaN), "Elevated")
  assert.equal(Model.radonState(NaN, 100), "Waiting for data")
})

test("builds metric rows only for sensors with readings", () => {
  const rows = Model.metricRows({ co2: [654.3, 12], temperature: [22.16, 0.1], broken: "n/a" })

  assert.deepEqual(rows, [
    { key: "temperature", label: "Temperature", text: "22.2 °C" },
    { key: "co2", label: "CO₂", text: "654 ppm" }
  ])
})

test("normalizes the device Status field into lines", () => {
  assert.deepEqual(Model.statusLines({}), [])
  assert.deepEqual(Model.statusLines({ Status: "OK" }), [])
  assert.deepEqual(Model.statusLines({ Status: "co2 sensor warming up" }), ["co2 sensor warming up"])
  assert.deepEqual(Model.statusLines({ Status: { co2: "co2 sensor error", radon: "radon sensor error" } }),
    ["co2 sensor error", "radon sensor error"])
})

test("describes measurement age in seconds, minutes, or hours", () => {
  const now = 1756600000000

  assert.equal(Model.measurementAge(now - 45 * 1000, now), "45s ago")
  assert.equal(Model.measurementAge(now - 5 * 60 * 1000, now), "5min ago")
  assert.equal(Model.measurementAge(now - 3 * 60 * 60 * 1000, now), "3h ago")
  assert.equal(Model.measurementAge(undefined, now), "unknown age")
  assert.equal(Model.measurementAge(now - 1000, NaN), "unknown age")
})

test("composes tooltip lines and marks stale readings", () => {
  const data = samplePayload()
  const now = data.timestamp + 30 * 1000

  const fresh = Model.tooltipText(data, now, false)
  assert.ok(fresh.startsWith("Radon: 42 Bq/m³\n"))
  assert.ok(fresh.includes("\nCO₂: 654 ppm\n"))
  assert.ok(fresh.endsWith("Measured 30s ago"))

  const stale = Model.tooltipText(data, now, true)
  assert.ok(stale.endsWith("Measured 30s ago · stale"))

  assert.equal(Model.tooltipText(null, now, false), "")
})

test("escapes tooltip text into an inert rich-text document", () => {
  assert.equal(Model.inertTooltipText("a & <b>\r\nc"), "<qt>a &amp; &lt;b&gt;<br>c</qt>")
  assert.equal(Model.inertTooltipText(null), "<qt></qt>")
})
