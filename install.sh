#!/usr/bin/bash

# install.sh - install the Insights CLI and our demo repository
# Written by Paul Wayper for Red Hat in August 2016.
# GPL v3 license applies - see https://www.gnu.org/licenses/gpl.html
# vim: set ts=4 et ai:

# We default to cloning the git repositories and installing from the local
# directories - as this gives the user the ability to write their own rules.
# We take the -n option to just use 'pip install' from the git repositories
# to just do a remote install without local source.  This is also the default
# if run as root.
# We also default to installing in a virtualenv if not run as root.  This
# can be turned off with the -r option.

required_packages=""

# TODO: long flags for options

install_source=$((UID==0?0:1))
use_virtualenv=$((UID==0?0:1))
help=0
verbose=0
git_fork=''
while getopts "g:hnrsv" opt; do
    case "${opt}" in
        g)
            git_fork="$OPTARG"
            ;;
        h)
            help=1
            ;;
        n)
            install_source=0
            ;;
        r)
            use_virtualenv=0
            ;;
        s)
            install_source=1
            ;;
        v)
            verbose=1
            ;;
    esac
done
shift $((OPTIND - 1))

# Check options

if [[ $help -eq 1 ]]; then
    echo "Usage: $0 [-g fork_name ] [-h] [-n] [-r] install_dir"
    echo "Options:"
    echo "  -g fork_name - use this fork of insights-core as a remote"
    echo "  -h           - this help"
    echo "  -n           - no source - do not clone source code locally"
    echo "  -r           - root install - do not use virtualenv for pip"
    echo "  -v           - let other programs be verbose"
    echo "(fork_name taken from https://github.com/fork_name/insights-core.git)"
    exit 0
fi

if [[ $install_source -eq 1 ]]; then
    # Now check that we've got a directory.
    if [[ -z "$1" ]]; then
        echo "Error: please supply directory to install/update Insights CLI:"
        echo "Usage: $0 [-g git_remote_URL ] [-h] [-n] [-r] [-s] install_dir"
        echo "e.g. $0 ~/insights/"
        exit 1
    fi
    echo "Installing source code."
    install_dir="$1"
else
    echo "Installing as pip modules."
fi

if [[ $use_virtualenv -eq 1 ]]; then
    echo "Installing using virtualenv"
    if [[ ${install_dir:0:1} != '/' ]]; then
        install_dir="$PWD/$1"
        echo "Warning: got relative path - installing to '$install_dir'."
    fi
else
    echo "Installing globally."
fi

pip_quiet='-q'
git_quiet='-q'
venv_quiet='-q'
if [[ $verbose -eq 1 ]]; then
    pip_quiet=''
    git_quiet=''
    venv_quiet=''
fi

################################# Functions #################################

function check_host {
    local host=$1
    if ! host $host >/dev/null; then
        echo "Error: cannot resolve $host - cannot continue."
        exit 2
    fi
}

function check_binary {
    local exe=$1
    # Supply the package name if it's not the same as the exe name
    local package=${2:-$1}
    if ! which $exe >/dev/null 2>&1; then
        echo "Warning: command '$exe' not installed..."
        required_packages="$required_packages $package"
    fi
}

function check_package {
    # Because of different OSes having different package names, step through
    # the list of package names and find the one that supplies what we need.
    local pkg=$1
    shift
    if ! rpm --quiet -q $pkg; then
        echo "Warning: package '$pkg' not installed..."
        required_packages="$required_packages $pkg"
    fi
}

# Version comparing thanks to http://stackoverflow.com/questions/16989598/bash-comparing-version-numbers
function version_lt() {
    test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" == "$1";
}

function check_python_version {
    local version=$( rpm -q python | cut -d - -f 2 )
    if version_lt $version '2.7.0'; then
        echo "Error: Python must be at least version 2.7.0 (got $version) - cannot install."
        exit 2
    fi
}

function install_requirements {
    if [[ ! -z "$required_packages" ]]; then
        if [[ $UID -eq 0 ]]; then
            echo "Installing required packages..."
            yum install -y $required_packages
        else
            echo "Installing required packages - sudo access required:"
            sudo yum install -y $required_packages
        fi
    fi
    for pkg in $required_packages; do
        if ! rpm -q $pkg; then
            echo "Error: $pkg did not get installed - cannot continue."
            exit 2
        fi
    done
    required_packages=''
}

function install_pip_exact_ver {
    local package=$1
    local version=$2
    local op=${3:-==}
    echo "Installing $package $version for Python 2.7 compatibility"
    if ! pip install $pip_quiet $package$op$version; then
        echo "ERROR: install of $package version $version failed.  Try the -v flag or 'pip install $package==$version' in the virtualenv"
        exit 2
    fi
}

