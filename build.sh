mkdir -p bin bin/dest
set -e

# Create a blank floppy image.
dd if=/dev/zero of=bin/drive.img bs=512 count=2880 status=none

# Assemble and copy the bootloader.
nasm boot.s -f bin -o bin/boot
dd if=bin/boot of=bin/drive.img bs=512 count=1 conv=notrunc status=none

# Assemble the system.
nasm system.s -f bin -o bin/dest/system

# Check the system fits in 32KB.
# The bootloader can't load files greater than a 64KB segment,
# and the system uses the upper 32KB of its segment for buffers.
if [ $(wc -c <bin/dest/system) -ge 32768 ]; then 
	echo "System too large (more than 32KB)."
	exit 1
fi

# Copy the system and other files to the floppy.
gcc -o bin/mkfs mkfs.c
cp *.lisp bin/dest
bin/mkfs bin/drive.img 2880 bin/dest

# Launch the emulator.
qemu-system-x86_64 -drive file=bin/drive.img,index=0,if=floppy,format=raw -boot a
# bochs -f bochs_config.txt -q
