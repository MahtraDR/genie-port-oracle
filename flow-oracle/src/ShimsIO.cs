// WINDOWS-PATH EMULATION. Genie4 builds every path with literal backslashes
// (Config.ScriptDir + "\" + file, LocalDirectory.Path + @"\Config\..."). On macOS '\' is
// an ordinary filename character, so these GenieClient.* types shadow the System.IO types
// the linked files use (same namespace-lookup trick as ShimsClock.cs) and translate
// '\' -> '/' before delegating. No Genie logic is altered; only the OS path separator.
//
// PER-RUN WRITE SANDBOX (lab hygiene, 2026-10-20). Genie writes files: `#var save` rewrites the
// variables.cfg it loaded (VariableList.m_FileName = the loaded path, Globals.cs:722-797 R),
// `#save` / `#trigger save` / `#config save` write Config.ConfigDir = LocalDirectory.Path +
// "\Config" (Command.cs:500-634 R) -- and genieflow roots LocalDirectory.Path at --scriptdir, so
// a sweep over the corpus wrote into the corpus and into the tester's real config dir (2026-10-20).
// Every write below therefore lands in a per-process temp dir ({Sandbox.Root}): a path outside
// it is shadowed at Root/shadow/<absolute path>, and reads see the shadow first, so a run still
// reads back what it wrote (a `#trigger save` then `#trigger load`) while the real file system is
// never written. An original is never moved, replaced or deleted (a delete hides it for the run).
// Parallel runs never share writable state (one Root per process, removed at exit).
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace GenieClient
{
    internal static class WinPath
    {
        public static string N(string p) => p == null ? null : p.Replace('\\', '/');
    }

    // The per-process write sandbox (see the header).
    public static class Sandbox
    {
        public static string Root { get; private set; }
        private static readonly HashSet<string> Hidden = new HashSet<string>(StringComparer.Ordinal);

        // Create Root (once) and remove it when the process exits.
        public static string Init()
        {
            if (Root != null) return Root;
            string root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"genieflow-{Environment.ProcessId}-{Guid.NewGuid():N}");
            System.IO.Directory.CreateDirectory(root);
            Root = System.IO.Path.GetFullPath(root).TrimEnd('/');
            AppDomain.CurrentDomain.ProcessExit += (_, _) => Cleanup();
            SweepOrphans();
            return Root;
        }

        // A run that dies (stack overflow = no ProcessExit; sweep_batch's SIGKILL on timeout) cannot
        // remove its own Root (WPF lab hygiene: 45 were left in $TMPDIR). Each run removes the
        // genieflow-<pid>-<guid> dirs whose pid is no longer running; a live run's dir is never
        // touched (a reused pid only keeps an orphan longer).
        private static void SweepOrphans()
        {
            try
            {
                foreach (string dir in System.IO.Directory.GetDirectories(System.IO.Path.GetTempPath(), "genieflow-*-*"))
                {
                    string[] parts = System.IO.Path.GetFileName(dir).Split('-');
                    if (parts.Length != 3 || !int.TryParse(parts[1], out int pid) || pid == Environment.ProcessId) continue;
                    bool alive;
                    try { using var p = System.Diagnostics.Process.GetProcessById(pid); alive = !p.HasExited; }
                    catch (ArgumentException) { alive = false; }
                    catch (InvalidOperationException) { alive = false; }
                    if (!alive) { try { System.IO.Directory.Delete(dir, true); } catch { } }
                }
            }
            catch { }
        }

        public static void Cleanup()
        {
            try { if (Root != null && System.IO.Directory.Exists(Root)) System.IO.Directory.Delete(Root, true); } catch { }
        }

        // A private copy of the top-level files of +dir+ under Root/<label>: what a run loads, so
        // even a loader that remembers its path (VariableList) writes only the copy.
        public static string CopyDir(string dir, string label)
        {
            Init();
            string dst = System.IO.Path.Combine(Root, label);
            System.IO.Directory.CreateDirectory(dst);
            foreach (string f in System.IO.Directory.GetFiles(System.IO.Path.GetFullPath(dir)))
                System.IO.File.Copy(f, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(f)), true);
            return dst;
        }

        // A private copy of one file under Root/<label>/<file name>.
        public static string CopyFile(string file, string label)
        {
            Init();
            string dst = System.IO.Path.Combine(Root, label);
            System.IO.Directory.CreateDirectory(dst);
            string to = System.IO.Path.Combine(dst, System.IO.Path.GetFileName(file));
            System.IO.File.Copy(System.IO.Path.GetFullPath(file), to, true);
            return to;
        }

        private static string Full(string p) => System.IO.Path.GetFullPath(WinPath.N(p));
        public static bool Inside(string full) => Root != null && (full == Root || full.StartsWith(Root + "/", StringComparison.Ordinal));
        private static string ShadowOf(string full) => Root + "/shadow" + full;
        private static bool Present(string p) => System.IO.File.Exists(p) || System.IO.Directory.Exists(p);

        // The path a READ of +p+ uses: the shadow if the run wrote it, nothing if the run deleted
        // it, else the original.
        public static string Read(string p)
        {
            if (p == null || Root == null) return WinPath.N(p);
            string full = Full(p);
            if (Inside(full)) return full;
            string shadow = ShadowOf(full);
            if (Present(shadow)) return shadow;
            return Hidden.Contains(full) ? ShadowOf(full) : full; // a hidden original reads as missing
        }

        // The path a WRITE of +p+ uses (its parent created). +seed+: start from the current
        // content (append / read-write open / replace).
        public static string Write(string p, bool seed = false)
        {
            if (p == null) return null;
            Init();
            string full = Full(p);
            if (Inside(full)) return full;
            string shadow = ShadowOf(full);
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(shadow));
            if (seed && !Present(shadow) && !Hidden.Contains(full) && System.IO.File.Exists(full)) System.IO.File.Copy(full, shadow);
            Hidden.Remove(full);
            return shadow;
        }

        // A sandbox path holding +p+'s content that the caller may consume (move away); the
        // original, if any, is hidden for the rest of the run.
        public static string Own(string p)
        {
            string read = Read(p);
            if (Inside(read)) return read;
            string full = Full(p);
            string shadow = Write(p, seed: true);
            Hidden.Add(full);
            return shadow;
        }

        public static void Delete(string p)
        {
            string read = Read(p);
            if (Inside(read)) { if (System.IO.File.Exists(read)) System.IO.File.Delete(read); }
            if (Root != null && !Inside(Full(p))) Hidden.Add(Full(p));
        }

        // A directory listing merging the original and the shadow, as original paths.
        public static string[] List(string p, Func<string, string[]> lister)
        {
            string full = Full(p);
            if (Root == null || Inside(full)) return lister(full);
            var names = new SortedSet<string>(StringComparer.Ordinal);
            if (System.IO.Directory.Exists(full)) foreach (string e in lister(full)) names.Add(e);
            string shadow = ShadowOf(full);
            if (System.IO.Directory.Exists(shadow)) foreach (string e in lister(shadow)) names.Add(e.Substring((Root + "/shadow").Length));
            return names.Where(e => !Hidden.Contains(e) || Present(ShadowOf(e))).ToArray();
        }

        public static bool WriteIntent(System.IO.FileMode m, System.IO.FileAccess a) => m != System.IO.FileMode.Open || (a & System.IO.FileAccess.Write) != 0;
        public static bool Seeded(System.IO.FileMode m) => m == System.IO.FileMode.Open || m == System.IO.FileMode.OpenOrCreate || m == System.IO.FileMode.Append;
    }

    public static class File
    {
        public static bool Exists(string p) => System.IO.File.Exists(Sandbox.Read(p));
        public static System.DateTime GetLastWriteTime(string p) => System.IO.File.GetLastWriteTime(Sandbox.Read(p));
        public static void Move(string a, string b) => Move(a, b, false);
        public static void Move(string a, string b, bool o) => System.IO.File.Move(Sandbox.Own(a), Sandbox.Write(b), o);
        public static void Delete(string p) => Sandbox.Delete(p);
        public static void Copy(string a, string b, bool o) => System.IO.File.Copy(Sandbox.Read(a), Sandbox.Write(b), o);
        // Remix Utility.SaveFileAtomic (Utility.cs:583 R) swaps a temp file in with File.Replace.
        public static void Replace(string src, string dst, string backup) =>
            System.IO.File.Replace(Sandbox.Own(src), Sandbox.Write(dst, seed: true), backup == null ? null : Sandbox.Write(backup));
        public static string ReadAllText(string p) => System.IO.File.ReadAllText(Sandbox.Read(p));
        public static string[] ReadAllLines(string p) => System.IO.File.ReadAllLines(Sandbox.Read(p));
        public static void WriteAllText(string p, string t) => System.IO.File.WriteAllText(Sandbox.Write(p), t);
        public static void AppendAllText(string p, string t) => System.IO.File.AppendAllText(Sandbox.Write(p, seed: true), t);
        public static System.IO.FileStream Create(string p) => System.IO.File.Create(Sandbox.Write(p));
        public static System.IO.FileStream OpenRead(string p) => System.IO.File.OpenRead(Sandbox.Read(p));
        public static byte[] ReadAllBytes(string p) => System.IO.File.ReadAllBytes(Sandbox.Read(p));
        public static System.IO.StreamWriter CreateText(string p) => System.IO.File.CreateText(Sandbox.Write(p));
        public static System.IO.StreamReader OpenText(string p) => System.IO.File.OpenText(Sandbox.Read(p));
    }

    public static class Directory
    {
        public static bool Exists(string p) => System.IO.Directory.Exists(Sandbox.Read(p));
        public static System.IO.DirectoryInfo CreateDirectory(string p) => System.IO.Directory.CreateDirectory(Sandbox.Write(p));
        public static string[] GetFiles(string p) => Sandbox.List(p, d => System.IO.Directory.GetFiles(d));
        public static string[] GetFiles(string p, string pat) => Sandbox.List(p, d => System.IO.Directory.GetFiles(d, pat));
        public static string[] GetFiles(string p, string pat, System.IO.SearchOption o) => Sandbox.List(p, d => System.IO.Directory.GetFiles(d, pat, o));
        public static string[] GetDirectories(string p) => Sandbox.List(p, d => System.IO.Directory.GetDirectories(d));
    }

    public class FileStream : System.IO.FileStream
    {
        public FileStream(string p, System.IO.FileMode m) : base(Pick(p, m, m == System.IO.FileMode.Append ? System.IO.FileAccess.Write : System.IO.FileAccess.ReadWrite), m) { }
        public FileStream(string p, System.IO.FileMode m, System.IO.FileAccess a) : base(Pick(p, m, a), m, a) { }
        public FileStream(string p, System.IO.FileMode m, System.IO.FileAccess a, System.IO.FileShare s) : base(Pick(p, m, a), m, a, s) { }

        private static string Pick(string p, System.IO.FileMode m, System.IO.FileAccess a) =>
            Sandbox.WriteIntent(m, a) ? Sandbox.Write(p, seed: Sandbox.Seeded(m)) : Sandbox.Read(p);
    }

    public class StreamReader : System.IO.StreamReader
    {
        public StreamReader(System.IO.Stream s) : base(s) { }
        public StreamReader(System.IO.Stream s, Encoding e) : base(s, e) { }
        public StreamReader(string p) : base(Sandbox.Read(p)) { }
        public StreamReader(string p, Encoding e) : base(Sandbox.Read(p), e) { }
        public StreamReader(string p, bool d) : base(Sandbox.Read(p), d) { }
    }

    public class StreamWriter : System.IO.StreamWriter
    {
        public StreamWriter(System.IO.Stream s) : base(s) { }
        public StreamWriter(string p) : base(Sandbox.Write(p)) { }
        public StreamWriter(string p, bool a) : base(Sandbox.Write(p, seed: a), a) { }
        public StreamWriter(string p, bool a, Encoding e) : base(Sandbox.Write(p, seed: a), a, e) { }
    }

    // Metadata from the path a read would use; names report the path Genie asked for.
    public sealed class FileInfo
    {
        private readonly System.IO.FileInfo f;
        private readonly System.IO.FileInfo asked;
        public FileInfo(string p) { f = new System.IO.FileInfo(Sandbox.Read(p)); asked = new System.IO.FileInfo(WinPath.N(p)); }
        public bool Exists => f.Exists;
        public long Length => f.Length;
        public string FullName => asked.FullName;
        public string Name => asked.Name;
        public string DirectoryName => asked.DirectoryName;
        public string Extension => asked.Extension;
        public System.DateTime LastWriteTime => f.LastWriteTime;
        public FileStream Open(System.IO.FileMode m, System.IO.FileAccess a, System.IO.FileShare s) => new FileStream(asked.FullName, m, a, s);
        public FileStream Open(System.IO.FileMode m, System.IO.FileAccess a) => new FileStream(asked.FullName, m, a);
        public FileStream Open(System.IO.FileMode m) => new FileStream(asked.FullName, m);
    }

    public sealed class DirectoryInfo
    {
        private readonly System.IO.DirectoryInfo d;
        private readonly System.IO.DirectoryInfo asked;
        public DirectoryInfo(string p) { d = new System.IO.DirectoryInfo(Sandbox.Read(p)); asked = new System.IO.DirectoryInfo(WinPath.N(p)); }
        public bool Exists => d.Exists;
        public string FullName => asked.FullName;
        public string Name => asked.Name;
        public void Create() => System.IO.Directory.CreateDirectory(Sandbox.Write(asked.FullName));
        public System.IO.FileInfo[] GetFiles() => d.GetFiles();
        public System.IO.FileInfo[] GetFiles(string pat) => d.GetFiles(pat);
        public System.IO.DirectoryInfo[] GetDirectories() => d.GetDirectories();
    }
}
