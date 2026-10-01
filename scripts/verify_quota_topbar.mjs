#!/usr/bin/env node
//
// bd-i2gwwn (was bd-gukyy1) — the status bar's quota chip, in a real browser.
//
// `ArbiterWeb.QuotaTopbarTest` proves the markup: one ring object per shown
// provider, its inner 5h and outer 7d rings, the popover's bars, the ARIA. What
// it cannot prove is the geometry and the interaction: that the 36px chip sits
// inside the 46px status bar at the same height whatever the provider count,
// that the wordmark, live badge, inbox trigger and theme toggle still fit
// beside it at `lg` (1024px) and `xl` (1280px) without overlap or horizontal
// overflow, that the ring colours resolve and follow the dark-mode tokens, and
// that the popover opens on a click, a keypress and a tap, closes on a second
// click, Escape and an outside click, and stays inside the viewport. `ConnCase`
// has no layout engine and doesn't run `JS` commands.
//
//   node scripts/verify_quota_topbar.mjs --url http://127.0.0.1:4848 \
//     [--expect claude,antigravity] [--full 1] [--shots <dir>]
//
// `--expect` is the providers the chip must show, in order (default
// `claude,antigravity`, the operator's install). `--full 0` runs only the fit
// checks — the browser test re-runs it that way for one and two providers.
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a final
// `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser). `--shots <dir>` also
// writes PNGs of the status bar per viewport/theme and of the open popover.
//
// No npm (RFC §6.1): the browser is one already on the machine and the driver
// is the Chrome DevTools Protocol over Node's built-in `WebSocket` and `fetch`.

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
const SHOTS = options.shots || null
const EXPECT = (options.expect || "claude,antigravity").split(",").filter(Boolean)
const FULL = options.full !== "0"

// Tailwind's `lg` (64rem) and `xl` (80rem) exactly, a roomy desktop, `sm`
// (40rem) where the chip still shows, and one below `sm` where it hides.
const LG = 1024
const XL = 1280
const WIDE = 1440
const SM = 640
const PHONE = 600
const HEIGHT = 900
const CHIP_HEIGHT = 36

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-quota-topbar-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${WIDE},${HEIGHT}`,
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
  // Exact-PID teardown only. This repo has an incident class around
  // pattern-matching kills reaching the live coordinator.
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

// Everything a claim below is decided from, read in one evaluate.
function stateScript() {
  return `(() => {
  const rect = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }
  }
  const shown = (el) => !!el && getComputedStyle(el).display !== "none" && el.getBoundingClientRect().width > 0
  const header = document.getElementById("app-status-bar")
  const chip = document.getElementById("quota-chip")
  const popover = document.getElementById("quota-popover")
  const objects = [...document.querySelectorAll("#quota-chip [data-ring-provider]")]
  const stroke = (el) => (el ? getComputedStyle(el).stroke : null)
  return JSON.stringify({
    header: rect(header),
    headerOverflow: header.scrollWidth - header.clientWidth,
    pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    width: window.innerWidth,
    height: window.innerHeight,
    chipShown: shown(chip),
    chip: rect(chip),
    expanded: chip && chip.getAttribute("aria-expanded"),
    popoverShown: shown(popover),
    popover: rect(popover),
    objects: objects.map((o) => ({
      provider: o.dataset.ringProvider,
      rect: rect(o),
      logo: rect(o.querySelector("[data-ring-logo] svg")),
      arcs: [...o.querySelectorAll("[data-ring-arc]")].map(stroke),
      track: stroke(o.querySelector("circle:not([data-ring-arc])")),
      hairlines: o.querySelectorAll("[data-ring-hairline]").length,
      label: o.getAttribute("aria-label")
    })),
    chrome: ["appshell-live", "coordinator-inbox-trigger", "theme-toggle"].map((id) => ({
      id,
      shown: shown(document.getElementById(id)),
      rect: rect(document.getElementById(id))
    })),
    wordmark: rect(header.querySelector("[aria-label=Arbiter]:not(.sm\\\\:hidden)")),
    errored: !!document.querySelector(".phx-error")
  })
})()`
}

async function state(page) {
  return JSON.parse(await page.eval(stateScript()))
}

async function joined(page, what, selector) {
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected") && !!document.querySelector(${JSON.stringify(selector)})
     })()`,
    `${what} never joined`
  )
}

function overlaps(a, b) {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
}

function inside(inner, outer) {
  return (
    inner.left >= outer.left - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.bottom <= outer.bottom + 0.5
  )
}

function px(n) {
  return `${Math.round(n * 10) / 10}px`
}

