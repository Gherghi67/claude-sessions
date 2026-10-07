/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs mod: keys above the prompt: rotate past the threshold, wrap up, or /clear once a handoff is armed.
// ABOUTME: A turn ending past CS_ROTATE_FORCE_CTX (default 80, off disables) runs /rotate itself, then counts down to the /clear (session colour, amber, crit); session.start writes a heartbeat for doctor.
// ABOUTME: /queue adds a task to the session's walk-away queue through `cs -queue add`, at once even mid-turn; bare, it prints `cs -queue list`. /finish toasts its start and outcome and, while its gate runs, draws a band with the elapsed time.
import type { On, EngineInterface } from 'claude-code'

declare const h: any
declare const Fragment: any

// KEEP IN SYNC with the ctx warn and crit defaults in bin/cs-statusline
// (_seg_ctx): by default the band appears where the status bar turns amber and
// the Stop hook gives its headroom notice. CS_STATUSLINE_CTX_WARN in the
// process environment moves it, as it moves the bar; CS_ROTATE_BUTTON_CTX moves
// the band alone. A value that is not a number is ignored.
export const DEFAULT_PERCENT = 40

// KEEP IN SYNC with _bg_shade and the `surface` arm of _sgr in
// bin/cs-statusline: the band paints the bar's own capsule fill, a shade of the
// terminal background nudged a tenth away from itself (darker on a light
// terminal, lighter on a dark one), so the keys read as one more capsule of the
// bar rather than as a row of the transcript. cs measures the background at
// launch and exports it; without that measurement the band paints no fill, so a
// guess can never leave the engine's own text on a surface it cannot read
// against.
export const SURFACE_SHIFT = 10

export function surfaceColor(bg: string | undefined): string | undefined {
  const parts = (bg ?? '').split(';')
  if (parts.length !== 3) return undefined
  const rgb = parts.map(part => (/^\s*\d{1,3}\s*$/.test(part) ? Number(part) : 256))
  if (rgb.some(v => v > 255)) return undefined
  const [r, g, b] = rgb
  const shade = 2126 * r + 7152 * g + 722 * b >= 1275000
    ? rgb.map(v => Math.floor(v * (100 - SURFACE_SHIFT) / 100))
    : rgb.map(v => v + Math.floor((255 - v) * SURFACE_SHIFT / 100))
  return `rgb(${shade.join(',')})`
}

// The count's colour ramp, in the status bar's inks. KEEP IN SYNC with _sgr in
// bin/cs-statusline (tests/test_mod_rotate.sh pins every value here against
// it): the session palette is Claude Code's /color, the tab colour cs sets;
// amber and crit are the bar's warning and critical inks. Amber pivots on the
// measured background's luminance (the ink pivot, not the surface one) and
// falls back to the theme; crit follows the theme.
export const SESSION_PALETTE: Record<string, string> = {
  red: '220,38,38', blue: '106,155,204', green: '22,163,74', yellow: '202,138,4',
  purple: '130,125,189', orange: '217,119,87', pink: '196,102,134', cyan: '8,145,178',
}
export const AMBER_LIGHT = '180,83,9'
export const AMBER_DARK = '253,230,138'
export const CRIT_LIGHT = '215,0,21'
export const CRIT_DARK = '255,69,58'
// Seconds left at which the count turns amber, and then crit (below CRIT_AT).
export const AMBER_AT = 10
export const CRIT_AT = 5
// The pane's bar: one block per second of the grace.
export const BAR_FULL = '\u2588'
export const BAR_EMPTY = '\u2591'
// The band's chip and caps, in the bar's inks. KEEP IN SYNC with _sgr in
// bin/cs-statusline (tests/test_mod_rotate.sh pins them): brand is the Claude
// coral the bar's mark wears, and white the chip's ink on a filled chip, softer
// on a dark terminal as the bar's is.
export const BRAND = '217,119,87'
export const WHITE_LIGHT = '255,255,255'
export const WHITE_DARK = '230,230,230'
// The bar's rounded capsule ends, Powerline glyphs drawn in the fill they close.
export const CAP_LEFT = '\ue0b6'
export const CAP_RIGHT = '\ue0b4'

// The colour the count wears with `left` seconds to go: the session's own
// colour while there is time (none, so the surrounding ink, when the session
// has no colour in the palette), amber from AMBER_AT, crit under CRIT_AT.
export function countdownColor(left: number, session: string | undefined, bg: string | undefined, theme: string | undefined): string | undefined {
  const dark = theme === 'dark'
  if (left < CRIT_AT) return `rgb(${dark ? CRIT_DARK : CRIT_LIGHT})`
  if (left <= AMBER_AT) {
    const rgb = (bg ?? '').split(';').map(part => (/^\s*\d{1,3}\s*$/.test(part) ? Number(part) : NaN))
    const measured = rgb.length === 3 && rgb.every(v => v <= 255)
    const light = measured ? 2126 * rgb[0] + 7152 * rgb[1] + 722 * rgb[2] >= 1530000 : !dark
    return `rgb(${light ? AMBER_LIGHT : AMBER_DARK})`
  }
  return paletteColor(session)
}

// A session colour name as an rgb() the engine paints, or undefined for a name
// outside the palette (state hand-edited, or from a newer Claude Code).
export function paletteColor(name: string | undefined): string | undefined {
  const rgb = name === undefined ? undefined : SESSION_PALETTE[name]
  return rgb === undefined ? undefined : `rgb(${rgb})`
}

// The pane's bar with `left` of GRACE_SECONDS still to run.
export function countdownBar(left: number): string {
  const full = Math.max(0, Math.min(GRACE_SECONDS, left))
  return BAR_FULL.repeat(full) + BAR_EMPTY.repeat(GRACE_SECONDS - full)
}

