// --config-dir: load a real Genie Config directory the way the client does at startup.
//
// Remix FormMain.cs (Genie4_Remix/Forms/FormMain.cs), startup sequence, each file from
// Config.ConfigDir + "\<name>.cfg" and each loader REAL Genie code (Lists/*.cs):
//   2295 Config.Load(settings.cfg)        2299 PresetList.Load(presets.cfg)
//   2311 VariableList.Load(variables.cfg) 2315 LoadHighlights(highlights.cfg)
//   2319 NameList.Load(names.cfg)         2323 MacroList.Load(macros.cfg)
//   2327 AliasList.Load(aliases.cfg)      2331 SubstituteList.Load(substitutes.cfg)
//   2335 GagList.Load(gags.cfg)           2339 TriggerList.Load(triggers.cfg)
//   2343 ClassList.Load(classes.cfg)
// Upstream 4.5.0.3 FormMain.cs uses the same order (Genie4/Forms/FormMain.cs LoadSettings).
// Missing files are skipped exactly as the loaders do (each returns false when !File.Exists).
// Not modelled: LoadProfileSettings (R:8524), which on connect re-loads variables/macros/aliases/
// classes from the per-character Config\Profiles\<char> dir.
using System;
using System.Collections.Generic;
using System.IO;
using GenieClient.Genie;

namespace GenieFlow
{
    internal static class ConfigDefaults
    {
        // Optional corpus default (lab feature, off unless configured): when GENIEFLOW_CORPUS_DIRS
        // (one or more directories, separated by ':') and GENIEFLOW_CORPUS_CONFIG (a Genie Config
        // directory) are both set, any script or --loadcheck path under one of those directories
        // loads that Config directory unless --config-dir / --no-config is given. Self-tests
        // (tests/) always use Genie's built-in defaults.
        public static readonly string CorpusConfigDir = NullIfEmpty(Environment.GetEnvironmentVariable("GENIEFLOW_CORPUS_CONFIG"));

        private static readonly string[] CorpusRoots = ParseRoots(Environment.GetEnvironmentVariable("GENIEFLOW_CORPUS_DIRS"));

        private static string NullIfEmpty(string s) => string.IsNullOrEmpty(s) ? null : s;

        private static string[] ParseRoots(string v)
        {
            if (string.IsNullOrEmpty(v)) return new string[0];
            var roots = new List<string>();
            foreach (var r in v.Split(':'))
            {
                if (r.Length == 0) continue;
                string full = Path.GetFullPath(r);
                roots.Add(full.EndsWith("/") ? full : full + "/");
            }
            return roots.ToArray();
        }

        public static bool IsCorpusPath(string p)
        {
            if (CorpusConfigDir == null || string.IsNullOrEmpty(p) || p.StartsWith("--")) return false;
            string full = Path.GetFullPath(p);
            if (Directory.Exists(full) && !full.EndsWith("/")) full += "/";
            foreach (var r in CorpusRoots) if (full.StartsWith(r, StringComparison.Ordinal)) return true;
            return false;
        }

        public static string TreeName =>
#if GENIE_REMIX
            "Genie4 Remix v4.2.4";
#else
            "Genie4 4.5.0.3";
#endif

        public static List<string> LoadConfigDir(Globals g, string dir)
        {
            var loaded = new List<string>();
            dir = Path.GetFullPath(dir);
            if (!Directory.Exists(dir)) throw new Exception("--config-dir: no such directory " + dir);
            // Load a private per-run copy (GenieClient.Sandbox, ShimsIO.cs): a loader that
            // remembers its path (VariableList, so `#var save`) writes the copy, never +dir+.
            // The `config` event still names +dir+'s files.
            string from = GenieClient.Sandbox.CopyDir(dir, "config");
            string W(string name) => from + "\\" + name; // Genie treats a path as absolute iff it contains '\'
            void Try(string name, Func<string, bool> load)
            {
                if (!File.Exists(Path.Combine(from, name))) return;
                load(W(name));
                loaded.Add(Path.Combine(dir, name));
            }
            Try("settings.cfg", f => g.Config.Load(f));
            Try("presets.cfg", f => g.PresetList.Load(f));
            Try("variables.cfg", f => g.VariableList.Load(f));
            Try("highlights.cfg", f => g.LoadHighlights(f));
            Try("names.cfg", f => g.NameList.Load(f));
            Try("macros.cfg", f => g.MacroList.Load(f));
            Try("aliases.cfg", f => g.AliasList.Load(f));
            Try("substitutes.cfg", f => g.SubstituteList.Load(f));
            Try("gags.cfg", f => g.GagList.Load(f));
            Try("triggers.cfg", f => g.TriggerList.Load(f));
            Try("classes.cfg", f => g.ClassList.Load(f));
            return loaded;
        }
    }
}
