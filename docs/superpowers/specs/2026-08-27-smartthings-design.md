# SmartThings — design

**Date:** 2026-08-27
**Status:** written without the user present, by their authorisation. Every
decision below is mine and marked as such where it could reasonably have gone
another way. Read the Decisions section first — it is the conversation we did
not get to have.

## Purpose

One bar widget for a whole SmartThings account: every device the token can
see, grouped by room, each one showing the controls it actually publishes.

The existing `io.github.artur-hash.smartac` plugin does one air conditioner
well. This is the general case, and it ships as a **separate plugin** — the
user asked for that explicitly. The two overlap on the air conditioner by
design; which one survives is a later decision, not this one.

## What the account actually contains

The design is grounded in the real account rather than an imagined house.
Queried 2026-08-27, with the names removed:

| Device | Type | Controllable |
|---|---|---|
| a television | Samsung OCF TV | switch, audioVolume, audioMute, mediaPlayback, mediaTrackControl, mediaInputSource, tvChannel |
| an air conditioner | Samsung OCF AC | the full set the smartac plugin already drives |
| a light sensor, attached to the television | light sensor | read-only: illuminance |
| a phone, registered twice | mobile | read-only: presence (one `present`, one `not present`) |

Four distinct things, five rows. **A "complete SmartThings client" for this
account means a TV and an air conditioner, plus three read-only sensors.**
That is the honest scale, and it is what the panel is designed around. The
capability registry is what makes it work for an account that later grows.

## The token scope problem

`GET /locations` returns **HTTP 403** with the smartac plugin's token. That
token was created with device scopes only — list, read, execute — exactly as
that plugin's setup screen instructs. Room names live behind location scopes,
so grouping by room is unreachable with it.

Two consequences, both decided:

1. **This plugin asks for its own token**, stored under its own keyring
   service (`smartthings`), and its setup screen asks for device *and*
   location read scopes. Sharing one keyring entry between two independently
   installable plugins would mean installing one silently grants the other
   access to a credential it never asked for.
2. **Missing location scope degrades, never fails.** With no room data the
   panel shows one flat list and no headings. A 403 on `/locations` is
   expected and unremarkable, not an error to surface.

## Scope

**In:**

- Discover every device the token can see
- Group by room where the token allows it, flat list where it does not
- Per-device controls generated from published capabilities
- Read-only sensor readings
- Token entry and setup inside the panel, as smartac does

**Out, and why:**

- **Scenes and automations.** A different API surface and a different mental
  model. Worth doing; not first.
- **Renaming devices or moving rooms.** This is a controller, not an account
  editor. Writes that change account structure deserve more care than a bar
  widget gives.
- **Vendor extras** (`samsungvd.art`, `samsungvd.ambient`, energy reports).
  They are Samsung-specific, and generality is the point of this plugin.
- **TV channel entry.** Reading the channel is fine; a numeric entry pad in a
  bar panel is a worse remote than the one on the sofa.
- **A daemon or webhooks.** Same reasoning as smartac: polling costs less
  trust and fewer moving parts than a service with a public endpoint.

## Architecture

```
keyring ──token──> bin/smartthings ──HTTPS──> api.smartthings.com
                          │
                      JSON on stdout
                          │
                    BarWidget.qml (Timer; immediate read on open)
                          │
                     Panel.qml ── DeviceList / DeviceDetail
```

Same shape as smartac, for the same reasons: the token lives in a short-lived
child rather than in the long-lived shared shell, a network error degrades one
exit code instead of the whole bar, and the backend is testable without a
running shell.

**Every hardening the smartac plugin earned is ported from the start**, not
rediscovered:

- Token read from **stdin only** — never argv, never `/proc/<pid>/cmdline`
- Auth sent through `curl -K -`, never on the command line
- **Responses bounded while they arrive** — `head -c` at a 1 MiB ceiling so
  curl dies of SIGPIPE, plus `--max-filesize`; overflow fails closed. Size is
  judged before curl's exit status, because enforcing the cap is what kills
  curl.
- Remote strings clamped to 128 characters, lists to 64, device rows to 200
- Writes **verified by reading the state back**, never assumed from a 200
- Per-command `results[].status` read, because the API answers 200 for a
  command it refuses

That last pair is not paranoia. The air conditioner silently drops any setting
that does not apply to its current state and answers `COMPLETED` anyway. There
is no reason to expect a television to be more honest.

## Capability registry

The heart of the plugin. Each entry maps a published capability to a control;
a device gets the union of the controls its capabilities earn. Nothing is
keyed on device type, model, or vendor.

| Capability | Control | Notes |
|---|---|---|
| `switch` | power button | universal; the same square filled/outlined button smartac uses |
| `switchLevel` | level stepper | not present in this account; cheap and common |
| `audioVolume` | volume stepper | debounced, as the AC setpoint is |
| `audioMute` | mute toggle | |
| `mediaPlayback` | transport row | buttons come from `supportedPlaybackCommands` |
| `mediaTrackControl` | previous / next | |
| `mediaInputSource` | input picker | from `supportedInputSources`; **empty while the TV is off**, so the control hides itself |
| `airConditionerMode` + friends | the AC controls | ported from smartac |
| `thermostatCoolingSetpoint` | setpoint stepper | range from `custom.thermostatSetpointControl` where published |
| `temperatureMeasurement` | reading | |
| `relativeHumidityMeasurement` | reading | feeds a heat index, as in smartac |
| `illuminanceMeasurement` | reading | lux |
| `presenceSensor` | reading | present / away |
| `battery` | reading | not present here; trivial |

