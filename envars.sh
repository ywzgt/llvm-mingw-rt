CFLAGS="-mtune=haswell -O2 -pipe -fPIC -ffunction-sections -fdata-sections"
CXXFLAGS="$CFLAGS"
CPPFLAGS="-DNDEBUG"
LDFLAGS="-Wl,-O2,--gc-sections"
MAKEFLAGS="-j$(nproc)"
NINJA_STATUS="[%r %f/%t %es] "

unset NINJAJOBS
export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS NINJA_STATUS
