<!-- (swiss :tags (files input ui term config deps pick theme preview) :sev (blocker gap polish)) -->

# oter

The scaffold (design step 1) is a sketch. Rewrite any of it when a hole needs a different
shape. There is no MVP target: `blocker` = the core loop of mark and send, `gap` = a
feature, `polish` = a small chore.

## Roadmap

Strict order: always work on the lowest unfinished milestone. A new idea goes to M5 unless
it blocks the current one. Each milestone ends in something you can try. The workstreams
below hold the decisions; this is the route through them.

### M1: it copies (done)

`marks`, `status-line`, `ghost-rows`, `job-wake`, then `send-to-pane`.
Done: mark three files with `y`, `shift+→`, see them land, read `copied 3 → …`.

### M2: it has a command line (done)

`cl-input` (`alt+;`), the chain running builtins (`:sel`, `:copy @-1`, `:move @+1`; `send-to-pane`
becomes a bind line), then `binds` from `binds.conf`. A shell step inside a pipe is a filter:
`sh -c` in the pane's dir, feed on stdin (via a temp file), stdout passed on. On its own it is
term0's (M3).
Done: `:sel | grep jpg | :copy @+1` works, and a key rebinds in `binds.conf`.

Binds: `binds.conf` in the config dir (see Config, M4), written from `DEFAULT_BINDS` on first
start when installed. Sections `[global]`, `[panes]`, `[sidebar]`; the sidebar has no pane rows, so it
swallows pane keys (Esc leaves it). A row replaces the default for its chord, `none` unbinds, a bad row is
reported in the status line with its line number and the rest still lands.

### M3: it has a shell (done)

term0 runs every shell step that is not inside a pipe: ` cd -- <pane dir>; <line> ;__oter <id> $?`,
the exit code back through oket's exit OSC. The chain waits on it, then the status line gets the
step's last output line (red on failure) and the pane follows the shell's dir. `e` is a plain
bind, `${EDITOR:-vi} $o_src`: the editor is a TUI, so the tray goes full and keys go to it.
Done: `git status` puts its last line in the status line; `hx file` goes full and comes back.


### M4: daily driver

`places` + `sidebar-keys` + `config` + delete / rename / mkdir (done).

Marks (yanks) belong to the pane as a list of full paths, so they survive a folder change.
`space` toggles, held with up/down it paints the state it set (repeats ignored), `esc` drops all,
`shift+esc` (`:unmark $o_dir`) only the folder's. The header shows `N yanked · M here`. A re-list
drops marks on gone paths. Delete / rename / mkdir are binds to `:stage` (oket's name; `:line`
is gone): `del` stages `:sel | xargs -d '\n' rm -rf --`, `alt+r` `mv -- $o_name`, `alt+n`
`mkdir --`. No trailing space survives a bind; you type it (an oket fix, then free here).

Config: `config.conf` beside `binds.conf`, same row reader (`conf_rows`). `[launch] panes` (panes
open at launch; `:np` adds more), `[theme] name` (helix TOML from `themes/` in the config dir,
gruvbox baked), `[copy]` / `[move]` `line` lists (a list in the file replaces the default whole).
Home: a binary in a `bin` dir is installed and uses `~/.config/oter`; anywhere else it is portable,
reads config beside itself and never writes defaults on start. `:oter status|install|uninstall`
runs the binary's own `--status|--install|--uninstall` in term0; `update` runs `install.sh`.
Install replaces the binary, `binds.conf`, `config.conf` and the launcher entry; uninstall takes
the binary, the entry and the whole config dir. No icon yet.

Places: `~/.config/oter/places`, one line per place, numbered `01` in the sidebar. A line that is
not a dir shows dimmed, which is all a separator (`=-= name =-=`) is. No text editor, and no
`$EDITOR`. Slots, not a list: line N is slot N, a blank line an empty slot, and every slot that
fits is shown, so numbers never shift. The cursor edits them with `:place cur|move|set|clear`,
each writing the file. `a` puts the pane's dir in the slot (`:place set $o_dir`), `s` a
separator, `d` empties it.
`:open <dir> [@N]` is oket's `:open` with panes only: enter opens in the pane you came from,
digit N in pane N. Builtins get `$o_` vars filled, as shell steps do.

### M5: later, no fixed order

