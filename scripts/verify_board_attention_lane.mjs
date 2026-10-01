#!/usr/bin/env node
//
// bd-79w1fs — the board's Needs-attention swimlane remembers its toggle and
// its coordinator chip per viewer, in browser storage, in a real browser.
//
// `ArbiterWeb.BoardLifecycleLiveTest` proves the server half: the
// `attention_lane_restore` event the `.AttentionLane` hook sends, and the
// `attention_lane_pref` push it answers each toggle with. Neither can run the
// hook itself — the `localStorage` read on mount, the write on each push, and
// the `try`/`catch` that keeps a board with no usable storage working.
//
//   node scripts/verify_board_attention_lane.mjs --url http://localhost:PORT --count N \
//     --ready A,B,C --backlog D [--shots <dir>]
//
// It also drives the `.BoardDrag` hook with real HTML5 drag events: `--ready`
// names three Ready cards in their displayed order, `--backlog` one Backlog
// card. A drop on the top half of a card ranks the dragged one before it and
// the order survives a reload; a Backlog card dropped on Ready is promoted;
// a drop on In progress is refused with a flash.
//
// `--count` is how many swimlane items the seeded board has with the
// coordinator chip on. Output is one `CHECK <name>: PASS|FAIL — <detail>` line
// per claim and a final `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser).
//
// No npm: the browser is Playwright's cached Chromium, driven directly over
// the Chrome DevTools Protocol via Node's built-in WebSocket/fetch.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs"
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
const COUNT = String(options.count || "")
const SHOTS = options.shots || null
const READY = (options.ready || "").split(",").filter(Boolean)
const BACKLOG = options.backlog || null
const KEY = "arbiter:board:attention-lane"

// Read before the run below starts, so they are defined up here.
const LANE_STATE = `JSON.stringify({
  open: document.querySelector("#board-attention-toggle")?.getAttribute("aria-expanded"),
  chip: document.querySelector("#board-attention-coordinator")?.getAttribute("aria-pressed"),
  count: document.querySelector("#board-attention-count")?.textContent.trim(),
  items: !!document.querySelector("#board-attention-items"),
  columns: document.querySelectorAll("#board-columns > [data-column]").length,
  errored: !!document.querySelector(".phx-error")
})`

