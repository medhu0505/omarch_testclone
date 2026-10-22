echo "Distrust the emSign root affected by the eMudhra key compromise"

# Another user, or ca-certificates-mozilla 3.131.1, may already have removed the root.
# update-ca-trust writes cadir last, so both clean means the whole extraction finished.
extracted=/etc/ca-certificates/extracted

if [[ ! -s $extracted/tls-ca-bundle.pem || ! -d $extracted/cadir || -e $extracted/cadir/emSign_ECC_Root_CA_-_G3.pem ]] ||
  grep -qxF "# emSign ECC Root CA - G3" "$extracted/tls-ca-bundle.pem"; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/block-emsign-root.sh"
fi
