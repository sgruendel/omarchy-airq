.pragma library

// The local API returns base64(IV || AES-256-CBC(JSON)). Keeping decryption
// here lets the password come from Secret Service without ever becoming a
// command-line argument.

function xtime(a) {
  a <<= 1
  if (a & 0x100) a ^= 0x11b
  return a & 0xff
}

function gmul(a, b) {
  var result = 0
  while (b) {
    if (b & 1) result ^= a
    a = xtime(a)
    b >>= 1
  }
  return result
}

function gpow(a, exponent) {
  var result = 1
  while (exponent) {
    if (exponent & 1) result = gmul(result, a)
    a = gmul(a, a)
    exponent >>= 1
  }
  return result
}

function rotl8(value, amount) {
  return ((value << amount) | (value >> (8 - amount))) & 0xff
}

var SBOX = null
var INV_SBOX = null
var RCON = null

function buildTables() {
  if (SBOX) return
  SBOX = new Array(256)
  INV_SBOX = new Array(256)
  RCON = new Array(15)
  for (var i = 0; i < 256; i++) {
    var inverse = i === 0 ? 0 : gpow(i, 254)
    var mapped = (inverse ^ rotl8(inverse, 1) ^ rotl8(inverse, 2)
      ^ rotl8(inverse, 3) ^ rotl8(inverse, 4) ^ 0x63) & 0xff
    SBOX[i] = mapped
    INV_SBOX[mapped] = i
  }
  var coefficient = 1
  for (var r = 0; r < 15; r++) {
    RCON[r] = coefficient
    coefficient = xtime(coefficient)
  }
}

function expandKey(keyBytes) {
  buildTables()
  var words = new Array(60)
  for (var i = 0; i < 8; i++)
    words[i] = [keyBytes[4 * i], keyBytes[4 * i + 1], keyBytes[4 * i + 2], keyBytes[4 * i + 3]]
  for (i = 8; i < 60; i++) {
    var value = words[i - 1].slice()
    if (i % 8 === 0) {
      value = [SBOX[value[1]], SBOX[value[2]], SBOX[value[3]], SBOX[value[0]]]
      value[0] ^= RCON[i / 8 - 1]
    } else if (i % 8 === 4) {
      value = [SBOX[value[0]], SBOX[value[1]], SBOX[value[2]], SBOX[value[3]]]
    }
    words[i] = [
      words[i - 8][0] ^ value[0], words[i - 8][1] ^ value[1],
      words[i - 8][2] ^ value[2], words[i - 8][3] ^ value[3]
    ]
  }
  return words
}

function addRoundKey(state, words, round) {
  for (var column = 0; column < 4; column++)
    for (var row = 0; row < 4; row++)
      state[row + 4 * column] ^= words[round * 4 + column][row]
}

function invSubBytes(state) {
  for (var i = 0; i < 16; i++) state[i] = INV_SBOX[state[i]]
}

function invShiftRows(state) {
  var value
  value = state[13]; state[13] = state[9]; state[9] = state[5]; state[5] = state[1]; state[1] = value
  value = state[2]; state[2] = state[10]; state[10] = value
  value = state[6]; state[6] = state[14]; state[14] = value
  value = state[3]; state[3] = state[7]; state[7] = state[11]; state[11] = state[15]; state[15] = value
}

function invMixColumns(state) {
  for (var column = 0; column < 4; column++) {
    var i = 4 * column
    var a0 = state[i], a1 = state[i + 1], a2 = state[i + 2], a3 = state[i + 3]
    state[i]     = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9)
    state[i + 1] = gmul(a0, 9)  ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13)
    state[i + 2] = gmul(a0, 13) ^ gmul(a1, 9)  ^ gmul(a2, 14) ^ gmul(a3, 11)
    state[i + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9)  ^ gmul(a3, 14)
  }
}

function decryptBlock(block, words) {
  var state = block.slice()
  addRoundKey(state, words, 14)
  for (var round = 13; round >= 1; round--) {
    invShiftRows(state)
    invSubBytes(state)
    addRoundKey(state, words, round)
    invMixColumns(state)
  }
  invShiftRows(state)
  invSubBytes(state)
  addRoundKey(state, words, 0)
  return state
}

