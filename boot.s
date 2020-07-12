[bits 16]
[org 0x7C00]
[cpu 386]

; Memory map:
; 0x500-0x700: filesystem header
; 0x700-0x900: sector table buffer
; 0x900-0xB00: file sector buffer
; 0x7000-0x7C00: stack
; 0x7C00-0x7E00: this code
; 0x10000-0x20000: loaded program

start:
	; Setup segment registers and the stack.
	cli
	xor	ax,ax
	mov	ds,ax
	mov	ss,ax
	mov	sp,0x7C00 ; Put stack below the code.
	sti
	cld
	jmp	0x0000:.set_cs
	.set_cs:

	; Save the BIOS drive number.
	mov	[drive_number],dl

	; Print a loading message.
	mov	si,loading_message
	call	print_string

	; Get drive parameters.
	mov	ah,0x08
	mov	dl,[drive_number]
	xor	di,di
	int	0x13
	mov	si,error_read
	jc	error
	and	cx,31
	mov	[max_sectors],cx
	inc	dh
	shr	dx,8
	mov	[max_heads],dx

	; Load the filesystem header.
	xor	ax,ax
	mov	es,ax
	mov	di,1
	mov	bx,0x500
	call	load_sector

	; Check for correct signature and version.
	mov	si,error_disk
	mov	ax,[0x500]
	cmp	ax,0x706C
	jne	error
	mov	ax,[0x502]
	cmp	ax,1
	jne	error

	; Load the root directory.
	mov	ax,[0x51C]
	mov	[file_remaining_size],ax
	mov	ax,[0x520]
	mov	[current_sector],ax
	mov	di,ax
	xor	ax,ax
	mov	es,ax
	mov	bx,0x900
	call	load_sector

	; Scan the root directory.
	xor	bx,bx
	.scan_root_directory:
	cmp	bx,0x200
	jne	.loaded_sector
	call	next_file_sector
	xor	bx,bx
	.loaded_sector:

	; Compare file name.
	xor	ax,ax
	mov	es,ax
	mov	cx,7
	mov	si,program_name
	mov	di,0x900
	add	di,bx
	rep	cmpsb
	jne	.next_entry

	; Save the startup program's first sector, size and checksum.
	mov	al,[0x917 + bx]
	mov	[checksum],al
	mov	ax,[0x910 + bx]
	mov	[file_remaining_size],ax
	mov	di,[0x914 + bx]
	mov	[current_sector],di
	jmp	.load_startup_program

	; Go to the next entry.
	.next_entry:
	add	bx,0x20
	sub	word [file_remaining_size],0x20
	cmp	word [file_remaining_size],0
	jne	.scan_root_directory
	mov	si,error_disk
	jmp	error

	; Load the startup program.
	.load_startup_program:
	xor	bx,bx
	mov	es,bx
	mov	bx,0x900
	call	load_sector

	; Copy the sector to the destination.
	.copy_sector:
	mov	bx,0x1000
	mov	es,bx
	mov	di,[file_destination]
	mov	si,0x900
	mov	cx,0x200
	rep	movsb

	; Calculate checksum.
	mov	bl,[checksum]
	mov	si,0x900
	mov	cx,0x200
	.checksum_loop:
	lodsb
	xor	bl,al
	loop	.checksum_loop
	mov	[checksum],bl

	; Load the next sector of the startup program.
	add	word [file_destination],0x200
	mov	ax,[file_remaining_size]
	cmp	ax,0x200
	jbe	.launch

	sub	word [file_remaining_size],0x200
	call	next_file_sector
	jmp	.copy_sector

	; Launch the startup program.
	.launch:
	mov	si,error_disk
	cmp	byte [checksum],0
	jne	error
	mov	dl,[drive_number]
	jmp	0x1000:0x0000

next_file_sector:
	; Do we need to switch the sector table buffer?
	mov	ax,[current_sector]
	shr	ax,8 ; 256 sector table entries per sector
	cmp	al,[current_sector_table]
	je	.skip_switch
	mov	[current_sector_table],al

	; Load the new sector table buffer.
	add	ax,2
	mov	di,ax
	xor	bx,bx
	mov	es,bx
	mov	bx,0x700
	call	load_sector
	.skip_switch:

	; Get the next sector.
	mov	bx,[current_sector]
	and	bx,0xFF
	shl	bx,1
	mov	di,[0x700 + bx]
	mov	[current_sector],di

	; Load the next sector.
	xor	bx,bx
	mov	es,bx
	mov	bx,0x900
	jmp	load_sector

; di - LBA.
; es:bx - buffer
load_sector:
	mov	byte [read_attempts],5

	.try_again:

	mov	si,error_read
	mov	al,[read_attempts]
	or	al,al
	jz	error
	dec	byte [read_attempts]

	; Calculate cylinder and head.
	mov	ax,di
	xor	dx,dx
	div	word [max_sectors]
	xor	dx,dx
	div	word [max_heads]
	push	dx ; remainder - head
	mov	ch,al ; quotient - cylinder
	shl	ah,6
	mov	cl,ah

	; Calculate sector.
	mov	ax,di
	xor	dx,dx
	div	word [max_sectors]
	inc	dx
	or	cl,dl

	; Load the sector.
	pop	dx
	mov	dh,dl
	mov	dl,[drive_number]
	mov	ax,0x0201
	int	0x13
	jc	.try_again

	ret

; ds:si - zero-terminated string.
error:
	call	print_string
	jmp	$

; ds:si - zero-terminated string.
print_string:
	lodsb
	or	al,al
	jz	.done
	mov	ah,0xE
	int	0x10
	jmp	print_string
	.done:	ret

file_destination:
	dw 0
current_sector_table:
	db 0xFF

error_read:
	db "Cannot read boot disk.",0
error_disk:
	db "Corrupt boot disk.",0
program_name:
	db "system",0 ; don't forget to change name length in comparison!
loading_message:
	db 'Loading... ',0

times (0x1FE - $ + $$) nop
dw 0xAA55

; Uninitialised variables outside the boot image.
drive_number:
	db 0
read_attempts:
	db 0
max_sectors:
	dw 0
max_heads:
	dw 0
current_sector:
	dw 0
file_remaining_size:
	dw 0
checksum:
	db 0
