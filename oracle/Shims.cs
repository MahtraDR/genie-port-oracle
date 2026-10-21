using System;
using System.Collections;
using Microsoft.VisualBasic;
using Microsoft.VisualBasic.CompilerServices;

// Minimal stand-ins for the two symbols Eval.cs/MathEval.cs reach outside the pure
// evaluator: Utility.StringToDouble (faithful copy -- returns -1 on non-numeric/null,
// a Genie quirk) and Globals.VariableList (Eval only calls .ContainsKey for def()).
// Also carries a VERBATIM copy of Utility.ParseArgs + AddArrayItem (Utility.cs:390),
// extracted so we can differential-test our Ruby Text.parse_args without dragging in
// the WinForms-tainted rest of Utility.cs (Config/GenieError in other functions).
namespace GenieClient
{
    public static class Utility
    {
        public static double StringToDouble(string sValue)
        {
            try
            {
                if (Microsoft.VisualBasic.Information.IsNothing(sValue))
                {
                    return -1;
                }
                return double.Parse(sValue, new System.Globalization.CultureInfo("en-US"));
            }
            catch
            {
                return -1;
            }
        }

        // VERBATIM copy of GenieClient.Utility.StringToInteger (Remix Utility/Utility.cs:682-704):
        // EvalRandom's bounds (Script.cs:3119 R).
        public static int StringToInteger(string sValue)
        {
            try
            {
                if (Microsoft.VisualBasic.Information.IsNothing(sValue))
                {
                    return -1;
                }

                int i = int.Parse(sValue, new System.Globalization.CultureInfo("en-US"));
                if (i > 0)
                {
                    return i;
                }
                else
                {
                    return -1;
                }
            }
            catch
            {
                return -1;
            }
        }

        // VERBATIM copy of GenieClient.Utility.ParseArgs (Utility/Utility.cs:390).
        public static ArrayList ParseArgs(string sText, bool bTreatUnderscoreAsSpace = false)
        {
            var oList = new ArrayList();
            try
            {
                bool bInsideString = false;
                var cInsideStringChar = default(char);
                int iBracketDepth = 0;
                bool bEscapeChar = false;
                char ch;
                int l = 0;
                int sp = 0;
                for (int cp = 0, loopTo = sText.Length - 1; cp <= loopTo; cp++)
                {
                    ch = sText[cp];
                    if (bEscapeChar == true)
                    {
                        bEscapeChar = false;
                    }
                    else if (bInsideString == true)
                    {
                        if (ch == cInsideStringChar)
                        {
                            bInsideString = false;
                        }
                    }
                    else if (ch == '"') // Or ch = "'"c
                    {
                        bInsideString = true;
                        cInsideStringChar = ch;
                    }
                    else if (ch == '{')
                    {
                        if (iBracketDepth == 0)
                        {
                            l = cp - sp;
                            if (l > 0)
                            {
                                string argsText2 = sText.Substring(sp, l);
                                AddArrayItem(oList, argsText2, Conversions.ToBoolean(Interaction.IIf(oList.Count > 0, bTreatUnderscoreAsSpace, false)));
                            }

                            sp = cp;
                        }

                        iBracketDepth += 1;
                    }
                    else if (ch == '}')
                    {
                        iBracketDepth -= 1;
                        if (iBracketDepth == 0)
                        {
                            l = cp - sp;
                            if (l > 0)
                            {
                                string argsText1 = sText.Substring(sp + 1, l - 1);
                                AddArrayItem(oList, argsText1, Conversions.ToBoolean(Interaction.IIf(oList.Count > 0, bTreatUnderscoreAsSpace, false)));
                            }
                            else
                            {
                                var tempVar = string.Empty;
                                AddArrayItem(oList, tempVar);
                            }

                            sp = cp + 1;
                        }
                    }
                    else if (ch == ' ')
                    {
                        if (iBracketDepth == 0)
                        {
                            l = cp - sp;
                            if (l > 0)
                            {
                                string argsText = sText.Substring(sp, l);
                                AddArrayItem(oList, argsText, Conversions.ToBoolean(Interaction.IIf(oList.Count > 0, bTreatUnderscoreAsSpace, false)));
                            }

                            sp = cp + 1;
                        }
                    }
                    else if (ch == '\\')
                    {
                        bEscapeChar = true;
                    }
                }

                l = sText.Length - sp;
                if (l > 0)
                {
                    string argsText3 = sText.Substring(sp, l);
                    AddArrayItem(oList, argsText3, Conversions.ToBoolean(Interaction.IIf(oList.Count > 0, bTreatUnderscoreAsSpace, false)));
                }
            }
            catch (Exception)
            {
                throw new Exception("Invalid string in Parse Arguments: " + sText);
            }

            return oList;
        }

        // VERBATIM copy of GenieClient.Utility.AddArrayItem (Utility/Utility.cs:494).
        public static void AddArrayItem(ArrayList oList, string sText, bool bTreatUnderscoreAsSpace = false)
        {
            if (sText.StartsWith("\""))
            {
                if (sText.EndsWith("\""))
                {
                    sText = sText.Substring(1, sText.Length - 2);
                }
            }

            if (sText.StartsWith("'"))
            {
                if (sText.EndsWith("'"))
                {
                    sText = sText.Substring(1, sText.Length - 2);
                }
            }

            if (bTreatUnderscoreAsSpace && sText.Contains("_"))
            {
                sText = sText.Replace("_", " ");
            }

            oList.Add(sText);
        }
    }
}

namespace GenieClient.Genie
{
    // Eval takes a Globals and only ever reads VariableList.ContainsKey(name).
    public class Globals
    {
        public Hashtable VariableList = new Hashtable();
    }
}
