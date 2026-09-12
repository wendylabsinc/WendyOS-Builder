# The native game-controller contract: the Linux input and HID interfaces every WendyOS
# kernel must expose, and the package each one owes the image when a BSP builds it as a
# module. Read by the kernel include, the kernel packagegroup and the CI validator, so
# the three cannot drift apart.

# Built in, no exceptions. The input and HID cores plus the menu gates the drivers below
# hang off, so an entitled service finds evdev without waiting on a module load — and so
# these are immune to a module package going missing from an image. Kconfig bools can
# only live here, having no modular form and therefore no package.
WENDYOS_GAME_CONTROLLER_BUILTIN = " \
    CONFIG_INPUT \
    CONFIG_INPUT_EVDEV \
    CONFIG_INPUT_JOYSTICK \
    CONFIG_HID \
    CONFIG_HID_GENERIC \
    CONFIG_HIDRAW \
    CONFIG_USB_HID \
    CONFIG_BT_BREDR \
    "

# Built in or modular, either satisfies the contract — but a BSP that resolves one to a
# module owes the image the package named beside it, which is what CI enforces against
# the finished manifest. Transports and vendor quirk drivers belong here: they are only
# needed once a controller is actually attached.
WENDYOS_GAME_CONTROLLER_MODULES = " \
    CONFIG_INPUT_JOYDEV:kernel-module-joydev \
    CONFIG_INPUT_FF_MEMLESS:kernel-module-ff-memless \
    CONFIG_UHID:kernel-module-uhid \
    CONFIG_BT:kernel-module-bluetooth \
    CONFIG_BT_HIDP:kernel-module-hidp \
    CONFIG_JOYSTICK_XPAD:kernel-module-xpad \
    CONFIG_HID_MICROSOFT:kernel-module-hid-microsoft \
    CONFIG_HID_PLAYSTATION:kernel-module-hid-playstation \
    CONFIG_HID_SONY:kernel-module-hid-sony \
    CONFIG_HID_NINTENDO:kernel-module-hid-nintendo \
    CONFIG_HID_LOGITECH:kernel-module-hid-logitech \
    CONFIG_HID_LOGITECH_HIDPP:kernel-module-hid-logitech-hidpp \
    CONFIG_HID_STEAM:kernel-module-hid-steam \
    "
