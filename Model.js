// Pure, Qt-free, node-testable. Everything the panel renders is decided here,
// so the QML stays a view and the interesting logic can be tested without a
// running shell or any hardware.

var MAX_INTERVAL_MS = 600000
var HEAT_INDEX_MIN_C = 27

function _num(v)  { return (typeof v === "number" && isFinite(v)) ? v : null }
function _str(v)  { return (typeof v === "string" && v !== "") ? v : null }
// An array that has crossed the QML property boundary is array-like but is not
// an Array: it has length and indexOf, and Array.isArray returns false for it.
// Guarding on Array.isArray therefore rejects every list the panel reads back
// out of a `property var` -- silently, and invisibly to tests under node, where
// the boundary does not exist and the arrays are real. Everything entering this
// module is copied into a genuine Array once, here.
function _arr(v) {
  if (!v || typeof v.length !== "number") return []
  var out = []
  for (var i = 0; i < v.length; i++) out.push(v[i])
  return out
}
function _list(v) { return _arr(v).filter(function (x) { return typeof x === "string" }) }

function emptyStatus(id) {
  return {
    id: id || "", online: null,
    switch: null, level: null,
    volume: null, mute: null, playback: null, input: null, channel: null,
    mode: null, fan: null, swing: null, preset: null, setpoint: null,
    temperature: null, unit: "C", humidity: null, illuminance: null,
    presence: null, battery: null,
    supported: { mode: [], fan: [], swing: [], preset: [], input: [], playback: [] },
    setpointMin: null, setpointMax: null
  }
}

// ------------------------------------------------------------------ parsing --
// The backend is a child process; a crash mid-write leaves half a line, so
// every parse survives garbage rather than throwing into the shell.

function _json(text) {
  try { return JSON.parse(String(text || "")) } catch (e) { return null }
}

function parseDevices(text) {
  var d = _json(text)
  if (!d || !d.devices || typeof d.devices.length !== "number") return { ok: false, devices: [] }
  return {
    ok: true,
    devices: d.devices.map(function (x) {
      return {
        id: String(x.id || ""),
        label: String(x.label || x.id || ""),
        roomId: String(x.roomId || ""),
        caps: _list(x.caps)
      }
    }).filter(function (x) { return x.id !== "" })
  }
}

function parseRooms(text) {
  var d = _json(text)
  if (!d || typeof d.rooms !== "object" || d.rooms === null)
    return { ok: false, rooms: {}, locations: 0, scoped: false }
  return { ok: true, rooms: d.rooms, locations: Number(d.locations) || 0, scoped: d.scoped === true }
}

function parseStatuses(text) {
  var d = _json(text)
  if (!d || !d.statuses || typeof d.statuses.length !== "number") return { ok: false, byId: {} }
  var byId = {}
  for (var i = 0; i < d.statuses.length; i++) {
    var s = d.statuses[i]
    if (!s || typeof s.id !== "string" || s.id === "") continue
    var out = emptyStatus(s.id)
    out.online = (s.online === true) ? true : (s.online === false ? false : null)
    var scalars = ["switch", "mute", "playback", "input", "channel",
                   "mode", "fan", "swing", "preset", "presence", "unit"]
    for (var j = 0; j < scalars.length; j++) out[scalars[j]] = _str(s[scalars[j]]) || out[scalars[j]]
    var numbers = ["level", "volume", "setpoint", "temperature", "humidity",
                   "illuminance", "battery", "setpointMin", "setpointMax"]
    for (var k = 0; k < numbers.length; k++) out[numbers[k]] = _num(s[numbers[k]])
    if (s.supported && typeof s.supported === "object") {
      var lists = ["mode", "fan", "swing", "preset", "input", "playback"]
      for (var l = 0; l < lists.length; l++) out.supported[lists[l]] = _list(s.supported[lists[l]])
    }
    byId[s.id] = out
  }
  return { ok: true, byId: byId }
}

// ----------------------------------------------------------------- grouping --

// Devices under their room heading, rooms in name order, unplaced devices last
// under a heading of their own. With no location scope every device is unplaced
// and the result is one flat group with no heading -- the degraded shape is the
// same shape, so the panel needs no second code path.
// A heading for one room. With more than one location in the account, the room
// name alone is ambiguous -- two places can both have a "Sala de estar" -- so
// the location leads.
function roomHeading(entry, locationCount) {
  if (!entry) return ""
  var name = String(entry.name || "")
  var loc = String(entry.location || "")
  if (name === "") return loc
  return (locationCount > 1 && loc !== "") ? loc + " · " + name : name
}

