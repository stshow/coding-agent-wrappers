{ cursor-cli, fetchurl, stdenv }:
let
  version = "2026.06.04-5fd875e";
  baseUrl = "https://downloads.cursor.com/lab/${version}/linux";
  sources = {
    x86_64-linux  = fetchurl { url = "${baseUrl}/x64/agent-cli-package.tar.gz";
      hash = "sha256-VCWqsp+KAdN33j3H90VXOa1Zgp4IeeoMQpa9nuxSAwA="; };  # #ADJUST run scripts/update-cursor-cli.sh
    aarch64-linux = fetchurl { url = "${baseUrl}/arm64/agent-cli-package.tar.gz";
      hash = "sha256-840iUUKLt1duoq1LbxIFgwtRmvTna7A6Ofi4wbkEKkI="; };  # #ADJUST run scripts/update-cursor-cli.sh
  };
in
cursor-cli.overrideAttrs (old: {
  version = "0-unstable-2026-06-04";
  src = sources.${stdenv.hostPlatform.system} or (throw
    "cursor-cli: unsupported system ${stdenv.hostPlatform.system}");
  passthru = (old.passthru or {}) // { inherit sources; };
})
