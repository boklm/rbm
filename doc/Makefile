.PHONY: clean html man install-man install-web install all

prefix ?= /usr
mandir ?= $(prefix)/share/man
man1dir = $(mandir)/man1
man5dir = $(mandir)/man5
man7dir = $(mandir)/man7
webdir = /tmp/www

INSTALL ?= install
ASCIIDOC = asciidoc
ASCIIDOC_ARGS =
ifdef ASCIIDOC_THEME
    ASCIIDOC_ARGS += --theme $(ASCIIDOC_THEME)
endif
A2X      = a2x

MAN1_ASC =
MAN5_ASC =
MAN7_ASC =

MAN1_MAN = $(patsubst %.asc,%.1,$(MAN1_ASC))
MAN5_MAN = $(patsubst %.asc,%.5,$(MAN5_ASC))
MAN7_MAN = $(patsubst %.asc,%.7,$(MAN7_ASC))

MAN1_ASC += burps.asc
MAN1_ASC += burps-usage.asc
MAN1_ASC += burps-tar.asc
MAN1_ASC += burps-showconf.asc
MAN1_ASC += burps-srpm.asc
MAN1_ASC += burps-rpm.asc
MAN1_ASC += burps-rpmspec.asc
MAN1_ASC += burps-fetch.asc
MAN1_ASC += burps-deb-src.asc
MAN1_ASC += burps-deb.asc
MAN1_ASC += burps-pkg.asc

MAN7_ASC += burps_tutorial.asc
MAN7_ASC += burps_layout.asc
MAN7_ASC += burps_config.asc
MAN7_ASC += burps_templates.asc
MAN7_ASC += burps_remote.asc
MAN7_ASC += burps_distributions.asc
MAN7_ASC += burps_targets.asc

MAN_ASC = $(MAN1_ASC) $(MAN5_ASC) $(MAN7_ASC)
MAN_MAN = $(MAN1_MAN) $(MAN5_MAN) $(MAN7_MAN)

PAGES_ASC = $(MAN_ASC)
PAGES_ASC += index.asc
PAGES_ASC += license.asc
PAGES_ASC += todo.asc
PAGES_ASC += git-version.asc
PAGES_ASC += changelog.asc

PAGES_HTML = $(patsubst %.asc,%.html,$(PAGES_ASC))

all: man

%.html: %.asc
	$(ASCIIDOC) $(ASCIIDOC_ARGS) -b xhtml11 $<

%.1: %.asc
	$(A2X) -f manpage $<
%.5: %.asc
	$(A2X) -f manpage $<
%.7: %.asc
	$(A2X) -f manpage $<

html: $(PAGES_HTML)

man: $(MAN_MAN)

install-man: man
	$(INSTALL) -d -m 755 $(DESTDIR)$(man1dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man5dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man7dir)
	$(INSTALL) -m 644 $(MAN1_MAN) $(DESTDIR)$(man1dir)
#	$(INSTALL) -m 644 $(MAN5_MAN) $(DESTDIR)$(man5dir)
	$(INSTALL) -m 644 $(MAN7_MAN) $(DESTDIR)$(man7dir)

install-web: html
	$(INSTALL) -d -m 755 $(DESTDIR)$(webdir)
	$(INSTALL) -m 644 $(PAGES_HTML) $(DESTDIR)$(webdir)

install: install-man

clean:
	rm -f *.html *.1 *.5 *.7
