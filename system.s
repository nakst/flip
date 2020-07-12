[bits 16]
[org 0]
[cpu 386]

; Memory map:
; 0x500-0x8000: all list (SS)
; 0x8000-0x10000: stack (SS)
; 0x10000-0x18000: system code (CS/DS)
; 0x18000-0x20000: system data (DS)
; 0x20000-0x30000: objects (FS)
; 0x30000-0x40000: strings (GS)
; 0x40000-0x50000: environment relinking

%define ADDITIONAL_DATA      (0x8000)
%define INPUT_BUFFER_SIZE    (0x200)
%define INPUT_BUFFER         (ADDITIONAL_DATA)
%define MAX_OPEN_FILES       (8)
%define SECTOR_SIZE          (0x200)
%define OPEN_FILE_BUFFER     (INPUT_BUFFER + INPUT_BUFFER_SIZE)
%define SECTOR_TABLE_BUFFER  (OPEN_FILE_BUFFER + SECTOR_SIZE * MAX_OPEN_FILES)
%define FS_HEADER_BUFFER     (SECTOR_TABLE_BUFFER + SECTOR_SIZE)
%define TYPE_BUFFER_SIZE     (0x100)
%define TYPE_BUFFER          (FS_HEADER_BUFFER + SECTOR_SIZE)
%define PRIOR_INPUT_BUFFER   (TYPE_BUFFER + TYPE_BUFFER_SIZE)

; Standard file open modes:
%define FILE_READ   (1)
%define FILE_WRITE  (2)
%define FILE_APPEND (3)

; Special file open modes:
%define FILE_RENAME (4)
%define FILE_DELETE (5)

; File flags.
%define FILE_ERROR  (0x80)

; 0  position in root directory
; 2  (remaining) file size low
; 4  (remaining) file size high
; 6  offset into sector
; 8  current sector
; 10 access mode (0 if handle unused)
; 11 checksum
%define DATA_PER_OPEN_FILE (12)
%define ROOT_HANDLE ((MAX_OPEN_FILES - 1) * DATA_PER_OPEN_FILE + open_file_table)

%define SCREEN_COLOR    (0x0700)
%define HIGHLIGHT_COLOR (0x1700)
%define ALT_COLOR       (0x2F00)
%define ALT2_COLOR      (0x3F00)
%define ALT3_COLOR      (0x1F00)
%define ERROR_COLOR     (0x4F00)

; If the stack pointer goes below this value then we assume it's about to overflow.
; We need a reasonable margin before the all list begins,
; since the stack is also used by the BIOS's interrupt handlers.
%macro CHECK_STACK_OVERFLOW 0
	cmp	sp,0x8200
	jb	error_stack_overflow
%endmacro

; Call the garbage collector before every object/string allocation.
; This is used to ensure that the all list is correct,
; so that only truly inaccessible objects are freed.
; %define ALWAYS_GC

; The all list is a stack of objects that shouldn't be freed.
; It grows down and uses SS, much like the actual stack.
; Its position is kept in BP, throughout all functions that need it.
; The symbol table is not kept in the all list.
%define ALL_LIST_TOP (0x8000)
%define ALL_POP(x) add bp,2*x

%macro ALL_PUSH 1 
	sub	bp,2
	cmp	bp,0x500
	je	error_stack_overflow
	mov	[ss:bp],%1
%endmacro

; Each object is 4 bytes. Object 0 is nil.
; Bit 0 of the first word is used by the garbage collector.
; Bit 1 of the first word is set if the object is not a pair.
; The first word is used by pairs to store car, otherwise to store the object type.
; The second word stores object data. For pairs, this is cdr.
%define OBJ_SIZE     (4)
%define TYPE_FREE    (0x06)
%define TYPE_INT     (0x0A)
%define TYPE_STRING  (0x0E)
%define TYPE_LAMBDA  (0x12)
%define TYPE_SYMBOL  (0x16)
%define TYPE_BUILTIN (0x1A)
%define TYPE_NIL     (0x1E)
%define TYPE_MACRO   (0x22)
%define CAR(d,s)     mov d,[fs:s + 0]
%define CDR(d,s)     mov d,[fs:s + 2]
%define SETCAR(d,s)  mov [fs:d + 0],s
%define SETCDR(d,s)  mov [fs:d + 2],s

; Each string section is 8 bytes. Section 0 is used to terminate a string.
; Bit 0 of the first word is used by the garbage collector.
; Bit 1 of the first word is set if the section is unused.
; The first word indicates the identifier of the next section.
; The other words in the section store 6 ASCII characters of the string.
; If the string length is not a multiple of 6, then the last section is padded with 0s.
%define STRING_SIZE (8)
%define STRING_DATA (6)
%define STRING_NEXT(d, s) mov d,[gs:s + 0]
%define MAX_SYMBOL_LENGTH (24)

%define BUILTIN_NIL (0) 

; Flags for next_argument:
%define NEXT_ARG_ANY    (1 << 8)  ; Match any type.
%define NEXT_ARG_QUOTE  (1 << 9)  ; Don't evaluate the argument.
%define NEXT_ARG_FINAL  (1 << 10) ; Check this is the last argument.
%define NEXT_ARG_TAIL   (1 << 11) ; Tail call evaluate. Implies _ANY and _BX; incompatible with _QUOTE and _KEEP.
%define NEXT_ARG_KEEP	(1 << 12) ; Add the result to the all list.
%define NEXT_ARG_BX     (1 << 13) ; Return the result in _BX. Use with _FINAL.
%define NEXT_ARG_NIL	(1 << 14) ; Allow nil as well as any matched types.

start:
	; Setup segment registers and the stack.
	cli
	xor	ax,ax
	mov	ss,ax
	mov	ax,0x1000
	mov	ds,ax
	mov	ax,0x2000
	mov	fs,ax
	mov	ax,0x3000
	mov	gs,ax
	mov	sp,0
	cld
	sti

	; Save the BIOS drive number.
	mov	[drive_number],dl

	; Clear the screen.
	call	clear_screen

	; Install exception handlers.
	call	install_exception_handlers

	; Initialize IO.
	call	initialize_io

	; Initialize the interpreter.
	call	initialize_interpreter

	; Run the REPL.
	mov	word [recover],repl
	call	repl

	cli
	hlt

repl:
	; Reset stack.
	mov	sp,0

	; Allow the garbage collector to run.
	mov	byte [gc_ready],1

	; Close any open files.
	mov	cx,MAX_OPEN_FILES - 1
	mov	si,open_file_table
	.close_file_loop:
	cmp	byte [si + 10],0
	jz	.handle_unused
	push	si
	push	cx
	call	close_file
	pop	cx
	pop	si
	.handle_unused:
	add	si,DATA_PER_OPEN_FILE
	loop	.close_file_loop

	; Get user input.
	mov	word [print_callback],terminal_print_string
	cmp	byte [run_startup_command],0
	je	.do_startup
	mov	si,prompt_message
	call	print_string
	call	get_user_input
	jmp	.got_input
	.do_startup:
	mov	byte [run_startup_command],1
	mov	cx,[startup_command_length]
	mov	si,startup_command
	mov	ax,ds
	mov	es,ax
	mov	di,INPUT_BUFFER
	rep	movsb
	mov	word [print_callback],output_null
	.got_input:

	; Reset read information.
	mov	byte [next_character],0
	mov	word [input_line],1
	mov	word [input_offset],0
	mov	word [input_handle],0

	; Set the environment.
	cmp	word [.environment],0
	jne	.environment_set
	mov	bx,[obj_builtins]
	mov	[.environment],bx
	.environment_set:

	; Tidy the environment.
	mov	bx,[.environment]
	call	tidy_environment

	; Read and evaluate all the objects in the input buffer.
	.evaluate_loop:
	mov	bp,ALL_LIST_TOP
	mov	bx,[.environment]
	ALL_PUSH(bx)
	call	print_newline
	call	read_object
	cmp	bx,0xFFFF
	je	.last_object
	ALL_PUSH(bx)
	mov	si,[.environment]
	push	si
	mov	di,sp
	call	evaluate_object
	pop	si
	mov	[.environment],si
	or	bx,bx
	jz	.evaluate_loop
	mov	cx,-100
	xor	dx,dx
	call	print_object
	jmp	.evaluate_loop
	.last_object:
	or	al,al
	jne	error_unexpected_character
	jmp	repl

	.environment: dw 0

get_user_input:
	; Save the position where user input began.
	call	get_caret_position
	mov	[user_input_start],bx

	; Reset last scancode.
	mov	byte [last_scancode],0

	; Add entropy to RNG.
	xor	ah,ah
	int	0x1A
	add	[do_builtin_random.seed],dx
	add	[do_builtin_random.seed],cx

	xor	bx,bx

	.loop:

	; Highlight the first unmatched brace.
	push	bx
	call	highlight_first_unmatched_brace
	pop	bx

	; Read a character from the keyboard.
	xor	ax,ax
	push	bx
	int	0x16
	pop	bx
	cmp	ah,0x48
	je	.up
	cmp	al,8
	je	.backspace
	cmp	al,13
	je	.done
	cmp	al,32
	jb	.loop
	cmp	al,127
	jae	.loop

	; Append the character to the end of the buffer.
	cmp	bx,INPUT_BUFFER_SIZE - 1
	je	.loop
	mov	[INPUT_BUFFER + bx],al
	inc	bx

	; Echo the character to the screen.
	push	ax
	push	bx
	call	print_character
	pop	bx
	pop	ax

	jmp	.loop
	
	; Move the caret back.
	.backspace:
	or	bx,bx
	jz	.loop
	push	bx
	call	print_backspace

	; Clear the cell.
	mov	al,' '
	call	print_character
	call	print_backspace
	pop	bx
	dec	bx
	jmp	.loop

	; Copy the prior input buffer to the current input buffer.
	.up:
	mov	ax,ds
	mov	es,ax
	mov	di,INPUT_BUFFER
	mov	si,PRIOR_INPUT_BUFFER
	mov	cx,INPUT_BUFFER_SIZE
	rep	movsb

	; Clear the already typed text.
	mov	cx,bx
	or	cx,cx
	jz	.no_text_to_clear
	.clear_loop:
	push	cx
	call	print_backspace
	mov	al,' '
	call	print_character
	call	print_backspace
	pop	cx
	loop	.clear_loop
	.no_text_to_clear:

	; Print the new text.
	mov	si,INPUT_BUFFER
	call	print_string

	; Update bx to the length of the new input.
	xor	bx,bx
	mov	si,INPUT_BUFFER
	.count_loop:
	lodsb
	or	al,al
	jz	.loop
	inc	bx
	jmp	.count_loop

	.done:

	; Zero terminate the result.
	mov	byte [INPUT_BUFFER + bx],0

	; Copy to the prior input buffer.
	mov	cx,bx
	inc	cx
	mov	ax,ds
	mov	es,ax
	mov	di,PRIOR_INPUT_BUFFER
	mov	si,INPUT_BUFFER
	rep	movsb

	; Remove any highlighting on an unmatched brace.
	mov	bx,[previously_unmatched_brace]
	or	bx,bx
	jz	.cleared_old_formatting
	mov	ax,0xB800
	mov	es,ax
	mov	byte [es:bx],SCREEN_COLOR >> 8
	.cleared_old_formatting:

	ret

; returns position in bx
; preserves cx, si, di, bp
get_caret_position:
	mov	ax,[caret_row]
	mov	dx,160
	mul	dx
	mov	bx,[caret_column]
	shl	bx,1
	add	bx,ax
	ret

; bx - input buffer position
highlight_first_unmatched_brace:
	mov	ax,0xB800
	mov	es,ax
	mov	cx,bx

	; Clear the formatting on the previously unmatched brace.
	mov	bx,[previously_unmatched_brace]
	or	bx,bx
	jz	.cleared_old_formatting
	mov	byte [es:bx],SCREEN_COLOR >> 8
	.cleared_old_formatting:

	; Find the first unmatched brace.
	call	get_caret_position
	xor	cx,cx
	.search_loop:
	sub	bx,2
	cmp	bx,[user_input_start]
	jb	.at_start
	mov	al,[es:bx]
	cmp	al,']'
	je	.right_brace
	cmp	al,'['
	je	.left_brace
	jmp	.search_loop
	.right_brace:
	inc	cx
	jmp	.search_loop
	.left_brace:
	or	cx,cx
	jz	.found
	dec	cx
	jmp	.search_loop

	; Set the formatting for the matching brace.
	.found:
	inc	bx
	mov	[previously_unmatched_brace],bx
	mov	byte [es:bx],HIGHLIGHT_COLOR >> 8
	ret

	; Check if there were more closing braces than opening braces.
	.at_start:
	or	cx,cx
	jz	.done

	; Highlight the last unmatched closing brace.
	call	get_caret_position
	.search_loop2:
	sub	bx,2
	cmp	bx,[user_input_start]
	jb	.done
	mov	al,[es:bx]
	cmp	al,']'
	jne	.search_loop2
	inc	bx
	mov	[previously_unmatched_brace],bx
	mov	byte [es:bx],ERROR_COLOR >> 8
	ret

	; All braces were matched.
	.done:
	xor	bx,bx
	mov	[previously_unmatched_brace],bx
	ret

initialize_interpreter:
	; The first object and string are reserved to indicate nil.
	mov	ax,1
	mov	word [first_free_string],STRING_SIZE
	mov	word [first_free_object],OBJ_SIZE

	; Create a list of free strings.
	mov	cx,(65536 / STRING_SIZE - 1)
	mov	bx,STRING_SIZE
	mov	ax,(STRING_SIZE * 2 + 2)
	.free_string_loop:
	mov	[gs:bx],ax
	add	bx,STRING_SIZE
	add	ax,STRING_SIZE
	loop	.free_string_loop

	; Create a list of free objects.
	mov	cx,(65536 / OBJ_SIZE - 1)
	mov	bx,OBJ_SIZE
	mov	ax,(OBJ_SIZE * 2)
	mov	dx,TYPE_FREE
	.free_obj_loop:
	SETCAR(bx, dx)
	SETCDR(bx, ax)
	add	bx,OBJ_SIZE
	add	ax,OBJ_SIZE
	loop	.free_obj_loop

	; Initial the nil object and string.
	mov	word [gs:0],0
	mov	word [gs:2],0
	mov	word [gs:4],0
	mov	word [gs:6],0
	mov	word [fs:0],TYPE_NIL
	mov	word [fs:2],0

	; Start the symbol table and builtins as the nil object.
	mov	word [obj_symbol_table],0
	mov	word [obj_builtins],0

	; Add builtins.
	call	add_builtins

	ret

