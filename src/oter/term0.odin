package oter

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import "oket:cl"
import "oket:gfx"
import "oket:input"
import vt "oket:libvterm"
import "oket:pty"
import "../pane"

// Names the exit report once, so a step carries `;__oter <id> $?` and not the escape.
// Doubled braces: this goes through fmt.
@(private = "file")
SETUP :: " export GIT_PAGER=cat PAGER=cat; __oter(){{ printf '\\033]%d;%%s;%%s\\007' \"$1\" \"$2\"; }}\n"

// The hidden shell, started in the focused pane's dir. `a.term0` must not move once spawned.
term0_start :: proc(a: ^App) -> bool {
    pty.wake_hook = push_wake
    if !pty.terminal_spawn(&a.term0, 24, 80, a.panes[a.active].dir) {
        status_set(a, "term0: the shell did not start", true)
        return false
    }
    pty.terminal_set_default_colors(&a.term0, a.theme[.Fg], a.theme[.Bg])
    setup := fmt.tprintf(SETUP, pty.OSC_EXIT_TAG)
    pty.terminal_write(&a.term0, transmute([]u8)setup)
    return true
}

// Sends one shell step: in the pane's dir, reporting its exit code with `a.step_id`.
term0_run :: proc(a: ^App, cmd: string) -> bool {
    t := &a.term0
    if !pty.terminal_alive(t) {
        pty.terminal_close(t)
        t^ = {}
        if !term0_start(a) {
            return false
        }
    }
    a.step_id += 1
    t.exit_ready = false // a report still standing is an older step's
    dir := cl.sh_quote(a.panes[a.active].dir, context.temp_allocator)
    line := fmt.tprintf(" cd -- %s; %s ;__oter %d $?\n", dir, cmd, a.step_id) // leading space: kept out of history
    pty.terminal_write(t, transmute([]u8)line)
    return true
}

// Each frame: output into the vt, its size from the drawer at rest, full and focused while a
// TUI is up, and the waiting step's report back to the chain.
term0_pump :: proc(a: ^App) {
    t := &a.term0
    pty.terminal_drain(t)
    if !pty.terminal_alive(t) {
        if a.chain.waiting {
            status_set(a, "term0's shell exited mid-step", true)
            cl.reset(&a.chain)
        }
        term_focus(a, false)
        return
    }
    if t.on_altscreen && a.drawer != .Full {
        a.drawer_before, a.drawer = a.drawer, .Full
    } else if !t.on_altscreen && a.drawer == .Full {
        a.drawer = a.drawer_before
    }
    term_focus(a, a.drawer != .Closed)

    // Sized as the tray shows it even while shut, so output wraps where you will read it.
    cw, ch := gfx.painter_cell(&a.painter)
    if rows := int(drawer_height(a, a.drawer == .Full ? .Full : .Open)) / ch; rows > 0 && a.frame.win.x > 0 {
        pty.terminal_resize(t, rows, int(a.frame.win.x) / cw)
    }

    if !a.chain.waiting || !t.exit_ready || t.exit_id != a.step_id {
        return
    }
    t.exit_ready = false
    code := t.exit_code
    last := last_output_line(a)
    status_set(a, code == 0 ? last : fmt.tprintf("exit %d: %s", code, last), code != 0)
    p := &a.panes[a.active]
    if dir := pty.terminal_cwd(t); dir != "" && dir != p.dir {
        pane.open(p, dir)
    } else {
        pane.relist(p) // the step may have changed what is here
    }
    cl.job_done(&a.chain, code)
    chain_pump(a)
}

// The tray up is the terminal: half-typed CL text carries into its prompt, and the shell
// stands in the pane's dir.
tray_up :: proc(a: ^App) {
    if a.drawer != .Closed {
        return
    }
    t := &a.term0
    if !pty.terminal_alive(t) {
        pty.terminal_close(t)
        t^ = {}
        if !term0_start(a) {
            return
        }
    }
    if pty.terminal_at_prompt(t) {
        if dir := a.panes[a.active].dir; pty.terminal_cwd(t) != dir {
            line := fmt.tprintf(" cd -- %s\n", cl.sh_quote(dir, context.temp_allocator))
            pty.terminal_write(t, transmute([]u8)line)
        }
        if a.line.on && !strings.has_prefix(string(a.line.text[:]), ":") {
            pty.terminal_write(t, a.line.text[:])
        }
    }
    if a.line.on {
        cl_close(a)
    }
    a.drawer = .Open
}

// The tray down leaves the mode: no CL, no term, and the pane follows the shell's dir.
tray_down :: proc(a: ^App) {
    if a.line.on {
        cl_close(a)
    }
    if a.drawer != .Open { // full belongs to the TUI
        return
    }
    a.drawer = .Closed
    p := &a.panes[a.active]
    if dir := pty.terminal_cwd(&a.term0); dir != "" && dir != p.dir {
        pane.open(p, dir)
    }
}

