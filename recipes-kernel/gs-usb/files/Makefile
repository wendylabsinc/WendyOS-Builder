obj-m := gs_usb.o
all:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) modules
modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) modules_install
