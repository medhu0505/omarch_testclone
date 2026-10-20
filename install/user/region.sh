# A regional install points this user's developer tools at the region's registries,
# leaves out the apps the region cannot reach and sets its font; the installer
# wrote the marker before finalization.
region=
[[ -r /etc/omarchy/region ]] && read -r region </etc/omarchy/region
if [[ $region == "cn" ]]; then
  "$OMARCHY_PATH/bin/omarchy-region-user" cn
  "$OMARCHY_PATH/bin/omarchy-region-preinstalls" cn
fi
