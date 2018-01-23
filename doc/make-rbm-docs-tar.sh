#!/bin/sh
set -e
docsdir=$(pwd)
tmpdir=$(mktemp -d)
make clean
make install-web webdir="$tmpdir"
cd "$tmpdir"
chmod 664 *
tar -cf "$docsdir"/rbm-docs.tar *
cd -
rm -Rf "$tmpdir"
echo "You can now update the web site with:"
echo "  ssh staticiforme.torproject.org tar --overwrite -p -C /srv/rbm-master.torproject.org/htdocs -xf - < rbm-docs.tar"
echo "  ssh staticiforme.torproject.org static-update-component rbm.torproject.org"
