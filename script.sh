#!/bin/bash

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "./config.sh"

TRUSTED_BOOT_KEY="/boot/trusted-boot-key"

BOOT_INFO_DIR="/boot/.tpm2-luks-helper/boot-info"
BOOT_INFO_CMDLINE="cmdline.txt"
BOOT_INFO_INITRAMFS_HASH="initramfs-hash.txt"
BOOT_INFO_GRUB_HASH="grub-hash.txt"

function get_grub_first_cmdline() {
	cat /boot/grub/grub.cfg | grep "$(echo -ne "^\tlinux\t")" | cut -f3 | cut -d' ' -f1 --complement | xargs
}

function get_grub_first_initramfs_hash() {
	# The path is like /initrd.img-5.15.74-1-pve
	PATH_RELATIVE_TO_BOOT="$(cat /boot/grub/grub.cfg | grep "$(echo -ne "^\tinitrd\t")" | cut -f3)"
	PATH_FULL="/boot/$PATH_RELATIVE_TO_BOOT"
	if [[ -f "$PATH_FULL" ]]; then
		HASH_VALUE="$(md5sum "$PATH_FULL" | cut -d' ' -f1)"
		echo "$PATH_FULL:$HASH_VALUE"
	fi
}

function get_grub_hash() {
	md5sum /boot/efi/EFI/BOOT/grubx64.efi | cut -d' ' -f1
}

function check_next_boot() {
	if [[ -f "$TRUSTED_BOOT_KEY" ]]; then
		echo "Trust next boot enabled."
		return 0
	fi

	CURRENT_CMDLINE="$(cat "$BOOT_INFO_DIR/$BOOT_INFO_CMDLINE")"
	CURRENT_INITRAMFS_HASH="$(cat "$BOOT_INFO_DIR/$BOOT_INFO_INITRAMFS_HASH")"
	CURRENT_GRUB_HASH="$(cat "$BOOT_INFO_DIR/$BOOT_INFO_GRUB_HASH")"

	NEXT_BOOT_CMDLINE="$(get_grub_first_cmdline)"
	NEXT_BOOT_INITRAMFS_HASH="$(get_grub_first_initramfs_hash)"
	NEXT_BOOT_GRUB_HASH="$(get_grub_hash)"

	function fail() {
		echo "Check failed: $1 changed"
		echo "  -   Current: \"$2\""
		echo "  - Next boot: \"$3\""
		echo "Please run \"tpm2-luks-helper trust-next-boot\" and do a *attended* reboot."
		return 1
	}

	if [[ "$CURRENT_CMDLINE" != "$NEXT_BOOT_CMDLINE" ]]; then
		fail cmdline "$CURRENT_CMDLINE" "$NEXT_BOOT_CMDLINE"
	elif [[ "$CURRENT_INITRAMFS_HASH" != "$NEXT_BOOT_INITRAMFS_HASH" ]]; then
		fail initramfs "$CURRENT_INITRAMFS_HASH" "$NEXT_BOOT_INITRAMFS_HASH"
	elif [[ "$CURRENT_GRUB_HASH" != "$NEXT_BOOT_GRUB_HASH" ]]; then
		fail grub "$CURRENT_GRUB_HASH" "$NEXT_BOOT_GRUB_HASH"
	fi
}

# Disable LUKS temporarily for new initramfs/cmdline
function trust_next_boot() {
	if [[ -f "$TRUSTED_BOOT_KEY" ]]; then
		echo "Trust next boot already enabled."
		return 0
	fi

	# Generate key
	(tpm2_getrandom --hex 32; tpm2_getrandom --hex 32) > "$TRUSTED_BOOT_KEY"
	for LUKS_DEVICE in $LUKS_DEVICES; do
		cryptsetup luksAddKey "$LUKS_DEVICE" "$TRUSTED_BOOT_KEY" \
			--key-file "$LUKS_KEY" \
			--pbkdf-force-iterations=4 \
			--pbkdf-parallel=1 \
			--pbkdf-memory=32
	done
}

function on_boot() {
	# Revoke trust_next_boot
	if [[ -f "$TRUSTED_BOOT_KEY" ]]; then
		echo "Trusted boot detected. Revoking."
		for LUKS_DEVICE in $LUKS_DEVICES; do
			cryptsetup luksRemoveKey "$LUKS_DEVICE" --key-file "$TRUSTED_BOOT_KEY"
		done
		rm "$TRUSTED_BOOT_KEY"
	fi

	# Save boot info
	rm -rf -- "$BOOT_INFO_DIR"
	mkdir -p "$BOOT_INFO_DIR"
	cat /proc/cmdline | cut -d' ' -f1 --complement > "$BOOT_INFO_DIR/$BOOT_INFO_CMDLINE"
	get_grub_first_initramfs_hash > "$BOOT_INFO_DIR/$BOOT_INFO_INITRAMFS_HASH"
	get_grub_hash > "$BOOT_INFO_DIR/$BOOT_INFO_GRUB_HASH"
	echo "Saved boot info:"
	echo "  - cmdline: \"$(cat "$BOOT_INFO_DIR/$BOOT_INFO_CMDLINE")\""
	echo "  - initramfs (first entry): $(cat "$BOOT_INFO_DIR/$BOOT_INFO_INITRAMFS_HASH")"
	echo "  - grub: $(cat "$BOOT_INFO_DIR/$BOOT_INFO_GRUB_HASH")"

	# Reseal LUKS key
	echo "Resealing LUKS key"
	tpm2-initramfs-tool seal --data "$(cat "$LUKS_KEY")" --pcrs "$TPM2_PCRS" > /dev/null
}

function sign_kernels() {
	for KERNEL_FILE in /boot/vmlinuz*; do
		echo Checking kernel "$KERNEL_FILE" for Secure Boot signature
		if ! sbverify --cert "$MOK_PEM" "$KERNEL_FILE"; then
			echo "Trying to sign kernel $KERNEL_FILE"
			sbsign --key "$MOK_KEY" --cert "$MOK_PEM" --output "$KERNEL_FILE" "$KERNEL_FILE"
		fi
	done
}

# Determine the command to execute
if [[ "$1" == "check-next-boot" ]]; then
	check_next_boot
elif [[ "$1" == "trust-next-boot" ]]; then
	trust_next_boot
elif [[ "$1"  == "on-boot" ]]; then
	on_boot
elif [[ "$1" == "sign-kernels" ]]; then
	sign_kernels
fi
