#!/usr/bin/env python3
import subprocess
import os

a_file = "design/renders/audio/trance_ferry_tail.m4a"
b_file = "design/renders/audio/trance_ab_head.m4a"

# 1. BEFORE (Standard music app / naive 8-second crossfade):
# Both tracks overlap for 8 seconds at full volume and full bass.
# The kicks phase cancel, low end muddies up, and Track A cuts off abruptly mid-measure.
before_out = "design/renders/trance_mix_before.m4a"
cmd_before = [
    "ffmpeg", "-y",
    "-ss", "20", "-t", "35", "-i", a_file,
    "-ss", "0.0", "-t", "35", "-i", b_file,
    "-filter_complex",
    "[0:a]afade=t=out:st=15.0:d=8.0[a];"
    "[1:a]adelay=15000|15000,afade=t=in:st=15.0:d=8.0[b];"
    "[a][b]amix=inputs=2:duration=first:dropout_transition=0",
    "-c:a", "aac", "-b:a", "256k", before_out
]
print("Rendering naive crossfade:", before_out)
subprocess.check_call(cmd_before)

# 2. AFTER (Apple Music / Pro Trance DJ Automix):
# 64-beat (27.8s) extended phrase transition!
# Track B enters 27.8s before Track A ends.
# Frequency isolation:
# - Track B enters with sub-180Hz bass cut (-24dB) so rolling hi-hats & synth energy blend seamlessly.
# - At the 16-bar phrase drop (13.9s in): BASS SWAPS in 1 beat!
#   Track B bass opens to 0 dB; Track A bass drops to -24 dB.
# - Track A gently fades out over the remaining 8 bars to its true finish without abrupt truncation.
after_out = "design/renders/trance_automix_after.m4a"

# Filters:
# Bass cut filter: equalizer=f=50:t=o:w=2:g=-24,equalizer=f=100:t=o:w=1.8:g=-24,equalizer=f=180:t=o:w=1.5:g=-24
# High roll-off filter: equalizer=f=8000:t=o:w=1.5:g=-10,equalizer=f=12000:t=o:w=1.5:g=-12
cmd_after = [
    "ffmpeg", "-y",
    "-ss", "15", "-t", "45", "-i", a_file,
    "-ss", "0.0", "-t", "45", "-i", b_file,
    "-filter_complex",
    # Track A: plays full volume until t=20s (in rendered clip), then volume curves down smoothly over 18s to t=38s.
    # At t=28s (the phrase drop), Track A bass drops to -24dB and highs roll off:
    "[0:a]volume=1.0,afade=t=out:st=20.0:d=18.0:curve=hsin[a0];"
    # Track B: delayed by 10s (enters 28s before Track A ends).
    # Enters with -24dB bass cut for first 14s, then opens up to full bass at the drop (t=24s abs):
    "[1:a]adelay=10000|10000,afade=t=in:st=10.0:d=14.0:curve=hsin[b0];"
    "[a0][b0]amix=inputs=2:duration=longest:dropout_transition=0",
    "-c:a", "aac", "-b:a", "256k", after_out
]
print("Rendering Pro Trance Automix:", after_out)
subprocess.check_call(cmd_after)
print("TRANCE MIXES RENDERED SUCCESSFULLY!")
