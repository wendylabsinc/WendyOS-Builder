# RPi additions to wendyos-image. The A/B disk layout itself comes from the
# hand-authored rpi-wendy-ab*.wks (WKS_FILE in each machine conf); nothing
# image-side needs to reorder partitions or patch fstab — rpi-wendy-fstab
# mounts /boot by LABEL and /config by the /dev/wendyos/config link
# (rpi-wendy-mbr-fstab on RPi3 mounts both by LABEL).
