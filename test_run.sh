#!/bin/bash

set -e

wget -q "https://api.github.com/repos/$GITHUB_REPOSITORY/releases"
wget -nv $(grep browser_download_url releases | grep '/artifacts/' | cut -d: -f2-9 | sed 's/"\|\s//g')

if [[ -n $(find -maxdepth 1 -name \*.zip) ]]; then
	find -maxdepth 1 -name \*.zip | xargs unzip -q
fi

if [[ -n $(find -name \*-i686.tar.xz -o -iname \*-x86_64.tar.xz) ]]; then
	find -name \*-i686.tar.xz -o -iname \*-x86_64.tar.xz | xargs unxz
fi

for f in $(find -maxdepth 1 -name \*.tar); do
	if [[ $f == *-nightly-* ]]; then
		args="-ousr/nightly"
	fi
	7z x -y -snl -snh $f ${args}
done

while read -r EXE; do
	case "$(basename ${EXE})" in
		clang.exe|llc.exe)
			"${EXE}" --version
			;;
		ffmpeg.exe)
			"${EXE}" -hwaccels
			;;
		openssl.exe)
			"${EXE}" version
			"${EXE}"
			;;
		7z.exe|7z?.exe)
			"${EXE}" i
			;;
	esac
done < <(find usr -name \*.exe)
