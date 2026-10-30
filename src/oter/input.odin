package oter

import "core:fmt"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import "oket:input"

handle :: proc(a: ^App, ev: sdl.Event) {
    // (hole mouse :tags input :sev gap) no click, wheel or drag.
    #partial switch ev.type {
    case .QUIT:
        a.running = false
    case .KEY_DOWN:
        switch a.mode {
        case .Term:
            term_key(a, ev.key)
        case .Line:
            if ev.key.mod & sdl.KMOD_ALT != {} {
                bind_run(a, ev.key) // alt+up lifts the tray from the line
            } else {
                cl_key(a, ev.key.key)
            }
        case .Panes, .Sidebar:
            bind_run(a, ev.key)
        }
    case .TEXT_INPUT:
        #partial switch a.mode {
        case .Term:
            term_text(a, ev.text.text)
        case .Line:
            cl_text(a, ev.text.text)
        }
    }
}

// Line and Term take typed text.
mode_set :: proc(a: ^App, m: Mode) {
    typed :: proc(m: Mode) -> bool {return m == .Line || m == .Term}
    if typed(m) != typed(a.mode) {
        _ = typed(m) ? sdl.StartTextInput(a.window) : sdl.StopTextInput(a.window)
    }
    a.mode = m
}

mods_of :: proc(mod: sdl.Keymod) -> (m: input.Mods) {
    if mod & sdl.KMOD_SHIFT != {} {
        m += {.Shift}
    }
    if mod & sdl.KMOD_CTRL != {} {
        m += {.Ctrl}
    }
    if mod & sdl.KMOD_ALT != {} {
        m += {.Alt}
    }
    if mod & sdl.KMOD_GUI != {} {
        m += {.Super}
    }
    return
}

SCANCODE_COUNT :: 512

// The position that types `name` under the current layout (oket's input.odin).
key_layout_code :: proc(name: string) -> (input.Code, bool) {
    if name == "" {
        return 0, false
    }
    for sc in 1 ..< SCANCODE_COUNT {
        if layout_name(input.Code(sc)) == name {
            return input.Code(sc), true
        }
    }
    return 0, false
}

// What a position types under the current layout, "" for keys that type nothing.
layout_name :: proc(code: input.Code) -> string {
    if code == 0 || int(code) >= SCANCODE_COUNT {
        return ""
    }
    key := u32(sdl.GetKeyFromScancode(sdl.Scancode(code), sdl.KMOD_NONE, false))
    if key <= ' ' || key == 0x7f || key >= u32(sdl.K_EXTENDED_MASK) {
        return ""
    }
    buf, n := utf8.encode_rune(rune(key))
    return fmt.tprint(string(buf[:n]))
}
