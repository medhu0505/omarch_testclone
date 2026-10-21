# eMudhra certificate distrust

`emsign-ecc-root-ca-g3.crt` is the public **emSign ECC Root CA - G3** certificate, SHA-256 `86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B`. It was extracted from Arch's installed Mozilla trust store and checked against the [incident's root list](https://emudhra.we-have-a-problem.com/roots.json).

The October 2026 compromised intermediate certificates chain to this root. Fresh system setup and an existing-install migration put this certificate in Arch's system blocklist and run `update-ca-trust`, protecting clients that use the generated system bundles, hashed certificate directory, or p11-kit. Arch's Mozilla bundle already excludes the other affected public TLS root, AAA Certificate Services.

This matches the [Arch workaround published by the incident responders](https://emudhra.we-have-a-problem.com/#linux) while Omarchy's stable mirror still ships `ca-certificates-mozilla 3.131-1`. Arch has shipped `3.131.1-1` with the root removed. Retaining the local blocklist after that update prevents an older package from restoring trust. Sites still relying on this root will need to replace their certificate chain.

Applications that cache their trust store need to restart. Applications with bundled trust stores, including some language runtimes, Python environments, Electron applications, and containers, need their own upstream updates. This system repair does not change those bundles or browser revocation settings.
