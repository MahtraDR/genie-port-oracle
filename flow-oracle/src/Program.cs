// genieflow -- run a .cmd through Genie4's REAL Script/Command/Game/Globals against a
// scripted game trace, on a virtual clock, and print the resulting event stream.
//
//   genieflow <script.cmd> [args...] --trace <file> [--config-dir dir | --no-config]
//             [--vars variables.cfg] [--settings settings.cfg] [--scriptdir dir] [--json]
//             [--out file] [--tail ms] [--verbose] [--no-in] [--tick ms] [--maxms ms]
//             [--trigger-delivery row|chunk|sync]
//
// See README.md for the trace language and the event vocabulary.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using GenieClient;

namespace GenieFlow
{
    public sealed class EventSink
    {
        public readonly List<Dictionary<string, object>> Events = new List<Dictionary<string, object>>();
        private readonly TextWriter w;
        private readonly bool json;
        public EventSink(TextWriter writer, bool asJson) { w = writer; json = asJson; }

        // Set when the modelled client process has died (Host.Crash). Everything the dying stack
        // would still do is dropped; only driver bookkeeping is written.
        public bool Frozen;

        public void Emit(string ev, params (string k, object v)[] kv)
        {
            if (Frozen && ev != "halted" && ev != "end" && ev != "driver-exception") return;
            var d = new Dictionary<string, object> { ["t"] = Math.Round(VirtualClock.ElapsedMs, 3), ["ev"] = ev };
            foreach (var (k, v) in kv) d[k] = v;
            Events.Add(d);
            if (json) w.WriteLine(ToJson(d));
            else
            {
                var rest = string.Join(" ", kv.Select(p => p.k + "=" + Quote(p.v)));
                w.WriteLine($"{VirtualClock.ElapsedMs,9:0}ms {ev,-16} {rest}");
            }
            w.Flush();
        }

        private static string Quote(object v) => v is string s ? "\"" + s.Replace("\r", "\\r").Replace("\n", "\\n") + "\"" : Convert.ToString(v, CultureInfo.InvariantCulture) ?? "null";

        public static string ToJson(Dictionary<string, object> d)
        {
            var sb = new StringBuilder("{");
            bool first = true;
            foreach (var kv in d)
            {
                if (!first) sb.Append(',');
                first = false;
                sb.Append(Str(kv.Key)).Append(':').Append(Val(kv.Value));
            }
            return sb.Append('}').ToString();
        }

        private static string Val(object v)
        {
            switch (v)
            {
                case null: return "null";
                case bool b: return b ? "true" : "false";
                case string s: return Str(s);
                case int i: return i.ToString(CultureInfo.InvariantCulture);
                case long l: return l.ToString(CultureInfo.InvariantCulture);
                case double x: return x.ToString("R", CultureInfo.InvariantCulture);
                default: return Str(Convert.ToString(v, CultureInfo.InvariantCulture));
            }
        }

