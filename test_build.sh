#!/bin/bash

_7zip() {
	local f l
	local flags=(
		IS_MINGW=1
		CC=${TRIPLE}-cc
		CXX=${TRIPLE}-c++
		RC=${TRIPLE}-windres
	)
	case "${TRIPLE}" in arm*|aarch64*) return;; esac

	if [ ! -d 7zip ]; then
		git clone --depth=1 https://github.com/ip7z/7zip
	fi
	cd 7zip

	for l in -lOle32 -lGdi32 -lComctl32 -lComdlg32 -lShell32 \
		-lUser32; do
		sed -i "s/$l/$(echo $l|tr 'A-Z' 'a-z')/g" CPP/7zip/7zip_gcc.mak C/7zip_gcc_c.mak
	done
	sed -i 's/NTSecAPI.h/ntsecapi.h/' CPP/Windows/SecurityUtils.h
	rm -f CPP/7zip/Bundles/SFXCon/makefile.gcc

	set -x
	while read -r f; do
		make ${flags[*]} -C $(dirname $f) -f makefile.gcc
	done < <(find -type f -name makefile.gcc)
	set +x
	find -iname \*.exe -o -iname \*.dll | xargs install -Dvt ${PKG}/usr/bin -m755
	cd ..
}

_ffmpeg() {
	local url=https://github.com/FFmpeg/FFmpeg
	local branch=$(git ls-remote $url|grep 'refs/heads/release/'|awk '{print$2}' |sort -uV |sed 's/^refs\/heads\///'|tail -1)

	if [ ! -d ffmpeg ]; then
		git clone --depth 1 ${url} -b ${branch} ffmpeg
	fi

	local _arch=${ARCH}
	case "${_arch}" in
		i686|x86_64)
			_yasm
			[[ $_arch != i686 ]] || _arch=x86
			;;
	esac

	cd ffmpeg
	./configure --prefix=${PREFIX} \
		--cross-prefix=${TRIPLE}- \
		--target-os=mingw32 --arch=$_arch \
		--enable-{gpl,version3,nonfree}
	make
	make DESTDIR=${PKG} install
	cd ..
}

_llvm() {
	local args=()
	local flags host tbuild

	if [ ! -d bld_llvm ]; then
		prepare_llvm clang lld
	fi

	cd bld_llvm
	_llvm_conf
	cmake "${args[@]}"
	cmake --build build
	DESTDIR=${PKG} cmake --install build --strip
	echo "llvm_ver=${LLVM_VER}" >> /ENV
	cd ..
	_llvm_post ${LLVM_VER}
}

