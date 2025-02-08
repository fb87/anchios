# vim: tabstop=2 shiftwidth=2 smartindent expandtab colorcolumn=80
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
          closureInfo=${pkgs.closureInfo { rootPaths = with pkgs.pkgsMusl; [
            busybox vim openssh
          ] ++ [
            pkgs.linuxPackages_latest.kernel
          ]; }};

          cp -Rf $(cat $closureInfo/store-paths) nix/store

          cat <<< '#!/bin/sh
          #!/bin/busybox sh

          mkdir /proc /sys /dev -p

          # Mount essential filesystems
          mount -t proc none         /proc
          mount -t sysfs none        /sys
          mount -t devtmpfs none     /dev

          mkdir -p /dev/pts /dev/shm
          mount -t tmpfs tmpfs       /dev/shm
          mount -t devpts devpts     /dev/pts

          chown root:tty /dev/tty    /dev/tty[1-4]
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

          [ -e /sys/class/net/eth0 ] || modprobe e1000
          [ -e /sys/class/net/eth0 ] && udhcpc -i eth0

          mkdir -p /var/empty
          ${pkgs.pkgsMusl.openssh}/bin/ssh-keygen -A
          ${pkgs.pkgsMusl.openssh}/bin/sshd -D &

          echo "Welcome to Anchi Linux"
          ' > etc/init.d/rcS
          chmod +x etc/init.d/rcS

          echo '::sysinit:/etc/init.d/rcS'                 >> etc/inittab
          echo '::respawn:/sbin/getty -L ttyS0 9600 vt100' >> etc/inittab
          echo 'tty1::respawn:/sbin/getty 38400 tty1'      >> etc/inittab
          echo '::ctrlaltdel:/sbin/reboot'                 >> etc/inittab

          echo 'root::0:0:root:/root:/bin/sh'              >> etc/passwd
          echo 'sshd:x:74:74:::'                           >> etc/passwd
          echo 'user:x:1000:100:user:/home/user:/bin/sh'   >> etc/passwd

          echo "tty:x:5:user"                              >> etc/group
          echo "root:x:0:"                                 >> etc/group
          echo "sshd:x:74:"                                >> etc/group
          echo "users:x:100:user"                          >> etc/group

          echo "root::0:0:99999:7:::"                      >> etc/shadow
          hashed=$(${pkgs.openssl}/bin/openssl passwd -6 -salt anchios user)
          echo "user:$hashed:90:0:99999:7:::"              >> etc/shadow

          chmod 644 etc/passwd etc/group
          chmod 640 etc/shadow

          echo "PS1='[\u@\h \w]\$ '"                       >> etc/profile

          ln -s ${pkgs.pkgsMusl.busybox}/{bin,sbin,linuxrc} .

          mkdir -p etc/ssh
          cat <<< '
          PermitEmptyPasswords   yes
          Port                   22
          PermitRootLogin        yes
          PasswordAuthentication yes
          ' > etc/ssh/sshd_config

          mkdir -p lib
          ln -s ${pkgs.linuxPackages_latest.kernel}/lib/modules lib

          mkdir -p home/user && chown 1000:100 -R home/user

          # to be able to have correct permission
          fakeroot sh -c "find . | ${pkgs.cpio}/bin/cpio --quiet -H newc -o | gzip -9 -n > $out"
        )
      '';

      iso = pkgs.runCommandNoCC "gen-iso" ''
      '';

      rootfs = "/tmp/rootfs.img";

      runvm = pkgs.writeShellScriptBin "runvm" ''
        [ -f "${rootfs}" ] || ${pkgs.qemu_kvm}/bin/qemu-img create -f raw ${rootfs} 2G
        ${pkgs.qemu_kvm}/bin/qemu-kvm -nographic -name singoc \
          -m 2048 -smp 4 -kernel ${kernel} -initrd ${initrd} \
          -drive format=raw,file=${rootfs} \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 \
          -device e1000,netdev=net0 \
          -append 'root=/dev/ram rdinit=/init console=ttyS0,115200 loglevel=4'
      '';
    in
    {
      packages.x86_64-linux.default = runvm;
    };
}
