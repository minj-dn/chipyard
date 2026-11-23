# RISCV environment variable must be set
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# Override BUILD_DIR to keep variant ROMs (e.g. dual boot) apart from the default one
BUILD_DIR ?= $(ROOT_DIR)/build

# Extra -D flags, e.g. BOOT_DEFS='-DDUALBOOT -DPAYLOAD_SIZE_B=0x2000 -DSPI_CLK=25000'
BOOT_DEFS ?=

CC=$(RISCV)/bin/riscv64-unknown-elf-gcc
OBJCOPY=$(RISCV)/bin/riscv64-unknown-elf-objcopy
OBJDUMP=$(RISCV)/bin/riscv64-unknown-elf-objdump
CFLAGS=-march=rv64ima_zicsr_zifencei -mcmodel=medany -O2 -std=gnu11 -Wall -nostartfiles
CFLAGS+= -fno-common -g -DENTROPY=0 -mabi=lp64 -DNONSMP_HART=0
CFLAGS+= -I $(ROOT_DIR)/include -I.
CFLAGS+= $(BOOT_DEFS)
LFLAGS=-static -nostdlib -L $(ROOT_DIR)/linker -T sdboot.elf.lds

# default to 1MHz but really should be overridden
PBUS_CLK ?= 1000000

default: elf bin dump

elf := $(BUILD_DIR)/sdboot.elf
$(elf): head.S kprintf.c sd.c $(BUILD_DIR)/boot_defs
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -DTL_CLK="$(PBUS_CLK)UL" $(LFLAGS) -o $@ head.S sd.c kprintf.c

# Rebuild when BOOT_DEFS or PBUS_CLK change
$(BUILD_DIR)/boot_defs: FORCE
	@mkdir -p $(BUILD_DIR)
	@echo '$(BOOT_DEFS) PBUS_CLK=$(PBUS_CLK)' | cmp -s - $@ || echo '$(BOOT_DEFS) PBUS_CLK=$(PBUS_CLK)' > $@

.PHONY: FORCE
FORCE:

.PHONY: elf
elf: $(elf)

bin := $(BUILD_DIR)/sdboot.bin
$(bin): $(elf)
	mkdir -p $(BUILD_DIR)
	$(OBJCOPY) -O binary --change-addresses=-0x10000 $< $@

.PHONY: bin
bin: $(bin)

dump := $(BUILD_DIR)/sdboot.dump
$(dump): $(elf)
	$(OBJDUMP) -D -S $< > $@

.PHONY: dump
dump: $(dump)

.PHONY: clean
clean::
	rm -rf $(BUILD_DIR)
