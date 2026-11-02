obj-m += gpu_blit.o
KDIR ?= /data/zcu106-riscv/linux
CROSS ?= riscv64-linux-gnu-
all:
	$(MAKE) -C $(KDIR) ARCH=riscv CROSS_COMPILE=$(CROSS) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) ARCH=riscv CROSS_COMPILE=$(CROSS) M=$(CURDIR) clean
