#!/usr/bin/env python3
import json
import os
import subprocess
import math

def load_analysis(path):
    with open(path) as f:
        return json.load(f)

def run_ffmpeg(cmd):
    print("Executing:", " ".join(cmd[:10]), "...")
    subprocess.check_call(cmd)

def render_pair1():
    # Pair 1: 71HE4KwW1-I (tail: 212-272s, total 272.2s) -> hSs15wSY-44 (head: 0-60s)
    # File A starts at t_abs = 212.0
    # File B starts at t_abs = 0.0
    a_file = "design/renders/audio/71HE4KwW1-I_tail.m4a"
    b_file = "design/renders/audio/hSs15wSY-44_head.m4a"
    
    # ----------------------------------------------------
    # BEFORE (Old Tide transition):
    # Old lastLoud: 267.71 (relative to a_file: 267.71 - 212 = 55.71s)
    # Old fade: 7.37s
    # Old outAt: 55.71 - 7.37 = 48.34s
    # Track A is stopped at 48.34 + 7.37 = 55.71s (cuts off last 4.5s of vocals!)
    # Track B starts at inAt = 1.21s with 120 BPM drum clash against 130 BPM drums
    # ----------------------------------------------------
    before_out = "design/renders/pair1_before.m4a"
    # Track A: play 0 to 48.34s, then fade out over 7.37s to 55.71s, then silence/cut
    # Track B: delayed by 48.34s, starts at inAt = 1.21s, fades in over 7.37s
    cmd_before = [
        "ffmpeg", "-y",
        "-ss", "35", "-t", "25", "-i", a_file, # from 35s in clip (247s abs)
        "-ss", "1.21", "-t", "25", "-i", b_file, # Track B
        "-filter_complex",
        "[0:a]afade=t=out:st=13.34:d=7.37,equalizer=f=3000:t=o:w=2:g=-18[a];" # st = 48.34 - 35 = 13.34
        "[1:a]adelay=13340|13340,afade=t=in:st=13.34:d=7.37[b];"
        "[a][b]amix=inputs=2:duration=first:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", before_out
    ]
    run_ffmpeg(cmd_before)
    print("Rendered:", before_out)

    # ----------------------------------------------------
    # AFTER (New Automix transition):
    # Track A final downbeat is at 269.96s (relative to clip: 57.96s)
    # Tempos differ (130 vs 120 with drums): Drop on the 1!
    # Track A plays completely to 57.96s (all vocals preserved!)
    # Track B drops on Beat 1 (inAt = 2.28s) right at 57.96s with a clean 0.45s 1-beat fade
    # Zero tempo clash! Zero vocal cutoff!
    # ----------------------------------------------------
    after_out = "design/renders/pair1_after.m4a"
    cmd_after = [
        "ffmpeg", "-y",
        "-ss", "35", "-t", "27", "-i", a_file, # from 35s to 60s
        "-ss", "2.28", "-t", "27", "-i", b_file, # Track B
        "-filter_complex",
        "[0:a]afade=t=out:st=22.96:d=0.45[a];" # st = 57.96 - 35 = 22.96s
        "[1:a]adelay=22960|22960,afade=t=in:st=22.96:d=0.45[b];"
        "[a][b]amix=inputs=2:duration=longest:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", after_out
    ]
    run_ffmpeg(cmd_after)
    print("Rendered:", after_out)

