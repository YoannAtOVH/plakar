#!/bin/sh
#
# build-ptar -- assemble plakar plugin packages (.ptar) from recipes.
#
# This runs *inside* the builder image (packaging/ptar/Dockerfile).  On the
# host use packaging/ptar/bin/plakar-ptar, `make ptar`, or docker compose,
# all of which start the container for you.
#
# Usage: build-ptar [recipe | path/to/recipe.yaml ...]
#
# With no argument every recipe in $RECIPE_DIR is built.  Each recipe is built
# once per platform listed in $PTAR_PLATFORMS.
#
# Environment:
#   PTAR_PLATFORMS       space separated os/arch list      (default linux/amd64)
#   PTAR_<NAME>_VERSION  pin one recipe's version/git tag  (e.g. PTAR_S3_VERSION)
#   PTAR_OWNER           uid:gid to chown the artifacts to, for bind mounts
#   PLAKAR_CLONE_TOKEN   token `plakar pkg build` uses for private clones
#   RECIPE_DIR, OUT_DIR  input and output directories      (default /recipes, /out)

set -eu

RECIPE_DIR="${RECIPE_DIR:-/recipes}"
OUT_DIR="${OUT_DIR:-/out}"
PTAR_PLATFORMS="${PTAR_PLATFORMS:-linux/amd64}"
STATE_DIR="${PTAR_STATE_DIR:-/tmp/plakar-state}"