// term0 takes the keys exactly while the tray is up.
@(private = "file")
term_focus :: proc(a: ^App, on: bool) {
    if on == a.in_term {
        return
    }
    a.in_term = on
    _ = on ? sdl.StartTextInput(a.window) : sdl.StopTextInput(a.window)
}

// The last non-blank row between the step's echoed line and the prompt now under the cursor.
// (hole multiline-prompt :tags term :sev polish) a two-line prompt's first line is taken for output.
@(private = "file")
last_output_line :: proc(a: ^App) -> string {
    t := &a.term0
    crow, _ := pty.terminal_cursor(t)
    tag := fmt.tprintf("__oter %d", a.step_id)
    for row := crow - 1; row >= 0; row -= 1 {
        b := strings.builder_make(context.temp_allocator)
        for col in 0 ..< t.cols {
            r := pty.terminal_cell_rune(t, row, col)
            strings.write_rune(&b, r == 0 ? ' ' : r)
        }
        text := strings.trim_space(strings.to_string(b))
        if strings.contains(text, tag) {
            return "" // reached the echo: the step printed nothing
        }
        if text != "" {
            return text
        }
    }
    return ""
}

// A key while term0 has focus: alt chords stay oter's binds, everything else is the shell's.
term_key :: proc(a: ^App, ev: sdl.KeyboardEvent) {
    code := input.Code(ev.scancode)
    mods := mods_of(ev.mod)
    if input.code_is_modifier(code) {
        return
    }
    if .Alt in mods {
        bind_run(a, ev)
        return
    }
    if a.drawer == .Open && code == input.Code(sdl.Scancode.ESCAPE) { // full: Esc is the TUI's
        tray_down(a)
        return
    }
    key: vt.Key
    switch input.key_name(code) {
    case "RTRN", "KPEN":
        key = .Enter
    case "TAB":
        key = .Tab
    case "BKSP":
        key = .Backspace
    case "ESC":
        key = .Escape
    case "UP":
        key = .Up
    case "DOWN":
        key = .Down
    case "LEFT":
        key = .Left
    case "RGHT":
        key = .Right
    case "HOME":
        key = .Home
    case "END":
        key = .End
    case "INS":
        key = .Ins
    case "DELE":
        key = .Del
    case "PGUP":
        key = .PageUp
    case "PGDN":
        key = .PageDown
    case:
        // Ctrl+letter follows the layout's letter; a printable arrives as TEXT_INPUT.
        if mods == {.Ctrl} || mods == {.Ctrl, .Shift} {
            if l := layout_name(code); len(l) == 1 && l[0] >= 'a' && l[0] <= 'z' {
                pty.terminal_input_ctrl(&a.term0, rune(l[0]))
            }
        }
        return
    }
    m: vt.Modifier
    if .Shift in mods {
        m |= vt.MOD_SHIFT
    }
    if .Ctrl in mods {
        m |= vt.MOD_CTRL
    }
    pty.terminal_input_key(&a.term0, key, m)
}

term_text :: proc(a: ^App, text: cstring) {
    if sdl.GetModState() & (sdl.KMOD_ALT | sdl.KMOD_CTRL) != {} {
        return
    }
    for r in string(text) {
        pty.terminal_input_rune(&a.term0, r)
    }
}

// term0's cells, its bottom row on the region's bottom row, so a slide shows the prompt first.
draw_term :: proc(a: ^App, r: ^Region) {
    th := a.theme
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], gfx.opaque(th[.Bg]))
    t := &a.term0
    if !pty.terminal_alive(t) {
        cols, _ := region_cells(a, r)
        write_clipped(g, 0, 0, cols, "term0: no shell; the next shell line starts one", th[.Dim], gfx.opaque(th[.Bg]), {})
        return
    }
    _, rows := region_cells(a, r)
    top := t.rows - rows // vt rows above the region
    crow, ccol := pty.terminal_cursor(t)
    for row in max(top, 0) ..< t.rows {
        for col in 0 ..< t.cols {
            cell := pty.terminal_cell(t, row, col) or_continue
            fg, fdef := pty.terminal_color(t, cell.fg)
            bg, bdef := pty.terminal_color(t, cell.bg)
            if fdef {
                fg = th[.Fg]
            }
            if bdef {
                bg = th[.Bg]
            }
            if cell.attrs.reverse != (a.in_term && row == crow && col == ccol) {
                fg, bg = bg, fg
            }
            attrs: gfx.Attrs
            if cell.attrs.bold {
                attrs += {.Bold}
            }
            if cell.attrs.italic {
                attrs += {.Italic}
            }
            if cell.attrs.underline != 0 {
                attrs += {.Underline}
            }
            ch := rune(cell.chars[0])
            if ch == 0 {
                ch = ' '
            }
            gfx.grid_put(g, col, row - top, gfx.Cell{ch, fg, gfx.opaque(bg), attrs, 0})
        }
    }
}

