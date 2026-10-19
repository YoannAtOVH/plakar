#!/bin/sh
#
# release -- publish the .ptar packages of a build as a GitHub release.
#
# Unlike a workflow artifact, an asset of a release in a public repository can be
# downloaded by anyone, without an account.  The release is named after the
# upstream plakar tag the packages were built with: ptar-v1.1.7 holds the packages
# assembled by plakar v1.1.7.  It is created on the commit that carries the
# packaging, and it is flagged as a pre-release when a package carries a
# pre-release version (webdav is still an alpha).
#
# When release immutability is enabled on the repository (Settings > Releases),
# publishing freezes the release: its assets and its tag can no longer change, the
# tag name can never be reused, and GitHub signs an attestation that `gh release
# verify` checks.  Hence the order followed here: create the release as a draft,
# upload the assets, check that GitHub holds exactly the files that were sent (it
# computes a sha256 for every asset), and only then publish.  A release that is
# immutable already is refused; a mutable one has its assets and notes replaced.
#
# Run by the `release` job of .github/workflows/ptar.yml, which hands it the
# packages built by the same run.
#
# Environment:
#   DIST               directory with the .ptar files and their .sha256     (required)
#   PLAKAR_REF         upstream plakar tag the packages were built with     (required)
#   GITHUB_REPOSITORY  owner/name                                           (required)
#   GITHUB_SHA         commit the release tag is created on                 (required)
#   GH_TOKEN           token allowed to write contents      (required, unless DRY_RUN)
#   RECIPE_DIR         recipes the packages come from        (default: ./recipes)
#   PLAKAR_VERSION     what `plakar version` printed for that build
#   RUN_URL            link to the run that built the packages
#   RELEASE_TAG        tag of the release                    (default: ptar-$PLAKAR_REF)
#   DRY_RUN=1          print the release notes and the plan, publish nothing
#   DRAFT_ONLY=1       create and check the draft, then stop: nothing becomes public

set -eu

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

: "${DIST:?DIST is required}"
: "${PLAKAR_REF:?PLAKAR_REF is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
here=$(cd -- "$(dirname -- "$0")" && pwd)
RECIPE_DIR="${RECIPE_DIR:-$here/recipes}"
PLAKAR_VERSION="${PLAKAR_VERSION:-unknown}"
RUN_URL="${RUN_URL:-}"
RELEASE_TAG="${RELEASE_TAG:-ptar-$PLAKAR_REF}"
DRY_RUN="${DRY_RUN:-}"
DRAFT_ONLY="${DRAFT_ONLY:-}"

# Only a plakar release gets a public release: a branch build would put a moving
# target under a name that reads like a version.
case $PLAKAR_REF in
v[0-9]*.[0-9]*.[0-9]*) ;;
*) die "refusing to publish for '$PLAKAR_REF': not a plakar release tag (vX.Y.Z)" ;;
esac

[ -d "$DIST" ] || die "no such directory: $DIST"
set -- "$DIST"/*.ptar
[ -e "$1" ] || die "no .ptar package in $DIST"
ptars=$*
for f in $ptars; do
	[ -s "$f.sha256" ] || die "$(basename "$f") has no .sha256 next to it"
done

# yaml_get FILE KEY -- read a top level scalar (same as build-ptar.sh).
yaml_get() {
	sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" |
		head -n 1 |
		sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# A package is <name>_<version>_<os>_<arch>.ptar: peel the platform off the end.
prerelease=false
platforms=
for f in $ptars; do
	b=${f##*/}
	b=${b%.ptar}
	arch=${b##*_}
	b=${b%_*}
	os=${b##*_}
	b=${b%_*}
	case ${b##*_} in
	*-*) prerelease=true ;;
	esac
	case " $platforms " in
	*" $os/$arch "*) ;;
	*) platforms="$platforms $os/$arch" ;;
	esac