die() { printf 'build-ptar: %s\n' "$*" >&2; exit 1; }
warn() { printf 'build-ptar: warning: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

# Keep plakar's config, cache and data out of $HOME: the container may run
# under an arbitrary uid, and a per-build state directory also keeps the pebble
# cache from being shared between concurrent invocations.
run_plakar() {
	plakar -configdir "$STATE_DIR/config" \
	       -cachedir "$STATE_DIR/cache" \
	       -datadir "$STATE_DIR/data" \
	       "$@"
}

# yaml_get FILE KEY -- read a top level scalar.  A recipe only ever holds three
# of them, which is not worth pulling a YAML parser into the image for.
yaml_get() {
	sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" |
		head -n 1 |
		sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# A bare word means "a recipe shipped in the image", anything that looks like a
# path is used as given, so a caller can bind mount its own recipe.
resolve_recipe() {
	case $1 in
	*/* | *.yaml | *.yml) printf '%s\n' "$1" ;;
	*) printf '%s/%s.yaml\n' "$RECIPE_DIR" "$1" ;;
	esac
}

setup() {
	mkdir -p "$STATE_DIR/config" "$STATE_DIR/cache" "$STATE_DIR/data" "$OUT_DIR"

	HOST_OS=$(go env GOHOSTOS)
	HOST_ARCH=$(go env GOHOSTARCH)

	# plakar calls user.Current() at startup and gives up ("go away casper !")
	# when the uid has no passwd entry -- which is exactly what `docker run
	# --user 1234:1234` gives you.  Add the entry if /etc/passwd happens to be
	# writable; either way make sure $USER and $HOME are both set and usable,
	# because that is the fallback Go's pure-Go lookup needs to succeed.
	if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
		[ -n "${USER:-}" ] || USER=builder
		if [ -z "${HOME:-}" ] || [ ! -w "${HOME:-}" ]; then
			HOME=$STATE_DIR/home
			mkdir -p "$HOME"
		fi
		export HOME USER

		if [ -w /etc/passwd ]; then
			printf '%s:x:%s:%s:%s:%s:/sbin/nologin\n' \
				"$USER" "$(id -u)" "$(id -g)" "$USER" "$HOME" >>/etc/passwd
		fi
	fi

	# First run prints a welcome banner, and from then on plakar polls the
	# release feed every 24h.  This cookie (stored in the cache directory)
	# turns both off, keeping the build quiet and offline.
	run_plakar -disable-security-check >/dev/null
}

build_one() {
	recipe=$1
	goos=$2
	goarch=$3

	name=$(yaml_get "$recipe" name)
	version=$(yaml_get "$recipe" version)
	repository=$(yaml_get "$recipe" repository)

	[ -n "$name" ] || die "$recipe: no 'name'"
	[ -n "$version" ] || die "$recipe: no 'version'"
	[ -n "$repository" ] || die "$recipe: no 'repository'"

	# Same charset plakar itself accepts (namere in subcommands/pkg/build.go).
	# Checked here too because the name is spliced into a variable name below.
	case $name in
	*[!_a-zA-Z0-9-]*) die "$recipe: not a valid plugin name: $name" ;;
	esac

	# PTAR_S3_VERSION, PTAR_WEBDAV_VERSION, ... let CI build an arbitrary tag
	# without rewriting the tracked recipe.
	var="PTAR_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_VERSION"
	eval "override=\${$var:-}"
	if [ -n "$override" ] && [ "$override" != "$version" ]; then
		info "$name: \$$var overrides $version with $override"
		version=$override
	fi

	# `version` is the git tag; for mono-repo recipes it reads
	# "<subdir>/<semver>" and only the semver part names the package.
	semver=${version##*/}
	out="${name}_${semver}_${goos}_${goarch}.ptar"

	work=$(mktemp -d)
	printf 'name: %s\nversion: %s\nrepository: %s\n' \
		"$name" "$version" "$repository" >"$work/recipe.yaml"

	info "$out  <-  $repository @ $version"

	# `plakar pkg build` writes the package to its working directory, and the
	# underlying ptar store refuses to overwrite, so clear the way first.
	rm -f "$OUT_DIR/$out"
	(
		cd "$OUT_DIR" || exit 1
		GOOS=$goos
		GOARCH=$goarch
		export GOOS GOARCH
		run_plakar pkg build "$work/recipe.yaml"
	)
	rm -rf "$work"

	[ -s "$OUT_DIR/$out" ] || die "$name: expected $out, nothing was produced"
	(cd "$OUT_DIR" && sha256sum "$out" >"$out.sha256")

	# Smoke test what we can actually load: installing a foreign platform's
	# package would fail on the executables, so only the native one is tried.
	if [ "$goos" = "$HOST_OS" ] && [ "$goarch" = "$HOST_ARCH" ]; then
		verify_native "$name" "$OUT_DIR/$out"
	fi
}

# verify_native NAME PTAR -- install the package into a throwaway plakar state
# and check it shows up, then remove it.  Catches a ptar that is well formed but
# carries a manifest plakar refuses.
#
# Since v1.1.5 plakar installs only signed packages, and nothing here signs
# them, so the install passes -allow-unsigned.  That waives the check for this
# throwaway state alone; a signature that is present is still verified.
verify_native() {
	vname=$1
	vptar=$2
	vstate=$(mktemp -d)

	vplakar() {
		plakar -configdir "$vstate/config" -cachedir "$vstate/cache" \
		       -datadir "$vstate/data" "$@"
	}

	# As setup() does for the build state: no first-run banner to wade through
	# if the install has to be diagnosed below.
	vplakar -disable-security-check >/dev/null

	# `pkg add` explains a refusal on its own ("package is not signed", a
	# manifest it dislikes, ...), so keep what it says and show it on failure.
	if vout=$(vplakar pkg add -allow-unsigned "$vptar" 2>&1) &&
		vplakar pkg show | grep -q "^$vname@"; then
		info "$vname: installs cleanly"
	else
		rm -rf "$vstate"
		printf '%s\n' "$vout" >&2
		die "$vname: $(basename "$vptar") does not install"
	fi

	rm -rf "$vstate"
}

if [ $# -eq 0 ]; then
	set -- "$RECIPE_DIR"/*.yaml
	[ -e "$1" ] || die "no recipe found in $RECIPE_DIR"
fi

setup

for spec in "$@"; do
	recipe=$(resolve_recipe "$spec")
	[ -f "$recipe" ] || die "no such recipe: $spec"

	for platform in $PTAR_PLATFORMS; do
		os=${platform%%/*}
		arch=${platform##*/}
		case $platform in
		*/*/*) die "platform must read os/arch, got: $platform" ;;
		*/*) [ -n "$os" ] && [ -n "$arch" ] ||
			die "platform must read os/arch, got: $platform" ;;
		*) die "platform must read os/arch, got: $platform" ;;
		esac
		build_one "$recipe" "$os" "$arch"
	done
done

# Bind mounted output is created by the container's uid; hand it back so the
# artifacts are not root owned on the host.
if [ -n "${PTAR_OWNER:-}" ]; then
	chown "$PTAR_OWNER" "$OUT_DIR"/*.ptar "$OUT_DIR"/*.ptar.sha256 2>/dev/null ||
		warn "could not chown the artifacts to $PTAR_OWNER"
fi

info "packages in $OUT_DIR:"
ls -l "$OUT_DIR"/*.ptar
