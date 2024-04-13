#!/bin/bash

set -e
source envars.sh

case "$1" in
	aarch64|armv7|i686|x86_64)
		TRIPLE="$1-w64-mingw32"
		ARCH=$1; shift
		;;
	*)
		ARCH=x86_64; TRIPLE="$ARCH-w64-mingw32"
		;;
esac

LLVM_VER=%VERSION%
MINGW_VER=93059a6ae05d8e0b42bec5039818003a9f6329b1  # Apr 9
PKG="$PWD/DEST"
PREFIX="/usr/${TRIPLE}"
MINGW_URL="https://github.com/mingw-w64/mingw-w64"
URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VER}"

SRC=(
	cmake
	compiler-rt
	libcxx
	libcxxabi
	libunwind
	llvm
	runtimes
	third-party
)

common_flags=(
	-DCMAKE_INSTALL_PREFIX=${PREFIX}
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_C_COMPILER=${TRIPLE}-clang
	-DCMAKE_CXX_COMPILER=${TRIPLE}-clang++
	-DCMAKE_SYSTEM_NAME=Windows
	-DCMAKE_FIND_ROOT_PATH=${PREFIX}
	-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
	-DCMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,PACKAGE}=ONLY
	-DLLVM_INCLUDE_TESTS=OFF
	-Wno-dev -GNinja -S runtimes -B build
)

if [[ $1 = bootstrap || $1 = test ]]; then
	sanitizers_flags=(
		-DCOMPILER_RT_BUILD_{SANITIZERS,LIBFUZZER}=OFF
		-DCOMPILER_RT_BUILD_{MEMPROF,ORC,PROFILE,XRAY}=OFF
	)
fi