async function screenshot(cdp, sessionId, name, clip) {
  if (!SHOTS || !clip) return
  const { data } = await cdp.send(
    "Page.captureScreenshot",
    {
      format: "png",
      clip: { x: clip.x || 0, y: clip.y || 0, width: clip.width, height: clip.height, scale: clip.scale || 1 }
    },
    sessionId
  )
  writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"))
}

async function open(page, width, theme) {
  await page.resizeViewport(width, HEIGHT)
  await page.goto(`${BASE}/`)
  await joined(page, `/ at ${width}px`, "#app-status-bar")
  if (theme) await page.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
  await page.settle()
  return state(page)
}

function fitChecks(tag, s) {
  check(`${tag} chip shown`, s.chipShown, `#quota-chip displayed: ${s.chipShown}`)

  const providers = s.objects.map((o) => o.provider)
  check(
    `${tag} one ring object per shown provider`,
    providers.join(",") === EXPECT.join(","),
    `objects: ${providers.join(", ")}; expected ${EXPECT.join(", ")}`
  )

  check(
    `${tag} chip height ${CHIP_HEIGHT}px`,
    s.chip && Math.abs(s.chip.height - CHIP_HEIGHT) < 0.5,
    `chip ${s.chip && px(s.chip.width)} × ${s.chip && px(s.chip.height)} for ${providers.length} provider(s)`
  )

  check(
    `${tag} chip fits the status bar`,
    s.chip && inside(s.chip, s.header),
    `chip ${px(s.chip.top)}–${px(s.chip.bottom)} within header ${px(s.header.top)}–${px(s.header.bottom)}`
  )

  const objectsOk = s.objects.every(
    (o) =>
      Math.abs(o.rect.width - 32) < 0.5 &&
      Math.abs(o.rect.height - 32) < 0.5 &&
      inside(o.rect, s.chip) &&
      o.logo &&
      Math.abs(o.logo.left + o.logo.width / 2 - (o.rect.left + o.rect.width / 2)) < 1 &&
      Math.abs(o.logo.top + o.logo.height / 2 - (o.rect.top + o.rect.height / 2)) < 1
  )
  check(
    `${tag} 32px ring objects, logo centred`,
    objectsOk,
    s.objects.map((o) => `${o.provider} ${px(o.rect.width)}×${px(o.rect.height)} logo ${o.logo && px(o.logo.width)}`).join("; ")
  )

  const chromeOk = s.chrome.every(
    (c) => c.shown && c.rect.right <= s.width + 0.5 && !overlaps(c.rect, s.chip) && inside(c.rect, s.header)
  )
  check(
    `${tag} chrome still fits beside the chip`,
    chromeOk && s.wordmark && !overlaps(s.wordmark, s.chip),
    s.chrome.map((c) => `${c.id} shown=${c.shown} ${px(c.rect.left)}–${px(c.rect.right)}`).join("; ") +
      `; wordmark ${s.wordmark && px(s.wordmark.right)}; chip ${px(s.chip.left)}–${px(s.chip.right)}; viewport ${s.width}`
  )

  check(
    `${tag} no horizontal overflow`,
    s.pageOverflow <= 0 && s.headerOverflow <= 0,
    `page ${s.pageOverflow}px, status bar ${s.headerOverflow}px`
  )

  const resolved = s.objects.every((o) => o.arcs.every((a) => a && a !== "none" && a !== o.track))
  check(
    `${tag} ring colours resolve`,
    resolved,
    s.objects.map((o) => `${o.provider} [${o.arcs.join(" | ")}] on ${o.track}`).join("; ")
  )

  check(`${tag} popover closed`, !s.popoverShown && s.expanded === "false", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)
  check(`${tag} page healthy`, !s.errored, `phx-error present: ${s.errored}`)
}

async function center(page, selector) {
  return JSON.parse(
    await page.eval(`(() => {
      const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect()
      return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2 })
    })()`)
  )
}

async function popoverAfter(page, what) {
  await page.settle(350)
  const s = await state(page)
  return { s, what }
}

