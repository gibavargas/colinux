# CoLinux Release Signing Keys

This directory holds the **public** GPG key(s) used to sign CoLinux release
artifacts (the detached signature over each release's `SHA256SUMS` file,
published as `SHA256SUMS.sig` on the GitHub Release).

## Verifying a release

```bash
# 1. Download from the release page: the ISO/image, SHA256SUMS, and SHA256SUMS.sig
# 2. Import the CoLinux release public key from this repo ...
gpg --import keys/colinux-release.asc
#    ... or from a keyserver (replace FINGERPRINT with the one in the release notes):
# gpg --recv-keys FINGERPRINT

# 3. Verify the checksum signature
gpg --verify SHA256SUMS.sig SHA256SUMS

# 4. Verify the artifact integrity
sha256sum -c SHA256SUMS
```

A release whose notes say it is **not GPG-signed** has no `SHA256SUMS.sig`;
in that case rely on the `SHA256SUMS` checksum alone.

## Key provisioning (maintainer)

The corresponding **private** key is never committed. It is stored as the
`COLINUX_GPG_PRIVATE_KEY` repository secret (ASCII-armored) consumed by
`.github/workflows/release.yml`. An optional `COLINUX_GPG_PASSPHRASE` secret
holds the key passphrase.

To generate and export a signing key:

```bash
# Generate a dedicated signing key (no expiry recommended for releases).
gpg --batch --full-generate-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: CoLinux Releases
Name-Email: releases@colinux.local
Expire-Date: 0
%commit
EOF

# Export the PUBLIC key here (committed to the repo):
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
gpg --armor --export "$KEYID" > keys/colinux-release.asc

# Export the PRIVATE key (paste into the GitHub secret COLINUX_GPG_PRIVATE_KEY):
gpg --armor --export-secret-keys "$KEYID"

# Publish the public key to a keyserver:
gpg --send-keys "$KEYID"
```

The release workflow imports the private key in CI, signs `SHA256SUMS` with a
detached armored signature, self-verifies, and uploads `SHA256SUMS.sig`.
If the secret is absent the release is published unsigned with a notice in the
notes — so the first release can be cut before a signing key exists.
