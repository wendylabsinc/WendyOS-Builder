# Both Unitree carriers use the module EEPROM and omit the separate carrier EEPROM.
wendy_install_unitree_mb2_bct() {
    flashdir="${D}${datadir}/tegraflash"
    stock="$flashdir/tegra234-mb2-bct-misc-p3767-0000.dts"
    if [ "$(grep -cE '^[[:space:]]*cvb_eeprom_read_size[[:space:]]*=[[:space:]]*<0x100>;' "$stock")" != 1 ]; then
        bbfatal "${MACHINE}: unexpected CVB EEPROM size in $stock"
    fi
    sed -E 's/(^[[:space:]]*cvb_eeprom_read_size[[:space:]]*=[[:space:]]*)<0x100>;/\1<0x0>;/' \
        "$stock" > "$flashdir/${TEGRA_FLASHVAR_MB2BCT_CFG}"
}

do_install:append:unitree-g1-pc2-orin-nx() {
    wendy_install_unitree_mb2_bct
}

do_install:append:unitree-go2-orin-nx() {
    wendy_install_unitree_mb2_bct
    flashdir="${D}${datadir}/tegraflash"

    # The factory image switches PP.06 to push-pull GPIO before asserting
    # USB-A VBUS. Set the pad in MB1 and let the kernel regulator own the line.
    cat > "$flashdir/${TEGRA_FLASHVAR_PINMUX_CONFIG}" <<'EOF'
#include "tegra234-mb1-bct-pinmux-p3767-dp-a03.dtsi"

/ {
	pinmux@2430000 {
		common {
			soc_gpio25_pp6 {
				nvidia,pull = <TEGRA_PIN_PULL_DOWN>;
				nvidia,tristate = <TEGRA_PIN_DISABLE>;
				nvidia,enable-input = <TEGRA_PIN_DISABLE>;
				nvidia,io-high-voltage = <TEGRA_PIN_DISABLE>;
			};
		};
	};
};
EOF
}
