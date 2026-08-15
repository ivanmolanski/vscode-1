#!/bin/bash
set -e
cd /tmp

echo "=== Download privoxy 4.2.0 ==="
wget -q http://deb.debian.org/debian/pool/main/p/privoxy/privoxy_4.2.0.orig.tar.gz
tar xzf privoxy_4.2.0.orig.tar.gz
cd privoxy-4.2.0

echo "=== Configure ==="
autoheader
autoconf
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --enable-static

echo "=== Build ==="
make -j$(nproc)

echo "=== Install ==="
sudo make install

echo "=== Verify ==="
privoxy --version
