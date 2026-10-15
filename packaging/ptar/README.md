# Building plugin packages (`.ptar`)

plakar connectors ship as `.ptar` packages: a Kloset archive holding the
connector executables plus the `manifest.yaml` describing them.  `plakar pkg
build` produces one from a [recipe][recipe], which is a name, a git repository
and a tag:

```console
$ plakar pkg build recipe.yaml     # -> s3_v1.1.2_linux_amd64.ptar
```

Doing that by hand needs plakar, git, make and a Go toolchain new enough for
every plugin.  This directory wraps the whole thing in a container so the only
host requirement is docker, and uses [direnv][direnv] to keep the knobs out of
your shell history.

## Quick start

```console
$ direnv allow                    # once, loads the repository .envrc
$ make ptar                       # s3 + webdav for the host platform
$ ls dist/plugins
s3_v1.1.2_linux_amd64.ptar          webdav_v1.1.0-alpha.3_linux_amd64.ptar
s3_v1.1.2_linux_amd64.ptar.sha256   webdav_v1.1.0-alpha.3_linux_amd64.ptar.sha256
```

Then install one locally:

```console
$ plakar pkg add -allow-unsigned dist/plugins/s3_v1.1.2_linux_amd64.ptar
$ plakar pkg show
s3@v1.1.2
```

`-allow-unsigned` is needed because plakar refuses a package without a
signature and these carry none, see [Signatures](#signatures).

Without direnv, or from a script, the wrapper works standalone too:

```console
$ packaging/ptar/bin/plakar-ptar --help
$ packaging/ptar/bin/plakar-ptar --platforms 'linux/amd64 darwin/arm64' s3
```

and so does compose, on the same image and entrypoint:

```console
$ cd packaging/ptar && docker compose run --rm ptar webdav
```

## What is in here

| Path | Role |
| --- | --- |
| `recipes/s3.yaml` | S3 connector: storage, importer, exporter — own repository, plain semver tag |
| `recipes/webdav.yaml` | WebDAV connector: importer, exporter — `integrations` mono-repo, `webdav/`-prefixed tag |
| `Dockerfile` | builder image: plakar from this working tree + git, make, Go |
| `Dockerfile.dockerignore` | keeps `.git` (130+ MB) out of the build context |
| `build-ptar.sh` | the image entrypoint: recipe × platform → `.ptar` + `.sha256` |
| `bin/plakar-ptar` | host wrapper; `docker build` then `docker run` |
| `docker-compose.yml` | declarative equivalent of the wrapper |

The two recipes differ in a way worth knowing about, because `version` doubles
as the git tag:

- `s3` lives in its own repository, tagged `v1.1.2`.
- `webdav` lives in the `integrations` mono-repo, tagged `webdav/v1.1.0-alpha.3`.
  `plakar pkg build` splits that on the last `/`: the left side is the
  subdirectory to sparse-checkout and build, the right side is the semver that
  names the package.

## Knobs

All of them are exported by `.envrc` with the defaults below, so a plain
`make ptar` needs none of them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PTAR_PLATFORMS` | `linux/amd64` | space separated `os/arch` list to build for |
| `PTAR_DIST` | `dist/plugins` | output directory |
| `PTAR_GO_IMAGE` | `golang:1.26.5-alpine3.23` | Go base image of the builder |
| `PTAR_IMAGE` | `plakar-ptar-builder:local` | builder image tag |
| `PTAR_S3_VERSION` | — | build another tag, e.g. `v1.1.1` |
| `PTAR_WEBDAV_VERSION` | — | build another tag, e.g. `webdav/v1.1.0-alpha.2` |
| `PLAKAR_CLONE_TOKEN` | — | forwarded to plakar for private plugin repositories |

Put the secrets and the pins in an untracked `.env` (see `.env.example`);
direnv picks it up.

## Cross compilation

The plugins are pure Go, so `GOOS`/`GOARCH` is all it takes — no emulation, no
second container.  A single amd64 builder covers every target:

```console
$ make ptar PTAR_PLATFORMS='linux/amd64 linux/arm64 darwin/arm64 windows/amd64'
```

Both connectors are known to build for the ten targets `.goreleaser.yml` ships
plakar itself for — `{linux,darwin,windows,freebsd,openbsd}/{amd64,arm64}` —
which is what the release workflow packages.

Only the host platform's package gets the install smoke test (`pkg add
-allow-unsigned`, `pkg show`, then discard); the others are checked for
existence and checksummed.
Windows is handled by plakar itself, which passes `EXT=.exe` to the plugin's
Makefile and rewrites the manifest's executable names.

## Signatures

`plakar pkg add` verifies a package against the keys plakar trusts and, since
v1.1.5, refuses one that carries no signature.  The packages built here have
none: the `.sha256` next to each only lets you check a download, it does not
say who made the package.  Hence `-allow-unsigned`:

- `build-ptar.sh` passes it for the install smoke test, which runs in a
  throwaway state that is deleted right after;
- so does anyone installing one of these packages by hand.  plakar prints a
  warning each time.

The flag only waives the *absence* of a signature.  A package that is signed is
still verified, and a bad signature is still fatal.

## Notes on the container

- **Go version.** `GOTOOLCHAIN=local` is set in the image, so a plugin whose
  `go.mod` outgrows the base image fails the build with a clear message instead
  of quietly downloading a toolchain. Today the floor is webdav's `go 1.26.2`;
  raise `PTAR_GO_IMAGE` when that moves.
- **Caches.** The Go module and build caches live in a `gocache` volume, so a
  second run skips the downloads.
- **File ownership.** The build runs as root inside the container and `chown`s
  the artifacts to `$PTAR_OWNER` (`$(id -u):$(id -g)`, exported by `.envrc`) on
  the way out. `docker run --user 1234:1234` works too: plakar calls
  `user.Current()` at startup and refuses to run for a uid it cannot resolve, so
  the entrypoint adds the `/etc/passwd` entry when it can and otherwise sets the
  `$USER`/`$HOME` pair that Go's lookup falls back to.
- **Offline and quiet.** The entrypoint drops a `-disable-security-check` cookie
  into its throwaway state directory first, which suppresses both the first-run
  banner and the 24h release-feed poll. The only network traffic left is the git
  clone and the module downloads.

## CI

Two Forgejo workflows drive the same `build-ptar.sh`, so CI and `make ptar`
cannot drift apart:

- `.forgejo/workflows/ptar.yml` — on pull requests, on pushes to `main` touching
  this directory, and on demand. Builds the packages, smoke-tests the native one
  and keeps them as job artifacts. Its `docker-image` job additionally exercises
  the `Dockerfile` itself; it is opt-in through the `PTAR_BUILD_DOCKER`
  repository variable, because only the runner's administrator can grant a job
  access to a docker daemon.
- `.forgejo/workflows/ptar-release.yml` — on a `ptar/*` tag. Cross builds the
  ten release platforms and attaches everything to the Forgejo release.

Neither nests docker: a Forgejo runner already hands the job an isolated
container, so they install the toolchain, build plakar and call the script
directly.

Note that `.forgejo/workflows/ci.yml` exists for a related reason — Forgejo uses
only the *first* of `.forgejo/workflows`, `.gitea/workflows` and
`.github/workflows` that it finds, so adding this directory hides
`.github/workflows` from a Forgejo mirror entirely.

[recipe]: ../../subcommands/pkg/plakar-pkg-recipe.yaml.5
[direnv]: https://direnv.net
