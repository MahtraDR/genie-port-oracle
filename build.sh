#!/bin/sh
# Build both oracles against a Genie4 Remix v4.2.4 checkout:
#   GENIE_REMIX_SRC=/path/to/Genie4_Remix ./build.sh
#     -> flow-oracle/bin/remix/Release/net10.0/genieflow.dll   (script flow: Script.cs, Command.cs, Game.cs, ...)
#     -> oracle/bin/remix/Release/net10.0/genieoracle.dll      (Eval.cs / MathEval.cs / .NET Regex)
# Optional: GENIE_UPSTREAM_SRC=/path/to/Genie4 also builds the upstream (4.5.0.3) trees, context only
# (an upstream build failure is reported but does not fail this script).
# GENIE_TFM=net8.0|all and DOTNET / DOTNET_ROOT are passed through (see flow-oracle/build.sh).
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
[ -n "$GENIE_REMIX_SRC" ] || { echo "build.sh: set GENIE_REMIX_SRC to a Genie4_Remix checkout at tag v4.2.4 (https://github.com/SekmehtDR/Genie4_Remix)" >&2; exit 2; }
GENIE=remix "$ROOT/flow-oracle/build.sh"
GENIE=remix "$ROOT/oracle/build.sh"
if [ -n "$GENIE_UPSTREAM_SRC" ]; then
  GENIE=upstream "$ROOT/flow-oracle/build.sh" || echo "build.sh: upstream genieflow build failed (context only; see flow-oracle/README.md, fidelity gap 13)" >&2
  GENIE=upstream "$ROOT/oracle/build.sh" || echo "build.sh: upstream genieoracle build failed (context only)" >&2
fi
