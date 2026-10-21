#!/bin/bash

set -euo pipefail

sddm_conf="${OMARCHY_SDDM_CONF:-/etc/sddm.conf}"
sddm_conf_dir="${OMARCHY_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
greeter="${OMARCHY_SDDM_GREETER:-/usr/bin/sddm-greeter}"

[[ -x $greeter ]] || exit 0
ldd_output=$(ldd "$greeter" 2>/dev/null) || exit 0
[[ $ldd_output == *"not found"* ]] || exit 0

config_files=()
for file in "$sddm_conf_dir"/*.conf; do
  [[ -f $file ]] || continue
  config_files+=("$file")
done
if [[ -f $sddm_conf ]]; then
  config_files+=("$sddm_conf")
fi
(( ${#config_files[@]} == 1 )) || exit 0

target_file=${config_files[0]}
theme=$(LC_ALL=C awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  {
    line = $0
    sub(/[;#].*$/, "", line)
    if (line ~ /^[[:space:]]*\[Theme\][[:space:]]*$/) {
      section = 1
      next
    }
    if (line ~ /^[[:space:]]*\[/) {
      section = 0
    }
    if (section && line ~ /^[[:space:]]*Current[[:space:]]*=/) {
      assignments++
      value = line
      sub(/^[[:space:]]*Current[[:space:]]*=[[:space:]]*/, "", value)
      value = trim(value)
      if (value == "elarun" || value == "maldives" || value == "maya") {
        theme = value
      }
    }
  }
  END {
    if (assignments == 1 && theme != "") {
      print theme
    }
  }
' "$target_file" 2>/dev/null || true)

case $theme in
  elarun|maldives|maya) ;;
  *) exit 0 ;;
esac

sudo sed -i -E \
  '/^[[:space:]]*\[Theme\][[:space:]]*$/,/^[[:space:]]*\[/ {
    s/^[[:space:]]*Current[[:space:]]*=[[:space:]]*(elarun|maldives|maya)([[:space:]]*[#;].*)?[[:space:]]*$/Current=omarchy/
  }' "$target_file"

echo "Changed SDDM theme from $theme to omarchy because the Qt5 greeter has missing libraries."
