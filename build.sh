#!/bin/sh

if [ "$INSIDE_DOCKER_CONTAINER" != "1" ]; then
	echo "Must be run in docker container"
	exit 1
fi

set -e
cd /mnt/raspotify

# Get the git rev of raspotify for .deb versioning
RASPOTIFY_GIT_VER="$(git describe --tags "$(git rev-list --tags --max-count=1)" 2>/dev/null || echo unknown)"

RASPOTIFY_HASH="$(git rev-parse HEAD | cut -c 1-7 2>/dev/null || echo unknown)"

echo "Build Raspotify $RASPOTIFY_GIT_VER~$RASPOTIFY_HASH $ARCHITECTURE..."

packages() {
	cd /mnt/raspotify
	if [ ! -d librespot ]; then
		# Use a vendored version of librespot.
		# https://github.com/librespot-org/librespot does not regularly or
		# really ever update their dependencies on released versions.
		# https://github.com/librespot-org/librespot/pull/1068
		git clone https://github.com/JasonLG1979/librespot
		cd librespot
		git checkout raspotify
		cd /mnt/raspotify
	fi

	DOC_DIR="raspotify/usr/share/doc/raspotify"

	if [ ! -d "$DOC_DIR" ]; then
		echo "Copy over copyright & readme files..."
		mkdir -p "$DOC_DIR"
		cp -v LICENSE "$DOC_DIR/copyright"
		cp -v readme "$DOC_DIR/readme"
		cp -v librespot/LICENSE "$DOC_DIR/librespot.copyright"
	fi

	cd librespot

	# Get the git rev of librespot for .deb versioning
	LIBRESPOT_VER="$(git describe --tags "$(git rev-list --tags --max-count=1)" 2>/dev/null || echo unknown)"

	LIBRESPOT_HASH="$(git rev-parse HEAD | cut -c 1-7 2>/dev/null || echo unknown)"

	echo "Build Librespot binary..."

	cargo build --jobs "$(nproc)" --profile raspotify --target "$BUILD_TARGET" --no-default-features --features "alsa-backend pulseaudio-backend"

	echo "Copy Librespot binary to pkg root..."
	cd /mnt/raspotify

	cp -v /build/"$BUILD_TARGET"/raspotify/librespot raspotify/usr/bin

	# Compute final package version + filename for Debian control file
	DEB_PKG_VER="${RASPOTIFY_GIT_VER}~librespot.${LIBRESPOT_VER}-${LIBRESPOT_HASH}"
	DEB_PKG_NAME="raspotify_${DEB_PKG_VER}_${ARCHITECTURE}.deb"

	# https://www.debian.org/doc/debian-policy/ch-controlfields.html#installed-size
	# "The disk space is given as the integer value of the estimated installed size
	# in bytes, divided by 1024 and rounded up."
	INSTALLED_SIZE="$((($(du -bs raspotify --exclude=raspotify/DEBIAN/control | cut -f 1) + 2048) / 1024))"

	echo "Generate Debian control..."
	export DEB_PKG_VER
	export INSTALLED_SIZE
	envsubst <control.debian.tmpl >raspotify/DEBIAN/control

	echo "Build Raspotify deb..."
	dpkg-deb -b raspotify "$DEB_PKG_NAME"

	PACKAGE_SIZE="$(du -bs "$DEB_PKG_NAME" | cut -f 1)"

	echo "Raspotify package built as: $DEB_PKG_NAME"
	echo "Estimated package size:     $PACKAGE_SIZE (Bytes)"
	echo "Estimated installed size:   $INSTALLED_SIZE (KiB)"

	if [ ! -d asound-conf-wizard ]; then
		git clone https://github.com/JasonLG1979/asound-conf-wizard.git
	fi

	cd asound-conf-wizard

	# Build asound-conf-wizard deb
	echo "Build asound-conf-wizard deb..."

	cargo-deb --profile default --target "$BUILD_TARGET" -- --jobs "$(nproc)"

	cd /build/"$BUILD_TARGET"/debian

	AWIZ_DEB_PKG_NAME=$(ls -1 -- *.deb)

	PACKAGE_SIZE="$(du -bs "$AWIZ_DEB_PKG_NAME" | cut -f 1)"

	echo "Copy asound-conf-wizard to pkg root..."
	cp -v "$AWIZ_DEB_PKG_NAME" /mnt/raspotify

	echo "asound-conf-wizard package built as: $AWIZ_DEB_PKG_NAME"
	echo "Estimated package size:              $PACKAGE_SIZE (Bytes)"
}

armhf() {
	ARCHITECTURE="armhf"
	BUILD_TARGET="armv7-unknown-linux-gnueabihf"
	packages
}

arm64() {
	ARCHITECTURE="arm64"
	BUILD_TARGET="aarch64-unknown-linux-gnu"
	packages
}

amd64() {
	ARCHITECTURE="amd64"
	BUILD_TARGET="x86_64-unknown-linux-gnu"
	packages
}

all() {
	armhf
	arm64
	amd64
}

build() {
	case $ARCHITECTURE in
	"armhf")
		armhf
		;;
	"arm64")
		arm64
		;;
	"amd64")
		amd64
		;;
	"all")
		all
		;;
	esac
}

build

# Perm fixup. Not needed on macOS, but is on Linux
chown -R "$PERMFIX_UID:$PERMFIX_GID" /mnt/raspotify 2>/dev/null || true

echo "Build complete"
