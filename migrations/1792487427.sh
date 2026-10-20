echo "Install matching 32-bit Vulkan drivers on AMD and Intel systems"

if omarchy-hw-x86; then
  bash -euo pipefail "$OMARCHY_PATH/install/hardware/vulkan.sh"
fi
