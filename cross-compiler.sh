#!/bin/bash

# Get lots of predefined environment variables and shell functions.

source include.sh

rm -rf "${CROSS}"
mkdir -p "${CROSS}" || dienow

# Orange
echo -e "\e[33m"

[ -z "$BUILD_STATIC" ] || STATIC_FLAGS='--static'

# Build and install binutils

setupfor binutils build-binutils &&
AR=ar AS=as LD=ld NM=nm OBJDUMP=objdump OBJCOPY=objcopy \
"${CURSRC}/configure" --prefix="${CROSS}" --host=${CROSS_HOST} \
	--target=${CROSS_TARGET} --with-lib-path=lib --disable-nls \
	--disable-shared --disable-multilib --program-prefix="${ARCH}-" \
	$BINUTILS_FLAGS &&
make -j $CPUS configure-host &&
make -j $CPUS CFLAGS="-O2 $STATIC_FLAGS" &&
make -j $CPUS install &&
cd .. &&
mkdir -p "${CROSS}/include" &&
cp binutils/include/libiberty.h "${CROSS}/include"

cleanup binutils build-binutils

# Build and install gcc

setupfor gcc-core build-gcc &&
AR_FOR_TARGET="${ARCH}-ar" "${CURSRC}/configure" $GCC_FLAGS \
	--prefix="${CROSS}" --host=${CROSS_HOST} --target=${CROSS_TARGET} \
	--enable-languages=c --disable-threads --disable-multilib \
	--disable-nls --disable-shared --program-prefix="${ARCH}-" &&
make -j $CPUS all-gcc LDFLAGS="$STATIC_FLAGS" &&
make -j $CPUS install-gcc &&
cd .. &&

echo Fixup toolchain... &&

# Write this out as a script snippet for debugging purposes.

cat > fixup-toolchain.sh << EOF &&
# Move the gcc internal libraries and headers somewhere sane.

mkdir -p "${CROSS}"/gcc &&
mv "${CROSS}"/lib/gcc/*/*/include "${CROSS}"/gcc/include &&
mv "${CROSS}"/lib/gcc/*/* "${CROSS}"/gcc/lib &&
ln -s ${CROSS_TARGET} ${CROSS}/tools &&
ln -sf ../../../../tools/bin/ld  ${CROSS}/libexec/gcc/*/*/collect2 &&
rm -rf "${CROSS}"/{lib/gcc,{libexec/gcc,gcc/lib}/install-tools} &&

# Build and install gcc wrapper script.

cd "${CROSS}"/bin &&
mv "${ARCH}-gcc" gcc-unwrapped &&
$CC $STATIC_FLAGS -Os -s "${SOURCES}"/toys/gcc-uClibc.c -o "${ARCH}-gcc"
EOF

# Run toolchain fixup and cleanup

chmod +x fixup-toolchain.sh &&
./fixup-toolchain.sh

cleanup "${CURSRC}" build-gcc

# Set up symlinks for distcc

mkdir -p "${CROSS}/distcc" &&
ln -s ../bin/gcc-unwrapped "${CROSS}/distcc/cc" &&
ln -s ../bin/gcc-unwrapped "${CROSS}/distcc/gcc" &&
ln -s ../bin/"$ARCH-as" "${CROSS}/distcc/as"

[ $? -ne 0 ] && dienow

# Install kernel headers.

setupfor linux &&
# Install Linux kernel headers (for use by uClibc).
make -j $CPUS headers_install ARCH="${KARCH}" INSTALL_HDR_PATH="${CROSS}" &&
cd ..

cleanup linux

# Build and install uClibc

setupfor uClibc

if [ -e /usr/include ]
then
  # Build $ARCH-readelf and $ARCH-ldd

  # "make utils" in uClibc is broken for cross compiling.  Either it creates a
  # target binary (which you can't run on the host), or it tries to link the
  # host binary against the target library, and use the target compiler flags
  # (neither of which is going to produce a working host binary).  The solution
  # is to bypass the broken build entirely, and do it by hand.
  make CROSS= allnoconfig &&
  make CROSS= headers KERNEL_HEADERS=/usr/include &&
  $CC $STATIC_FLAGS -Os -s -I include utils/readelf.c \
      -o "${CROSS}/bin/${ARCH}-readelf" &&
  $CC $STATIC_FLAGS -Os -s -I ldso/include utils/ldd.c \
      -o "${CROSS}/bin/${ARCH}-ldd" &&
  make CROSS= distclean

  [ $? -ne 0 ] && dienow
fi

# Build and install the uClibc libraries.

make CROSS= allnoconfig KCONFIG_ALLCONFIG="${CONFIG_DIR}"/miniconfig-uClibc &&
# Can't use -j here, build is unstable.
make CROSS="${ARCH}-" KERNEL_HEADERS="${CROSS}/include" PREFIX="${CROSS}/" \
	RUNTIME_PREFIX=/ DEVEL_PREFIX=/ all install_runtime install_dev &&
cd ..

cleanup uClibc

cat > "${CROSS}"/README << EOF &&
Cross compiler for $ARCH
From http://landley.net/code/firmware

To use: Add the "bin" directory to your \$PATH, and use "$ARCH-gcc" as
your compiler.

The syntax used to build the Linux kernel is:

  make ARCH=${KARCH} CROSS_COMPILE=${ARCH}-

EOF

# Strip everything

cd "$CROSS"
for i in `find bin -type f` `find "$CROSS_TARGET" -type f`
do
  strip "$i" 2> /dev/null
done
#for i in `find lib -type f` `find gcc/lib -type f`
#do
#  "${ARCH}-strip" "$i" 2> /dev/null
#done

echo -n creating "build/cross-compiler-${ARCH}".tar.bz2 &&
cd "${BUILD}"
{ tar cjvf "cross-compiler-${ARCH}".tar.bz2 cross-compiler-"${ARCH}" || dienow
} | dotprogress

[ $? -ne 0 ] && dienow

# A quick hello world program to test the cross-compiler out.
# Build hello.c dynamic, then static, to verify header/library paths.

echo "Sanity test: building Hello World."

"${ARCH}-gcc" -Os "${SOURCES}/toys/hello.c" -o "$WORK"/hello &&
"${ARCH}-gcc" -Os -static "${SOURCES}/toys/hello.c" -o "$WORK"/hello &&
if which qemu-"${QEMU_TEST}" > /dev/null
then
  [ x"$(qemu-"${QEMU_TEST}" "${WORK}"/hello)" == x"Hello world!" ] &&
  echo Cross-toolchain seems to work.
fi

[ $? -ne 0 ] && dienow

echo -e "\e[32mCross compiler toolchain build complete.\e[0m"
