obj-m := wendyos_hello.o

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR)

clean:
	rm -f *.o *~ core .depend .*.cmd *.ko *.mod.c *.mod
	rm -f Module.markers Module.symvers modules.order
	rm -rf .tmp_versions
