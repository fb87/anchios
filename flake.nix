{
  description = "A OS derived from Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-24.11-small";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      kernel = "${pkgs.linuxPackages_latest.kernel}/bzImage";
      initrd = pkgs.runCommand "build-initrd" { buildInputs = [ pkgs.fakeroot ]; } ''
        mkdir tmp

        # generate the initrd
        (cd tmp;
          mkdir nix/{var,store} -p

          # migrate the store to new rootfs
          closureInfo=${pkgs.closureInfo { rootPaths = pkgs.pkgsMusl.busybox; }}
          cp -Rf $(cat $closureInfo/store-paths) nix/store

          cat <<< '#!/bin/sh
          #!/bin/busybox sh

          mkdir /proc /sys /dev -p

          # Mount essential filesystems
          mount -t proc none     /proc
          mount -t sysfs none    /sys
          mount -t devtmpfs none /dev

          mkdir -p /dev/pts /dev/shm
          mount -t tmpfs tmpfs   /dev/shm
          mount -t devpts devpts /dev/pts

	  chown root:tty /dev/tty /dev/tty[1-4]
          chmod 620 /dev/tty[1-4]

          # Switch to the real init
          exec /sbin/init
          ' > init
          chmod +x init

          mkdir -p etc/init.d
          cat <<< '#!/bin/sh
          #!/bin/sh

          # Set hostname
          echo "anchi-linux" > /proc/sys/kernel/hostname

          echo "Welcome to Anchi Linux"
          ' > etc/init.d/rcS
          chmod +x etc/init.d/rcS

          echo '::sysinit:/etc/init.d/rcS'                 >> etc/inittab
          echo '::respawn:/sbin/getty -L ttyS0 9600 vt100' >> etc/inittab
	  echo 'tty1::respawn:/sbin/getty 38400 tty1'      >> etc/inittab
          echo '::ctrlaltdel:/sbin/reboot'                 >> etc/inittab

          echo 'root::0:0:root:/root:/bin/sh'              >> etc/passwd
          echo 'user::1000:100:user:/home/user:/bin/sh'    >> etc/passwd
	  echo "tty:x:5:"                                  >> etc/group
	  echo "root:x:0:"                                 >> etc/group
	  echo "users:x:100:"                              >> etc/group

	  chmod 644 etc/passwd etc/group

	  echo "PS1='[\u@\h \w]\$ '"                       >> etc/profile

          ln -s ${pkgs.pkgsMusl.busybox}/{bin,sbin,linuxrc} .

          # to be able to have correct permission
          fakeroot sh -c "find . | ${pkgs.cpio}/bin/cpio --quiet -H newc -o | gzip -9 -n > $out"
        )
      '';

      rootfs = "/tmp/rootfs.img";

      runvm = pkgs.writeShellScriptBin "runvm" ''
        [ -f "${rootfs}" ] || trunscate -s 1G ${rootfs}
        ${pkgs.qemu_kvm}/bin/qemu-kvm -nographic -name singoc \
          -m 2048 -smp 4 -kernel ${kernel} -initrd ${initrd} \
          -drive format=raw,file=${rootfs} \
          -append 'root=/dev/ram rdinit=/init console=ttyS0,115200 loglevel=4'
      '';
    in
    {
      packages.x86_64-linux.default = runvm;
    };
}