// Doctor observes the mod RUNNING, not merely installed: under a managed
// machine's policy a mod can load and never run. Written when the plugin loads
// (process start or reload; session.start does not fire on /clear). Path is
// relative to the session's cwd, which under cs is the session directory (or
// its worktree).
export const HEARTBEAT = '.cs/local/cs.heartbeat'
// Written by /wrap's last pass: the conversation it wrapped.
export const WRAPPED = '.cs/local/wrapped'

// The rotate skill's last step writes the handoff's basename here; cs's
// SessionStart hook reads it on the next conversation and starts the handoff's
// next step. While it names a handoff the conversation has nothing left to do
// but /clear, whatever the context reads. An encrypted session keeps the
// marker and its handoffs behind .cs/private (a link into its vault).
export const MARKER = '.cs/local/pending-handoff'
export const HANDOFFS = '.cs/handoffs'
export const PRIVATE_MARKER = '.cs/private/pending-handoff'
export const PRIVATE_HANDOFFS = '.cs/private/handoffs'

// The conversation a forced rotation already ran /rotate for, by id. Written
// BEFORE the run is scheduled: a rotation that fails must not be retried at
// the end of every turn. Module state would not do: it survives a /clear
// (measured; a timer started before one kept firing after it) and is lost
// on a reload of the mod.
export const FORCED = '.cs/local/cs.forced'

// Once the forced rotation has armed its handoff, how long the band counts
// down before the mod runs the /clear itself. Pressing the button or sending a
// prompt stops it.
export const GRACE_SECONDS = 20
// The percentage a turn must end past for the mod to rotate on its own. Above
// the 65% nudge, so the ladder stays suggest -> offer -> force, and below where
// Claude Code's own auto-compact lands, so a handoff is written while the
// conversation is still whole.
export const FORCE_DEFAULT = 80

// The pane the first grace of a session opens beside the band: what the
// handoff will do next, read while the count runs. It carries no keys, so
// stopping the count stays on the band, and it closes whenever the count ends.
// Shown once per load of the mod: later graces keep to the band. A pane the
// mod opens on its own is not drawn below 144 columns (110 once the person has
// opened it themselves), so on a narrow terminal the band is all there is.
export const PREVIEW_PANE = 'cs-rotate-handoff'
// The most text a Markdown element takes: a longer one refuses the whole tree,
// and the pane would draw nothing (KEEP IN SYNC with MarkdownProps.text in
// the mods type contract).
export const MARKDOWN_LIMIT = 10000

// The wrap key's question, and the answer that runs /wrap. `$.ui.ask` opens
// the engine's own AskUserQuestion dialog and resolves to the label chosen, or
// to free text typed under Other, so the answer is compared exactly; it rejects
// when the dialog is dismissed and in a `-p` run, where there is nobody to ask.
export const WRAP_QUESTION = 'Run /wrap for this session?'
export const WRAP_YES = 'Yes, wrap up'

// Bare /queue's offer, and the prompt a Start sends when no turn is running.
// `cs -queue start` only arms the queue: the Stop hook hands over each task as
// a turn ends, so an idle session needs one turn to reach that first stop.
export const QUEUE_START = 'Start'
export const QUEUE_COMPACT = 'Compact'
// How much of a task a toast shows: a queued one, or the feature /finish lands.
const TOAST_TASK_CHARS = 60

function cutTask(task: string): string {
  return task.length > TOAST_TASK_CHARS ? `${task.slice(0, TOAST_TASK_CHARS)}…` : task
}

// /finish's progress, as cs records it while `cs <base> -integrate-feature`
// and `-retire-feature` run (_finish_progress_write in lib/30-worktree.sh):
// one record, replaced whole at each step, behind .cs/private in an encrypted
// session and in .cs/local otherwise. pid is the cs process that wrote it.
export const FINISH_RECORD = 'finish-progress.json'
// How often the watch /finish starts reads the record.
export const FINISH_POLL_MS = 1000
export type FinishRecord = {
  id: string
  pid: number
  task: string
  sha: string
  step: string
  gate_started?: number
  result?: string
  reason?: string
}
const FINISH_OUTCOMES = new Set(['landed', 'refused', 'retired'])

// Asked after Start or Compact: how the tasks run, as the word cs -queue start
// takes for each (none runs them in this conversation).
export const QUEUE_MODE_QUESTION = 'How should the queued tasks run?'
export const QUEUE_HERE = 'In this conversation'
export const QUEUE_SUBAGENTS = 'In subagents'
export const QUEUE_WORKFLOWS = 'As workflows'
const QUEUE_MODE_WORDS: Record<string, string[]> = { [QUEUE_HERE]: [], [QUEUE_SUBAGENTS]: ['subagents'], [QUEUE_WORKFLOWS]: ['workflow'] }
export const QUEUE_KICK = 'The cs walk-away queue is started. Reply with one short line saying so, then stop: the cs Stop hook hands you each queued task in turn.'

// The countdown: seconds left, its ticker, and what the band last saw. Module
// state survives a /clear (measured), so every path that ends the countdown
// cancels the ticker; a reload of the mod drops it with its timers.
let left: number | undefined
let ticker: { cancel: () => void } | undefined
let bandIdle = false
// Whether a turn was running when the band last drew: a queue started then
// reaches its first stop without a prompt from the mod.
let turnRunning = false
// The preview's lines while its pane is open, and whether this load has shown it.
let preview: Step | undefined
let previewShown = false