        private static string Str(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c > 0x7e) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }
    }

    internal static class Program
    {
        private static int Main(string[] argv)
        {
            System.Threading.Thread.CurrentThread.CurrentCulture = new CultureInfo("en-US");
            System.Threading.Thread.CurrentThread.CurrentUICulture = new CultureInfo("en-US");
            // Every file Genie writes goes to this process's own temp dir (ShimsIO.cs header).
            GenieClient.Sandbox.Init();

            string script = null, trace = null, vars = null, settings = null, scriptDir = null, outFile = null, configDir = null, delivery = null;
            bool json = false, verbose = false, traceIn = true, noConfig = false;
            double tailMs = 2000, tickMs = 10, maxMs = 600000;
            var args = new List<string>();
            for (int i = 0; i < argv.Length; i++)
            {
                string a = argv[i];
                switch (a)
                {
                    case "--trace": trace = argv[++i]; break;
                    case "--vars": vars = argv[++i]; break;
                    case "--settings": settings = argv[++i]; break;
                    case "--config-dir": configDir = argv[++i]; break;
                    case "--no-config": noConfig = true; break;
                    case "--trigger-delivery": delivery = argv[++i]; break;
                    case "--scriptdir": scriptDir = argv[++i]; break;
                    case "--out": outFile = argv[++i]; break;
                    case "--json": json = true; break;
                    case "--verbose": verbose = true; break;
                    case "--no-in": traceIn = false; break;
                    case "--tail": tailMs = double.Parse(argv[++i], CultureInfo.InvariantCulture); break;
                    case "--tick": tickMs = double.Parse(argv[++i], CultureInfo.InvariantCulture); break;
                    case "--maxms": maxMs = double.Parse(argv[++i], CultureInfo.InvariantCulture); break;
                    case "--seed": GenieClient.Random.Shared = new System.Random(int.Parse(argv[++i])); break;
                    default:
                        if (script == null) script = a; else args.Add(a);
                        break;
                }
            }
            if (script == "--loadcheck")
            {
                if (configDir == null && !noConfig && args.Any(ConfigDefaults.IsCorpusPath)) configDir = ConfigDefaults.CorpusConfigDir;
                return LoadCheck.Run(args, noConfig ? null : configDir);
            }
            if (script == null)
            {
                Console.Error.WriteLine("usage: genieflow <script.cmd> [args...] [--trace file] [--vars variables.cfg] [--settings settings.cfg] [--scriptdir dir] [--json] [--out file] [--tail ms] [--verbose] [--no-in]");
                return 2;
            }

            TextWriter w = outFile != null ? new System.IO.StreamWriter(outFile, false, new UTF8Encoding(false)) : Console.Out;
            var sink = new EventSink(w, json);
            var runner = new Runner(sink, tickMs, maxMs) { Verbose = verbose };
            try
            {
                if (configDir == null && !noConfig && ConfigDefaults.IsCorpusPath(script)) configDir = ConfigDefaults.CorpusConfigDir;
                runner.Setup(script, scriptDir, noConfig ? null : configDir, vars, settings, traceIn, delivery);
                runner.Start(Path.GetFileNameWithoutExtension(script), args);
                if (trace != null) runner.RunTrace(System.IO.File.ReadAllLines(trace));
                runner.Tail(tailMs);
                if (runner.H.Crashed) sink.Emit("halted", ("why", "genie-crash"));
                sink.Emit("end", ("live", runner.H.LiveScriptCount));
            }
            catch (Exception ex)
            {
                sink.Emit("driver-exception", ("message", ex.ToString()));
                w.Flush();
                return 1;
            }
            w.Flush();
            if (outFile != null) w.Dispose();
            return 0;
        }
    }

    public sealed class Runner
    {
        public Host H;
        public bool Verbose;
        private readonly EventSink sink;
        private readonly double tickMs, maxMs;
        private int sendCursor = 0;
        private bool chunkOpen = false;

        public Runner(EventSink s, double tick, double max) { sink = s; tickMs = tick; maxMs = max; }

        public void Setup(string script, string scriptDir, string configDir, string vars, string settings, bool traceIn, string delivery)
        {
            scriptDir = Path.GetFullPath(scriptDir ?? Path.GetDirectoryName(Path.GetFullPath(script)));
            // LocalDirectory.Path is Genie's user-data root; Config.ScriptDir = Path + "\" + sScriptDir.
            // sScriptDir="" -> "<scriptDir>\" -> Script.AppendFile builds "<scriptDir>\name.cmd"
            // (Script.cs:3633), which the WinPath shim maps to "<scriptDir>/name.cmd".
            LocalDirectory.Path = scriptDir;
            H = new Host(sink) { VerboseGameVars = Verbose, TraceIn = traceIn };
            var cfg = H.G.Config;
            cfg.sScriptDir = "";
            cfg.bAutoLog = false;
            if (delivery != null)
            {
                H.Delivery = delivery.ToLowerInvariant() switch
                {
                    "row" => TriggerDelivery.Row,
                    "chunk" => TriggerDelivery.Chunk,
                    "sync" => TriggerDelivery.Sync,
                    _ => throw new Exception("--trigger-delivery must be row|chunk|sync"),
                };
#if GENIE_UPSTREAM
                if (H.Delivery != TriggerDelivery.Sync) throw new Exception("--trigger-delivery row|chunk models Remix's trigger Channel (FormMain.cs:6596 R); upstream is always sync");
#endif
            }
            var loaded = new List<string>();
            if (configDir != null) loaded.AddRange(ConfigDefaults.LoadConfigDir(H.G, configDir));
            // --settings / --vars: loaded from a private copy too (VariableList remembers the path)
            if (settings != null) { cfg.Load(WinStyle(GenieClient.Sandbox.CopyFile(settings, "settings"))); loaded.Add(Path.GetFullPath(settings)); }
            // Paths in a real settings.cfg (scriptdir {Scripts}, autolog...) would redirect file I/O;
            // genieflow keeps scripts resolved from --scriptdir and never logs.
            cfg.sScriptDir = "";
            cfg.bAutoLog = false;
            if (vars != null) { H.G.VariableList.Load(WinStyle(GenieClient.Sandbox.CopyFile(vars, "vars"))); loaded.Add(Path.GetFullPath(vars)); }
            // A live session always has $connected=1; Script.SetBufferWait (Script.cs:2134) only
            // defers match/waitfor resumption to the end of the socket chunk when it is 1.
            H.G.VariableList["connected"] = "1";
            // FormMain's startup ALWAYS runs ClassList.Load(ConfigDir\classes.cfg) (FormMain.cs:2343 R),
            // and Classes.Load adds "default" = True before it even looks for the file (Classes.cs:
            // 137-147 R); ConfigLoad skips a missing classes.cfg, so put the entry Load would have
            // added (WP10: `#class` listings and the class re-apply see `default` as in the client).
            if (!H.G.ClassList.ContainsKey("default")) H.G.ClassList.Add("default", "True");
            sink.Emit("setup", ("scriptdir", scriptDir), ("genie", ConfigDefaults.TreeName), ("delivery", H.Delivery.ToString().ToLowerInvariant()));
            if (loaded.Count > 0) sink.Emit("config", ("files", string.Join(" ", loaded)), ("ignorescriptwarnings", cfg.bIgnoreScriptWarnings), ("triggeroninput", cfg.bTriggerOnInput), ("abortdupescript", cfg.bAbortDupeScript), ("maxgosubdepth", cfg.iMaxGoSubDepth), ("scripttimeout", cfg.iScriptTimeout));
        }

        internal static string WinStyleStatic(string p) => WinStyle(p);

        // Genie's loaders only treat a path as absolute if it contains '\' (e.g. Globals.cs:727).
        private static string WinStyle(string p)
        {
            p = Path.GetFullPath(p);
            return Path.GetDirectoryName(p) + "\\" + Path.GetFileName(p);
        }

        public void Start(string name, List<string> args)
        {
            // Exactly what typing ".name args" does: Command.ParseCommand -> RunScript (Command.cs:2557)
            // -> FormMain.ClassCommand_RunScript -> LoadScript + RunScript.
            string line = "." + name + (args.Count > 0 ? " " + string.Join(" ", args) : "");
            H.UserInput(line);
            TickOnce();
        }

        public void TickOnce()
        {
            VirtualClock.AdvanceMs(tickMs);
            H.Tick();
            if (VirtualClock.ElapsedMs > maxMs) throw new Exception("virtual time limit exceeded (--maxms)");
        }

        private void CloseChunk()
        {
            if (!chunkOpen) return;
            chunkOpen = false;
            H.Flush();
            TickOnce();
        }

        private long GameTime => 1700000000L + (long)(VirtualClock.ElapsedMs / 1000.0);

        public void RunTrace(string[] lines)
        {
            int lineNo = 0;
            foreach (string raw in lines)
            {
                if (H.Crashed) break; // the real client process is gone (see Host.RemixRecursionCap)
                lineNo++;
                string l = raw.TrimEnd('\r');
                if (l.Trim().Length == 0 || l.TrimStart().StartsWith("#")) continue;
                string kw = l.Split(' ')[0].ToUpperInvariant();
                string rest = l.Length > kw.Length ? l.Substring(kw.Length + 1) : "";
                switch (kw)
                {
                    case "IN":
                        chunkOpen = true;
                        H.FeedRow(rest);
                        break;
                    case "PROMPT":
                    {
                        chunkOpen = true;
                        int rt = rest.Trim().Length > 0 ? int.Parse(rest.Trim()) : 0;
                        long gt = GameTime;
                        if (rt > 0) H.FeedRow($"<roundTime value='{gt + rt}'/>");
                        H.FeedRow($"<prompt time=\"{gt}\">&gt;</prompt>");
                        CloseChunk(); // a DR prompt ends the server packet
                        break;
                    }
                    case "ROOM":
                    {
                        chunkOpen = true;
                        string title = rest.Trim().Length > 0 ? rest.Trim() : "Somewhere";
                        H.FeedRow($"<streamWindow id='main' title='Story' subtitle=\" - [{title}]\" location='center' target='drop'/>");
                        H.FeedRow($"<component id='room desc'>You are in {title}.</component>");
                        break;
                    }
                    case "FLUSH":
                        if (!chunkOpen) { chunkOpen = true; }
                        CloseChunk();
                        break;
                    case "TICK":
                    {
                        CloseChunk();
                        int n = rest.Trim().Length > 0 ? int.Parse(rest.Trim()) : 1;
                        for (int i = 0; i < n; i++) TickOnce();
                        break;
                    }
                    case "WAIT":
                    {
                        CloseChunk();
                        double ms = double.Parse(rest.Trim(), CultureInfo.InvariantCulture);
                        double target = VirtualClock.ElapsedMs + ms;
                        while (VirtualClock.ElapsedMs + 1e-9 < target) TickOnce();
                        break;
                    }
                    case "EXPECT":
                        CloseChunk();
                        Expect(rest, lineNo);
                        break;
                    case "VAR":
                    {
                        CloseChunk();
                        int sp = rest.IndexOf(' ');
                        string name = sp < 0 ? rest : rest.Substring(0, sp);
                        string val = sp < 0 ? "" : rest.Substring(sp + 1);
                        H.G.VariableList[name] = val;
                        sink.Emit("var", ("name", "$" + name), ("value", val), ("src", "trace"));
                        H.TriggerVariableChanged("$" + name);
                        break;
                    }
                    case "INPUT":
                        CloseChunk();
                        H.UserInput(rest);
                        TickOnce();
                        break;
                    case "RUN":
                        CloseChunk();
                        H.UserInput("." + rest);
                        TickOnce();
                        break;
                    case "IDLE":
                    {
                        CloseChunk();
                        double ms = rest.Trim().Length > 0 ? double.Parse(rest.Trim(), CultureInfo.InvariantCulture) : 30000;
                        double target = VirtualClock.ElapsedMs + ms;
                        while (H.LiveScriptCount > 0 && VirtualClock.ElapsedMs < target) TickOnce();
                        break;
                    }
                    default:
                        throw new Exception($"trace line {lineNo}: unknown directive '{kw}'");
                }
            }
            CloseChunk();
        }

        private void Expect(string spec, int lineNo)
        {
            spec = spec.Trim();
            double limit = 30000;
            Regex re = null;
            string lit = spec;
            if (spec.StartsWith("/"))
            {
                int end = spec.LastIndexOf('/');
                string pat = spec.Substring(1, end - 1);
                string tail = spec.Substring(end + 1).Trim();
                if (tail.Length > 0) limit = double.Parse(tail, CultureInfo.InvariantCulture);
                re = new Regex(pat);
            }
            double deadline = VirtualClock.ElapsedMs + limit;
            while (true)
            {
                var sends = sink.Events.Where(e => (string)e["ev"] == "send").ToList();
                for (int i = sendCursor; i < sends.Count; i++)
                {
                    string text = (string)sends[i]["text"];
                    if (re != null ? re.IsMatch(text) : text == lit)
                    {
                        sendCursor = i + 1;
                        sink.Emit("expect-ok", ("want", spec), ("got", text));
                        return;
                    }
                }
                if (VirtualClock.ElapsedMs >= deadline || H.LiveScriptCount == 0)
                {
                    sink.Emit("expect-timeout", ("want", spec), ("line", lineNo));
                    return;
                }
                TickOnce();
            }
        }

        public void Tail(double ms)
        {
            double target = VirtualClock.ElapsedMs + ms;
            while (H.LiveScriptCount > 0 && VirtualClock.ElapsedMs < target) TickOnce();
        }
    }
}
