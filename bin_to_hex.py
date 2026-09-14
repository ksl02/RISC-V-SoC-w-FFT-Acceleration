import sys

NOP = 0x00000013

if len(sys.argv) < 3:
    sys.exit(1)

data = open(sys.argv[1], "rb").read()
if len(data) % 4:
    data += b"\x00" * (4 - (len(data) % 4))

base_word = 0
if len(sys.argv) >= 4:
    base_byte = int(sys.argv[3], 0)
    base_word = base_byte // 4

with open(sys.argv[2], "w") as f:
    #Pad with NOPs up to the base address
    for _ in range(base_word):
        f.write(f"{NOP:08x}\n")
    #Write actual code
    for i in range(0, len(data), 4):
        w = int.from_bytes(data[i:i+4], "little")
        f.write(f"{w:08x}\n")