add_builtins:
	mov	si,builtin_strings
	mov	dx,0
	.builtin_loop:

	; Check if we're done.
	mov	al,[si]
	or	al,al
	jz	.done

	push	si
	push	dx

	xor	bx,bx
	cmp	dx,BUILTIN_NIL
	je	.made_object

	; Make the builtin object itself.
	mov	ax,TYPE_BUILTIN
	call	new_object
	.made_object:

	; Get the symbol object.
	push	bx
	mov	bp,ALL_LIST_TOP
	call	find_symbol

	; Create the pair of symbol-builtin.
	mov	ax,bx
	pop	dx
	call	new_object

	; Create the list object.
	mov	ax,bx
	mov	dx,[obj_builtins]
	call	new_object
	mov	[obj_builtins],bx

	; Advance to the next builtin.
	pop	dx
	pop	si
	inc	dx
	.string_end_loop:
	lodsb
	or	al,al
	jne	.string_end_loop
	jmp	.builtin_loop

	.done:
	ret

; bp - all list (preserved)
; returns object in bx (bx != 0xFFFF), or character in al (bx = 0xFFFF)
read_object:
	CHECK_STACK_OVERFLOW

	; Read a non-whitespace character.
	.try_again:
	call	read_next_character
	cmp	al,10
	je	.try_again
	cmp	al,13
	je	.try_again
	cmp	al,9
	je	.try_again
	cmp	al,' '
	je	.try_again

	; End of input?
	mov	bx,0xFFFF
	or	al,al
	je	.done

	; Check for a comment.
	cmp	al,';'
	jne	.not_comment
	.comment_loop:
	call	read_next_character
	or	al,al
	jz	read_object
	cmp	al,10
	je	read_object
	jmp	.comment_loop
	.not_comment:

	; Check for single-character tokens, ']' and '.'.
	mov	bx,0xFFFF
	cmp	al,']'
	je	.done
	cmp	al,'.'
	je	.done

	; Check for string.
	cmp	al,'"'
	je	read_string_object

	; Check for list.
	cmp	al,'['
	je	read_list_object
	
	; It must be either a symbol or integer.
	jmp	read_symbol_object

	.done:
	ret

; bp - all list (preserved)
read_string_object:
	; Create the object.
	mov	ax,TYPE_STRING
	xor	dx,dx ; new_string could gc, so this should be valid
	call	new_object
	ALL_PUSH(bx)

	; Create the first string section.
	push	bx
	call	new_string
	pop	di
	SETCDR(di,bx)
	push	di

	; Read characters until the string is closed.
	.add_loop:
	call	read_next_character
	or	al,al
	jz	error_unexpected_eoi
	cmp	al,'"'
	je	.done

	; Handle escape codes.
	cmp	al,'\'
	jne	.append
	call	read_next_character
	cmp	al,'n'
	jne	.e1
	mov	al,10
	.e1:

	; Append the character.
	.append:
	call	string_append_character
	jmp	.add_loop

	.done:
	pop	bx
	ALL_POP(1)
	ret

; bp - all list (preserved)
; al - first character of symbol
read_symbol_object:
	xor	bx,bx

	; Read characters into the buffer.
	.loop:
	cmp	al,'['
	je	.end_symbol
	cmp	al,']'
	je	.end_symbol
	cmp	al,';'
	je	.end_symbol
	cmp	al,'.'
	je	.end_symbol
	cmp	al,'"'
	je	.end_symbol
	cmp	al,' '
	je	.end_symbol
	cmp	al,9
	je	.end_symbol
	cmp	al,10
	je	.end_symbol
	or	al,al
	jz	.end_symbol

	; Store the characer, and read the next one.
	cmp	bx,MAX_SYMBOL_LENGTH
	je	error_symbol_too_long
	mov	[.buffer + bx],al
	inc	bx
	call	read_next_character
	jmp	.loop
	.end_symbol:
	mov	byte [.buffer + bx],0
	mov	[next_character],al

	; Try to parse the symbol as an integer.
	mov	si,.buffer
	call	read_integer_object
	jc	.done

	; Find the symbol.
	mov	si,.buffer
	call	find_symbol

	; Create the object.
	mov	ax,TYPE_SYMBOL
	mov	dx,bx
	call	new_object

	.done:	ret
	.buffer: times (MAX_SYMBOL_LENGTH + 1) db 0

; bp - all list (preserved)
; si - buffer containing string
; returns object in bx, carry clear if not an integer
read_integer_object:
	; Is it negative?
	mov	dx,32767
	mov	al,[si]
	cmp	al,'-'
	jne	.positive
	mov	dx,32768
	inc	si
	mov	al,[si]
	.positive:

	; Is it an empty string?
	or	al,al
	jz	.not_integer

	; Iterate through each digit
	xor	cx,cx
	.digit_loop:
	lodsb
	or	al,al
	jz	.done
	cmp	al,'0'
	jb	.not_integer
	cmp	al,'9'
	ja	.not_integer

	; Check for overflow.
	cmp	cx,3276
	ja	error_integer_too_large

	; Multiply by 10.
	push	ax
	push	dx
	mov	ax,cx
	mov	bx,10
	mul	bx
	mov	cx,ax
	pop	dx
	pop	ax

	; Check for overflow.
	mov	bx,dx
	xor	ah,ah
	sub	bx,ax
	add	bx,'0'
	cmp	cx,bx
	ja	error_integer_too_large

	; Add the digit.
	add	cx,ax
	sub	cx,'0'
	jmp	.digit_loop

	; Negate the final result.
	.done:
	cmp	dx,32768
	jne	.negated
	neg	cx
	.negated:

	; Create the object.
	mov	dx,cx
	mov	ax,TYPE_INT
	call	new_object
	stc
	ret

	.not_integer:
	clc
	ret

; bp - all list (preserved)
read_list_object:
	sub	sp,8
	mov	di,sp
	mov	[ss:di+0],bp     ; all
	mov	byte [ss:di+2],1 ; first
	mov	word [ss:di+4],0 ; result
	mov	word [ss:di+6],0 ; tail

	; Loop until the list is closed.
	.loop:
	mov	bp,[ss:di+0]
	mov	bx,[ss:di+4]
	ALL_PUSH(bx)
	call	read_object
	mov	di,sp

	; Check for end of list and dotted lists.
	cmp	bx,0xFFFF
	jne	.next_item
	or	al,al
	jz	error_unexpected_eoi
	cmp	al,']'
	je	.done
	cmp	al,'.'
	je	.dotted
	jmp	error_unknown

	; Save the item.
	.next_item:
	ALL_PUSH(bx)

	; Is this the first item in the list?
	cmp	byte [ss:di+2],1
	jne	.not_first

	; Create the pair and set it as the tail.
	mov	byte [ss:di+2],0
	mov	ax,bx
	xor	dx,dx
	call	new_object
	mov	di,sp
	mov	[ss:di+4],bx
	mov	[ss:di+6],bx
	jmp	.loop

	; Create the pair and add it to the tail.
	.not_first:
	mov	ax,bx
	xor	dx,dx
	call	new_object
	mov	di,sp
	mov	si,[ss:di+6]
	SETCDR(si, bx)
	mov	[ss:di+6],bx
	jmp	.loop

	; Restore context and return.
	.done:
	mov	bp,[ss:di+0]
	mov	bx,[ss:di+4]
	add	sp,8
	ret

	; Dotted list.
	.dotted:
	cmp	byte [ss:di+2],1
	je	error_invalid_dot

	; Read the final item.
	call	read_object
	mov	di,sp
	cmp	bx,0xFFFF
	je	error_invalid_dot
	mov	si,[ss:di+6]
	SETCDR(si, bx)

	; Read the closing brace.
	call	read_object
	cmp	bx,0xFFFF
	jne	error_invalid_dot
	cmp	al,']'
	jne	error_invalid_dot
	jmp	.done

; returns next character in al
; overwrites si only
read_next_character:
	mov	al,[next_character]
	mov	byte [next_character],0
	or	al,al
	jnz	.return

	cmp	word [input_handle],0
	je	.from_input_buffer
	jmp	.from_file

	.process:
	cmp	al,10
	jne	.return
	inc	word [input_line]
	.return: ret

	.from_input_buffer:
	mov	si,[input_offset]
	mov	al,[si + INPUT_BUFFER]
	or	al,al
	jz	.process
	inc	si
	mov	[input_offset],si
	jmp	.process

	.from_file:
	pusha
	mov	si,[input_handle]
	mov	cx,1
	mov	ax,ds
	mov	es,ax
	mov	di,.destination
	call	read_file
	call	has_error_file
	jc	error_read_file
	or	cx,cx
	jnz	.e1
	mov	byte [.destination],0
	.e1:
	popa
	mov	al,[.destination]
	jmp	.process
	.destination: db 1

; bp - all list
; si - environment
; bx - object
; di - stack address to write updated enviornment, else 0
; evaluated object returned in bx
; no registers preserved
evaluate_object:
	CHECK_STACK_OVERFLOW

	; Keep our environment.
	ALL_PUSH(si)
	
	; Check for Ctrl+C.
	inc	byte [check_break]
	jnz	.no_break
	mov	ah,1
	int	0x16
	jz	.no_break
	cmp	ah,0x2E
	jne	.remove_key
	mov	ah,2
	int	0x16
	test	al,(1 << 2)
	jnz	error_break
	.remove_key:
	mov	[last_scancode],ah
	xor	ah,ah
	int	0x16
	.no_break:

	; Is the object a list?
	CAR(ax, bx)
	test	ax,2
	jz	.list

	; Is the object a symbol?
	cmp	ax,TYPE_SYMBOL
	je	.symbol

	; Otherwise, the object evalutes to itself.
	cmp	ax,TYPE_FREE
	je	error_free_accessible
	ret

	; Lookup the value of the symbol in the environment.
	.symbol:
	CDR(bx, bx)
	call	lookup_symbol
	CDR(bx, bx)
	ret

	; Evaluate the function.
	.list:
	push	bx
	push	bp
	push	si
	push	di
	xor	di,di
	CAR(bx, bx)
	call	evaluate_object
	pop	di
	pop	si
	pop	bp
	ALL_PUSH(bx)

	; Is the function a builtin?
	CAR(ax, bx)
	cmp	ax,TYPE_BUILTIN
	je	.builtin

	; Is the function a lambda or macro?
	cmp	ax,TYPE_LAMBDA
	je	evaluate_lambda
	cmp	ax,TYPE_MACRO
	je	evaluate_macro

	; Otherwise, the function object is not callable.
	jmp	error_not_callable

	; Get the builtin ID and the start of the arguments list.
	.builtin:
	CDR(ax, bx)
	pop	bx
	CDR(bx, bx)

	; Call the builtin.
	push	di
	mov	di,ax
	shl	di,1
	mov	ax,[di + builtin_functions]
	or	ax,ax
	jz	error_unimplemented_builtin
	pop	di
	jmp	ax

%macro EVALUATE_LAMBDA_COMMON 1
	; Extract information about the lambda.
	CDR(bx, bx)
	CDR(di, bx) ; di = new environment
	CAR(bx, bx)
	CDR(ax, bx) 
	CAR(dx, bx) ; dx = symbols
	pop	bx  
	push	ax  ; function body
	CDR(bx, bx) ; bx = arguments

	; For each argument...
	.argument_loop:
	or	dx,dx
	jz	.environment_ready
	ALL_PUSH(di)
	mov	cx,%1
	call	next_argument

	; Add it to the new environment.
	push	bx
	push	di
	push	dx
	mov	di,dx
	CAR(di, di)
	CDR(ax, di)
	mov	dx,cx
	call	new_object
	ALL_PUSH(bx)
	pop	dx
	mov	di,dx
	CDR(dx, di)
	pop	di
	push	dx
	mov	ax,bx
	mov	dx,di
	call	new_object
	mov	di,bx
	pop	dx
	pop	bx

	ALL_POP(3)
	jmp	.argument_loop

	; Check we used all the arguments.
	.environment_ready:
	or	bx,bx
	jnz	error_too_many_arguments
%endmacro

evaluate_lambda:
	EVALUATE_LAMBDA_COMMON NEXT_ARG_ANY | NEXT_ARG_KEEP

	; Call the function body.
	mov	si,di
	pop	bx
	jmp	do_builtin_do

evaluate_macro:
	pop	ax
	push	di ; old environment pointer
	push	si ; old environment
	push	bp ; all list

	; Construct the new environment.
	push	ax
	EVALUATE_LAMBDA_COMMON NEXT_ARG_ANY | NEXT_ARG_KEEP | NEXT_ARG_QUOTE

	; Evaluate the arguments passed to the macro using the new environment.
	mov	si,di
	ALL_PUSH(si)
	pop	bx
	call	do_builtin_list

	; Evaluate the result using the old environment.
	pop	bp
	pop	si
	pop	di
	ALL_PUSH(bx)
	.loop:
	or	bx,bx
	jz	.done
	mov	cx,NEXT_ARG_QUOTE | NEXT_ARG_ANY
	call	next_argument
	push	bx
	push	di
	push	bp
	push	si
	or	di,di
	jz	.no_di
	mov	si,[ss:di]
	.no_di:
	mov	bx,cx
	call	evaluate_object
	pop	si
	pop	bp
	pop	di
	pop	bx
	jmp	.loop
	.done:
	ret

do_builtin_add:
	xor	dx,dx
	.loop:
	or	bx,bx
	jz	.done
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(cx, di)
	add	dx,cx
	jmp	.loop
	.done:
	mov	ax,TYPE_INT
	jmp	new_object

do_builtin_subtract:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(dx, di)
	or	bx,bx
	jz	.negate
	.loop:
	or	bx,bx
	jz	.done
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(cx, di)
	sub	dx,cx
	jmp	.loop
	.negate:
	neg	dx
	.done:
	mov	ax,TYPE_INT
	jmp	new_object

%macro MULDIV_START 0
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	.loop:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(cx, di)
%endmacro

%macro MULDIV_END 0
	or	bx,bx
	jnz	.loop
	.done:
	mov	dx,ax
	mov	ax,TYPE_INT
	jmp	new_object
%endmacro

do_builtin_multiply:
	MULDIV_START
	imul	cx
	MULDIV_END

do_builtin_divide:
	MULDIV_START
	cwd
	idiv	cx
	MULDIV_END

do_builtin_modulo:
	MULDIV_START
	xor	dx,dx
	div	cx
	mov	ax,dx
	MULDIV_END

