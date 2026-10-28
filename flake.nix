{
  description = "Prebuilt GCC trunk toolchains, refreshed by CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # CI writes nix/sources/<system>.json for each published archive.
      sourceFile = system: ./nix/sources + "/${system}.json";
      systems = builtins.filter (system: builtins.pathExists (sourceFile system))
        [ "x86_64-linux" "aarch64-linux" ];
      forSystems = f: lib.genAttrs systems
        (system: f (nixpkgs.legacyPackages.${system}.extend self.overlays.default));
    in
    {
      overlays.default = final: prev: {
        gcc-trunk-unwrapped =
          let system = final.stdenv.hostPlatform.system; in
          if builtins.elem system systems
          then final.callPackage ./nix/package.nix { source = lib.importJSON (sourceFile system); }
          else throw "gcc-trunk: no prebuilt archive for ${system}";
        # Adds glibc headers/crt files, binutils and the Nix dynamic linker.
        gcc-trunk = final.wrapCCWith { cc = final.gcc-trunk-unwrapped; };
        gccTrunkStdenv = final.overrideCC final.stdenv final.gcc-trunk;
      };

      packages = forSystems (pkgs: {
        inherit (pkgs) gcc-trunk gcc-trunk-unwrapped;
        default = pkgs.gcc-trunk;
      });

      devShells = forSystems (pkgs: {
        default = pkgs.mkShell.override { stdenv = pkgs.gccTrunkStdenv; } { };
      });

      checks = forSystems (pkgs: {
        hello = pkgs.gccTrunkStdenv.mkDerivation {
          name = "gcc-trunk-hello";
          dontUnpack = true;
          buildPhase = ''
            printf '%s\n' '#include <iostream>' 'int main(){std::cout << "ok\n";}' > t.cc
            $CXX -std=c++26 -fopenmp t.cc -o t
            ./t
          '';
          installPhase = "touch $out";
        };
      });
    };
}
