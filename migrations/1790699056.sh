echo "Disable Chromium GPU compositing on legacy radeon GPUs"

for browser in chromium chrome microsoft-edge-stable brave brave-origin; do
  omarchy-install-chromium-legacy-gpu "$HOME/.config/$browser-flags.conf"
done
