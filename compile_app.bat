CALL riscv64-unknown-elf-gcc -c start.S -o start.o -march=rv32i -mabi=ilp32 -mno-relax
CALL riscv64-unknown-elf-gcc -c main.c -o main.o -march=rv32i -mabi=ilp32 -mno-relax -std=c99 -O1 -ffreestanding -fno-pic -fno-pie -Wall
CALL riscv64-unknown-elf-gcc start.o main.o -o prog.elf -nostdlib -nostartfiles -Wl,-T,link.ld -Wl,-Map,prog.map -march=rv32i -mabi=ilp32 -mno-relax
CALL riscv64-unknown-elf-objdump -d prog.elf > prog.dis
CALL riscv64-unknown-elf-objcopy -O binary prog.elf prog.bin
