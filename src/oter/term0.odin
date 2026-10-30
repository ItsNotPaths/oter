package oter

import "core:fmt"
import sdl "vendor:sdl3"
import "oket:cl"
import "oket:gfx"
import "oket:input"
import vt "oket:libvterm"
import "oket:pty"
import "../pane"

// The hidden shell, started in the focused pane's dir. `a.term0` must not move once spawned.
term0_start :: proc(a: ^App) -> bool {
    pty.wake_hook = push_wake
    if !pty.terminal_spawn(&a.term0, 24, 80, a.panes[a.active].dir) {
        status_set(a, "term0: the shell did not start", true)
        return false
    }
    pty.terminal_set_default_colors(&a.term0, a.theme[.Fg], a.theme[.Bg])
    return true
}

// Each frame: output into the vt, the size of the drawer at rest, full while a TUI is up.
term0_pump :: proc(a: ^App) {
    t := &a.term0
    pty.terminal_drain(t)
    if !pty.terminal_alive(t) {
        if a.in_term {
            term_leave(a)
        }
        return
    }
    switch {
    case t.on_altscreen:
        a.drawer = .Full
    case a.drawer == .Full:
        a.drawer = .Open
    }
    cw, ch := gfx.painter_cell(&a.painter)
    rows := int(drawer_dest(a) + term_extra(a)) / ch
    if rows > 0 && a.frame.win.x > 0 {
        pty.terminal_resize(t, rows, int(a.frame.win.x) / cw)
    }
}

// Rows the term gains over the drawer when focused: it takes the CL row.
term_extra :: proc(a: ^App) -> f32 {
    _, ch := gfx.painter_cell(&a.painter)
    return a.in_term ? f32(ch) + GAP : 0
}

// `:term`: open the drawer and send keys to the shell, standing in the pane's dir.
term_enter :: proc(a: ^App) {
    t := &a.term0
    if !pty.terminal_alive(t) {
        pty.terminal_close(t)
        t^ = {}
        if !term0_start(a) {
            return
        }
    }
    dir := a.panes[a.active].dir
    if pty.terminal_cwd(t) != dir && pty.terminal_at_prompt(t) {
        line := fmt.tprintf(" cd -- %s\n", cl.sh_quote(dir, context.temp_allocator)) // leading space: kept out of history
        pty.terminal_write(t, transmute([]u8)line)
    }
    if a.drawer == .Closed {
        a.drawer = .Open
    }
    a.in_term = true
    _ = sdl.StartTextInput(a.window)
}

// Back to the panes; the focused pane follows the shell's dir.
term_leave :: proc(a: ^App) {
    a.in_term = false
    _ = sdl.StopTextInput(a.window)
    p := &a.panes[a.active]
    if dir := pty.terminal_cwd(&a.term0); dir != "" && dir != p.dir {
        pane.open(p, dir)
    }
}

// A key while focused: alt chords stay oter's binds, everything else is the shell's.
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
        write_clipped(g, 0, 0, cols, "term0: no shell; alt+c starts one", th[.Dim], gfx.opaque(th[.Bg]), {})
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

// (hole edit :tags term :sev gap :needs (drawer-auto cl-shell)) `:edit` does not open $EDITOR on the cursor item in term0.
edit_cursor_item :: proc(a: ^App) -> bool {
    return false
}
