{
  description = "Shared library for blink.* neovim plugins";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs = {
    nixpkgs,
    self,
  }: let
    inherit (nixpkgs) lib;
    inherit (lib.attrsets) genAttrs mapAttrs' nameValuePair;
    inherit (lib.fileset) fileFilter toSource;

    systems = ["x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = genAttrs systems;
    nixpkgsFor = forAllSystems (system: nixpkgs.legacyPackages.${system});

    blink-lib-package = {vimUtils}:
      vimUtils.buildVimPlugin {
        pname = "blink.lib";
        version = "0.1.0";
        src = toSource {
          root = ./.;
          fileset = fileFilter (file: file.hasExt "lua") ./.;
        };
      };
  in {
    packages = forAllSystems (system: rec {
      blink-lib = nixpkgsFor.${system}.callPackage blink-lib-package {};
      default = blink-lib;
    });

    overlays.default = final: prev: {
      vimPlugins = prev.vimPlugins.extend (_: _: {
        blink-lib = final.callPackage blink-lib-package {};
      });
    };

    checks = forAllSystems (system: mapAttrs' (n: nameValuePair "package-${n}") (removeAttrs self.packages.${system} ["default"]));
  };
}
