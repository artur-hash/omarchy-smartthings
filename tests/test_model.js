// Unit tests for Model.js. Run: node tests/test_model.js
//
// The shapes here are taken from a real account -- a Samsung television, a
// Samsung air conditioner, a light sensor and a phone -- with the identifiers
// replaced. Anything a real device does that surprised the design is pinned
// down by a test rather than a comment.
const assert = require("assert");
const path = require("path");
const M = require(path.join(__dirname, "..", "Model.js"));

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

const TV = { id: "tv-1", label: "living room tv", roomId: "r1",
  caps: ["switch", "audioVolume", "audioMute", "mediaPlayback", "mediaTrackControl",
         "mediaInputSource", "tvChannel"] };
const AC = { id: "ac-1", label: "air conditioner", roomId: "r2",
  caps: ["switch", "airConditionerMode", "airConditionerFanMode", "fanOscillationMode",
         "custom.airConditionerOptionalMode", "thermostatCoolingSetpoint",
         "temperatureMeasurement", "relativeHumidityMeasurement", "audioVolume"] };
const LIGHT = { id: "ls-1", label: "light sensor", roomId: "r1",
  caps: ["switch", "illuminanceMeasurement"] };
const PHONE = { id: "ph-1", label: "phone", roomId: "", caps: ["presenceSensor"] };

function statusFor(over) {
  return Object.assign(M.emptyStatus("x"), over);
}

// ------------------------------------------------------------------ parsing --

test("parseDevices reads the backend's list", () => {
  const r = M.parseDevices('{"devices":[{"id":"a","label":"TV","roomId":"r1","caps":["switch"]}]}');
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.devices[0].label, "TV");
  assert.deepStrictEqual(r.devices[0].caps, ["switch"]);
});

test("parseDevices survives half a line without throwing", () => {
  assert.strictEqual(M.parseDevices('{"devices":[').ok, false);
  assert.deepStrictEqual(M.parseDevices("").devices, []);
});

test("parseDevices drops a row with no id rather than rendering a ghost", () => {
  const r = M.parseDevices('{"devices":[{"label":"nameless"},{"id":"a","label":"real"}]}');
  assert.strictEqual(r.devices.length, 1);
  assert.strictEqual(r.devices[0].id, "a");
});

test("parseRooms carries the scope and the location count through", () => {
  assert.strictEqual(M.parseRooms('{"rooms":{},"locations":0,"scoped":false}').scoped, false);
  const r = M.parseRooms('{"rooms":{"r1":{"name":"Sala","location":"Casa"}},"locations":2,"scoped":true}');
  assert.strictEqual(r.rooms.r1.name, "Sala");
  assert.strictEqual(r.locations, 2);
});

test("parseStatuses keys by device and normalises absent values", () => {
  const r = M.parseStatuses('{"statuses":[{"id":"tv-1","switch":"on","volume":21,"mute":"unmuted"}]}');
  assert.strictEqual(r.byId["tv-1"].switch, "on");
  assert.strictEqual(r.byId["tv-1"].volume, 21);
  assert.strictEqual(r.byId["tv-1"].setpoint, null);
  assert.deepStrictEqual(r.byId["tv-1"].supported.input, []);
});

test("parseStatuses keeps online tri-state, because unknown is not offline", () => {
  const q = M.parseStatuses('{"statuses":[{"id":"a","online":null}]}').byId.a;
  assert.strictEqual(q.online, null);
  assert.strictEqual(M.parseStatuses('{"statuses":[{"id":"a","online":false}]}').byId.a.online, false);
  assert.strictEqual(M.parseStatuses('{"statuses":[{"id":"a","online":true}]}').byId.a.online, true);
});

// ----------------------------------------------------------------- grouping --

const R1 = { name: "Living room", location: "Home" };
const R2 = { name: "Bedroom", location: "Home" };

