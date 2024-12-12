{
  description = "A OS derived from Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-24.11-small";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      stage1 = pkgs.writeScript "init" ''
        #!/bin/busybox sh

        # expands the busybox
        /bin/busybox --install

        # make sure we have vfs mounted
        /bin/busybox mount -t sysfs none /sys
        /bin/busybox mount -t proc  none /proc

        # generate device files
        /bin/busybox mdev -s

        HOME=/root USER=root exec /bin/busybox sh
      '';

      kernel = "${pkgs.linuxPackages_latest.kernel}/bzImage";
      initrd = pkgs.runCommand "build-initrd" { } ''
        mkdir tmp

        # generate the initrd
        (cd tmp;
          mkdir nix/{var,store} -p

          # migrate the store to new rootfs
          closureInfo=${pkgs.closureInfo { rootPaths = pkgs.pkgsMusl.busybox; }}
          cp -Rf $(cat $closureInfo/store-paths) nix/store

          closureInfo=${pkgs.closureInfo { rootPaths = stage1; }}
          cp -Rf $(cat $closureInfo/store-paths) nix/store

          mkdir proc sys dev bin sbin
          ln -s ${pkgs.pkgsMusl.busybox}/bin/busybox bin

          find . | ${pkgs.cpio}/bin/cpio --quiet -H newc -o | gzip -9 -n > $out
        )
      '';

      rootfs = "/tmp/rootfs.img";

      runvm = pkgs.writeScriptBin "runvm" ''
        #!${pkgs.stdenv.shell}

        ${pkgs.closureInfo { rootPaths = pkgs.dinit; }}

        [ -f "${rootfs}" ] || trunscate -s 1G ${rootfs}
        ${pkgs.qemu_kvm}/bin/qemu-kvm -nographic -name singoc \
          -m 2048 -smp 4 -kernel ${kernel} -initrd ${initrd} -drive \
      	format=raw,file=${rootfs} \
      	-append 'root=/dev/ram rdinit=${stage1} console=ttyS0 loglevel=4'
      '';
    in
    {
      packages.x86_64-linux.default = runvm;
    };
}