do_builtin_muldiv:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(cx, di)
	imul	cx
	mov	cx,TYPE_INT | NEXT_ARG_FINAL
	call	next_argument
	mov	di,cx
	CDR(cx, di)
	idiv	cx
	mov	dx,ax
	mov	ax,TYPE_INT
	jmp	new_object

do_builtin_quote:
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_QUOTE | NEXT_ARG_ANY | NEXT_ARG_BX
	jmp	next_argument

do_builtin_car:
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CAR(bx, bx)
	ret

do_builtin_cdr:
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(bx, bx)
	ret

do_builtin_setcar:
	mov	cx,NEXT_ARG_KEEP
	call	next_argument
	mov	di,cx
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	SETCAR(di, cx)
	mov	bx,di
	ret

do_builtin_setcdr:
	mov	cx,NEXT_ARG_KEEP
	call	next_argument
	mov	di,cx
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	SETCDR(di, cx)
	mov	bx,di
	ret

do_builtin_cons:
	mov	cx,NEXT_ARG_KEEP | NEXT_ARG_ANY
	call	next_argument
	mov	ax,cx
	mov	cx,NEXT_ARG_KEEP | NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	mov	dx,cx
	jmp	new_object

new_true:
	mov	ax,TYPE_INT
	mov	dx,1
	jmp	new_object

%macro COMPARE_COMMON 1
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	mov	cx,TYPE_INT | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(bx, bx)
	cmp	ax,bx
	%1	new_true
	xor	bx,bx
	ret
%endmacro

do_builtin_lt:  COMPARE_COMMON jl
do_builtin_lte: COMPARE_COMMON jle
do_builtin_gt:  COMPARE_COMMON jg
do_builtin_gte: COMPARE_COMMON jge

do_builtin_not:
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	or	bx,bx
	jz	new_true
	xor	bx,bx
	ret

%macro PRINT_COMMON 0
	.loop:
	or	bx,bx
	jz	.done
	mov	cx,NEXT_ARG_ANY
	call	next_argument
	pusha
	mov	bx,cx
	mov	cx,-100
	mov	dx,1
	ALL_PUSH(bx)
	call	print_object
	popa
	jmp	.loop
	.done:
%endmacro

do_builtin_print:
	PRINT_COMMON
	xor	bx,bx
	ret

do_builtin_print_colored:
	push	word [output_color]
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	and	ax,15
	mov	[output_color],ax
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	and	ax,15
	shl	ax,4
	or	[output_color],ax
	PRINT_COMMON
	xor	bx,bx
	pop	word [output_color]
	ret

do_builtin_print_substr:
	; Get the starting index, the length to print, and the string itself.
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	push	ax
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	or	ax,ax
	jz	.out_of_bounds_seek
	push	ax
	mov	cx,TYPE_STRING | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	ALL_PUSH(bx)
	CDR(bx, bx)
	pop	ax
	pop	cx
	push	ax

	; Seek to the start of the substring.
	.seek:
	or	bx,bx
	jz	.out_of_bounds_seek
	cmp	cx,6
	jb	.in_section
	STRING_NEXT(bx, bx)
	sub	cx,6
	jmp	.seek
	.in_section:
	add	bx,2
	.loop2:
	or	cx,cx
	jz	.seek_done
	mov	al,[gs:bx]
	or	al,al
	jz	.out_of_bounds_seek
	inc	bx
	dec	cx
	jmp	.loop2
	.seek_done:

	; Print this section.
	pop	cx
	.first_section:
	test	bx,7
	jz	.first_done
	mov	al,[gs:bx]
	or	al,al
	jz	.done
	call	print_character
	inc	bx
	loop	.first_section
	jmp	.done
	.first_done:

	; Go to the first middle section.
	sub	bx,8
	STRING_NEXT(bx, bx)

	; Print out full sections.
	.middle_section:
	or	bx,bx
	jz	.done
	cmp	cx,6
	jl	.last_section
	mov	si,print_string_list.buffer
	mov	al,[gs:bx+2]
	mov	[si+0],al
	mov	al,[gs:bx+3]
	mov	[si+1],al
	mov	al,[gs:bx+4]
	mov	[si+2],al
	mov	al,[gs:bx+5]
	mov	[si+3],al
	mov	al,[gs:bx+6]
	mov	[si+4],al
	mov	al,[gs:bx+7]
	mov	[si+5],al
	call	print_string
	STRING_NEXT(bx, bx)
	sub	cx,6
	jmp	.middle_section
	or	cx,cx
	jz	.done

	; Print out the last section.
	.last_section:
	add	bx,2
	.last_loop:
	mov	al,[gs:bx]
	or	al,al
	jz	.done
	call	print_character
	inc	bx
	loop	.last_loop

	.done:
	xor	bx,bx
	ret

	.out_of_bounds_seek:
	pop	ax
	xor	bx,bx
	ret

do_builtin_poke:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(di, di)
	mov	cx,TYPE_INT | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(cx, bx)
	shl	ax,12
	mov	es,ax
	mov	[es:di],cl
	xor	bx,bx
	ret

do_builtin_peek:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(di, di)
	shl	ax,12
	mov	es,ax
	xor	dh,dh
	mov	dl,[es:di]
	mov	ax,TYPE_INT
	jmp	new_object

do_builtin_atom:
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CAR(ax, bx)
	test	ax,2
	jnz	new_true
	xor	bx,bx
	ret

do_builtin_is:
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_KEEP
	call	next_argument
	mov	di,cx
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	cmp	di,bx 
	je	new_true ; same IDs
	CAR(ax, di)
	CAR(cx, bx)
	cmp	ax,cx
	jne	.false ; different types
	CDR(di, di)
	CDR(bx, bx)
	cmp	ax,TYPE_INT
	je	.compare_cdr
	cmp	ax,TYPE_SYMBOL
	je	.compare_cdr
	cmp	ax,TYPE_STRING
	je	.compare_strings
	.false:
	xor	bx,bx
	ret
	.compare_cdr:
	cmp	bx,di
	je	new_true ; same int/symbol
	xor	bx,bx
	ret
	.compare_strings:
	call	string_compare
	jc	new_true
	xor	bx,bx
	ret

do_builtin_and:
	or	bx,bx
	jz	new_true
	mov	cx,NEXT_ARG_ANY
	call	next_argument
	or	cx,cx
	jnz	do_builtin_and
	xor	bx,bx
	ret

do_builtin_or:
	or	bx,bx
	jnz	.test
	xor	bx,bx
	ret
	.test:
	mov	cx,NEXT_ARG_ANY
	call	next_argument
	or	cx,cx
	jz	do_builtin_or
	jmp	new_true

do_builtin_if:
	CDR(cx, bx)
	or	cx,cx
	jz	error_insufficient_arguments
	.loop:
	CDR(cx, bx)
	or	cx,cx
	jz	.true ; final else
	mov	cx,NEXT_ARG_ANY
	call	next_argument
	or	cx,cx
	jnz	.true
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_QUOTE
	call	next_argument
	jmp	.loop ; false case
	.true:
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_BX | NEXT_ARG_TAIL
	jmp	next_argument ; true case

%macro LAMBDA_COMMON 1
	mov	ax,bx
	mov	cx,NEXT_ARG_NIL | NEXT_ARG_QUOTE
	call	next_argument
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_QUOTE
	call	next_argument
	mov	dx,si
	call	new_object
	ALL_PUSH(bx)
	mov	ax,%1
	mov	dx,bx
	jmp	new_object
%endmacro

do_builtin_lambda:
	LAMBDA_COMMON	TYPE_LAMBDA
do_builtin_macro:
	LAMBDA_COMMON	TYPE_MACRO

do_builtin_list:
	; Check for an empty list.
	or	bx,bx
	jnz	.non_empty
	ret

	; Create the head of the list.
	.non_empty:
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_KEEP
	call	next_argument
	mov	ax,cx
	xor	dx,dx
	push	bx
	call	new_object
	mov	di,bx ; di = tail
	pop	bx
	push	di ; result on stack
	ALL_POP(1)
	ALL_PUSH(di)

	; Loop through the rest of the items in the list.
	.loop:
	or	bx,bx
	jz	.end
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_KEEP
	call	next_argument

	; Add it to the tail.
	mov	ax,cx
	xor	dx,dx
	push	bx
	push	di
	call	new_object
	pop	di
	SETCDR(di, bx)
	mov	di,bx
	pop	bx
	ALL_POP(1)
	jmp	.loop

	; Return the head of the list.
	.end:
	pop	bx
	ret

do_builtin_do:
	mov	cx,NEXT_ARG_QUOTE | NEXT_ARG_ANY
	call	next_argument
	or	bx,bx
	jz	.last_argument
	push	bx
	push	si
	mov	di,sp
	push	bp
	mov	bx,cx
	ALL_PUSH(si)
	call	evaluate_object
	pop	bp
	pop	si
	pop	bx
	jmp	do_builtin_do
	.last_argument:
	xor	di,di
	mov	bx,cx
	ALL_POP(2) ; function and environment
	jmp	evaluate_object

do_builtin_let:
	or	di,di
	jz	error_cannot_let
	push	di
	mov	cx,TYPE_SYMBOL | NEXT_ARG_QUOTE | NEXT_ARG_KEEP
	call	next_argument
	mov	di,cx
	CDR(ax, di)
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL | NEXT_ARG_KEEP
	call	next_argument
	mov	dx,cx
	call	new_object
	ALL_PUSH(bx)
	mov	ax,bx
	mov	dx,si
	call	new_object
	pop	di
	mov	[ss:di],bx
	xor	bx,bx
	ret

do_builtin_set:
	mov	cx,TYPE_SYMBOL | NEXT_ARG_QUOTE | NEXT_ARG_KEEP
	call	next_argument
	mov	di,cx
	CDR(di, di)
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL
	call	next_argument
	mov	bx,di
	call	lookup_symbol
	SETCDR(bx, cx)
	mov	bx,cx
	ret

do_builtin_while:
	mov	di,bx
	.loop:
	mov	cx,NEXT_ARG_ANY
	call	next_argument
	or	cx,cx
	jz	.done
	mov	cx,NEXT_ARG_ANY | NEXT_ARG_FINAL
	call	next_argument
	mov	bx,di
	jmp	.loop
	.done:
	xor	bx,bx
	ret

; cx - additional flags to pass to next_argument
; preserves bp, si
next_filename_argument:
	or	cx,TYPE_STRING
	call	next_argument
	push	bx
	push	si
	mov	bx,cx
	CDR(bx, bx)
	mov	di,.name
	mov	cx,16
	call	string_flatten
	jc	error_file_name_too_long
	pop	si
	pop	bx
	ret
	.name: times 16 db 0

do_builtin_src:
	; We need to be in a environment-updating context to use src.
	or	di,di
	jz	error_cannot_src

	push	di
	push	si
	push	bp

	; Get the name of the file to source.
	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument

	; Open a handle to the file.
	mov	dx,FILE_READ
	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file
	mov	dx,si

	pop	bp
	pop	si

	; Save the previous input context.
	mov	al,[next_character]
	push	ax
	mov	ax,[input_line]
	push	ax
	mov	ax,[input_offset]
	push	ax
	mov	ax,[input_handle]
	push	ax

	; Set the new input context.
	mov	byte [next_character],0
	mov	word [input_line],1
	mov	word [input_offset],0
	mov	[input_handle],dx

	push	bp

	.evaluate_loop:

	; Reset the all list and push the environment.
	pop	bp
	push	bp
	ALL_PUSH(si)
	push	si

	; Read the object and put it on the all list.
	call	read_object
	cmp	bx,0xFFFF
	je	.last_object
	ALL_PUSH(bx)

	; Evaluate the object.
	pop	si
	push	si
	mov	di,sp
	call	evaluate_object
	pop	si

	jmp	.evaluate_loop

	; Check for stray tokens.
	.last_object:
	or	al,al
	jne	error_unexpected_character

	; Close file handle.
	push	si
	mov	si,[input_handle]
	call	close_file
	pop	si

	add	sp,4

	; Restore the previous input context.
	pop	ax
	mov	[input_handle],ax
	pop	ax
	mov	[input_offset],ax
	pop	ax
	mov	[input_line],ax
	pop	ax
	mov	[next_character],al

	; Save the environment.
	pop	di
	mov	[ss:di],si

	xor	bx,bx
	ret

do_builtin_read:
	; Get the name of the file to type.
	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument

	; Open a handle to the file.
	mov	dx,FILE_READ
	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file

	; Read the file and print until done.
	.loop:
	mov	ax,ds
	mov	es,ax
	mov	cx,TYPE_BUFFER_SIZE - 1
	mov	di,TYPE_BUFFER
	call	read_file
	call	has_error_file
	jc	error_read_file
	mov	bx,cx
	mov	byte [TYPE_BUFFER + bx],0
	push	si
	mov	si,TYPE_BUFFER
	call	print_string
	pop	si
	or	bx,bx
	jnz	.loop
	call	close_file
	xor	bx,bx
	ret

; ds:si - string
; result in cx
; null byte not counted
; preserves di, bx, dx
calculate_string_length:
	xor	cx,cx
	.loop:
	lodsb
	or	al,al
	jz	.done
	inc	cx
	jmp	.loop
	.done:
	ret

write_string_to_file:
	mov	di,si
	call	calculate_string_length
	mov	si,[print_data]
	mov	ax,ds
	mov	es,ax
	jmp	write_file

write_append_common:
	push	word [print_callback]
	push	word [print_data]
	push	si
	push	bx

	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file
	mov	[print_data],si
	mov	word [print_callback],write_string_to_file

	pop	bx
	pop	si

	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument

	mov	si,[print_data]
	call	close_file

	pop	word [print_data]
	pop	word [print_callback]

	xor	bx,bx
	ret

do_builtin_write:
	xor	cx,cx
	call	next_filename_argument
	mov	dx,FILE_WRITE
	jmp	write_append_common

do_builtin_append:
	xor	cx,cx
	call	next_filename_argument
	mov	dx,FILE_APPEND
	jmp	write_append_common

do_builtin_rename:
	xor	cx,cx
	call	next_filename_argument

	push	si
	push	bx
	mov	si,next_filename_argument.name
	mov	dx,FILE_RENAME
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file
	mov	di,si
	pop	bx
	pop	si
	push	di

	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument

	mov	si,next_filename_argument.name
	mov	dx,FILE_READ
	call	open_file
	cmp	si,0xFFFF
	jne	error_file_already_exists

	pop	si
	call	close_file
	xor	bx,bx
	ret