`mouse` (parked: not worth the code before release), `:np` (new pane at the focused pane's dir)
and N panes (layout already takes any count), font zoom (`:font.bigger|smaller|reset` (oket's names) on ctrl+= / ctrl+- / ctrl+0, oket's `fonts.odin` over
`gfx.atlas_resize`; keep the px `face_stack_load` returns), `rsync-progress`, `hatchzip-ffi` (done: browse,
copy out, threaded listing), `archive-password` (asked in the tray term, not the CL), `file-dialog`
(Workstream P), image preview (done; `preview-archive` left), theming (Workstream T), clipboard.
`multiline-prompt` is dropped. Ghostty core comes after `mouse`, which comes after release.

## Workstream U: UI layout

`frame_fit` (`src/oter/layout.odin`) turns the window into pixel rects, oket's flat frame.
Left to right and top down: places sidebar, the pane strip, the term0 drawer, the CL bar.
Each region is its own grid drawn at its rect, with a 4px gap and a 1px rim per region, so
two rims make the double line between regions. `oket:strip` gives pane slots (`slot`) and
slides (`approach`, on the clock); the loop waits with a timeout only while something
moves. The skeleton draws empty boxes; holes fill them.

Decisions:
- The drawer has three states: closed, open (a third of the rows above the CL, at least 3)
  and full (every row above the CL). Full means exactly "term0 is on the alt screen"
  (`pty`'s `on_altscreen`): hx, nvim, less and htop switch to it, `make` and `rsync` never
  do, so no list of programs is needed. Leaving the alt screen drops back to open. The panes shrink above it rather than
  being covered, so the cursor never hides under it.
- The sidebar is always shown, a fixed column on the left (24 cols, at most a third of the
  window). Tab only moves focus into it and back to the pane you came from.
- The CL row is the last row, always, drawn as a bar. Status text and typing share it.
- `alt+up` raises the drawer, `alt+down` or Esc lowers it. Never full by hand. Otherwise the
  CL stays a single-line bar.
- While the sidebar has focus it takes every key; nothing reaches the pane behind it.

<!-- (skeleton :tags (ui term)) -->

_No holes match this query._

<!-- /skeleton -->

## Workstream F: mark and send

The core: split panes, mark on one side, send to the other.

Order: see M1.

Decisions:
- Safety and edge cases come before progress bars. Each op is a list of plain sh lines,
  best first (`fsop.COPY_LINES`: rsync, then `cp -aT`; `fsop.MOVE_LINES`: `mv -T`, a
  rename on one disk). All use skip-existing flags.
- The first line whose program (first word) is on PATH runs. Fallback is the list, not
  `||`, so `||` inside a line keeps its bash meaning. `config.conf` overrides the lists.
- The vendored oket is patched (`patches/oket-oter-vars.patch`) so `$o_` vars are oter's:
  `$o_src`, `$o_dir`, `$o_dst`.
- File ops run on a worker thread (`fsop.start`). The main thread only reads `Item.done`
  and `Job.finished`.
- On send, each item shows at once in the target dir as a greyed row. It turns into an
  ordinary row when its command exits; with rsync it can fill by bytes (`rsync-progress`).
  A dir is one row.
- The worker wakes the main loop (an SDL event, as `pty.wake_hook` does) when an item or the
  job ends, so rows update with no polling.
- A name clash skips the item, drops its ghost row and counts it. No overwrite prompt yet.
- The first failing item stops the job; its stderr is `Job.err`.
- When a job finishes, both panes re-list, cursor kept by name.
- `status-line` shows the finished result or error: `copied 3, skipped 1 → ~/Pictures`.
- On a move, the source row stays normal while in flight; it is complete until deleted.

`fsop` lives in `src/fsop`, so tests drive them on temp dirs without a window.

Likely next: delete, rename, mkdir. No stubs yet.


## Workstream I: input and CL

CL typing, then binds as CL strings through
oket's `cl/` and `input/bind.odin`.

Oket news: bind rows now hold a command line (`Bind.line`) and sections are opaque, so the
"make it generic in oket first" note in the design is done. Held chords (`tab+…`) are gone
from oket, so "hold Tab + digit" for places needs its own key-held tracking or a new key.

Decisions:
- Anything in the CL that is not a builtin is shell, run in a hidden long-lived terminal,
  term0, as oket does: the user's rc, aliases and env apply. Each step first `cd`s to the
  focused pane's dir; after it, the pane moves to term0's cwd (`pty.terminal_cwd`), so `cd`
  typed in the CL moves the pane. No `:cd` builtin.
- term0 lives in a drawer that slides up from the CL row over the bottom of the panes, so the
  dirs stay in view. Not a pane in the strip.
- Four states. Panes: no mode. CL (tray down; `alt+c` empty, `alt+;` with `:`): the single
  line, a no-feedback injector into term0. Tray up (`alt+up`, from the panes or the CL): a
  full normal terminal, just short; half-typed shell text from the CL carries into its prompt.
  Full: the tray while term0 is on the alt screen (a TUI), back to what it was after.
- Panes is the hub, a 0-depth web: the sidebar (Tab) and the CL open only from the panes
  and close back to them; Tab does nothing from the CL or the tray. CL > tray > full is one
  contained offshoot that only steps forward (CL can go straight to full by running a TUI).
  Full goes back to where it came from: the tray, or the panes if it came from the CL.
- Leaving: Esc or Enter closes the CL; `alt+down` or Esc closes the open tray. In full, Esc
  is the TUI's. A shell that dies closes the tray. Pulling the tray up `cd`s the shell to the pane's dir; letting it down
  moves the pane to the shell's dir.
- term0 takes the keys exactly while the tray is up (alt chords stay oter's binds).
- A shell step's last output line goes to the status line; a failure shows `exit N: …` in red.
  term0 is sized as the open tray even while shut, so output wraps where it is read.
- A shell that exited is respawned by the next shell step.
- Copy and move never go through term0; they stay on the `fsop` worker.
- term0 reuses oket's `pty`, with libvterm vendored (oket's build step and patch). oter sets
  `pty.wake_hook` to push an SDL event; no lues.
- Copy and move are CL sinks fed by `:sel`: `shift+left = :sel | :copy @-1`,
  `ctrl+right = :sel | :move @+1`. Shell filters can sit between: `:sel | grep jpg | :copy @+1`.
  `config.conf` keeps the `copy` / `move` line lists; the feed only says which items.
- `:sel` is the marked items, else the cursor item, newline-separated. A name with a newline
  in it is refused with a CL error that asks why the fuck you have that.
- Targets follow oket's pane model (niri-style strip): `@N` is pane N from the left, `@±N`
  steps from the focused one. No rings, so no `#N`. A bare path targets a dir. A target with
  no pane there does nothing. Parse with oket's `cl.target_parse`, resolve with
  `cl.target_index`; refuse `#N`, `@=` and `@*`.
- Until the chain runner lands, `send-to-pane` calls the proc `:copy` / `:move` will call, so
  the binds swap over without touching `fsop`.

<!-- (skeleton :tags input) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **mouse** · input · ready
  - [src/oter/input.odin:9](src/oter/input.odin#L9) · gap · no click, wheel or drag.

<!-- /skeleton -->

## Workstream P: file dialog

oter as the system's file dialog, through `xdg-desktop-portal-termfilechooser`. oter does no
D-Bus: the portal runs `oter-pick.sh multiple directory save path out`, which runs
`oter --pick` with the same five args, and oter writes the chosen paths to `out`.

Decisions:
- Two panes. Pane 0 is the pick pane (`pane.Pick`, a `Source` beside `Archive`); pane 1 is a
  normal pane at `path` (its dir in save mode). The pick pane's header says what was asked:
  `open a file`, `open files`, `pick a folder`, `save as`.
- The pick pane's rows are whole paths, what was thrown in. Nothing on disk is touched.
  `:copy` / `:move` into it add a row; single modes replace the one row. A file in folder mode
  or a folder in file mode is refused in the status line.
- Save starts with one row, the suggested `dir/name`. A folder thrown in keeps the name in that
  folder; a file thrown in replaces the row (overwrite). The folder is where the thrown thing
  came from, not read live from the right pane.
- Rename is the same `alt+r` bind (`:stage mv -- $o_name`). In the pick pane no shell runs: a
  lone `mv -- <old> <new>` renames the row's last part, a `/` in the new name is refused, and
  any other shell line is refused as in an archive.
- Out: `:copy` or `:move` from the pick pane to a normal pane drops the rows; `del` drops them too through
  a `[pick]` bind section, walked before `[panes]` while the pick pane has focus, shipping
  `del = :unpick`.
- `alt+enter` = `:stage :confirm`, then `enter`: the rows go to `out`, one path per line, and
  oter quits. Closing the window or `:quit` writes nothing: cancel.
- Windows open at a share of the primary display's usable area (oket's `window_size`): 0.9
  normally, `[launch] pick` (0.6) for `--pick`, whose app id is `oter-pick` for a WM rule.
- The pick pane cannot be closed, `:open`ed over or entered; `:np` from it is refused.
- `:oter install` puts `oter-pick.sh` beside the binary and prints the termfilechooser `config`
  and `portals.conf` lines; the user adds those.

<!-- (skeleton :tags pick) -->

_No holes match this query._

<!-- /skeleton -->

## Workstream L: later features

No code sites yet for clipboard `text/uri-list` and the clash prompt; each gets a stub when
its turn comes. Image preview is a toggle, not a held key: `:preview` on `w`. While on, the
picture under each pane's cursor opens in the list (design.md's rows rule), decoded with
stb_image on its own thread; a GIF plays and the loop sleeps until its next frame. Files
inside archives get none yet (`preview-archive`). The places sidebar has
its stub (`places`, Workstream U); hatchzip has its vendoring (`hatchzip-ffi`).

<!-- (skeleton :tags (config deps preview)) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **preview-archive** · preview · ready
  - [src/oter/preview.odin:137](src/oter/preview.odin#L137) · gap · no picture for a file inside an archive.

<!-- /skeleton -->

## Workstream T: themes

The format is settled: helix TOML, the same as oket (`theme.load`, `themes/<name>.toml` in the
config dir, gruvbox baked in). The open problem is the UX: how a person finds, tries and keeps
a theme. None ship, so where themes come from is part of it. Whatever lands here, oket gets
the same.

<!-- (skeleton :tags theme) -->

_2 holes, 2 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **theme-switch** · theme · ready
  - [src/oter/config.odin:110](src/oter/config.odin#L110) · gap · the theme loads once at start; no `:set theme.name` as in oket.
- **theme-pick** · theme · needs **theme-switch**
  - [src/oter/config.odin:111](src/oter/config.odin#L111) · gap · no way to list or try themes; only a name typed in config.conf.

<!-- /skeleton -->
