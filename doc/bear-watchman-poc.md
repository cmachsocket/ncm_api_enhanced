# bear runtime migration — Watchman SDK / jsdom root cause

> Updates doc/bear-e2e-poc.md. I previously attributed the Watchman SDK
> failure to "SDK internal" or "jsdom 30 + SDK compatibility". After
> further tracing, the actual culprit is bare-vm's incomplete Node-vm
> API surface, which breaks jsdom 30's window-creation logic.

## What the stack trace actually shows

The 5% path that fails (`register_checktoken_v2` → jsdom → Watchman SDK)
ends with this stack when run on bare:

```
TypeError: Cannot read properties of undefined (reading 'evaluate')
    at Object.runInContext (bare-vm/index.js:25:16)
    at createWindow (bundle.js:200625:35)
    at new _JSDOM (bundle.js:201609:25)
```

…and after patching bare-vm's `createContext(sandbox)` overload:

```
TypeError: Object.defineProperty called on non-object
    at Object.defineProperty (<anonymous>)
    at Object.beforeParse (bundle.js:201870:20)
    at new _JSDOM (bundle.js:201611:17)
```

## The chain of cause

1. **jsdom 30 calls `vm.createContext(window)`** to "contextify" the
   freshly created `window = {}` object before populating it with web
   platform interfaces (`navigator`, `document`, `EventTarget`, …).
   This is the Node `vm` module API.
2. **On Node**, `vm.createContext(window)` mutates the object's
   internal slot so the V8 engine treats it as a context for
   `runInContext("this", window)` to return `window` itself. After
   contextification, jsdom installs web platform interfaces directly
   onto that same object.
3. **On bare**, `vm` is provided by `bare-vm`. bare-vm's
   `createContext(sandbox)` (when sandbox is provided) is **not
   implemented** — its source is `realms.set(context, realm);
   return context` with no mutation of the sandbox. So the `window`
   object jsdom handed in is *not* registered as the context the
   caller expects.
4. **Subsequent `vm.runInContext("this", window)`** in bare-vm
   resolves the realm via `realms.get(window)` → undefined. The
   code path then crashes with the first `evaluate`/`defineProperty`
   error observed above.
5. The `beforeParse` failure (`window.navigator` undefined) is the
   downstream consequence: jsdom tried to install navigator via
   `vm.runInContext("navigator", window)` to *read* it back, which
   now also fails because the realm is detached from the sandbox.

## What about the SDK?

I previously wrote "SDK internal". That was wrong on inspection: the
Watchman SDK calls `initWatchman(...)` which jsdom exposes as
`dom.window.initWatchman`. That call invokes the Watchman SDK source,
which runs scripts in the window's vm context — and *that* is where
the failure cascades. The SDK itself doesn't probe for `evaluate`
on undefined; it never gets that far because jsdom's window is
half-built.

## Can bare-vm be fixed?

In principle, yes. bare-vm would need to implement
`createContext(sandbox)` to *actually* wrap the sandbox object as a
context. bare-realm (its dep) creates independent realms — each
with its own `globalThis` — and bare-realm doesn't expose a way to
turn an existing object into a realm.

I patched bare-vm locally (see /tmp/bear-poc3/bundle-pkg/node_modules/bare-vm/index.js)
to approximate this: copy sandbox keys into a fresh realm, run
in the realm, then write globals back. That gets past the *first*
crash but lands on the next one (`defineProperty on non-object`)
because jsdom 30's window-setup interleaves `vm.runInContext("this", …)`
with direct `Object.defineProperty(window, …)` calls — these two
storage locations are not actually shared in the patched bare-vm,
so jsdom sees a half-populated window.

A complete fix needs bare-realm itself to support "attach this realm
to an existing object" rather than "create a fresh realm". This is
upstream work in https://github.com/holepunchto/bare-realm, not
something we can patch around in our bundle.

## Recommendation

**Mark the Watchman SDK path as blocked by bare-realm, not by the
SDK itself.** The infrastructure (jsdom, the require graph, axios
+ bare-http1) all work in bare. The blocker is at the seam where
jsdom expects Node vm's contextification semantics, and bare-vm +
bare-realm don't provide them.

For the NCM plugin on bare:

- ~95% of module fns work as-is. Worth shipping as "bare-compatible
  read-only" if that's a useful mode.
- `register_checktoken_v2` / anti-captcha-token-fetching will need
  either a fallback to a non-jsdom anti-captcha strategy, or upstream
  bare-realm work. Out of scope for this repo.
