#!/bin/sh
# Build genieflow (Genie's real Script.cs/Command.cs/Game.cs/Globals.cs, headless).
#   GENIE_REMIX_SRC=<Genie4_Remix checkout at v4.2.4> ./build.sh   -> bin/remix/Release/net10.0/
#   GENIE=upstream GENIE_UPSTREAM_SRC=<Genie4 checkout> ./build.sh   -> bin/upstream/Release/<tfm>/ (context only)
#   GENIE=all ./build.sh           -> both trees (needs both source variables)
#   GENIE_TFM=net8.0 ./build.sh    -> the legacy .NET 8 build (needs a .NET 8 SDK as well)
#   GENIE_TFM=all ./build.sh       -> net10.0 and net8.0
# net10.0 (default) is the runtime Remix v4.2.4 ships on (Genie4_Remix/Genie4.csproj net10.0-windows).
# Each TFM is built by its own SDK major: the script writes a temporary global.json next to the
# project for the build and removes it afterwards (do not run two builds of this tree at once).
# The Remix build restores Jint 4.0.0 (the JS engine Remix ships) from NuGet once (network).
# dotnet: $DOTNET if set, else $DOTNET_ROOT/dotnet if present, else `dotnet` on PATH.
set -e
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
if [ -z "$DOTNET" ]; then
  if [ -n "$DOTNET_ROOT" ] && [ -x "$DOTNET_ROOT/dotnet" ]; then DOTNET=$DOTNET_ROOT/dotnet; else DOTNET=dotnet; fi
fi
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" # absolute, so the GENIE/GENIE_TFM=all re-runs work from any cwd
cd "$(dirname "$SELF")"
G=${GENIE:-remix}
T=${GENIE_TFM:-net10.0}
case "$G" in
  all) GENIE=remix "$SELF" "$@"; GENIE=upstream "$SELF" "$@"; exit 0;;
  remix) SRC=$GENIE_REMIX_SRC; VAR=GENIE_REMIX_SRC;;
  upstream) SRC=$GENIE_UPSTREAM_SRC; VAR=GENIE_UPSTREAM_SRC;;
  *) echo "GENIE must be remix|upstream|all (got '$G')" >&2; exit 2;;
esac
case "$T" in
  all) GENIE_TFM=net10.0 "$SELF" "$@"; GENIE_TFM=net8.0 "$SELF" "$@"; exit 0;;
  net10.0) SDK_PIN='{ "sdk": { "version": "10.0.100", "rollForward": "latestFeature", "allowPrerelease": false } }';;
  net8.0) SDK_PIN='{ "sdk": { "version": "8.0.100", "rollForward": "latestFeature", "allowPrerelease": false } }';;
  *) echo "GENIE_TFM must be net10.0|net8.0|all (got '$T')" >&2; exit 2;;
esac
[ -n "$SRC" ] || { echo "build.sh: set $VAR to a Genie source checkout (see README.md)" >&2; exit 2; }
[ -f "$SRC/Script/Script.cs" ] || { echo "build.sh: $VAR=$SRC has no Script/Script.cs" >&2; exit 2; }
SRC=$(cd "$SRC" && pwd)
if [ "$G" = remix ]; then
  tag=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)
  [ "$tag" = v4.2.4 ] || echo "build.sh: WARNING $SRC is not at tag v4.2.4 (got '${tag:-no exact tag}'); the goldens were recorded against v4.2.4" >&2
fi
[ -e global.json ] && { echo "build.sh: global.json already exists here (another build running?)" >&2; exit 2; }
trap 'rm -f global.json' EXIT INT TERM
printf '%s\n' "$SDK_PIN" > global.json
echo "genieflow: GENIE=$G GENIE_TFM=$T src=$SRC (SDK $("$DOTNET" --version))"
"$DOTNET" build genieflow.csproj -c Release -nologo -v q -p:Genie="$G" -p:GenieTfm="$T" -p:GenieSrc="$SRC" "$@"
