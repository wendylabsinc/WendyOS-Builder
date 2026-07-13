# RPi additions to wendyos-image. The A/B disk layout itself comes from the
# hand-authored rpi-wendy-ab*.wks (WKS_FILE in each machine conf); nothing
# image-side needs to reorder partitions or patch fstab — rpi-wendy-fstab
# mounts /config and /boot by LABEL.
