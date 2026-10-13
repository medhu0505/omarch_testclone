#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Helium raises one classless "Profile error occurred" dialog per failed profile
# database. They have to float, or half a dozen of them tile the workspace.
rules=$(OMARCHY_PATH="$ROOT" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
hl = setmetatable({
  window_rule = function(rule)
    if rule.tag == "+floating-window" then
      print((rule.match.class or "") .. "\t" .. (rule.match.title or ""))
    end
  end,
}, { __index = function() return function() return {} end end })
require("default.hypr.helpers")
require("default.hypr.apps.browser")
LUA
)

[[ $rules == $'^$\t^Profile error occurred$' ]] ||
  fail "Helium profile error dialogs float" "floating-window rules: ${rules:-none}"
pass "Helium profile error dialogs float"