do_builtin_delete:
	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument
	mov	dx,FILE_DELETE
	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file
	call	close_file
	xor	bx,bx
	ret

do_builtin_terminal:
	push	word [print_callback]
	push	word [print_data]
	mov	word [print_callback],terminal_print_string
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	pop	word [print_data]
	pop	word [print_callback]
	xor	bx,bx
	ret

%macro LS_COMMON_START 0
	or	bx,bx
	jnz	error_too_many_arguments

	; Start reading the root directory from the beginning.
	call	start_reading_root_directory

	.loop:
	
	; Read the next entry.
	mov	ax,ds
	mov	es,ax
	mov	si,ROOT_HANDLE
	mov	di,open_file.directory_entry
	mov	cx,0x20
	call	read_file

	call	has_error_file
	jc	error_read_file
	or	cx,cx
	jz	.done
	cmp	byte [open_file.directory_entry],0
	jz	.loop
%endmacro

%macro LS_COMMON_END 0
	jmp	.loop

	.done:
%endmacro

do_builtin_ls:
	LS_COMMON_START
	mov	si,open_file.directory_entry
	call	print_string
	call	print_newline
	LS_COMMON_END
	xor	bx,bx
	ret

do_builtin_dir:
	xor	ax,ax
	mov	[.total_size + 0],ax
	mov	[.total_size + 2],ax
	LS_COMMON_START
	mov	dx,[open_file.directory_entry + 18]
	or	dx,dx
	jnz	.not_small
	mov	ax,[open_file.directory_entry + 16]
	cmp	ax,1000
	ja	.not_small
	call	print_s16
	mov	si,bytes_message
	call	print_string
	jmp	.common
	.not_small:
	mov	cx,1000
	div	cx
	call	print_s16
	mov	si,kilobytes_message
	call	print_string
	.common:
	mov	word [caret_column],8
	mov	si,open_file.directory_entry
	call	print_string
	call	print_newline
	mov	ax,[open_file.directory_entry + 16]
	mov	cx,[open_file.directory_entry + 18]
	add	[.total_size + 0],ax
	adc	[.total_size + 2],cx
	LS_COMMON_END
	mov	ax,[.total_size + 0]
	shr	ax,10
	mov	bx,[.total_size + 2]
	shl	bx,6
	or	ax,bx
	mov	si,total_usage_message
	call	print_string
	call	print_s16
	mov	si,kilobytes_message
	call	print_string
	mov	si,out_of_message
	call	print_string
	mov	ax,[FS_HEADER_BUFFER + 4]
	shr 	ax,1
	call	print_s16
	mov	si,kilobytes_message
	call	print_string
	xor	bx,bx
	ret
	.total_size: dd 0

do_builtin_strlen:
	mov	cx,TYPE_STRING | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(bx, bx)
	xor	dx,dx
	.loop1:
	or	bx,bx
	jz	.done
	mov	cx,6
	STRING_NEXT(di, bx)
	add	bx,2
	.loop2:
	mov	al,[gs:bx]
	or	al,al
	jz	.done
	inc	bx
	inc	dx
	loop	.loop2
	mov	bx,di
	jmp	.loop1
	.done:
	mov	ax,TYPE_INT
	jmp	new_object

do_builtin_nth_char:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(dx, di)
	mov	cx,TYPE_STRING | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(bx, bx)
	mov	cx,dx
	.loop1:
	or	bx,bx
	jz	.out_of_bounds
	cmp	cx,6
	jb	.in_section
	STRING_NEXT(bx, bx)
	sub	cx,6
	jmp	.loop1
	.in_section:
	inc	cx
	add	bx,2
	.loop2:
	mov	al,[gs:bx]
	or	al,al
	jz	.out_of_bounds
	inc	bx
	loop	.loop2
	.done:
	xor	ah,ah
	mov	dx,ax
	mov	ax,TYPE_INT
	jmp	new_object
	.out_of_bounds:
	xor	dx,dx
	mov	ax,TYPE_INT
	jmp	new_object

capture_common:
	push	si
	push	bx
	mov	ax,TYPE_STRING
	xor	dx,dx ; must be valid since new_string might gc
	call	new_object
	ALL_PUSH(bx)
	push	bx
	call	new_string
	mov	dx,bx
	pop	bx
	SETCDR(bx, dx)
	mov	[print_data],dx
	mov	dx,bx
	pop	bx
	pop	si
	push	dx
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	pop	bx
	pop	word [print_data]
	pop	word [print_callback]
	ret

%macro CAPTURE_START 1
	push	word [print_callback]
	push	word [print_data]
	mov	word [print_callback],%1
	jmp	capture_common
%endmacro

capture_string:
	lodsb
	or	al,al
	jz	.done
	mov	bx,[print_data]
	push	si
	call	string_append_character
	pop	si
	mov	[print_data],bx
	jmp	capture_string
	.done:	ret

do_builtin_capture:
	CAPTURE_START capture_string

capture_string_lower:
	lodsb
	or	al,al
	jz	.done
	mov	bx,[print_data]
	cmp	al,'A'
	jb	.no_convert
	cmp	al,'Z'
	ja	.no_convert
	add	al,'a'-'A'
	.no_convert:
	push	si
	call	string_append_character
	pop	si
	mov	[print_data],bx
	jmp	capture_string_lower
	.done:	ret

do_builtin_capture_lower:
	CAPTURE_START capture_string_lower

capture_string_upper:
	lodsb
	or	al,al
	jz	.done
	mov	bx,[print_data]
	cmp	al,'a'
	jb	.no_convert
	cmp	al,'z'
	ja	.no_convert
	sub	al,'a'-'A'
	.no_convert:
	push	si
	call	string_append_character
	pop	si
	mov	[print_data],bx
	jmp	capture_string_upper
	.done:	ret

do_builtin_capture_upper:
	CAPTURE_START capture_string_upper

set_graphics_mode:
	mov	al,[graphics_mode]
	or	al,al
	jnz	.done
	mov	byte [graphics_mode],1
	mov	ax,0xA000
	mov	es,ax
	xor	di,di
	xor	al,al
	mov	cx,320 * 200
	rep	stosb
	mov	ax,0x13
	int	0x10
	.done:	ret

set_text_mode:
	mov	al,[graphics_mode]
	or	al,al
	jz	.done
	mov	byte [graphics_mode],0
	call	clear_screen
	mov	ax,0x03
	int	0x10
	mov	word [caret_column],1
	mov	word [caret_row],0
	.done:	ret

do_builtin_set_graphics:
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY
	call	next_argument
	or	cx,cx
	jz	.text
	call	set_graphics_mode
	xor	bx,bx
	ret
	.text:
	call	set_text_mode
	xor	bx,bx
	ret

do_builtin_wait_key:
	or	bx,bx
	jnz	error_too_many_arguments
	xor	ax,ax
	int	0x16
	xor	bx,bx
	ret

do_builtin_env_reset:
	or	di,di
	jz	error_cannot_env
	or	bx,bx
	jnz	error_too_many_arguments
	mov	ax,[obj_builtins]
	mov	[ss:di],ax
	mov	byte [run_startup_command],0
	xor	bx,bx
	ret

do_builtin_env_list:
	push	word [output_color]
	or	bx,bx
	jnz	error_too_many_arguments
	.loop:
	or	si,si
	jz	.done
	CAR(bx, si)
	CDR(di, bx)
	CAR(ax, di)
	CAR(bx, bx)
	CDR(bx, bx)
	cmp	ax,TYPE_MACRO
	je	.alt
	cmp	ax,TYPE_BUILTIN
	je	.alt2
	cmp	ax,TYPE_LAMBDA
	je	.alt3
	mov	byte [output_color],(SCREEN_COLOR >> 8)
	.print:
	push	si
	call	print_string_list
	mov	byte [output_color],(SCREEN_COLOR >> 8)
	mov	si,space_message
	call	print_string
	pop	si
	CDR(si, si)
	jmp	.loop
	.done:
	call	print_newline
	mov	si,memory_usage_message
	call	print_string
	call	get_memory_usage
	shr	ax,8
	inc	ax
	call	print_s16
	mov	si,kilobytes_message
	call	print_string
	mov	si,out_of_message
	call	print_string
	mov	ax,128
	call	print_s16
	mov	si,kilobytes_message
	call	print_string
	xor	bx,bx
	pop	word [output_color]
	ret
	.highlight:
	mov	byte [output_color],(HIGHLIGHT_COLOR >> 8)
	jmp	.print
	.alt:
	mov	byte [output_color],(ALT_COLOR >> 8)
	jmp	.print
	.alt2:
	mov	byte [output_color],(ALT2_COLOR >> 8)
	jmp	.print
	.alt3:
	mov	byte [output_color],(ALT3_COLOR >> 8)
	jmp	.print

do_builtin_env_export:
	; Open the file to export to.
	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument
	mov	dx,FILE_WRITE
	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file

	; Garbage collect now to reduce export size.
	push	si
	call	garbage_collect
	pop	si

	; Write out a signature.
	mov	word [.buffer + 0],'en'
	mov	word [.buffer + 2],('v' + 0x1000)
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,4
	call	write_file

	; For each object...
	xor	bx,bx
	.object_loop:
	add	bx,OBJ_SIZE
	or	bx,bx
	jz	.object_done
	CAR(ax, bx)
	cmp	ax,TYPE_FREE
	je	.object_loop

	; Write out the ID and contents.
	mov	[.buffer + 0],bx
	mov	[.buffer + 2],ax
	CDR(ax, bx)
	mov	[.buffer + 4],ax
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,6
	push	bx
	call	write_file
	pop	bx
	jmp	.object_loop
	.object_done:

	; Write separator.
	mov	word [.buffer],0
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,6
	call	write_file

	; For each string...
	xor	bx,bx
	.string_loop:
	add	bx,STRING_SIZE
	or	bx,bx
	jz	.string_done
	STRING_NEXT(ax, bx)
	test	ax,2
	jnz	.string_loop

	; Write out the ID and contents.
	mov	[.buffer + 0],bx
	mov	[.buffer + 2],ax
	mov	ax,[gs:bx + 2]
	mov	[.buffer + 4],ax
	mov	ax,[gs:bx + 4]
	mov	[.buffer + 6],ax
	mov	ax,[gs:bx + 6]
	mov	[.buffer + 8],ax
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,10
	push	bx
	call	write_file
	pop	bx
	jmp	.string_loop
	.string_done:

	; Write separator.
	mov	word [.buffer],0
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,10
	call	write_file

	; Save the environment ID and symbol table.
	mov	ax,[repl.environment]
	mov	[.buffer + 0],ax
	mov	ax,[obj_symbol_table]
	mov	[.buffer + 2],ax
	mov	di,.buffer
	mov	ax,ds
	mov	es,ax
	mov	cx,4
	call	write_file

	call	close_file
	xor	bx,bx
	ret

	.buffer: times 10 db 0

do_builtin_env_import:
	or	di,di
	jz	error_cannot_env
	mov	[.environment_dest],di

	; Open the file to import from.
	mov	cx,NEXT_ARG_FINAL
	call	next_filename_argument
	mov	dx,FILE_READ
	mov	si,next_filename_argument.name
	call	open_file
	cmp	si,0xFFFF
	je	error_cannot_open_file

	; Garbage collect now, since we can't during the import.
	push	si
	call	garbage_collect
	mov	byte [gc_ready],0
	pop	si

	; Clear the re-link segment.
	mov	ax,0x4000
	mov	es,ax
	mov	cx,32768
	xor	ax,ax
	xor	di,di
	rep	stosw

	; Check the file signature.
	mov	cx,4
	mov	ax,ds
	mov	es,ax
	mov	di,.buffer
	call	read_file
	cmp	cx,4
	jne	error_read_file
	cmp	word [.buffer + 0],'en'
	jne	error_bad_signature
	cmp	word [.buffer + 2],('v' + 0x1000)
	jne	error_bad_signature

	; Load the objects.
	.load_object_loop:
	mov	cx,6
	mov	ax,ds
	mov	es,ax
	mov	di,.buffer
	call	read_file
	cmp	cx,6
	jne	error_read_file
	cmp	word [.buffer],0
	jz	.load_object_done
	mov	ax,[.buffer + 2]
	mov	dx,[.buffer + 4]
	call	new_object
	mov	ax,0x4000
	mov	es,ax
	mov	di,[.buffer + 0]
	shr	di,1
	mov	[es:di],bx
	jmp	.load_object_loop
	.load_object_done:

	; Load the strings.
	.load_string_loop:
	mov	cx,10
	mov	ax,ds
	mov	es,ax
	mov	di,.buffer
	call	read_file
	cmp	cx,10
	jne	error_read_file
	cmp	word [.buffer],0
	jz	.load_string_done
	call	new_string
	mov	ax,[.buffer + 2]
	mov	[gs:bx + 0],ax
	mov	ax,[.buffer + 4]
	mov	[gs:bx + 2],ax
	mov	ax,[.buffer + 6]
	mov	[gs:bx + 4],ax
	mov	ax,[.buffer + 8]
	mov	[gs:bx + 6],ax
	mov	ax,0x4000
	mov	es,ax
	mov	di,[.buffer + 0]
	shr	di,2
	mov	[es:di + 0x8000],bx
	jmp	.load_string_loop
	.load_string_done:

	; Load the environment ID and symbol table.
	mov	cx,4
	mov	ax,ds
	mov	es,ax
	mov	di,.buffer
	call	read_file
	cmp	cx,4
	jne	error_read_file
	mov	ax,[.buffer + 0]
	mov	[.environment],ax
	mov	ax,[.buffer + 2]
	mov	[.symbol_table],ax

	; Close the file.
	call	close_file

	; Use the re-link table segment.
	mov	ax,0x4000
	mov	es,ax

	; Re-link objects.
	call	.relink_objects

	; Re-link strings.
	mov	bx,0x8000
	.link_string_loop:
	cmp	bx,0xC000
	je	.link_string_done
	mov	di,[es:bx]
	or	di,di
	jz	.link_string_next
	STRING_NEXT(si, di)
	or	si,si
	jz	.link_string_next
	shr	si,2
	mov	ax,[es:si + 0x8000]
	mov	[gs:di],ax
	.link_string_next:
	add	bx,2
	jmp	.link_string_loop
	.link_string_done:

	; Save the new environment ID and symbol table before we identity map the link table.
	mov	si,[.symbol_table]
	shr	si,1
	mov	si,[es:si]
	mov	[.symbol_table],si
	mov	si,[.environment]
	shr	si,1
	mov	si,[es:si]
	mov	[.environment],si

	; Identity map all objects.
	mov	ax,0x4000
	mov	es,ax
	mov	cx,65536 / OBJ_SIZE
	xor	ax,ax
	xor	di,di
	.identity_loop:
	mov	[es:di],ax
	add	di,2
	add	ax,4
	loop	.identity_loop

	; Identity map all strings.
	mov	cx,65536 / STRING_SIZE
	xor	ax,ax
	mov	di,0x8000
	.identity_loop2:
	mov	[es:di],ax
	add	di,2
	add	ax,8
	loop	.identity_loop2

	; Intern symbols.
	mov	si,[.symbol_table]
	.symbol_loop:
	or	si,si
	jz	.symbol_done
	CAR(bx, si)
	push	si
	mov	di,.symbol
	mov	cx,(MAX_SYMBOL_LENGTH + 1)
	CDR(bx, bx)
	call	string_flatten
	mov	si,.symbol
	call	find_symbol
	pop	si
	CAR(di, si)
	shr	di,1
	mov	ax,0x4000
	mov	es,ax
	mov	[es:di],bx
	CDR(si, si)
	jmp	.symbol_loop
	.symbol_done:

	; Re-link objects again to use interned symbols.
	call	.relink_objects

	; Append the environment.
	mov	si,[.environment]
	.environment_loop:
	CDR(ax, si)
	or	ax,ax
	jz	.environment_found
	mov	si,ax
	jmp	.environment_loop
	.environment_found:
	mov	bx,[.environment_dest]
	mov	ax,[ss:bx]
	SETCDR(si, ax)
	mov	si,[.environment]
	mov	[ss:bx],si

	; We're done!
	mov	byte [gc_ready],1
	xor	bx,bx
	ret

	.buffer: times 10 db 0
	.environment: dw 0
	.environment_dest: dw 0
	.symbol: times (MAX_SYMBOL_LENGTH + 1) db 0
	.symbol_table: dw 0

	.relink_objects:
	xor	bx,bx
	mov	ax,0x4000
	mov	es,ax
	.link_object_loop:
	cmp	bx,0x8000
	je	.link_object_done
	mov	di,[es:bx]
	or	di,di
	jz	.link_object_next
	CAR(si, di)
	cmp	si,TYPE_LAMBDA
	je	.link_cdr
	cmp	si,TYPE_MACRO
	je	.link_cdr
	cmp	si,TYPE_SYMBOL
	je	.link_cdr
	test	si,2
	jz	.link_both
	cmp	si,TYPE_STRING
	jne	.link_object_next
	CDR(si, di)
	shr	si,2
	mov	ax,[es:si + 0x8000]
	SETCDR(di, ax)
	.link_object_next:
	add	bx,2
	jmp	.link_object_loop
	.link_both:
	shr	si,1
	mov	ax,[es:si]
	SETCAR(di, ax)
	.link_cdr:
	CDR(si, di)
	shr	si,1
	mov	ax,[es:si]
	SETCDR(di, ax)
	add	bx,2
	jmp	.link_object_loop
	.link_object_done:
	ret

