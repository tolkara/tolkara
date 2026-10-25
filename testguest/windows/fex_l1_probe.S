.text
.p2align 13
.globl f
f:
 imull $17, %ecx, %eax
 addl $3, %eax
 retq
 .space 65536-(.-f), 0x90
.globl g
g:
 imull $23, %ecx, %eax
 addl $7, %eax
 retq
