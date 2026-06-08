#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_FILE="$SCRIPT_DIR/../packages/cursor-cli/default.nix"

version="${1:-$(curl -fsSL https://cursor.com/install | grep -oP 'lab/\K[^/]+' | head -n1)}"
echo "cursor-cli version: ${version}" >&2

# "2026.06.04-5fd875e" -> "0-unstable-2026-06-04"
date_part="$(echo "$version" | cut -d- -f1 | tr '.' '-')"
cosmetic_version="0-unstable-${date_part}"

base_url="https://downloads.cursor.com/lab/${version}"

hash_x64=""
hash_arm64=""
for platform in x64 arm64; do
  url="${base_url}/linux/${platform}/agent-cli-package.tar.gz"
  echo "Prefetching ${url}" >&2
  base32_hash="$(TMPDIR=/tmp nix-prefetch-url --type sha256 "$url")"
  sri_hash="$(nix hash convert --hash-algo sha256 --to sri "$base32_hash")"
  case "$platform" in
    x64)  hash_x64="$sri_hash"  ;;
    arm64) hash_arm64="$sri_hash" ;;
  esac
  echo "  ${platform}: ${sri_hash}" >&2
done

# Rewrite the nix file. Nix's \${...} interpolation is escaped here so bash
# doesn't expand it — only the shell variables above are substituted.
cat > "$NIX_FILE" <<EOF
{ cursor-cli, fetchurl, stdenv }:
let
  version = "${version}";
  baseUrl = "https://downloads.cursor.com/lab/\${version}/linux";
  sources = {
    x86_64-linux  = fetchurl { url = "\${baseUrl}/x64/agent-cli-package.tar.gz";
      hash = "${hash_x64}"; };  # #ADJUST run scripts/update-cursor-cli.sh
    aarch64-linux = fetchurl { url = "\${baseUrl}/arm64/agent-cli-package.tar.gz";
      hash = "${hash_arm64}"; };  # #ADJUST run scripts/update-cursor-cli.sh
  };
in
cursor-cli.overrideAttrs (old: {
  version = "${cosmetic_version}";
  src = sources.\${stdenv.hostPlatform.system} or (throw
    "cursor-cli: unsupported system \${stdenv.hostPlatform.system}");
  passthru = (old.passthru or {}) // { inherit sources; };
})
EOF

echo "Updated ${NIX_FILE}" >&2
