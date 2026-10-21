// VIRTUAL CLOCK. Genie4 reads the wall clock through `DateTime.Now` (unqualified) in
// Script.cs / Globals.cs / Events.cs / CommandQueue.cs / Game.cs. All of those files live
// in namespace GenieClient or GenieClient.Genie[.X]; C# name lookup searches enclosing
// namespaces BEFORE `using System;`, so this GenieClient.DateTime transparently replaces
// System.DateTime for every linked Genie4 file WITHOUT editing them. It is a thin wrapper
// (identical value semantics, implicit conversions both ways) whose Now/UtcNow/Today come
// from VirtualClock, which only the driver advances.
using System;
using System.Globalization;

namespace GenieFlow
{
    public static class VirtualClock
    {
        // Fixed epoch so @time@/@date@ etc. are reproducible. Local kind, like DateTime.Now.
        public static readonly System.DateTime Epoch = new System.DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Local);
        public static System.DateTime Now = Epoch;
        public static double ElapsedMs => (Now - Epoch).TotalMilliseconds;
        public static void AdvanceMs(double ms) { if (ms > 0) Now = Now.AddMilliseconds(ms); }
    }
}

namespace GenieClient
{
    [Serializable]
    public readonly struct DateTime : IComparable, IComparable<DateTime>, IEquatable<DateTime>, IFormattable
    {
        private readonly System.DateTime v;
        public DateTime(System.DateTime value) { v = value; }
        public DateTime(long ticks) { v = new System.DateTime(ticks); }
        public DateTime(int y, int mo, int d) { v = new System.DateTime(y, mo, d); }
        public DateTime(int y, int mo, int d, int h, int mi, int s) { v = new System.DateTime(y, mo, d, h, mi, s); }

        public static DateTime Now => new DateTime(GenieFlow.VirtualClock.Now);
        public static DateTime UtcNow => new DateTime(GenieFlow.VirtualClock.Now.ToUniversalTime());
        public static DateTime Today => new DateTime(GenieFlow.VirtualClock.Now.Date);
        public static readonly DateTime MinValue = new DateTime(System.DateTime.MinValue);
        public static readonly DateTime MaxValue = new DateTime(System.DateTime.MaxValue);

        public static DateTime Parse(string s) => new DateTime(System.DateTime.Parse(s));
        public static DateTime Parse(string s, IFormatProvider p) => new DateTime(System.DateTime.Parse(s, p));
        public static bool TryParse(string s, out DateTime r) { var ok = System.DateTime.TryParse(s, out var d); r = new DateTime(d); return ok; }

        public DateTime AddMilliseconds(double x) => new DateTime(v.AddMilliseconds(x));
        public DateTime AddSeconds(double x) => new DateTime(v.AddSeconds(x));
        public DateTime AddMinutes(double x) => new DateTime(v.AddMinutes(x));
        public DateTime AddHours(double x) => new DateTime(v.AddHours(x));
        public DateTime AddDays(double x) => new DateTime(v.AddDays(x));
        public DateTime AddTicks(long x) => new DateTime(v.AddTicks(x));
        public DateTime Add(TimeSpan t) => new DateTime(v.Add(t));
        public TimeSpan Subtract(DateTime o) => v - o.v;
        public DateTime Subtract(TimeSpan t) => new DateTime(v - t);
        public DateTime ToUniversalTime() => new DateTime(v.ToUniversalTime());
        public DateTime ToLocalTime() => new DateTime(v.ToLocalTime());

        public int Year => v.Year; public int Month => v.Month; public int Day => v.Day;
        public int Hour => v.Hour; public int Minute => v.Minute; public int Second => v.Second;
        public int Millisecond => v.Millisecond; public int DayOfYear => v.DayOfYear;
        public DayOfWeek DayOfWeek => v.DayOfWeek; public long Ticks => v.Ticks;
        public DateTime Date => new DateTime(v.Date); public TimeSpan TimeOfDay => v.TimeOfDay;
        public DateTimeKind Kind => v.Kind;

        public override string ToString() => v.ToString();
        public string ToString(string f) => v.ToString(f);
        public string ToString(IFormatProvider p) => v.ToString(p);
        public string ToString(string f, IFormatProvider p) => v.ToString(f, p);
        public string ToShortTimeString() => v.ToShortTimeString();
        public string ToShortDateString() => v.ToShortDateString();
        public string ToLongTimeString() => v.ToLongTimeString();

        public override bool Equals(object o) => (o is DateTime d && d.v == v) || (o is System.DateTime s && s == v);
        public bool Equals(DateTime o) => o.v == v;
        public override int GetHashCode() => v.GetHashCode();
        public int CompareTo(DateTime o) => v.CompareTo(o.v);
        public int CompareTo(object o) => o is DateTime d ? v.CompareTo(d.v) : v.CompareTo(o);

        public static implicit operator System.DateTime(DateTime d) => d.v;
        public static implicit operator DateTime(System.DateTime d) => new DateTime(d);

        public static bool operator ==(DateTime a, DateTime b) => a.v == b.v;
        public static bool operator !=(DateTime a, DateTime b) => a.v != b.v;
        public static bool operator <(DateTime a, DateTime b) => a.v < b.v;
        public static bool operator >(DateTime a, DateTime b) => a.v > b.v;
        public static bool operator <=(DateTime a, DateTime b) => a.v <= b.v;
        public static bool operator >=(DateTime a, DateTime b) => a.v >= b.v;
        public static TimeSpan operator -(DateTime a, DateTime b) => a.v - b.v;
        public static DateTime operator -(DateTime a, TimeSpan t) => new DateTime(a.v - t);
        public static DateTime operator +(DateTime a, TimeSpan t) => new DateTime(a.v + t);
    }
}

namespace GenieClient
{
    // DETERMINISTIC RANDOM. Utility.RandomNumber (Utility.cs:251) does `new Random().Next(min, max + 1)`.
    // This GenieClient.Random shadows System.Random for the linked files (same lookup trick) and
    // draws from one process-wide generator seeded by --seed (default 1), so `random`/#random
    // are reproducible. Range semantics are System.Random's (inclusive min, exclusive max).
    public class Random
    {
        public static System.Random Shared = new System.Random(1);
        public int Next(int min, int max) => Shared.Next(min, max);
        public int Next(int max) => Shared.Next(max);
        public int Next() => Shared.Next();
        public double NextDouble() => Shared.NextDouble();
    }
}

namespace GenieClient
{
    // DateTimeOffset.Now/UtcNow on the virtual clock (closes old fidelity gap #5). Callers in the
    // linked files: Globals.cs:230 (@unixtime@, both trees) and, in Remix only, Game.cs:2368
    // (writes $unixtime on every prompt). Same namespace-shadowing trick as DateTime above.
    public static class DateTimeOffset
    {
        public static System.DateTimeOffset Now => new System.DateTimeOffset(GenieFlow.VirtualClock.Now);
        public static System.DateTimeOffset UtcNow => new System.DateTimeOffset(GenieFlow.VirtualClock.Now).ToUniversalTime();
    }
}
