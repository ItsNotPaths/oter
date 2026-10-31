package tests

import "core:sys/posix"
import "core:testing"
import "core:time"
import "oket:pty"
import "oter:oter"
import "oter:pane"

// A 7z whose headers are encrypted: nothing lists without the password, `oter`.
@(private = "file")
DATA :: #directory + "data"

@(private = "file")
LOCKED :: DATA + "/locked.7z"

// Plain sh, no rc: the user's own shell config has no place in a test.
@(init)
password_test_shell :: proc "contextless" () {
    posix.setenv("SHELL", "/bin/sh", true)
}

// Pane 0 on the fixtures, cursor on locked.7z, term0 up.
@(private = "file")
locked_app :: proc(t: ^testing.T, a: ^oter.App) -> bool {
    p: pane.Pane
    pane.open(&p, DATA)
    for e, i in p.entries {
        if e.name == "locked.7z" {
            p.cursor = i
        }
    }
    append(&a.panes, p)
    oter.config_load(a)
    return testing.expect(t, oter.term0_start(a), "no shell")
}

@(private = "file")
teardown :: proc(a: ^oter.App) {
    pty.terminal_close(&a.term0)
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    delete(a.sends)
    delete(a.status)
    oter.archives_destroy(a)
    oter.config_destroy(&a.config)
}

// Pumps the app until `done` holds or 5s pass.
@(private = "file")
pump_until :: proc(a: ^oter.App, done: proc(a: ^oter.App) -> bool) -> bool {
    start := time.tick_now()
    for time.tick_since(start) < 5 * time.Second {
        oter.jobs_poll(a)
        oter.term0_pump(a)
        if done(a) {
            return true
        }
        time.sleep(time.Millisecond)
    }
    return false
}

@(private = "file")
asking :: proc(a: ^oter.App) -> bool {return a.ask != nil}

@(private = "file")
settled :: proc(a: ^oter.App) -> bool {return a.ask == nil && len(a.listings) == 0}

@(private = "file")
answer :: proc(a: ^oter.App, text: string) {
    pty.terminal_write(&a.term0, transmute([]u8)text)
}

@(test)
a_locked_archive_asks_in_the_tray_and_opens :: proc(t: ^testing.T) {
    a: oter.App
    defer teardown(&a)
    if !locked_app(t, &a) {
        return
    }

    oter.run_line(&a, ":enter")
    testing.expect(t, pump_until(&a, asking), "no question")
    testing.expect_value(t, a.mode, oter.Mode.Term)
    testing.expect_value(t, a.drawer, oter.Drawer.Open)

    answer(&a, "oter\n")
    testing.expect(t, pump_until(&a, settled), "the answer never landed")
    testing.expect_value(t, a.panes[0].dir, LOCKED)
    testing.expect_value(t, a.mode, oter.Mode.Panes)
    testing.expect_value(t, a.drawer, oter.Drawer.Closed)
}

@(test)
a_wrong_password_opens_nothing_and_says_so :: proc(t: ^testing.T) {
    a: oter.App
    defer teardown(&a)
    if !locked_app(t, &a) {
        return
    }

    oter.run_line(&a, ":enter")
    testing.expect(t, pump_until(&a, asking), "no question")
    answer(&a, "nope\n")
    testing.expect(t, pump_until(&a, settled), "the answer never landed")
    testing.expect_value(t, a.panes[0].dir, DATA)
    testing.expect(t, a.status_err)
}

@(test)
closing_the_tray_cancels_the_question :: proc(t: ^testing.T) {
    a: oter.App
    defer teardown(&a)
    if !locked_app(t, &a) {
        return
    }

    oter.run_line(&a, ":enter")
    testing.expect(t, pump_until(&a, asking), "no question")
    oter.tray_down(&a)
    testing.expect(t, pump_until(&a, settled), "the cancel never landed")
    testing.expect_value(t, a.panes[0].dir, DATA)
    testing.expect_value(t, a.drawer, oter.Drawer.Closed)

    oter.run_line(&a, "true") // the read is over: the shell takes steps again
    testing.expect(t, pump_until(&a, proc(a: ^oter.App) -> bool {return !a.chain.waiting}), "the step never ended")
    testing.expect(t, !a.status_err)
}
