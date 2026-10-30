package oter

import sdl "vendor:sdl3"
import "../pane"

handle :: proc(a: ^App, ev: sdl.Event) {
    // (hole mouse :tags input :sev gap :needs send-to-pane) no click, wheel or drag.
    #partial switch ev.type {
    case .QUIT:
        a.running = false
    case .KEY_DOWN:
        key(a, ev.key.key, ev.key.mod)
    }
}

// (hole binds :tags input :sev gap :needs cl-input) keys are hard-coded, not CL strings from binds.conf.
key :: proc(a: ^App, k: sdl.Keycode, mod: sdl.Keymod) {
    alt := mod & sdl.KMOD_ALT != {}
    shift := mod & sdl.KMOD_SHIFT != {}
    ctrl := mod & sdl.KMOD_CTRL != {}
    p := &a.panes[a.active]
    page := max(list_rows(a) - 1, 1)

    switch {
    case ctrl && k == sdl.K_Q:
        a.running = false
    case alt && k == sdl.K_UP && a.drawer == .Closed: // only a TUI makes it full
        a.drawer = .Open
    case (alt && k == sdl.K_DOWN || k == sdl.K_ESCAPE) && a.drawer == .Open: // full belongs to the TUI
        a.drawer = .Closed
    case k == sdl.K_TAB:
        a.in_sidebar = !a.in_sidebar
    // (hole sidebar-keys :tags (ui input) :sev gap :needs places) the sidebar swallows keys; no cursor, no enter.
    case a.in_sidebar:
    case alt && shift && k == sdl.K_LEFT:
        swap_pane(a, -1)
    case alt && shift && k == sdl.K_RIGHT:
        swap_pane(a, +1)
    case alt && k == sdl.K_LEFT:
        a.active = max(a.active - 1, 0)
    case alt && k == sdl.K_RIGHT:
        a.active = min(a.active + 1, len(a.panes) - 1)
    case alt || ctrl || shift:
        // (hole send-to-pane :tags (files input) :sev blocker :needs (marks ghost-rows status-line job-wake)) shift/ctrl+arrows do nothing.
    case k == sdl.K_UP:
        pane.move(p, -1)
    case k == sdl.K_DOWN:
        pane.move(p, +1)
    case k == sdl.K_PAGEUP:
        pane.move(p, -page)
    case k == sdl.K_PAGEDOWN:
        pane.move(p, +page)
    case k == sdl.K_HOME:
        pane.move(p, -len(p.entries))
    case k == sdl.K_END:
        pane.move(p, +len(p.entries))
    case k == sdl.K_RETURN || k == sdl.K_RIGHT:
        pane.enter(p)
    case k == sdl.K_BACKSPACE || k == sdl.K_LEFT:
        pane.up(p)
    }
}

// Moves the active pane one slot left or right; focus follows it.
swap_pane :: proc(a: ^App, dir: int) {
    to := a.active + dir
    if to < 0 || to >= len(a.panes) {
        return
    }
    a.panes[a.active], a.panes[to] = a.panes[to], a.panes[a.active]
    a.active = to
}
