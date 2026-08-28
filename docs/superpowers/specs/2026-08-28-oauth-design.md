# OAuth for SmartThings — design

**Date:** 2026-08-28
**Status:** draft. Two facts it rests on are unverified and are the first
implementation step, not an assumption to build on. They are named below.

## Why

A SmartThings personal access token is **valid for 24 hours** from creation.
Tokens issued before 30 December 2024 could last up to fifty years, which is
why nothing looked wrong while both plugins were built and tested in a single
day: the credential worked all afternoon and was gone the next morning, taking
both plugins' copies with it, because both held the same token and each cleared
its own on the 401.

The plugins behaved correctly. The setup instructions were the lie, and they
have since been corrected in both. But a home controller that demands a fresh
token every morning is not usable, and no feature built on top of that changes
it. This is the blocking problem.

## What replaces it

OAuth. The access token still expires in 24 hours, but a refresh token buys
another without anyone retyping anything, and the refresh token rotates on each
use. Refreshed daily, the plugin stays authorised indefinitely.

```
                     once, at setup                      forever after
  PAT (w:apps) ──> POST /apps ──> client_id + secret
                                        │
                    browser ──> /oauth/authorize ──> code
                                        │
                          POST /oauth/token ──> access + refresh
                                                      │
                                        401 or age ──>│
                                                      ▼
                                    POST /oauth/token (grant_type=refresh_token)
                                          ──> new access + NEW refresh
```

## The two unverified facts

Everything below is contingent on these. They are cheap to test and the first
thing implementation does.

1. **Does `POST /apps` accept `http://localhost:PORT/...` as a redirect URI?**
   The documentation says redirect URIs must be HTTPS. Community reports show
   `http://localhost:3000/oauth/callback` in working examples, and others show
   `redirect_uri could not be validated`. If localhost is refused, the browser
   cannot hand the code back to a local process and the flow changes shape (see
   Fallback).
2. **Does the authorize endpoint honour it too?** Registration accepting a URI
   does not guarantee the authorize step will.

`GET /v1/apps` answers 401 rather than 404, so the endpoint exists. That is all
that is currently established.

## Setup, as the user experiences it

The point of this design is that registering an OAuth client should not mean
installing a CLI and learning the developer workspace.

1. The panel asks for **one** personal access token, with `w:apps:*` added to
   the scopes it already asks for.
2. The plugin calls `POST /apps` itself, creating an `API_ONLY` app, and keeps
   the `client_id` and `client_secret` it gets back.
3. **The PAT is discarded immediately.** It was scaffolding; it expires in a
   day anyway, and holding a credential with app-write scope after it has
   served its purpose is worse than not holding it.
4. The browser opens at the authorize URL. The user approves once.
5. The code comes back, is exchanged for a token pair, and the pair goes into
   the keyring.

From then on the plugin refreshes on its own. The user never sees a token
again.

### Fallback if localhost is refused

The redirect points at a URL that simply displays what it was given, and the
panel gains a field for pasting the `code` out of the address bar. It is uglier
and it is one extra step, but it is a one-time step and it needs no listening
socket. **This fallback is not a worse design to be avoided — if fact 1 fails,
it is the design.**

## Endpoints

| Purpose | Call |
|---|---|
| Register | `POST /v1/apps` — `appType: API_ONLY`, with the OAuth scopes and redirect URIs |
| Authorize | `GET https://api.smartthings.com/oauth/authorize?client_id=…&response_type=code&redirect_uri=…&scope=…` |
| Exchange | `POST https://api.smartthings.com/oauth/token`, Basic auth `client_id:client_secret`, form-encoded `grant_type=authorization_code&code=…&redirect_uri=…&client_id=…` |
| Refresh | the same endpoint, `grant_type=refresh_token&refresh_token=…` |

Scopes: `r:devices:*`, `x:devices:*`, `r:locations:*` — the same three the
plugin needs today, plus `w:apps:*` on the bootstrap PAT only.

## What is stored, and where

Four secrets, all in the login keyring under service `smartthings`, never in a
config file:

| key | why it must persist |
|---|---|
| `client_id` | identifies the app on every refresh |
| `client_secret` | authenticates the refresh |
| `access_token` | the working credential, 24 hours |
| `refresh_token` | buys the next access token |

The bootstrap PAT is never stored.

## Rotation is the dangerous part

**The refresh token changes every time it is used, and the old one dies.** A
refresh that succeeds at SmartThings but fails to persist locally loses the
account: the stored token is spent, the new one was never written, and the only
way back is the whole setup again.

So the write is ordered accordingly:

1. Exchange, and hold the response in memory.
2. Write the **new refresh token first**, before the access token. A crash
   between the two costs one access token, which is recoverable by refreshing
   again; the reverse order costs the account.
3. Only then treat the exchange as done.

If the refresh itself fails with `invalid_grant`, the chain is broken for good
and the panel must say so and return to setup rather than retrying a spent
token forever.

## Concurrency

