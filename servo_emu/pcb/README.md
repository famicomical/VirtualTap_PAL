# Servo emulator wiring

`wiring.png` is furrtek's original hookup: the ATtiny plugs into the Virtual Boy's 10-pin servo board connector (the one on the edge opposite the cartridge slot) in place of the mechanical mirror servo board. `servo_emu_GERBER.zip` is a small board that carries the ATtiny and the pins so no soldering to the Virtual Boy is needed (see `doc/manual_servo_emu_v1_en_anon.pdf`).

| ATtiny25/45/85 pin | Port | Virtual Boy servo connector | Signal |
|---|---|---|---|
| 1 | RESET | – | not connected |
| 2 | PB3 | pin 4 | frame duration clock |
| 3 | PB4 | pin 5 | frame duration data |
| 4 | GND | pin 1 | ground |
| 5 | PB0 | pin 8 | eye A sync feedback |
| 6 | PB1 | pin 9 | eye B sync feedback |
| 7 | PB2 | pin 6 | main 50 Hz sync |
| 8 | VCC | pin 3 | 5 V |

## PAL bitstream: one extra wire

The PAL bitstream in this fork does not follow the Virtual Boy; the Virtual Boy follows VirtualTap. VirtualTap generates the main 50 Hz servo sync itself and moves it until the VB's column transfer sits in the output's vertical blanking. For that the emulator must listen to VirtualTap instead of generating the main sync, and the servo emulator becomes **required**: the mechanical servo board cannot stay.

`wiring_pal.png` shows the change (red wire):

* **Firmware**: `firmware/servo_emu_vtsync.hex` (ATtiny25; `_attiny45` / `_attiny85` variants alongside) instead of `servo_emu.hex`. Same fuses (Ext 0xFF, High 0xDF, Low 0xE2). With this firmware PB2 is an input with pull-up; every rising edge restarts the 20 ms cycle.
* **Wire**: VirtualTap `J1` pin 8, the pad labelled `V_HS` (CPLD signal `SERVO_SYNC`, 3.3 V logic), to the ATtiny pin 7 net. On the plug-in board that is the pin 7 pad, or the Virtual Boy servo connector pin 6 net, whichever is easier to reach. Ground is already common through the Virtual Boy (VirtualTap `J1` pin 9 / 12 is ground if a return is wanted for a longer run).
* Everything else stays as in `wiring.png`.

VirtualTap drives the net directly at 3.3 V; the Virtual Boy and the ATtiny both accept that level (tested). If another unit does not, put a 5 V-powered non-inverting buffer (74HCT1G125 or similar) in the wire. Without VirtualTap connected the emulator free-runs at 24 ms so the Virtual Boy still boots, only slower than 50 Hz.

`J1` pin 8 is a raw CPLD output, not routed through the THS7373 video amplifier, so it is safe to load with a CMOS input but must not be shorted to the 5 V rail.
