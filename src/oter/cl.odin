package oter

import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// The one-line editor in the CL bar. `cursor` is a byte offset into `text`.
Cl :: struct {
    text:   [dynamic]u8,
    cursor: int,
}

cl_open :: proc(a: ^App, pre: string) {
    clear(&a.line.text)
    append(&a.line.text, pre)
    a.line.cursor = len(pre)
    mode_set(a, .Line)
}

// Typed text. Ignored under alt or ctrl, so the chord that opened the line does not land in it.
cl_text :: proc(a: ^App, text: cstring) {
    if sdl.GetModState() & (sdl.KMOD_ALT | sdl.KMOD_CTRL) != {} {
        return
    }
    s := string(text)
    inject_at(&a.line.text, a.line.cursor, ..transmute([]u8)s)
    a.line.cursor += len(s)
}

// Keys while the line is open. Every key is the line's; none reach the panes.
cl_key :: proc(a: ^App, k: sdl.Keycode) {
    c := &a.line
    switch k {
    case sdl.K_ESCAPE:
        mode_set(a, .Panes)
    case sdl.K_RETURN, sdl.K_KP_ENTER:
        line := strings.clone(string(c.text[:]), context.temp_allocator)
        mode_set(a, .Panes)
        run_line(a, line)
    case sdl.K_BACKSPACE:
        if c.cursor > 0 {
            _, n := utf8.decode_last_rune(c.text[:c.cursor])
            remove_range(&c.text, c.cursor - n, c.cursor)
            c.cursor -= n
        }
    case sdl.K_DELETE:
        if c.cursor < len(c.text) {
            _, n := utf8.decode_rune(c.text[c.cursor:])
            remove_range(&c.text, c.cursor, c.cursor + n)
        }
    case sdl.K_LEFT:
        if c.cursor > 0 {
            _, n := utf8.decode_last_rune(c.text[:c.cursor])
            c.cursor -= n
        }
    case sdl.K_RIGHT:
        if c.cursor < len(c.text) {
            _, n := utf8.decode_rune(c.text[c.cursor:])
            c.cursor += n
        }
    case sdl.K_HOME:
        c.cursor = 0
    case sdl.K_END:
        c.cursor = len(c.text)
    }
}