async function run(page, cdp, sessionId) {
  const arcs = {}
  const widths = FULL ? [LG, XL, WIDE] : [LG, XL]
  const themes = FULL ? ["light", "dark"] : ["light"]

  for (const width of widths) {
    for (const theme of themes) {
      const tag = `${EXPECT.length}p ${width}px/${theme}`
      const s = await open(page, width, theme)
      fitChecks(tag, s)
      arcs[`${width}/${theme}`] = s.objects.map((o) => o.arcs.join(",")).join(";")
      await screenshot(cdp, sessionId, `topbar-${EXPECT.length}p-${width}-${theme}`, { width, height: Math.ceil(s.header.bottom) })
      if (width === LG && s.chip) {
        // The chip alone at 3x, roughly what a high-density screen draws.
        await screenshot(cdp, sessionId, `chip-${EXPECT.length}p-${theme}@3x`, {
          x: Math.floor(s.chip.left - 6),
          y: Math.floor(s.header.top),
          width: Math.ceil(s.chip.width + 12),
          height: Math.ceil(s.header.height),
          scale: 3
        })
      }
    }
  }

  // Below `lg` the rail toggle joins the bar; the chip still fits down to `sm`.
  const sm = await open(page, SM, "light")
  fitChecks(`${EXPECT.length}p ${SM}px/light`, sm)
  const phone = await open(page, PHONE, "light")
  check(`${EXPECT.length}p ${PHONE}px chip hidden below sm`, !phone.chipShown, `#quota-chip displayed: ${phone.chipShown}`)
  check(`${EXPECT.length}p ${PHONE}px no horizontal overflow`, phone.pageOverflow <= 0 && phone.headerOverflow <= 0, `page ${phone.pageOverflow}px, status bar ${phone.headerOverflow}px`)

  if (!FULL) return

  check(
    "ring colours follow the dark-mode tokens",
    arcs[`${LG}/light`] !== arcs[`${LG}/dark`],
    `light ${arcs[`${LG}/light`]} vs dark ${arcs[`${LG}/dark`]}`
  )

  await interaction(page, cdp, sessionId, LG)
  await interaction(page, cdp, sessionId, SM)

  await page.resizeViewport(WIDE, HEIGHT)
  await page.goto(`${BASE}/usage`)
  await joined(page, "/usage", "#usage-quota-antigravity")
  const usage = JSON.parse(
    await page.eval(`JSON.stringify({
      bars: document.querySelectorAll("#usage-quota-antigravity [data-quota-bar]").length,
      claude: document.querySelectorAll("#usage-quota-claude [data-quota-bar]").length,
      overflow: document.documentElement.scrollWidth - window.innerWidth
    })`)
  )
  check("/usage antigravity four bars, claude two", usage.bars === 4 && usage.claude === 2, `antigravity ${usage.bars}, claude ${usage.claude}`)
  check("/usage no horizontal overflow", usage.overflow <= 0, `${usage.overflow}px`)
  if (SHOTS) {
    const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId)
    writeFileSync(path.join(SHOTS, "usage-1440.png"), Buffer.from(data, "base64"))
  }

  check("no console errors", consoleErrors.length === 0, consoleErrors.slice(0, 3).join(" | ") || "none")
}

