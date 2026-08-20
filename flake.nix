{
  description = "cli-spec-transform: pattern-based transformers between cli-spec specifications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # The cli-spec Racket collection this package transforms specs of.
    # Not a flake output we can consume as a package (nixpkgs has no Racket
    # package builder), so we take the source tree and register it with raco
    # from the dev shell.
    cli-syntax = {
      url = "github:riz0id/cli-syntax";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cli-syntax,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.racket # provides racket and raco
          ];

          # Pin the exact cli-syntax revision from flake.lock for the hooks
          # below and for manual updates:
          #   raco pkg update --name cli-spec --copy "$CLI_SYNTAX_SRC"
          CLI_SYNTAX_SRC = "${cli-syntax}";

          shellHook = ''
            # Keep the Racket state (installed packages, compiled files) in a
            # per-project directory so nothing leaks into the global user
            # scope. It must live outside the working tree: raco refuses to
            # link a package directory that contains its own collects path.
            export PLTUSERHOME="$HOME/.cache/racket-envs/cli-spec-transform"

            # cli-spec comes from the Nix store (read-only), so install by
            # copy; this package is the working tree, so install as a link.
            raco pkg install --batch --skip-installed --auto \
              --name cli-spec --copy "$CLI_SYNTAX_SRC"
            raco pkg install --batch --skip-installed --auto \
              --name cli-spec-transform --link "$PWD"
          '';
        };
      });
    };
}
