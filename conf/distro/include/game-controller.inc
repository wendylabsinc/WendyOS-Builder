# The game-controller contract: the input and HID interfaces every shipping kernel must
# expose. Read by the kernel include, the packagegroup and the CI check, so the three
# cannot drift apart.

# Must resolve to =y: the cores and the menu gates the drivers below hang off, so nothing
# races a module load and no missing package can take them out.
WENDYOS_GAME_CONTROLLER_BUILTIN = " \
    CONFIG_INPUT \
    CONFIG_INPUT_EVDEV \
    CONFIG_INPUT_JOYSTICK \
    CONFIG_HID \
    CONFIG_HID_GENERIC \
    CONFIG_HIDRAW \
    CONFIG_USB \
    CONFIG_USB_HID \
    CONFIG_BT_BREDR \
    CONFIG_NEW_LEDS \
    CONFIG_LEDS_CLASS \
    "

# =y or =m both satisfy the contract, but a symbol that came out modular owes the image
# the package named beside it.
WENDYOS_GAME_CONTROLLER_MODULES = " \
    CONFIG_INPUT_JOYDEV:kernel-module-joydev \
    CONFIG_INPUT_FF_MEMLESS:kernel-module-ff-memless \
    CONFIG_UHID:kernel-module-uhid \
    CONFIG_BT:kernel-module-bluetooth \
    CONFIG_BT_HIDP:kernel-module-hidp \
    CONFIG_LEDS_CLASS_MULTICOLOR:kernel-module-led-class-multicolor \
    CONFIG_JOYSTICK_XPAD:kernel-module-xpad \
    CONFIG_HID_MICROSOFT:kernel-module-hid-microsoft \
    CONFIG_HID_PLAYSTATION:kernel-module-hid-playstation \
    CONFIG_HID_SONY:kernel-module-hid-sony \
    CONFIG_HID_NINTENDO:kernel-module-hid-nintendo \
    CONFIG_HID_LOGITECH:kernel-module-hid-logitech \
    CONFIG_HID_LOGITECH_HIDPP:kernel-module-hid-logitech-hidpp \
    CONFIG_HID_STEAM:kernel-module-hid-steam \
    "
