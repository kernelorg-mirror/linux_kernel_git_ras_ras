/* Copyright 2002 Andi Kleen */

#include <linux/linkage.h>
#include <asm/cpufeature.h>
#include <asm/alternative-asm.h>

/*
 * We build a jump to memcpy_orig by default which gets NOPped out on
 * the majority of x86 CPUs which set REP_GOOD. In addition, CPUs which
 * have the enhanced REP MOVSB/STOSB feature (ERMS), change those NOPs
 * to a jmp to memcpy_erms which does the REP; MOVSB mem copy.
 */

.weak memcpy

/*
 * memcpy - Copy a memory block.
 *
 * Input:
 *  rdi destination
 *  rsi source
 *  rdx count
 *
 * Output:
 * rax original destination
 */
ENTRY(__memcpy)
ENTRY(memcpy)
	ALTERNATIVE_2 "jmp memcpy_orig", "", X86_FEATURE_REP_GOOD, \
		      "jmp memcpy_erms", X86_FEATURE_ERMS

	movq %rdi, %rax
	movq %rdx, %rcx
	shrq $3, %rcx
	andl $7, %edx
	rep movsq
	movl %edx, %ecx
	rep movsb
	ret
ENDPROC(memcpy)
ENDPROC(__memcpy)

/*
 * memcpy_erms() - enhanced fast string memcpy. This is faster and
 * simpler than memcpy. Use memcpy_erms when possible.
 */
ENTRY(memcpy_erms)
	movq %rdi, %rax
	movq %rdx, %rcx
	rep movsb
	ret
ENDPROC(memcpy_erms)

ENTRY(memcpy_orig)
	movq %rdi, %rax

	cmpq $0x20, %rdx
	jb .Lhandle_tail

	/*
	 * We check whether memory false dependence could occur,
	 * then jump to corresponding copy mode.
	 */
	cmp  %dil, %sil
	jl .Lcopy_backward
	subq $0x20, %rdx
.Lcopy_forward_loop:
	subq $0x20,	%rdx

	/*
	 * Move in blocks of 4x8 bytes:
	 */
	movq 0*8(%rsi),	%r8
	movq 1*8(%rsi),	%r9
	movq 2*8(%rsi),	%r10
	movq 3*8(%rsi),	%r11
	leaq 4*8(%rsi),	%rsi

	movq %r8,	0*8(%rdi)
	movq %r9,	1*8(%rdi)
	movq %r10,	2*8(%rdi)
	movq %r11,	3*8(%rdi)
	leaq 4*8(%rdi),	%rdi
	jae  .Lcopy_forward_loop
	addl $0x20,	%edx
	jmp  .Lhandle_tail

.Lcopy_backward:
	/*
	 * Calculate copy position to tail.
	 */
	addq %rdx,	%rsi
	addq %rdx,	%rdi
	subq $0x20,	%rdx
	/*
	 * At most 3 ALU operations in one cycle,
	 * so append NOPS in the same 16 bytes trunk.
	 */
	.p2align 4
.Lcopy_backward_loop:
	subq $0x20,	%rdx
	movq -1*8(%rsi),	%r8
	movq -2*8(%rsi),	%r9
	movq -3*8(%rsi),	%r10
	movq -4*8(%rsi),	%r11
	leaq -4*8(%rsi),	%rsi
	movq %r8,		-1*8(%rdi)
	movq %r9,		-2*8(%rdi)
	movq %r10,		-3*8(%rdi)
	movq %r11,		-4*8(%rdi)
	leaq -4*8(%rdi),	%rdi
	jae  .Lcopy_backward_loop

	/*
	 * Calculate copy position to head.
	 */
	addl $0x20,	%edx
	subq %rdx,	%rsi
	subq %rdx,	%rdi
.Lhandle_tail:
	cmpl $16,	%edx
	jb   .Lless_16bytes

	/*
	 * Move data from 16 bytes to 31 bytes.
	 */
	movq 0*8(%rsi), %r8
	movq 1*8(%rsi),	%r9
	movq -2*8(%rsi, %rdx),	%r10
	movq -1*8(%rsi, %rdx),	%r11
	movq %r8,	0*8(%rdi)
	movq %r9,	1*8(%rdi)
	movq %r10,	-2*8(%rdi, %rdx)
	movq %r11,	-1*8(%rdi, %rdx)
	retq
	.p2align 4
.Lless_16bytes:
	cmpl $8,	%edx
	jb   .Lless_8bytes
	/*
	 * Move data from 8 bytes to 15 bytes.
	 */
	movq 0*8(%rsi),	%r8
	movq -1*8(%rsi, %rdx),	%r9
	movq %r8,	0*8(%rdi)
	movq %r9,	-1*8(%rdi, %rdx)
	retq
	.p2align 4
.Lless_8bytes:
	cmpl $4,	%edx
	jb   .Lless_3bytes

	/*
	 * Move data from 4 bytes to 7 bytes.
	 */
	movl (%rsi), %ecx
	movl -4(%rsi, %rdx), %r8d
	movl %ecx, (%rdi)
	movl %r8d, -4(%rdi, %rdx)
	retq
	.p2align 4
