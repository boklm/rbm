VERSION=0.3

PROJECTNAME=mkpkg
BINFILES=mkpkg
PERL_MODULES=lib/MkPkg.pm

sysconfdir=/etc
bindir=/usr/bin
perldir=/usr/lib/perl5/site_perl

.PHONY: all install

all:

install:
	install -d $(DESTDIR)$(bindir) $(DESTDIR)$(sysconfdir)
	install -m 755 $(BINFILES) $(DESTDIR)$(bindir)
	install -d $(DESTDIR)$(perldir)
	install -m 644 $(PERL_MODULES) $(DESTDIR)$(perldir)

