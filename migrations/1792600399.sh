echo "Distrust the root of the compromised eMudhra intermediate certificates"

sudo env OMARCHY_PATH="$OMARCHY_PATH" bash -euo pipefail "$OMARCHY_PATH/install/config/distrust-emudhra.sh"
