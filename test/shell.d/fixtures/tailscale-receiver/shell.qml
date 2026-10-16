import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "tailscale" as Tailscale

// Drives the real Tailscale panel and service against the stub `systemctl`,
// `which`, and `tailscale` the runner puts on PATH. Automated runs are
// offscreen and never open the panel, and every command lands in the stub log.
ShellRoot {
  id: test

  property bool failed: false
  property string stateDir: Quickshell.env("TS_TEST_STATE")
  property string logPath: Quickshell.env("TS_TEST_LOG")
  property var waiting: null
  property int stepIndex: 0

  readonly property var svc: panel.testService
  readonly property var keys: panel.testKeys
  readonly property var row: panel.testReceiverRow
  readonly property var separator: panel.testReceiverSeparator
  readonly property var receiverSwitch: panel.testReceiverSwitch
  readonly property var flick: panel.testFlick

  readonly property string enableLine: "--user enable --now omarchy-tailscale-receive.service"
  readonly property string disableLine: "--user disable --now omarchy-tailscale-receive.service"
  readonly property string statusLine: "--user is-active omarchy-tailscale-receive.service"

  function check(ok, message) {
    if (ok) return
    failed = true
    console.log("RESULT fail " + message)
  }

  function log() {
    var request = new XMLHttpRequest()
    request.open("GET", "file://" + logPath, false)
    request.send(null)
    var text = String(request.responseText || "")
    return text === "" ? [] : text.replace(/\n$/, "").split("\n")
  }

  function count(line) {
    return log().filter(function(entry) { return entry === "systemctl " + line }).length
  }

  function lastSystemctl() {
    var lines = log().filter(function(entry) { return entry.indexOf("systemctl ") === 0 })
    return lines.length > 0 ? lines[lines.length - 1] : ""
  }

  function idle() {
    return !svc.busy && !svc.receiverBusy && !svc._receiverConfirming
  }

  function waitFor(label, predicate, next) {
    waiting = { label: label, predicate: predicate, next: next, deadline: Date.now() + 8000 }
  }

  function setState(script, next) {
    stateProcess.next = next
    stateProcess.command = ["bash", "-c", "cd \"$TS_TEST_STATE\" && " + script]
    stateProcess.running = true
  }

  function move(dy) {
    panel.cursorActive = true
    keys.moveRequested(0, dy)
  }

  function focus(section) {
    panel.cursorActive = true
    panel.focusSection = section
  }

  function finish() {
    if (!failed) console.log("RESULT pass")
    Qt.quit()
  }

  function nextStep() {
    if (failed) { finish(); return }
    var step = steps[stepIndex++]
    if (!step) { finish(); return }
    step()
  }

  Process {
    id: stateProcess
    property var next: null
    onExited: function(exitCode) {
      test.check(exitCode === 0, "fixture state change succeeds")
      var next = stateProcess.next
      stateProcess.next = null
      if (next) next()
    }
  }

  Timer {
    interval: 20
    repeat: true
    running: test.waiting !== null
    onTriggered: {
      var pending = test.waiting
      if (pending.predicate()) {
        test.waiting = null
        pending.next()
      } else if (Date.now() > pending.deadline) {
        test.waiting = null
        test.check(false, "timed out waiting for " + pending.label)
        test.finish()
      }
    }
  }

  // Offscreen this window exists only in memory; it gives the panel content a
  // scene so layouts and scrolling run. Previews leave it hidden and map only
  // the real card.
  FloatingWindow {
    visible: test.preview === ""
    implicitWidth: 420
    implicitHeight: 240
    color: "transparent"

    Tailscale.Panel {
      id: panel
      bar: QtObject {
        property color foreground: Color.foreground
        property color barForeground: Color.foreground
        property color urgent: Color.urgent
        property string fontFamily: Style.font.family
        property string position: "top"
        property int barSize: 24
        property bool vertical: false
        property bool foregroundAnimationEnabled: false
        property var activePopout: null
        function requestPopout(owner) { activePopout = owner }
        function releasePopout(owner) { activePopout = null }
        function registerClickTarget(target) {}
        function unregisterClickTarget(target) {}
        function hideTooltip(target) {}
        function showTooltip(target, text) {}
      }
    }
  }

  property var steps: [
    // The unit ships with every install, so without the CLI it still reports
    // inactive (3). The switch must stay hidden and refuse to run anyway.
    function() {
      waitFor("startup without the CLI", function() { return test.idle() && test.count(test.statusLine) >= 1 && !test.svc.installed }, function() {
        check(svc.receiverAvailable, "inactive unit reports available")
        check(!panel.showReceiver && !row.visible && !separator.visible, "receiver row and separator stay hidden without the CLI")
        svc.toggleReceiver()
        check(count(enableLine) === 0 && svc.actionStatus === "", "receiver toggle is rejected without the CLI")
        focus("header")
        move(1)
        check(panel.focusSection === "header", "down from header skips the hidden receiver")
        focus("receiver")
        panel.ensureCursor()
        check(panel.focusSection === "header" && !receiverSwitch.hasCursor, "a hidden receiver hands the cursor back to the header")
        nextStep()
      })
    },

    function() {
      setState("touch installed", function() {
        var before = count(statusLine)
        svc.refresh()
        check(svc.receiverBusy, "refresh() starts a receiver status check")
        waitFor("CLI detected", function() { return test.idle() && test.svc.installed && test.count(test.statusLine) === before + 1 }, function() {
          check(panel.showReceiver && row.visible && separator.visible, "receiver row and separator show with the CLI and the unit")
          check(!svc.receiverActive && !receiverSwitch.checked, "inactive unit shows the switch off")
          check(receiverSwitch.Accessible.name === "Receive files automatically", "receiver switch has an accessible name")
          check(receiverSwitch.Accessible.role === Accessible.CheckBox && receiverSwitch.Accessible.checkable, "receiver switch is exposed as a checkable control")
          check(!receiverSwitch.Accessible.checked, "receiver switch exposes its off state")
          nextStep()
        })
      })
    },

    function() {
      focus("header")
      move(1)
      check(panel.focusSection === "receiver" && receiverSwitch.hasCursor && !panel.headerHasCursor, "down from header reaches the receiver switch")
      move(1)
      check(panel.focusSection === "receiver", "down from the receiver stays put with nothing below")
      move(-1)
      check(panel.focusSection === "header" && !receiverSwitch.hasCursor, "up from the receiver returns to the header")
      panel.cursorActive = false
      receiverSwitch.hovered(true)
      check(panel.cursorActive && panel.focusSection === "receiver" && receiverSwitch.hasCursor, "hovering the receiver switch moves the cursor to it")
      var statusBefore = count(statusLine)
      keys.activateRequested()
      check(svc.actionStatus === "Turning automatic file receiving on...", "activation announces the receiver turning on")
      waitFor("keyboard enable", function() { return test.idle() && test.count(test.statusLine) > statusBefore }, function() {
        check(lastSystemctl() === "systemctl " + statusLine, "a status check confirms the toggle")
        check(count(enableLine) === 1 && count(disableLine) === 0, "Enter on the receiver runs enable --now")
        check(svc.receiverActive && receiverSwitch.checked && receiverSwitch.Accessible.checked, "receiver switch turns on")
        check(svc.actionStatus === "Automatic file receiving turned on" && svc.lastError === "", "receiver reports it turned on")
        nextStep()
      })
    },

    function() {
      receiverSwitch.toggled()
      waitFor("disable", function() { return test.idle() && test.count(test.disableLine) === 1 }, function() {
        check(count(enableLine) === 1, "turning off does not enable")
        check(!svc.receiverActive && !receiverSwitch.checked, "receiver switch turns off")
        check(svc.actionStatus === "Automatic file receiving turned off", "receiver reports it turned off")
        receiverSwitch.Accessible.toggleAction()
        waitFor("accessible toggle", function() { return test.idle() && test.count(test.enableLine) === 2 }, function() {
          check(svc.receiverActive, "the accessible toggle action turns the receiver on")
          nextStep()
        })
      })
    },

    // A slow toggle swallows repeats and status checks until it lands.
    function() {
      setState("echo 0.6 > toggle-delay", function() {
        var statusBefore = count(statusLine)
        focus("receiver")
        svc.toggleReceiver()
        svc.toggleReceiver()
        keys.activateRequested()
        receiverSwitch.toggled()
        receiverSwitch.Accessible.toggleAction()
        svc.refreshReceiver()
        svc.refresh()
        waitFor("slow disable", function() { return test.count(test.disableLine) === 2 }, function() {
          check(svc.receiverBusy && receiverSwitch.busy, "receiver reports busy while the toggle runs")
          check(count(statusLine) === statusBefore, "no status check races the running toggle")
          waitFor("slow disable done", function() { return test.idle() && test.count(test.statusLine) > statusBefore }, function() {
            check(count(disableLine) === 2 && count(enableLine) === 2, "repeated toggles while busy run a single command")
            check(!svc.receiverActive, "the single toggle turned the receiver off")
            nextStep()
          })
        })
      })
    },

    // A status check in flight blocks a toggle, so its stale answer cannot
    // overwrite the toggle's result.
    function() {
      setState("rm -f toggle-delay && echo 0.6 > is-active-delay", function() {
        svc.refreshReceiver()
        check(svc.receiverBusy, "status check marks the receiver busy")
        svc.toggleReceiver()
        check(svc.actionStatus.indexOf("Turning") !== 0, "toggle during a status check announces nothing")
        waitFor("slow status", function() { return test.idle() }, function() {
          check(count(enableLine) === 2 && count(disableLine) === 2, "toggle during a status check runs nothing")
          check(!svc.receiverActive, "receiver state is untouched by the rejected toggle")
          nextStep()
        })
      })
    },

    function() {
      setState("rm -f is-active-delay && printf 'stdout detail\\n' > toggle-stdout && printf 'Failed to enable unit: boom\\n' > toggle-stderr && echo 1 > toggle-exit", function() {
        svc.toggleReceiver()
        waitFor("failing toggle", function() { return test.idle() && test.count(test.enableLine) === 3 }, function() {
          check(svc.lastError === "Failed to enable unit: boom" && svc.actionStatus === svc.lastError, "receiver failure reports stderr first")
          check(!svc.receiverActive && !receiverSwitch.checked, "failed toggle leaves the switch off")
          nextStep()
        })
      })
    },

    function() {
      setState("rm -f toggle-stderr", function() {
        svc.toggleReceiver()
        waitFor("stdout failure", function() { return test.idle() && test.count(test.enableLine) === 4 }, function() {
          check(svc.lastError === "stdout detail", "receiver failure falls back to stdout without reusing the previous stderr")
          nextStep()
        })
      })
    },

    function() {
      setState("rm -f toggle-stdout", function() {
        svc.toggleReceiver()
        waitFor("silent failure", function() { return test.idle() && test.count(test.enableLine) === 5 }, function() {
          check(svc.lastError === "Could not change automatic file receiving", "silent receiver failure uses the fallback without reusing previous output")
          nextStep()
        })
      })
    },

    function() {
      setState("printf 'x%.0s' {1..300} > toggle-stderr", function() {
        svc.toggleReceiver()
        waitFor("long failure", function() { return test.idle() && test.count(test.enableLine) === 6 }, function() {
          check(svc.lastError.length === 138 && svc.lastError.charAt(137) === "…", "long receiver failures are elided like other service errors")
          nextStep()
        })
      })
    },

    // Without the CLI the unit's condition skips the start but `enable --now`
    // still exits 0; the follow-up status check must not leave "turned on".
    function() {
      setState("rm -f toggle-stderr toggle-exit && touch skip-start", function() {
        svc.toggleReceiver()
        waitFor("skipped start", function() { return test.idle() && test.count(test.enableLine) === 7 }, function() {
          check(!svc.receiverActive && !receiverSwitch.checked, "skipped start shows the switch off")
          check(svc.lastError === "Automatic file receiving did not start" && svc.actionStatus === svc.lastError, "skipped start reports that receiving did not start")
          nextStep()
        })
      })
    },

    function() {
      setState("rm -f skip-start", function() {
        svc.toggleReceiver()
        waitFor("recovered start", function() { return test.idle() && test.count(test.enableLine) === 8 }, function() {
          check(svc.receiverActive && svc.lastError === "" && svc.actionStatus === "Automatic file receiving turned on", "a later success clears the receiver error")
          nextStep()
        })
      })
    },

    // A follow-up check that cannot answer proves nothing, so a stop that
    // exited 0 is reported unverified rather than as switched off.
    function() {
      setState("touch break-status-after-toggle", function() {
        svc.toggleReceiver()
        waitFor("unverified stop", function() { return test.idle() && test.count(test.disableLine) === 3 && test.lastSystemctl() === "systemctl " + test.statusLine }, function() {
          check(svc.lastError === "Could not verify automatic file receiving" && svc.actionStatus === svc.lastError, "an unanswered follow-up check reports the stop unverified")
          check(svc.actionStatus !== "Automatic file receiving turned off", "an unanswered follow-up check does not claim the stop worked")
          check(!svc.receiverAvailable && !panel.showReceiver, "an unanswered follow-up check hides the switch")
          setState("rm -f break-status-after-toggle is-active-exit", function() {
            svc.refreshReceiver()
            waitFor("receiver answers again", function() { return test.idle() && test.svc.receiverAvailable }, function() {
              check(!svc.receiverActive && panel.showReceiver, "the receiver reappears off once systemd answers")
              nextStep()
            })
          })
        })
      })
    },

    // A toggle whose command never starts fails like any other and does not
    // leave the switch busy.
    function() {
      setState("mv ../bin/systemctl ../bin/systemctl.off", function() {
        svc.toggleReceiver()
        waitFor("toggle that cannot start", function() { return test.idle() && test.svc.lastError !== "" }, function() {
          check(svc.lastError === "Could not change automatic file receiving" && !svc.receiverActive, "a toggle that cannot start reports the generic failure")
          check(!svc.receiverBusy && !receiverSwitch.busy, "a toggle that cannot start leaves the switch idle")
          setState("mv ../bin/systemctl.off ../bin/systemctl", function() {
            svc.refreshReceiver()
            waitFor("systemctl back", function() { return test.idle() && test.svc.receiverAvailable }, nextStep)
          })
        })
      })
    },

    // A unit that disappears, or a manager that cannot answer, hides the row
    // and takes the cursor off it.
    function() {
      focus("receiver")
      setState("echo 4 > is-active-exit", function() {
        svc.refreshReceiver()
        waitFor("missing unit", function() { return test.idle() && !test.svc.receiverAvailable }, function() {
          check(!svc.receiverActive && !panel.showReceiver && !row.visible && !separator.visible, "missing unit hides the receiver row")
          check(panel.focusSection === "header" && !receiverSwitch.hasCursor, "hidden receiver hands the cursor back to the header")
          var before = count(enableLine) + count(disableLine)
          svc.toggleReceiver()
          check(count(enableLine) + count(disableLine) === before, "receiver toggle is rejected for a missing unit")
          setState("echo 1 > is-active-exit", function() {
            svc.refreshReceiver()
            waitFor("manager failure", function() { return test.idle() && test.count(test.statusLine) > 0 && test.lastSystemctl() === "systemctl " + test.statusLine }, function() {
              check(!svc.receiverAvailable && !panel.showReceiver, "an unanswered status check keeps the receiver hidden")
              nextStep()
            })
          })
        })
      })
    },

    // Exit nodes, machines, and connections stay reachable around the
    // receiver, and skip it when it is hidden.
    function() {
      setState("cp status-full.json status.json && cp accounts-two.json accounts.json", function() {
        svc.refresh(true)
        waitFor("full status", function() { return test.idle() && test.svc.peers.length === 2 && test.svc.accounts.length === 2 && panel.showExitNodes }, function() {
          focus("header")
          move(1)
          check(panel.focusSection === "accounts", "down from header skips the hidden receiver to connections")
          focus("accounts")
          panel.accountIndex = 0
          move(-1)
          check(panel.focusSection === "header", "up from connections skips the hidden receiver")
          setState("rm -f is-active-exit", function() {
            svc.refreshReceiver()
            waitFor("receiver back", function() { return test.idle() && test.panel_showReceiver() }, function() {
              focus("header")
              move(1)
              check(panel.focusSection === "receiver", "down from header reaches the receiver again")
              move(1)
              check(panel.focusSection === "accounts" && panel.accountIndex === 0, "down from the receiver reaches connections")
              move(-1)
              check(panel.focusSection === "receiver", "up from the first connection reaches the receiver")
              focus("accounts")
              panel.accountIndex = 1
              move(1)
              check(panel.focusSection === "exitNodes" && panel.exitNodeIndex === 0, "connections still lead to exit nodes")
              move(-1)
              check(panel.focusSection === "accounts", "exit nodes still lead back to connections")

              svc.accountsAccessDenied = true
              focus("receiver")
              move(1)
              check(panel.focusSection === "auth", "down from the receiver reaches operator authorization")
              move(-1)
              check(panel.focusSection === "receiver", "up from operator authorization reaches the receiver")
              focus("auth")
              move(1)
              check(panel.focusSection === "accounts", "operator authorization still leads to connections")
              svc.accountsAccessDenied = false

              svc.accounts = []
              focus("receiver")
              move(1)
              check(panel.focusSection === "exitNodes", "down from the receiver reaches exit nodes without connections")
              panel.exitNodeIndex = panel.exitNodes.length - 1
              move(1)
              check(panel.focusSection === "peers" && panel.peerIndex === 0, "exit nodes still lead to machines")
              move(-1)
              check(panel.focusSection === "exitNodes", "machines still lead back to exit nodes")
              panel.exitNodeIndex = 0
              move(-1)
              check(panel.focusSection === "receiver", "up from the first exit node reaches the receiver")

              focus("auth")
              panel.ensureCursor()
              check(panel.focusSection === "exitNodes", "a vanished authorization row falls to the next section")

              focus("exitNodes")
              panel.exitNodeIndex = 0
              Qt.callLater(function() {
                check(flick.height > row.height && flick.contentHeight > flick.height, "panel content is laid out taller than its viewport (" + flick.height + " of " + flick.contentHeight + ")")
                flick.contentY = Math.max(0, flick.contentHeight - flick.height)
                check(!rowInView(), "receiver starts scrolled out of view (contentY " + flick.contentY + ", height " + flick.height + " of " + flick.contentHeight + ")")
                move(-1)
                Qt.callLater(function() {
                  check(panel.focusSection === "receiver", "cursor reaches the receiver for scrolling")
                  check(rowInView(), "moving onto the receiver scrolls it into view (contentY " + flick.contentY + ", row at " + row.mapToItem(flick.contentItem, 0, 0).y + ")")
                  nextStep()
                })
              })
            })
          })
        })
      })
    }
  ]

  function panel_showReceiver() { return panel.showReceiver }

  function rowInView() {
    var top = row.mapToItem(flick.contentItem, 0, 0).y
    return top >= flick.contentY && top + row.height <= flick.contentY + flick.height
  }

  // Opt-in, panel-only captures: TS_TEST_PREVIEW=receiver, receiver-off, or
  // absent, with TS_TEST_SCREENSHOT=/path/to/card.png. The runner keeps the
  // real KeyboardPanel for these, so the card maps for about a second; the
  // tailnet, unit, and commands are the same stubs as the automated run, and
  // only the card itself is saved, never the desktop behind it.
  readonly property string preview: Quickshell.env("TS_TEST_PREVIEW")

  function startPreview() {
    waitFor("preview state", function() {
      if (!test.idle() || test.count(test.statusLine) < 1) return false
      return test.preview === "absent" ? !test.svc.installed : test.svc.installed && test.svc.peers.length > 0 && test.svc.receiverAvailable
    }, function() {
      panel.open()
      Qt.callLater(function() {
        if (preview !== "absent") focus("receiver")
        previewCapture.start()
      })
    })
  }

  Timer {
    id: previewCapture
    interval: 900
    onTriggered: {
      var path = Quickshell.env("TS_TEST_SCREENSHOT")
      var card = test.keys.parent.parent
      if (!path || !card) {
        test.check(false, "preview has a screenshot path and a card")
        panel.close()
        test.finish()
        return
      }
      card.grabToImage(function(result) {
        test.check(result.saveToFile(path), "save preview screenshot")
        panel.close()
        test.finish()
      })
    }
  }

  // Never leave a mapped card behind, even if the grab never answers.
  Timer { running: test.preview !== ""; interval: 15000; onTriggered: { panel.close(); test.finish() } }

  Component.onCompleted: preview !== "" ? startPreview() : nextStep()
}
