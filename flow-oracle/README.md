# genieflow: Genie's real script engine, headless, on a virtual clock

`genieflow` is a .NET console app (net10.0 by default, the runtime Remix v4.2.4 ships on; the legacy
net8.0 build stays selectable, see [Selecting the .NET runtime](#selecting-the-net-runtime)). It runs Genie's own `Script.cs`, `Command.cs`, `Game.cs` and
`Globals.cs`, compiled straight from a Genie source tree with no edits to those files. You give it a
`.cmd` script and a game trace. It prints what the script did: sends, echoes, errors, variable sets,
and script start and finish, each stamped with virtual time.

**Parity target: Genie4 Remix v4.2.4** (`$GENIE_REMIX_SRC`, a checkout at tag v4.2.4, the
build the tester runs). That is the default build and the default for every tool here. Upstream Genie4
4.5.0.3 (`$GENIE_UPSTREAM_SRC`) stays available behind `GENIE=upstream` (context only); see
[Selecting the Genie tree](#selecting-the-genie-tree) and
[Remix vs upstream](#remix-vs-upstream-golden-diff).

Script flow (match/matchwait/matchre/waitfor/action/goto/gosub/pause/wait/move/#trigger/RT gating)
used to be checkable only by a human running native Genie. Now it can be differentially tested:
`diff_driver.rb` runs the same script and trace through our Ruby engine and diffs the two event
streams.

The dated work-package log of how this tool grew lives in the lab, not here. The goldens in
`tests/expected-remix/` were recorded with this code against Genie4 Remix v4.2.4; see the top-level
`README.md` for which lab tests are not published and why.


## Build and run

```sh
cd flow-oracle
GENIE_REMIX_SRC=/path/to/Genie4_Remix ./build.sh   # Remix (default), net10.0
GENIE=upstream GENIE_UPSTREAM_SRC=/path/to/Genie4 ./build.sh   # upstream 4.5.0.3
GENIE=all ./build.sh                         # both trees
GENIE_TFM=net8.0 ./build.sh                  # the legacy .NET 8 build (SDK 8); GENIE_TFM=all = both TFMs
GENIE_TFM=net8.0 ./genieflow ...             # run it (every tool below reads GENIE_TFM too)
./genieflow tests/t02_pause_match.cmd --trace tests/t02_pause_match.trace          # human-readable
./genieflow tests/t02_pause_match.cmd --trace tests/t02_pause_match.trace --json   # JSONL
GENIE=upstream ./genieflow ...               # same, against upstream
./genieflow <script.cmd> [args...] [--trace f] [--config-dir dir | --no-config]
            [--vars variables.cfg] [--settings settings.cfg] [--scriptdir dir] [--json]
            [--out file] [--tail ms] [--tick ms] [--maxms ms] [--seed n] [--verbose] [--no-in]
            [--trigger-delivery row|chunk|sync]
./genieflow --loadcheck <file-or-dir>... [--config-dir d | --no-config]   # would Genie even START it?
ruby loadcheck_compare.rb [--config-dir d | --no-config] <file-or-dir>... # ...and do we agree? (exit 1 on a difference)
./run_tests.sh [--record]                    # golden check of tests/*.cmd against tests/expected-$GENIE/
ruby diff_driver.rb --all tests              # Remix vs OUR engine on every self-test
GENIE=upstream ruby diff_driver.rb --all tests
ruby diff_driver.rb <script.cmd> [args] --trace t [--scriptdir d] [--config-dir d|--no-config]
                    [--trigger-delivery m] [--verbose]
ruby capture2trace.rb <genie_capture.log> > x.trace   # replay a captured live session
```

Options:
- `--scriptdir`: where scripts and includes are resolved. It defaults to the script's directory.
- `--config-dir DIR`: load a real Genie `Config` directory the way the client does at startup
  (see [Config directory](#config-directory---config-dir)). Optional corpus default: with
  `GENIEFLOW_CORPUS_DIRS` (`:`-separated directories) and `GENIEFLOW_CORPUS_CONFIG` (a Genie Config
  directory) both set, any script or loadcheck path under one of those directories gets that config
  unless `--config-dir`/`--no-config` is given (diff_driver.rb, loadcheck_compare.rb and
  sweep_batch.rb read the same variables). Unset by default. Self-tests (`tests/`) use Genie's
  built-in defaults.
- `--no-config`: Genie defaults even for a corpus path.
- `--vars` / `--settings`: load one extra `variables.cfg` / `settings.cfg` after the config dir.
- `--trigger-delivery` (Remix only): how game text reaches scripts/#triggers, see
  [Threading model](#threading-model). Default `row`.
- `--tail`: keeps ticking for that many ms after the trace ends (default 2000), or until every
  script finishes.
- `--verbose`: also prints Game-originated variable changes and every game print.
- `--no-in`: hides the echo of fed rows.

## Selecting the Genie tree

| | Remix (default) | upstream |
|---|---|---|
| source | `$GENIE_REMIX_SRC` (v4.2.4) | `$GENIE_UPSTREAM_SRC` (4.5.0.3) |
| select | nothing, or `GENIE=remix` | `GENIE=upstream` |
| build output | `bin/remix/Release/<tfm>/`, `obj/remix/<tfm>/` | `bin/upstream/Release/<tfm>/`, `obj/upstream/<tfm>/` |
| goldens | `tests/expected-remix/` | `tests/expected-upstream/` |
| preprocessor symbol | `GENIE_REMIX` | `GENIE_UPSTREAM` |
| `$version` / connect string | 4.2.4.0 | 4.5.0.3 |
| JavaScript | Jint 4.0.0 from NuGet, as Remix ships it (`Genie4.csproj` `PackageReference Jint 4.0.0`); CLR callbacks (`setVar`, `echo`, ...) work | Genie's `Libs/Jint.dll` (Jint 2); CLR callbacks fail (gap 4) |

Mechanics: `Directory.Build.props` maps the MSBuild property `Genie` (default `remix`) to separate
`BaseIntermediateOutputPath`/`BaseOutputPath`; `genieflow.csproj` picks `GenieSrc` from it (override
with `-p:GenieSrc=...`). `build.sh`, `genieflow`, `run_tests.sh` and `diff_driver.rb` all read
`GENIE`. The Remix build restores Jint 4.0.0 (+ Acornima) from NuGet once (network), then builds
offline.

Remix-only shims (all type-level, no script semantics): `src/ShimsNet10.cs` supplies
`X509CertificateLoader` (.NET 9+ API, used only by the TLS login path, Utility.cs:150 R);
`ShimsIO.cs` gained `File.Replace` (Remix `Utility.SaveFileAtomic`, Utility.cs:583 R). Remix also
links `Utility/LichLauncher.cs` verbatim (Remix Command.cs `#lc` calls it).

## Selecting the .NET runtime

Remix v4.2.4 targets `net10.0-windows` and is published self-contained with the .NET 10 runtime
(Genie4_Remix/Genie4.csproj:3, .github/workflows/release.yml:212-231 R; its regex engine is the
interpreter: `new Regex(p, Multiline [| IgnoreCase])`, Script.cs:359-363, 507-511, 3427 R). The
oracles used to run on .NET 8, whose regex engine has bugs .NET 10 fixed (todo parity N6). Since
2026-10-20 (WPZ):

| | net10.0 (default) | net8.0 (legacy baseline) |
|---|---|---|
| select | nothing, or `GENIE_TFM=net10.0` | `GENIE_TFM=net8.0` |
| built by | SDK 10.0.402 (runtime 10.0.13) | SDK 8.0.424 (runtime 8.0.30), the toolchain of every golden before 2026-10-20 |
| output | `bin/<tree>/Release/net10.0/` | `bin/<tree>/Release/net8.0/` |

Install both SDKs side by side if you want both builds (e.g. the official dotnet-install.sh with
`--channel 10.0` and `--channel 8.0` into one `--install-dir`, then point `DOTNET_ROOT` at it). `build.sh` writes a temporary `global.json` so each TFM is built
by its own SDK major; `Directory.Build.props` maps `GenieTfm` (default net10.0) to `obj/<tree>/<tfm>/`
and the csproj's `TargetFramework`. `./genieflow`, `run_tests.sh`, `diff_driver.rb`,
`loadcheck_compare.rb` and `sweep_batch.rb` all honour `GENIE_TFM` (diff_driver/run_tests through
`./genieflow`). `src/ShimsNet10.cs` (the `X509CertificateLoader` stand-in) now compiles only for net8.0.
The csproj also keeps `bin/**`/`obj/**` out of the default items: otherwise the Remix build's
`Jint.dll` (Jint 4) in another `bin/remix/Release/<tfm>/` became a CandidateAssemblyFiles match that
beat the upstream HintPath (Jint 2) and the upstream build failed (`JintEngine` not found).

**net8 vs net10, 2026-10-20** (engine = worktree HEAD 30082131 v0.24.2, frozen export; every oracle
request diffed row by row with `ORACLE_DUMP`):
- run_tests.sh Remix: 247/247 goldens on both (t111-t119 included); upstream: 80 ok + 167 without an
  upstream golden, same on both. diff_driver.rb --all tests: 241/245 MATCH on both (the 4 ACCEPTED).
  loadcheck_compare.rb: 0 differences in all 27 runs on both. No golden changes.
- genieoracle: every answer identical for all fuzzers at default N and large N (fuzz_oracle 20000,
  fuzz_regex 40000, fuzz_regex_unicode 30000, fuzz_eval_chars 40000, fuzz_eval_grammar 20000),
  corpus_oracle golden (38182 rows, drift 0), the repo eval_golden.tsv fixture (442 rows, drift 0),
  specxcheck, harvest_regex (11136 corpus patterns).
- Corpus regexes x real text (6945 corpus patterns from the WP3 parity scan x 2045 tester log lines
  and x 6036 synthetic subjects, `new Regex(p, Multiline [| IgnoreCase])`): identical on both.
- Only synthetic regex fuzz differs. fuzz_netregex N=30000 (seeds 1, 7): 4 of 58968 rows, all .NET 10
  answers that are not valid regex semantics (net8 and Onigmo agree):
  `(?:[ab]{1,2}|){2}` (and every `X*(?:Y{m,n}|){k}` shape) never matches, even on "" (net8 "b" / "");
  under IgnoreCase a lazy loop over a negated set holding a letter, then `\b`, skips word boundaries:
  `[^a]+?\b` /i on "An arisen" -> "n " (net8 "n"), on "Xn " -> no match (net8 "Xn"). 0 corpus patterns
  have either shape. The WP3 reviewers' AST generator (gen.rb, 4 profiles x 5 seeds x 4000, ~397k
  rows): 161 changed -- 34 .NET 8 IndexOutOfRange/ArgumentOutOfRange faults now answer, 35 rows where
  net10 now agrees with Onigmo (N6-class impossible lookbehind matches gone), 4 rows / 2 patterns with
  a NEW .NET 10 IndexOutOfRangeException, 37 flips of the 2 s match timeout (timing, 26 net8 / 11
  net10), 51 with no Onigmo reference (NetRegex Unsupported; where ours compiles, net10 agrees on
  group 0). The exact bundled runtime of the v4.2.4 release (10.0.x of 2026-09-22) is unknown here; a
  patch-level difference from the lab's 10.0.13 is possible.

## Remix vs upstream (golden diff)

Every self-test, Remix golden vs upstream golden (the `setup` line is ignored). "same" means
byte-identical event streams. Reproduce with `ruby golden_diff.rb` (compares `tests/expected-remix/`
with `tests/expected-upstream/`).

Same in both trees (59 of 79): t01-t12, t14-t31, t35, t36, t37, t48, t53, t54, t57-t67, t69-t79, genie-only t33.
t68 has no upstream golden (remix-only in golden_diff). The 19 below differ (18 differ, t49 runs under Remix only).

| test | upstream | Remix | Remix source reason |
|---|---|---|---|
| t13_loopguard | `[Script error: possible infinite loop detected ("look" sent 10 times in 10s)]` + trace, script killed | all 15 `look` sent, `done 15`, finishes | Remix `Script.SendText` has no send-history guard (Script.cs:4438-4441 R vs Script.cs:4385-4414 U; fields Script.cs:693-697 U deleted) |
| t34_loopguard_paced | killed at 4500 ms (10 same in 10 s) | sends `look` to 7000 ms, finishes | same |
| t38_loopguard_total (new) | killed at 2900 ms (`30 commands sent in 10s`) | sends all 35 | same |
| t39_trigger_input_loop (new) | `ping` sent twice (script + one trigger re-fire), script finishes | `ping`/trigger recurse without bound; **client process dies** (modelled as `genie-crash` + `halted`) | no re-entrancy guard in ParseTriggers (FormMain.cs:4425 R vs 4148-4171 U) and no ParseCommand depth guard (Command.cs:219 R vs 218-224 U); trigger-on-input on by default (Config.cs:19) |
| t40_evaltrigger_chain (new) | second eval #trigger does NOT fire | `tb-fired` | TriggerVariableChanged depth guards deleted (FormMain.cs:4725 R vs 4492 + 4677 U) |
| t51_evaltrigger_lastcommand_loop (new) | eval #trigger on `$lastcommand` fires once (2 `ping` sent) | recursion through Game.SendText -> VariableChanged("lastcommand") (Game.cs:549-551 R): **client process dies** (`genie-crash` after 200) | TriggerVariableChanged depth guards deleted (FormMain.cs:4725 R vs 4492, 4677 U) |
| t41_eval_keywords (new) | `OR` upper-case not translated (`upper-or-false`); `contains(..) && 2 = 1` and `%a && 2 = 5` TRUE | `upper-or-true`; both FALSE | keyword regex `IgnoreCase \| Multiline` (Eval.cs:92 R) vs `IgnoreCase & ...` = None (Eval.cs:83 U); `&&`/`\|\|` reset iArgLeft (Eval.cs:530-546 R, #145) |
| t42_math_divzero (new) | `math x divide 0` -> `∞` (script and `#math`) | value unchanged (`10`) | `if (dNumber != 0)` in Utility.MathCalc (Utility.cs:928 R); `evalmath 10 / 0` is `∞` in both |
| t56_math_mod_divide_zero (new, WPR) | divide by 0 / -N / non-number -> `∞` (`math`, `counter`, `#math`) | value unchanged; mod 0 / -N / non-number -> `NaN` in both trees; `mod` of a huge divisor keeps the dividend (`-95`) in both | Utility.MathCalc clamp (Utility.cs:887-890 R) + `if (dNumber != 0)` (Utility.cs:928 R); C# double `%` (Utility.cs:932-946 R, same upstream) |
| t43_reserved_dirvars (new) | `$scriptdir`/`$logdir`/`$mapdir` undefined; `$gameroomid` = 0 | resolved to Config paths; `$gameroomid` undefined | Globals.cs:859-864, 237-242 R add them; `gameroomid` reserved var removed (Globals.cs:844 U) |
| t44_room_uid (new) | `$gameroomid=12345`, `$uid` undefined | `$uid=12345`, `$gameroomid` undefined | Game.cs:1485-1523 R (RoomNameRegex, Game.cs:2663 R) vs 1410-1442 U |
| t45_unixtime_prompt (new) | `$unixtime` live (u3 = start+6) | frozen at the last prompt (u3 = start+3) | Game.cs:2366-2369 R overwrites the reserved `@unixtime@` (Globals.cs:902 R) with a literal on every prompt |
| t46_var_vs_text_order (new) | `TEXT-ACTION` (10 ms) then `VAR-ACTION` (next tick, 20 ms) | `VAR-ACTION` then `TEXT-ACTION`, both 10 ms | variable changes synchronous (FormMain.cs:5049 R) vs queued to next tick (FormMain.cs:4815-4819, 2885, 7983 U); game text via Channel (FormMain.cs:6596 R) |
| t47_ping (new) | `[Ping]: Connected to game server.` | `Unknown command: #ping` | `#ping` removed (Command.cs:847-855 U; Remix falls to Command.cs:2527 R) |
| t49_waitfor_lastrow_chunk (new, Remix-only) | n/a (upstream is always inline) | with `--trigger-delivery chunk` the `waitfor` resumes at 5030 ms (next chunk) instead of 20 ms | Remix race, see Threading model; t48 is the same script with the default delivery (same in both trees) |
| t50_onerow_stream (new) | `<pushStream id='inv'/>a shiny rock<popStream/>` reaches scripts (matchre ROCK) | text routed to the inv window, scripts never see it (matchre PLAIN) | same-row stream flush (Game.cs:628-660 R) + Room/Inv/Log exclusion (Game.cs:3062-3069 R) |
| t52_stream_routing (new) | the `room` pushStream reaches scripts and #triggers (`trig-room`, `got-room`); talk/spellfront too | talk/spellfront reach both (WindowTarget.Other); the `room` stream reaches neither | same-row stream flush (Game.cs:627-658 R; upstream prints the row's text at row end, after popStream reset the target to Main) + Room/Inv/Log exclusion (Game.cs:3063-3069 R, same code as Game.cs:2924 U); unnamed ids -> Other, parsed (Game.cs:1630-1635 R; `parsegameonly` off by default, Lists/Config.cs:40 R) |
| t55_row_split (new) | the mid-row stream row `PRE <pushStream id='thoughts'/>MID<popStream/> POST` is one line (`trig-whole`, `whole:PRE MID POST`); the roomDesc row splits as in Remix | three lines `PRE `, `MID`, ` POST` (`trig-pre`/`trig-mid`/`trig-post`, `pre:PRE`) | same-row stream flush FlushRowTextTo (Game.cs:628-658, 2941-2956 R; absent upstream); the roomDesc preset printed on its own is in both (Game.cs:689-693 R) |
| genie-only t32_js | Jint 2 CLR delegate fails (`System.Security.Permissions`) | `js setVar("q","hello")` works, `q=hello` | Remix Jint 4 `Engine.SetValue` (Script.cs:695-705 R) |

## Trace language (one directive per line, `#` comments)

| directive | meaning |
|---|---|
| `IN <text>` | One raw game row (XML allowed), fed to the real `Game.ParseGameRow(row + "\r\n")` like a Windows socket row. Consecutive IN/PROMPT/ROOM lines form one socket packet (chunk). |
| `PROMPT [rt]` | Emits `<roundTime value=gt+rt/>` (if rt>0) and then `<prompt time=gt>&gt;</prompt>`, and ends the chunk. Real Game.cs turns this into TriggerPrompt plus SetRoundTime. |
| `ROOM [title]` | Emits room XML (`<component id='room desc'>`), which fires the real `EventTriggerMove`. |
| `FLUSH` | Ends the current chunk: `EventDataRecieveEnd`, then `Script.SetBufferEnd`, then one tick. |
| `TICK [n]` | n UI ticks of 10 ms each. |
| `WAIT <ms>` | Advances virtual time in 10 ms ticks. |
| `EXPECT <text>` or `EXPECT /re/ [maxms]` | Ticks until some script sends a matching command (searches sends not yet consumed; default limit 30000 ms). Emits `expect-ok` or `expect-timeout`. This is what makes a static trace reactive: put it before the game's reply. |
| `VAR name value` | Sets a global `$name` and notifies (FormMain.TriggerVariableChanged). |
| `INPUT text` | User typed `text` (Command.ParseCommand(text, true, true)), e.g. `INPUT #var x 1`. |
| `RUN name args` | Same as `INPUT .name args`. |
| `IDLE [ms]` | Ticks until no script is running (default limit 30 s). |

The trace runs in this order:
1. The entry script is started exactly as typing `.name args` would start it, then one tick runs.
2. The directives run in order.
3. Ticking continues for `--tail` ms.

## Output events (JSONL; `t` = virtual ms)

Each event below is listed with its fields and what it means:
- `send` (`text`, `origin`, `user`): text actually sent to the game: emitted at Game.SendText's socket send (Game.cs:545-552 R), so never for a `mycommandchar` text (`/x`), which Game only echoes (WPF). `origin` is the script name, `"Trigger"`, or `""` for queue/user.
- `queue` (`text`, `delay`, `script`): the script `send` verb put text on CommandQueue.
- `inputbox` (`text`, `origin`): the text contained `@` or `\x`. Genie puts it in the input box and sends nothing (FormMain.cs:4114).
- `echo` (`text`, `script`): output of the script `echo` verb.
- `cmdecho` (`text`, `window`): output of `#echo` (Command.EchoText).
- `print` (`text`, `script`): a Script.PrintText line ("[Script loaded...]", "[Script finished...]", "[Script error: possible infinite loop...]", "Trace follows:").
- `error` (`text`, `script`): a Script.PrintError line ("[Script error in f.cmd(row): ...]").
- `debug` (`text`, `script`): output at debug level.
- `var` (`name`, `value`, `src`): a global variable change notification. `src` is `cmd` for #var/#tvar and similar from scripts or triggers, `trace`, or `game` (game-originated, shown only with `--verbose`).
- `trigger-fire` (`pattern`, `text` or `var`): a global #trigger fired.
- `script-start`, `script-finish`, `script-pause`, `script-resume` (`script`, `args`).
- `prompt-event`, `move-event`, `roundtime-event`: engine signals produced by the real Game.cs.
- `expect-ok`, `expect-timeout`, `end`: driver bookkeeping.
- `host-exception`, `genie-exception`: exceptions Genie surfaces through HandleGenieException or GenieError.
- `setup` (`scriptdir`, `genie` = tree, `delivery`), `config` (files loaded + key settings).
- `genie-crash` (`where`), `halted`: Remix only. Unbounded recursion through a path with no guard in
  Remix (ParseTriggers / TriggerVariableChanged); the real client overflows its stack and the process
  dies. genieflow stops at depth 200, drops every later event and halts the trace.
- `swallowed-fault`: Remix only. A script `put` whose ParseCommand Task faulted; Remix discards the
  Task (FormMain.cs:6823 R) so nothing is shown. Bookkeeping, not client output.

## What is real and what is shimmed

**Real Genie code, linked verbatim from the selected tree** (`<Compile Include>` in `genieflow.csproj`):
- `Script/Script.cs`, `Script/Eval.cs`, `Script/MathEval.cs`, `Script/Trace.cs`
- `Core/Command.cs`, `Core/Game.cs`, `Core/Connection.cs` (compiled; no socket is ever opened), `Core/GenieError.cs`
- `Lists/*.cs`: Aliases, ArrayList, Classes, CollectionList, CommandQueue, Config, Events, Globals, Highlights, Macros, Names, ScriptList, SortedList, VolatileHighlight
- `Utility/Utility.cs`, `Log.cs`, `ColorCode.cs`, `INaturalComparer.cs`, `KeyCode.cs`, `Crypto.cs`, `FileHandler.cs`, `Sound.cs`
- `RegexOptions.cs`, `LocalDirectory.cs`; Remix also `Utility/LichLauncher.cs`
- `Libs/Antlr3.Runtime.dll`, `Libs/Interfaces.dll`: Genie's own binaries, referenced directly.
- JavaScript: upstream `Libs/Jint.dll`; Remix the NuGet Jint 4.0.0 it ships with.

**Shims** (`src/Shims*.cs`): types only. None of them contains script semantics.
- `ShimsWinForms.cs`:
  - `System.Windows.Forms`: `Keys`, `KeysConverter`, `Application`, `Form`.
  - `System.Drawing`: `Font`, `FontStyle`, `FontFamily`, `Image`, `Bitmap`, `GraphicsUnit`. These are display-only. `Color` is the real one from System.Drawing.Primitives.
  - `GeniePlugin.Plugins.IPlugin`/`IHost`: a C# mirror of `Plugin/IPlugin.vb` and `IHost.vb`.
- `ShimsMy.cs`: `My.MyProject.Application.Info`. It supplies the version that ends up in `$version`
  (4.2.4.0 Remix, 4.5.0.3 upstream).
- `ShimsNet10.cs` (Remix): `X509CertificateLoader`.
- `ShimsClock.cs`, the **virtual clock**:
  - `GenieClient.DateTime` wraps `System.DateTime` (implicit conversions both ways) and gets `Now`
    from `VirtualClock`. C# looks up enclosing namespaces before `using System;`, so every unqualified
    `DateTime.Now` in Script.cs, Globals.cs, Events.cs, CommandQueue.cs and Game.cs resolves to it.
    No source edit is involved.
  - `GenieClient.Random` replaces Utility.RandomNumber's `new Random()` with one generator seeded by
    `--seed`.
  - `GenieClient.DateTimeOffset` puts `DateTimeOffset.Now/UtcNow` on the virtual clock too
    (`@unixtime@`, Globals.cs:230; Remix's per-prompt `$unixtime`, Game.cs:2368 R).
- `ShimsIO.cs`: `File`, `Directory`, `FileStream`, `StreamReader`, `StreamWriter`, `FileInfo` and
  `DirectoryInfo` in namespace GenieClient. They shadow System.IO the same way and translate the
  Windows separator `\` to `/`. Genie builds every path as `dir + "\" + file`, e.g. Script.cs:3633.

**Transcribed, not linked**: `src/Host.cs`. `Forms/FormMain.cs` (~9k lines of WinForms) is the glue
that owns the script list and routes events, so each Host method transcribes the cited FormMain
method with only the UI side effects removed. R = Remix FormMain.cs line, U = upstream. Where the
trees differ both bodies are kept under `#if GENIE_REMIX` / `GENIE_UPSTREAM`.

| Host method | R | U | Remix difference implemented |
|---|---|---|---|
| Game/Command wiring | 420-440, 512-558 | 417-434, 512-551 | none for the script path |
| Game_EventTriggerParse | 6592-6596 | 6284-6288 | text goes to the trigger Channel (`m_oTriggerChannel`), drained per `--trigger-delivery`; consumer = StartTriggerConsumer 141-152 |
| ParseTriggers | 4425 | 4146 | re-entrancy guard (U 4148-4171) removed; recursion model cap 200 -> `genie-crash` |
| TriggerAction | 4615 | 4369 | identical |
| ClassCommand_ParseText (#parse) | 4659 | 4413 | identical (synchronous, bBufferWait=false) |
| ClassCommand_EventVariableChanged | 5045 | 4808 | no socket-thread queue: TriggerVariableChanged runs synchronously (5049) |
| DrainPendingVariableChanges | deleted | 2885 | upstream only |
| TriggerVariableChanged | 4725 | 4482 | `InvokeRequired` enqueue (U 4484-4490), depth >= 20 (U 4492) and depth > 1 (U 4677) guards removed; direction early-return kept (R 4793 / U 4563); recursion model cap 200 |
| ClassCommand_SendText | 4391 | 4110 | identical for scripts (Remix only adds m_CommandSent) |
| Script_EventSendText | 6812 | 6503 | ParseCommand Task discarded (6823), no IsFaulted report (U 6514-6516) |
| RunQueueCommand | 3857 | 3576 | identical |
| user input | 4216 | 3935 | identical |
| ClassCommand_RunScript / LoadScript | 4678 / 3401 | 4432 / 3121 | identical (U 3154 per-script GenieError subscription is UI-only) |
| Script_EventPrintText | 5611-5614 | 5393 | Remix delegate has no window target (Script.cs:631 R): debug output goes to the MAIN window; classified by colour RoyalBlue (Script.cs:4420/4424 R) |
| Command_ScriptAbort/Pause/PauseOrResume/Reload/Resume | 5783/5845/5906/5973/6022 | 5561/5623/5684/5751/5800 | identical |
| Command_ScriptDebugLevel / ScriptVariables | 6083 / 5678 | 5861 / 5456 | identical |
| Command_EventClassChange | 7483 | 7163 | identical (highlight toggles dropped; trigger, sub and gag toggles kept -- the sub/gag ones since WP10-r1) |
| Simutronics_EventEndUpdate | 5620 | 5398 | identical |
| Game_EventTriggerPrompt / Move | 6860 / 6889 | 6553 / 6582 | identical |
| Game_EventRoundtime -> SetRoundTime, HasRoundTime | 6725-6731, 6927, 6918 | 6416-6422, 6620, 6611 | identical (synchronous Invoke) |
| TimerBgWorker_Tick | 8313 | 7975 | no DrainPendingVariableChanges (U 7983) |
| TickScripts / AddScripts / RemoveExitedScripts / SetScriptListVariable | 3185 / 3809 / 3229 / 4516 | 2905 / 3528 / 2949 / 4270 | identical |

<a id="threading-model"></a>**Threading model.** Real Genie parses game rows on the socket thread and
ticks scripts on a 10 ms WinForms timer (FormMain.Designer.cs:1409 R / :1361 U). genieflow serializes
both, deterministically. A chunk's rows run in "socket context", then `FLUSH` ends the buffer
(EndUpdate -> Script.SetBufferEnd), then the UI ticks run.

- **Upstream**: game text reaches ParseTriggers inline (FormMain.cs:6284 U). Variable-change
  notifications raised in socket context are queued (FormMain.cs:4815-4819 U) and drained first
  thing in the next tick (FormMain.cs:2885, 7983 U).
- **Remix**: variable changes run TriggerVariableChanged synchronously on the socket thread
  (FormMain.cs:5045-5050 R; the queue and the drain are gone). Game text is written to an unbounded
  `Channel<string>` (FormMain.cs:343, 6596 R) and a single thread-pool consumer calls ParseTriggers
  (FormMain.cs:141-152 R). The consumer and the socket thread race. `--trigger-delivery` picks the
  outcome:
  - `row` (default): the consumer keeps up. The channel is drained after each row has been fully
    parsed (so that row's prompt/roundtime/variable events come first) and before the chunk's
    EndUpdate.
  - `chunk`: the consumer loses. The channel is drained only after EndUpdate has run
    Script.SetBufferEnd. A match then calls SetBufferWait (Script.cs:2098-2104 R) after the buffer
    end, so the script does not resume until the NEXT chunk ends (t49: 5 s late).
  - `sync`: upstream behaviour, for A/B only.
  Real Remix can also drop a line for a script: Script.TriggerParse takes the script lock with
  `Monitor.TryEnter(.., Config.iScriptMatchTimeout)` (Script.cs:1186 R; default 100 ms, the tester's 100)
  instead of 3500 ms, and silently skips the line if a tick holds the lock longer. genieflow ticks
  are instantaneous, so this never happens here.

## Write sandbox

Genie writes files: `#var save` rewrites the `variables.cfg` it loaded (VariableList remembers the
loaded path, Globals.cs:722-797 R), `#save` / `#trigger save` / `#config save` / `#alias save` ...
write `Config.ConfigDir` = `LocalDirectory.Path\Config` (Command.cs:500-634 R), and genieflow roots
`LocalDirectory.Path` at `--scriptdir`. Until 2026-10-20 a corpus sweep therefore wrote into the
corpus (`<corpus>/Config/`) and into the tester's real config dir, and later runs read the
polluted values (since quarantined in the lab). Now:

- **genieflow** creates one temp dir per process (`$TMPDIR/genieflow-<pid>-<guid>`, removed at exit;
  a run that dies of a stack overflow leaves it behind). `--config-dir`, `--vars` and `--settings`
  are loaded from private copies in it (the `config` event still names the original files). Every
  write Genie makes through the IO shims (`src/ShimsIO.cs`) to a path outside the temp dir lands
  in a shadow copy inside it (`<tmp>/shadow/<absolute path>`); reads see the shadow first, so a
  run still reads back what it wrote (`#trigger save` then `#trigger load`), and an original is
  never written, moved, replaced or deleted (a delete hides it for the rest of the run). Parallel
  runs share no writable state.
- **diff_driver.rb** gives our engine a per-run temp copy of the config dir as well, and so does the
  repo's `Flow.run_ours` (rspec ratchet). Since WPZ (v0.25.0) OurRun loads that copy's
  variables.cfg through the production `GlobalStore.new(file:)`, so a `#var save` writes the copy
  (like genieflow's sandboxed --config-dir copy) and never the real dir; `#trigger save` stays
  unmodelled.
- **run_tests.sh** fails with `WROTE` if any file under `tests/` other than `expected-$GENIE/`
  changed during the run.
- **sweep_batch.rb** (the reviewers' batch.rb as a lab tool) runs diff_driver over a script list on
  one trace and exits 3 if the corpus config dir (GENIEFLOW_CORPUS_CONFIG) or any swept script dir changed. Run sweeps
  sequentially.
- **reference/corpus_execute_sweep.rb** loads no config dir and runs no Genie save path at all.

Two consequences to keep in mind (WP7a round-2 parity NB4):

- A write whose parent directory does not exist still succeeds: the shim creates the shadow
  copy's parent dirs. That matches Remix, whose startup creates `Config\`, `Config\Profiles`,
  `Config\Layout`, `Config\PluginKeys`, `Scripts\`, `Logs\` ... under `LocalDirectory.Path`
  (CreateGenieFolders, FormMain.cs:2449-2460 R), so `#save` / `#trigger save` never fail for a
  missing `Config\` there either.
- `--config-dir` is only what genieflow loads at startup. A save or load made by the run itself
  (`#trigger save|load`, `#save`, `#load` ...) uses `Config.ConfigDir` = `<scriptdir>/Config`
  (Command.cs:500-800 R), not the `--config-dir` copy: a script that `#load`s reads
  `<scriptdir>/Config` (through the shadow), whatever `--config-dir` says (variables are the
  exception: `#var save` writes the file VariableList loaded, i.e. the private `--config-dir`
  copy). Pre-existing
  genieflow gap (production Genie has one dir for both); 0 corpus scripts load a config during a
  run, so no golden depends on it.
- sweep_batch.rb gives each script SWEEP_TIMEOUT seconds (default 60) and then kills genieflow's
  whole process group (TERM, then KILL); before 2026-10-20 the dotnet child of a run that never
  ends (ww.cmd) kept running after the Timeout.

## Config directory (`--config-dir`)

`src/ConfigLoad.cs` loads a Genie `Config` directory with Genie's own loaders, in the order Remix
FormMain runs them at startup (FormMain.cs:2295-2343 R; upstream uses the same order):
`settings.cfg` (Config.Load) -> `presets.cfg` -> `variables.cfg` -> `highlights.cfg` -> `names.cfg`
-> `macros.cfg` -> `aliases.cfg` -> `substitutes.cfg` -> `gags.cfg` -> `triggers.cfg` ->
`classes.cfg`. Missing files are skipped, as the loaders themselves do. Config.Load swallows bad lines
per line (Config.cs:547-554 R), so upstream silently ignores Remix-only keys such as
`scriptmatchtimeout`/`historysize`. After loading, `scriptdir` is forced to "" (scripts resolve from
`--scriptdir`) and `autolog` off. Not modelled: the per-character profile reload on connect
(LoadProfileSettings, FormMain.cs:8524 R).

The tester's Config export used in the lab (not published) has settings.cfg, variables.cfg
(858 vars) and aliases.cfg only. Notable: `ignorescriptwarnings False`,
`scripttimeout 5000`, `scriptmatchtimeout 100`, `maxgosubdepth 50`, `triggeroninput True`,
`abortdupescript True`, empty `connectscript`, `monstercountignorelist` set, `scriptchar .`.
`diff_driver.rb` preloads the same `variables.cfg` into OUR engine's global store, but our side
does not load settings.cfg or aliases.cfg (scripttimeout, abortdupescript, ignorescriptwarnings,
aliases), so corpus diffs are NOT fully like with like: the driver prints a WARNING on stderr naming
the ignored files whenever the config dir holds any (frozen fixtures raise instead,
Flow.check_config_dir).

**Loadcheck over a private player corpus (1422 .cmd, ignorescriptwarnings False)**: identical in Remix
and upstream, file for file: 34 refused (26 missing includes in that copy, 3 zero-byte files, 4 prose
notes saved as .cmd, 1 invalid IF) and 6 loaded with duplicate-label warnings. The corpus itself is
not published.

## Known fidelity gaps

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
6. **Config.** Self-tests use Genie defaults; corpus paths can default to a configured config dir (GENIEFLOW_CORPUS_CONFIG; see
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
   `hum2.cmd`, `js_arrays.js`. The tester's `variables.cfg`, `settings.cfg` and `triggers.cfg` are not
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

## How diff_driver.rb models OUR engine

`GENIE=remix` (default) or `upstream` picks the genieflow build. `.flags`/`.only` are honoured by
`--all`. When genieflow would load a config dir (explicit, or the corpus default), the driver loads
the same `variables.cfg` into our engine's global store and the same `triggers.cfg` into its
trigger registry (WP11; a relative `.flags` `--config-dir` resolves against the test dir, as in
run_tests.sh). The lab test t68_cfg_triggers_load (not published: its triggers.cfg quotes a tester script) covers the startup triggers.cfg load.

The our-engine side is NOT in this directory any more (WP0): diff_driver loads
`$LICH_WORKTREE/spec/lib/genie/support/flow_harness.rb` (default: a `lich-5` checkout next to this
repository), the same code that runs the dotnet-free rspec ratchet
`spec/lib/genie/flow_parity_spec.rb` over frozen copies of `tests/` + `tests/expected-remix/`
(`spec/fixtures/genie/flow/`). Change a test here, re-record, then copy it there (the spec header has
the steps). Exception (user decision D9, 2026-10-20): the LAB-ONLY cases t227, t228, t233, t234, t236
and t238-t245 include or contain third-party JavaScript (the GPLv3 js_arrays.js versions --
`js_arrays.js`, `_js_arrays_miner.js`, `_js_arrays_<blob>.js` -- SkillData.cmd's block, uber.cmd's
TEXT_TO_NUMBER block); only their goldens are copied to the repo, whose flow_parity_spec runs the
scripts from here (point `GENIE_LAB_FLOW_TESTS` at this `tests/` directory) and skips them when the
dir is absent. Never copy those scripts or `.js` files into the lich-5 repo. (t238 is not published
here either -- its source is all-rights-reserved -- so the spec keeps skipping it.) The harness header is the authoritative list of modelling assumptions; in short:
- It loads `lib/genie` and runs one Fiber per script on the same 10 ms virtual clock, kept in integer
  milliseconds. (A float clock that added 0.010 per tick drifted: 450 ticks sum to 4.4999..., so every
  `pause 0.5` resumed one tick late. That was N11; t34/t38 now MATCH.)
- Our interpreter compares float deadlines, which can still sit ~1e-15 s past a tick. A timed wait
  with < 1 ms left is treated as expired inside the current tick, as the real port's timed pop would be.
- `IN` delivers an XML-stripped line to every script's input, and to global #triggers. This is the
  Lich glue filter, not Remix routing or Remix's row parser (N19: suppressed streams, rows of a stream
  open across rows held until popStream; N18: entities, dropped `;`, lost `&` tail).
- `PROMPT` and `ROOM` deliver no LINE (Lich's strip_xml drops `<prompt>` and component XML, a Lich
  fact since WP6, lessons-learned "WP6 Lich delivery facts"); their rows feed GameState, whose events
  (SetRoundTime, TriggerPrompt + the prompt text, TriggerMove) reach the scripts through the
  production GameEvents.deliver, as in the glue.
- Roundtime is known at the packet's prompt (Remix's model) and gates the interpreters' RESUMES; no
  send waits it out (LichGamePort has no `waitrt?` since WP6). A wait resumes only at the end of a
  packet: its prompt, or 10 ms with no further row (= the tick after a FLUSH or a chunk-closing
  directive).
- Launches (WP7a, v0.19.0) use the production ScriptLaunch + ScriptList: exactly `<name>.cmd` in
  the case dir (Remix's "File not found" / "Unable to load file" errors), abortdupescript from the
  config dir's settings.cfg (default True), the dupe check over the LISTED scripts. A launched
  script's first run is resumed at once, inside the launcher's resume (the glue's launching script
  waits for it; a #trigger/queued/typed launch does not wait in the glue). A script is listed at the
  end of its own first run and of its launcher's run (the glue's deterministic tick end); until then
  it is frozen and gets no line, `#parse`, change or event, and `#script`/`$scriptlist` do not see it.
- `INPUT` is user typing as Remix Command.ParseCommand(text, true, true) (FormMain.cs:4216 R), run
  through the engine's own production `ParseCommand` (WP4, v0.17.0): `;`/`bug `/`sing ` rows whole,
  the SafeSplit, `-x` quick send, `.name` launches, plain rows ParseGlobalVars'd + SendTextToGame'd,
  each `#` arm expanding `$globals` where Remix does. Aliases are not modelled (the engine owns no
  AliasList). Typed sends are not RT-waited. (The harness's own RAW_INPUT_ARMS approximation is gone.)
- The CommandQueue (WP4): the production `CommandQueue` on the virtual wall clock, drained at the start
  of every tick before the scripts (FormMain.cs:8313-8339 R); RT = `GameState#roundtime?`, $webbed /
  $stunned through the variables.
- Directive clock = genieflow RunTrace's chunk model (src/Program.cs:245-344): IN/PROMPT/ROOM open a
  chunk; PROMPT/FLUSH close it with one tick; every other directive first closes an open chunk (one
  tick only if open); VAR then adds no tick and `TICK n` runs exactly n ticks (TICK 0 = none).
- Trace lines split like genieflow (`kw = l.Split(' ')[0]`, rest after ONE space).
- No game-state model: reserved variables (`$roomname`, `$unixtime`, `$health`, ...) are unresolved
  (game_state nil). t44/t45/t46 diverge partly for that reason (triage in docs/genie-engine/todo.md).
- Errors are recognised by our engine's `[...]` message shapes.
- Not compared: script lifecycle (script-finish / aborted / "[Script finished]"). A script that keeps
  running on one side only shows up through its sends/echoes.
- Known engine gap visible in INPUT and script sends: Remix SendTextToGame strips backslashes
  (Command.cs:2826-2839 R), ours does not (N15, todo.md).

The driver compares six streams: send, echo, error, globalvar, expect-timeout and inputbox. Matching
uses LCS alignment. Aligned send or echo pairs more than 60 ms apart are reported as TIMING; repeated
identical report lines are collapsed (`(xN)`).

WP7a differential (2026-10-20, v0.19.0): **147/163 MATCH vs Remix** (WP6's 139/155 + the new t158-t165:
script-list membership, self-abort, abortdupescript relaunch, launch names, $scriptlist at the tick end,
`#parse` vs an unlisted child; no MATCH -> DIVERGENT).

WP4 differential (2026-10-19, v0.17.0): **114/137 MATCH vs Remix** (WP3b's 99/124 + t12 t36 t37
(G15/G16) - t18 (now G07: it matched only because the unqueued `send` waited out RT) = 101/124, plus the
13 new Remix-recorded cases t127-t139 (ParseCommand split/escapes/quick send/results, CommandQueue timing,
RT/webbed/stunned gates, a tester login trigger, delay parse faults, put fault swallow, #var ParseAllArgs,
separatorchar config, TriggerAction `$n`)).

WP1 differential (2026-10-18): **28/61 MATCH vs Remix**, WPR's 18 plus t01, t09, t15 (G02/G14/G62,
script args + shift) and the new t57_args_parse, t58_args_none, t59_launch_child (+ `_t59_child`),
t60_shift_action and corpus copies t61_corpus_holy (+ a `WAIT 500` trace so Remix's queued last send
drains), t62_corpus_put, t63_corpus_put_wb (the tester's holy.cmd/put.cmd verbatim, default config; not published here).
The our-engine side now tokenizes launches with the production `Lich::Genie::ScriptArgs.parse_launch`.

WPR differential (2026-10-18): **18/54 MATCH vs Remix**, WP0's 14 plus t13 (N01, send-history guard
removed), t41 (N03, keyword case), t42 (N04, divide by 0) and the new t56 (N04/N05, divide/mod by 0).

WP0 differential (2026-10-18, final): **14/53 MATCH vs Remix** (t06 t07 t18 t19 t21 t22 t24 t25 t26 t29
t34 t38 t48 t50). t50 matches since the our-engine side feeds game rows through Lich's real strip_xml;
t52_stream_routing (N19) pins that this is the LICH glue filter, not Remix's stream routing: Remix
parses talk/spellfront (WindowTarget.Other, Game.cs:1630-1635 R) and skips the room stream
(Game.cs:3063-3069 R); Lich SUPPRESSED_STREAMS drops talk/spellfront (Remix parses them) and delivers
room (Remix excludes it); `inv` agrees, and thoughts/familiar/death/logons/combat/percWindow match
(lab probes). t52 is DIVERGENT, pending in the repo. A MATCH also runs a launched
script synchronously (the Genie model), which hides G59 (the Lich glue launches it async).
t53_stream_multirow (N19 multi-row): a stream left open across rows makes Lich's strip carry every
row, plain main rows too, until popStream, so ours sees them late; Remix parses each row on arrival.
t54_entity_glue (N18): Remix ParseGameRow drops a bare `;`, loses a short `&` tail with its CRLF,
turns `&amp;gt;` into `&gt` (Game.cs:756-815 R), blanks `&apos;`, maps `&nbsp;` to a space; Lich
does none of that. t55_row_split (N20): Remix parses one row as several lines, a roomDesc preset
on its own (Game.cs:689-693 R, the real DR room-look shape) and the text before a mid-row stream
change on its own (Game.cs:628-658 R); Lich delivers one joined line. All are pending in the repo
with exact-report pins.
The matching tests' only timing deltas are -10 ms (ours one tick early), inside the 60 ms tolerance,
from two causes: the echo resumes in t07/t48/t50 are G32 (Remix resumes waitfor/matchwait only at
the buffer end, Script.cs:1551, 1600, 2098-2104 R); the `send look` in t18 is G16 (Remix queues the
send, Command.cs:2600-2634 R, and the timer drains the queue on the next tick before TickScripts,
FormMain.cs:8324-8339 R). A launched script runs synchronously on our
side (the Genie model), so G59 (async launch in the Lich glue) is invisible. Unsupported `.flags`
options raise (Flow.parse_flags), as does a `--trigger-delivery` value other than row|chunk|sync;
in a repo fixture (run_ours) a `.flags` `--config-dir` must exist and hold no config file but
variables.cfg (ours models only that; ConfigLoad.cs:62-72 loads 11). diff_driver's explicit
`--config-dir` and its corpus default are not checked. t30_parse was replaced by a two-script `#parse` test (`_t30_waiter.cmd` waits while the
issuer fires `#parse`); it MATCHes since WP2 (v0.13.0). WP2 added t69-t79 (#parse self/trigger/
nested/action-goto, waitfor/match trimming and case, the corpus skd/MC_Pound/sandspit->automapper
excerpts, the .NET-only regex constructs, `/re/i` variants, the stale waitforre flag); the
`#parse` recursion cases where Remix dies are rspec decided fixtures (flow-decided/d3_*).

## Extending

- Add `tests/<name>.cmd` with optional `<name>.trace`, `<name>.args`, `<name>.flags` (extra genieflow
  options) and `<name>.only` (`remix` or `upstream`: run under that tree only). Files starting with
  `_` are helpers or includes and are skipped. Tests that are inherently non-diffable go in
  `tests/genie-only/`.
- Then run `./run_tests.sh --record` and `GENIE=upstream ./run_tests.sh --record`, and
  `ruby diff_driver.rb --all tests`.
- To link more Genie code, add a `<Compile Include>` (conditioned on `$(Genie)` if only one tree has
  the file). If it pulls in a WinForms type, shim the type, not the file.
- To virtualize another clock source, shadow its type in namespace `GenieClient`, as ShimsClock.cs
  does.
