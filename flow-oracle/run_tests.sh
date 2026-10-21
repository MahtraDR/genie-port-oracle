#!/bin/sh
# Run every tests/*.cmd through genieflow (REAL Genie code) and compare with tests/expected-$GENIE/.
#   ./run_tests.sh                    -> verify against Genie4 Remix v4.2.4 (default)
#   GENIE=upstream ./run_tests.sh     -> verify against Genie4 4.5.0.3
#   ./run_tests.sh --record           -> (re)write tests/expected-$GENIE/<name>.jsonl
#   GENIE_TFM=net8.0 ./run_tests.sh   -> run the legacy .NET 8 build instead of net10.0 (the default,
#                                        the runtime Remix ships on); the goldens are the same files
# Per-test inputs: <name>.args (script args), <name>.trace, <name>.flags (extra genieflow options,
# e.g. --trigger-delivery chunk), <name>.only (a tree name: test runs only under that tree).
# Self-tests use Genie's DEFAULT config (no --config-dir) unless their .flags say otherwise.
# genieflow writes every file into its own per-run temp dir (src/ShimsIO.cs, README "Write
# sandbox"); as a guard this script fails (WROTE) if any file under tests/ other than
# expected-$GENIE/ changed while it ran.
# Paths: genieflow prints absolute paths (the `setup` scriptdir, `config` files, $scriptdir echoes).
# Before comparing or recording, this script rewrites the absolute tests/ path to <TESTS>, so the
# goldens do not depend on where the checkout lives.
G=${GENIE:-remix}
export GENIE=$G
cd "$(dirname "$0")/tests" || exit 2
TESTS_P=$(pwd -P); TESTS_L=$(pwd -L); export TESTS_P TESTS_L
# physical path first: on macOS /tmp/x is /private/tmp/x, and the logical path is a substring of it
norm() { perl -pe 's/\Q$ENV{TESTS_P}\E/<TESTS>/g; s/\Q$ENV{TESTS_L}\E/<TESTS>/g'; }
mkdir -p "expected-$G"
rc=0; nok=0; ndiff=0
marker=$(mktemp "${TMPDIR:-/tmp}/run_tests.XXXXXX") || exit 2
trap 'rm -f "$marker"' EXIT
for c in *.cmd genie-only/*.cmd; do
  case "$(basename "$c")" in _*) continue;; esac
  b=${c%.cmd}; n=$(echo "$b" | tr / _)
  if [ -f "$b.only" ] && [ "$(cat "$b.only")" != "$G" ]; then continue; fi
  args=""; [ -f "$b.args" ] && args=$(cat "$b.args")
  tr=""; [ -f "$b.trace" ] && tr="--trace $b.trace"
  fl=""; [ -f "$b.flags" ] && fl=$(cat "$b.flags")
  out=$(../genieflow "$c" $args $tr $fl --json --scriptdir "$(dirname "$c")" | norm)
  if [ "$1" = "--record" ]; then printf "%s\n" "$out" > "expected-$G/$n.jsonl"; echo "recorded $G/$n"
  elif [ "$out" = "$(cat "expected-$G/$n.jsonl" 2>/dev/null)" ]; then echo "ok   $G/$n"; nok=$((nok+1))
  else echo "DIFF $G/$n"; rc=1; ndiff=$((ndiff+1)); fi
done
wrote=$(find . -newer "$marker" ! -path "./expected-$G/*" ! -path "./expected-$G" ! -path . -print)
if [ -n "$wrote" ]; then echo "WROTE under tests/ (must never happen):"; echo "$wrote"; rc=1; fi
[ "$1" = "--record" ] || echo "run_tests: $nok ok, $ndiff DIFF (GENIE=$G GENIE_TFM=${GENIE_TFM:-net10.0})"
exit $rc
