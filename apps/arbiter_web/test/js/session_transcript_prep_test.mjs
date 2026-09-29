// What a replayed transcript is rewritten to before xterm sees it (bd-bgemk5).
//
//   node --test apps/arbiter_web/test/js/session_transcript_prep_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { prepareTranscript } from "../../assets/js/session_transcript_prep.mjs"

const ESC = "\x1b"

test("alternate-screen switches are dropped so the replay keeps a scrollback", () => {
  for (const mode of ["47", "1047", "1048", "1049"]) {
    assert.equal(prepareTranscript(`a${ESC}[?${mode}hb${ESC}[?${mode}lc`, 24), "abc")
  }
})

test("mouse tracking is dropped so the wheel scrolls instead of being reported", () => {
  for (const mode of ["9", "1000", "1002", "1003", "1005", "1006", "1015", "1016"]) {
    assert.equal(prepareTranscript(`${ESC}[?${mode}h${ESC}[?${mode}l`, 24), "")
  }
})

test("other private modes survive", () => {
  const data = `${ESC}[?25l${ESC}[?2004h${ESC}[?2026h`
  assert.equal(prepareTranscript(data, 24), data)
})

test("a screen clear pushes the screen it wipes into scrollback first", () => {
  const out = prepareTranscript(`x${ESC}[2Jy`, 3)
  assert.equal(out, `x${ESC}[3;1H\n\n\n${ESC}[H${ESC}[2Jy`)
})

test("text without escapes is untouched", () => {
  assert.equal(prepareTranscript("hello\r\nworld", 24), "hello\r\nworld")
})
