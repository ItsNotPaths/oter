package oter

import sdl "vendor:sdl3"
import "../pane"

handle :: proc(a: ^App, ev: sdl.Event) {
    #partial switch ev.type {
    case .QUIT:
        a.running = false
    case .KEY_DOWN:
        key(a, ev.key.key, ev.key.mod)
    }
}

key :: proc(a: ^App, k: sdl.Keycode, mod: sdl.Keymod) {
    alt := mod & sdl.KMOD_ALT != {}
    shift := mod & sdl.KMOD_SHIFT != {}
    ctrl := mod & sdl.KMOD_CTRL != {}
    p := &a.panes[a.active]
    page := max(list_rows(a) - 1, 1)

    switch {
    case ctrl && k == sdl.K_Q:
        a.running = false
    case alt && shift && k == sdl.K_LEFT:
        swap_pane(a, -1)
    case alt && shift && k == sdl.K_RIGHT:
        swap_pane(a, +1)
    case alt && k == sdl.K_LEFT:
        a.active = max(a.active - 1, 0)
    case alt && k == sdl.K_RIGHT:
        a.active = min(a.active + 1, len(a.panes) - 1)
    case alt || ctrl || shift:
        // copy/move go here
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
