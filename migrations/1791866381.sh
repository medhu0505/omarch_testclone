echo "Fix microphone and speakers on ASUS ProArt PX13 HN7306"

if omarchy-hw-asus-proart-px13-hn7306; then
  source "$OMARCHY_PATH/install/hardware/asus/fix-asus-proart-px13-hn7306-audio.sh"

  # Forget this card's saved profile so the new pro-audio default takes effect
  profile_state=~/.local/state/wireplumber/default-profile
  if [[ -f $profile_state ]]; then
    sed -i '/-platform-amd_sdw=/d' "$profile_state"
  fi
  systemctl --user daemon-reload
  systemctl --user try-restart wireplumber.service
fi
