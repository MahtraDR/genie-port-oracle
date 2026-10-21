// genieflow --loadcheck <file-or-dir>...
// Loads every .cmd through the REAL Script.LoadFile (-> AppendFile/AddLine) with Genie's default
// config, or with a real Config dir (--config-dir; or GENIEFLOW_CORPUS_CONFIG for corpus paths, see
// ConfigLoad.cs), and reports whether Genie4 would even
// START the script, plus every load-time error ("Unknown script command", "Invalid IF
// statement", "Replacing duplicate label", missing include...). One JSON object per file.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using GenieClient;
using GenieClient.Genie;

namespace GenieFlow
{
    internal static class LoadCheck
    {
        public static int Run(List<string> paths, string configDir)
        {
            var files = new List<string>();
            foreach (var p in paths)
            {
                if (System.IO.Directory.Exists(p))
                    files.AddRange(System.IO.Directory.GetFiles(p, "*", System.IO.SearchOption.AllDirectories)
                        .Where(f => f.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)));
                else files.Add(p);
            }
            files.Sort(StringComparer.Ordinal);
            var g = new Globals();
            var loaded = configDir != null ? ConfigDefaults.LoadConfigDir(g, configDir) : new List<string>();
            g.Config.bAutoLog = false;
            g.Config.sScriptDir = "";
            Console.WriteLine(EventSink.ToJson(new Dictionary<string, object> { ["t"] = 0.0, ["ev"] = "setup", ["genie"] = ConfigDefaults.TreeName, ["config"] = string.Join(" ", loaded), ["ignorescriptwarnings"] = g.Config.bIgnoreScriptWarnings }));
            foreach (var f in files)
            {
                var full = System.IO.Path.GetFullPath(f);
                LocalDirectory.Path = System.IO.Path.GetDirectoryName(full);
                var errors = new List<string>();
                var s = new Script(g);
                s.EventPrintError += t => errors.Add(Host.Clean(t));
                var al = new ArrayList { "." + System.IO.Path.GetFileNameWithoutExtension(full) };
                bool ok;
                try { ok = s.LoadFile(System.IO.Path.GetFileName(full), al); }
                catch (Exception ex) { ok = false; errors.Add("EXCEPTION " + ex.GetType().Name + ": " + ex.Message); }
                var d = new Dictionary<string, object> { ["t"] = 0.0, ["ev"] = "loadcheck", ["file"] = full, ["loaded"] = ok, ["errors"] = string.Join("\u001f", errors) };
                Console.WriteLine(EventSink.ToJson(d));
            }
            return 0;
        }
    }
}
