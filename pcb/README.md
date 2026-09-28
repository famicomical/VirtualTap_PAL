# VirtualTap Rev. C board

Proteus project `vt_c.pdsprj`, schematic `vt_c_schematic.png`, Gerbers `vt_c_GERBER.zip`, bill of materials `vt_c_BOM.csv`. The board is furrtek's design and is unchanged in this fork; only the CPLD bitstream differs, and that changes what one pad of the output header does.

## `J1` output header

| Pin | Pad | Upstream (VGA / NTSC) | PAL bitstream (this fork) |
|---|---|---|---|
| 1 | `S_OUT` | composite sync, 75 Ω through the amp | same |
| 2 | `R_OUT` | red | same |
| 3 | `G_OUT` | green | same |
| 4 | `B_OUT` | blue | same |
| 5 | `1.65V` | reference | same |
| 6 | `5V` | 5 V | same |
| 7 | `V_VS` | raw composite sync (NTSC) / V sync (VGA), CPLD level | same, composite sync |
| 8 | `V_HS` | H sync (VGA), unused (NTSC) | **`SERVO_SYNC`**: main 50 Hz servo sync out, wire to the servo emulator (see `servo_emu/pcb/README.md`) |
| 9 | GND | ground | same |
| 10 | `MODE` | buffer mode select | unused |
| 11 | `PAL` | palette switch | same |
| 12 | GND | ground | same |

Pins 7 and 8 come straight from the CPLD (3.3 V logic, not through the THS7373 amplifier); pins 1..4 are the amplified 75 Ω video outputs. Nothing on the board needs to be changed or populated differently for the PAL bitstream.
