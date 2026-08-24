{
  description = "Zero-dependency HTTP/2 implementation in pure Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      ZIG_VERSION = "0.16.0";
      eachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [
                zig-overlay.overlays.default
              ];
            }
          )
        );

      treefmt =
        pkgs:
        treefmt-nix.lib.evalModule pkgs (
          { pkgs, ... }: {
            projectRootFile = "flake.nix";
            programs = {
              zig.enable = true;
              nixfmt.enable = true;
            };
            settings = {
              zig = {
                package = pkgs.zigpkgs.${ZIG_VERSION};
              };
            };
          }
        );
    in
    {
      packages = eachSystem (pkgs: {
        h2 = pkgs.stdenv.mkDerivation {
          pname = "h2.zig";
          version = "0.0.0";
          src = ./.;
          buildInputs = [ pkgs.zigpkgs.${ZIG_VERSION} ];
          buildPhase = ''
            # zig needs a $HOME dir for caching (non-configurable)
            export HOME=.
            zig build --release=fast
          '';
          installPhase = ''
            mv ./zig-out "$out"
          '';
        };
      });
      formatter = eachSystem (pkgs: (treefmt pkgs).config.build.wrapper);
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          name = "h2.zig dev shell";
          buildInputs = [
            pkgs.zigpkgs.${ZIG_VERSION}
            pkgs.zls
            pkgs.nixd
            pkgs.nil
          ];
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.rustPlatform.bindgenHook
            # pkgs.gcc16Stdenv.cc.libc.static
            (treefmt pkgs).config.build.wrapper
          ]
          ++ pkgs.lib.attrsets.attrValues (treefmt pkgs).config.build.programs;
        };
      });
    };
}