// Which conversation the turns belong to, and whether it is being judged. A
// conversation that begins past the force threshold did not get there by
// working: forcing it would rotate again as soon as its successor woke
// (measured at 1%). Only a conversation born of a /clear seen in this process
// (`clearSeen`, then `birth`) is judged that way, by the context its first
// turn ended with (`startPercent`). Any other new id (a launch, a reload, a
// /resume at 72%) is adopted unjudged, since past the line is exactly where
// the person asked to be rotated. Module state is kept across /clear, which
// is what makes the birth visible.
let adopted: string | undefined
let clearSeen = false
let birth: string | undefined
let startPercent: number | undefined
// Whether this load has registered /queue: session.start fires at load, and
// registering the same name again would only replace it.
let registered = false
// The /finish watch: its timer, whether the turn that started it has ended,
// which steps of which runs have been toasted (`<id>:started`,
// `<id>:<outcome>`), the gate the band shows while one runs under a live pid,
// and whether a problem reading the record or the pid has been said.
let finishWatch: { cancel: () => void } | undefined
let finishTurnOver = false
let finishShown = new Set<string>()
let finishGate: { task: string; since: number } | undefined
let finishProblemShown = false

export function register(on: On) {
  // A (re)load has no countdown: the engine cancelled the old one's timers.
  left = undefined; ticker = undefined; bandIdle = false; turnRunning = false; preview = undefined; previewShown = false; adopted = undefined; clearSeen = false; birth = undefined; startPercent = undefined; registered = false
  finishWatch = undefined; finishTurnOver = false; finishShown = new Set(); finishGate = undefined; finishProblemShown = false
  on('session.start', async ($, e, next) => {
    if (!registered) {
      registered = true
      await $.command.register({ name: 'queue', description: "Add a task to this cs session's walk-away queue, or list it.", argumentHint: '[task]', immediate: true })
    }
    // Only a cs session has .cs/local; anywhere else the mod stays silent.
    const local = `${e.cwd}/.cs/local`
    if (await $.fs.exists(local)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    return next(e)
  })

  // `/queue <task>` runs `cs -queue add` by the path the launch exported;
  // `/queue` alone runs `cs -queue list`. The child inherits the claude
  // process's environment, and CLAUDE_SESSION_META_DIR there picks the queue.
  // Registered immediate, so the hook may run while a turn streams: it reads
  // nothing of the turn. cs is the judge of the task: whatever it refuses
  // (an empty or multi-line body) comes back as its own stderr.
  on('command.run', { command: 'queue' }, async ($, e) => {
    const task = e.args.trim()
    const argv = task === '' ? ['-queue', 'list'] : ['-queue', 'add', e.args]
    const bin = await $.env.get("CS_BIN")
    if (!bin) return { text: 'The launch did not say where cs is (CS_BIN); run `cs -queue add "<task>"` from a shell in this session.' }
    const what = `cs ${argv.slice(0, 2).join(' ')}`
    let result: { exitCode: number; stdout: string; stderr: string }
    try {
      result = await $.process.run([bin, ...argv])
    } catch (err) {
      return { text: `${what} did not run: ${String(err instanceof Error ? err.message : err)}` }
    }
    if (result.exitCode !== 0) {
      const tail = result.stderr.split('\n').filter(l => l.trim() !== '').slice(-5).join('\n')
      return { text: tail === '' ? `${what} exited ${result.exitCode}.` : `${what} exited ${result.exitCode}.\n${tail}` }
    }
    if (task !== '') {
      // The command's text lands in the transcript, which a running turn
      // scrolls past; the toast under the prompt confirms the add where the
      // person is looking. One line, so a long task is cut.
      $.ui.toast(`cs: queued: ${cutTask(task)}`)
      return { text: `Queued: ${task}` }
    }
    const pending = /^Pending \((\d+)\)$/m.exec(result.stdout)
    if (pending && !(await queueRunning($))) void offerToStart($, bin, Number(pending[1]))
    return { text: result.stdout.trimEnd() }
  })

  // The end of a turn is the one moment a rotation can be started for the
  // person: the answer is in, nothing runs. An aborted or errored turn is no
  // place to start one, and a subagent's turn ends in the same event.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) finishTurnOver = true
    if (e.reason === 'answer' && e.agentId === undefined) await forceRotation($)
    return next(e)
  })

  // /finish is a skill: this fires when it is typed, and when `cs <base>
  // -finish` launches a conversation on it. Its turn runs cs's integrate and
  // retire, and the watch follows the record cs writes meanwhile, until that
  // turn is over and nothing runs.
  on('skill.prompt', { skill: 'finish' }, async ($, e, next) => {
    finishTurnOver = false
    if (!finishWatch) await watchFinish($)
    return next(e)
  })

  // A prompt entering the session, from anywhere, means the conversation is
  // not done with: the countdown stops and the prompt goes through untouched.
  on('prompt.submit', async ($, e, next) => {
    if (ticker) stopCountdown($)
    return next(e)
  })

  // A /clear from anywhere else (typed, another plugin) ends the conversation
  // the count belongs to, so the timer must not outlive it, and makes the
  // next conversation a birth; a run the engine refuses makes nothing.
  on('command.run', { command: 'clear' }, async ($, e, next) => {
    clearSeen = true
    if (ticker) stopCountdown($)
    try {
      return await next(e)
    } catch (err) {
      clearSeen = false
      throw err
    }
  })

  // A turn that starts from a prompt is work after any wrap that finished: the
  // marker that wrap left no longer describes the conversation. A continuation
  // (no prompt, as a Stop hook's feedback starts one) is the wrap's own turn.
  on('turn.start', async ($, e, next) => {
    if (e.text !== '') await clearWrapped($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const drawn = await withGateBand($, e, await next(e))
    // The band draws in a new conversation before any of its turns end, so
    // the birth is settled here: a later /resume is not mistaken for it.
    noteConversation(await $.session.id())
    // A survey owns the band; a running turn cannot be rotated out of.
    turnRunning = e.props.isWorking
    bandIdle = !e.props.hasSurvey && !e.props.isWorking
    if (!bandIdle) return drawn
    const armed = await handoffArmed($)
    const { context } = await $.session.usage()
    const percent = context.percent
    if (!armed && (percent === undefined || percent < (await threshold($)))) return drawn
    if (!(await ownsRotation($))) return drawn
    const wrapped = !armed && (await wrapFinished($))
    const fill = surfaceColor(await $.env.get("CS_TERM_BG_RGB"))
    const chords = await boundChords($)
    const own = paletteColor(await sessionColor($))
    // The chip is the band's identity, as the session name is the bar's: on
    // the session colour, Claude coral once a handoff is armed so the /clear
    // reads apart, and on the surface in the terminal's own ink for a session
    // with no colour. The body keeps the surface either way, where the count's
    // ramp keeps its contrast.
    const chipFill = armed ? `rgb(${BRAND})` : own ?? fill
    const chipInk = chipFill === fill
      ? undefined
      : `rgb(${(await $.env.get("CS_TERM_THEME")) === 'dark' ? WHITE_DARK : WHITE_LIGHT})`
    // Caps close a fill on the terminal's own background, so they need both a
    // fill and this machine's consent to the glyph.
    const caps = fill !== undefined && chipFill !== undefined && (await capsWanted($))
    const { Box, Text, Button } = await $.ui.resolve(e)
    // The Buttons carry no hotkey: a bare digit pressed them from an empty
    // composer, where a digit typed as the answer to a numbered question
    // belongs. A chord bound to each Button's action presses it instead, and
    // the engine draws a Button with no hotkey as its label alone, so the key
    // is spelled beside it, and only when keybindings.json binds one.
    const key = (action: string) => chords[action] !== undefined &&
      <Box marginRight={1}><Text bold color={own}>{chords[action]}</Text></Box>
    // One capsule in the status bar's idiom: the cs chip, then the keys on the
    // bar's own fill, a blank line above them so the band reads apart from the
    // transcript. The context percentage is the bar's to carry; the band does
    // not repeat it. The keyed box lights coral under the pointer; the engine
    // restyles it without running the hook. It starts two columns in, where
    // Claude Code draws the bar and the mode line under the prompt.
    return (
      <Box flexDirection="column">
        {drawn}
        <Box marginTop={1}>
          <Box key="cs-rotate-band" marginLeft={2}>
            {caps && <Text color={chipFill}>{CAP_LEFT}</Text>}
            <Box paddingX={1} backgroundColor={chipFill}><Text bold color={chipInk}>cs</Text></Box>
            <Box key="cs-rotate-band-body" paddingX={1} backgroundColor={fill}>
            {key(ROTATE_ACTION)}
            {armed
              ? <Button key="cs-rotate" action={ROTATE_ACTION} plain label="/clear and continue from the handoff"
                        onPress={() => clearAndContinue($)} />
              : <Button key="cs-rotate" action={ROTATE_ACTION} plain label="rotate this conversation"
                        onPress={() => rotate($)} />}
            {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured), so the separator stands beside it */}
            {!armed && !wrapped && <Text dimColor>{'  \u00b7  '}</Text>}
            {!armed && !wrapped && key(WRAP_ACTION)}
            {!armed && !wrapped && <Button key="cs-wrap" action={WRAP_ACTION} plain label="wrap up this session" onPress={() => askToWrap($)} />}
            {/* the forced rotation's grace: the seconds left before the mod runs the /clear itself */}
            {armed && left !== undefined && <Text dimColor>{'  \u00b7  '}</Text>}
            {armed && left !== undefined && <Text bold color={await rampColor($, left)}>{`/clear in ${left}s`}</Text>}
            </Box>
            {caps && <Text color={fill}>{CAP_RIGHT}</Text>}
          </Box>
        </Box>
      </Box>
    )
  })

  // The preview's body: the handoff's next step and the count. Any other pane,
  // or this one once the count has ended, is not the mod's to draw.
  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PREVIEW_PANE || preview === undefined) return next(e)
    const { Box, Text, Markdown } = await $.ui.resolve(e)
    // With one pane open the engine draws no title, so the pane carries its
    // own, in the session's colour; the step is drawn as a reply's markdown is.
    const own = paletteColor(await sessionColor($))
    const color = left === undefined ? undefined : await rampColor($, left)
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text key="header" bold color={own}>Handoff</Text>
        <Box flexDirection="column" marginTop={1}>
          <Markdown key="step" text={preview.text} />
          {preview.cut && <Text key="cut" dimColor>… the rest of the step is in the handoff</Text>}
        </Box>
        {left !== undefined && (
          <Box flexDirection="column" marginTop={1}>
            <Box>
              <Text key="bar" color={color}>{countdownBar(left)}</Text>
              <Text>{'  '}</Text>
              <Text key="count" bold color={color}>{`/clear in ${left}s`}</Text>
            </Box>
            <Text dimColor>press 1 to clear now, or send a prompt to stay</Text>
          </Box>
        )}
      </Box>
    )
  })
}

