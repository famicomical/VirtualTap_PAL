#!/bin/sh
# (C) 2026 Rony Ballouz, GPLv2 as the rest of VirtualTap.
# Flash servo_emu_attiny45.hex and its fuses into an ATtiny45 with a TL866II+/T48 using the
# open-source minipro tool on macOS/Linux (brew install minipro). Chip in the ZIF socket, out of the
# emulator board. Fuses as in servo_emu.c: Ext 0xFF, High 0xDF, Low 0xE2 (CKDIV8 off, CKOUT off).
# The fuse file is derived from the chip's own config read-back so every field minipro expects for
# this programmer (T48 also lists user_id0..7) is present; only lfuse/hfuse/efuse/lock are changed.
# Usage: ./flash_attiny45.sh [device-name]   (default ATTINY45@DIP8, see `minipro -l | grep -i attiny45`)
set -e
cd "$(dirname "$0")"
DEV=${1:-ATTINY45@DIP8}
HEX=servo_emu_attiny45.hex
[ -f "$HEX" ] || { echo "missing $HEX (build it with avr-gcc -mmcu=attiny45, see servo_emu.c)"; exit 1; }

CUR=$(mktemp); FUSES=$(mktemp)
trap 'rm -f "$CUR" "$FUSES"' EXIT

echo "== current fuses"
minipro -p "$DEV" -c config -r "$CUR"
cat "$CUR"
sed -e 's/^lfuse *=.*/lfuse = 0xe2/' -e 's/^hfuse *=.*/hfuse = 0xdf/' -e 's/^efuse *=.*/efuse = 0xff/' -e 's/^lock *=.*/lock = 0xff/' "$CUR" > "$FUSES"
grep -q '^lfuse' "$FUSES" || { echo "config read-back has no lfuse line, not writing fuses"; exit 1; }

echo "== writing flash"
minipro -p "$DEV" -w "$HEX" -f ihex
echo "== writing fuses"
minipro -p "$DEV" -c config -w "$FUSES"
echo "== verify fuses"
minipro -p "$DEV" -c config -r "$CUR"
cat "$CUR"
grep -q '^lfuse *= *0xe2' "$CUR" && grep -q '^hfuse *= *0xdf' "$CUR" || { echo "FUSES NOT AS EXPECTED, do not use the chip yet"; exit 1; }
echo "done: original emulator firmware restored, PB2 drives main sync again. DO NOT connect the V_HS sync wire with this firmware."