function groupByRoom(devices, rooms, scoped, locationCount) {
  var list = _arr(devices)
  var names = rooms || {}
  var n = Number(locationCount) || 0
  var buckets = {}, order = []

  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    var head = (scoped && d.roomId && names[d.roomId]) ? roomHeading(names[d.roomId], n) : ""
    if (!buckets[head]) { buckets[head] = []; order.push(head) }
    buckets[head].push(d)
  }

  order.sort(function (a, b) {
    if (a === "") return 1          // unplaced devices sink to the bottom
    if (b === "") return -1
    return a.localeCompare(b)
  })

  // An unnamed group sitting under a named one reads as part of it: the
  // devices look like they are in the room above. It only stays unlabelled
  // when nothing is labelled -- no location scope, so there are no rooms to
  // belong to and a heading would be noise.
  var anyNamed = order.some(function (x) { return x !== "" })

  return order.map(function (head) {
    return {
      room: (head === "" && anyNamed) ? "NO ROOM" : head,
      devices: buckets[head].slice().sort(function (a, b) { return a.label.localeCompare(b.label) })
    }
  })
}

// ------------------------------------------------------- capability registry --
//
// The heart of the plugin. A control is earned by a published capability, never
// by a device type, model or vendor. A device that offers a capability but
// publishes nothing usable for it -- a television lists no input sources while
// it is off -- earns no control rather than a dead one.

function _has(caps, id) {
  return !!caps && typeof caps.indexOf === "function" && caps.indexOf(id) !== -1
}

// Which of the values the device published are worth a row of buttons.
function _choice(kind, caps, capability, command, status, listKey, current) {
  if (!_has(caps, capability)) return null
  var options = _arr(status.supported ? status.supported[listKey] : null)
  if (options.length === 0) return null
  return { kind: "choice", key: kind, label: kind.toUpperCase(), capability: capability,
           command: command, options: options, value: current }
}

function controlsFor(device, status) {
  var caps = device ? _arr(device.caps) : []
  var st = status || emptyStatus(device ? device.id : "")
  var out = []

  if (_has(caps, "switch"))
    out.push({ kind: "power", key: "switch", label: "POWER", capability: "switch",
               command: st.switch === "on" ? "off" : "on", value: st.switch })

  if (_has(caps, "switchLevel"))
    out.push({ kind: "stepper", key: "level", label: "LEVEL", capability: "switchLevel",
               command: "setLevel", value: st.level, min: 0, max: 100, unit: "%" })

  // A thermostat setpoint takes its range from the device where the device
  // publishes one. The alternative is a constant that happens to match one
  // machine, which is how the sibling plugin got it wrong the first time.
  if (_has(caps, "thermostatCoolingSetpoint")) {
    var r = setpointRange(st)
    out.push({ kind: "stepper", key: "setpoint", label: "TEMPERATURE",
               capability: "thermostatCoolingSetpoint", command: "setCoolingSetpoint",
               value: st.setpoint, min: r[0], max: r[1], unit: "°" + (st.unit || "C"), numeric: true })
  }

  out.push(_choice("mode",   caps, "airConditionerMode",    "setAirConditionerMode",  st, "mode",   st.mode))
  out.push(_choice("fan",    caps, "airConditionerFanMode", "setFanMode",             st, "fan",    st.fan))
  out.push(_choice("swing",  caps, "fanOscillationMode",    "setFanOscillationMode",  st, "swing",  st.swing))
  out.push(_choice("preset", caps, "custom.airConditionerOptionalMode",
                                   "setAcOptionalMode",     st, "preset", st.preset))
  out.push(_choice("input",  caps, "mediaInputSource",      "setInputSource",         st, "input",  st.input))

  if (_has(caps, "audioVolume"))
    out.push({ kind: "stepper", key: "volume", label: "VOLUME", capability: "audioVolume",
               command: "setVolume", value: st.volume, min: 0, max: 100, unit: "", numeric: true })

  if (_has(caps, "audioMute"))
    out.push({ kind: "toggle", key: "mute", label: "MUTE", capability: "audioMute",
               command: st.mute === "muted" ? "unmute" : "mute", value: st.mute === "muted" })

  var playback = _arr(st.supported ? st.supported.playback : null)
  if (_has(caps, "mediaPlayback") && playback.length > 0)
    out.push({ kind: "transport", key: "playback", label: "PLAYBACK", capability: "mediaPlayback",
               options: playback, value: st.playback })

  if (_has(caps, "mediaTrackControl"))
    out.push({ kind: "track", key: "track", label: "TRACK", capability: "mediaTrackControl",
               options: ["previousTrack", "nextTrack"] })

  return out.filter(function (c) { return c !== null })
}

// Read-only rows. Separated from controls because they answer a different
// question -- what is it like in there, rather than what can I change.
function readingsFor(device, status) {
  var caps = device ? _arr(device.caps) : []
  var st = status || emptyStatus("")
  var out = []
  function add(cap, label, value, suffix) {
    if (_has(caps, cap) && value !== null && value !== undefined)
      out.push({ label: label, text: String(value) + (suffix || "") })
  }
  add("temperatureMeasurement", "TEMPERATURE", st.temperature, "°" + (st.unit || "C"))
  add("relativeHumidityMeasurement", "HUMIDITY", st.humidity, "%")

  var feels = feelsLike(st)
  if (feels !== null) out.push({ label: "FEELS LIKE", text: feels + "°" + (st.unit || "C") })

  add("illuminanceMeasurement", "LIGHT", st.illuminance, " lux")
  add("battery", "BATTERY", st.battery, "%")
  if (_has(caps, "presenceSensor") && st.presence !== null)
    out.push({ label: "PRESENCE", text: st.presence === "present" ? "Home" : "Away" })
  if (_has(caps, "tvChannel") && st.channel !== null && st.channel !== "")
    out.push({ label: "CHANNEL", text: st.channel })
  return out
}

