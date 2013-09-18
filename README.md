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

In addition to the configuration options listed here, you are free to
add any other options that you want, and use them in the template files.
Unfortunately this also means that you won't have an error message in
case of typo in an option name.


Template files
==============

The template files are made using perl Template Toolkit. You can read
more about the syntax on the [Template Toolkit website][perltt].

TODO: description of the variables that can be used.

[perltt]: http://www.template-toolkit.org/


Examples
========

TODO


TODO
====

TODO: add list of things to do.

