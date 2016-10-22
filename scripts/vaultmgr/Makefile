TOP:=$(shell pwd)

LUKS_VAULT:=$(shell find $(TOP)/../ -maxdepth 1 -name '*-vault.luks' | head -n1)
ifeq ($(LUKS_VAULT), ) 
    $(error Cannot find a LUKS encrypted file.)
endif
LUKS_VAULT_NAME:=$(notdir $(LUKS_VAULT))

all: mount

open:
	cp $(LUKS_VAULT) $(TOP)
	sudo -k cryptsetup luksOpen $(LUKS_VAULT) gpg-vault

mount: open
	mkdir $(TOP)/vault
	sudo -k mount /dev/mapper/gpg-vault $(TOP)/vault

umount:
	sudo -k umount $(TOP)/vault && sync
	rmdir $(TOP)/vault

close: umount
	sudo -k cryptsetup luksClose gpg-vault
	md5sum $(TOP)/$(LUKS_VAULT_NAME) > $(TOP)/$(LUKS_VAULT_NAME).md5