Both the bar's poll and the panel's verification read can hit a 401 at the same
moment and both try to refresh. The second refresh would present a token the
first has already spent, and lose the account.

Refresh therefore happens **behind a lock** — an exclusive `flock` on a file in
the runtime directory. A caller that cannot take the lock waits for the holder
and then re-reads the keyring, rather than refreshing again.

## Failure handling

| Condition | Behaviour |
|---|---|
| Access token expired | Refresh once, transparently, then retry the call |
| Refresh returns `invalid_grant` | Chain is dead: clear tokens, panel returns to setup, message says the authorisation was revoked or expired |
| `POST /apps` returns 403 | The bootstrap PAT lacks `w:apps:*`; say exactly that |
| Registration succeeds, authorize fails | Keep the client credentials — re-registering on every attempt would litter the account with apps |
| Localhost redirect refused | Fall back to the paste flow, and say why |

## Scope of the change

**This lands in the SmartThings plugin, not in smartac.** Two reasons: the
general plugin already renders the air conditioner, so smartac may not survive
the decision the user has deferred; and building the same OAuth path twice
before knowing which plugin is kept is work spent to be thrown away.

smartac keeps the PAT flow with the honest 24-hour warning it now carries. If
OAuth proves out here, backporting it is mechanical — or the submission moves
to this plugin instead, which is a strategic choice for the user rather than a
technical one.

## Testing

- The token lifecycle is the part worth testing hardest: refresh-on-401,
  rotation persisted in the right order, `invalid_grant` clearing the chain,
  and the lock preventing a double refresh. All of it is testable against the
  faked `curl` and `secret-tool` the suite already uses.
- Registration is one call with one shape; the fixture is its response.
- Nothing here needs the network or a real account to test.

## Decisions I am making, for the record

1. **The plugin registers its own OAuth app** rather than asking the user to
   install the SmartThings CLI. It costs one extra PAT scope at setup and saves
   a toolchain.
2. **The bootstrap PAT is discarded**, not kept as a fallback. A credential
   that can create apps is not one to keep lying around for convenience.
3. **The refresh token is written before the access token.** The orderings are
   not symmetric: one loses a day, the other loses the account.
4. **Refresh is locked.** Two concurrent refreshes is the realistic way to lose
   a working setup, and this plugin has two independent readers by design.


---

# What testing found

Written after five authorisation attempts against a real account. The design
above is sound on paper; the platform did not cooperate, and the record of why
is worth more than the design.

## The two unverified facts, resolved

**1. `POST /apps` accepts `http://localhost` — and that means nothing.**
Registration returned 200 for a loopback redirect. The authorize endpoint then
refused it with 403. Registration accepting a value is not the platform
honouring it, which is exactly why the two were listed separately.

**2. The 403 was the wrong host, not the loopback.** I concluded from it that
SmartThings forbids loopback redirects entirely, said so as a fact, and
designed a paste-the-code flow around it. That was wrong. The official CLI uses
a different host and a loopback redirect on port 61973:

| host | redirect | authorize |
|---|---|---|
| `api.smartthings.com/oauth/authorize` | `http://localhost` | **403** |
| `oauthin-regional.api.smartthings.com/oauth/authorize` | `http://localhost` | **302** |

The public documentation points at the first host. Taking its 403 as a verdict
about the platform, rather than as a fact about one endpoint, cost three of the
five attempts.

## The app record, settled by reading the CLI

Guessing app fields and having a human click after each guess is a bad loop.
The official CLI's source ends it — `apps-user-input-create.js` builds exactly:

```
appType:        API_ONLY
classifications: [CONNECTED_SERVICE]      // not AUTOMATION
singleInstance:  true
principalType:   LOCATION                 // not USER_LEVEL; and immutable
oauth:           { clientName, scope, redirectUris }
```

Two of my guesses were wrong (`AUTOMATION`, then `USER_LEVEL`), and
`principalType` cannot be changed after creation: the PUT answers 200 and
ignores it. Read the reference implementation before the second guess, not
after the fourth.

## Where it actually stops

The consent screen refuses this account, and the refusal is unaffected by the
app record. Three configurations, including the canonical one, produced the
same result on desktop and on mobile:

- desktop: *"It looks like you have not set up a SmartThings account."*
- mobile: *"É necessária pelo menos uma localização para activar a integração."*

The account has two locations and five devices, and a personal access token
reads and controls all of them. The mobile wording is the honest one and points
at the consent step, not at the account.

The deciding test was the official CLI's own login, which uses Samsung's own
registered client on their own host: it wrote no credentials file. If the
platform's own client cannot complete consent here, nothing registered from
this side will.

## Consequence

OAuth is not reachable for this account, so both plugins stay on personal
access tokens, which expire every 24 hours. That is a property of the
credential and it is now stated plainly in both setup screens and READMEs
rather than discovered by the user the next morning.

What remains worth doing is reducing the friction of the daily paste — one
entry point that stores the token for both plugins, rather than two panels
opened in turn. It is worse than OAuth and it is what the platform allows.