test("groupByRoom sorts rooms by name and devices within them", () => {
  const g = M.groupByRoom([AC, TV, LIGHT], { r1: R1, r2: R2 }, true, 1);
  assert.deepStrictEqual(g.map(x => x.room), ["Bedroom", "Living room"]);
  assert.deepStrictEqual(g[1].devices.map(d => d.label), ["light sensor", "living room tv"]);
});

// One account can hold a home and an office, and both can have a room by the
// same name. The location leads so the two are told apart.
test("the location leads the heading when there is more than one", () => {
  const g = M.groupByRoom([TV], { r1: R1 }, true, 2);
  assert.strictEqual(g[0].room, "Home · Living room");
});

test("and stays out of the way when there is only one", () => {
  const g = M.groupByRoom([TV], { r1: R1 }, true, 1);
  assert.strictEqual(g[0].room, "Living room");
});

// An unnamed group under a named one reads as part of it -- the devices look
// like they are in the room above, which is how an air conditioner in another
// building appeared to be in the living room.
test("ungrouped devices get their own heading once anything is named", () => {
  const g = M.groupByRoom([PHONE, TV], { r1: R1 }, true, 1);
  assert.strictEqual(g[0].room, "Living room");
  assert.strictEqual(g[1].room, "NO ROOM");
});

test("but not when nothing is named, because there is nothing to belong to", () => {
  const g = M.groupByRoom([PHONE, TV], {}, false, 0);
  assert.strictEqual(g.length, 1);
  assert.strictEqual(g[0].room, "");
});

// Without location scope every device is unplaced, and the degraded result is
// the same shape as the grouped one -- so the panel needs no second code path.
test("with no location scope everything lands in one unnamed group", () => {
  const g = M.groupByRoom([TV, AC, PHONE], {}, false, 0);
  assert.strictEqual(g.length, 1);
  assert.strictEqual(g[0].room, "");
  assert.strictEqual(g[0].devices.length, 3);
});

// ------------------------------------------------------- capability registry --

test("a device earns a power button from switch alone", () => {
  const c = M.controlsFor(LIGHT, statusFor({ switch: "off" }));
  const power = c.find(x => x.kind === "power");
  assert.strictEqual(power.capability, "switch");
  assert.strictEqual(power.command, "on", "the command is the one that changes it");
});

test("the power command flips with the current state", () => {
  const c = M.controlsFor(LIGHT, statusFor({ switch: "on" }));
  assert.strictEqual(c.find(x => x.kind === "power").command, "off");
});

test("a phone earns no controls at all, and still no crash", () => {
  assert.deepStrictEqual(M.controlsFor(PHONE, statusFor({ presence: "present" })), []);
});

// This is the case that shaped the design: a television publishes no input
// sources while it is off. A control built from a hardcoded list would offer
// buttons that do nothing.
test("an empty supported list earns no control rather than a dead one", () => {
  const off = M.controlsFor(TV, statusFor({ switch: "off", supported: {
    mode: [], fan: [], swing: [], preset: [], input: [], playback: ["play", "pause"] } }));
  assert.strictEqual(off.find(x => x.key === "input"), undefined);
  assert.ok(off.find(x => x.key === "playback"), "playback is published even while off");
});

test("the same television earns an input picker once it publishes sources", () => {
  const on = M.controlsFor(TV, statusFor({ switch: "on", input: "HDMI1", supported: {
    mode: [], fan: [], swing: [], preset: [], input: ["HDMI1", "HDMI2"], playback: [] } }));
  const input = on.find(x => x.key === "input");
  assert.deepStrictEqual(input.options, ["HDMI1", "HDMI2"]);
  assert.strictEqual(input.value, "HDMI1");
  assert.strictEqual(input.command, "setInputSource");
});

