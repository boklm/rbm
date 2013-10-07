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

 - maintainance of built tarballs. You can build packages, but it's also
   possible to use custom build scripts.


How it works
============

Most mkpkg commands take a project argument. A project corresponds to a
package and git repository, and is defined in the configuration.

The following commands are available :

 - **projects** :
        print the list of defined projects
 
 - **fetch** :
        fetch new commits from the git repository of a project

 - **tar** :
        create a source tarball for a project
 
 - **rpm** :
        build an rpm package

 - **srpm** :
        create a source rpm package
 
 - **deb-src** :
        create a debian source package

 - **build** :
        build the project, using a template build script

 - **showconf** :
        print the configuration. This can display all the configuration,
        or only select values. Using this command can help understand
        how configuration works.
 
 - **rpmspec** :
        create an rpm spec file, from the template file
 
 - **usage** :
        print usage information for a command


Configuration
=============

All configuration options can be defined in 3 different places :

- in the main configuration in your working directory

- in the global system configuration

- in a project configuration

- with a command line option

The command line options override the project configuration which
override the main configuration, which override the system
configuration.

The system configuration is by default located at */etc/mkpkg.conf*, or
the path defined in the *sysconf_file* option. If the path does not
exists, it is ignored. This is where you will put configuration only
relevant to your local use of mkpkg.

The main configuration file is *mkpkg.conf*, in YAML format. It can be
located anywhere on your filesystem, but you will need to run the
*mkpkg* commands from the same directory, or one of its subdirectories.
This is where you will put configuration relevant to all projects under
this working directory. All relative paths used in the configuration
are relative from the *mkpkg.conf* location.

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

- **sysconf_file** :
        The path to an optional system configuration file. The default
        is */etc/mkpkg.conf*. This can also be set with the --sysconf-file
        command line parameter.

- **projects_dir** :
        The directory containing the projects definitions. The default
        value is *projects*.

- **git_clone_dir** :
        The directory used to store clones of git repositories. The
        default value is *git_clones*.

- **output_dir** :
        The directory where output files (tarballs, spec files or
        packages) are created. The default value is *out*.

- **fetch** :
        The value should be 0 or 1, depending on whether the commits
        from the remote git repository should be fetched automatically.

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
        match the key ID from *commit_gpg_id*. The option can be set to
        a single gpg ID, or to a list of gpg IDs. The IDs can be short
        or long IDs, or full fingerprint (with no spaces). For this to
        work, the GPG keys should be present in the selected keyring
        (see *keyring* option). If the option is set to 1 or an array
        containing 1 then any key from the selected keyring is accepted.
        On command line, the *--commit-gpg-id* option can be listed
        multiple times to define a list of keys.

- **tag_gpg_id** :
        If set, the commit selected with *git_hash* should be a tag and
        will have its signature checked. The tarball will not be created
        if the tag doesn't have a valid signature, and if the key used
        to sign it does not match the key ID from *tag_gpg_id*. The
        option can be set to a single gpg ID, or to a list of gpg IDs.
        The IDs can be short or long IDs, or full fingerprint (with no
        spaces). For this to work, the GPG keys should be present in
        the selected keyring (see *keyring* option). If the option is
        set to 1 or an array containing 1 then any key from the selected
        keyring is accepted. On command line, the *--tag-gpg-id* option
        can be listed multiple times to define a list of keys.

- **gpg_wrapper** :
        This is a template for a gpg wrapper script. The default wrapper
        will call gpg with the keyring specified by option *gpg_keyring*
        if defined.

- **gpg_keyring** :
        The filename of the gpg keyring to use. Path is relative to the
        *gpg_keyring_dir* directory. This can also be an absolute path.

- **gpg_keyring_dir** :
        The directory containing gpg keyring files. The default is
        *$basedir/keyring* (with $basedir the directory where the main
        config file is located).

- **gpg_bin** :
        The gpg command to be used. The default is *gpg*.

- **gpg_args** :
        Optional gpg arguments. The default is empty.

- **copy_files** :
        A list of files that should be copied when building the package.
        Path is relative to the project's template directory.

- **timestamp** :
        This is the UNIX timestamp, set as modification time on files
        created such as the sources tarball and rpm spec file. The
        default is to use the commit time of the commit used. If set to
        0 it will use the current time.

- **notmpl** :
        An array containing a list of options that should not be
        processed as template (see the *template* section below for
        details).