.Lless_3bytes:
	subl $1, %edx
	jb .Lend
	/*
	 * Move data from 1 bytes to 3 bytes.
	 */
	movzbl (%rsi), %ecx
	jz .Lstore_1byte
	movzbq 1(%rsi), %r8
	movzbq (%rsi, %rdx), %r9
	movb %r8b, 1(%rdi)
	movb %r9b, (%rdi, %rdx)
.Lstore_1byte:
	movb %cl, (%rdi)

.Lend:
	retq
ENDPROC(memcpy_orig)

#ifndef CONFIG_UML
/*
 * __mcsafe_copy - memory copy with machine check exception handling
 * Note that we only catch machine checks when reading the source addresses.
 * Writes to target are posted and don't generate machine checks.
 */
ENTRY(__mcsafe_copy)
	cmpl $8,%edx
	jb 20f		/* less then 8 bytes, go to byte copy loop */

	/* check for bad alignment of source */
	testl $7,%esi
	/* already aligned */
	jz 102f

	/* copy one byte at a time until source is 8-byte aligned */
	movl %esi,%ecx
	andl $7,%ecx
	subl $8,%ecx
	negl %ecx
	subl %ecx,%edx
0:	movb (%rsi),%al
	movb %al,(%rdi)
	incq %rsi
	incq %rdi
	decl %ecx
	jnz 0b

102:
	/* Figure out how many whole cache lines (64-bytes) to copy */
	movl %edx,%ecx
	andl $63,%edx
	shrl $6,%ecx
	jz 17f

	/* Loop copying whole cache lines */
1:	movq (%rsi),%r8
2:	movq 1*8(%rsi),%r9
3:	movq 2*8(%rsi),%r10
4:	movq 3*8(%rsi),%r11
	movq %r8,(%rdi)
	movq %r9,1*8(%rdi)
	movq %r10,2*8(%rdi)
	movq %r11,3*8(%rdi)
9:	movq 4*8(%rsi),%r8
10:	movq 5*8(%rsi),%r9
11:	movq 6*8(%rsi),%r10
12:	movq 7*8(%rsi),%r11
	movq %r8,4*8(%rdi)
	movq %r9,5*8(%rdi)
	movq %r10,6*8(%rdi)
	movq %r11,7*8(%rdi)
	leaq 64(%rsi),%rsi
	leaq 64(%rdi),%rdi
	decl %ecx
	jnz 1b

	/* Are there any trailing 8-byte words? */
17:	movl %edx,%ecx
	andl $7,%edx
	shrl $3,%ecx
	jz 20f

	/* Copy trailing words */
18:	movq (%rsi),%r8
	mov %r8,(%rdi)
	leaq 8(%rsi),%rsi
	leaq 8(%rdi),%rdi
	decl %ecx
	jnz 18b

	/* Any trailing bytes? */
20:	andl %edx,%edx
	jz 23f

	/* copy trailing bytes */
	movl %edx,%ecx
21:	movb (%rsi),%al
	movb %al,(%rdi)
	incq %rsi
	incq %rdi
	decl %ecx
	jnz 21b

	/* Copy successful. Return .remain = 0, .trapnr = 0 */
23:	xorq %rax, %rax
	xorq %rdx, %rdx
	ret

	.section .fixup,"ax"
	/*
	 * machine check handler loaded %rax with trap number
	 * We just need to make sure %edx has the number of
	 * bytes remaining
	 */
30:
	add %ecx,%edx
	ret
31:
	shl $6,%ecx
	add %ecx,%edx
	ret
32:
	shl $6,%ecx
	lea -8(%ecx,%edx),%edx
	ret
33:
	shl $6,%ecx
	lea -16(%ecx,%edx),%edx
	ret
34:
	shl $6,%ecx
	lea -24(%ecx,%edx),%edx
	ret
35:
	shl $6,%ecx
	lea -32(%ecx,%edx),%edx
	ret
36:
	shl $6,%ecx
	lea -40(%ecx,%edx),%edx
	ret
37:
	shl $6,%ecx
	lea -48(%ecx,%edx),%edx
	ret
38:
	shl $6,%ecx
	lea -56(%ecx,%edx),%edx
	ret
39:
	lea (%rdx,%rcx,8),%rdx
	ret
40:
	mov %ecx,%edx
	ret
	.previous

	_ASM_EXTABLE_FAULT(0b,30b)
	_ASM_EXTABLE_FAULT(1b,31b)
	_ASM_EXTABLE_FAULT(2b,32b)
	_ASM_EXTABLE_FAULT(3b,33b)
	_ASM_EXTABLE_FAULT(4b,34b)
	_ASM_EXTABLE_FAULT(9b,35b)
	_ASM_EXTABLE_FAULT(10b,36b)
	_ASM_EXTABLE_FAULT(11b,37b)
	_ASM_EXTABLE_FAULT(12b,38b)
	_ASM_EXTABLE_FAULT(18b,39b)
	_ASM_EXTABLE_FAULT(21b,40b)
#endif