test("an air conditioner earns its whole cluster from its capabilities", () => {
  const c = M.controlsFor(AC, statusFor({ switch: "on", mode: "cool", fan: "auto",
    setpoint: 23, supported: { mode: ["auto", "cool"], fan: ["auto", "low"],
    swing: ["fixed"], preset: ["off", "windFree"], input: [], playback: [] } }));
  const keys = c.map(x => x.key);
  ["switch", "setpoint", "mode", "fan", "swing", "preset"].forEach(k =>
    assert.ok(keys.indexOf(k) !== -1, "missing " + k));
});

test("mute reports its state and offers the opposite command", () => {
  const muted = M.controlsFor(TV, statusFor({ mute: "muted" })).find(x => x.key === "mute");
  assert.strictEqual(muted.value, true);
  assert.strictEqual(muted.command, "unmute");
});

// Capability-driven rendering has a cost, and this pins it: an air conditioner
// that publishes audioVolume (its beep) earns a volume control. Suppressing it
// would mean special-casing a device type, which is the thing this design
// refuses to do.
test("an air conditioner publishing audioVolume earns a volume control", () => {
  const c = M.controlsFor(AC, statusFor({ volume: 0 }));
  assert.ok(c.find(x => x.key === "volume"), "generality cuts both ways, on purpose");
});

// An array that has crossed the QML property boundary is array-like but is not
// an Array: length and indexOf work, Array.isArray does not. Guarding on
// Array.isArray therefore rejected every list read back out of a `property var`
// -- and node, where arrays are real, could never have shown it. These fixtures
// are that boundary, so the mistake cannot come back unnoticed.
function qmlArray(items) {
  const o = { length: items.length,
              indexOf: function (x) { return items.indexOf(x) },
              filter: function (f) { return items.filter(f) } };
  items.forEach((v, i) => { o[i] = v });
  return o;   // Array.isArray(o) === false, by construction
}

test("a capability list that crossed the QML boundary is still read", () => {
  assert.strictEqual(Array.isArray(qmlArray(["switch"])), false, "the fixture must not be a real array");
  const crossed = { id: "x", label: "x", roomId: "", caps: qmlArray(["switch", "illuminanceMeasurement"]) };
  const c = M.controlsFor(crossed, statusFor({ switch: "off" }));
  assert.ok(c.find(x => x.kind === "power"), "the power button survived the crossing");
  const r = M.readingsFor(crossed, statusFor({ illuminance: 11 }));
  assert.strictEqual(r[0].text, "11 lux");
});

test("a summary survives the crossing too", () => {
  const crossed = { id: "x", label: "x", roomId: "",
                    caps: qmlArray(["switch", "temperatureMeasurement", "relativeHumidityMeasurement"]) };
  assert.strictEqual(
    M.summaryFor(crossed, statusFor({ switch: "off", temperature: 22, humidity: 55 })),
    "Off · 22°C · 55%");
});

test("a device list that crossed the boundary still groups and counts", () => {
  const crossed = qmlArray([TV, AC]);
  assert.strictEqual(M.groupByRoom(crossed, {}, false, 0)[0].devices.length, 2);
  assert.strictEqual(M.devicesNeedingStatus(crossed).length, 2);
  assert.strictEqual(M.onCount(crossed, { "tv-1": statusFor({ switch: "on" }) }), 1);
});

test("a supported list that crossed the boundary still builds its buttons", () => {
  const st = statusFor({ mode: "cool", supported: {
    mode: qmlArray(["auto", "cool"]), fan: [], swing: [], preset: [], input: [], playback: [] } });
  const c = M.controlsFor(AC, st).find(x => x.key === "mode");
  assert.deepStrictEqual(c.options, ["auto", "cool"]);
});

// --------------------------------------------------------------- readings --

test("readings come only from capabilities the device actually has", () => {
  const r = M.readingsFor(LIGHT, statusFor({ illuminance: 11 }));
  assert.deepStrictEqual(r.map(x => x.label), ["LIGHT"]);
  assert.strictEqual(r[0].text, "11 lux");
});

