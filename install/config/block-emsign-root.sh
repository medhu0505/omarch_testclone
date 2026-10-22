# Mitigate the October 2026 eMudhra intermediate-key compromise while stable
# mirrors await ca-certificates-mozilla 3.131.1. Use the advisory's Arch remedy:
# https://emudhra.we-have-a-problem.com/#are-there-workarounds-for-linux
# The PEM is the public emSign ECC Root CA - G3 from Mozilla's 3.131 trust store,
# SHA-256 86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B.
# Keep the certificate here so already-patched and offline installs work too.
emsign_root="${BASH_SOURCE[0]%/*}/emsign-ecc-root-ca-g3.pem"
emsign_blocklist=/etc/ca-certificates/trust-source/blocklist/omarchy-emsign-ecc-root-ca-g3.pem

if [[ -L $emsign_blocklist ]] || { [[ -e $emsign_blocklist ]] && ! cmp -s "$emsign_root" "$emsign_blocklist"; }; then
  echo "Refusing to replace a modified eMudhra blocklist file: $emsign_blocklist" >&2
  false
else
  install -Dm644 "$emsign_root" "$emsign_blocklist"
  # Always retry extraction: an earlier run may have installed the blocklist
  # but failed before regenerating the OpenSSL, PEM and Java trust stores.
  update-ca-trust
fi
