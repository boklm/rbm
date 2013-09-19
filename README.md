mkpkg
=====

mkpkg is a tool to generate some packages from a git repository, using
package templates.

Some of the uses can be :

 - automatic creation of new packages when new commits are done on a git
   repository, for instance for continuous integration.

 - packaging for multiple distributions with templates.

 - regular maintainance of packages. This automates the creation of
   tarballs, with verification of gpg signature on tags and / or commits.


How it works
============

Most mkpkg commands take a project argument. A project corresponds to a
package and git repository, and is defined in the configuration.

The following commands are available :

 - **projects** :
        print the list of defined projects
 
 - **tar** :
        create a source tarball for a project
 
 - **rpm** :
        build an rpm package

 - **srpm** :
        create a source rpm package
 
 - **showconf** :
        print the configuration
 
 - **rpmspec** :
        create an rpm spec file, from the template file
 
 - **usage** :
        print usage information for a command


Configuration
=============

All configuration options can be defined in 3 different places :

- in the main configuration

- in a project configuration

- with a command line option

The command line options override the project configuration which
override the main configuration.

The main configuration file is *mkpkg.conf*, in YAML format. It can be
located anywhere on your filesystem, but you will need to run the
*mkpkg* commands from the same directory, or one of its subdirectories.
All relative paths used in the configuration are relative from the
*mkpkg.conf* location.

An example *mkpkg.conf* file will look like this :

```
projects_dir: projects
compress_tar: xz
```

The *projects_dir* option define the path to the directory containing
the projects definitions.

Adding a new project is done by creating a directory with the name of
the project inside the *projects_dir* directory, and adding a *config*
file in this new directory. The *config* file contains the configuration
for the project. At the minimum it should contain the *git_url*
configuration, and any other configuration option you want to set for
this project.

All the configuration options that can be set in the main configuration
file and projects configuration files can also be overrided with command
line options. The name of the command line option is the same as the
configuration file option, prepended with '--', and with '_' replaced
by '-'. For instance "output_dir: out" in the configuration file can be
replaced by "--output-dir=out".


Configuration options
=====================

The following configuration options are available :

- **projects_dir** :
        The directory containing the projects definitions. The default
        value is *projects*.

- **git_clone_dir** :
        The directory used to store clones of git repositories. The
        default value is *git_clones*.

- **output_dir** :
        The directory where output files (tarballs, spec files or
        packages) are created. The default value is *out*.

- **compress_tar** :
        If set, the tarball created will be compressed in the select
        format. Possible values: xz, gz, bz2.

- **version** :
        Version number of the software. This is used to create the
        tarball, and in the package spec file.

- **version_command** :
        A command to run in the checked out source tree to determine
        the version, if the *version* option is not set. The command
        should print the version on stdout.

- **pkg_rel** :
        Package release number.

- **git_hash** :
        A git hash, branch name or tag. This is what is used to create
        the tarball.

- **distribution** :
        The name of the distribution for which you wish to build a package.

- **commit_gpg_id** :
        If set, the commit selected with *git_hash* will have its
        signature checked. The tarball will not be created if there is
        no valid signature, and if the key used to sign it does not
        match the key id from *commit_gpg_id*. The option can be set to
        a single gpg id, or to a list of gpg ids. The format is like
        this: 1B678A63. For this to work, the GPG keys should be present
        in the GPG public keyring.

- **tag_gpg_id** :
        If set, the commit selected with *git_hash* should be a tag and
        will have its signature checked. The tarball will not be created
        if the tag doesn't have a valid signature, and if the key used
        to sign it does not match the key id from *tag_gpg_id*. The
        option can be set to a single gpg id, or to a list of gpg ids.
        The format is like this: 1B678A63. For this to work, the GPG
        keys should be present in the GPG public keyring.

- **copy_files** :
        A list of files that should be copied when building the package.
        Path is relative to the project's template directory.

In addition to the configuration options listed here, you are free to
add any other options that you want, and use them in the template files.
Unfortunately this also means that you won't have an error message in
case of typo in an option name.


Template files
==============

The template files are made using perl Template Toolkit. You can read
more about the syntax on the [Template Toolkit website][perltt].

[perltt]: http://www.template-toolkit.org/

The template files are added to the directory *projects_dir/project*
where *projects_dir* is the projects directory (the default is
*projects*) and *project* the name of the project. Other template files
can be added in the directory *projects_dir/common*, to be included
from any of the other templates.

The following variables can be used in the template files :

- **config** :
        contains all the configuration. You can view the content with
        `mkpkg showconf`.

- **c** :
        This variable is a function reference. Instead of accessing the
        *config* variable directly, you can use the *c* function which
        will look at the command line parameters, the project specific
        configuration then the global configuration and return the first
        defined one. The syntax to use this function is `c('option-name')`.

- **project** :
        The name of the project for which we are processing a template.

- **p** :
        The project's configuration. This is a shortcut for the value
        of `config.projects.$project`.

- **d** :
        The selected distribution configuration. This is a shortcut for
        `distro = c('distribution'); config.distributions.$distro`.


How the package version is set
==============================

The version of the package can be explicitely set with a command line
option (`--version [version]`) or in the configuration. If the version
is not explicitely set, then it is determined automatically in the
following way :

- If the *version_command* option is set, then the value of this option
  is run in the checked out source tree, and the output is used as the
  version.

- If the *version_command* is not set, or if running the command failed,
  then the most recent tag (as returned by git-describe) is used as
  version.


Examples
========

An example of package templates and configuration is available in this
git repository : https://github.com/boklm/mkpkg-templates


Installation
============

It is recommended to install *mkpkg* using packages. If you cannot
install with packages, it's also possible to clone this git repository
somewhere, and add a script similar to this one in your $PATH :


```
#!/bin/sh
mkpkg_dir=/some/directory
export PERL5LIB=$mkpkg_dir/lib
exec $mkpkg_dir/mkpkg "$*"
```

You will also need perl and the following perl modules installed :
 - YAML
 - Getopt::Long
 - Template
 - IO::CaptureOutput


TODO
====

- Add support for building packages inside a chroot, with [Mock][mock]
  or [Iurt][iurt].

- Add support for Debian packages

- Update file modification time of all created files to be the date of
  the commit used (to allow reproducible builds)

[mock]: http://fedoraproject.org/wiki/Projects/Mock
[iurt]: http://gitweb.mageia.org/software/build-system/iurt/