function numberOr(raw: string | undefined, fallback: number): number {
  return raw !== undefined && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : fallback
}

// On at FORCE_DEFAULT unless CS_ROTATE_FORCE_CTX says otherwise: `off` (any
// case) and `0` turn the forcing off, a percentage moves it, and anything else
// — a typo — is the default rather than silence, because a value nobody can
// read must not quietly disable a rotation the person is relying on.
// `claude plugin validate` lists what a module reads, and a name it does not
// spell is refused.
async function forceThreshold($: EngineInterface): Promise<number | undefined> {
  const raw = (await $.env.get("CS_ROTATE_FORCE_CTX"))?.trim()
  if (raw === undefined || raw === '') return FORCE_DEFAULT
  if (raw.toLowerCase() === 'off' || /^0+$/.test(raw)) return undefined
  return /^\d+$/.test(raw) ? Number(raw) : FORCE_DEFAULT
}

// A conversation id the mod has not met yet is the current one from here on,
// and the call says so. It is a birth, to be judged by its first turn's end,
// only when a /clear was seen since the last id; a /resume, a launch or a
// reload adopt unjudged, and an earlier judgment of the same id is dropped
// with them.
function noteConversation(id: string): boolean {
  if (id === adopted) return false
  adopted = id
  startPercent = undefined
  birth = clearSeen ? id : undefined
  clearSeen = false
  return true
}

