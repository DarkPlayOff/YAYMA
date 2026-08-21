{
  description = "YAYMA - Yet Another Yandex Music App";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      version = "2.3.0";
      # URL: https://github.com/DarkPlayOff/YAYMA/releases/download/v${version}/yayma-linux-x64-${version}.tar.gz
      # Bump `version` and re-run `nix flake lock --update-input nixpkgs` + `nix store prefetch-file <url>`
      # to get the new sha256.
      srcHash = "sha256-0fu6Q8pcsGPiRvG3LsIILWL0MkE0tW9Ebp9lU41Q/IY=";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          yayma = pkgs.stdenv.mkDerivation {
            pname = "yayma";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/DarkPlayOff/YAYMA/releases/download/v${version}/yayma-linux-x64-${version}.tar.gz";
              sha256 = srcHash;
            };

            # Flutter bundles contain several top-level directories (data, lib, ...).
            sourceRoot = ".";

            dontConfigure = true;
            dontBuild = true;

            nativeBuildInputs = [
              pkgs.autoPatchelfHook
              pkgs.wrapGAppsHook3
            ];

            buildInputs = [
              pkgs.alsa-lib
              pkgs.dbus
              pkgs.gdk-pixbuf
              pkgs.glib-networking
              pkgs.gsettings-desktop-schemas
              pkgs.gtk3
              pkgs.jdk
              pkgs.libayatana-appindicator
              pkgs.libayatana-indicator
              pkgs.libsecret
              pkgs.libsoup_3
              pkgs.shared-mime-info
              pkgs.webkitgtk_4_1
              pkgs.stdenv.cc.cc.lib
            ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/scalable/apps
              cp -r . $out/bin/
              install -Dm644 ${./packaging/linux/io.github.darkplayoff.yayma.desktop} $out/share/applications/io.github.darkplayoff.yayma.desktop
              install -Dm644 ${./src/assets/icons/logo.svg} $out/share/icons/hicolor/scalable/apps/io.github.darkplayoff.yayma.svg
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Yet Another Yandex Music Client";
              homepage = "https://github.com/DarkPlayOff/YAYMA";
              license = licenses.gpl3Plus;
              mainProgram = "yayma";
              platforms = [ "x86_64-linux" ];
            };
          };
        in
        {
          yayma = yayma;
          default = yayma;
        });

      apps = forAllSystems (system:
        let
          yayma = self.packages.${system}.yayma;
        in
        {
          default = {
            type = "app";
            program = "${yayma}/bin/yayma";
          };
        });
    };
}
