{
  description = "GUTT: 🦤";

  # zig 0.14.0
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zargs = {
      url = "github:pseudocc/zargs?rev=2b27bfe487d80ec326ffa3bab4b7dd5ccb6a4e58";
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

        env = {
          LINUX_INCLUDE_DIR = "${linux}/include";
          LIBC_INCLUDE_DIR = "${libc.dev}/include";
          LIBSSH_INCLUDE_DIR = "${libssh.dev}/include";
          LIBSSH_DIR = "${libssh}/lib";
        };

        deps = [
          linux
          libc.dev
          libssh
          libssh.dev
        ];

        configure = ''
            ln -s ${libssh.dev}/include/libssh translate-c/libssh
            ln -s ${linux}/include/linux translate-c/linux
        '';

        drv.larp = optimize: pkgs.stdenv.mkDerivation ({
          inherit version;
          pname = "larp";

          buildInputs = [
            (zig.hook.overrideAttrs {
              zig_default_flags = [
                "-Dcpu=baseline"
                "--release=${optimize}"
                "--color off"
              ];
            })
          ] ++ deps;
          src = ./.;

          LIBSSH_DIR = "${libssh}/lib";
          LIBC_INCLUDE_DIR = "${libc.dev}/include";
          LINUX_INCLUDE_DIR = "${linux}/include";
          LIBSSH_INCLUDE_DIR = "${libssh.dev}/include";

          outputs = [ "out" "doc" ];

          configurePhase = configure;

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
        } // env);

        packages = rec {
          larp-debug = drv.larp "off";
          larp-release-fast = drv.larp "fast";
          larp-release-safe = drv.larp "safe";
          larp-release-small = drv.larp "small";
          larp = larp-release-fast;
        };
      in {
        devShells.default = pkgs.mkShell ({
          buildInputs = deps ++ [
            zig
            zls
            pkgs.autoPatchelfHook
          ];
          shellHook = ''
            rm -f translate-c/{libssh,linux}
            ${configure}
          '';
        } // env);

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
          entries = builtins.listToAttrs (lib.mapAttrsToList ctor.larp packages);
        in entries // {
          default = entries.larp;
        };
      }
    );
}
