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
    if !term0_ensure(a) {
        return false
    }
    t := &a.term0
    a.step_id += 1
    t.exit_ready = false // a report still standing is an older step's
    dir := cl.sh_quote(a.panes[a.active].dir, context.temp_allocator)
    line := fmt.tprintf(" cd -- %s; %s ;__oter %d $?\n", dir, cmd, a.step_id) // leading space: kept out of history
    pty.terminal_write(t, transmute([]u8)line)
    return true
}

// A dead shell is replaced by a fresh one.
@(private = "file")
term0_ensure :: proc(a: ^App) -> bool {
    t := &a.term0
    if pty.terminal_alive(t) {
        return true
    }
    pty.terminal_close(t)
    t^ = {}
    return term0_start(a)
}

// The active pane moves to the shell's dir. False if it was already there.
@(private = "file")
pane_follow_shell :: proc(a: ^App) -> bool {
    p := &a.panes[a.active]
    dir := pty.terminal_cwd(&a.term0)
    if dir == "" || dir == p.dir {
        return false
    }
    pane.open(p, dir)
    return true
}

// Each frame: drain output, size the vt, track a TUI, and report the waiting step.
term0_pump :: proc(a: ^App) {
    t := &a.term0
    pty.terminal_drain(t)
    if !pty.terminal_alive(t) {
        if a.chain.waiting {
            status_set(a, "term0's shell exited mid-step", true)
            cl.reset(&a.chain)
        }
        if a.mode == .Term {
            mode_set(a, .Panes)
        }
        a.drawer = .Closed
        return
    }
    if t.on_altscreen && a.drawer != .Full {
        a.drawer_before, a.drawer = a.drawer, .Full
        mode_set(a, .Term)
    } else if !t.on_altscreen && a.drawer == .Full {
        a.drawer = a.drawer_before
        mode_set(a, a.drawer == .Open ? .Term : .Panes)
    }

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
    if !pane_follow_shell(a) {
        pane.relist(&a.panes[a.active]) // the step may have changed what is here
    }
    cl.job_done(&a.chain, code)
    chain_pump(a)
}

// The tray up is the terminal: half-typed CL text goes to its prompt, in the pane's dir.
tray_up :: proc(a: ^App) {
    if (a.mode != .Panes && a.mode != .Line) || !term0_ensure(a) {
        return
    }
    t := &a.term0
    if pty.terminal_at_prompt(t) {
        if dir := a.panes[a.active].dir; pty.terminal_cwd(t) != dir {
            line := fmt.tprintf(" cd -- %s\n", cl.sh_quote(dir, context.temp_allocator))
            pty.terminal_write(t, transmute([]u8)line)
        }
        if a.mode == .Line && !strings.has_prefix(string(a.line.text[:]), ":") {
            pty.terminal_write(t, a.line.text[:])
        }
    }
    mode_set(a, .Term)
    a.drawer = .Open
}

// Back to the panes, which follow the shell's dir.
tray_down :: proc(a: ^App) {
    if a.drawer != .Open { // full belongs to the TUI
        return
    }
    a.drawer = .Closed
    mode_set(a, .Panes)
    pane_follow_shell(a)
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
    key, named := vt_key(code)
    if !named {
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

@(private = "file")
vt_key :: proc(code: input.Code) -> (vt.Key, bool) {
    switch input.key_name(code) {
    case "RTRN", "KPEN": return .Enter, true
    case "TAB":          return .Tab, true
    case "BKSP":         return .Backspace, true
    case "ESC":          return .Escape, true
    case "UP":           return .Up, true
    case "DOWN":         return .Down, true
    case "LEFT":         return .Left, true
    case "RGHT":         return .Right, true
    case "HOME":         return .Home, true
    case "END":          return .End, true
    case "INS":          return .Ins, true
    case "DELE":         return .Del, true
    case "PGUP":         return .PageUp, true
    case "PGDN":         return .PageDown, true
    }
    return {}, false
}

term_text :: proc(a: ^App, text: cstring) {
    if sdl.GetModState() & (sdl.KMOD_ALT | sdl.KMOD_CTRL) != {} {
        return
    }
    for r in string(text) {
        pty.terminal_input_rune(&a.term0, r)
    }
}