var B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64Decode(text) {
  var output = []
  var accumulator = 0
  var bits = 0
  var source = String(text || "")
  for (var i = 0; i < source.length; i++) {
    var character = source.charAt(i)
    if (character === "=") break
    var value = B64_CHARS.indexOf(character)
    if (value < 0) continue
    accumulator = (accumulator << 6) | value
    bits += 6
    if (bits >= 8) {
      bits -= 8
      output.push((accumulator >> bits) & 0xff)
    }
  }
  return output
}

function utf8Encode(text) {
  var output = []
  var source = String(text || "")
  for (var i = 0; i < source.length; i++) {
    var codepoint = source.charCodeAt(i)
    if (codepoint >= 0xd800 && codepoint <= 0xdbff && i + 1 < source.length) {
      var low = source.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00)
        i++
      }
    }
    if (codepoint < 0x80) output.push(codepoint)
    else if (codepoint < 0x800)
      output.push(0xc0 | (codepoint >> 6), 0x80 | (codepoint & 0x3f))
    else if (codepoint < 0x10000)
      output.push(0xe0 | (codepoint >> 12), 0x80 | ((codepoint >> 6) & 0x3f), 0x80 | (codepoint & 0x3f))
    else
      output.push(0xf0 | (codepoint >> 18), 0x80 | ((codepoint >> 12) & 0x3f),
        0x80 | ((codepoint >> 6) & 0x3f), 0x80 | (codepoint & 0x3f))
  }
  return output
}

function utf8Decode(bytes) {
  var output = ""
  for (var i = 0; i < bytes.length; i++) {
    var value = bytes[i]
    if (value < 0x80) output += String.fromCharCode(value)
    else if (value < 0xe0)
      output += String.fromCharCode(((value & 0x1f) << 6) | (bytes[++i] & 0x3f))
    else if (value < 0xf0)
      output += String.fromCharCode(((value & 0x0f) << 12) | ((bytes[++i] & 0x3f) << 6) | (bytes[++i] & 0x3f))
    else {
      var codepoint = ((value & 7) << 18) | ((bytes[++i] & 0x3f) << 12)
        | ((bytes[++i] & 0x3f) << 6) | (bytes[++i] & 0x3f)
      codepoint -= 0x10000
      output += String.fromCharCode(0xd800 + (codepoint >> 10), 0xdc00 + (codepoint & 0x3ff))
    }
  }
  return output
}

function deriveKey(password) {
  var key = utf8Encode(password)
  while (key.length < 32) key.push(0x30)
  return key.slice(0, 32)
}

function decryptContent(content, password) {
  var bytes = base64Decode(content)
  if (bytes.length < 32 || bytes.length % 16 !== 0) return ""
  var words = expandKey(deriveKey(password))
  var previous = bytes.slice(0, 16)
  var plain = []
  for (var offset = 16; offset < bytes.length; offset += 16) {
    var block = bytes.slice(offset, offset + 16)
    var decrypted = decryptBlock(block, words)
    for (var i = 0; i < 16; i++) plain.push(decrypted[i] ^ previous[i])
    previous = block
  }
  var padding = plain[plain.length - 1]
  if (padding < 1 || padding > 16 || plain.length < padding) return ""
  for (var j = plain.length - padding; j < plain.length; j++)
    if (plain[j] !== padding) return ""
  return utf8Decode(plain.slice(0, plain.length - padding))
}