do_builtin_inspect:
	mov	cx,NEXT_ARG_FINAL | NEXT_ARG_ANY | NEXT_ARG_BX
	call	next_argument
	CAR(ax, bx)
	cmp	ax,TYPE_LAMBDA
	je	.inspect
	cmp	ax,TYPE_MACRO
	je	.inspect
	.print:
	mov	cx,-100
	xor	dx,dx
	ALL_PUSH(bx)
	call	print_object
	xor	bx,bx
	ret
	.inspect:
	CDR(bx, bx)
	CAR(bx, bx)
	jmp	.print

do_builtin_pause:
	or	bx,bx
	jnz	error_too_many_arguments
	.loop:
	xor	ah,ah
	int	0x1A
	cmp	dx,[.previous_time]
	je	.loop
	mov	[.previous_time],dx
	add	[do_builtin_random.seed],dx
	add	[do_builtin_random.seed],cx
	xor	bx,bx
	ret
	.previous_time: dw 0

do_builtin_last_scancode:
	or	bx,bx
	jnz	error_too_many_arguments

	mov	ah,1
	int	0x16
	jz	.none
	mov	[last_scancode],ah
	xor	ah,ah
	int	0x16

	.none:
	mov	ax,TYPE_INT
	mov	dx,[last_scancode]
	jmp	new_object

do_builtin_random:
	or	bx,bx
	jnz	error_too_many_arguments
	mov	ax,[.seed]
	add	ax,12345
	mov	cx,9781
	mul	cx
	mov	dx,ax
	mov	ax,TYPE_INT
	jmp	new_object
	.seed: dw 0

do_builtin_outb:
	mov	cx,TYPE_INT
	call	next_argument
	mov	di,cx
	CDR(di, di)
	mov	cx,TYPE_INT | NEXT_ARG_FINAL | NEXT_ARG_BX
	call	next_argument
	CDR(ax, bx)
	mov	dx,di
	out	dx,al
	xor	bx,bx
	ret

; bp - all list (preserved, unless _KEEP set)
; si - environment (preserved)
; bx - argument list pointer (updated)
; cx - desired argument type and flags
; argument stored in cx
; additionally preserves ax, dx and di
next_argument:
	; Check there is another argument.
	or	bx,bx
	jz	error_insufficient_arguments

	push	dx
	push	di
	mov	dx,cx

	; Get the next argument and go to the next element in the list.
	CAR(cx, bx)
	CDR(bx, bx)

	; Check this is the last argument, if requested.
	test	dx,NEXT_ARG_FINAL
	jz	.done_final_check
	or	bx,bx
	jnz	error_too_many_arguments
	.done_final_check:

	; Evaluate the argument with tail call recursion, if requested.
	test	dx,NEXT_ARG_TAIL
	jz	.done_tail
	add	sp,4 ; pop dx, di
	mov	bx,cx
	xor	di,di
	ALL_POP(2) ; function and environment
	jmp	evaluate_object
	.done_tail:

	; Evaluate the argument, if requested.
	test	dx,NEXT_ARG_QUOTE
	jnz	.done_evaluate
	push	ax
	push	bx
	push	dx
	push	si
	push	bp
	mov	bx,cx
	xor	di,di
	call	evaluate_object
	mov	cx,bx
	pop	bp
	pop	si
	pop	dx
	pop	bx
	pop	ax
	.done_evaluate:

	; Add the result to the all list, if requested.
	test	dx,NEXT_ARG_KEEP
	jz	.done_keep
	ALL_PUSH(cx)
	.done_keep:

	; Check the type is correct, if requested.
	test	dx,NEXT_ARG_NIL
	jz	.no_nil_flag
	or	cx,cx
	jz	.done_type_check
	.no_nil_flag:
	test	dx,NEXT_ARG_ANY
	jnz	.done_type_check
	mov	di,cx
	CAR(di, di)
	or	dl,dl
	jnz	.type_non_pair
	and	di,2
	.type_non_pair:
	push	dx
	xor	dh,dh
	cmp	dx,di
	jne	error_wrong_type
	pop	dx
	.done_type_check:

	; Move the result to bx, if requested.
	test	dx,NEXT_ARG_BX
	jz	.done_bx
	mov	bx,cx
	.done_bx:

	pop	di
	pop	dx

	ret

; bx - environment
tidy_environment:
	; Mark all string objects in use, and mark all duplicates.
	push	bx
	.mark_loop:
	or	bx,bx
	jz	.mark_done
	CAR(di, bx)
	CAR(di, di)
	CAR(si, di)
	test	si,1
	jnz	.already_marked
	or	si,1
	SETCAR(di, si)
	jmp	.mark_next
	.already_marked:
	xor	ax,ax
	SETCAR(bx, ax)
	.mark_next:
	CDR(bx, bx)
	jmp	.mark_loop
	.mark_done:
	pop	bx

	; Unlink duplicates.
	push	bx
	.unlink_loop:
	or	bx,bx
	jz	.unlink_done
	CAR(ax, bx)
	or	ax,ax
	jnz	.unlink_next
	CDR(si, bx)
	SETCDR(di, si)
	mov	bx,di
	.unlink_next:
	mov	di,bx
	CDR(bx, bx)
	jmp	.unlink_loop
	.unlink_done:
	pop	bx

	; Finally, remove the mark from the string objects.
	.unmark_loop:
	or	bx,bx
	jz	.unmark_done
	CAR(di, bx)
	CAR(di, di)
	CAR(si, di)
	and	si,~1
	SETCAR(di, si)
	CDR(bx, bx)
	jmp	.unmark_loop
	.unmark_done:

	ret

; si - environment
; bx - canonical string object for symbol
; returns object in bx
; preserves ax, cx, dx
lookup_symbol:
	; Are we at the end of the environment list?
	or	si,si
	jz	error_symbol_not_found

	; Does the string object match?
	CAR(di, si)
	CAR(di, di)
	cmp	di,bx
	je	.match

	; Go to the next value in the environment.
	CDR(si, si)
	jmp	lookup_symbol

	; Return the value pair.
	.match:
	CAR(bx, si)
	ret

; bp - all list (preserved)
; si - string to search for
; returns object in bx
find_symbol:
	; Look through the symbol table for a match.
	mov	di,[obj_symbol_table]
	.table_loop:
	or	di,di
	jz	.not_found
	CAR(bx, di)
	CDR(bx, bx)
	push	si
	call	string_compare_with_literal
	pop	si
	jc	.match
	CDR(di, di)
	jmp	.table_loop
	.match:
	CAR(bx, di)
	ret

	; Create a new string object.
	.not_found:
	push	si
	mov	ax,TYPE_STRING
	xor	dx,dx ; new_string could gc, so this should be valid
	call	new_object
	ALL_PUSH(bx)
	push	bx
	call	new_string
	pop	di
	SETCDR(di,bx)
	push	di

	; Add the string object to the symbol table.
	push	bx
	mov	ax,di
	mov	dx,[obj_symbol_table]
	call	new_object
	mov	[obj_symbol_table],bx
	ALL_POP(1)

	; Append the characters to the string.
	pop	bx
	pop	di
	pop	si
	push	di
	.append_loop:
	lodsb
	or	al,al
	jz	.string_complete
	push	si
	call	string_append_character
	pop	si
	jmp	.append_loop
	.string_complete:

	pop	bx
	ret

; bp - all list (preserved)
; bx - string (modified if tail section changes)
; al - character
string_append_character:
	push	bx

	; Look for a free place in the current section.
	mov	cx,STRING_DATA
	add	bx,2
	.loop:
	cmp	byte [gs:bx],0
	je	.store
	inc	bx
	loop	.loop
	sub	bx,8

	; Allocate a new section.
	push	ax
	call	new_string
	pop	ax
	pop	si
	mov	[gs:si],bx
	push	bx
	add	bx,2

	; Store the character.
	.store:
	mov	[gs:bx],al
	pop	bx
	ret

; bx - string 1
; di - string 2
; carry set if equal
string_compare:
	mov	cx,STRING_DATA
	STRING_NEXT(dx, bx)
	STRING_NEXT(si, di)
	add	bx,2
	add	di,2
	.loop:
	mov	al,[gs:di]
	cmp	al,[gs:bx]
	jne	.not_equal
	or	al,al
	je	.equal
	inc	bx
	inc	di
	loop	.loop
	mov	bx,dx
	mov	di,si
	jmp	string_compare
	.not_equal:
	clc
	ret
	.equal:
	stc
	ret

; bx - string
; si - literal
; carry set if equal
; preserves di
string_compare_with_literal:
	mov	cx,STRING_DATA
	STRING_NEXT(dx, bx)
	add	bx,2
	.loop:
	lodsb
	cmp	al,[gs:bx]
	jne	string_compare.not_equal
	or	al,al
	je	string_compare.equal
	inc	bx
	loop	.loop
	mov	bx,dx
	jmp	string_compare_with_literal

; bx - string
; di - destination buffer
; cx - size of the destination buffer (including space to put null byte)
; carry set if destination buffer was too small
; preserves bp
string_flatten:
	mov	si,cx
	.next_section:
	mov	cx,STRING_DATA
	STRING_NEXT(dx, bx)
	add	bx,2
	.loop:
	mov	al,[gs:bx]
	inc	bx
	or	si,si
	jz	.full
	mov	[di],al
	inc	di
	dec	si
	or	al,al
	jz	.done
	loop	.loop
	mov	bx,dx
	jmp	.next_section
	.done:
	clc
	ret
	.full:
	stc
	ret

; bp - all list (preserved)
; returns string in bx
new_string:
%ifdef ALWAYS_GC
	call	garbage_collect
%endif

	; If there are no more free string, call the garbage collector.
	cmp	word [first_free_string],0
	jne	.got_memory
	call	garbage_collect
	cmp	word [first_free_string],0
	je	error_out_of_memory
	.got_memory:

	; Remove the first free string from the list.
	mov	bx,[first_free_string]
	STRING_NEXT(ax, bx)
	and	ax,0xFFFC
	mov	[first_free_string],ax

	; Clear the contents of the string.
	xor	ax,ax
	mov	word [gs:bx+0],ax
	mov	word [gs:bx+2],ax
	mov	word [gs:bx+4],ax
	mov	word [gs:bx+6],ax

	ret

; bp - all list (preserved)
; ax - low word (preserved)
; dx - high word (preserved)
; returns object in bx
; additionally preserves si
new_object:
	push	ax
	push	dx
	push	si

%ifdef ALWAYS_GC
	call	garbage_collect
%endif

	; If there are no more free objects, call the garbage collector.
	cmp	word [first_free_object],0
	jne	.got_memory
	call	garbage_collect
	cmp	word [first_free_object],0
	je	error_out_of_memory
	.got_memory:

	; Remove the first free object from the list.
	mov	bx,[first_free_object]
	CDR(ax, bx)
	mov	[first_free_object],ax

	; Set the contents of the object.
	pop	si
	pop	dx
	pop	ax
	SETCAR(bx, ax)
	SETCDR(bx, dx)

	ret

