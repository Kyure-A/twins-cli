{
  description = "Development environment and package for twins-cli";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = pkgs.ocamlPackages;
        in
        rec {
          twins-cli = ocamlPackages.buildDunePackage {
            pname = "twins-cli";
            version = "0.1.0";
            src = pkgs.lib.cleanSourceWith {
              src = ./.;
              filter =
                path: type:
                let
                  name = builtins.baseNameOf path;
                in
                pkgs.lib.cleanSourceFilter path type
                && name != "_build"
                && name != ".direnv"
                && name != "result"
                && !(pkgs.lib.hasPrefix "result-" name);
            };

            minimalOCamlVersion = "5.1";
            duneVersion = "3";

            propagatedBuildInputs = with ocamlPackages; [
              cmdliner
              cohttp-lwt-unix
              lambdasoup
              lwt
              uri
              yojson
            ];

            checkInputs = [ ocamlPackages.alcotest ];
            doCheck = true;
            checkPhase = "dune runtest --force";

            meta = {
              description = "Unofficial command-line client for the University of Tsukuba TWINS";
              homepage = "https://github.com/Kyure-A/twins-cli";
              license = pkgs.lib.licenses.gpl3Only;
              mainProgram = "twins";
              platforms = systems;
            };
          };

          default = twins-cli;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = pkgs.ocamlPackages;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = with ocamlPackages; [
              alcotest
              dune_3
              findlib
              ocaml
              ocamlformat
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.default;
        in
        {
          inherit package;

          cli-smoke = pkgs.runCommand "twins-cli-smoke" { } ''
            ${pkgs.bash}/bin/bash ${./scripts/ci-smoke.sh} ${package}/bin/twins
            touch "$out"
          '';
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/twins";
          meta = self.packages.${system}.default.meta;
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
