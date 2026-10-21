notify_update() {
  omarchy-notification-send -u critical -g  "Update System" "Click to update the system." \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-update
}

# Something for omarchy-update to install: Omarchy itself or a development
# checkout behind its upstream (what the bar's update icon shows), or any
# repository package. checkupdates exits 2 when every package is current and
# 1 when it could not tell, so only a definite "nothing" holds the prompt back.
update_pending() {
  omarchy-update-available >/dev/null 2>&1 && return 0

  local status=0
  checkupdates --nocolor >/dev/null 2>&1 || status=$?
  ((status != 2))
}

notify_wifi() {
  omarchy-notification-send -u critical -g 󰖩 "Setup Wi-Fi" "Click to configure the wireless network." \
    --exec omarchy-shell shell toggle omarchy.network
}

announce_network() {
  # Ethernet is still negotiating DHCP when the session starts, so probing
  # right away calls a working machine offline. NetworkManager reports startup
  # complete once it has tried every connection it could auto-activate, which
  # is the first moment the answer means anything.
  nm-online -q -s -t 30

  # -x takes that answer as it stands rather than waiting out the timeout, so
  # a laptop with nothing to connect to gets prompted immediately.
  if ! nm-online -q -x -t 30; then
    notify_wifi
    # Nothing to update against until a link lands, so hold that prompt.
    nm-online -q -t 3600 || return
  fi

  # A fresh install from current media has nothing to update, and a toast
  # that leads nowhere teaches people to dismiss the next one.
  update_pending && notify_update
}

# Detached, so a slow or absent connection never holds up the rest of first run.
announce_network &
