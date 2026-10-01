#!/usr/bin/env node
//
// bd-3tnoi9 — the `/settings` page in a real browser, at desktop and mobile width.
//
// `ArbiterWeb.SettingsLiveTest` proves the page's data and its saves.
// What `ConnCase` cannot show is that the page is actually laid out and usable:
// every section drawn, nothing pushed past the viewport at 1280px or at a phone
// width, the theme switcher really flipping `html[data-theme]`, and a save
// typed into a real input round-tripping through the socket.
//
//   node scripts/verify_settings_page.mjs --url http://127.0.0.1:4848 [--mutate 1] [--shots DIR]
//
// `--mutate 1` also types a value into the max-concurrent field, saves it and
// clears it again — leave it off against a live install. `--shots DIR` writes a
// PNG per width (real captures of the real page).
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a final
// `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser). No npm: the browser is
// one already on the machine and the driver is CDP over Node's built-in
// `WebSocket` and `fetch`.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const CHROME_CANDIDATES = [
  process.env.ARB_CHROME,
  path.join(process.env.HOME || "", ".cache/ms-playwright/chromium-1234/chrome-linux64/chrome"),
  path.join(
    process.env.HOME || "",
    ".cache/ms-playwright/chromium_headless_shell-1234/chrome-linux64/headless_shell"
  ),
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome"
].filter(Boolean)

const options = parseArgs(process.argv.slice(2))
const BASE = (options.url || "http://127.0.0.1:4848").replace(/\/$/, "")
const DEADLINE_MS = Number(options.seconds || 30) * 1000
const MUTATE = options.mutate === "1"
const SHOTS = options.shots || null

const NARROW = 400
const WIDE = 1280

const SECTIONS = ["settings-scheduler", "settings-watchdog", "settings-appearance", "settings-about"]

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-settings-page-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${WIDE},900`,
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank"
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
)

let cdp = null

try {
  const port = await waitForDevToolsPort(path.join(profile, "DevToolsActivePort"))
  const { webSocketDebuggerUrl } = await (
    await fetch(`http://127.0.0.1:${port}/json/version`)
  ).json()

  cdp = await connect(webSocketDebuggerUrl)

  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" })
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true })

  cdp.on("Runtime.consoleAPICalled", (params) => {
    if (params.type === "error") consoleErrors.push(describeConsole(params))
  })
  cdp.on("Runtime.exceptionThrown", (params) => {
    const d = params.exceptionDetails
    consoleErrors.push((d.exception && d.exception.description) || d.text)
  })

  await cdp.send("Runtime.enable", {}, sessionId)
  await cdp.send("Page.enable", {}, sessionId)

  await run(pageDriver(cdp, sessionId))
} catch (error) {
  check("harness", false, (error && error.stack) || String(error))
} finally {
  if (cdp) cdp.close()
  // Exact-PID teardown only. This repo has an incident class around
  // pattern-matching kills reaching the live coordinator.
  browser.kill("SIGTERM")
  await exited(browser)
  // Chromium keeps writing into its profile until it is actually gone, so a
  // removal issued alongside the signal loses the race under load
  // (`ENOTEMPTY`). Wait for the exit, retry, and never let cleanup decide the
  // verdict — every CHECK has already been printed by this point.
  try {
    rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 })
  } catch (error) {
    console.log(`NOTE: could not remove ${work}: ${error && error.message}`)
  }
}

const failed = checks.length === 0 || checks.some((c) => !c.ok)
console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- the run ------------------------------------------------------------------

