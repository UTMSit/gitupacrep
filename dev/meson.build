NAME=meson
VERSION=1.5.2
REVISION=1
URL=https://github.com/mesonbuild/meson/releases/download/${VERSION}/meson-${VERSION}.tar.gz
DEPENDS="python"

build() {
    python3 setup.py build
}

upac_install() {
    python3 setup.py install --root="${1}" --prefix=/usr
}