test("presence reads as a place, not as a protocol value", () => {
  assert.strictEqual(M.readingsFor(PHONE, statusFor({ presence: "present" }))[0].text, "Home");
  assert.strictEqual(M.readingsFor(PHONE, statusFor({ presence: "not present" }))[0].text, "Away");
});

test("feels-like is hidden when it would just repeat the air temperature", () => {
  const cool = M.readingsFor(AC, statusFor({ temperature: 21, humidity: 59 }));
  assert.strictEqual(cool.find(x => x.label === "FEELS LIKE"), undefined);
});

test("feels-like appears once the heat index diverges", () => {
  const warm = M.readingsFor(AC, statusFor({ temperature: 32, humidity: 70 }));
  const f = warm.find(x => x.label === "FEELS LIKE");
  assert.ok(f && parseInt(f.text, 10) > 32, "humid heat should read hotter than the air");
});

// ---------------------------------------------------------------- summaries --

test("a summary says what the device is doing in the fewest true words", () => {
  assert.strictEqual(
    M.summaryFor(AC, statusFor({ switch: "on", temperature: 22, humidity: 55 })),
    "On · 22°C · 55%");
});

test("a device with no status read yet says nothing rather than guessing", () => {
  assert.strictEqual(M.summaryFor(TV, null), "");
});

test("volume joins the summary only while the set is on", () => {
  assert.strictEqual(M.summaryFor(TV, statusFor({ switch: "off", volume: 21 })), "Off");
  assert.strictEqual(M.summaryFor(TV, statusFor({ switch: "on", volume: 21 })), "On · vol 21");
});

// ------------------------------------------------------------ request budget --
// There is no bulk status endpoint, so every device costs a request. The list
// screen pays only for devices whose state a row actually shows.

test("only devices whose state a row shows are worth a status request", () => {
  const need = M.devicesNeedingStatus([TV, AC, LIGHT, PHONE]);
  assert.deepStrictEqual(need.map(d => d.id), ["tv-1", "ac-1", "ls-1", "ph-1"]);
});

test("a device with nothing displayable costs no request", () => {
  const inert = { id: "z", label: "z", roomId: "", caps: ["refresh", "execute"] };
  assert.deepStrictEqual(M.devicesNeedingStatus([inert]), []);
});

test("the bar counts what is on and stays quiet when nothing is", () => {
  const on = { "tv-1": statusFor({ switch: "on" }), "ac-1": statusFor({ switch: "off" }) };
  assert.strictEqual(M.onCount([TV, AC], on), 1);
  assert.strictEqual(M.barLabel([TV, AC], on), "1");
  assert.strictEqual(M.barLabel([TV, AC], { "tv-1": statusFor({ switch: "off" }) }), "");
});

// -------------------------------------------------------------- numbers --

test("setpointRange prefers the device's own bounds", () => {
  assert.deepStrictEqual(M.setpointRange({ setpointMin: 18, setpointMax: 26 }), [18, 26]);
});

test("an inverted range is discarded, not trusted", () => {
  assert.deepStrictEqual(M.setpointRange({ setpointMin: 30, setpointMax: 16, unit: "C" }), [16, 30]);
});

test("clampSetpoint holds the range", () => {
  assert.strictEqual(M.clampSetpoint(40, 16, 30), 30);
  assert.strictEqual(M.clampSetpoint(2, 16, 30), 16);
});

test("nextInterval backs off exponentially and caps at ten minutes", () => {
  assert.strictEqual(M.nextInterval(20000, 0), 20000);
  assert.strictEqual(M.nextInterval(90000, 1), 180000);
  assert.strictEqual(M.nextInterval(90000, 9), M.MAX_INTERVAL_MS);
});

let failed = 0;
for (const [name, fn] of tests) {
  try { fn(); console.log(`ok    ${name}`); }
  catch (e) { failed++; console.error(`FAIL  ${name}\n      ${e.message}`); }
}
console.log(`\n${tests.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
