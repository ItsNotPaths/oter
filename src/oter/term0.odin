package oter

// (hole term0 :tags term :sev gap) no hidden shell; nothing spawns it or draws it in the drawer.
term0_start :: proc(a: ^App) -> bool {
    return false
}

// (hole edit :tags term :sev gap :needs (drawer drawer-auto)) `:edit` does not open $EDITOR on the cursor item in term0.
edit_cursor_item :: proc(a: ^App) -> bool {
    return false
}