// Runs /rotate for the person once a turn ends past the force threshold, once
// per conversation, from a timer: the contract refuses `$.command.run` inside
// a hook the turn is waiting on, and a `clock.after` callback runs once the
// hook has returned (measured: a 0 ms timer scheduled in turn.complete ran the
// command). A rejected run is not retried; the button stays for the person.
async function forceRotation($: EngineInterface) {
  const force = await forceThreshold($)
  if (force === undefined) return
  if (!(await ownsRotation($))) return
  const id = await $.session.id()
  const { context } = await $.session.usage()
  noteConversation(id)
  if (birth === id) {
    birth = undefined
    startPercent = context.percent
    if (startPercent !== undefined && startPercent >= force) {
      $.ui.toast(`cs: CS_ROTATE_FORCE_CTX=${force} is below this conversation's starting context (${startPercent}%); not forcing a rotation`)
    }
  }
  if (await handoffArmed($)) {
    if (!ticker) startCountdown($)
    return
  }
  if (startPercent !== undefined && startPercent >= force) return
  if (context.percent === undefined || context.percent < force) return
  const forced = `${await $.session.cwd()}/${FORCED}`
  if ((await $.fs.exists(forced)) && (await $.fs.read(forced)).trim() === id) return
  await $.fs.write(forced, `${id}\n`)
  $.clock.after(0, () => {
    rotate($).catch(err => $.ui.toast(`cs: /rotate did not run: ${String(err)}`))
  })
}

// Counts the band down, one redraw a second (the contract folds calls past
// ten a second). Each redraw re-reads the marker and the handoff: the count
// must see the press and the prompt that stop it, so nothing here is cached.
// At zero the /clear runs only where the band would draw the button: the band
// idle, the handoff still armed, this the lead; otherwise the count stops and
// the button stays for the person.
function startCountdown($: EngineInterface) {
  left = GRACE_SECONDS
  if (!previewShown) {
    previewShown = true
    // From a timer: the count starts inside the turn's own hook.
    $.clock.after(0, () => openPreview($))
  }
  ticker = $.clock.every(1000, async () => {
    // Nothing to count once stopped, and nothing below zero: a period that
    // lands while the zero tick is still reading leaves the count where it is.
    if (left === undefined || left <= 0) return
    left -= 1
    $.ui.invalidate('ui.render')
    if (left > 0) return
    // The count holds at zero through the reads below: a prompt or a press
    // landing meanwhile stops it (left becomes undefined), and this tick
    // then does nothing, so nothing clears twice or behind a new turn.
    const idle = bandIdle && (await handoffArmed($)) && (await ownsRotation($))
    if (left !== 0) return
    stopCountdown($)
    if (idle) await clearAndContinue($).catch(err => $.ui.toast(`cs: /clear did not run: ${String(err)}`))
  })
}

function stopCountdown($: EngineInterface) {
  ticker?.cancel()
  ticker = undefined
  left = undefined
  if (preview !== undefined) {
    preview = undefined
    $.ui.close({ id: PREVIEW_PANE }).catch(err => $.ui.toast(`cs: the handoff pane did not close: ${String(err)}`))
  }
  $.ui.invalidate('ui.render')
}

// Opens the preview for the count that scheduled it, if that count still runs.
async function openPreview($: EngineInterface) {
  if (ticker === undefined) return
  const text = await armedHandoff($)
  if (text === undefined || ticker === undefined) return
  preview = nextStep(text)
  await $.ui.open({ id: PREVIEW_PANE, title: 'Handoff' })
  // The count can end while the open is in flight, and its close may reach the
  // engine first: a pane that lands after its count is closed here, since
  // nothing else will close it.
  if (preview === undefined) {
    await $.ui.close({ id: PREVIEW_PANE }).catch(err => $.ui.toast(`cs: the handoff pane did not close: ${String(err)}`))
  }
}

// A handoff's next step as the pane shows it: the section's markdown, and
// whether MARKDOWN_LIMIT cut it short.
export type Step = { text: string; cut: boolean }