function update_repo {
    local repo=$1
    local reponame=$2
    dir=${repo##*/}
    dir=${dir%%.git}
    # TODO: error detection

    dir_branch='master'
    extra_install_flag=''
    if [[ "$repo" =~ 'insights-core' ]]; then
        # This script tries to set it up so that people can develop new rules,
        # so we need to install the packages needed for developing in python.
        extra_install_flag='[develop]'
    fi

    if [[ $install_source -eq 0 ]]; then
        echo "... Just installing via PIP"
        pip install $pip_quiet --upgrade ${repo}${extra_install_flag}
        return
    fi

    # If the directory doesn't exist already, we only have to clone and
    # install.
    requires_branch_change=0
    requires_unstash=0
    current_branch='master'
    if [[ ! -d $dir ]]; then
        echo "Installing $reponame into $dir"
        git clone $git_quiet $repo $dir
        # Sanity check - if $dir doesn't exist, git clone failed.
        if [[ ! -d $dir ]]; then
            echo "... ERROR: '$dir' not created - run with -v to find out why."
            exit 2
        fi
    else
        echo "Updating $reponame in $dir"
        cd $dir

        # We need to stash any changes the user might have made, go to the
        # master branch, pull that, and then pip install from that.  Then we
        # get back to where the user was by changing back to their branch and
        # unstashing the changes.
        current_branch=$( git branch | grep '*' | cut -c 3- )
        if [[ $current_branch != $dir_branch ]]; then
            requires_branch_change=1
            if [[ $( git diff | wc -l ) -gt 0 ]]; then
                requires_unstash=1
                git stash save
            fi
        fi

        # Has the 'origin' remote changed?  If so, we need to change that.
        current_origin=$( git remote -v | awk '/origin.*fetch/ {print $2}' )
        if [[ $current_origin != $repo ]]; then
            echo "...Remote URL for 'origin' repository set to $repo"
            git remote set-url origin $repo
        fi

        cd ..
    fi # Clone into directory or update existing

    # Now pull down the required branch and update or install from it
    if [[ $requires_branch_change -eq 1 ]]; then
        cd $dir
        git checkout $git_quiet $dir_branch
        git pull $git_quiet
        cd ..
    fi
    pip install $pip_quiet -e ${dir}${extra_install_flag}

    # Set everything back the way the user had it before
    if [[ $requires_branch_change -eq 1 ]]; then
        cd $dir
        git checkout $git_quiet "$current_branch"
        if [[ $requires_unstash -eq 1 ]]; then
            git stash pop
        fi
        cd ..
    fi

    # If the user has specified another remote to set up via the -g flag,
    # Set that up.
    if [[ ! -z "$git_fork" && $repo =~ 'insights-core' ]]; then
        local_repo_url=${repo/RedHatInsights/$git_fork}
        cd $dir
        git remote add $git_fork $local_repo_url
        cd ..
    fi
}

# Pre-requisites:
# 1a) Python >= 2.7.0
echo "Checking version of python..."
check_python_version

# Script pre-requisites
check_binary host bind-utils
install_requirements

# 1b) able to access VPN for git requests
echo "Checking we can access git servers..."
check_host github.com

# 1c) Is virtualenv and other requirements available?
echo "Checking if required commands and packages are installed..."
check_binary sudo
check_binary python
check_binary virtualenv python-virtualenv
check_binary pip python-pip
check_binary git
check_package libyaml-devel

install_requirements

# Worth noting that putting any pip dependencies here is wrong - they should
# be listed as dependencies of the things we're installing :-)

if [[ $use_virtualenv -eq 1 ]]; then
    # 2a) create target directory if not already existing
    if [[ ! -d "$install_dir" ]]; then
        echo "Creating new directory '$install_dir'..."
        mkdir -p "$install_dir"
    else
        echo "Using existing directory '$install_dir'..."
    fi

    cd "$install_dir"
    if [[ ! -f bin/activate ]]; then
        virtualenv $venv_quiet .
    fi
    . bin/activate
    # Early versions of pip don't understand the [develop] suffix, so we
    # should upgrade pip.
    pip install $pip_quiet --upgrade pip
fi

# 2017-06-05 - Sphinx 1.6.2 seems to need Python > 3.5; preinstall 1.6.1 to
# fix this problem
install_pip_exact_ver Sphinx '1.6.1'

# 2017-11-01 - cryptography > 2.1 seems to not install on Python 2.7, use 1.9
install_pip_exact_ver cryptography '1.9'

# 2018-01-30 - ipython above 5.0 doesn't like Python 2.7 either, use 5.0
install_pip_exact_ver ipython '5.2' '<'

########################################
# Install the actual Insights components

update_repo https://github.com/RedHatInsights/insights-core.git "rules engine"

update_repo https://github.com/RedHatInsights/insights-plugins-demo.git "demo rule set"

# Safety check - if the user has $HOME/bin in their path, but it doesn't
# exist, create it because we can use it.
if echo $PATH | grep -q $HOME/bin; then
    if [[ ! -d $HOME/bin ]]; then
        mkdir $HOME/bin
        echo "As a convenience, $HOME/bin now exists for you"
    fi
fi

# Put insights-cli in $HOME/bin as a convenience if not already set up
if [[ -d $HOME/bin && ! -h $HOME/bin/insights-cli ]]; then
    ln -s "$install_dir/bin/insights-cli" $HOME/bin/insights-cli
    echo "You should now be able to use 'insights-cli' as a command!"
fi

echo "Insights installer finished."
