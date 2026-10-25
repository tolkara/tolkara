.text
.globl long_block
long_block:
 movl %ecx, %eax
 .rept 12000
 imull $17, %eax, %eax
 addl $3, %eax
 .endr
 retq