- **rpmspec** :
        This is the content of the rpm spec file, used by the *rpm* and
        *srpm* commands. The default is to include the template file named
        *project.spec* (with *project* replaced by the project's name).

- **rpmbuild** :
        This is the content of the script to build a rpm.

- **build** :
        This is the content of the build script used by the *build*
        command. The default is to include the template file named
        *build*.

- **deb_src** :
        This is the script that is used to create the debian source
        package. By default it will use the debian files listed in the
        option *debian_files* and create the source package with
        dpkg-source.

- **debian_files** :
        This is an array containing the files to create in the debian
        directory. Each item in the array is an hash, with the following
        two keys : *name* is the file name in the debian directory of
        the file to create, and *content* is the content of the file.
        The filename and content are processed as template, so for
        instance if you want to store the content of a file in a separate
        file, you can use the INCLUDE directive.

In addition to the configuration options listed here, you are free to
add any other options that you want, and use them in the template files.
Unfortunately this also means that you won't have an error message in
case of typo in an option name.


Templates
=========

All configuration options are actually templates. So you can use
template directives in any of the option. There are a few exceptions
however, for the options that are needed to process templates, so they
can't be templated themself. The following options are not templated :

 - distribution
 - projects_dir

If you want to make other options not templated, add them to the
*notmpl* config option, which is an array. All the other options are
automatically processed as template.

The template are made using perl Template Toolkit. You can read more
about the syntax on the [Template Toolkit website][perltt].

[perltt]: http://www.template-toolkit.org/

From any template, it is possible to include other template files using
the *INCLUDE* directive. The template files are added to the directory
*projects_dir/project* where *projects_dir* is the projects directory
(the default is *projects*) and *project* the name of the project. Other
template files can be added in the directory *projects_dir/common*, to
be included from any of the other templates.

There are different template files :
By default, the following template files are used :

- the rpm spec file template, named *project.spec* (replacing *project*
  with the project's name). This is used when you use the *rpmspec*,
  *srpm* *rpm*, or *build* commands. This creates the *rpmspec* option.
  If you don't want to use this file, just replace the *rpmspec* option
  by something else.

- the build script template, named *build*. This template is used to
  create a build script, that is executed when you use the *build*
  command. This creates the *build* option.

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
        Optionally it can take as a second argument a hash table
        containing options to override temporarily (in template processing).
        Additionally the 2nd argument can contain the following options :
        *no_tmpl* : set this to 1 if you want to disable template processing
        for this option lookup. *error_if_undef* : set this to 1 (for
        default error message) or a string containing an error message
        if you want to exit with an error when the selected option is
        undefined.

- **project** :
        The name of the project for which we are processing a template.

- **p** :
        The project's configuration. This is a shortcut for the value
        of `config.projects.$project`.

- **d** :
        The selected distribution configuration. This is a shortcut for
        `distro = c('distribution'); config.distributions.$distro`.

- **dest_dir** :
        The destination directory, where the resulting files will be
        stored at the end of the build. This is mainly useful in build
        script templates, and probably not useful in package template
        files.

- **exit_error** :
        A function that you can use to exit with an error. The first
        argument is an error message. The second argument is an optional
        exit code (default is 1).

- **exec** :
        A function taking a command line as argument, to be executed in
        the sources tree. The output of the command is returned, if the
        exit code was 0. If the argument starts with '#', then it is
        considered to be a script, which will be written to a temporary
        file and executed.

- **path** :
        A function to return an absolute path. It takes a path as first
        argument. If the path is already an absolute path, then it
        returns the same thing. If the path is a relative path, it
        returns the path concatenated with *basedir* which is the
        directory where the main configuration file is located.
        Optionally it can take a second argument to set an other value
        for the *basedir*.

- **tmpl** :
        A function taking a template text as argument, and returning it
        processed.


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
 - YAML::XS
 - Getopt::Long
 - Template
 - IO::CaptureOutput
 - File::Slurp


Git Version
===========

If you are going to use gpg signed commits, it is recommended to use
git >= 1.8.3.

 - git < 1.7.9 does not support signed commits. It only supports signed
   tags.

 - git < 1.8.3 does not use the *git-config* option *gpg.program* in
   `git log --show-signature` and `git show --show-signatures` commands
   used to check commits signatures. This means you won't be able to
   use the *gpg_keyring* option for commits signature verification (but
   it will work for tag signature verification). This was fixed in git
   commit *6005dbb9*, included in version 1.8.3.


TODO
====

- Add support for building packages inside a chroot, with [Mock][mock]
  or [Iurt][iurt].

- Add support for Debian packages

- Make it possible to run the package build inside a chroot, a VM or
  remote node

- Add a test command. After building packages, this run some integration
  tests on the packages. This works on packages, or other files created
  by the build command.

- Add an upload command, with a default upload template script.
  This will build packages, run the tests if any, and upload/copy the
  packages to a repository. Depending on selected distro the template
  will decide if it should build an rpm or deb, where to upload it and
  how to update repo metadata.

- Add an option to download a tarball, instead of creating it. In the
  config it should be possible to add an url and an sha256sum of a
  tarball that will be downloaded, and can be used to build the package.

- Make the *d* template variable a function that returns the distro
  config option value. Make it possible to override distro config in a
  project's config.

- Make it possible to use perl config files (probably named *config.pl*)
  in addition to the yaml config files. That would allow to use a perl
  function for some of the options.

- Add a pkg template function that take a generic package name as
  argument, and return a distro specific package name. To do this, it
  will use the first undef value after trying in the following order :
   * if the config option *distributions/[distro]/packages* is a hash,
     then return the value with generic package name as key
   * if the config option *distributions/[distro]/packages* is a string,
     then use it as the package name. You could do an exec in this option,
     if you want to use a script to convert the package name.
   * return the same package name

- Write default templates for perl, python, ruby modules, and plugins
  to generate config file for modules with infos from CPAN, Python
  package index, Ruby gems, etc ... This should make it possible to
  create a package for any supported distribution, for a perl, python,
  ruby module with a single command.

[mock]: http://fedoraproject.org/wiki/Projects/Mock
[iurt]: http://gitweb.mageia.org/software/build-system/iurt/

