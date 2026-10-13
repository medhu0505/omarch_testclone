echo "Let UPower notice the charger being plugged in or out on Snapdragon laptops"

# See install/hardware/qualcomm/charger-events.sh, which sets up new installs the same way.
rules="${OMARCHY_QUALCOMM_CHARGER_RULES:-/etc/udev/rules.d/71-omarchy-qualcomm-charger-events.rules}"

if ! omarchy-hw-aarch64-qualcomm || [[ -f $rules ]]; then
  exit 0
fi

sudo install -Dm644 /dev/stdin "$rules" <<'RULES'
# Qualcomm: qcom_battmgr only announces the battery, so replay a change event on
# its charger supplies for UPower; see install/hardware/qualcomm/charger-events.sh.
# Never match the battery itself here, or the replay loops.
ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", RUN+="/usr/bin/udevadm trigger --action=change --subsystem-match=power_supply --sysname-match=qcom-battmgr-ac --sysname-match=qcom-battmgr-usb --sysname-match=qcom-battmgr-wls"
RULES

# UPower may already hold a stale charger state, so have it read the charger
# supplies again now instead of at the battery's next report.
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=power_supply --sysname-match=qcom-battmgr-ac --sysname-match=qcom-battmgr-usb --sysname-match=qcom-battmgr-wls