create_symlink(){
	local binary
	local prefix=$1
	local BINUTILS_SYMLINKS=(
		addr2line
		ar
		c++filt
		dlltool
		ranlib
		nm
		objcopy
		objdump
		readelf
		size
		strings
		strip
		windres
	)

	install -d ${prefix}/usr/bin
	ln -sf clang "${prefix}/usr/bin/${TRIPLE}-clang"
	ln -sf clang++ "${prefix}/usr/bin/${TRIPLE}-clang++"
	ln -sf mingw-lld "${prefix}/usr/bin/${TRIPLE}-ld.lld"
	ln -sf ${TRIPLE}-ld.lld "${prefix}/usr/bin/${TRIPLE}-ld"
	ln -sf ${TRIPLE}-clang "${prefix}/usr/bin/${TRIPLE}-cc"
	ln -sf ${TRIPLE}-clang "${prefix}/usr/bin/${TRIPLE}-as"
	ln -sf ${TRIPLE}-clang "${prefix}/usr/bin/${TRIPLE}-gcc"
	ln -sf ${TRIPLE}-clang++ "${prefix}/usr/bin/${TRIPLE}-c++"

	local default_conf=$(clang -v 2>&1|sed -n 's/Configuration file:\s\+\(.*\)/\1/p')
	local target_triple=$(${TRIPLE}-clang -print-target-triple)
	local conf_dir=$(dirname ${default_conf})
	sed '/-fstack-protector/d' ${default_conf} > ${target_triple}-clang.cfg
	sed -i "\$a--sysroot=${PREFIX}" ${target_triple}-clang.cfg
	install -d ${prefix}${conf_dir}
	mv -f ${target_triple}-clang.cfg "${prefix}${conf_dir}"
	ln -sf ${target_triple}-clang.cfg "${prefix}${conf_dir}/${target_triple}-clang++.cfg"

	for binary in ${BINUTILS_SYMLINKS[*]}; do
		if [[ ! -x ${prefix}/usr/bin/${TRIPLE}-${binary} ]]; then
			ln -s llvm-${binary/++/xx} "${prefix}/usr/bin/${TRIPLE}-${binary}"
		fi
	done

	if [[ -n ${prefix} ]]; then
		if [[ -n $(find ${prefix}${PREFIX}/bin -name \*.dll) ]]; then
			llvm-strip -s ${prefix}${PREFIX}/bin/*.dll
		fi
		rm -f  ${prefix}${PREFIX}/lib/*.la
		chmod -x  ${prefix}${PREFIX}/lib/*.a
	fi
}

prepare_llvm() {
	for f in ${SRC[@]} $*; do
		[[ -f $f-${LLVM_VER}.src.tar.xz ]] || wget -qc ${URL}/$f-${LLVM_VER}.src.tar.xz
		if [ ! -d bld_llvm/$f-${LLVM_VER}.src ]; then
			install -d bld_llvm
			tar xf $f-${LLVM_VER}.src.tar.xz -C bld_llvm
			ln -srv bld_llvm/$f{-$LLVM_VER.src,}
		fi
	done
}

prepare_src() {
	local major=${LLVM_VER%%.*}
	local old=$((major-1))
	local old_old=$((old-1))

	if [[ ! -d /usr/lib/clang/${major}/lib/windows ]]; then
		if [[ -d /usr/lib/clang/${old}/lib/windows ]]
		then
			ln -srv /usr/lib/clang/{${old},${major}}/lib/windows
		elif [[ -d /usr/lib/clang/${old_old}/lib/windows ]]
		then
			ln -srv /usr/lib/clang/{${old_old},${major}}/lib/windows
		fi
	fi

	if [ ! -d mingw-w64 ]; then
		git clone --no-checkout ${MINGW_URL}
		cd mingw-w64
		git checkout ${MINGW_VER}
		cd ..
	fi

	create_symlink
	prepare_llvm
}

build_llvmrt() {
	cd bld_llvm

	if [[ $1 == bootstrap ]]; then
		common_flags+=(-DCMAKE_C{,XX}_COMPILER_WORKS=1)
	fi

	rm -rf build
	local C_TARGET=$($TRIPLE-gcc -v 2>&1|grep Target|sed 's/.*:\|\s//g')
	local RT_DIR=usr/lib/clang/${LLVM_VER%%.*}
	cmake "${common_flags[@]}" \
	-DLLVM_ENABLE_RUNTIMES=compiler-rt \
	-DCMAKE_C_COMPILER_TARGET=${C_TARGET} \
	-DCOMPILER_RT_INSTALL_PATH=/${RT_DIR} \
	-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
	-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
	-DSANITIZER_CXX_ABI=libc++ "${sanitizers_flags[@]}"
	DESTDIR=${PKG} ninja install -C build
	rm -rf ${PKG}/${RT_DIR}/{include,share}/
	if [[ -n $(find ${PKG}/${RT_DIR}/lib/windows -name \*.dll) ]]; then
		install -d ${PKG}${PREFIX}/bin
		mv "${PKG}/${RT_DIR}/lib/windows/"*.dll "${PKG}${PREFIX}/bin"
	fi
	rm -rf /${RT_DIR}/lib/windows
	cp -a ${PKG}/${RT_DIR}/lib/windows "/${RT_DIR}/lib"

	rm -rf build
	cmake "${common_flags[@]}" \
	-DLLVM_ENABLE_RUNTIMES="libunwind;libcxx;libcxxabi" \
	-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
	-DLIBCXX_HARDENING_MODE=extensive \
	-DLIBCXXABI_ENABLE_SHARED=OFF \
	-DLIBCXX_HAS_ATOMIC_LIB=OFF \
	-DLIB{UNWIND,CXX{,ABI}}_USE_COMPILER_RT=ON
	ninja install -C build
	DESTDIR=${PKG} ninja install -C build > /dev/null 2>&1
	cd ..
}

build_mingw() {
	cd mingw-w64/mingw-w64-headers
	# https://learn.microsoft.com/zh-cn/cpp/porting/modifying-winver-and-win32-winnt?view=msvc-170
	rm -rf build && mkdir build && cd build
	../configure --prefix=${PREFIX} \
		--with-default-win32-winnt=0x0601 \
		--with-default-msvcrt=ucrt
	make install
	make install DESTDIR=${PKG} >/dev/null

	cd ../../mingw-w64-crt
	local FLAGS="--disable-lib32 --disable-lib64"
	case "${TRIPLE}" in
		armv?-*)
			FLAGS="$FLAGS --enable-libarm32"
			;;
		aarch64-*)
			FLAGS="$FLAGS --enable-libarm64"
			;;
		i686-*)
			FLAGS="--enable-lib32 --disable-lib64"
			;;
		x86_64-*)
			FLAGS="--disable-lib32 --enable-lib64"
			;;
	esac
	FLAGS="$FLAGS --with-default-msvcrt=ucrt --enable-cfguard"

	rm -rf build && mkdir build && cd build
	# 不检查 ${TRIPLE}-cc, ${TRIPLE}-gcc 必须存在
	../configure --prefix=${PREFIX} --host=${TRIPLE} $FLAGS
	make
	make install
	make install DESTDIR=${PKG} >/dev/null

	 if [[ ! -f ${PKG}${PREFIX}/lib/libssp.a ]]; then
		# Create empty dummy archives, to avoid failing when the compiler
		# driver adds "-lssp -lssh_nonshared" when linking.
		install -d ${PKG}${PREFIX}/lib
		llvm-ar rcs ${PKG}${PREFIX}/lib/libssp.a
		llvm-ar rcs ${PKG}${PREFIX}/lib/libssp_nonshared.a
	fi

	[[ $1 != bootstrap ]] || { cd ../../..; return; }
	cd ../../mingw-w64-libraries
	cd winpthreads
	rm -rf build && mkdir build && cd build
	../configure --prefix=${PREFIX} --host=${TRIPLE} \
	C{,XX}FLAGS="$([[ $TRIPLE != aarch64-* ]] && echo $CFLAGS || echo ${CFLAGS/ -ffunction-sections}) -mguard=cf"
	make
	make install
	make install DESTDIR=${PKG} >/dev/null
	cd ../../../..
}

cleanup() {
	if [[ -n $(ls -A ${PKG}${PREFIX}/lib 2>/dev/null) ]]; then
		rm -rf ${PREFIX}
		rm -rf /usr/lib/clang/${LLVM_VER%%.*}/lib/windows
		cp -a ${PKG}/usr/* /usr
		rm -rf ${PKG}
	fi
}

if [[ $1 == bootstrap ]]; then
	prepare_src
	build_mingw bootstrap
	build_llvmrt bootstrap
elif [[ $1 == test ]]; then
	shift
	source test_build.sh
	t_build $*
else
	cleanup
	build_llvmrt
	build_mingw
	create_symlink ${PKG}
fi
