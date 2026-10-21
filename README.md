# Genie4 Remix oracle for the lich-5 Genie engine

This repository holds the verification tooling behind the Genie `.cmd` engine proposed for lich-5 in
[elanthia-online/lich-5#1813](https://github.com/elanthia-online/lich-5/pull/1813). With it you
can check the PR's parity claims yourself, against the real Genie client code rather than our
reading of it.

The parity target is **Genie4 Remix v4.2.4**
([SekmehtDR/Genie4_Remix](https://github.com/SekmehtDR/Genie4_Remix), tag `v4.2.4`). The
oracles are not a re-implementation of Genie. They compile Remix's own C# source files, unedited,
into small headless .NET console programs and run scripts through them on a virtual clock:

| oracle | what it runs | Remix files compiled in (verbatim, from your checkout) |
|---|---|---|
| `flow-oracle/` (**genieflow**) | whole scripts against a scripted game stream: match/matchre/matchwait, waitfor/waitforre, action, goto/gosub, pause/wait/move, #trigger, roundtime gating, #commands, script lists, JavaScript blocks | `Script/Script.cs`, `Eval.cs`, `MathEval.cs`, `Trace.cs`; `Core/Command.cs`, `Game.cs`, `Connection.cs`, `GenieError.cs`; `Lists/*.cs` (incl. `Globals.cs`); `Utility/Utility.cs`, `Log.cs`, `ColorCode.cs`, `INaturalComparer.cs`, `KeyCode.cs`, `Crypto.cs`, `FileHandler.cs`, `Sound.cs`, `LichLauncher.cs`; `RegexOptions.cs`, `LocalDirectory.cs`; Remix's `Libs/Antlr3.Runtime.dll` + `Libs/Interfaces.dll`; Jint 4.0.0 from NuGet (the version Remix ships) |
| `oracle/` (**genieoracle**) | single expressions: `Eval`, `MathEval`, argument parsing, numeric conversions, .NET regex validity and captures | `Script/Eval.cs`, `Script/MathEval.cs`, `Lists/ArrayList.cs`, `RegexOptions.cs` |

The Ruby drivers then run the same input through the lich-5 engine (loaded from a lich-5 checkout
you point them at) and diff the two outputs.

## What is real and what is shimmed

- **Real Remix code:** every file in the table above, compiled from your Genie4_Remix checkout.
  Nothing in this repository is a copy of a Remix source file.
- **Shims, types only (`flow-oracle/src/Shims*.cs`, `oracle/Shims.cs`):** stand-ins for the WinForms /
  System.Drawing / plugin types those files mention (`Keys`, `Form`, `Font`, `IPlugin`, ...), the
  `My.Application.Info` version (4.2.4.0), a virtual clock (`DateTime.Now`, `DateTimeOffset.Now` and
  `Random` are shadowed in namespace `GenieClient`, so Remix's unqualified calls resolve to them
  without a source edit), and file-system classes that turn Windows `\` paths into `/` and sandbox
  every write into a per-run temp dir. None of them contains script semantics.
- **Transcribed, not linked: `flow-oracle/src/Host.cs`.** Remix's `Forms/FormMain.cs` (~9k lines of
  WinForms) is the glue that owns the script list and routes game text, variable changes, triggers
  and the command queue. Host.cs transcribes each FormMain method genieflow needs, with only the UI
  side effects removed, and cites the FormMain line for each one (`R:<line>`). This is the one
  place where a transcription slip could hide; audit it against the cited lines when a result looks
  surprising. The full table of transcribed methods is in `flow-oracle/README.md` ("What is real and
  what is shimmed").

## Prerequisites

- **.NET 10 SDK** (`dotnet` on PATH, or set `DOTNET_ROOT` / `DOTNET`). Remix v4.2.4 targets
  `net10.0-windows`; the oracles target `net10.0` and build on macOS, Linux and Windows.
  Optional: a .NET 8 SDK as well, for the legacy `GENIE_TFM=net8.0` baseline builds.
- **A Genie4_Remix checkout at tag v4.2.4:**
  `git clone --branch v4.2.4 https://github.com/SekmehtDR/Genie4_Remix.git`
- **Ruby + Bundler and a lich-5 checkout of the PR branch** (the branch of #1813), with
  `bundle install` done in it. The drivers load `lib/genie` and the shared flow harness
  `spec/lib/genie/support/flow_harness.rb` from that checkout.
- `perl` (used by `run_tests.sh` to normalize paths; standard on macOS and Linux) and a POSIX `sh`.
- Network access once, for the NuGet restore of Jint 4.0.0.

## Environment variables

| variable | used by | meaning |
|---|---|---|
| `GENIE_REMIX_SRC` | `build.sh` | path to the Genie4_Remix checkout (v4.2.4). Required. |
| `GENIE_UPSTREAM_SRC` | `build.sh` | optional: path to an upstream [GenieClient/Genie4](https://github.com/GenieClient/Genie4) 4.5.0.3 checkout, for the context-only `GENIE=upstream` builds |
| `LICH_WORKTREE` | all Ruby drivers | path to the lich-5 checkout under test. Default: a `lich-5` directory next to this repository's checkout |
| `GENIE` | all tools | `remix` (default) or `upstream` |
| `GENIE_TFM` | all tools | `net10.0` (default, the runtime Remix ships on) or `net8.0` (legacy baseline) |
| `DOTNET`, `DOTNET_ROOT` | all tools | which `dotnet` to run (default: `$DOTNET_ROOT/dotnet` if present, else `dotnet` on PATH) |
| `CORPUS_DIR` | `reference/corpus_*.rb`, `harvest_regex.rb` | directories of Genie scripts to sweep (`label=dir` or `dir`, `:`-separated). See "What needs the private corpus" |
| `GENIEFLOW_CORPUS_DIRS`, `GENIEFLOW_CORPUS_CONFIG` | genieflow, `diff_driver.rb`, `loadcheck_compare.rb`, `sweep_batch.rb` | optional: scripts under those dirs load that Genie `Config` dir by default (unset: Genie's built-in defaults) |

## Build

```sh
GENIE_REMIX_SRC=/path/to/Genie4_Remix ./build.sh
```

This builds `flow-oracle/bin/remix/Release/net10.0/genieflow.dll` and
`oracle/bin/remix/Release/net10.0/genieoracle.dll`. Each sub-directory also has its own `build.sh`
(`GENIE=remix|upstream|all`, `GENIE_TFM=net10.0|net8.0|all`). The build warns if the checkout is not
at tag `v4.2.4`.

## Run

### 1. The goldens: does genieflow still reproduce Remix?

```sh
flow-oracle/run_tests.sh
```

Runs every `flow-oracle/tests/*.cmd` (with its `.trace` / `.args` / `.flags`) through genieflow and
compares the JSONL event stream byte for byte with `tests/expected-remix/<name>.jsonl`. Absolute
paths in the output are rewritten to `<TESTS>` first, so the goldens do not depend on where you
cloned. The script also fails if any run wrote a file under `tests/`.

### 2. The differential: does the lich-5 engine do what Remix does?

```sh
cd flow-oracle
LICH_WORKTREE=/path/to/lich-5 ruby diff_driver.rb --all tests
```

Runs each test through genieflow AND through the lich-5 engine (headless, same virtual clock, via
the PR's own `spec/lib/genie/support/flow_harness.rb`) and compares six event streams: send, echo,
error, global variable set, expect-timeout and input-box. A report block per test ends in `MATCH`
or `DIVERGENT`; the summary goes to stderr. Single script:
`ruby diff_driver.rb <script.cmd> [args] --trace <file> [--verbose]`.

The four DIVERGENT tests are decided, documented divergences, pending in the PR's rspec ratchet
(`spec/lib/genie/flow_parity_spec.rb`), so `diff_driver.rb --all` exits 1 by design:

| test | why |
|---|---|
| t39_trigger_input_loop | Remix recurses through trigger-on-input until the client process dies; the lich-5 engine caps dispatch depth at 20 (decision D3) |
| t43_reserved_dirvars | `$scriptdir` / `$logdir` / `$mapdir` resolve to the lich-5 engine's own directories, not Remix's Config paths (D6) |
| t49_waitfor_lastrow_chunk | models one extreme of a Remix thread race (trigger Channel vs socket thread); not emulated (D5) |
| t51_evaltrigger_lastcommand_loop | Remix recursion through `$lastcommand` kills the client; capped like t39 (D3) |

### 3. The PR's dotnet-free rspec ratchet, with the lab-only cases

The PR freezes copies of most of these tests and goldens in `spec/fixtures/genie/flow/` and runs
them without dotnet. Thirteen cases contain third-party JavaScript (twelve from the GPL-3.0
DR-Genie-Scripts, one from ubercombat) that cannot go into the BSD-licensed lich-5 repo, so the spec
loads those scripts from a lab directory and skips them when it is absent. Point it here:

```sh
cd /path/to/lich-5
GENIE_LAB_FLOW_TESTS=/path/to/this-repo/flow-oracle/tests bundle exec rspec spec/lib/genie/flow_parity_spec.rb
```

12 of the 13 then run; t238 stays skipped (its source is all-rights-reserved and is not published
here either).

### 4. Expression oracle (genieoracle) and the fuzzers

```sh
export LICH_WORKTREE=/path/to/lich-5 BUNDLE_GEMFILE=/path/to/lich-5/Gemfile
bundle exec ruby reference/fuzz_oracle.rb [N] [seed]        # Eval/MathEval: flat AND/OR/NOT, functions, comparisons
bundle exec ruby reference/fuzz_eval_grammar.rb             # grammar-driven Eval; default run gated by exact accepted keys
bundle exec ruby reference/fuzz_eval_chars.rb [N] [seed]    # character-level Eval/MathEval inputs, incl. non-ASCII
bundle exec ruby reference/fuzz_format.rb                   # likewise fuzz_eval, fuzz_parseargs, fuzz_numeric, fuzz_vb_toint
bundle exec ruby reference/fuzz_regex.rb                    # likewise fuzz_regex_unicode, fuzz_netregex: .NET regex vs the engine's NetRegex
bundle exec ruby reference/sim_compare.rb                   # 19 hand-written scenarios
bundle exec ruby reference/property_invariants.rb [N]       # engine invariants (no dotnet)
bundle exec ruby reference/specxcheck.rb                    # every literal in the engine's eval/math specs vs the oracle
bundle exec ruby reference/curate_oracle_golden.rb --check-fixture   # re-ask Remix for every row of the PR's eval_golden.tsv
dotnet oracle/bin/remix/Release/net10.0/genieoracle.dll evalbool '1 = 1 AND "a" = "a"'   # direct use
```

Each fuzzer exits 1 on a diff not explained by `reference/fuzz_allowlist.tsv` (fuzzer, tree, mode,
input regex, Genie-output regex, finding id). `specxcheck.rb` is expected to exit 1 on the two known
G54 spec literals (`\w+(?<=a+)y`, a .NET-only variable-length lookbehind).

### Other tools

- `flow-oracle/loadcheck_compare.rb [--config-dir d | --no-config] <file-or-dir>...`: would Remix
  even start each script (load errors and warnings), versus the engine's lexer.
- `flow-oracle/sweep_batch.rb <trace> <outfile> <script.cmd>... | @listfile`: diff_driver over many
  scripts on one trace (per-script timeout, process-group kill, write-hygiene check).
- `reference/genie_capture.lic` (a Lich script a tester runs while playing under native Genie) ->
  `flow-oracle/capture2trace.rb <log> > x.trace` -> genieflow / diff_driver: replay a captured live
  session.
- `flow-oracle/golden_diff.rb`: Remix goldens vs upstream goldens.
- `reference/gen_zone_names.rb <Genie-Maps> <out.rb>`: regenerates the PR's `lib/genie/zone_names.rb`
  from a [GenieClient/Maps](https://github.com/GenieClient/Maps) checkout.

The trace language, the output event vocabulary, the threading model, the write sandbox, the
`--config-dir` loader and the full list of how diff_driver models the lich-5 side are documented in
`flow-oracle/README.md`.

## Results at the time of publication

Verified on 2026-10-22 from a clean copy of this tree: Genie4_Remix at `v4.2.4`, .NET SDK 10.0.402
(runtime 10.0.13), macOS, lich-5 at the PR branch (commit `8c2697ca`):

| check | result |
|---|---|
| `flow-oracle/run_tests.sh` | 238 ok, 0 DIFF |
| `diff_driver.rb --all tests` | 232 of 236 MATCH; DIVERGENT: t39, t43, t49, t51 (the decided divergences above) |
| `flow_parity_spec.rb` with `GENIE_LAB_FLOW_TESTS` pointing here | 264 examples, 0 failures, 5 pending (the 4 above + t238 skipped) |
| fuzzers (`fuzz_oracle 2000 5`, `fuzz_eval_grammar`, `fuzz_format`, `fuzz_eval`, `fuzz_parseargs`, `fuzz_numeric`, `fuzz_vb_toint`, `fuzz_regex`, `fuzz_eval_chars`, `fuzz_netregex`) | 0 unexplained diffs; `fuzz_regex_unicode`: only the 944 allowlisted G54 rows |
| `sim_compare.rb` / `property_invariants.rb 2000` / `curate_oracle_golden.rb --check-fixture` | 19/19 / all invariants hold / 442 rows, drift 0 |
| `specxcheck.rb` | exits 1 on the 2 known G54 literals (expected) |
| `loadcheck_compare.rb --no-config flow-oracle/tests` | 273 files, 0 differences |
| `GENIE=upstream flow-oracle/run_tests.sh` (Genie4 at tag 4.5.0.3) | 72 ok; the other 165 tests have no upstream golden |

The lab, which also has the unpublished tests listed below, had 254 goldens ok and 248 of 252 MATCH
(same four DIVERGENT).

## What needs the private corpus (and cannot be reproduced from this repository)

The PR's headline corpus numbers were measured on about 1,500 real Genie scripts: one DragonRealms
player's (the beta tester's) private script collection of 1,422 files, plus the ubercombat,
Mastercraft and DR-Genie-Scripts collections. The tester's scripts are not ours to publish, and
ubercombat and Mastercraft carry no license, so **none of the corpus is in this repository**. These
results therefore need the corpus and cannot be re-run from here:

- **Full-corpus flow sweep: 1502/1502 MATCH** (`flow-oracle/sweep_batch.rb` over every corpus script
  on a trace converted from one captured live session with `capture2trace.rb`). The capture is
  the tester's real game session (character, room, other players' names), so neither it nor the
  trace is published either.
- **Corpus execute sweep** (`reference/corpus_execute_sweep.rb`: 1499 scripts run headless, 0
  exceptions) and the compile sweep (`reference/corpus_sweep.rb`).
- **Corpus expression golden** (`reference/corpus_oracle.rb`: about 38,000 conditions, evals and
  regexes harvested from the corpus and answered by genieoracle; NOT published, because each row
  quotes corpus text) and `reference/harvest_regex.rb` (about 11,000 corpus regexes: does the
  engine's NetRegex compile exactly what .NET compiles).
- **`loadcheck_compare.rb` over the corpus** (0 differences in 27 runs: 9 directories x 3 settings).

The tools are included, so anyone with their own Genie scripts can run them:
`CORPUS_DIR=mine=/path/to/scripts bundle exec ruby reference/corpus_sweep.rb`, and so on.
`corpus_oracle.rb --record` builds a golden from your corpus (then `--accept` freezes the known
differences); `sweep_batch.rb` needs a trace (hand-written, or `capture2trace.rb` on a
`genie_capture.lic` log).

## Lab tests that are not published

The lab suite has 254 genieflow goldens; 238 are here. The other 16 contain someone else's
script text or the tester's live data:

| test(s) | reason |
|---|---|
| t61_corpus_holy, t62_corpus_put, t63_corpus_put_wb, t68_cfg_triggers_load, t74_corpus_skd_look, t77_net_regex, t217_trigger_listing | verbatim (t68: near-verbatim trigger definitions) lines from the tester's private scripts (t61 also names his character) |
| t86_room_components, t87_hands_prompt_rt | rows taken from the tester's captured live session (his character name, another player's name) |
| t238_js_uber_text_to_number | verbatim ubercombat code (all rights reserved) |
| t55_row_split, t75_corpus_mc_pound, t76_corpus_automapper_move (+ `_t76_sandspit.cmd`), t110_corpus_automapper_actions, t140_echo_hex_colour, t148_corpus_automapper_waiteval_depth | verbatim lines from public scripts that carry no license (Mastercraft; automapper.cmd / sandspit.cmd from GenieClient/Maps), or a row shape from the captured session (t55) |

## Known fidelity gaps

Copied from `flow-oracle/README.md`:

1. **FormMain is transcribed, not linked.** A transcription slip is possible, so audit Host.cs
   against the cited lines when a result looks surprising. These are absent: plugins
   (`SafeParsePluginInput/Text` treated as identity; a `mycommandchar` `/x` text, which Remix hands
   to plugins, therefore only echoes), display verbs (`#beep`, `#play`, `#layout`, `#flash`, ... do
   nothing headless; the repo covers them with router specs), the AutoMapper (`#goto`/`#mapper` produce a
   `mapper` event, and mapper-driven `$roomid` is never updated), and the UI parts (bars, icons,
   highlight display). The gag/substitute lists are real (Globals.GagList / SubstituteList): they
   decide what PrintTextToWindow prints and so m_bLastRowWasPrompt, and since WP10-r1 (parity 8a)
   Command_EventClassChange toggles them with the triggers (FormMain.cs:7510-7514 R; golden
   t226_gag_sub_class -- before the fix a `#class x off` left a class-x gag hiding lines).
2. **Timer granularity.** The tick is 10 ms (the Designer value). Real WinForms timers on Windows
   fire every ~15.6 ms, and the socket thread runs concurrently with the timer. genieflow never
   interleaves a tick inside a chunk.
3. **NewLine.** `Environment.NewLine` is `\n` on macOS but `\r\n` on Windows. Rows are fed with
   `\r\n` (the Windows socket path), so `Game.cs` comparisons such as `== "\r\n"` behave the same.
   Strings Genie builds with `Environment.NewLine` end in `\n`; genieflow strips that.
4. **JavaScript.** Remix: real Jint 4.0.0, CLR callbacks work (t32). Upstream: pure Jint expressions
   work, but Jint 2 calls into CLR delegates (`setVar/getVar/echo/put`, i.e. all of js_arrays.js) fail
   because `System.Security.Permissions` is missing.
5. **Wall clock.** `DateTime` and `DateTimeOffset` are virtual. The VB `DateAndTime.Now` in
   socket-error timestamps is not (never reached).
6. **Config.** Self-tests use Genie defaults; corpus paths default to the tester's config dir (see
   above). `$connected` is forced to 1, as in a live session; Script.SetBufferWait depends on it.
6a. **Remix races.** The trigger Channel race and the 100 ms script-lock drop are modelled only as
   the selectable `row`/`chunk` extremes (see Threading model).
6b. **Remix crashes.** Unbounded recursion is cut at depth 200 and reported as `genie-crash`; the real
   client dies with a StackOverflowException.
6c. **GenieError recursion (WP3b-r1 parity 4).** Game's Globals setter subscribes
   `Game.HandleGenieException` to `GenieError.EventGenieError` (Game.cs:150-161 R), and that handler
   calls `GenieError.Error` again (Game.cs:3291-3294 R), so ANY `GenieError.Error` -- e.g. the
   "Collection was modified" InvalidOperationException of an `action remove` inside an eval-action
   pass (probe WP3b-r1-parity q15b) -- recurses until genieflow dies with "Stack overflow." (no
   JSONL, diff_driver raises). The same subscription exists in the real client (FormMain.cs:30 R
   constructs `new Genie.Game(ref _m_oGlobals)`), so this may be real Remix behaviour rather than a
   host-wiring artefact; unverified on a live client. Treat such a probe as "Remix dies here", not as
   a golden, and do not record it.
7. **Trace sugar.** `PROMPT`/`ROOM` generate minimal DR XML. For real streams, use `capture2trace.rb`
   on a `genie_capture.lic` log. It reproduces Connection.ParseData row splitting, and each captured
   receive ends with FLUSH.
8. **Non-reactive replay.** A captured stream does not react to what the replayed script sends. Use
   EXPECT in hand-written traces.
9. **Corpus gaps.** These files are missing from the corpus copy (seen in loadcheck "File not
   found"): `commonsingleweap.cmd` (needed by a tester's combat script), `commoncombatd/l.cmd`, `commonmagic(d).cmd`,
   `hum2.cmd`, `js_arrays.js`. the tester's `variables.cfg`, `settings.cfg` and `triggers.cfg` are not
   available either. Without them a replay of his scripts takes the "undefined `$var`" branches.

10. **`#log >file` crashes the Host (WP6-r2 parity NB6).** genieflow dies with a stack overflow on a
   script that runs `#log >file` (a corpus speedtest script); treat such a run as "no golden".
11. **`#script list/vars/trace` output is not modelled (WP6-r2 parity NB7).** The Host's `#script`
   handling covers pause/resume/abort; the listing/variable/trace output Remix prints is absent.
12. **Default-layout window fallback (WP6-r2 parity NB1).** The Host treats only `main` as the main
   window. In Remix's default layout (LayoutBasic, FormMain.cs:3144-3175 R) closed combat/debug/
   portrait windows fall back to main (FindIfClosed, FormMain.cs:5380-5389 R), so their text also
   clears m_bLastRowWasPrompt there; goldens model a layout where those windows are open.
13. **Lab notes from the WP10-r1 parity review (not fixed; lab probes).**
   (a) No `Cmd.EventChangeIcon` subscriber: Remix subscribes Command_ChangeIcon (FormMain.cs:505 R),
   genieflow does not, so an `#icon` row behaves differently from the real client (the reviewer's
   patched copy added a no-op subscriber). (b) ShimsIO's `File.Exists("")` throws where .NET returns
   false. (c) Our flow harness builds its Lists with `writable: false`, so no `#save`/`#load`
   round-trip of a list is compared (genieflow writes into its per-run sandbox). (d) A typed
   `#var $x ...` projects the key differently in genieflow's typed path (recorded, not traced).
   (e) Fuzz cases that reach the D3 depth-20 cap (decided divergence) show as diffs; triage them as
   D3, not as defects. The upstream (4.5.0.3) build currently fails on Genie4's Script.cs
   `JintEngine` (CS0246) -- pre-existing, unrelated to the Remix build.


## Upstream Genie4 (context only)

`GENIE=upstream` builds the same oracles from upstream Genie4 4.5.0.3 (`GENIE_UPSTREAM_SRC`, a
[GenieClient/Genie4](https://github.com/GenieClient/Genie4) checkout) for comparison only: the parity
target is Remix. `tests/expected-upstream/` holds upstream goldens for the 72 older tests; the newer
tests have none. Verified 2026-10-22 against Genie4 at tag 4.5.0.3: both upstream builds succeed
(the `JintEngine` build failure in gap 13 above no longer reproduces), and
`GENIE=upstream flow-oracle/run_tests.sh` gives 72 ok plus 165 DIFF, which are exactly the tests
without an upstream golden. `flow-oracle/golden_diff.rb` lists where the two trees differ.

## Third-party content in this repository

- `flow-oracle/tests/js_arrays.js`, `_js_arrays_miner.js` and `_js_arrays_<commit>.js` (five
  historical versions) are verbatim copies of the `js_arrays.js` library from DR-Genie-Scripts
  (`JS_Arrays/`, `Miner/`, `mm_train/` and their git history), GPL-3.0. Tests t227, t228, t234,
  t236 and t239-t245 include them.
- `t118_corpus_hunt309_varblock.cmd` and `t119_corpus_hunt_appraise_matchre.cmd` quote
  DR-Genie-Scripts `GenieHunter/hunt.cmd` (lines 256-291, 309, 4071-4073, 4253) verbatim;
  `t233_js_skilldata.cmd` quotes the `<% %>` block of DR-Genie-Scripts `SkillData.cmd`. GPL-3.0.
- Every other test script and trace was written for this suite. A few contain one generic command
  line that also appears in the tester's scripts (`put #script abort all`, `put #class harness on`,
  `put #var invisible 0`, `put #config lichport 11024`, ...).
- No Genie4_Remix or Genie4 source file is included; the build compiles them from your checkout.

## License

GPL-3.0 (see `LICENSE`, the same text as Genie4_Remix's). genieflow and genieoracle are built by
compiling GPL-3.0 Genie4_Remix source files into the same assembly as this repository's code, and
`flow-oracle/src/Host.cs` is a transcription of methods of Remix's `Forms/FormMain.cs`, so both
are derivative works of Genie4_Remix. The test suite also includes GPL-3.0 files from
DR-Genie-Scripts. The lich-5 engine under test (BSD-3-Clause) is not included: the Ruby drivers
load it at run time from your separate lich-5 checkout.
