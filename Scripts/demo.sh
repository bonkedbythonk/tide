#!/bin/zsh
# Opens a second Tide window filled with made-up songs, playlists and abstract
# covers, for screenshots. Your own library, queue and caches are not touched.
# Needs ImageMagick (brew install imagemagick) and Tide.app built once with ./run.sh.
set -e
cd "${0:A:h}/.."
dir=${TMPDIR:-/tmp}/tide-demo
mkdir -p $dir
pairs=(
  "#1d3557-#457b9d" "#2a9d8f-#264653" "#e76f51-#f4a261" "#6d597a-#b56576"
  "#355070-#eaac8b" "#0b132b-#5bc0be" "#3d405b-#81b29a" "#22223b-#9a8c98"
  "#003049-#669bbc" "#5f0f40-#fb8b24" "#14213d-#fca311" "#283618-#dda15e"
)
if [[ ! -f $dir/cover-23.jpg ]]; then
  for i in {0..23}; do
    magick -size 400x400 "plasma:${pairs[$(( i % 12 + 1 ))]}" -blur 0x12 -modulate 100,130 $dir/cover-$i.jpg
  done
  magick -size 2400x1500 "plasma:#0b2545-#13315c" -blur 0x60 -modulate 90,140 $dir/wallpaper.jpg
fi
# Its own copy of the app with a fresh binary, so a Tide you have open keeps playing.
swift build -c release
rm -rf $dir/Tide.app
cp -R Tide.app $dir/Tide.app
cp .build/release/MusicSample $dir/Tide.app/Contents/MacOS/
# Optional first argument: the screen to open on (playlist, nowplaying, settings).
open -n $dir/Tide.app --args --demo -demoScreen "${1:-home}" -demoCovers $dir \
  -wallpaperSource image -wallpaperImage $dir/wallpaper.jpg -wallpaperVisibility 0.6
