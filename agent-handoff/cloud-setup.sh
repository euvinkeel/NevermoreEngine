#!/usr/bin/env bash
# Reproduces the M0 toolchain in a Linux cloud session (no aftman, no GitHub API).
#
#   bash agent-handoff/cloud-setup.sh            # tools + pnpm install + tool build + sourcemap
#   bash agent-handoff/cloud-setup.sh --selene-std   # also generate roblox.yml for selene
#   export PATH="$HOME/.nevermore-headless/bin:$PATH"
#
# Why it exists:
# - aftman resolves versions through api.github.com, which the cloud proxy blocks (403).
#   Release asset downloads from github.com work, so tools are fetched directly.
# - pnpm-lock.yaml pins five dependencies as codeload.github.com tarballs (jecs, Iris, Fusion,
#   Highlighter, BufferEncoder). codeload is blocked too, but `git fetch` of the same public
#   repos works. We rebuild identical tarballs with `git archive`, point the lockfile's
#   `resolution: {tarball: ...}` lines at them for the install only, then restore the lockfile.
#   Those entries carry no integrity hash, and `--frozen-lockfile` only checks specifiers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${NEVERMORE_HEADLESS_TOOLS:-$HOME/.nevermore-headless}"
BIN="$TOOLS_DIR/bin"
TARBALLS="$TOOLS_DIR/tarballs"
mkdir -p "$BIN" "$TARBALLS" "$TOOLS_DIR/dl"

fetch_zip() { # name url
	local name="$1" url="$2"
	if [[ -x "$BIN/$name" ]]; then return; fi
	echo "Downloading $name"
	curl -fsSL -o "$TOOLS_DIR/dl/$name.zip" "$url"
	unzip -o -q "$TOOLS_DIR/dl/$name.zip" -d "$BIN"
	chmod +x "$BIN/$name"
}

# Versions mirror aftman.toml.
fetch_zip lune "https://github.com/lune-org/lune/releases/download/v0.10.5/lune-0.10.5-linux-x86_64.zip"
fetch_zip stylua "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.3.1/stylua-linux-x86_64.zip"
fetch_zip selene "https://github.com/Kampfkarren/selene/releases/download/0.29.0/selene-0.29.0-linux.zip"
fetch_zip luau-lsp "https://github.com/Quenty/luau-lsp/releases/download/1.58.0-quenty.1/luau-lsp-linux-x86_64.zip"
fetch_zip rojo "https://github.com/quenty/rojo/releases/download/v7.7.0-rc.3-quenty/rojo-7.7.0-rc.3-quenty-linux-x86_64.zip"
# aftman.toml says UpliftGames/moonwave; the releases are served from evaera/moonwave.
fetch_zip moonwave-extractor "https://github.com/evaera/moonwave/releases/download/v1.3.0/moonwave-extractor-v1.3.0-linux.zip"
export PATH="$BIN:$PATH"
for t in lune rojo stylua selene luau-lsp; do printf '%-9s %s\n' "$t" "$("$t" --version 2>&1 | head -1)"; done

# The repo's Claude hooks (.claude/hooks) run stylua and `npm run lint:luau` with the default PATH,
# so expose the tools there when we can.
if [[ -w /usr/local/bin ]]; then
	for t in lune rojo stylua selene luau-lsp moonwave-extractor; do ln -sf "$BIN/$t" "/usr/local/bin/$t"; done
fi

# `lune setup` writes typedefs to ~/.lune/.typedefs and also adds an alias to .luaurc in the
# current directory, so run it outside the repo.
(cd "$TOOLS_DIR" && lune setup >/dev/null)

if [[ "${1:-}" == "--tools-only" ]]; then exit 0; fi

# Rebuild codeload tarballs from git for every codeload resolution in the lockfile.
cd "$REPO_ROOT"
grep -oE 'resolution: \{tarball: https://codeload\.github\.com/[^}]+\}' pnpm-lock.yaml \
	| sed -E 's#.*codeload\.github\.com/([^/]+)/([^/]+)/tar\.gz/([0-9a-f]+)\}#\1 \2 \3#' \
	| sort -u | while read -r owner repo sha; do
		out="$TARBALLS/$repo-$sha.tar.gz"
		if [[ -f "$out" ]]; then continue; fi
		echo "Building $owner/$repo@$sha from git"
		tmp="$(mktemp -d)"
		git init -q "$tmp"
		git -C "$tmp" fetch -q --depth 1 "https://github.com/$owner/$repo" "$sha"
		git -C "$tmp" archive --format=tar.gz --prefix="$repo-$sha/" -o "$out" FETCH_HEAD
		rm -rf "$tmp"
	done

cp pnpm-lock.yaml "$TOOLS_DIR/pnpm-lock.yaml.orig"
restore_lock() { cp "$TOOLS_DIR/pnpm-lock.yaml.orig" "$REPO_ROOT/pnpm-lock.yaml"; }
trap restore_lock EXIT
sed -i -E "s#resolution: \\{tarball: https://codeload\\.github\\.com/([^/]+)/([^/]+)/tar\\.gz/([0-9a-f]+)\\}#resolution: {tarball: file:$TARBALLS/\\2-\\3.tar.gz}#" pnpm-lock.yaml
pnpm install --frozen-lockfile
restore_lock
trap - EXIT

# Mirrors .github/workflows/linting.yml.
pnpm -r --filter './tools/**' --filter '!./tools/nevermore-vscode' run build
# Reinstalling over an existing global link fails inside npm ("reading 'package'"), so skip it.
command -v nevermore >/dev/null || (cd tools/nevermore-cli && npm install --ignore-scripts -g . >/dev/null)
npm run build:sourcemap

# `npm run lint:selene` needs roblox.yml from `selene generate-roblox-std`, which downloads the API
# dump with its own bundled CA roots and so rejects the proxy's certificate. With --selene-std, build
# selene 0.29.0 from crates.io with ureq's native-certs feature (about 1.5 min) just to generate it.
if [[ " $* " == *" --selene-std "* && ! -f roblox.yml ]]; then
	SRC="$TOOLS_DIR/selene-src"
	mkdir -p "$SRC"
	curl -fsSL -o "$SRC/selene.crate" https://crates.io/api/v1/crates/selene/0.29.0/download
	tar xzf "$SRC/selene.crate" -C "$SRC"
	sed -i '/\[dependencies.ureq\]/,/^optional/ s/features = \["json"\]/features = ["json", "native-certs"]/' "$SRC/selene-0.29.0/Cargo.toml"
	(cd "$SRC/selene-0.29.0" && cargo build --release)
	"$SRC/selene-0.29.0/target/release/selene" generate-roblox-std
fi

echo "Done. Next: export PATH=\"$BIN:\$PATH\" && npm run lint:luau"
