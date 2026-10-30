package oter

import "core:strings"

// Replaces the CL bar's text.
status_set :: proc(a: ^App, text: string, err := false) {
    delete(a.status)
    a.status = strings.clone(text)
    a.status_err = err
}
