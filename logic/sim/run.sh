#!/bin/sh
# Icarus Verilog bench for the CPLD logic. (C) 2026 Rony Ballouz, GPLv2 as the rest of VirtualTap.
# Usage: ./run.sh pal [DLY_ns] [NFRAMES] [CHECK_FROM] [JITNS]   |   ./run.sh ntsc
# pal: servo-master VT_pal2.v with tb_servo.v. DLY = servo sync rise -> VB burst start (default 1024000 ns, measured on hardware,
#      with INIT_FALL_LINE 240 the burst ends on line 52 at once; 6019900 starts ~78 lines late,
#      12424900 ~136 lines early; keep DLY below 14.8 ms, the VB model
#      triggers once per sync edge).
#      Checks rigid raster (2562-clock lines, 314-line frames), every displayed pixel from CHECK_FROM
#      on, no SRAM read during the burst, lock within 60 VB frames, servo sync timing.
#      Prints "RESULT ...: N pixels checked, E errors". Writes frame.pgm (last frame). ~4 min per 60 frames.
set -e
cd "$(dirname "$0")"
case "$1" in
	pal)  iverilog -g2012 -P tb.DLY=${2:-1024000} -P tb.NFRAMES=${3:-40} -P tb.CHECK_FROM=${4:-10} -P tb.JITNS=${5:-0} -P tb.DUMP=1 -o sim.vvp tb_servo.v ../VT_pal2.v ;;
	ntsc) iverilog -g2012 -DDUT=VT_NTSC2 -DDUTNAME='"NTSC"' -P tb.H0=500 -P tb.V0=24 -P tb.NCOL=382 -P tb.LINE=2542 -o sim.vvp tb.v ../VT_ntsc2.v ;;
	*) echo "usage: $0 pal [DLY_ns] [NFRAMES] [CHECK_FROM] [JITNS] | ntsc"; exit 1 ;;
esac
vvp sim.vvp | grep -v '^ERR pixel' | grep -v '^$'
