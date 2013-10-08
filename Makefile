VERSION=0.3

PROJECTNAME=mkpkg
BINFILES=mkpkg
PERL_MODULE_MAIN=lib/MkPkg.pm
PERL_MODULES=lib/MkPkg/DefaultConfig.pm

sysconfdir=/etc
bindir=/usr/bin
perldir=/usr/lib/perl5/site_perl

.PHONY: all install

all:

install:
	install -d $(DESTDIR)$(bindir) $(DESTDIR)$(sysconfdir)
	install -m 755 $(BINFILES) $(DESTDIR)$(bindir)
	install -d $(DESTDIR)$(perldir) $(DESTDIR)$(perldir)/MkPkg
	install -m 644 $(PERL_MODULE_MAIN) $(DESTDIR)$(perldir)
	install -m 644 $(PERL_MODULES) $(DESTDIR)$(perldir)/MkPkg

