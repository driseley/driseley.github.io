#!/usr/bin/env bash
#
# Update the Ruby dependencies for the Jekyll site in docs/.
#
# Everything runs inside the container built from tools/Dockerfile, so no local
# Ruby install is needed. The container runs as the calling user and keeps its
# gems inside the container, so docs/Gemfile.lock is the only file touched on
# the host and it stays owned by you rather than by root.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/update-gems.sh [options] [gem...]

  With no gem names, updates every gem as far as the Gemfile constraints allow.
  With gem names, updates only those gems and their dependencies.

Options:
  --no-verify   Skip the post-update site build (faster, but unchecked)
  -h, --help    Show this help

Examples:
  tools/update-gems.sh
  tools/update-gems.sh nokogiri
  tools/update-gems.sh --no-verify
EOF
}

verify=true
gems=()

for arg in "$@"; do
  case "$arg" in
    --no-verify) verify=false ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    *) gems+=("$arg") ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is required but was not found on PATH." >&2
  exit 1
fi

lockfile=docs/Gemfile.lock
previous=$(mktemp)
trap 'rm -f "$previous"' EXIT
cp "$lockfile" "$previous"

# Run as the host user so the rewritten lockfile is not owned by root, and keep
# HOME and the gem path on container-local paths the unprivileged user can write.
as_host_user=(
  --rm
  --user "$(id -u):$(id -g)"
  --env HOME=/tmp
  --env BUNDLE_PATH=/tmp/bundle
)

echo "==> Building the toolchain image"
docker compose build jekyll-serve

echo "==> Resolving dependencies"
# ${gems[@]+...} keeps an empty array from tripping `set -u` on older Bash.
docker compose run "${as_host_user[@]}" --entrypoint bundle jekyll-serve \
  lock --update ${gems[@]+"${gems[@]}"}

if [ "$verify" = true ]; then
  echo "==> Verifying the site still builds"
  # The default entrypoint runs `bundle install` before the given command.
  docker compose run "${as_host_user[@]}" jekyll-serve \
    bundle exec jekyll build -s /site -d /tmp/_site
fi

if diff -q "$previous" "$lockfile" >/dev/null; then
  echo "==> No dependency changes"
else
  echo "==> Changes to $lockfile"
  diff -u "$previous" "$lockfile" || true
  echo
  echo "Preview the site with: docker compose up jekyll-serve"
fi
