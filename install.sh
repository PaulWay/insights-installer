#!/usr/bin/bash

# install.sh - install the Insights CLI as per:
# https://docs.google.com/document/d/1eFWhpi9XCvmGOLVDsSc6GQSa1Tah78CTh2PKQUQ_QLo/edit
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

# TODO: support --no-source long flag for -n
# TODO: support -h and --help
# TODO: support --root long flag for -r

install_source=$((UID==0?0:1))
use_virtualenv=$((UID==0?0:1))
github_remotes=0
insights_developer=0
help=0
git_remote_URL=''
while getopts "ghnrs" opt; do
    case "${opt}" in
        d)
            insights_developer=1
            ;;
        g)
            github_remotes=1
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
    esac
done
shift $((OPTIND - 1))

if [[ $help -eq 1 ]]; then
    echo "Usage: $0 [-g git_remote_URL ] [-h] [-n] [-r] install_dir"
    echo "Options:"
    echo "  -g git_remote_URL - set this URL as a git remote for diag-insights-rules"
    echo "  -h                - this help"
    echo "  -n                - no source - do not clone source code locally"
    echo "  -r                - root install - do not use virtualenv for pip"
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
    # the list of package names and find the one that
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

function update_repo {
    local repo=$1
    shift
    dir=${repo##*/}
    dir=${dir%%.git}
    # TODO: error detection

    if [[ $install_source -eq 0 ]]; then
        echo "... Just installing via PIP"
        if [[ $repo =~ 'falafel' ]]; then
            pip install -q --upgrade ${repo}[develop]
        else
            pip install -q --upgrade $repo
        fi
        return
    fi

    if [[ ! -d $dir ]]; then
        echo "...Cloning source into $dir"
        git clone -q $repo $dir $@
        if [[ $dir == 'falafel' ]]; then
            pip install -q -e falafel[develop]
        else
            pip install -q -e $dir
        fi

    else
        echo "...Updating source in $dir"
        cd $dir

        # We need to stash any changes the user might have made, go to the
        # master branch, pull that, and then pip install from that.  Then we
        # get back to where the user was by changing back to their branch and
        # unstashing the changes.
        # git stash on a directory with no changes is a warning but OK - if
        # there was a way to detect whether there was outstanding changes we
        # should use it.  Then update when using master.

        local current_branch=$( git branch | grep '*' | cut -c 3- )
        if [[ $current_branch != 'master' ]]; then
            git stash save
            git checkout master
        fi

        # Has the 'origin' remote changed?  If so, we need to change that.
        current_origin=$( git remote -v | awk '/origin.*fetch/ {print $2}' )
        if [[ $current_origin != $repo ]]; then
            echo "...Remote URL for 'origin' repository set to $repo"
            git remote set-url origin $repo
        fi

        git pull -q
        cd ..
        # This script tries to set it up so that people can develop new rules,
        # so we need to install the packages needed for developing in python.
        if [[ $dir == 'insights-core' ]]; then
            pip install -q -e $dir[develop]
        else
            pip install -q -e $dir
        fi

        if [[ $current_branch != 'master' ]]; then
            cd $dir
            git checkout "$current_branch"
            git stash apply
            cd ..
        fi
    fi

    # Set up the GitHub remotes for this directory if they aren't already set.
    # Only do this if our 'origin' repo is the internal one
    if [[ $github_remotes -eq 1 && $repo =~ 'gitlab.cee.redhat.com/insights-open-source' ]]; then
        # Convert Repo URL to GitHub URL:
        github_url=${repo/gitlab.cee.redhat.com/github.com}
        github_url=${github_url/insights-open-source/RedHatInsights}

        cd $dir
        if git remote | grep -q ^github; then
            echo "...GitHub remote for $dir exists already"
        else
            git remote add github $github_url
            echo "...git remote 'github' set to $github_url"
        fi
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
check_host gitlab.cee.redhat.com
if [[ $github_remotes -eq 1 ]]; then
    check_host github.com
fi

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
        virtualenv .
    fi
    . bin/activate
fi

echo "Installing rules engine..."
update_repo https://github.com/RedHatInsights/insights-core.git

echo "Installing Command Line interface..."
update_repo https://github.com/RedHatInsights/insights-cli.git

echo "Installing Insights plugins..."
update_repo https://github.com/RedHatInsights/insights-plugins.git

echo "Installing Support Delivery plugins..."
update_repo https://gitlab.cee.redhat.com/insights-sd/diag-insights-rules.git

echo "Installing Insights content server..."
update_repo https://github.com/RedHatInsights/insights-content-server.git

echo "Installing Insights content..."
update_repo https://gitlab.cee.redhat.com/insights-open-source/insights-content.git

# Safety check - if we don't have a bin/insights-cli here, something's wrong.
if [[ ! -f "$install_dir/bin/insights-cli" ]]; then
    echo "Error: cannot find $install_dir/bin/insights-cli - install has failed?"
    exit 2
fi

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
