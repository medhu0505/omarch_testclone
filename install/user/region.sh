# A regional install points this user's developer tools at the region's
# registries and leaves out the preinstalled apps the region cannot reach; the
# installer wrote the marker before finalization.
region=
[[ -r /etc/omarchy/region ]] && read -r region </etc/omarchy/region
if [[ $region == "cn" ]]; then
  "$OMARCHY_PATH/bin/omarchy-region-user" cn
  "$OMARCHY_PATH/bin/omarchy-region-preinstalls" cn
fi
