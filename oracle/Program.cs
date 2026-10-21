using System;
using System.Collections;
using System.Globalization;
using System.Text;
using GenieClient;
using GenieClient.Genie;
using GenieClient.Genie.Script;
using Microsoft.VisualBasic.CompilerServices;

// genieoracle <mode> <expression...>
//   math       -> MathEval.Evaluate  (prints the raw double, invariant culture)
//   eval       -> Eval.EvalString    (prints the string result)
//   evalbool   -> Eval.DoEval        (prints 1/0)
//   parseargs  -> Utility.ParseArgs(expr, false) -> count then tokens, \x1f-joined
//   parseargs_ -> Utility.ParseArgs(expr, true)  (bTreatUnderscoreAsSpace=true)
//   s2d        -> Utility.StringToDouble(expr)   (double, "R"; -1 on failure)
//   s2i        -> Utility.StringToInteger(expr)  (Int32; -1 unless a positive int.Parse value)
//   toint      -> Conversions.ToInteger(expr)    (Int32, banker's; throws on bad/overflow)
//   tolong     -> Conversions.ToLong(expr)       (Int64, banker's; throws on bad/overflow)
//   tointmsg   -> as toint, but an exception prints "ERR:<Type>:<Message>" (the host text)
//   rxmatch    -> "<flags>\x1f<pattern>\x1f<subject>": new Regex(pattern, Multiline [| IgnoreCase
//                 when flags == "i"]) exactly like Script.cs:359-363, 507-511 R; an invalid pattern
//                 prints "ERR:<Type>"; else the Match serialized like parseargs (count, then each
//                 group's Value, "" for an unmatched group); "0" = no match.
// Reads one call per argv, OR many from stdin ("<mode>\t<expr>" per line) with --stdin.
internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--stdin")
        {
            string line;
            while ((line = Console.In.ReadLine()) != null)
            {
                int tab = line.IndexOf('\t');
                if (tab < 0) { Console.WriteLine("ERR:badline"); continue; }
                Console.WriteLine(RunOne(line.Substring(0, tab), line.Substring(tab + 1)));
            }
            return 0;
        }

        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: genieoracle <math|eval|evalbool> <expr>   (or: --stdin)");
            return 2;
        }
        Console.WriteLine(RunOne(args[0], string.Join(" ", args, 1, args.Length - 1)));
        return 0;
    }

    private static string RunOne(string mode, string expr)
    {
        try
        {
            switch (mode)
            {
                case "math":
                    return new MathEval().Evaluate(expr).ToString("R", CultureInfo.InvariantCulture);
                case "evalmath":
                {
                    // Faithful copy of Command.cs EvalMath: en-US culture, plain ToString().
                    var save = System.Threading.Thread.CurrentThread.CurrentCulture;
                    System.Threading.Thread.CurrentThread.CurrentCulture = new CultureInfo("en-US");
                    try { return new MathEval().Evaluate(expr).ToString(); }
                    finally { System.Threading.Thread.CurrentThread.CurrentCulture = save; }
                }
                case "eval":
                    return new Eval().EvalString(expr, new Globals());
                case "matchrecaps":
                {
                    // Evaluate a matchre(...) expression, then serialize Eval.ResultList
                    // (the m_RegExpResultList capture groups) exactly like parseargs:
                    // "<count>\x1f<g0>\x1f<g1>...". count 0 == no match / no captures.
                    var ev = new Eval();
                    ev.EvalString(expr, new Globals());
                    return SerializeArgs(ev.ResultList);
                }
                case "evalbool":
                    return new Eval().DoEval(expr, new Globals()) ? "1" : "0";
                case "parseargs":
                    return SerializeArgs(Utility.ParseArgs(expr, false));
                case "parseargs_":
                    return SerializeArgs(Utility.ParseArgs(expr, true));
                case "s2d":
                    // Utility.StringToDouble: en-US double.Parse, -1 on nothing/failure.
                    // "R" = round-trippable, so the Ruby side re-parses to the exact bits.
                    return Utility.StringToDouble(expr).ToString("R", CultureInfo.InvariantCulture);
                case "s2i":
                    // Utility.StringToInteger: en-US int.Parse; <= 0 or a failure -> -1 (EvalRandom's bounds).
                    return Utility.StringToInteger(expr).ToString(CultureInfo.InvariantCulture);
                case "toint":
                    // VB Conversions.ToInteger (substr/substring/round-digits/factorial):
                    // Int32, banker's rounding; throws on non-numeric / Int32 overflow.
                    return Conversions.ToInteger(expr).ToString(CultureInfo.InvariantCulture);
                case "tolong":
                    // VB Conversions.ToLong (the `\` integer-division operands): Int64,
                    // banker's rounding; throws on non-numeric / Int64 overflow.
                    return Conversions.ToLong(expr).ToString(CultureInfo.InvariantCulture);
                case "tointmsg":
                    // As toint, with the exception MESSAGE (ScriptArgs shift fault text).
                    try { return Conversions.ToInteger(expr).ToString(CultureInfo.InvariantCulture); }
                    catch (Exception ex) { return "ERR:" + ex.GetType().Name + ":" + ex.Message; }
                case "rxmatch":
                {
                    var parts = expr.Split('\x1f');
                    if (parts.Length != 3) return "ERR:badrx";
                    var opts = System.Text.RegularExpressions.RegexOptions.Multiline;
                    if (parts[0] == "i") opts |= System.Text.RegularExpressions.RegexOptions.IgnoreCase;
                    var rx = new System.Text.RegularExpressions.Regex(parts[1], opts);
                    var m = rx.Match(parts[2]);
                    var groups = new ArrayList();
                    if (m.Success)
                        for (int g = 0; g < m.Groups.Count; g++) groups.Add(m.Groups[g].Value);
                    return SerializeArgs(groups);
                }
                default:
                    return "ERR:mode";
            }
        }
        catch (Exception ex)
        {
            return "ERR:" + ex.GetType().Name;
        }
    }

    // count, then each token, joined by \x1f (unit separator). The leading count keeps
    // 0-token results ("") distinct from a single empty-string token ("{}") which would
    // otherwise both serialize to "". The Ruby fuzzer mirrors this format exactly.
    private static string SerializeArgs(ArrayList oList)
    {
        var sb = new StringBuilder();
        sb.Append(oList.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var item in oList)
        {
            sb.Append('\x1f');
            sb.Append(item == null ? string.Empty : item.ToString());
        }
        return sb.ToString();
    }
}
