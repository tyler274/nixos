#!/usr/bin/env bash
for ds in steam anime-game-launcher honkers-railway-launcher sleepy-launcher wavey-launcher; do
  case $ds in steam) mp=steam ;; *) mp=$ds ;; esac
  zfs create -o canmount=noauto \
             -o com.sun:auto-snapshot=false \
             -o mountpoint=/home/luluco/.local/share/$mp \
             rpool/nixos/home/luluco/$ds
done

