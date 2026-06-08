#!/usr/bin/env bash
# update-grok-build-cli.sh — fetch current Grok CLI release, compute SRI hashes,
# and REWRITE packages/grok-build-cli/default.nix in place.
#
# Usage:
#   ./update-grok-build-cli.sh          # auto-detect latest version
#   ./update-grok-build-cli.sh 0.2.33   # pin to a specific version
#
# Mirrors the approach used by update-cursor-cli.sh: a heredoc regenerates the
# entire default.nix so version + hashes are always consistent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_FILE="$SCRIPT_DIR/../packages/grok-build-cli/default.nix"

version="${1:-$(curl -fsSL https://x.ai/cli/stable)}"
echo "grok-build-cli version: ${version}" >&2

base_url="https://x.ai/cli"

hash_x86_64=""
hash_aarch64=""

for platform in linux-x86_64 linux-aarch64; do
  url="${base_url}/grok-${version}-${platform}"
  echo "Prefetching ${url}" >&2

  base32_hash="$(TMPDIR=/tmp nix-prefetch-url --type sha256 "$url")"
  sri_hash="$(nix hash convert --hash-algo sha256 --to sri "$base32_hash")"

  case "$platform" in
    linux-x86_64)  hash_x86_64="$sri_hash"  ;;
    linux-aarch64) hash_aarch64="$sri_hash" ;;
  esac
  echo "  ${platform}: ${sri_hash}" >&2
done

# Rewrite the nix file.  Nix's \${...} interpolation is escaped here so bash
# doesn't expand it — only the shell variables above are substituted.
cat > "$NIX_FILE" <<EOF
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "${version}";
  baseUrl = "https://x.ai/cli";

  sources = {
    x86_64-linux = fetchurl {
      url = "\${baseUrl}/grok-\${version}-linux-x86_64";
      hash = "${hash_x86_64}";
    };

    aarch64-linux = fetchurl {
      url = "\${baseUrl}/grok-\${version}-linux-aarch64";
      hash = "${hash_aarch64}";
    };
  };
in
stdenv.mkDerivation {
  pname = "grok-build-cli";
  inherit version;

  src = sources.\${stdenv.hostPlatform.system} or (throw
    "grok-build-cli: unsupported system \${stdenv.hostPlatform.system}"
  );

  # Current upstream Linux artifacts are raw ELF binaries, not archives.
  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
  ];

  # Add packages here only after readelf/ldd confirms a future release needs them.
  buildInputs = [ ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "\$src" "\$out/bin/grok"
    runHook postInstall
  '';

  doCheck = false;

  meta = {
    description = "xAI Grok Build CLI";
    homepage = "https://x.ai/cli";
    license = lib.licenses.unfree;
    mainProgram = "grok";
    platforms = lib.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
EOF

echo "Updated ${NIX_FILE}" >&2