// The popover: a disclosure toggled by click, Enter and tap; closed by a second
// click, Escape and a click outside; inside the viewport and under the bar.
async function interaction(page, cdp, sessionId, width) {
  const tag = `${width}px`
  const opened = await open(page, width, "light")
  const chip = await center(page, "#quota-chip")
  // "Outside": the empty status bar between the wordmark and the chip —
  // never inside the popover (which hangs below the bar) and never a control.
  const away = {
    x: Math.round((opened.wordmark.right + opened.chip.left) / 2),
    y: Math.round((opened.header.top + opened.header.bottom) / 2)
  }

  await page.click(chip.x, chip.y)
  let { s } = await popoverAfter(page)
  check(`${tag} click opens the popover`, s.popoverShown && s.expanded === "true", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)

  // The browser test broadcasts a changing Claude reading every 150ms: the
  // rings re-render under the open popover, which must stay open.
  const pctBefore = await page.eval(`document.querySelector("#quota-ring-claude-5h").dataset.ringPct`)
  await page.settle(900)
  const pctAfter = await page.eval(`document.querySelector("#quota-ring-claude-5h").dataset.ringPct`)
  ;({ s } = await popoverAfter(page))
  check(
    `${tag} popover survives a server patch`,
    pctBefore !== pctAfter && s.popoverShown && s.expanded === "true",
    `claude 5h ring ${pctBefore}% → ${pctAfter}%; shown ${s.popoverShown}, aria-expanded ${s.expanded}`
  )
  check(
    `${tag} popover inside the viewport, under the bar`,
    s.popover && s.popover.left >= 0 && s.popover.right <= s.width + 0.5 && s.popover.bottom <= s.height + 0.5 && s.popover.top >= s.header.bottom - 0.5,
    s.popover && `popover ${px(s.popover.left)}–${px(s.popover.right)} × ${px(s.popover.top)}–${px(s.popover.bottom)}; viewport ${s.width}×${s.height}; bar bottom ${px(s.header.bottom)}`
  )
  check(
    `${tag} popover clear of the right-hand cluster`,
    s.chrome.every((c) => !overlaps(c.rect, s.popover)),
    s.chrome.map((c) => `${c.id} ${px(c.rect.left)}–${px(c.rect.right)} × ${px(c.rect.top)}–${px(c.rect.bottom)}`).join("; ")
  )
  const entries = JSON.parse(
    await page.eval(`JSON.stringify([...document.querySelectorAll("#quota-popover > section")].map((e) => ({ id: e.id, bars: e.querySelectorAll("[data-quota-bar]").length })))`)
  )
  check(
    `${tag} popover lists each provider's windows`,
    entries.map((e) => e.id).join(",") === EXPECT.map((p) => `quota-popover-${p}`).join(",") && entries.every((e) => e.bars >= 1),
    entries.map((e) => `${e.id}: ${e.bars} bars`).join("; ")
  )
  if (width === LG) {
    await screenshot(cdp, sessionId, `popover-${EXPECT.length}p-${width}`, {
      width,
      height: Math.ceil(Math.min(s.popover.bottom + 12, s.height))
    })
  }

  await page.click(chip.x, chip.y)
  ;({ s } = await popoverAfter(page))
  check(`${tag} second click closes it`, !s.popoverShown && s.expanded === "false", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)

  await page.click(chip.x, chip.y)
  await page.settle(350)
  await page.key("Escape", "Escape", 27)
  ;({ s } = await popoverAfter(page))
  check(`${tag} Escape closes it`, !s.popoverShown && s.expanded === "false", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)

  await page.click(chip.x, chip.y)
  await page.settle(350)
  await page.click(away.x, away.y)
  ;({ s } = await popoverAfter(page))
  check(`${tag} a click outside closes it`, !s.popoverShown && s.expanded === "false", `clicked ${away.x},${away.y}; shown ${s.popoverShown}, aria-expanded ${s.expanded}`)

  await page.click(chip.x, chip.y)
  await page.settle(350)
  const popoverBox = (await state(page)).popover
  await page.click(Math.round(popoverBox.left + 20), Math.round(popoverBox.top + 20))
  ;({ s } = await popoverAfter(page))
  check(`${tag} a click inside the popover keeps it open`, s.popoverShown && s.expanded === "true", `shown ${s.popoverShown}`)
  await page.key("Escape", "Escape", 27)
  await page.settle(350)

  // Keyboard: the chip is a focusable <button>; Enter toggles.
  const focused = await page.eval(`(() => { const c = document.getElementById("quota-chip"); c.focus(); return document.activeElement === c })()`)
  await page.key("Enter", "Enter", 13, "\r")
  ;({ s } = await popoverAfter(page))
  check(`${tag} keyboard: focus + Enter opens it`, focused && s.popoverShown && s.expanded === "true", `focused ${focused}, shown ${s.popoverShown}`)
  await page.key("Escape", "Escape", 27)
  ;({ s } = await popoverAfter(page))
  check(`${tag} keyboard: Escape closes it`, !s.popoverShown, `shown ${s.popoverShown}`)

  // Touch: a tap is a click — no hover-only content.
  await page.touch(true)
  await page.tap(chip.x, chip.y)
  ;({ s } = await popoverAfter(page))
  check(`${tag} touch: a tap opens it`, s.popoverShown && s.expanded === "true", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)
  await page.tap(away.x, away.y)
  ;({ s } = await popoverAfter(page))
  check(`${tag} touch: a tap outside closes it`, !s.popoverShown && s.expanded === "false", `shown ${s.popoverShown}, aria-expanded ${s.expanded}`)
  await page.touch(false)
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
    },

    async onNewDocument(source) {
      await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source }, sessionId)
    },

    async mouseMove(x, y) {
      await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y }, sessionId)
    },

    // A trusted click: pointer there first, so `:hover` is what a real
    // operator would have had at the moment of the press.
    async click(x, y) {
      await driver.mouseMove(x, y)
      for (const type of ["mousePressed", "mouseReleased"]) {
        await cdp.send(
          "Input.dispatchMouseEvent",
          { type, x, y, button: "left", clickCount: 1 },
          sessionId
        )
      }
    },

    async key(key, code, keyCode, text) {
      for (const type of ["keyDown", "keyUp"]) {
        const params = { type, key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode }
        if (text && type === "keyDown") params.text = text
        await cdp.send("Input.dispatchKeyEvent", params, sessionId)
      }
    },

    async touch(enabled) {
      await cdp.send("Emulation.setTouchEmulationEnabled", { enabled, maxTouchPoints: 1 }, sessionId)
    },

    async tap(x, y) {
      await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] }, sessionId)
      await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [{ x, y }] }, sessionId)
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