// The handoff's Next Step section (`# Next Step`, `## 1. Next Step`) as
// written, blank lines and all, trimmed of the blank lines around it; empty
// when it has none. Past MARKDOWN_LIMIT it keeps the whole lines that fit.
export function nextStep(text: string): Step {
  const lines = text.split('\n')
  const start = lines.findIndex(line => /^#+\s*(\d+\.\s*)?next step\s*$/i.test(line.trim()))
  if (start < 0) return { text: '', cut: false }
  const body: string[] = []
  // A `#` line inside a fenced block (a shell comment in a command block) is
  // the step's text, not the next section.
  let fence: string | undefined
  for (const line of lines.slice(start + 1)) {
    const marker = /^\s*(```|~~~)/.exec(line)?.[1]
    if (marker !== undefined) fence = fence === undefined ? marker : fence === marker ? undefined : fence
    else if (fence === undefined && /^#+\s/.test(line)) break
    body.push(line.trimEnd())
  }
  const step = body.join('\n').replace(/^\n+/, '').trimEnd()
  if (step.length <= MARKDOWN_LIMIT) return { text: step, cut: false }
  // a line longer than the bound has no line end to stop at: cut at the bound
  const end = step.lastIndexOf('\n', MARKDOWN_LIMIT)
  return { text: end > 0 ? step.slice(0, end).trimEnd() : step.slice(0, MARKDOWN_LIMIT), cut: true }
}

// The band's own threshold; without one it is the bar's warn band, read the way
// the bar reads it. Each variable's name is a literal: `claude plugin validate`
// lists what a module reads, and a name it does not spell is refused.
async function threshold($: EngineInterface): Promise<number> {
  return numberOr(
    await $.env.get("CS_ROTATE_BUTTON_CTX"),
    numberOr(await $.env.get("CS_STATUSLINE_CTX_WARN"), DEFAULT_PERCENT),
  )
}

// Armed means the marker names a handoff the SessionStart hook will accept
// after the /clear: a bare basename (the hook rejects a separator), a file in
// the store, and frontmatter that still says unconsumed. A marker an aborted
// rotation left behind, or one naming a handoff since consumed, would offer a
// /clear that lands in a conversation with nothing to continue from, so it
// does not arm. One exists per render; the reads only while the marker is there.
async function handoffArmed($: EngineInterface): Promise<boolean> {
  return (await armedHandoff($)) !== undefined
}

// The armed handoff's text, read under the rule above; undefined when unarmed.
// Each marker names a handoff in its own store only: the vault's marker never
// arms from the plaintext store, nor the reverse. The marker is read rather
// than probed for, as queueRunning does: a read follows the .cs/private link
// the way the hook's own does, and a marker that cannot be read (absent, or
// behind a locked vault) arms nothing.
async function armedHandoff($: EngineInterface): Promise<string | undefined> {
  const cwd = await $.session.cwd()
  for (const [marker, store] of [[PRIVATE_MARKER, PRIVATE_HANDOFFS], [MARKER, HANDOFFS]]) {
    let name: string
    try {
      name = (await $.fs.read(`${cwd}/${marker}`)).trim()
    } catch {
      continue
    }
    if (name === '' || /[/\\]/.test(name)) return undefined
    try {
      const text = await $.fs.read(`${cwd}/${store}/${name}`)
      return isUnconsumed(text) ? text : undefined
    } catch {
      return undefined
    }
  }
  return undefined
}

// The hook's own rule (_handoff_is_unconsumed in hooks/session-start.sh): a
// frontmatter block opened by `---` on the first line and CLOSED by the next
// `---`, carrying `status: unconsumed` between them. A file the closing line
// never reaches (a truncated write) is not armed: the hook would refuse it,
// and a /clear on it would land in a conversation with nothing to continue.
export function isUnconsumed(text: string): boolean {
  const lines = text.split('\n')
  if (lines[0] !== '---') return false
  let matched = false
  for (const line of lines.slice(1)) {
    if (line === '---') return matched
    if (line === 'status: unconsumed') matched = true
  }
  return false
}

// The count's colour for this session and terminal. Each name is a literal:
// `claude plugin validate` lists what a module reads.
async function rampColor($: EngineInterface, secs: number): Promise<string | undefined> {
  return countdownColor(secs, await sessionColor($), await $.env.get("CS_TERM_BG_RGB"), await $.env.get("CS_TERM_THEME"))
}

// The session's colour name as cs recorded it in state, or undefined.
async function sessionColor($: EngineInterface): Promise<string | undefined> {
  const state = await readState($)
  return state?.match(/^claude_session_color: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
}

// Whether this machine has said its font has the bar's cap glyphs: the
// statusline's own rule (_caps_wanted in bin/cs-statusline, KEEP IN SYNC).
// CS_STATUSLINE_CAPS=1 or 0 decides; otherwise the per-machine answer file
// holding `on`. Unanswered, or unreadable, means square ends.
async function capsWanted($: EngineInterface): Promise<boolean> {
  const forced = await $.env.get("CS_STATUSLINE_CAPS")
  if (forced === '1') return true
  if (forced === '0') return false
  const config = (await $.env.get("XDG_CONFIG_HOME")) || `${await $.env.get("HOME")}/.config`
  try {
    return (await $.fs.read(`${config}/cs/statusline-caps`)).split('\n')[0] === 'on'
  } catch {
    return false // no answer file: unanswered
  }
}

// The engine actions the band's Buttons answer to. They carry no default
// chord and no engine handler is mounted for them (measured on 2.1.291 and
// 2.1.292), so the chord a person binds to one presses the Button. KEEP IN
// SYNC with CS_ROTATE_WRAP_KEYS in lib/01-manifests.sh, which binds them.
export const ROTATE_ACTION = 'strip:jump1'
export const WRAP_ACTION = 'strip:jump2'

// The chord keybindings.json binds to each action in the Global context, as
// the person wrote it. Claude Code reads that file from CLAUDE_CONFIG_DIR, else
// ~/.claude; an encrypted session's config dir holds a link to the shell's
// file, so this reads the file Claude Code reads. An unreadable or malformed
// file, or a key unbound with null, binds nothing.
async function boundChords($: EngineInterface): Promise<Record<string, string>> {
  const dir = (await $.env.get("CLAUDE_CONFIG_DIR")) || `${await $.env.get("HOME")}/.claude`
  let doc: any
  try {
    doc = JSON.parse(await $.fs.read(`${dir}/keybindings.json`))
  } catch {
    return {} // no file, or not JSON: no chord to spell
  }
  const chords: Record<string, string> = {}
  for (const block of Array.isArray(doc?.bindings) ? doc.bindings : []) {
    if (block?.context !== 'Global' || typeof block.bindings !== 'object' || block.bindings === null) continue
    for (const [chord, action] of Object.entries(block.bindings)) {
      if (typeof action === 'string' && chords[action] === undefined) chords[action] = chord
    }
  }
  return chords
}

async function readState($: EngineInterface): Promise<string | undefined> {
  try {
    return await $.fs.read(`${await $.session.cwd()}/.cs/local/state`)
  } catch {
    return undefined // no state: not a session cs launched
  }
}

// Only the lead conversation of a cs session may be offered a rotation. The
// rotate skill refuses outside a cs session, .cs/local/disabled opts a
// directory out of cs entirely, and the handoff it writes carries the UUID in
// .cs/local/state, which belongs to the one conversation cs launched: a
// teammate claude in the same directory would arm the lead's marker under the
// lead's identity. The checks run only once the band has a button to draw.
// The value may be quoted and may carry trailing spaces, as cs's own state
// readers allow.
async function ownsRotation($: EngineInterface): Promise<boolean> {
  const local = `${await $.session.cwd()}/.cs/local`
  if (!(await $.fs.exists(local)) || (await $.fs.exists(`${local}/disabled`))) return false
  const state = await readState($)
  if (state === undefined) return false
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// Runs the rotate skill as if the person had typed /rotate: the skill draws
// the purpose from the conversation itself.
async function rotate($: EngineInterface) {
  await $.command.run({ command: 'rotate', args: '' })
}

// /wrap's last pass writes WRAPPED naming the conversation it ran in
// (CLAUDE_CODE_SESSION_ID, so a teammate's wrap names the teammate), so a wrap
// that finished is the conversation's latest act and the key has nothing to
// offer. The next turn started from a prompt clears it. A summary written any
// other way proves nothing.
async function wrapFinished($: EngineInterface): Promise<boolean> {
  const marker = await readWrapped($)
  return marker !== '' && marker === (await $.session.id())
}

async function clearWrapped($: EngineInterface) {
  const marker = await readWrapped($)
  if (marker === '' || marker !== (await $.session.id())) return
  await $.fs.write(`${await $.session.cwd()}/${WRAPPED}`, '').catch(() => {})
}

async function readWrapped($: EngineInterface): Promise<string> {
  try {
    return (await $.fs.read(`${await $.session.cwd()}/${WRAPPED}`)).trim()
  } catch {
    return '' // no wrap has finished here
  }
}

// `2` asks before running /wrap: it replaces .cs/summary.md and runs two Opus
// passes before the narrative rotation, so a key that may have been meant for
// the composer opens the engine's own dialog rather than acting on the press.
async function askToWrap($: EngineInterface) {
  let answer: string
  try {
    answer = await $.ui.ask(WRAP_QUESTION, { header: 'Wrap', options: [WRAP_YES, 'Not now'] })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask
  }
  if (answer !== WRAP_YES) return
  try {
    await $.command.run({ command: 'wrap', args: '' })
  } catch (err) {
    $.ui.toast(`cs: /wrap did not run: ${String(err)}`)
  }
}

// An armed or draining queue is already on its way; only bin/cs and the Stop
// hook write the file, and no file is an idle queue.
// An encrypted session keeps its queue behind .cs/private (a link into its
// vault), every other session in .cs/local. A file that cannot be read (absent,
// or behind a locked vault) says nothing about the queue.
async function queueRunning($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  for (const dir of ['private', 'local']) {
    let state: string
    try {
      state = (await $.fs.read(`${cwd}/.cs/${dir}/queue.state`)).trim()
    } catch {
      continue
    }
    return state === 'armed' || state === 'draining'
  }
  return false
}

// Asked after bare /queue has printed the list, so the tasks are on screen
// when the question is. Start arms the queue; Not yet defers it the way the
// Stop hook's own offer does, so that offer does not ask again straight away.
// Compact compacts the conversation first, then starts as Start does; a
// compaction that does not happen leaves the queue unarmed. Start and Compact
// then ask how the tasks run, before any compaction, so a dismissed second
// question starts and compacts nothing.
async function offerToStart($: EngineInterface, bin: string, count: number) {
  let answer: string
  try {
    answer = await $.ui.ask(`Start the ${count} queued ${count === 1 ? 'task' : 'tasks'} now?`, { header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask
  }
  const starting = answer === QUEUE_START || answer === QUEUE_COMPACT
  let mode: string[] = []
  if (starting) {
    let how: string
    try {
      how = await $.ui.ask(QUEUE_MODE_QUESTION, { header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] })
    } catch {
      return
    }
    const words = QUEUE_MODE_WORDS[how]
    if (words === undefined) {
      // Free text typed under "Other" names no mode cs knows.
      $.ui.toast(`cs: '${how}' is not a way to run the queue; it is not started`)
      return
    }
    mode = words
  }
  if (answer === QUEUE_COMPACT) {
    let reason: string | undefined
    try {
      const compacted = await $.session.compact()
      reason = 'skip' in compacted ? compacted.skip : undefined
    } catch (err) {
      reason = String(err instanceof Error ? err.message : err)
    }
    if (reason !== undefined) {
      $.ui.toast(`cs: the conversation was not compacted (${reason}); the queue is not started`)
      return
    }
  }
  const verb = starting ? 'start' : 'defer'
  let result: { exitCode: number; stdout: string; stderr: string }
  try {
    result = await $.process.run([bin, '-queue', verb, ...mode])
  } catch (err) {
    $.ui.toast(`cs: cs -queue ${verb} did not run: ${String(err instanceof Error ? err.message : err)}`)
    return
  }
  if (result.exitCode !== 0) {
    const tail = result.stderr.split('\n').filter(l => l.trim() !== '').slice(-1)[0] ?? ''
    $.ui.toast(`cs: cs -queue ${verb} exited ${result.exitCode}${tail === '' ? '' : `: ${tail}`}`)
    return
  }
  if (verb !== 'start' || turnRunning) return
  try {
    await $.prompt.submit({ text: QUEUE_KICK })
  } catch (err) {
    $.ui.toast(`cs: the queue is armed, but its first turn did not start: ${String(err instanceof Error ? err.message : err)}`)
  }
}

// /clear ends this conversation, and cs's SessionStart hook then starts the
// armed handoff's next step in the new one.
// Measured: the run resolves once the screen has cleared and a new transcript
// is open; the marker is the hook's to consume.
async function clearAndContinue($: EngineInterface) {
  clearSeen = true
  if (ticker) stopCountdown($)
  try {
    await $.command.run({ command: 'clear', args: '' })
  } catch (err) {
    clearSeen = false
    throw err
  }
}

// Starts the /finish watch. Whatever the record holds now belongs to an
// earlier run, so its steps count as shown: only what this /finish writes is
// toasted.
async function watchFinish($: EngineInterface) {
  const before = await readFinish($)
  if (before !== undefined) {
    finishShown.add(`${before.id}:started`)
    finishShown.add(`${before.id}:${before.step}`)
  }
  finishWatch = $.clock.every(FINISH_POLL_MS, () => followFinish($))
}

// One read of the record: toast a run's start and its outcome once each, keep
// the band's gate while a gate runs under a live pid, and end the watch once
// the turn is over with nothing running. A step whose pid is gone was left by
// a run that was killed: it is over, whatever it says.
async function followFinish($: EngineInterface) {
  const record = await readFinish($)
  let live = false
  let gate: typeof finishGate
  if (record !== undefined) {
    const outcome = FINISH_OUTCOMES.has(record.step)
    const key = `${record.id}:${outcome ? record.step : 'started'}`
    if (!finishShown.has(key)) {
      finishShown.add(key)
      $.ui.toast(finishToast(record))
    }
    live = !outcome && (await pidAlive($, record.pid))
    if (live && record.step === 'gate' && record.gate_started !== undefined) gate = { task: record.task, since: record.gate_started }
  }
  // While the band shows, every read redraws it: its elapsed time moves.
  if (gate !== undefined || finishGate !== undefined) $.ui.invalidate('ui.render')
  finishGate = gate
  if (finishTurnOver && !live) {
    finishWatch?.cancel()
    finishWatch = undefined
  }
}

// The toast for a record: the run starting, or its outcome.
export function finishToast(record: FinishRecord): string {
  const task = cutTask(record.task)
  switch (record.step) {
    case 'landed': return `cs: landed ${task} ${record.sha.slice(0, 7)} -> ${(record.result ?? '').slice(0, 7)}`
    case 'refused': return `cs: /finish ${task} refused: ${record.reason ?? ''}`
    case 'retired': return `cs: retired ${task}`
    default: return `cs: finishing ${task}`
  }
}

// The record as cs wrote it, from the vault's store first, as queueRunning
// reads; undefined when there is none. One cs did not write (hand-edited, or
// from another version) is said once and otherwise read as no record, since
// the watch would only repeat the complaint every second.
async function readFinish($: EngineInterface): Promise<FinishRecord | undefined> {
  const cwd = await $.session.cwd()
  for (const dir of ['private', 'local']) {
    let text: string
    try {
      text = await $.fs.read(`${cwd}/.cs/${dir}/${FINISH_RECORD}`)
    } catch {
      continue // absent, or behind a locked vault
    }
    const record = parseFinish(text)
    if (record === undefined) finishProblem($, `.cs/${dir}/${FINISH_RECORD} is not a record cs wrote; /finish progress is not shown`)
    return record
  }
  return undefined
}

export function parseFinish(text: string): FinishRecord | undefined {
  let r: unknown
  try {
    r = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof r !== 'object' || r === null) return undefined
  const o = r as Record<string, unknown>
  if (typeof o.id !== 'string' || typeof o.task !== 'string' || typeof o.sha !== 'string' || typeof o.step !== 'string') return undefined
  if (typeof o.pid !== 'number' || !Number.isInteger(o.pid) || o.pid <= 0) return undefined
  if (o.gate_started !== undefined && typeof o.gate_started !== 'number') return undefined
  if (o.step === 'landed' && typeof o.result !== 'string') return undefined
  if (o.step === 'refused' && typeof o.reason !== 'string') return undefined
  return {
    id: o.id, pid: o.pid, task: o.task, sha: o.sha, step: o.step,
    gate_started: o.gate_started as number | undefined,
    result: typeof o.result === 'string' ? o.result : undefined,
    reason: typeof o.reason === 'string' ? o.reason : undefined,
  }
}

// Whether the cs process that wrote a step still runs: `kill -0` sends no
// signal, it only asks. A check that cannot run is said once and counts as
// not running, so a band never outlives what it stands for.
async function pidAlive($: EngineInterface, pid: number): Promise<boolean> {
  try {
    return (await $.process.run(['kill', '-0', String(pid)])).exitCode === 0
  } catch (err) {
    finishProblem($, `cannot tell whether /finish is still running: ${String(err instanceof Error ? err.message : err)}`)
    return false
  }
}

function finishProblem($: EngineInterface, text: string) {
  if (finishProblemShown) return
  finishProblemShown = true
  $.ui.toast(`cs: ${text}`)
}

// The time since a gate started, as the band shows it: 42s, 1m 05s.
export function gateElapsed(secs: number): string {
  if (secs < 60) return `${secs}s`
  return `${Math.floor(secs / 60)}m ${String(secs % 60).padStart(2, '0')}s`
}

// The gate band under what the engine drew, while a /finish gate runs; the
// drawing itself, untouched, at any other time. It draws mid-turn, since the
// gate runs inside one, on the status bar's capsule fill as the rotation band.
async function withGateBand($: EngineInterface, e: Parameters<EngineInterface['ui']['resolve']>[0], drawn: unknown) {
  if (finishGate === undefined) return drawn
  const { Box, Text } = await $.ui.resolve(e)
  const fill = surfaceColor(await $.env.get("CS_TERM_BG_RGB"))
  const secs = Math.max(0, Math.floor((await $.clock.now()) / 1000) - finishGate.since)
  return (
    <Box flexDirection="column">
      {drawn}
      <Box marginTop={1}>
        <Box paddingX={1} backgroundColor={fill}>
          <Text>{`finishing ${cutTask(finishGate.task)} · gate ${gateElapsed(secs)}`}</Text>
        </Box>
      </Box>
    </Box>
  )
}
