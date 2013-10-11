VERSION=0.4

PROJECTNAME=mkpkg
BINFILES=mkpkg
PERL_MODULE_MAIN=lib/MkPkg.pm
PERL_MODULES=lib/MkPkg/DefaultConfig.pm

sysconfdir=/etc
bindir=/usr/bin
perldir=/usr/lib/perl5/site_perl

.PHONY: all install clean

all:
	$(MAKE) -C doc

install:
	install -d $(DESTDIR)$(bindir) $(DESTDIR)$(sysconfdir)
	install -m 755 $(BINFILES) $(DESTDIR)$(bindir)
	install -d $(DESTDIR)$(perldir) $(DESTDIR)$(perldir)/MkPkg
	install -m 644 $(PERL_MODULE_MAIN) $(DESTDIR)$(perldir)
	install -m 644 $(PERL_MODULES) $(DESTDIR)$(perldir)/MkPkg
	$(MAKE) -C doc install

clean:
	$(MAKE) -C doc clean