function parseDataResponse(raw, password) {
  try {
    var envelope = JSON.parse(String(raw || ""))
    if (!envelope || typeof envelope.content !== "string" || !password) return null
    var plain = decryptContent(envelope.content, password)
    if (!plain) return null
    var parsed = JSON.parse(plain)
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (error) {
    return null
  }
}

function number(data, key) {
  if (!data || data[key] === undefined || data[key] === null) return NaN
  var raw = data[key]
  var value = Array.isArray(raw) ? raw[0] : raw
  var parsed = parseFloat(String(value))
  return isFinite(parsed) ? parsed : NaN
}

function uncertainty(data, key) {
  if (!data || !Array.isArray(data[key]) || data[key].length < 2) return NaN
  var parsed = parseFloat(String(data[key][1]))
  return isFinite(parsed) ? parsed : NaN
}

function rounded(value, decimals) {
  if (!isFinite(value)) return "—"
  var places = Math.max(0, parseInt(decimals, 10) || 0)
  var factor = Math.pow(10, places)
  return String(Math.round(value * factor) / factor)
}

function reading(data, key, decimals, unit) {
  var value = number(data, key)
  return isFinite(value) ? rounded(value, decimals) + (unit ? " " + unit : "") : "—"
}

function score(data, key) {
  var value = indexPercent(data, key)
  return isFinite(value) ? rounded(value, 1) + "%" : "—"
}

function indexPercent(data, key) {
  var value = number(data, key)
  return isFinite(value) ? value / 10 : NaN
}

function indexState(value, greenThreshold, yellowThreshold) {
  if (!isFinite(value)) return "unavailable"
  if (value >= greenThreshold) return "green"
  if (value >= yellowThreshold) return "yellow"
  return "red"
}

function radonState(value, warning) {
  if (!isFinite(value)) return "Waiting for data"
  var threshold = isFinite(warning) && warning > 0 ? warning : 100
  if (value >= 300) return "High"
  if (value >= threshold) return "Elevated"
  return "Good"
}

var METRICS = [
  { key: "tvoc",         label: "VOC",           unit: "ppb",    decimals: 0 },
  { key: "temperature",  label: "Temperature",   unit: "°C",     decimals: 1 },
  { key: "humidity",     label: "Humidity",      unit: "%",      decimals: 1 },
  { key: "humidity_abs", label: "Abs. humidity", unit: "g/m³",   decimals: 1 },
  { key: "mold",         label: "Mold safety",   unit: "%",      decimals: 1 },
  { key: "dewpt",        label: "Dew point",     unit: "°C",     decimals: 1 },
  { key: "pressure_rel", label: "Pressure",      unit: "hPa",    decimals: 1 },
  { key: "co2",          label: "CO₂",           unit: "ppm",    decimals: 0 },
  { key: "pm2_5",        label: "PM2.5",         unit: "µg/m³",  decimals: 0 },
  { key: "pm10",         label: "PM10",          unit: "µg/m³",  decimals: 0 },
  { key: "oxygen",       label: "Oxygen",        unit: "%",      decimals: 2 },
  { key: "sound",        label: "Sound",         unit: "dB(A)",  decimals: 1 }
]

function metricRows(data) {
  var rows = []
  for (var i = 0; i < METRICS.length; i++) {
    var metric = METRICS[i]
    var value = number(data, metric.key)
    if (!isFinite(value)) continue
    rows.push({
      key: metric.key,
      label: metric.label,
      text: rounded(value, metric.decimals) + " " + metric.unit
    })
  }
  return rows
}

function statusLines(data) {
  if (!data || data.Status === undefined || data.Status === "OK") return []
  if (typeof data.Status === "string") return [data.Status]
  var lines = []
  for (var key in data.Status) lines.push(String(data.Status[key]))
  return lines
}

function measurementAge(timestampMs, nowMs) {
  var timestamp = parseFloat(String(timestampMs))
  var now = parseFloat(String(nowMs))
  if (!isFinite(timestamp) || timestamp <= 0 || !isFinite(now)) return "unknown age"
  var seconds = Math.max(0, Math.round((now - timestamp) / 1000))
  if (seconds < 90) return seconds + "s ago"
  var minutes = Math.round(seconds / 60)
  if (minutes < 90) return minutes + "min ago"
  return Math.round(minutes / 60) + "h ago"
}

function tooltipText(data, nowMs, stale) {
  if (!data) return ""
  var lines = []
  var radon = number(data, "radon")
  if (isFinite(radon)) lines.push("Radon: " + reading(data, "radon", radon < 10 ? 1 : 0, "Bq/m³"))
  var rows = metricRows(data)
  for (var i = 0; i < rows.length; i++) lines.push(rows[i].label + ": " + rows[i].text)
  lines.push("Measured " + measurementAge(data.timestamp, nowMs) + (stale ? " · stale" : ""))
  return lines.join("\n")
}
