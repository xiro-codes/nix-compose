{
  name ? "app",
}:
{
  lib,
  pkgs,
  rustPlatform,
}:

let
  inherit (lib) cleanSource;
in
rustPlatform.buildRustPackage {
  pname = "${name}";
  version = "0.1.0";

  src = cleanSource ../.;

  cargoLock = {
    lockFile = ../Cargo.lock;
  };

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];

  doCheck = false;
  OPENSSL_NO_VENDOR = 1;

  postInstall = ''
    mkdir -p $out/share/${name}
    cp -r templates $out/share/${name}
    cp -r static $out/share/${name}
  '';

  meta = {
    description = "Web Service";
    homepage = "https://github.com/xiro-codes/${name}";
  };
}
