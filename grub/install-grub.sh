#!/bin/bash -e

cd "$(dirname "${BASH_SOURCE[0]}")"
source "../config.sh"
source "./grub-modules.sh"

grub-install \
	--efi-directory=/boot/efi/ \
	--sbat=sbat.csv \
	--modules="$GRUB_MODULES" \
	--no-nvram \
	--no-bootsector \
	--no-uefi-secure-boot \
	--bootloader-id=BOOT

sbsign \
	--key "$MOK_KEY" \
	--cert "$MOK_PEM" \
	--output /boot/efi/EFI/BOOT/grubx64.efi \
	/boot/efi/EFI/BOOT/grubx64.efi