done
platforms=${platforms# }

example=
for f in $ptars; do
	case $f in
	*_linux_amd64.ptar) example=${f##*/}; break ;;
	esac
done
[ -n "$example" ] || example=$(basename "${ptars%% *}")

bt=$(printf '\140')
base=https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG
title="Connector packages for plakar $PLAKAR_REF (unofficial builds)"
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT

{
	printf 'Community builds of the Plakar connectors, packaged as %s.ptar%s by the CI of this repository with plakar %s (%splakar version%s printed %s%s%s).\n\n' \
		"$bt" "$bt" "$PLAKAR_REF" "$bt" "$bt" "$bt" "$PLAKAR_VERSION" "$bt"
	printf '**These packages are not official and not signed.** plakar installs them only with %s-allow-unsigned%s, and the %s.sha256%s files only let you check your download: they do not say who made the package.\n\n' \
		"$bt" "$bt" "$bt" "$bt"
	printf '## Contents\n\n| Connector | Source and tag |\n| --- | --- |\n'
	for r in "$RECIPE_DIR"/*.yaml; do
		[ -f "$r" ] || continue
		printf '| %s | %s @ %s%s%s |\n' \
			"$(yaml_get "$r" name)" "$(yaml_get "$r" repository)" \
			"$bt" "$(yaml_get "$r" version)" "$bt"
	done
	printf '\nOne package per platform (%s), named %s<connector>_<version>_<os>_<arch>.ptar%s: take the one for your machine.\n\n' \
		"$platforms" "$bt" "$bt"
	printf '## Install\n\n%s%s%ssh\n' "$bt" "$bt" "$bt"
	printf 'curl -fLO %s/%s\n' "$base" "$example"
	printf 'curl -fLO %s/%s.sha256\n' "$base" "$example"
	printf 'sha256sum -c %s.sha256        # macOS: shasum -a 256 -c %s.sha256\n' "$example" "$example"
	printf 'plakar pkg add -allow-unsigned %s\n' "$example"
	printf 'plakar pkg show\n'
	printf '%s%s%s\n\n' "$bt" "$bt" "$bt"
	printf '## sha256\n\n%s%s%s\n' "$bt" "$bt" "$bt"
	cat "$DIST"/*.ptar.sha256
	printf '%s%s%s\n\n' "$bt" "$bt" "$bt"
	printf '## Verify\n\nDownloading needs no account.  When this release carries the "Immutable" badge, its tag and its assets can no longer change and GitHub signed an attestation of them.  With %sgh%s (which needs a GitHub login, a free account is enough):\n\n' "$bt" "$bt"
	printf '%s%s%ssh\n' "$bt" "$bt" "$bt"
	printf 'gh release verify %s -R %s\n' "$RELEASE_TAG" "$GITHUB_REPOSITORY"
	printf 'gh release verify-asset %s %s -R %s\n' "$RELEASE_TAG" "$example" "$GITHUB_REPOSITORY"
	printf '%s%s%s\n\n' "$bt" "$bt" "$bt"
	printf '## Provenance and licenses\n\n'
	if [ -n "$RUN_URL" ]; then
		printf 'Built by %s from commit %s%s%s; the packaging is in %spackaging/ptar%s.\n' \
			"$RUN_URL" "$bt" "$GITHUB_SHA" "$bt" "$bt" "$bt"
	else
		printf 'Built from commit %s%s%s; the packaging is in %spackaging/ptar%s.\n' \
			"$bt" "$GITHUB_SHA" "$bt" "$bt" "$bt"
	fi
	printf 'The plugins are static executables. Each package carries a %smanifest.yaml%s that declares its license; the sources linked above hold the license files, if any, and the Go dependencies keep their own licenses.\n' \
		"$bt" "$bt"
} >"$notes"

pre_flag=
[ "$prerelease" = true ] && pre_flag=--prerelease

if [ -n "$DRY_RUN" ]; then
	info "DRY RUN: nothing is published"
	info "repository : $GITHUB_REPOSITORY"
	info "tag        : $RELEASE_TAG (on $GITHUB_SHA)"
	info "title      : $title"
	info "pre-release: $prerelease"
	info "assets     :"
	for f in $ptars; do printf '    %s\n    %s.sha256\n' "$(basename "$f")" "$(basename "$f")"; done
	info "notes:"
	cat "$notes"
	exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
export GH_REPO="$GITHUB_REPOSITORY"

# Collect the assets: every package and its checksum, nothing else.
set --
for f in $ptars; do set -- "$@" "$f" "$f.sha256"; done

# check_assets FILE... -- GitHub computes a sha256 for every asset it receives:
# compare it with the files that were meant to be sent, and count them, before
# anything is made public.
check_assets() {
	remote=$(gh release view "$RELEASE_TAG" --json assets \
		--jq '.assets[] | "\(.name) \(.digest)"')
	for f in "$@"; do
		want=sha256:$(sha256sum "$f" | cut -d' ' -f1)
		got=$(printf '%s\n' "$remote" | awk -v n="${f##*/}" '$1 == n { print $2 }')
		[ "$got" = "$want" ] || return 1
	done
	[ "$(printf '%s\n' "$remote" | wc -l)" -eq "$#" ]
}

if state=$(gh release view "$RELEASE_TAG" --json isDraft,isImmutable \
	--jq '"\(.isDraft) \(.isImmutable)"' 2>/dev/null); then
	is_draft=${state%% *}
	is_immutable=${state##* }
	if [ "$is_draft" = true ]; then
		die "a draft of $RELEASE_TAG already exists, left by an earlier run: delete it (gh release delete $RELEASE_TAG --yes) and run again"
	fi
	if [ "$is_immutable" = true ]; then
		die "release $RELEASE_TAG is immutable: its assets and its tag cannot change any more. Publish under another tag (RELEASE_TAG=...); deleting the release would not free the tag name"
	fi
	info "release $RELEASE_TAG exists and is mutable: replacing its assets and notes"
	gh release upload "$RELEASE_TAG" "$@" --clobber
	check_assets "$@" || die "the assets GitHub holds for $RELEASE_TAG differ from the files here"
	gh release edit "$RELEASE_TAG" --title "$title" --notes-file "$notes" \
		--prerelease="$prerelease"
else
	info "creating the draft of release $RELEASE_TAG (tag on $GITHUB_SHA, unless it exists already)"
	# shellcheck disable=SC2086 # $pre_flag is either empty or one flag
	gh release create "$RELEASE_TAG" "$@" --draft --target "$GITHUB_SHA" \
		--title "$title" --notes-file "$notes" $pre_flag
	check_assets "$@" || die "the assets GitHub holds differ from the files here: the draft is left unpublished, inspect it then delete it (gh release delete $RELEASE_TAG --yes)"
	info "the $# assets GitHub holds match their sha256"
	if [ -n "$DRAFT_ONLY" ]; then
		info "DRAFT_ONLY: left as a draft, nothing is public"
		exit 0
	fi
	info "publishing"
	gh release edit "$RELEASE_TAG" --draft=false
fi

info "published: https://github.com/$GITHUB_REPOSITORY/releases/tag/$RELEASE_TAG"
info "immutable: $(gh release view "$RELEASE_TAG" --json isImmutable --jq .isImmutable)"