; bp - all list (preserved)
garbage_collect:
	; If we system has not yet been initialized, then we can't garbage collect.
	cmp	byte [gc_ready],0
	je	.done

	; Mark the all list and the symbol table.
	mov	bx,[obj_symbol_table]
	call	mark_object
	mov	di,bp
	.mark_loop:
	cmp	di,ALL_LIST_TOP
	je	.mark_complete
	mov	bx,[ss:di]
	call	mark_object
	add	di,2
	jmp	.mark_loop
	.mark_complete:

	; Iterate over all strings.
	mov	cx,(65536 / STRING_SIZE - 1)
	mov	bx,STRING_SIZE
	.string_loop:

	; Store and clear the mark.
	STRING_NEXT(ax, bx)
	and	byte [gs:bx],0xFE

	; If the mark is set, or the string was already free, don't free the string.
	test	ax,3
	jnz	.next_string

	; Free the string.
	mov	ax,[first_free_string]
	or	ax,2
	mov	word [gs:bx],ax
	mov	[first_free_string],bx

	; Go to the next string.
	.next_string:
	add	bx,STRING_SIZE
	loop	.string_loop

	; Iterate over all objects.
	mov	cx,(65536 / OBJ_SIZE - 1)
	mov	bx,OBJ_SIZE
	.object_loop:

	; Store and clear the mark.
	CAR(ax, bx)
	and	byte [fs:bx],0xFE

	; If the mark is set, or the object was already free, don't free the object.
	test	ax,1
	jnz	.next_object
	cmp	ax,TYPE_FREE
	je	.next_object

	; Free the object.
	mov	ax,[first_free_object]
	SETCDR(bx, ax)
	mov	ax,TYPE_FREE
	SETCAR(bx, ax)
	mov	[first_free_object],bx

	; Go to the next object.
	.next_object:
	add	bx,OBJ_SIZE
	loop	.object_loop

	.done:
	ret

get_memory_usage:
	call	garbage_collect
	xor	ax,ax
	
	; Count used objects.
	xor	bx,bx
	mov	cx,(65536 / OBJ_SIZE)
	.object_loop:
	CAR(dx, bx)
	cmp	dx,TYPE_FREE
	je	.object_free
	inc	ax
	.object_free:
	add	bx,OBJ_SIZE
	loop	.object_loop

	; Count used strings.
	xor	bx,bx
	mov	cx,(65536 / STRING_SIZE)
	.string_loop:
	STRING_NEXT(dx, bx)
	test	dx,2
	jnz	.string_free
	add	ax,2
	.string_free:
	add	bx,STRING_SIZE
	loop	.string_loop

	ret

; bx - object to recursively GC mark
; preserves bp
mark_object:
	CHECK_STACK_OVERFLOW

	; Don't mark the nil object.
	or	bx,bx
	jz	.done

	; Has the object already been marked?
	CAR(ax, bx)
	test	ax,1
	jnz	.done

	; Mark the object.
	or	byte [fs:bx],1

	; Is the object a pair?
	test	ax,2
	jz	.mark_both

	; Is the object a lambda or macro?
	cmp	ax,TYPE_LAMBDA
	je	.mark_cdr
	cmp	ax,TYPE_MACRO
	je	.mark_cdr

	; Is the object a string?
	cmp	ax,TYPE_STRING
	je	.string

	cmp	ax,TYPE_FREE
	je	error_free_accessible

	.done:
	ret

	.mark_both:
	push	bx
	mov	bx,ax
	call	mark_object
	pop	bx
	.mark_cdr:
	CDR(bx, bx)
	jmp	mark_object

	.string:
	CDR(bx, bx)
	jmp	mark_string

; bx - string to GC mark
; preserves bp
mark_string:
	; Don't mark the nil string.
	or	bx,bx
	jz	.done

	; Has the section already been marked?
	STRING_NEXT(ax, bx)
	test	ax,2
	jnz	.done

	; Mark the section.
	or	byte [gs:bx],1

	; Go to the next section.
	mov	bx,ax
	jmp	mark_string
	
	.done:
	ret

; preserves all registers
reset_output:
	pusha
	mov	byte [output_color],(SCREEN_COLOR >> 8)
	mov	word [print_callback],terminal_print_string
	call	set_text_mode
	popa
	ret

; ax - message
error_runtime:
	call	reset_output
	mov	si,.message
	call	print_string
	mov	si,ax
	call	print_string
	jmp	[recover]
	.message: db 'Runtime error: ',0

error_out_of_memory:
	mov	ax,.message
	jmp	error_runtime
	.message: db 'out of memory',10,0

error_stack_overflow:
	mov	ax,.message
	jmp	error_runtime
	.message: db 'stack overflow',10,0

; ax - message
error_read:
	call	reset_output
	mov	si,.message
	call	print_string
	mov	si,ax
	call	print_string
	mov	si,.line
	call	print_string
	mov	ax,[input_line]
	call	print_s16
	call	print_newline
	jmp	[recover]
	.message: db 'Read error: ',0
	.line: db 'at line ',0

error_unexpected_eoi:
	mov	ax,.message
	jmp	error_read
	.message: db 'unexpected end of input',10,0

error_symbol_too_long:
	mov	ax,.message
	jmp	error_read
	.message: db 'symbol too long (max is 24 characters)',10,0

error_integer_too_large:
	mov	ax,.message
	jmp	error_read
	.message: db 'integer too large (must be between -32768 and 32767)',10,0

error_invalid_dot:
	mov	ax,.message
	jmp	error_read
	.message: db 'invalid dotted list (dot must be after penultimate item)',10,0

error_unexpected_character:
	mov	ax,.message
	jmp	error_read
	.message: db 'unexpected character',10,0

; ax - message
; bx - object
error_evaluate:
	call	reset_output
	mov	si,.message
	call	print_string
	mov	si,ax
	call	print_string
	mov	cx,-5
	or	bx,bx
	jz	.no_object
	call	print_object
	.no_object:
	call	print_newline
	jmp	[recover]
	.message: db 'Evaluate error: ',0

error_symbol_not_found:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'symbol not found - ',0

error_not_callable:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'object not callable',10,0

error_insufficient_arguments:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'insufficient arguments',10,0

error_too_many_arguments:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'too many arguments',10,0

error_wrong_type:
	mov	bx,cx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'incorrect argument type',10,0

error_cannot_let:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'cannot use let in this context',10,0

error_cannot_src:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'cannot use src in this context',10,0

error_cannot_env:
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'cannot modify environment in this context',10,0

error_file_name_too_long:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'the file name is too long (max 15 characters)',10,0

error_cannot_open_file:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'the file could not be found, or is already in use',10,0

error_file_already_exists:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'the file already exists',10,0

error_read_file:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'the file could not be read',10,0

error_divide_error:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'divide error (division by zero, or muldiv result too large)',10,0

error_break:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'Ctrl+C pressed',10,0

error_bad_signature:
	xor	bx,bx
	mov	ax,.message
	jmp	error_evaluate
	.message: db 'file does not contain environment',10,0

; ax - message
error_internal:
	call	reset_output
	mov	si,.message
	call	print_string
	mov	si,ax
	call	print_string
	hlt
	jmp	$
	.message: db 'Internal error: ',0

error_free_accessible:
	mov	ax,.message
	jmp	error_internal
	.message: db 'an accessible object was freed',10,0

error_unknown:
	mov	ax,.message
	jmp	error_internal
	.message: db 'general failure',10,0

error_unimplemented_builtin:
	mov	ax,.message
	jmp	error_internal
	.message: db 'unimplemented builtin',10,0

error_io_fatal:
	mov	ax,.message
	jmp	error_internal
	.message: db 'could not access boot disk',10,0

install_exception_handlers:
	xor	ax,ax
	mov	es,ax
	mov	word [es: 0],error_divide_error
	mov	word [es: 2],0x1000
	mov	word [es: 4],error_unknown
	mov	word [es: 6],0x1000
	mov	word [es: 8],error_unknown
	mov	word [es:10],0x1000
	mov	word [es:12],error_unknown
	mov	word [es:14],0x1000
	mov	word [es:16],error_unknown
	mov	word [es:18],0x1000
	mov	word [es:20],error_unknown
	mov	word [es:22],0x1000
	mov	word [es:24],error_unknown
	mov	word [es:26],0x1000
	mov	word [es:28],error_unknown
	mov	word [es:30],0x1000
	ret

; bx - object
; cx - depth limit
; dx - 0 to quote strings
; bp - all list (preserved)
print_object:
	CHECK_STACK_OVERFLOW

	CAR(ax, bx)

	cmp	ax,TYPE_BUILTIN
	je	.builtin
	cmp	ax,TYPE_SYMBOL
	je	.symbol
	cmp	ax,TYPE_STRING
	je	.string
	cmp	ax,TYPE_NIL
	je	.nil
	cmp	ax,TYPE_INT
	je	.integer
	cmp	ax,TYPE_LAMBDA
	je	.lambda
	cmp	ax,TYPE_MACRO
	je	.macro

	and	ax,2
	cmp	ax,0
	je	.pair

	mov	si,unknown_type_message
	jmp	print_string

	.builtin:
	mov	si,builtin_message
	call	print_string
	CDR(ax, bx)
	call	print_s16
	mov	si,close_sign_message
	call	print_string
	ret

	.symbol:
	CDR(bx, bx)
	CDR(bx, bx)
	jmp	print_string_list

	.string:
	or	dl,dl
	jnz	.unquoted_string
	mov	si,string_quote_message
	call	print_string
	CDR(bx, bx)
	call	print_string_list
	mov	si,string_quote_message
	jmp	print_string
	.unquoted_string:
	CDR(bx, bx)
	jmp	print_string_list

	.nil:
	mov	si,nil_message
	jmp	print_string

	.lambda:
	mov	si,lambda_message
	call	print_string
	CDR(ax, bx)
	call	print_word
	mov	si,close_sign_message
	call	print_string
	ret

	.macro:
	mov	si,macro_message
	call	print_string
	CDR(ax, bx)
	call	print_word
	mov	si,close_sign_message
	call	print_string
	ret

	.integer:
	CDR(ax, bx)
	jmp	print_s16

	.pair:
	mov	si,list_start_message
	call	print_string
	cmp	cx,-1
	je	.depth_limit_reached
	inc	cx
	push	cx
	push	bx
	CAR(bx, bx)
	xor	dx,dx
	call	print_object
	pop	bx
	pop	cx
	CDR(bx, bx)

	.list_loop:
	CAR(ax, bx);
	test	ax,2
	jnz	.list_end
	mov	si,space_message
	call	print_string
	push	cx
	push	bx
	CAR(bx, bx)
	xor	dx,dx
	call	print_object
	pop	bx
	pop	cx
	CDR(bx, bx)
	jmp	.list_loop

	.list_end:
	or	bx,bx
	jz	.list_close
	mov	si,dot_message
	call	print_string
	xor	dx,dx
	call	print_object

	.list_close:
	mov	si,list_end_message
	call	print_string
	ret

	.depth_limit_reached:
	mov	si,depth_limit_reached_message
	jmp	print_string

; bx - string list
print_string_list:
	or	bx,bx
	jz	.done
	mov	si,.buffer
	mov	al,[gs:bx+2]
	mov	[si+0],al
	mov	al,[gs:bx+3]
	mov	[si+1],al
	mov	al,[gs:bx+4]
	mov	[si+2],al
	mov	al,[gs:bx+5]
	mov	[si+3],al
	mov	al,[gs:bx+6]
	mov	[si+4],al
	mov	al,[gs:bx+7]
	mov	[si+5],al
	call	print_string
	STRING_NEXT(bx, bx)
	jmp	print_string_list
	.done:
	ret
	.buffer: db 0,0,0,0,0,0,0

clear_screen:
	mov	ax,0xB800
	mov	es,ax
	mov	ax,SCREEN_COLOR
	mov	cx,80 * 25
	xor	di,di
	rep	stosw
	ret

output_null:
	ret

terminal_print_string:
	.loop:
	lodsb
	or	al,al
	jz	.done
	push	si
	call	terminal_print_character
	pop	si
	jmp	.loop
	.done:	
	call	update_caret
	ret

; al - character
print_character:
	pusha
	mov	[.buffer],al
	mov	si,.buffer
	call	[print_callback]
	popa
	ret
	.buffer: dw 0

; si - zero-terminated string
; bp - all list (if print callback is not to the terminal)
; preserves all registers
print_string:
	pusha
	call	[print_callback]
	popa	
	ret

update_caret:
	mov	ax,[caret_row]
	mov	dx,80
	mul	dx
	add	ax,[caret_column]
	mov	bx,ax
	mov	dx,0x03D4
	mov	al,0x0F
	out	dx,al
	mov	dx,0x03D5
	mov	al,bl
	out	dx,al
	mov	dx,0x03D4
	mov	al,0x0E
	out	dx,al
	mov	dx,0x03D5
	mov	al,bh
	out	dx,al
	ret

; al - character
terminal_print_character:
	mov	cx,0xB800
	mov	es,cx
	cmp	al,10
	je	.newline
	mov	cx,ax
	call	get_caret_position
	mov	ax,cx
	mov	[es:bx],al
	mov	al,[output_color]
	mov	[es:bx + 1],al
	mov	bx,[caret_column]
	inc	bx
	cmp	bx,79
	je	.newline
	mov	[caret_column],bx
	ret

	.newline:
	mov	bx,1
	mov	[caret_column],bx
	mov	bx,[caret_row]
	inc	bx
	cmp	bx,25
	je	.scroll
	mov	[caret_row],bx
	ret

	.scroll:
	mov	bx,[user_input_start]
	sub	bx,160
	mov	[user_input_start],bx
	mov	bx,[previously_unmatched_brace]
	or	bx,bx
	jz	.e1
	sub	bx,160
	mov	[previously_unmatched_brace],bx
	.e1:
	mov	cx,80 * 24
	mov	si,160
	mov	di,0
	.scroll_loop:
	mov	ax,[es:si]
	mov	[es:di],ax
	add	si,2
	add	di,2
	loop	.scroll_loop
	mov	ax,SCREEN_COLOR
	mov	cx,80
	rep	stosw
	ret

print_backspace:
	mov	ax,[caret_column]
	cmp	ax,1
	je	.up
	dec	ax
	mov	[caret_column],ax
	jmp	update_caret
	.up:
	mov	word [caret_column],78
	dec	word [caret_row]
	jmp	update_caret

; ax - int to print
; preserves registers
print_s16:
	pusha
	cmp	ax,0
	jg	.positive
	je	.zero
	push	ax
	mov	al,'-'
	call	print_character
	pop	ax
	neg	ax
	.positive:
	mov	si,.buffer + 4
	.divide_loop:
	or	ax,ax
	jz	.done
	xor	dx,dx
	mov	cx,10
	div	cx
	add	dl,'0'
	mov	[si],dl
	dec	si
	jmp	.divide_loop
	.done:
	inc	si
	call	print_string
	popa
	ret
	.zero:
	mov	al,'0'
	call	print_character
	popa
	ret
	.buffer: db 0, 0, 0, 0, 0, 0

