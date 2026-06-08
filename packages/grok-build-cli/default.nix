{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "0.2.32";
  baseUrl = "https://x.ai/cli";

  sources = {
    x86_64-linux = fetchurl {
      url = "${baseUrl}/grok-${version}-linux-x86_64";
      hash = "sha256-qasE36S/cD9ySyI+Rcf1IsaIdEIflI9ilqs0djhcvao=";
    };

    aarch64-linux = fetchurl {
      url = "${baseUrl}/grok-${version}-linux-aarch64";
      hash = "sha256-AKy4N6SyVpqVPvK1A7D4EoGbQcTPjzl7Dck9Fa0tqgs=";
    };
  };
in
stdenv.mkDerivation {
  pname = "grok-build-cli";
  inherit version;

  src = sources.${stdenv.hostPlatform.system} or (throw
    "grok-build-cli: unsupported system ${stdenv.hostPlatform.system}"
  );

  # Current upstream Linux artifacts are raw ELF binaries, not archives.
  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
  ];

  # 0.2.32 linux-x86_64 is static PIE and has no DT_NEEDED dependencies.
  # Add packages here only after readelf/ldd confirms a future release needs them.
  buildInputs = [ ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/grok"
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
