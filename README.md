# ZARP

ZARP is an ARP scanner written in 100% Zig, which may help you to
discover your lab devices.

ZARP only supports Linux and depends libssh which help us to execute
commands on devices to collect informations like their host names.

## Development

ZARP is fully managed by Nix Flake and Zig.

```sh
# start a development shell
nix develop
zig build && \
  auto-patchelf --lib $LIBSSH_DIR --paths zig-out/bin/zarp && \
  sudo setcap cap_net_raw=ep zig-out/bin/zarp
```

For non Nix Flake users, you need to configure your environment with:

```sh
# Something similar to this, but based on your system
# do these once
ln -s ${libssh.dev}/include/libssh translate-c/libssh
ln -s ${linux}/include/linux translate-c/linux
# do these every time you build
export LINUX_INCLUDE_DIR = "${linux}/include"
export LIBC_INCLUDE_DIR = "${libc.dev}/include"
export LIBSSH_INCLUDE_DIR = "${libssh.dev}/include"
export LIBSSH_DIR = "${libssh}/lib"
zig-build && sudo setcap cap_net_raw=ep zig-out/bin/zarp
```

### Customizing

You may not only want to get the host names of your devices, but also
other informations like their distribution, kernel version, etc.

You should extend the struct `daemon.Device.Info`, and execute extra
commands in the `daemon.Device.update` method, you can refer to the
implementation of host name retrieval in it.

## Usage

Start the daemon:
```sh
zarp daemon --key /your/private/key --user lab-user
```

List your devices:
```sh
# list all devices
zarp list
# list all devices in JSON format
# This is useful to parse the output with jq
zarp list --json
# list all devices sorted by their host names
zarp list --sort-by name
```

Require a full rescan:
```sh
zarp rescan
```

For more information, please check the help for each command with
`zarp <command> --help`.
