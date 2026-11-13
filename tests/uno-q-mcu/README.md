# UNO Q microcontroller helpers

`run.py` runs `mcu-gpio` and `mcu-flash` from
`meta-arduino-extensions/recipes-bsp/wendyos-mcu/files/` against stub
`gpiodetect`, `gpioset`, `gpioinfo`, `openocd` and `systemctl`, which record
their arguments. It checks the contract the agent relies on: the `--layouts`
line, BOOT0 driven low before OpenOCD, the OpenOCD arguments, the final
`wendy-mcu-status` JSON line and the exit codes (0 ok, 2 bad input, 3 GPIO,
4 OpenOCD).

    python3 tests/uno-q-mcu/run.py

No hardware or bitbake needed. The real flash is checked on a board.