; ax - word to print in hex
; preserves registers
print_word:
	pusha
	mov	cx,ax
	mov	bx,cx
	shr	bx,12
	and	bx,15
	mov	al,[hex_characters + bx]
	push	cx
	call	print_character
	pop	cx
	mov	bx,cx
	shr	bx,8
	and	bx,15
	mov	al,[hex_characters + bx]
	push	cx
	call	print_character
	pop	cx
	mov	bx,cx
	shr	bx,4
	and	bx,15
	mov	al,[hex_characters + bx]
	push	cx
	call	print_character
	pop	cx
	mov	bx,cx
	and	bx,15
	mov	al,[hex_characters + bx]
	call	print_character
	popa
	ret

; preserves registers
print_newline:
	pusha
	mov	al,10
	call	print_character
	popa
	ret

initialize_io:
	; Get drive parameters.
	mov	ah,0x08
	mov	dl,[drive_number]
	xor	di,di
	int	0x13
	jc	error_io_fatal
	and	cx,31
	mov	[max_sectors],cx
	inc	dh
	shr	dx,8
	mov	[max_heads],dx

	; Load the filesystem header.
	mov	ax,ds
	mov	es,ax
	mov	di,1
	mov	bx,FS_HEADER_BUFFER
	call	read_sector
	jc	error_io_fatal

	; Check for correct signature and version.
	mov	ax,[FS_HEADER_BUFFER]
	cmp	ax,0x706C
	jne	error_io_fatal
	mov	ax,[FS_HEADER_BUFFER + 2]
	cmp	ax,1
	jne	error_io_fatal

	ret

; di - LBA.
; es:bx - buffer
; returns carry set on error
read_sector:
	xor	si,si
	jmp	access_sector

; di - LBA.
; es:bx - buffer
; returns carry set on error
write_sector:
	mov	si,1
	jmp	access_sector

; di - LBA.
; es:bx - buffer
; si - 1 to write, 0 to read
; returns carry set on error
access_sector:
	mov	byte [read_attempts],5

	.try_again:

	mov	al,[read_attempts]
	or	al,al
	jz	.error
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

	; Access the sector.
	pop	dx
	mov	dh,dl
	mov	dl,[drive_number]
	push	si
	or	si,si
	jz	.read
	mov	ax,0x0301
	int	0x13
	jmp	.done_int
	.read:
	mov	ax,0x0201
	int	0x13
	.done_int:
	pop	si
	jc	.try_again

	clc
	ret
	.error:
	stc
	ret

; preserves bx, cx, dx, di, bp
start_reading_root_directory:
	mov	word [ROOT_HANDLE + 0],0xFFFF ; position in root directory (invalid)
	mov	ax,[FS_HEADER_BUFFER + 12 + 16]
	mov	[ROOT_HANDLE + 2],ax          ; file size (low)
	mov	ax,[FS_HEADER_BUFFER + 12 + 18]
	mov	[ROOT_HANDLE + 4],ax          ; file size (high)
	mov	word [ROOT_HANDLE + 6],0      ; offset into sector
	mov	ax,[FS_HEADER_BUFFER + 12 + 20]
	mov	[ROOT_HANDLE + 8],ax          ; current sector
	mov	ax,1
	mov	[ROOT_HANDLE + 10],ax         ; access mode
	mov	si,ROOT_HANDLE
	pusha
	call	read_first_file_sector
	popa
	ret
	
; si - zero-terminated filename
; dx - 1 for read mode, 2 for write mode, 3 for append mode
;      read/append fails if file doesn't exist, write creates or truncates 
; returns file handle in si, or 0xFFFF if not found/on error
open_file:
	; Check the filename is between 1 and 15 bytes.
	mov	di,si
	.check_length:
	lodsb
	or	al,al
	jz	.got_length
	jmp	.check_length
	.got_length:
	mov	cx,si
	sub	cx,di
	cmp	cx,16
	ja	.error
	or	cx,cx
	jz	.error
	mov	[.name_length],cx
	mov	[.name],di
	mov	[.access_mode],dx

	; Setup the last file handle for reading the root directory.
	call	start_reading_root_directory
	jc	.error

	mov	word [.first_unused],0xFFFF

	; Loop through each entry of the root directory.
	.directory_loop:
	mov	ax,[ROOT_HANDLE + 8]
	mov	[.previous_sector],ax
	mov	si,ROOT_HANDLE
	mov	cx,0x20
	mov	bx,ds
	mov	es,bx
	mov	di,.directory_entry
	call	read_file
	cmp	cx,0x20
	jb	.not_found
	call	has_error_file
	jc	.error

	; Is the entry in use?
	cmp	byte [.directory_entry],0
	jne	.in_use
	mov	ax,[FS_HEADER_BUFFER + 12 + 16]
	sub	ax,[ROOT_HANDLE + 2]
	sub	ax,0x20 ; ...since the file pointer is now one past this entry
	and	ax,0x1FF
	mov	[.first_unused],ax
	mov	ax,[.previous_sector]
	mov	[.first_unused_sector],ax
	jmp	.directory_loop

	; Compare the filenames.
	.in_use:
	mov	ax,ds
	mov	es,ax
	mov	cx,[.name_length]
	mov	si,[.name]
	mov	di,.directory_entry
	rep	cmpsb
	jne	.directory_loop

	; Calculate the position of the file in the root directory.
	; The root directory cannot exceed 64KB, so we ignore the high file size.
	mov	ax,[FS_HEADER_BUFFER + 12 + 16]
	sub	ax,[ROOT_HANDLE + 2]
	sub	ax,0x20 ; ...since the file pointer is now one past this entry

	; Check the file isn't already open, and note the first available handle.
	mov	cx,MAX_OPEN_FILES
	mov	si,open_file_table
	mov	di,0xFFFF
	.check_not_open_loop:
	cmp	word [si + 10],0
	je	.not_in_use
	cmp	[si + 0],ax
	je	.error ; already open
	jmp	.next_open_check
	.not_in_use:
	mov	di,si
	.next_open_check:
	add	si,DATA_PER_OPEN_FILE
	loop	.check_not_open_loop

	; Were there any available handles?
	cmp	di,0xFFFF
	je	.error

	; Save the file information to the handle table.
	mov	[di + 0],ax ; position in root directory
	mov	ax,[.directory_entry + 16]
	mov	[di + 2],ax ; file size low
	mov	ax,[.directory_entry + 18]
	mov	[di + 4],ax ; file size high
	mov	word [di + 6],0 ; offset into sector
	mov	ax,[.directory_entry + 20]
	mov	[di + 8],ax ; current sector

	mov	si,di

	; If opening the file in write or delete mode, truncate the file.
	cmp	word [.access_mode],FILE_READ
	je	.not_truncate
	cmp	word [.access_mode],FILE_RENAME
	je	.not_truncate
	cmp	word [.access_mode],FILE_APPEND
	je	.not_truncate
	mov	ax,[si + 2]
	or	ax,[si + 4]
	or	ax,ax
	jz	.not_truncate ; the file size is zero, no need to truncate
	xor	ax,ax
	mov	[si + 2],ax ; file size = 0
	mov	[si + 4],ax
	mov	ax,[si + 8]
	push	si
	xor	dx,dx
	cmp	word [.access_mode],FILE_DELETE
	je	.truncate_all
	inc	dx
	.truncate_all:
	call	free_file_sectors
	pop	si
	jc	.error
	.not_truncate:

	; If opening the file in append mode, seek to the end of the file.
	cmp	word [.access_mode],FILE_APPEND
	jne	.not_append
	mov	cx,[si + 2]
	shr	cx,9
	mov	dx,[si + 4]
	shl	dx,7
	or	cx,dx
	.seek_loop:
	or	cx,cx
	jz	.seek_done
	push	cx
	push	si
	xor	cx,cx ; we read the sector in read_first_file_sector below
	call	read_next_file_sector
	pop	si
	pop	cx
	jc	.error
	dec	cx
	jmp	.seek_loop
	.seek_done:
	mov	cx,[si + 2]
	and	cx,511
	mov	[si + 6],cx
	.not_append:

	; If reading or appending, load the current sector.
	cmp	word [.access_mode],FILE_WRITE
	je	.skip_load_current_sector
	cmp	word [.access_mode],FILE_RENAME
	je	.skip_load_current_sector
	cmp	word [.access_mode],FILE_DELETE
	je	.skip_load_current_sector
	push	si
	call	read_first_file_sector
	pop	si
	jc	.error
	.skip_load_current_sector:

	; Return the file handle.
	mov	ax,[.access_mode]
	mov	[si + 10],al ; access mode
	mov	al,[.directory_entry + 23]
	mov	[si + 11],al ; checksum
	ret

	; The file was not found.
	.not_found:
	cmp	word [.access_mode],FILE_READ
	je	.error
	cmp	word [.access_mode],FILE_RENAME
	je	.error
	cmp	word [.access_mode],FILE_DELETE
	je	.error

	; Have we seen an unused entry to put the file in?
	mov	ax,[.first_unused]
	cmp	ax,0xFFFF
	je	.append_entry
	mov	ax,[.first_unused_sector]
	mov	[ROOT_HANDLE + 8],ax
	call	read_first_file_sector
	mov	bx,[.first_unused]
	jmp	.create_entry

	.append_entry:

	; Is there room in the last sector of the directory?
	mov	bx,[ROOT_HANDLE + 6]
	cmp	bx,0x200
	jne	.grown
	mov	si,ROOT_HANDLE
	call	grow_file
	mov	bx,[ROOT_HANDLE + 6]
	or	bx,bx
	jnz	error_unknown
	.grown:
	
	; Update the root directory's size in the header sector.
	push	bx
	add	word [FS_HEADER_BUFFER + 12 + 16],0x20
	mov	di,1
	mov	ax,ds
	mov	es,ax
	mov	bx,FS_HEADER_BUFFER
	call	write_sector
	pop	bx
	jc	.error

	; Create the new entry.
	.create_entry:
	add	bx,OPEN_FILE_BUFFER + SECTOR_SIZE * 7
	call	create_directory_entry
	jc	.error

	; Save the directory.
	mov	di,[ROOT_HANDLE + 8]
	mov	ax,ds
	mov	es,ax
	mov	bx,OPEN_FILE_BUFFER + SECTOR_SIZE * 7
	call	write_sector
	jc	.error

	jmp	.retry

	; Try to open the file again.
	.retry:
	mov	si,[.name]
	mov	dx,[.access_mode]
	jmp	open_file

	.error:
	mov	si,0xFFFF
	ret

	.directory_entry: times 0x20 db 0
	.name_length: dw 0
	.name: dw 0
	.access_mode: dw 0
	.first_unused: dw 0
	.first_unused_sector: dw 0
	.previous_sector: dw 0

; ax - first sector
; dx - the new table value for the first sector (i.e. 0 frees the whole file, 1 frees all but the first sector)
; carry set on error
free_file_sectors:
	; Switch the sector table.
	mov	bx,ax
	shr	ax,8
	push	bx
	push	dx
	call	switch_sector_table
	pop	dx
	pop	bx
	jc	.done

	; Write the updated entry.
	and	bx,255
	shl	bx,1
	mov	ax,[SECTOR_TABLE_BUFFER + bx]
	mov	[SECTOR_TABLE_BUFFER + bx],dx
	mov	byte [sector_table_modified],1
	
	; Free the next sector.
	xor	dx,dx
	cmp	ax,1
	jne	free_file_sectors
	clc
	.done:	ret

; bx - destination
; carry set on error
create_directory_entry:
	mov	ax,ds
	mov	es,ax

	; Clear the entry.
	mov	cx,0x20
	xor	al,al
	mov	di,bx
	rep	stosb

	; Save the file name.
	mov	si,[open_file.name]
	mov	cx,[open_file.name_length]
	mov	di,bx
	rep	movsb

	; Allocate the first sector.
	push	bx
	call	allocate_sector ; sets carry on error (returned)
	pop	bx
	mov	[bx + 20],ax
	ret

; returns allocated sector in ax
; carry set if disk full or error
allocate_sector:
	; Search the currently loaded table sector.
	cmp	byte [current_sector_table],0xFF
	je	.skip_initial_search
	call	.search_table_sector
	jnc	.done

	; Try other table sectors.
	.skip_initial_search:
	mov	byte [.current_search_table],0
	.table_loop:
	mov	al,[.current_search_table]
	call	switch_sector_table
	jc	.error
	call	.search_table_sector
	jnc	.done
	.next_table:
	mov	ax,[FS_HEADER_BUFFER + 8]
	dec	ax
	mov	bl,[.current_search_table]
	cmp	al,bl
	je	.error
	inc	bl
	mov	[.current_search_table],bl
	jmp	.table_loop

	.error:
	stc
	ret

	.current_search_table: db 0

	; Search the loaded sector table sector for a free sector.
	.search_table_sector:
	mov	cx,256 ; 512 byte sector, 2 bytes per entry
	mov	bx,SECTOR_TABLE_BUFFER
	.search_loop:
	cmp	word [bx],0
	jz	.search_found
	add	bx,2
	loop	.search_loop
	stc
	ret

	; Update the table.
	.search_found:
	mov	ax,bx
	shr	ax,1
	mov	ah,[current_sector_table]
	mov	word [bx],1 ; end of file
	mov	byte [sector_table_modified],1
	ret

	.done:
	ret

; sets carry on error
save_sector_table:
	cmp	byte [sector_table_modified],0
	je	.done
	mov	byte [sector_table_modified],0
	xor	ah,ah
	mov	al,[current_sector_table]
	mov	di,ax
	add	di,2
	mov	ax,ds
	mov	es,ax
	mov	bx,SECTOR_TABLE_BUFFER
	jmp	write_sector 
	.done:  ret

; si - file handle 
; carry set on error
flush_current_sector:
	call	get_file_buffer_offset
	mov	di,[si + 8] ; current sector
	mov	ax,ds
	mov	es,ax
	jmp	write_sector

