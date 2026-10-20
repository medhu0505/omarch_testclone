# Install Vulkan drivers matching detected GPU hardware
# (NVIDIA Vulkan is handled by nvidia.sh via nvidia-utils)

declare -A VULKAN_DRIVERS=(
  [Intel]=vulkan-intel
  [AMD]=vulkan-radeon
  [Apple]=vulkan-asahi
)

PACKAGES=()

for vendor in "${!VULKAN_DRIVERS[@]}"; do
  if lspci | grep -iE "(VGA|Display).*$vendor" > /dev/null; then
    PACKAGES+=("${VULKAN_DRIVERS[$vendor]}")
    # Satisfy lib32-vulkan-driver before a direct Steam/umu install can pick
    # an NVIDIA provider on Intel or AMD hardware. Multilib is x86-only.
    if [[ $vendor == "Intel" || $vendor == "AMD" ]] && omarchy-hw-x86; then
      PACKAGES+=("lib32-${VULKAN_DRIVERS[$vendor]}")
    fi
  fi
done

# Adreno GPUs are platform devices, so lspci never sees them.
if omarchy-hw-aarch64-qualcomm; then
  PACKAGES+=(vulkan-freedreno)
fi

if (( ${#PACKAGES[@]} > 0 )); then
  omarchy-pkg-add "${PACKAGES[@]}"
fi
