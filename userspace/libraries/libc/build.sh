build() {
    pushd .
        cd $script_dir && \
        make ARCH=$opt_arch RELEASE=1 -B -j`nproc` libc.a libm.a && \
        make install \
            LIBDIR=$opt_toolsdir/lib/gcc/$opt_arch/8.3.0/ \
            INCLUDEDIR=$opt_toolsdir/lib/gcc/$opt_arch/8.3.0/include
    popd
}

install() {
    echo -ne
}
