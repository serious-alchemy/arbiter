// Raw PTY bytes, made navigable (bd-bgemk5).
//
// A persisted transcript is what the agent's TUI wrote to a terminal, not a
// log. Replayed verbatim into a read-only xterm it is often unscrollable, for
// two reasons that have nothing to do with how much is replayed:
//
//   * The TUI enters the alternate screen (and, in `mode 1049`, xterm gives
//     the alternate buffer no scrollback at all) and turns on mouse tracking,
//     which makes xterm *report* the wheel instead of scrolling. A live pane
//     wants both; a recording that ends with them still on has neither a
//     scrollback nor a working wheel.
//   * A full-screen redraw is `ESC[2J`, which xterm.js 5.5 discards rather than
//     scrolls, so every screen the agent cleared is gone from the history.
//
// So this drops the screen switch and the mouse modes, and turns each clear
// into "scroll the current screen up into the scrollback, then clear". Nothing
// is typed into a transcript, so nothing is lost by it being inert.

// Alternate screen: 47, 1047, 1048 (save/restore cursor), 1049.
const SCREEN_SWITCH = /\x1b\[\?(?:47|1047|1048|1049)[hl]/g
// X10 (9), normal/button/any tracking, and their encodings (1005/1006/1015/1016).
const MOUSE_TRACKING = /\x1b\[\?(?:9|1000|1002|1003|1005|1006|1015|1016)[hl]/g
const ERASE_DISPLAY = /\x1b\[2J/g

/**
 * @param {string} data  the replayed snapshot
 * @param {number} rows  the pane's row count — how many lines a clear scrolls
 */
export function prepareTranscript(data, rows) {
  const scrollScreenAway = `\x1b[${rows};1H${"\n".repeat(rows)}\x1b[H`

  return data
    .replace(SCREEN_SWITCH, "")
    .replace(MOUSE_TRACKING, "")
    .replace(ERASE_DISPLAY, `${scrollScreenAway}\x1b[2J`)
}
