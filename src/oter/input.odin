package oter

import sdl "vendor:sdl3"

handle :: proc(a: ^App, ev: sdl.Event) {
    // (hole mouse :tags input :sev gap) no click, wheel or drag.
    #partial switch ev.type {
    case .QUIT:
        a.running = false
    case .KEY_DOWN:
        if a.in_term {
            term_key(a, ev.key)
        } else if a.line.on {
            if ev.key.mod & sdl.KMOD_ALT != {} {
                bind_run(a, ev.key) // alt+up / alt+down work from the line too
            } else {
                cl_key(a, ev.key.key)
            }
        } else {
            bind_run(a, ev.key)
        }
    case .TEXT_INPUT:
        if a.in_term {
            term_text(a, ev.text.text)
        } else {
            cl_text(a, ev.text.text)
        }
    }
}