_llvm_conf() {
	local arch=${ARCH}
	flags="${common_flags[@]}"
	host=${ARCH}-pc-windows-msvc
	tbuild=host

	case "${ARCH}" in
		aarch64)
			tbuild="${tbuild};ARM"
			;;
		armv7)
			arch=arm
			host="armv7a-${host#*-}"
			;;
		i686)
			arch=i386
			flags+=" -DCAN_TARGET_i386=ON"
			flags+=" -DCAN_TARGET_x86_64=OFF"
			;;
	esac

	args=(
		${flags/runtimes/llvm}
		${sanitizers_flags[@]}
		-DLLVM_BUILD_TESTS=OFF
		-DLLVM_HOST_TRIPLE=${host}
		-DLLVM_TARGETS_TO_BUILD=${tbuild}
		-DLLVM_ENABLE_PROJECTS="clang;compiler-rt;lld"
		-DLLVM_LINK_LLVM_DYLIB=ON
		-DCLANG_DEFAULT_CXX_STDLIB=libc++
		-DCLANG_DEFAULT_LINKER=lld
		-DCLANG_DEFAULT_RTLIB=compiler-rt
		-DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
		-DCLANG_DEFAULT_UNWINDLIB=libunwind
		-DCLANG_CONFIG_FILE_SYSTEM_DIR="D:/Tools/clang"
		-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
		-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
		-DLIBCXX_HARDENING_MODE=extensive
		-DLIBCXXABI_ENABLE_SHARED=OFF
		-DLIB{CXX{,ABI},UNWIND}_USE_COMPILER_RT=ON
		-DLIB{CXX{,ABI},UNWIND}_INSTALL_LIBRARY_DIR:PATH=lib
	)

	# 使用 LLVM_ENABLE_RUNTIMES
	# 会在最后才对runtimes运行cmake
	# 并报错:  No known features for CXX compiler \n "Clang"\n version 18.1.3.
	for i in lib{cxx,cxxabi,unwind}; do
		ln -sr $i llvm/projects/
		sed -i 's@\.\./cmake@../&@;s@\.\./runtimes@../&@' $i/CMakeLists.txt
	done
	ln -sr runtimes/cmake/Modules/* cmake/Modules/
	sed -i '/LIBCXXABI_USE_LLVM_UNWINDER AND NOT/s/ NOT//' libcxxabi/CMakeLists.txt

	local cl_dir=/usr/lib/clang/${LLVM_VER%%.*}/lib/windows
	if [[ -f ${cl_dir}/libclang_rt.builtins-${arch}.a ]]; then
		# git 版本没有这个可能会报错
		ln -sf libclang_rt.builtins-${arch}.a "${cl_dir}/clang_rt.builtins-${arch}.lib"
	fi

	ln -sf clang /usr/bin/cc
	ln -sf clang++ /usr/bin/c++
}

_llvm_nightly() {
	local args=()
	local flags host tbuild

	if [ ! -d llvm-project ]; then
		git clone --depth 1 https://github.com/llvm/llvm-project
	fi

	cd llvm-project
	_llvm_conf
	cmake "${args[@]}"
	cmake --build build
	DESTDIR=${PKG} ninja install/strip -C build
	LV=$(grep '^CMAKE_PROJECT_VERSION:' build/CMakeCache.txt|cut -d= -f2)
	echo "llvm_ver=${LV}" >> /ENV
	cd ..
	_llvm_post ${LV}
}

_llvm_post() {
	local cl_dir=${PKG}${PREFIX}/lib/clang/${1%%.*}/lib/windows
	local fn orig
	[ -d ${cl_dir} ] || return
	while read -r fn; do
		orig=$(basename ${fn})
		orig=${orig#lib}
		[ ! -f "${cl_dir}/${orig%.a}.lib" ] || continue
		mv ${fn} "${cl_dir}/${orig%.a}.lib"
	done < <(find ${cl_dir} -type f -name lib\*.a)
}

_openssl() {
	local flags
	if [ ! -d openssl ]; then
		git clone --depth 1 https://github.com/openssl/openssl
	fi
	cd openssl

	case "${ARCH}" in
		armv7|aarch64)
			patch -p1 -i ../openssl-mingw-armconf.patch
			flags=mingwarm${ARCH:5}
			;;
		i686)
			flags=mingw
			;;
		x86_64)
			flags=mingw64
			;;
	esac

	./Configure --prefix=${PREFIX} \
    --cross-compile-prefix=${TRIPLE}- \
    --libdir=lib no-docs ${flags}
	make
	make DESTDIR=${PKG} install
	cd ..
}

_yasm() {
	local src=yasm-1.3.0.tar.gz
	wget -nv https://www.tortall.net/projects/yasm/releases/$src
	tar xf $src
	cd ${src%.tar*}
	sed -i 's#) ytasm.*#)#' Makefile.in
	CC=clang CXX=clang++ \
	./configure --prefix=/usr
	make
	make install
	cd ..
}

t_build() {
	local target
	for target; do
		case "${target}" in
			7z)
				_7zip
				;;
			ffmpeg)
				_ffmpeg
				;;
			llvm|cxx)
				_llvm
				;;
			llvm-nightly)
				_llvm_nightly
				;;
			openssl)
				_openssl
				;;
			c|C)
				_7zip
				_ffmpeg
				_openssl
				;;
		esac
	done
	if [[ -n $(ls -A $PKG 2>/dev/null) ]]; then
		echo "PKG=rootfs/$PKG" >> /ENV
		if [[ $1 = llvm || $1 = llvm-nightly ]]; then
			echo "pkgver=-$(grep '^llvm_ver' /ENV|cut -d= -f2)" >> /ENV
		fi
		if [[ -n $(find -type f -name CMakeCache.txt) ]]; then
			local cdir cfile
			while read -r cfile; do
				cdir="$(dirname ${cfile})"
				install -vm644 "${cfile}" "${PKG}${PREFIX}/CMakeCache-$(basename ${cdir%/*}).txt"
			done < <(find -type f -name CMakeCache.txt)
		fi
	fi
}