async function run(page) {
  await page.resizeViewport(WIDE, 900)
  await page.goto(`${BASE}/settings`)

  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected")
     })()`,
    "the /settings LiveView never joined"
  )
  await page.settle()

  for (const width of [WIDE, NARROW]) {
    await page.resizeViewport(width, 900)
    await page.settle(500)
    await layoutChecks(page, width)
    await screenshot(page, width)
  }

  // -- the nav entry (desktop rail) -------------------------------------------

  await page.resizeViewport(WIDE, 900)
  await page.settle(500)
  const nav = await page.eval(
    `(() => {
       const a = document.querySelector('#nav-rail a[href="/settings"]')
       return a ? a.getAttribute("aria-current") : null
     })()`
  )
  check("nav-entry-is-active-on-settings", nav === "page", `aria-current=${nav}`)

  // -- the theme switcher -----------------------------------------------------

  const themed = await page.eval(
    `(async () => {
       const read = () => document.documentElement.getAttribute("data-theme")
       const btn = (t) => document.querySelector('#settings-theme-toggle [data-phx-theme="' + t + '"]')
       const seen = {}
       for (const t of ["dark", "light"]) {
         const b = btn(t)
         if (!b) return JSON.stringify({ error: "no " + t + " button" })
         b.click()
         await new Promise((r) => setTimeout(r, 200))
         seen[t] = read()
       }
       btn("system").click()
       await new Promise((r) => setTimeout(r, 200))
       seen.system = read()
       return JSON.stringify(seen)
     })()`,
    true
  )
  const t = JSON.parse(themed)
  check(
    "theme-switcher-sets-data-theme",
    !t.error && t.dark === "dark" && t.light === "light" && !t.system,
    t.error || `dark->${t.dark} light->${t.light} system->${t.system}`
  )

  // -- a real save round-trips ------------------------------------------------

  if (MUTATE) {
    const saved = await submitConcurrency(page, "5")
    check("typed-save-updates-effective-value", saved === "5", `effective=${saved}`)
    const cleared = await submitConcurrency(page, "")
    const override = await page.eval(
      `document.getElementById("settings-concurrency").getAttribute("data-override")`
    )
    check(
      "blank-save-clears-the-override",
      override === "false",
      `data-override=${override} effective=${cleared}`
    )
    const bad = await submitConcurrency(page, "0", true)
    const invalid = await page.eval(
      `document.getElementById("settings-concurrency-field").getAttribute("data-invalid")`
    )
    check("invalid-save-shows-an-inline-error", invalid === "true", `data-invalid=${invalid} ${bad}`)
  }

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )
}

async function submitConcurrency(page, value, expectError = false) {
  await page.eval(
    `(() => {
       const input = document.getElementById("settings-concurrency-input")
       input.focus()
       input.value = ${JSON.stringify(value)}
       input.dispatchEvent(new Event("input", { bubbles: true }))
       document.getElementById("settings-concurrency-save").click()
     })()`
  )
  if (expectError) {
    await page.pollValue(
      `document.getElementById("settings-concurrency-field").getAttribute("data-invalid") === "true" ? "error" : null`,
      "the invalid value never produced an inline error"
    )
    return "refused"
  }
  await sleep(600)
  return page.eval(
    `(() => {
       const el = document.getElementById("settings-concurrency-effective")
       return el ? el.textContent.trim() : null
     })()`
  )
}

async function layoutChecks(page, width) {
  const raw = await page.eval(
    `(() => {
       const sections = ${JSON.stringify(SECTIONS)}.map((id) => {
         const el = document.getElementById(id)
         if (!el) return { id, drawn: false }
         const r = el.getBoundingClientRect()
         return { id, drawn: r.width > 0 && r.height > 0, left: r.left, right: r.right, width: r.width }
       })
       const limit = window.innerWidth + 1
       const offenders = []
       for (const el of document.querySelectorAll("#settings-page *")) {
         const r = el.getBoundingClientRect()
         if (r.width === 0 || r.right <= limit) continue
         if ([...el.children].some((c) => c.getBoundingClientRect().right > limit)) continue
         offenders.push(
           (el.id ? "#" + el.id : el.tagName.toLowerCase()) + " right=" + Math.round(r.right)
         )
       }
       const inputs = ["concurrency", "interval", "recovery"].map((k) => {
         const el = document.getElementById("settings-" + k + "-input")
         return el ? el.getBoundingClientRect().width : 0
       })
       return JSON.stringify({
         sections,
         offenders: offenders.slice(0, 5),
         documentOverflow: document.documentElement.scrollWidth - window.innerWidth,
         inputs
       })
     })()`
  )
  const m = JSON.parse(raw)

  check(
    `every-section-is-drawn-at-${width}px`,
    m.sections.every((s) => s.drawn),
    m.sections.map((s) => `${s.id}=${s.drawn ? Math.round(s.width) : "absent"}`).join(" ")
  )

  check(
    `nothing-overflows-the-viewport-at-${width}px`,
    m.documentOverflow <= 1 && m.offenders.length === 0,
    `document scrollWidth-innerWidth=${round(m.documentOverflow)}px` +
      (m.offenders.length ? `, widest: ${JSON.stringify(m.offenders)}` : "")
  )

  check(
    `number-inputs-are-usable-at-${width}px`,
    m.inputs.every((w) => w >= 60),
    `widths=${m.inputs.map(round).join(",")}`
  )
}

async function screenshot(page, width) {
  if (!SHOTS) return
  mkdirSync(SHOTS, { recursive: true })
  const data = await page.screenshot()
  const file = path.join(SHOTS, `settings-${width}.png`)
  writeFileSync(file, Buffer.from(data, "base64"))
  console.log(`NOTE: wrote ${file}`)
}

// -- the page driver ----------------------------------------------------------

function pageDriver(cdp, sessionId) {
  const driver = {
    async goto(url) {
      await cdp.send("Page.navigate", { url }, sessionId)
      await driver.poll(`document.readyState === "complete"`, `${url} never finished loading`)
    },

    async eval(expression, awaitPromise = false) {
      const { result, exceptionDetails } = await cdp.send(
        "Runtime.evaluate",
        { expression, returnByValue: true, awaitPromise, userGesture: true },
        sessionId
      )

      if (exceptionDetails) {
        throw new Error(
          (exceptionDetails.exception && exceptionDetails.exception.description) ||
            exceptionDetails.text
        )
      }

      return result.value
    },

    async poll(expression, message) {
      await driver.pollValue(`(${expression}) || null`, message)
    },

    async pollValue(expression, message) {
      const deadline = Date.now() + DEADLINE_MS

      while (Date.now() < deadline) {
        let value = null
        try {
          value = await driver.eval(expression)
        } catch (_error) {
          // A navigation can tear the execution context out from under an
          // evaluate; the next poll runs in the new one.
        }
        if (value !== null && value !== undefined && value !== false) return value
        await sleep(100)
      }

      throw new Error(message)
    },

    async screenshot() {
      const { data } = await cdp.send(
        "Page.captureScreenshot",
        { format: "png", captureBeyondViewport: true },
        sessionId
      )
      return data
    },

    settle(ms = 400) {
      return sleep(ms)
    },

    async resizeViewport(width, height) {
      await cdp.send(
        "Emulation.setDeviceMetricsOverride",
        { width, height, deviceScaleFactor: 1, mobile: false },
        sessionId
      )
    }
  }

  return driver
}

// -- helpers ------------------------------------------------------------------

function parseArgs(argv) {
  const options = {}
  for (let i = 0; i < argv.length; i += 2) {
    options[argv[i].replace(/^--/, "")] = argv[i + 1]
  }
  return options
}

// Issue ids are `prefix-suffix`, so they are CSS-safe already, but an id that
// starts with a digit is not a valid bare selector — escape defensively.
function cssEscape(id) {
  return id.replace(/[^a-zA-Z0-9_-]/g, "\\$&").replace(/^(\d)/, "\\3$1 ")
}

function firstExisting(candidates, what) {
  const found = candidates.find((c) => existsSync(c))
  if (!found) {
    console.log(`RESULT: SKIP — no ${what} found (looked in ${candidates.join(", ")})`)
    process.exit(3)
  }
  return found
}

function describeConsole(params) {
  return (params.args || [])
    .map((a) => a.description || (a.value !== undefined ? String(a.value) : a.type))
    .join(" ")
}

function round(n) {
  return Math.round(n * 10) / 10
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// Resolves on the child's exit, or after a grace period if it will not go —
// a hung browser must not hang the verification.
function exited(child, graceMs = 5000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve()

  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      resolve()
    }, graceMs)
    child.once("exit", done)
  })
}

async function waitForDevToolsPort(file) {
  for (let i = 0; i < 100; i++) {
    if (existsSync(file)) {
      const port = readFileSync(file, "utf8").split("\n")[0].trim()
      if (port) return port
    }
    await sleep(100)
  }
  throw new Error("the browser never wrote a DevToolsActivePort")
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    const pending = new Map()
    const listeners = new Map()
    let nextId = 0

    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data)

      if (message.method) {
        const handler = listeners.get(message.method)
        if (handler) handler(message.params || {})
        return
      }

      const waiter = pending.get(message.id)
      if (!waiter) return
      pending.delete(message.id)
      message.error
        ? waiter.reject(new Error(JSON.stringify(message.error)))
        : waiter.resolve(message.result)
    })

    ws.addEventListener("error", () => reject(new Error("devtools socket error")))

    ws.addEventListener("open", () =>
      resolve({
        send(method, params = {}, sessionId) {
          const id = ++nextId
          const frame = { id, method, params }
          if (sessionId) frame.sessionId = sessionId
          ws.send(JSON.stringify(frame))
          return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }))
        },
        on(method, handler) {
          listeners.set(method, handler)
        },
        close: () => ws.close()
      })
    )
  })
}