A capability with nothing to show renders nothing. A device whose capabilities
all render nothing still appears in the list with its name and reachability —
knowing a thing is there and offline is information.

**Empty published lists are the normal case, not an error.** The TV publishes
no input sources while it is off; the AC publishes none of its dust readings
at all. Both hide rather than showing a dead control.

## Panel structure

Two screens, as `parm.clock` does for event detail:

1. **List** — devices grouped under room headings, each row showing name,
   reachability, a one-line summary of its state, and an inline power button
   where the device has `switch`. The common action costs one click.
2. **Detail** — one device, every control it earns, with a back button.

Setup and the token screen sit in front of both, exactly as smartac does.

**Bar label:** an icon plus the number of devices currently on. It is generic,
it is true for any account, and it answers the question a glance at a bar is
actually asking — did I leave something running.

## Polling

Ninety seconds closed, twenty open — the cadence smartac arrived at, and for
the reason it arrived at it: the panel is where the user is clicking and where
devices visibly change state on their own.

**There is no bulk status endpoint.** `GET /devices/status` and
`GET /devices/health` both answer HTTP 400; I assumed otherwise when first
drafting this and checked before building on it. Status costs one request per
device, so request volume — not rendering — is the binding constraint on this
design. This token hit SmartThings' rate limit at roughly sixteen requests in
nine seconds during smartac's development.

What the endpoints do give: `GET /devices` returns structure only — no health,
no status — and accepts a `?capability=` filter. Structure changes rarely, so
it is read once per session rather than per tick.

The panel therefore fetches status only for devices whose state is on screen:

- **List screen:** only devices with `switch`, since that is all the rows and
  the bar count actually show. Three of the five rows in this account.
- **Detail screen:** the one device being looked at.
- **Health:** fetched only for a device currently reporting `on`. A device
  reporting off has nothing a reachability check would correct, and doubling
  every refresh to catch an unplugged set is a bad trade against the limit
  that actually bites. Typical list refresh: three requests. Worst case: six.

Reads are **sequential inside one backend process**, never a fan-out of
concurrent children. The limit that bit during smartac's development was a
burst limit; pacing inside a single process is what keeps a refresh from
looking like an attack.

Backoff on 429 is exponential to a ten-minute ceiling, reset on first success.

## Error handling

| Condition | Behaviour |
|---|---|
| No token | Panel opens on setup |
| 401 | Token cleared, back to setup, message says it was rejected |
| 403 on `/locations` | Silent; flat list, no room headings |
| 403 elsewhere | Named, with the scope that is missing |
| 429 | Backoff; last state kept and marked stale |
| Response over 1 MiB | Refused, fails closed, own exit code |
| Device offline | Row shows it; controls disabled |
| Command accepted but not applied | Read back, then say the device did not apply it |

## Testing

- `Model.js` under node: capability→control resolution, grouping, summaries,
  clamping, interval selection. Pure and Qt-free.
- `bin/smartthings` against a faked `curl` and `secret-tool` on PATH, as
  smartac does — including the size ceiling and the clamps.
- `omarchy plugin validate` in CI.

The capability registry is the part most worth testing: it is a lookup table,
its failure mode is a missing or wrong control, and a fixture per device type
pins that down without hardware.

## Decisions I made without you

Listed plainly, because you should be able to overturn any of them in a
sentence tomorrow.

1. **Its own token and keyring service.** Forced by the 403 — room grouping
   needs scopes your current token lacks. Alternative: drop room grouping and
   share nothing. I chose the one that keeps your original vision.
2. **Separate repo and plugin id** (`io.github.artur-hash.smartthings`).
   Marketplace ids are permanent and one repo per listing is the pattern.
3. **List-then-detail, not everything inline.** Four devices fit inline; forty
   do not, and the structure should not have to change when your account
   grows.
4. **Bar shows a count of devices on.** The alternative was a static icon.
   A count answers a real question.
5. **Vendor capabilities excluded**, including the Samsung art and ambient
   modes your TV publishes. Generality is the point; those belong in a
   Samsung-specific plugin if anywhere.
6. **The phone appears twice, and I left it that way.** Your account has two
   registrations of the same phone, one `present` and one `not present`.
   Deduplicating would mean guessing which is real.
7. **The list screen does not verify reachability for every device.** Health
   is fetched only for a device reporting itself on. The alternative doubles
   every refresh against the one limit that has actually bitten this project.
8. **The air conditioner will appear in both plugins.** Overlap is the
   consequence of shipping this separately, which is what you asked for.

## Built, and what happened

Everything above is implemented and running on the bar. Two things went
differently from the plan.

**A defect the tests could not have caught.** Every capability check failed
silently in the shell while all 35 model tests passed under node. An array
stored in a QML `property var` and read back crosses a boundary between JS
engine contexts: it keeps `length` and `indexOf`, and `Array.isArray` returns
`false` for it. `_has()` used `Array.isArray` as its gate, so every list the
panel read back was rejected — the air conditioner's row said `Off` instead of
`Off · 22°C · 55%`, and the sensors said nothing at all. Node has real arrays,
so no test written there could ever have shown it. The module now copies every
incoming list into a genuine Array once, and the regression tests build
array-like objects that are deliberately not Arrays.

**The televison's controls render, and are still unverified.** Power, volume,
mute, playback and track all appear, built from what the set publishes while
off. Whether they *do* anything needs the set on, and that is your call to
make, not mine.

## What I could not verify

**The television's controls.** Everything here is designed from what it
publishes while off. I did not turn on a television in an empty house to watch
what changed — that is a physical act in your home for my convenience. Volume,
mute, playback, and input picking need your eyes on them once, and input
sources in particular publish nothing until the set is on.