; si - file handle
close_file:
	; Were we writing to this file?
	cmp	byte [si + 10],FILE_READ
	je	.done

	; Don't flush the file if we only opened it to rename or delete it.
	cmp	byte [si + 10],FILE_RENAME
	je	.skip_flush
	cmp	byte [si + 10],FILE_DELETE
	je	.skip_flush

	; We need to flush the file.
	push	si
	call	flush_current_sector
	pop	si
	.skip_flush:

	; Seek to the correct sector in the root directory.
	mov	cx,[si + 0] ; position in root directory
	shr	cx,9 ; get sector in root directory
	push	si
	call	start_reading_root_directory
	jc	.done
	or	cx,cx
	jz	.no_seek
	.find_directory_entry_loop:
	push	cx
	mov	si,ROOT_HANDLE
	call	read_next_file_sector ; cx = 1 on last iteration, which loads sector
	pop	cx
	jc	.pop
	loop	.find_directory_entry_loop
	.no_seek:
	pop	si

	; Update the directory entry.
	mov	bx,[si + 0]
	and	bx,511 ; get position within root directory sector
	mov	cx,[si + 2] ; file size low
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 16],cx
	mov	cx,[si + 4] ; file size high
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 18],cx
	mov	cl,[si + 11] ; checksum
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 23],cl

	; Rename the file, if necessary.
	cmp	byte [si + 10],FILE_RENAME
	jne	.skip_rename
	mov	ax,[next_filename_argument.name + 0]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 0],ax
	mov	ax,[next_filename_argument.name + 2]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 2],ax
	mov	ax,[next_filename_argument.name + 4]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 4],ax
	mov	ax,[next_filename_argument.name + 6]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 6],ax
	mov	ax,[next_filename_argument.name + 8]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 8],ax
	mov	ax,[next_filename_argument.name + 10]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 10],ax
	mov	ax,[next_filename_argument.name + 12]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 12],ax
	mov	ax,[next_filename_argument.name + 14]
	mov	[bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 14],ax
	.skip_rename:

	; Delete the entry, if necessary.
	cmp	byte [si + 10],FILE_DELETE
	jne	.skip_delete
	mov	byte [bx + OPEN_FILE_BUFFER + SECTOR_SIZE * 7 + 0],0
	.skip_delete:

	; Write out the directory entry.
	push	si
	mov	si,ROOT_HANDLE
	call	flush_current_sector

	; Finally, save the sector table (if it was modified).
	call	save_sector_table

	.pop:
	pop	si
	.done:
	mov	word [si + 10],0 ; clear access mode
	ret
	
; si - file handle
; carry set if file handle has error flag set
; everything preserved
has_error_file:
	test	word [si + 10],FILE_ERROR
	jz	.no_error
	stc
	ret
	.no_error:
	clc
	ret

; si - file handle (preserved)
; offset returned in bx
; additionally preserves di and es
get_file_buffer_offset:
	mov	ax,si
	sub	ax,open_file_table
	mov	cx,DATA_PER_OPEN_FILE
	xor	dx,dx
	div	cx
	mov	cx,0x200
	mul	cx
	mov	bx,OPEN_FILE_BUFFER
	add	bx,ax
	ret

; si - file handle (preserved)
; cx - bytes to write
; es:di - source
; may set error flag on handle
write_file:
	or	cx,cx
	jz	.done

	; Check error flag has not been set.
	mov	al,[si + 10]
	test	al,FILE_ERROR
	jnz	.done

	; Get the file buffer to use.
	push	cx
	call	get_file_buffer_offset
	mov	dx,bx
	pop	cx

	.loop:

	; Work out how many bytes we can write this iteration.
	; We are limited by the buffer size (a sector),
	; and the amount of requested bytes to write.
	mov	ax,cx
	mov	bx,0x200
	sub	bx,[si + 6] ; offset into sector
	cmp	bx,ax ; is remaining data in buffer limiting?
	ja	.e1
	mov	ax,bx
	.e1:
	or	ax,ax
	jz	.nothing_to_write

	; Write data to the buffer.
	mov	bl,[si + 11] ; checksum
	push	cx
	push	si
	push	ax
	mov	cx,ax
	mov	si,[si + 6]
	add	si,dx
	.write_loop:
	mov	al,[es:di]
	mov	[si],al
	inc	si
	inc	di
	xor	bl,al
	loop	.write_loop
	pop	ax
	pop	si
	pop	cx
	mov	[si + 11],bl

	; Update position in buffer, file size and remaining bytes to read.
	add	[si + 6],ax
	add	[si + 2],ax
	adc	word [si + 4],0
	sub	cx,ax

	.nothing_to_write:
	; If we are at the end of the buffer, then write the sector and allocate the next.
	cmp	word [si + 6],0x200
	jne	.sector_unfinished
	mov	ax,es
	push	ax
	push	cx
	push	dx
	push	di
	push	si
	call	flush_current_sector
	pop	si
	jc	.flush_failed
	call	grow_file
	.flush_failed:
	pop	di
	pop	dx
	pop	cx
	pop	es
	jc	.error
	.sector_unfinished:

	; Have we written all the requested data yet?
	or	cx,cx
	jnz	.loop

	.done:
	ret
	.error:
	or	byte [si + 10],FILE_ERROR
	jmp	.done

; si - file handle (preserved)
; sets carry on error
grow_file:
	; Allocate a new sector.
	push	si
	call	allocate_sector
	pop	si
	jc	.done

	; Store the new sector.
	mov	bx,[si + 8] ; previous sector
	mov	[si + 8],ax ; current sector

	; Link sector into file.
	mov	ax,bx
	shr	ax,8 ; sector table index
	push	si
	push	bx
	call	switch_sector_table
	pop	bx
	pop	si
	jc	.done
	and	bx,0xFF
	mov	ax,[si + 8]
	shl	bx,1
	mov	[bx + SECTOR_TABLE_BUFFER],ax
	mov	byte [sector_table_modified],1
	jc	.done
	mov	word [si + 6],0

	clc
	.done:
	ret

; al - new sector table index
; sets carry on error
switch_sector_table:
	cmp	al,[current_sector_table]
	je	.skip_switch

	; Save the previous sector table (if it was modified).
	push	ax
	call	save_sector_table
	pop	ax
	mov	[current_sector_table],al

	; Load the new sector table buffer.
	xor	ah,ah
	add	ax,2
	mov	di,ax
	mov	bx,ds
	mov	es,bx
	mov	bx,SECTOR_TABLE_BUFFER
	call	read_sector
	jc	.error

	.skip_switch:
	clc
	ret

	.error:
	mov	byte [current_sector_table],0xFF
	stc
	ret

; si - file handle (preserved)
; cx - bytes to read
; es:di - destination
; returns bytes read in cx, may set error flag on handle
read_file:
	mov	word [.bytes_read],0

	or	cx,cx
	jz	.done

	; Check error flag has not been set.
	mov	al,[si + 10]
	cmp	al,FILE_READ
	jne	.done

	; Get the file buffer to use.
	push	cx
	call	get_file_buffer_offset
	mov	dx,bx
	pop	cx

	.loop:

	; Work out how many bytes we can read this iteration.
	; We are limited by the buffer size (a sector),
	; the amount of data left in the file,
	; and the amount of requested bytes to read.
	mov	ax,cx
	cmp	word [si + 4],0 ; is high file remaining non-zero?
	jne	.e1
	cmp	word [si + 2],ax ; is low file remaining limiting?
	ja	.e1
	mov	ax,[si + 2]
	.e1:
	mov	bx,0x200
	sub	bx,[si + 6] ; offset into sector
	cmp	bx,ax ; is remaining data in buffer limiting?
	ja	.e2
	mov	ax,bx
	.e2:

	; Read data from the buffer.
	push	cx
	push	si
	mov	cx,ax
	mov	si,[si + 6]
	add	si,dx
	rep	movsb
	pop	si
	pop	cx

	; Update bytes read, position in buffer, remaining bytes in file and remaining bytes to read.
	add	[.bytes_read],ax
	add	[si + 6],ax
	sub	[si + 2],ax
	sbb	word [si + 4],0
	sub	cx,ax

	; If we are at the end of the file, then exit.
	cmp	word [si + 2],0
	jne	.not_at_end
	cmp	word [si + 4],0
	je	.done
	.not_at_end:

	; If we are at the end of the buffer, then read the next sector.
	cmp	word [si + 6],0x200
	jne	.sector_unfinished
	mov	ax,es
	push	ax
	push	cx
	push	dx
	push	si
	push	di
	mov	cx,1
	call	read_next_file_sector
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	es
	jc	.error
	mov	word [si + 6],0
	.sector_unfinished:

	; Have we read all the requested data yet?
	or	cx,cx
	jnz	.loop

	.done:
	mov	cx,[.bytes_read]
	ret
	.error:
	or	byte [si + 10],FILE_ERROR
	jmp	.done
	.bytes_read: dw 0

; si - file handle
; carry set on error
read_first_file_sector:
	call	get_file_buffer_offset
	mov	di,[si + 8]
	mov	ax,ds
	mov	es,ax
	jmp	read_sector

; si - file handle
; cx - **1** if you want to read the sector
; carry set on error
read_next_file_sector:
	push	si
	push	cx

	; Do we need to switch the sector table buffer?
	mov	ax,[si + 8] ; current sector
	shr	ax,8 ; 256 sector table entries per sector
	call	switch_sector_table
	jc	.error_table

	pop	cx
	pop	si

	; Get the next sector.
	mov	bx,[si + 8] ; current sector
	and	bx,0xFF
	shl	bx,1
	mov	di,[SECTOR_TABLE_BUFFER + bx]
	mov	[si + 8],di

	; If we're just seeking through the file, we don't need to read the sector.
	cmp	cx,1
	jne	.skip_load

	; Load the next sector.
	mov	bx,ds
	mov	es,bx
	call	get_file_buffer_offset
	jmp	read_sector

	.skip_load:
	clc
	ret

	.error_table:
	pop	si
	stc
	ret

; --------------- Global state.

recover:
	dw	0

first_free_string:
	dw	0
first_free_object:
	dw	0
obj_symbol_table:
	dw	0
obj_builtins:
	dw	0
gc_ready:
	db	0

next_character:
	dw	0
input_handle:
	dw	0
input_line:
	dw	0
input_offset:
	dw	0

print_callback:
	dw	terminal_print_string
print_data:
	dw	0

drive_number:
	db	0
read_attempts:
	db 	0
max_sectors:
	dw 	0
max_heads:
	dw 	0

current_sector_table:
	db	0xFF
sector_table_modified:
	db	0

caret_column:
	dw	1
caret_row:
	dw	0
output_color:
	dw	(SCREEN_COLOR >> 8)
graphics_mode:
	dw	0

user_input_start:
	dw	0
previously_unmatched_brace:
	dw	0

check_break:
	db	0
last_scancode:
	db	0

open_file_table:
	times (MAX_OPEN_FILES * DATA_PER_OPEN_FILE) db 0

; --------------- Constants.

loading_message:
	db 'initializing... ',0
hex_characters:
	db '0123456789ABCDEF'
prompt_message:
	db 10,'flip> ',0
unknown_type_message:
	db '<??>',0
nil_message:
	db 'nil',0
builtin_message:
	db '<builtin:',0
lambda_message:
	db '<lambda:',0
macro_message:
	db '<macro:',0
close_sign_message:
	db '>',0
string_quote_message:
	db '"',0
list_start_message:
	db '[',0
depth_limit_reached_message:
	db '...]',0
list_end_message:
	db ']',0
dot_message:
	db ' . ',0
space_message:
	db ' ',0
kilobytes_message:
	db 'K',0
bytes_message:
	db 'B',0
total_usage_message:
	db 'Disk space usage: ',0
out_of_message:
	db ' of ',0
memory_usage_message:
	db 'Memory usage: ',0

startup_command:
	db '[src "startup.lisp"]',0
startup_command_length:
	db 21
run_startup_command:
	db 0

builtin_strings:
	db 'nil',0
	db '+',0
	db '-',0
	db '*',0
	db '/',0
	db 'mod',0
	db '<',0
	db '<=',0
	db '>',0
	db '>=',0
	db 'is',0
	db 'atom',0
	db 'not',0
	db 'and',0
	db 'or',0
	db 'car',0
	db 'cdr',0
	db 'cons',0
	db 'setcar',0
	db 'setcdr',0
	db 'list',0
	db 'do',0
	db 'if',0
	db 'while',0
	db 'let',0
	db '=',0
	db 'q',0
	db 'fun',0
	db 'mac',0
	db 'print',0
	db 'print-col',0
	db 'print-substr',0
	db 'poke',0
	db 'peek',0
	db 'src',0
	db 'read',0
	db 'write',0
	db 'append',0
	db 'rename',0
	db 'annul',0
	db 'dir',0
	db 'ls',0
	db 'terminal',0
	db 'strlen',0
	db 'nth-char',0
	db 'capture',0
	db 'capture-upper',0
	db 'capture-lower',0
	db 'set-graphics',0
	db 'wait-key',0
	db 'muldiv',0
	db 'env-reset',0
	db 'env-list',0
	db 'env-export',0
	db 'env-import',0
	db 'inspect',0
	db 'pause',0
	db 'last-scancode',0
	db 'random',0
	db 'outb',0
	db 0
builtin_functions:
	dw 0 ; nil
	dw do_builtin_add     
	dw do_builtin_subtract
	dw do_builtin_multiply
	dw do_builtin_divide  
	dw do_builtin_modulo  
	dw do_builtin_lt      
	dw do_builtin_lte     
	dw do_builtin_gt      
	dw do_builtin_gte     
	dw do_builtin_is      
	dw do_builtin_atom    
	dw do_builtin_not     
	dw do_builtin_and     
	dw do_builtin_or      
	dw do_builtin_car     
	dw do_builtin_cdr     
	dw do_builtin_cons    
	dw do_builtin_setcar  
	dw do_builtin_setcdr  
	dw do_builtin_list    
	dw do_builtin_do 
	dw do_builtin_if 
	dw do_builtin_while 
	dw do_builtin_let     
	dw do_builtin_set     
	dw do_builtin_quote   
	dw do_builtin_lambda  
	dw do_builtin_macro   
	dw do_builtin_print 
	dw do_builtin_print_colored
	dw do_builtin_print_substr
	dw do_builtin_poke
	dw do_builtin_peek
	dw do_builtin_src
	dw do_builtin_read
	dw do_builtin_write
	dw do_builtin_append
	dw do_builtin_rename
	dw do_builtin_delete
	dw do_builtin_dir
	dw do_builtin_ls
	dw do_builtin_terminal
	dw do_builtin_strlen
	dw do_builtin_nth_char
	dw do_builtin_capture
	dw do_builtin_capture_upper
	dw do_builtin_capture_lower
	dw do_builtin_set_graphics
	dw do_builtin_wait_key
	dw do_builtin_muldiv
	dw do_builtin_env_reset
	dw do_builtin_env_list
	dw do_builtin_env_export
	dw do_builtin_env_import
	dw do_builtin_inspect
	dw do_builtin_pause
	dw do_builtin_last_scancode
	dw do_builtin_random
	dw do_builtin_outb
