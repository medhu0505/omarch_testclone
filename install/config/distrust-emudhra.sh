# The October 2026 eMudhra intermediate-key compromise also affects clients
# without browser revocation lists, including curl and git. Block the root
# while Omarchy's package mirrors catch up with ca-certificates-mozilla 3.131.1.
# Arch already removed the other affected public TLS root (AAA Certificate Services).
# https://emudhra.we-have-a-problem.com/#linux
install -Dm644 "$OMARCHY_PATH/default/ca-certificates/emsign-ecc-root-ca-g3.crt" \
  /etc/ca-certificates/trust-source/blocklist/omarchy-emsign-ecc-root-ca-g3.crt

# Always retry extraction, even if a previous attempt installed the blocklist
# successfully but failed to regenerate the bundles and hashed certificate dir.
update-ca-trust
