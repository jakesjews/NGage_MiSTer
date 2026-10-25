#!/bin/zsh
# A persistent Quartus container on the Ubuntu server that owns the DE10-nano's
# USB-Blaster II and runs the JTAG server, for SignalTap and the programmer.
#   ssh ubuntu 'dev/mister/NGage_MiSTer/tools/jtag-server.sh start'   # start jtagd
#   ssh ubuntu 'dev/mister/NGage_MiSTer/tools/jtag-server.sh chain'   # list the chain
#   ssh ubuntu 'dev/mister/NGage_MiSTer/tools/jtag-server.sh stp ARGS' # quartus_stp ...
#   ssh ubuntu 'dev/mister/NGage_MiSTer/tools/jtag-server.sh stop'
# The container runs as root, so no host udev rule is needed for it; the rule
# below only matters for host-side users. The cable enumerates as 09fb:6810
# until jtagd loads its firmware, then re-enumerates as 09fb:6010 "DE-SoC";
# jtagd needs libudev.so.0 to notice that (the symlink in start), else restart.
# Chain on 2026-10-25: "DE-SoC [3-1]: 4BA00477 SOCVHPS, 02D020DD 5CSEBA6".
# Host udev rule (optional, with sudo),
#   /etc/udev/rules.d/51-usbblaster.rules:
#     SUBSYSTEM=="usb", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6810", MODE="0666"
#     SUBSYSTEM=="usb", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6800", MODE="0666"
#     SUBSYSTEM=="usb", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6010", MODE="0666"
#   then: sudo udevadm control --reload-rules && sudo udevadm trigger
set -e
image=theypsilon/quartus-lite-c5:17.0.2.docker0
name=ngage-jtag
q=/opt/intelFPGA_lite/quartus/bin
dir=${BUILD_DIR:-dev/mister/NGage_MiSTer}
case "${1:-chain}" in
  start)
    docker rm -f $name >/dev/null 2>&1 || true
    docker run -d --name $name --device=/dev/bus/usb -v /dev/bus/usb:/dev/bus/usb \
      -v $HOME/$dir:/project -w /project --network host $image \
      bash -c "ln -sf /lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libudev.so.0; $q/jtagd --foreground --user-start" >/dev/null
    sleep 2; docker exec $name $q/jtagconfig ;;
  chain) docker exec $name $q/jtagconfig ;;
  stp) shift; docker exec $name $q/quartus_stp "$@" ;;
  pgm) shift; docker exec $name $q/quartus_pgm "$@" ;;
  stop) docker rm -f $name ;;
  *) echo "usage: $0 start|chain|stp ARGS|pgm ARGS|stop"; exit 1 ;;
esac
