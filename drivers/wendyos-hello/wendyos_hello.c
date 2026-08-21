// SPDX-License-Identifier: GPL-2.0-only
//
// Trivial out-of-tree module used to validate the WendyOS driver add-on pipeline
// (compile -> sysext .raw -> merge -> depmod -> modprobe) end to end, without
// needing real accelerator hardware. Stand-in for a vendor driver.

#include <linux/module.h>
#include <linux/init.h>

static int __init wendyos_hello_init(void)
{
	pr_info("wendyos_hello: driver add-on loaded (sysext pipeline OK)\n");
	return 0;
}

static void __exit wendyos_hello_exit(void)
{
	pr_info("wendyos_hello: driver add-on unloaded\n");
}

module_init(wendyos_hello_init);
module_exit(wendyos_hello_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("WendyOS sysext driver-pipeline self-test module");
MODULE_AUTHOR("WendyOS");
