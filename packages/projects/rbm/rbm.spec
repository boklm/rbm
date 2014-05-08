Name:           [% project %]
Version:        [% c('version') %]
Release:        [% c('rpm_rel') %]%{?dist}
Source:         %{name}-%{version}.tar.[% c('compress_tar') %]
Summary:        [% c('summary') %]
URL:            [% c('url') %]
License:        CC0
Group:          Text tools
BuildRequires:  asciidoc
BuildArch:      noarch
%description
[% c('description') -%]

%prep
%setup -q

%build

%install
make perldir=%{perl_vendorlib} DESTDIR=%{buildroot} install

%files
%doc README.md COPYING
%{_bindir}/%{name}
%{perl_vendorlib}/RBM.pm
%{perl_vendorlib}/RBM/DefaultConfig.pm
%{_mandir}/man1/rbm.1*
%{_mandir}/man1/rbm-*.1*
%{_mandir}/man7/rbm_*.7*
