# vim: tabstop=2 shiftwidth=2 smartindent expandtab colorcolumn=80
{
  description = "A OS derived from Nix";

  inputs = {
    # pin nixos-24.11-small to avoid meta updateing
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-24.11-small";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = (import nixpkgs {
        system = "x86_64-linux";
      });

      path = pkgs.lib.makeBinPath [
        pkgs.pkgsMusl.vim pkgs.pkgsMusl.dropbear

        (pkgs.pkgsMusl.htop.override({ systemdSupport = false; }))
      ];

      anchios = pkgs.runCommandNoCC "anchios-amd64" { } ''
        mkdir $out && cd $out

        cat <<< '#!/bin/sh

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

        # Set hostname
        echo "anchi-linux" > /proc/sys/kernel/hostname

        [ -e /sys/class/net/eth0 ] || modprobe e1000
        [ -e /sys/class/net/eth0 ] && udhcpc -i eth0

        # keyboard modules
        # The atkbd module is the AT (Advanced Technology) keyboard driver
        # for Linux
        modprobe atkbd &

        # The i8042 module is the Linux driver for the Intel 8042 keyboard
        # controller, which handles PS/2 keyboards and mice.
        modprobe i8042 &

        # Real keyboard?
        modprobe usbhid hid_generic

        mkdir -p /etc/dropbear
        ${pkgs.pkgsMusl.dropbear}/bin/dropbear -B -R

        echo "Welcome to Anchi Linux"
        ' > etc/init.d/rcS
        chmod +x etc/init.d/rcS

        echo '::sysinit:/etc/init.d/rcS'                 >> etc/inittab
        echo '::respawn:/sbin/getty -L ttyS0 115200 vt100' >> etc/inittab
        echo 'tty1::respawn:/sbin/getty 115200 tty1'       >> etc/inittab

        echo '::ctrlaltdel:/sbin/reboot'                 >> etc/inittab

        echo 'root::0:0:root:/root:/bin/sh'              >> etc/passwd
        echo 'user:x:1000:100:user:/home/user:/bin/sh'   >> etc/passwd

        echo "tty:x:5:user"                              >> etc/group
        echo "root:x:0:"                                 >> etc/group
        echo "users:x:100:user"                          >> etc/group

        echo "root::0:0:99999:7:::"                      >> etc/shadow
        hashed=$(${pkgs.openssl}/bin/openssl passwd -6 -salt anchios user)
        echo "user:$hashed:90:0:99999:7:::"              >> etc/shadow

        chmod 644 etc/passwd etc/group
        chmod 640 etc/shadow

        echo "PATH=${path}:\$PATH"                       >> etc/profile.local
        echo "PS1='[\u@\h \w]\$ '"                       >> etc/profile

        mkdir -p home/user && chown 1000:100 -R home/user
      '';

      kernel = "${pkgs.linuxPackages_latest.kernel}/bzImage";
      initrd = pkgs.runCommand "initrd.gz" { } ''
        set -x

        mkdir tmp

        # generate the initrd
        (cd tmp;
          mkdir nix/{var,store} -p

          # migrate the store to new rootfs
          closureInfo=${pkgs.closureInfo { rootPaths = with pkgs.pkgsMusl; [
            busybox vim

            # Using dropbear for its lightweight
            dropbear

            # painful when enabling systemd
            (htop.override({ systemdSupport = false; }))
          ] ++ [
            # pkgs.linuxPackages_latest.kernel
          ] ++ [ anchios ]; }};
          cp -Rf $(cat $closureInfo/store-paths) nix/store

          ln -s ${pkgs.pkgsMusl.busybox}/{bin,sbin,linuxrc} .
          ln -s ${anchios}/etc etc

          moddir=${pkgs.linuxPackages_latest.kernel}/lib/modules
          # e1000 + af_packet - for ethernet to work, without ef_packet,
          # cannot use IPv4. Remaining is used for input(mouse, keyboard)
          for mod in atkbd usbhid usbkbd i8042 e1000 af_packet hid vivaldi-fmap serio libps2; do
            abspath=$(find $moddir -type f -name "$mod.ko.xz")
            relpath=$(cut -d'/' -f5- <<< $abspath)
            [ -z "$abspath" ] && continue
            [ -z "$relpath" ] && continue
            ${pkgs.rsync}/bin/rsync --mkpath $abspath ./$relpath
          done

          for f in $(find $moddir -type f -name "modules.*"); do
            relpath=$(cut -d'/' -f5- <<< $f)
            [ ! -z "$f" ] && [ ! -z "$relpath" ] && \
              ${pkgs.rsync}/bin/rsync --mkpath $f ./$relpath
          done

          # to be able to have correct permission
          ${pkgs.fakeroot}/bin/fakeroot sh -c "find . | ${pkgs.cpio}/bin/cpio \
            --quiet -H newc -o | gzip -9 -n > $out"
        )
      '';

      iso = pkgs.runCommandNoCC "gen-iso" {
        nativeBuildInputs = [ pkgs.grub2_efi pkgs.libisoburn pkgs.mtools ];
      } ''
        set -x

        mkdir -p iso/boot/grub
        mkdir -p iso/EFI/BOOT

        # Copy Kernel and Initramfs
        cp -v ${kernel} iso/boot/vmlinuz
        cp -v ${initrd} iso/boot/initrd.gz

        cat <<-EOF > iso/boot/grub/grub.cfg
        set default=0
        set timeout=5

        insmod progress
        menuentry 'Anchi Linux' --class os {
            linux  /boot/vmlinuz root=/dev/ram rdinit=${anchios}/init
            initrd /boot/initrd.gz
        }
        EOF

        # Create bootable ISO with mkisofs
        grub-mkstandalone \
          --format=x86_64-efi \
          --output=iso/EFI/BOOT/BOOTX64.EFI \
          --modules="normal iso9660 linux search search_fs_uuid ls" \
          "boot/grub/grub.cfg=iso/boot/grub/grub.cfg"
        grub-mkrescue -o $out iso --modules="linux normal iso9660 search \
          search_fs_uuid ls" --compress=xz
      '';

      rootfs = "/tmp/rootfs.img";

      runvm = pkgs.writeShellScriptBin "runvm" ''
        [ -f "${rootfs}" ] || ${pkgs.qemu_kvm}/bin/qemu-img create -f raw \
          ${rootfs} 2G

        ${pkgs.qemu_kvm}/bin/qemu-kvm -name singoc \
          -m 2048 -smp 4 -kernel ${kernel} -initrd ${initrd} \
          -drive format=raw,file=${rootfs} \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 \
          -device e1000,netdev=net0 \
          -append 'root=/dev/ram rdinit=${anchios}/init console=ttyS0,115200 \
            console=tty1 loglevel=4' $@
      '';

      boot-iso = pkgs.writeShellScriptBin "boot-iso" ''
        ${pkgs.qemu_kvm}/bin/qemu-kvm  -name singoc \
          -m 2048 -smp 4 -cdrom ${iso} \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 \
          -device e1000,netdev=net0 \
          -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF.fd \
          -boot d -display gtk $@
      '';

      muslStdenv = (import nixpkgs {
        system = "x86_64-linux";
      }).pkgsMusl.stdenv;
    in
    {
      packages.x86_64-linux.iso = iso;
      packages.x86_64-linux.runvm = runvm;
      packages.x86_64-linux.initrd = initrd;
      packages.x86_64-linux.default = boot-iso;
      packages.x86_64-linux.muslStdenv = muslStdenv;
    };
}
