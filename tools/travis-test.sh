#!/bin/bash
set -o errexit
set -o xtrace

# travis boxes give you 1.5 cpus
export NPY_NUM_BUILD_JOBS=2

# setup env
if [ -r /usr/lib/libeatmydata/libeatmydata.so ]; then
  # much faster package installation
  export LD_PRELOAD=/usr/lib/libeatmydata/libeatmydata.so
fi

python_sysconfig()
{
  $PYTHON -c "from distutils import sysconfig; print (sysconfig.get_config_var('CFLAGS'))"
}

setup_base()
{
  # windows compilers have this requirement
  common_cflags="-Werror=declaration-after-statement -Werror=nonnull"

  # We used to use 'setup.py install' here, but that has the terrible
  # behaviour that if a copy of the package is already installed in
  # the install location, then the new copy just gets dropped on top
  # of it. Travis typically has a stable numpy release pre-installed,
  # and if we don't remove it, then we can accidentally end up
  # e.g. running old test modules that were in the stable release but
  # have been removed from master. (See gh-2765, gh-2768.)  Using 'pip
  # install' also has the advantage that it tests that numpy is 'pip
  # install' compatible, see e.g. gh-2766...
if [ -z "$USE_DEBUG" ]; then
  if [ -z "$IN_CHROOT" ]; then
    $PIP install .
  else
    sysflags="$(python_sysconfig)"
    CFLAGS="$sysflags $common_cflags -Wlogical-op" $PIP install . 2>&1 | tee log
    grep -v "_configtest" log | grep -vE "ld returned 1|no previously-included files matching" | grep -E "warning\>";
    # accept a mysterious memset warning that shows with -flto
    test $(grep -v "_configtest" log | grep -vE "ld returned 1|no previously-included files matching" | grep -E "warning\>" -c) -lt 2;
  fi
else
  sysflags="$(python_sysconfig)"
  CFLAGS="$sysflags $common_cflags" $PYTHON setup.py build_ext --inplace
fi
}

setup_chroot()
{
  # this can all be replaced with:
  # apt-get install libpython2.7-dev:i386
  # CC="gcc -m32" LDSHARED="gcc -m32 -shared" LDFLAGS="-m32 -shared" linux32 python setup.py build
  # when travis updates to ubuntu 14.04
  DIR=$1
  set -u
  fakechroot fakeroot debootstrap --variant=fakechroot \
                       --include=fakeroot,build-essential,eatmydata \
                       --arch=$ARCH --foreign \
                       $DIST $DIR
  fakechroot fakeroot chroot $DIR ./debootstrap/debootstrap --second-stage
  rsync -a $TRAVIS_BUILD_DIR $DIR/
  tee $DIR/etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ $DIST main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $DIST-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $DIST-security  main restricted universe multiverse
EOF
  echo /usr/lib/libeatmydata/libeatmydata.so | tee -a $DIR/etc/ld.so.preload
  fakeroot fakechroot $DIR bash -c "apt-get update"
  fakeroot fakechroot $DIR bash -c "apt-get install -qq -y --force-yes libatlas-dev libatlas-base-dev gfortran python3-dev python3-nose python3-pip cython3 cython"
}

setup_bento()
{
  export CI_ROOT=$PWD
  cd ..

  # Waf
  wget https://raw.githubusercontent.com/numpy/numpy-vendor/master/waf-1.7.16.tar.bz2
  tar xjvf waf-1.7.16.tar.bz2
  cd waf-1.7.16
  python waf-light
  export WAFDIR=$PWD
  cd ..

  # Bento
  wget https://github.com/cournape/Bento/archive/master.zip
  unzip master.zip
  cd Bento-master
  python bootstrap.py
  export BENTO_ROOT=$PWD
  cd ..

  cd $CI_ROOT

  # In-place numpy build
  $BENTO_ROOT/bentomaker build -v -i -j

  # Prepend to PYTHONPATH so tests can be run
  export PYTHONPATH=$PWD:$PYTHONPATH
}

run_test()
{
  if [ -n "$USE_DEBUG" ]; then
    export PYTHONPATH=$PWD
  fi

  # We change directories to make sure that python won't find the copy
  # of numpy in the source directory.
  mkdir -p empty
  cd empty
  INSTALLDIR=$($PYTHON -c "import os; import numpy; print(os.path.dirname(numpy.__file__))")
  export PYTHONWARNINGS=default
  $PYTHON ../tools/test-installed-numpy.py # --mode=full
  # - coverage run --source=$INSTALLDIR --rcfile=../.coveragerc $(which $PYTHON) ../tools/test-installed-numpy.py
  # - coverage report --rcfile=../.coveragerc --show-missing
}

# travis venv tests override python
PYTHON=${PYTHON:-python}
PIP=${PIP:-pip}

if [ -n "$USE_DEBUG" ]; then
  PYTHON=python3-dbg
fi

if [ -n "$PYTHON_OO" ]; then
  PYTHON="$PYTHON -OO"
fi

export PYTHON
export PIP
if [ -n "$USE_WHEEL" ] && [ $# -eq 0 ]; then
  # Build wheel
  $PIP install wheel
  $PYTHON setup.py bdist_wheel
  # Make another virtualenv to install into
  virtualenv --python=python venv-for-wheel
  . venv-for-wheel/bin/activate
  # Move out of source directory to avoid finding local numpy
  pushd dist
  $PIP install --pre --upgrade --find-links . numpy
  $PIP install nose
  popd
  run_test
elif [ "$USE_CHROOT" != "1" ] && [ "$USE_BENTO" != "1" ]; then
  setup_base
  run_test
elif [ -n "$USE_CHROOT" ] && [ $# -eq 0 ]; then
  DIR="$HOME/chroot"
  setup_chroot $DIR
  # run again in chroot with this time testing
  linux32 fakechroot $DIR bash -c "cd numpy && PYTHON=python3 PIP=pip3 IN_CHROOT=1 $0 test"
elif [ -n "$USE_BENTO" ] && [ $# -eq 0 ]; then
  setup_bento
  # run again this time testing
  $0 test
else
  run_test
fi