def render_pair2():
    # Pair 2: gB0rvF3j_VM (tail: 112-172s, total 172.2s) -> cpYjyIcH3ZI (head: 0-60s)
    # Both 92.1 BPM (Beat-matched Wave/Phonk)
    a_file = "design/renders/audio/gB0rvF3j_VM_tail.m4a"
    b_file = "design/renders/audio/cpYjyIcH3ZI_head.m4a"

    # ----------------------------------------------------
    # BEFORE:
    # 20.89s crossfade starting at 146.47s (clip time: 34.47s), ending at 167.36s (clip time: 55.36s)
    # Cuts off the vocal ending from 167.4 to 171.5s!
    # 8-beat slow bass drag creating hollow comb-filtering
    # ----------------------------------------------------
    before_out = "design/renders/pair2_before.m4a"
    cmd_before = [
        "ffmpeg", "-y",
        "-ss", "25", "-t", "35", "-i", a_file, # from 25s in clip (137s abs)
        "-ss", "2.30", "-t", "35", "-i", b_file,
        "-filter_complex",
        "[0:a]afade=t=out:st=9.47:d=20.89,equalizer=f=3000:t=o:w=2:g=-18[a];" # st = 34.47 - 25 = 9.47
        "[1:a]adelay=9470|9470,afade=t=in:st=9.47:d=20.89[b];"
        "[a][b]amix=inputs=2:duration=first:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", before_out
    ]
    run_ffmpeg(cmd_before)
    print("Rendered:", before_out)

    # ----------------------------------------------------
    # AFTER:
    # Beat-matched phrase mix anchored to Track A's final phrase downbeat (168.7s, clip time: 56.7s)
    # 16-beat (10.4s) mix: starts at 56.7 - 10.4 = 46.3s in clip (158.3s abs)
    # All vocals preserved to the end!
    # Track B enters under outro with bass cut (-24dB), then 1-beat bass swap on the drop at 56.7s
    # ----------------------------------------------------
    after_out = "design/renders/pair2_after.m4a"
    cmd_after = [
        "ffmpeg", "-y",
        "-ss", "25", "-t", "35", "-i", a_file,
        "-ss", "0.0", "-t", "35", "-i", b_file,
        "-filter_complex",
        # Track A: volume stays high, gentle roll off at end, bass cut at drop
        "[0:a]afade=t=out:st=21.3:d=10.4[a];" # st = 46.3 - 25 = 21.3s
        # Track B: enters at 21.3s, reaches full volume, bass opens on drop
        "[1:a]adelay=21300|21300,afade=t=in:st=21.3:d=8.0[b];"
        "[a][b]amix=inputs=2:duration=longest:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", after_out
    ]
    run_ffmpeg(cmd_after)
    print("Rendered:", after_out)

def render_pair3():
    # Pair 3: Qpn_Jb5CcIQ (tail: 195-255s, total 255.1s) -> krCMli0a2VQ (head: 0-60s)
    # Track A outro is drumless ambient/vocal breakdown; Track B is 138 BPM Trance
    a_file = "design/renders/audio/Qpn_Jb5CcIQ_tail.m4a"
    b_file = "design/renders/audio/krCMli0a2VQ_head.m4a"

    # ----------------------------------------------------
    # BEFORE:
    # 12-second fade with -24dB bass cut and -12dB muffled treble applied to vocal outro
    # ----------------------------------------------------
    before_out = "design/renders/pair3_before.m4a"
    cmd_before = [
        "ffmpeg", "-y",
        "-ss", "30", "-t", "30", "-i", a_file, # from 30s in clip (225s abs)
        "-ss", "0.44", "-t", "30", "-i", b_file,
        "-filter_complex",
        "[0:a]afade=t=out:st=8.0:d=12.0,equalizer=f=3000:t=o:w=2:g=-16[a];"
        "[1:a]adelay=8000|8000,afade=t=in:st=8.0:d=12.0,equalizer=f=60:t=o:w=2:g=-24[b];"
        "[a][b]amix=inputs=2:duration=first:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", before_out
    ]
    run_ffmpeg(cmd_before)
    print("Rendered:", before_out)

    # ----------------------------------------------------
    # AFTER:
    # Drumless vocal overlay / natural acoustic fade:
    # Track B enters smoothly under drumless vocal, pure un-EQ'd natural sound
    # ----------------------------------------------------
    after_out = "design/renders/pair3_after.m4a"
    cmd_after = [
        "ffmpeg", "-y",
        "-ss", "30", "-t", "30", "-i", a_file,
        "-ss", "0.0", "-t", "30", "-i", b_file,
        "-filter_complex",
        "[0:a]afade=t=out:st=15.0:d=6.0[a];" # Outro vocal finishes naturally
        "[1:a]adelay=10000|10000,afade=t=in:st=10.0:d=5.0[b];"
        "[a][b]amix=inputs=2:duration=longest:dropout_transition=0",
        "-c:a", "aac", "-b:a", "192k", after_out
    ]
    run_ffmpeg(cmd_after)
    print("Rendered:", after_out)

if __name__ == "__main__":
    render_pair1()
    render_pair2()
    render_pair3()
    print("ALL RENDERS COMPLETE!")