// One line for a list row: what this device is doing, in the fewest words that
// are still true. A device with no status read yet says nothing rather than
// guessing.
function summaryFor(device, status) {
  var caps = device ? _arr(device.caps) : []
  var st = status
  if (!st) return ""
  var bits = []
  if (st.switch !== null) bits.push(st.switch === "on" ? "On" : "Off")
  if (_has(caps, "temperatureMeasurement") && st.temperature !== null)
    bits.push(Math.round(st.temperature) + "°" + (st.unit || "C"))
  if (_has(caps, "relativeHumidityMeasurement") && st.humidity !== null)
    bits.push(Math.round(st.humidity) + "%")
  if (_has(caps, "illuminanceMeasurement") && st.illuminance !== null)
    bits.push(st.illuminance + " lux")
  if (_has(caps, "presenceSensor") && st.presence !== null)
    bits.push(st.presence === "present" ? "Home" : "Away")
  if (st.switch === "on" && _has(caps, "audioVolume") && st.volume !== null)
    bits.push("vol " + st.volume)
  return bits.join(" · ")
}

// Which devices the list screen needs a status for. Everything else costs a
// request per tick to show nothing the row displays.
function devicesNeedingStatus(devices) {
  return _arr(devices).filter(function (d) {
    return _has(d.caps, "switch") || _has(d.caps, "temperatureMeasurement")
      || _has(d.caps, "presenceSensor") || _has(d.caps, "illuminanceMeasurement")
  })
}

function onCount(devices, byId) {
  var n = 0
  var list = _arr(devices)
  for (var i = 0; i < list.length; i++) {
    var st = (byId || {})[list[i].id]
    if (st && st.switch === "on") n++
  }
  return n
}

// The bar answers the question a glance is actually asking: did I leave
// something running. Nothing on says nothing, rather than a confident zero.
function barLabel(devices, byId) {
  var n = onCount(devices, byId)
  return n > 0 ? String(n) : ""
}

// -------------------------------------------------------------- numbers --

function clampSetpoint(v, min, max) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) return min
  return Math.min(max, Math.max(min, n))
}

function setpointRange(status) {
  var st = status || {}
  var lo = _num(st.setpointMin), hi = _num(st.setpointMax)
  // An inverted range would clamp every press to the wrong end, so it is
  // discarded rather than trusted.
  if (lo !== null && hi !== null && lo < hi) return [Math.round(lo), Math.round(hi)]
  return (st.unit === "F") ? [61, 86] : [16, 30]
}

// NWS heat index (Rothfusz). Only defined at or above about 27C; below that it
// returns the air temperature, and feelsLike then hides it rather than printing
// "21 feels like 21" as though that were information.
function heatIndex(tempC, humidity) {
  var t = _num(tempC), h = _num(humidity)
  if (t === null || h === null || h < 0 || h > 100) return null
  if (t < HEAT_INDEX_MIN_C) return t
  var f = t * 9 / 5 + 32
  var hi = -42.379 + 2.04901523 * f + 10.14333127 * h
         - 0.22475541 * f * h - 0.00683783 * f * f - 0.05481717 * h * h
         + 0.00122874 * f * f * h + 0.00085282 * f * h * h - 0.00000199 * f * f * h * h
  return (hi - 32) * 5 / 9
}

function feelsLike(status) {
  var st = status || {}
  if (st.unit === "F") return null          // the regression is stated in Celsius here
  var hi = heatIndex(st.temperature, st.humidity)
  if (hi === null) return null
  var r = Math.round(hi)
  if (Math.abs(hi - st.temperature) < 1) return null
  return r
}

// Polling follows attention: ninety seconds for a bar label nobody is reading,
// twenty for an open panel where the user is clicking and devices move on their
// own. Rate-limit backoff wins over both.
function nextInterval(baseMs, consecutiveFailures) {
  var base = Number(baseMs) || 90000
  var fails = Number(consecutiveFailures) || 0
  if (fails > 0) return Math.min(MAX_INTERVAL_MS, base * Math.pow(2, fails))
  return base
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseDevices: parseDevices, parseRooms: parseRooms, parseStatuses: parseStatuses,
    groupByRoom: groupByRoom, roomHeading: roomHeading,
    controlsFor: controlsFor, readingsFor: readingsFor,
    summaryFor: summaryFor, devicesNeedingStatus: devicesNeedingStatus,
    onCount: onCount, barLabel: barLabel,
    clampSetpoint: clampSetpoint, setpointRange: setpointRange,
    heatIndex: heatIndex, feelsLike: feelsLike, nextInterval: nextInterval,
    emptyStatus: emptyStatus, MAX_INTERVAL_MS: MAX_INTERVAL_MS
  }
}