const STORED = `(() => { try { return window.localStorage.getItem(${JSON.stringify(KEY)}) } catch (_) { return "unavailable" } })()`

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-lane-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    "--window-size=1600,900",
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

  await run(pageDriver(cdp, sessionId), cdp, sessionId)
} catch (error) {
  check("harness", false, (error && error.stack) || String(error))
} finally {
  if (cdp) cdp.close()
  browser.kill("SIGTERM")
  await exited(browser)
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

async function lane(page) {
  return JSON.parse(await page.eval(LANE_STATE))
}

async function run(page, cdp, sessionId) {
  // 1. A first visit: nothing stored, so the lane opens, operator-only.
  await page.goto(`${BASE}/`)
  await page.eval(`window.localStorage.removeItem(${JSON.stringify(KEY)})`)
  await page.goto(`${BASE}/`)
  await boardReady(page, "first visit")

  await screenshot(cdp, sessionId, "board-lane-open")

  let s = await lane(page)
  check("first visit: the lane starts open", s.open === "true" && s.items, JSON.stringify(s))
  check("first visit: the coordinator chip starts off", s.chip === "false", `aria-pressed=${s.chip}`)

  // 2. Toggle both; each change is stored for this viewer.
  await page.eval(`document.querySelector("#board-attention-coordinator").click()`)
  await page.poll(`document.querySelector("#board-attention-coordinator").getAttribute("aria-pressed") === "true"`, "the chip never turned on")
  await page.eval(`document.querySelector("#board-attention-toggle").click()`)
  await page.poll(`document.querySelector("#board-attention-toggle").getAttribute("aria-expanded") === "false"`, "the lane never collapsed")

  const stored = await page.pollValue(`(() => { const v = ${STORED}; return v && JSON.parse(v).open === false ? v : null })()`, "the collapsed state was never stored")
  check("toggling stores the viewer's preference", JSON.parse(stored).coordinator === true, `stored=${stored}`)

  // 3. A reload restores both, and the collapsed lane shows its count.
  await page.goto(`${BASE}/`)
  await boardReady(page, "reload")
  await page.poll(`document.querySelector("#board-attention-toggle").getAttribute("aria-expanded") === "false"`, "the reload did not restore the collapsed lane")

  await screenshot(cdp, sessionId, "board-lane-collapsed")

  s = await lane(page)
  check("reload: the lane is still collapsed", s.open === "false" && !s.items, JSON.stringify(s))
  check("reload: the coordinator chip is still on", s.chip === "true", `aria-pressed=${s.chip}`)
  check("reload: the collapsed lane shows its count", s.count === COUNT, `count=${s.count}, expected ${COUNT}`)

  // 4. No usable storage: reading or writing the lane's key throws, as it
  //    does with storage disabled or over quota. (Only this key: LiveView
  //    itself reads localStorage on boot, and a page whose framework cannot
  //    start is not the hook's failure to handle.) The board still renders,
  //    the lane starts at its defaults, and toggling still works.
  await cdp.send(
    "Page.addScriptToEvaluateOnNewDocument",
    {
      source: `(() => {
        const key = ${JSON.stringify(KEY)}
        const get = Storage.prototype.getItem
        const set = Storage.prototype.setItem
        Storage.prototype.getItem = function (k) {
          if (k === key) throw new DOMException("storage is disabled", "SecurityError")
          return get.call(this, k)
        }
        Storage.prototype.setItem = function (k, v) {
          if (k === key) throw new DOMException("storage is disabled", "SecurityError")
          return set.call(this, k, v)
        }
      })()`
    },
    sessionId
  )

  await page.goto(`${BASE}/`)
  await boardReady(page, "no storage")
  await page.settle(600)

  s = await lane(page)
  check("no storage: localStorage really throws", (await page.eval(STORED)) === "unavailable", "getItem threw")
  check("no storage: the board renders all seven columns", s.columns === 7 && !s.errored, JSON.stringify(s))
  check("no storage: the lane starts open, operator-only", s.open === "true" && s.chip === "false", JSON.stringify(s))

  await page.eval(`document.querySelector("#board-attention-toggle").click()`)
  await page.poll(`document.querySelector("#board-attention-toggle").getAttribute("aria-expanded") === "false"`, "the lane never collapsed without storage")
  await page.settle(300)
  check("no storage: toggling still works", !(await lane(page)).errored, "collapsed, no phx-error")

  // 5. The drag hook, with real drag events.
  await layout(page, cdp, sessionId)
  if (READY.length === 3 && BACKLOG) await drags(page)

  check("no console errors", consoleErrors.length === 0, consoleErrors.slice(0, 3).join(" | ") || "none")
}

function ORDER(column) {
  return `JSON.stringify([...document.querySelectorAll("#board-column-${column} [data-card]")].map((n) => n.dataset.card))`
}

// A drag of card `id` released over `target` — a card (on its top or bottom
// half) or a column — through the same events a browser fires.
function dragScript(id, target, half) {
  return `(() => {
    const card = document.querySelector('[data-card="${id}"]')
    const over = document.querySelector(${JSON.stringify(target)})
    const dt = new DataTransfer()
    const box = over.getBoundingClientRect()
    const y = ${JSON.stringify(half)} === "top" ? box.top + 2 : box.bottom - 2
    const at = { bubbles: true, cancelable: true, dataTransfer: dt, clientX: box.left + 5, clientY: y }
    card.dispatchEvent(new DragEvent("dragstart", at))
    over.dispatchEvent(new DragEvent("dragover", at))
    over.dispatchEvent(new DragEvent("drop", at))
    card.dispatchEvent(new DragEvent("dragend", at))
    return true
  })()`
}

// The columns keep a minimum width: where seven of them don't fit (a 1560px
// viewport stands in for a wide one with the session dock open beside the
// board) the row scrolls, never the page; on a wide screen they fill it.
function LAYOUT() { return `(() => {
  const row = document.querySelector("#board-columns")
  const cols = Array.from(row.children).map((c) => c.getBoundingClientRect().width)
  const root = document.documentElement
  return JSON.stringify({
    count: cols.length,
    min: Math.min(...cols),
    rowScrolls: row.scrollWidth > row.clientWidth + 1,
    pageScrolls: root.scrollWidth > root.clientWidth + 1,
    rem: parseFloat(getComputedStyle(root).fontSize)
  })
})()` }

async function layout(page, cdp, sessionId) {
  const metrics = (width) =>
    cdp.send("Emulation.setDeviceMetricsOverride", { width, height: 900, deviceScaleFactor: 1, mobile: false }, sessionId)

  await metrics(1560)
  await page.settle()
  let l = JSON.parse(await page.eval(LAYOUT()))
  check("layout: with too little room every column keeps its minimum width", l.count === 7 && l.min >= 16 * l.rem - 1, JSON.stringify(l))
  check("layout: the columns row scrolls horizontally", l.rowScrolls, JSON.stringify(l))
  check("layout: the page does not scroll horizontally", !l.pageScrolls, JSON.stringify(l))

  await metrics(2400)
  await page.settle()
  l = JSON.parse(await page.eval(LAYOUT()))
  check("layout: on a wide screen the columns fill the width with no scrollbar", !l.rowScrolls && !l.pageScrolls, JSON.stringify(l))

  await cdp.send("Emulation.clearDeviceMetricsOverride", {}, sessionId)
  await page.settle()
}

async function drags(page) {
  const [a, b, c] = READY
  const want = JSON.stringify([c, a, b])

  await page.goto(`${BASE}/`)
  await boardReady(page, "drag")
  check("drag: Ready starts in the seeded order", (await page.eval(ORDER("ready"))) === JSON.stringify(READY), await page.eval(ORDER("ready")))

  await page.eval(dragScript(c, `[data-card="${a}"]`, "top"))
  const after = await page.pollValue(`(() => { const o = ${ORDER("ready")}; return o === ${JSON.stringify(want)} ? o : null })()`, "the drop never re-ranked Ready").catch((e) => String(e))
  check("drag: a drop on the top half of a card ranks before it", after === want, after)

  await page.goto(`${BASE}/`)
  await boardReady(page, "drag reload")
  const reloaded = await page.eval(ORDER("ready"))
  check("drag: the new order survives a reload", reloaded === want, reloaded)

  await page.eval(dragScript(BACKLOG, "#board-column-ready", "bottom"))
  const promoted = await page.pollValue(`document.querySelector('#board-column-ready [data-card="${BACKLOG}"]') ? "in Ready" : null`, "the Backlog card never reached Ready").catch((e) => String(e))
  check("drag: Backlog → Ready promotes", promoted === "in Ready", promoted)

  await page.eval(dragScript(a, "#board-column-in_progress", "bottom"))
  const flash = await page.pollValue(`(() => { const t = document.body.innerText; return t.includes("cannot be dragged") ? "flashed" : null })()`, "no refusal flash").catch((e) => String(e))
  check("drag: a drop on In progress is refused with a flash", flash === "flashed", flash)
  check("drag: the refused card stays in Ready", !!(await page.eval(`!!document.querySelector('#board-column-ready [data-card="${a}"]')`)), "still in Ready")
}

async function screenshot(cdp, sessionId, name) {
  if (!SHOTS) return
  const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId)
  writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"))
}

async function boardReady(page, what) {
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected") && !!document.querySelector("#board-columns")
     })()`,
    `${what}: the board never loaded`
  )
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

    settle(ms = 400) {
      return sleep(ms)
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

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
