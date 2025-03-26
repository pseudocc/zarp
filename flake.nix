{
  description = "GUTT: 🦤";

  # zig 0.14.0
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zargs = {
      url = "github:pseudocc/zargs?rev=c07f9abe56bde798cbaf3159f2c543679c937b19";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    zargs,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;

    eachSystem = fn:
      lib.foldl' (
        acc: system:
          lib.recursiveUpdate
          acc
          (lib.mapAttrs (_: value: {${system} = value;}) (fn system))
      ) {}
      lib.platforms.linux;

    version = with builtins; let
      matched_group = match ''.+\.version = "([^"]+)",.+'' (readFile ./build.zig.zon);
    in elemAt matched_group 0;
  in
    eachSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        zig = pkgs.zig;
        zls = pkgs.zls;
        linux = pkgs.linuxHeaders;
        libc = pkgs.glibc;
        libssh = pkgs.libssh;

        drv.larp = optimize: pkgs.stdenv.mkDerivation {
          inherit version;
          pname = "larp";

          buildInputs = [
            zig.hook
            linux
            libc.dev
            libssh
            libssh.dev
          ];
          src = ./.;

          zigBuildFlags = [ "-Doptimize=${optimize}" ];
          outputs = [ "out" "doc" ];

          configurePhase = ''
            ln -s ${linux}/include include/linux
            ln -s ${libc.dev}/include include/libc
            ln -s ${libssh.dev}/include include/libssh
            ln -s ${libssh}/lib lib/libssh
          '';

          patchPhase = ''
            zig fetch --save=zargs ${zargs.outPath}
          '';

          postInstall = ''
            install -D -m644 LICENSE $doc/share/doc/LICENSE
          '';

          passthru = { inherit optimize zig; };

          meta = {
            description = "Lab ARP scanner";
            license = lib.licenses.free;
            mainProgram = "larp";
          };
        };

        packages = rec {
          larp-debug = drv.larp "Debug";
          larp-release-fast = drv.larp "ReleaseFast";
          larp-release-safe = drv.larp "ReleaseSafe";
          larp = larp-release-fast;
        };
      in {
        devShells.default = pkgs.mkShell {
          LIBSSH_DIR = "${libssh}/lib";
          buildInputs = [
            zig
            zls
            linux
            libc.dev
            libssh
            libssh.dev
          ];
          shellHook = ''
            rm -f include/{linux,libc,libssh} lib/libssh
            ln -s ${linux}/include include/linux
            ln -s ${libc.dev}/include include/libc
            ln -s ${libssh.dev}/include include/libssh
            ln -s ${libssh}/lib lib/libssh
          '';
        };

        packages = packages // {
          default = packages.larp;
        };

        apps = let
          ctor.larp = name: pkg: {
            inherit name;
            value = {
              type = "app";
              program = lib.getExe' pkg "larp";
            };
          };
          ctor.larpy = name: pkg: {
            name = builtins.replaceStrings ["larp"] ["larpy"] name;
            value = {
              type = "app";
              program = lib.getExe' pkg "larpy";
            };
          };
          entries = builtins.listToAttrs (
            (lib.mapAttrsToList ctor.larp packages) ++
            (lib.mapAttrsToList ctor.larpy packages)
          );
        in entries // {
          default = entries.larpy;
        };
      }
    );
}
