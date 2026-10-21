// Host = headless stand-in for Forms/FormMain.cs: the glue that owns the script list,
// routes Game/Command/Script events, and runs the 10 ms UI timer tick. FormMain.cs itself
// is unlinkable (8-9k lines of WinForms), so each method below is a TRANSCRIPTION of the
// cited FormMain.cs method with only UI side effects removed. Everything it calls
// (Script, Command, Game, Globals, ScriptList, CommandQueue, Events) is REAL Genie code,
// linked verbatim from the selected tree.
//
// TWO TREES. Citations are "R:<line>" = $GENIE_REMIX_SRC/Forms/FormMain.cs (v4.2.4,
// the parity target) and "U:<line>" = $GENIE_UPSTREAM_SRC/Forms/FormMain.cs (4.5.0.3).
// The build defines GENIE_REMIX or GENIE_UPSTREAM (Directory.Build.props / genieflow.csproj);
// where the two FormMains differ, both bodies are kept under #if.
//
// Threading model (deterministic, single OS thread):
//   * "socket context"  = what Genie runs on the Connection receive thread:
//       Game.ParseGameRow -> prompt/move/roundtime events, variable changes, TriggerParse, and
//       EndUpdate (Connection.DataRecieveEnd).
//       UPSTREAM: FormMain's InvokeRequired is TRUE there, so variable-change notifications are
//         ENQUEUED (U:4808-4819 ClassCommand_EventVariableChanged) and delivered at the next tick
//         (U:2885 DrainPendingVariableChanges, called first in U:7983). Game text reaches
//         ParseTriggers synchronously (U:6284-6288 Game_EventTriggerParse).
//       REMIX: there is no queue (DrainPendingVariableChanges is deleted); variable changes run
//         TriggerVariableChanged SYNCHRONOUSLY on the socket thread (R:5045-5050). Game text is
//         written to an unbounded Channel (R:6592-6596) drained by ONE thread-pool consumer that
//         calls ParseTriggers (R:141-152 StartTriggerConsumer). Its timing relative to the socket
//         thread is a real race; see TriggerDelivery below.
//   * "UI context"      = TimerBgWorker_Tick (R:8313 / U:7975, Interval=10 ms per
//       FormMain.Designer.cs:1409 R / :1361 U) and user input. InvokeRequired is FALSE.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using GenieClient;
using GenieClient.Genie;
using Microsoft.VisualBasic;
using Microsoft.VisualBasic.CompilerServices;

namespace GenieFlow
{
    // How game text reaches ParseTriggers (scripts' match/waitfor/action + global #triggers).
    //   Sync  : inline, inside ParseGameRow (upstream U:6284; the only upstream behaviour).
    //   Row   : REMIX, consumer keeps up: the channel is drained after each socket row has been
    //           fully processed (so that row's prompt/roundtime/variable events precede it) and
    //           before the chunk's EndUpdate. Default for the Remix build.
    //   Chunk : REMIX, consumer loses the race: the channel is drained only AFTER the chunk's
    //           EndUpdate has run Script.SetBufferEnd. A match then calls SetBufferWait
    //           (Script.cs:2098-2104 R) AFTER the buffer end, so the script does not resume until
    //           the NEXT socket chunk ends.
    public enum TriggerDelivery { Sync, Row, Chunk }

    public sealed class Host
    {
        public Globals G;
        public Game GameObj;
        public Command Cmd;
        private Globals _g; // ref target for Game/Command ctors

        private readonly ScriptList m_oScriptList = new ScriptList();
        private readonly ScriptList m_oScriptListNew = new ScriptList();
        private readonly Dictionary<string, string> m_oScriptNames = new Dictionary<string, string>();
        private readonly HashSet<string> m_oFinished = new HashSet<string>();
        private bool m_bScriptListUpdated = false;
        private bool m_bTriggersEnabled = true;
#if GENIE_UPSTREAM
        private readonly Queue<string> m_oPendingVariableChanges = new Queue<string>();
        private int m_iTriggerVariableChangedDepth = 0;
        private bool m_bParseTriggers = false;
#else
        // R:343 _triggerChannel (Channel<string>, SingleReader). Modelled as a FIFO.
        private readonly Queue<string> m_oTriggerChannel = new Queue<string>();
        // Remix has NO re-entrancy guard in ParseTriggers (R:4425) or TriggerVariableChanged
        // (R:4725) and no depth guard in Command.ParseCommand (removed vs Command.cs:221 U). A
        // self-feeding trigger therefore recurses until the .NET stack overflows, which kills the
        // process (StackOverflowException cannot be caught). genieflow cannot overflow for real, so
        // it stops at this depth, emits "genie-crash", and halts the run. NOT Genie code.
        private const int RemixRecursionCap = 200;
        private int m_iParseTriggersDepth = 0;
        private int m_iTriggerVariableChangedDepth = 0;
#endif
        public TriggerDelivery Delivery =
#if GENIE_REMIX
            TriggerDelivery.Row;
#else
            TriggerDelivery.Sync;
#endif
        public bool Crashed; // Remix stack-overflow model (see RemixRecursionCap)

        public bool SocketContext; // see header
        public readonly EventSink Out;
        public bool VerboseGameVars;
        public bool TraceIn = true;

        public Host(EventSink sink)
        {
            Out = sink;
            _g = new Globals();
            G = _g;
            GameObj = new Game(ref _g);
            Cmd = new Command(ref _g);

            // Game wiring (R:420-440 / U:417-434)
            GameObj.EventVariableChanged += v => ClassCommand_EventVariableChanged(v, "game");
            GameObj.EventPrintError += t => Out.Emit("game-error", ("text", Clean(t)));
            GameObj.EventDataRecieveEnd += Simutronics_EventEndUpdate;
            GameObj.EventTriggerParse += Game_EventTriggerParse;
            GameObj.EventRoundTime += SetRoundTime; // Game_EventRoundtime -> Invoke(SetRoundTime) (R:6725-6731 / U:6416-6422): synchronous
            // Game_EventSpellTime / Game_EventClearSpellTime -> Invoke(SetSpellTime / ClearSpellTime)
            // (R:6653-6695 / U:6346-6388): synchronous. Added 2026-10-19 (WP5) so the spell
            // specials (@spelltime@ ..., Globals.cs:206-222) and $spellstarttime are exercised.
            GameObj.EventSpellTime += SetSpellTime;
            GameObj.EventClearSpellTime += ClearSpellTime;
            GameObj.EventTriggerPrompt += Game_EventTriggerPrompt;
            GameObj.EventTriggerMove += Game_EventTriggerMove;
            GameObj.EventPrintText += (text, c, bg, target, sTarget, mono, prompt, input) =>
            {
                if (VerboseGameVars) Out.Emit("game-print", ("text", Clean(text)), ("window", target.ToString()));
                // Simutronics_EventPrintText -> AddText(WindowTarget) (R:5596-5600, 5142-5239 / U:5378,
                // 4911): the default arm (Unknown, Main) is the main window.
                if (IsMainWindowTarget(target)) AddTextToMain(text, prompt, input);
            };

            // Command wiring (R:512-558 / U:512-551) -- only script-relevant events.
            Cmd.EventEchoText += (t, w) => { Out.Emit("cmdecho", ("text", Clean(t)), ("window", w ?? "")); EchoToMain(t, w); };
            Cmd.EventEchoColorText += (t, c, bg, w) => { Out.Emit("cmdecho", ("text", Clean(t)), ("window", w ?? ""), ("color", c.Name)); EchoToMain(t, w); };
            Cmd.EventLinkText += (t, l, w) => Out.Emit("cmdlink", ("text", t), ("link", l), ("window", w ?? ""));
            Cmd.EventSendText += ClassCommand_SendText;
            Cmd.EventSendRaw += t => Out.Emit("sendraw", ("text", t));
            Cmd.EventRunScript += ClassCommand_RunScript;
            Cmd.EventParseLine += ClassCommand_ParseText;
            Cmd.EventVariableChanged += v => ClassCommand_EventVariableChanged(v, "cmd");
            Cmd.EventScriptAbort += s => ForEachScript(s, true, sc => sc.AbortScript());           // R:5783 / U:5561
            Cmd.EventScriptPause += s => ForEachScript(s, true, sc => sc.PauseScript());           // R:5845 / U:5623
            Cmd.EventScriptResume += s => ForEachScript(s, true, sc => sc.ResumeScript());         // R:6022 / U:5800
            Cmd.EventScriptPauseOrResume += s => ForEachScript(s, true, sc => { if (sc.ScriptPaused) sc.ResumeScript(); else sc.PauseScript(); }); // R:5906 / U:5684
            Cmd.EventScriptReload += s => ForEachScript(s, false, sc => sc.ReloadScript());        // R:5973 / U:5751
            Cmd.EventScriptDebug += Command_ScriptDebugLevel;
            Cmd.EventScriptTrace += s => Out.Emit("cmd-unsupported", ("what", "#script trace " + s));
            Cmd.EventScriptVariables += (s, f) => Command_ScriptVariables(s, f);
            Cmd.EventClassChange += Command_EventClassChange;
            Cmd.EventListScripts += f => Out.Emit("cmd-unsupported", ("what", "#script list " + f));
            Cmd.EventMapperCommand += c => Out.Emit("mapper", ("cmd", c));
            Cmd.EventStatusBar += (t, i) => { };
            Cmd.EventConnect += (a, p, c, gm, l) => Out.Emit("cmd-unsupported", ("what", "#connect"));
            Cmd.EventDisconnect += () => Out.Emit("cmd-unsupported", ("what", "#disconnect"));
            Cmd.EventExit += () => Out.Emit("cmd-unsupported", ("what", "#exit"));

            GenieError.EventGenieError += (section, msg, desc) => Out.Emit("genie-exception", ("section", section), ("message", msg));
        }

        public static string Clean(string s) => s == null ? "" : Utility.Trim(s);

        // ---------------------------------------------------------------- the main window's prompt row
        // R:5084-5122 / U:4858-4896 AddText(FormSkin): the only part a script can observe is
        // Game.LastRowWasPrompt, which Game.cs reads at the next prompt (R:2397 / U:2312: no "> "
        // rewrite of $prompt and no PrintTextWithParse, so no TriggerParse of the prompt text, while
        // the last row printed to the main window was a prompt). Set by a prompt printed to main,
        // cleared by any other main-window text that is not blank after Trim -- game text, the
        // echo of every send (Game.PrintInputText, bInput), script echo/print/debug/errors and
        // #echo with no window. Display (colours, PromptBreak newline, the RichTextBox) removed.
        // Headless: the only window is main -- a text for any other WindowTarget (combat, thoughts,
        // a named stream ...) is never in main here, where Genie may redirect a CLOSED window's
        // text to its IfClosed target (R:5231-5235), which can be main (layout-dependent).
        private void AddTextToMain(string sText, bool bPrompt, bool bInput)
        {
            if (bPrompt == true)
            {
                if (GameObj.LastRowWasPrompt) return;
                GameObj.LastRowWasPrompt = true;
            }
            else if (sText.Trim().Length > 0)
            {
                if (GameObj.LastRowWasPrompt == true) GameObj.LastRowWasPrompt = false;
            }
        }

        // R:5142-5239 / U:4911-5014 AddText(WindowTarget): every named arm picks its own form; the
        // default arm (Unknown, Main; Raw arrives as Other) is m_oOutputMain.
        private static bool IsMainWindowTarget(Game.WindowTarget target)
        {
            switch (target)
            {
                case Game.WindowTarget.Death: case Game.WindowTarget.Familiar: case Game.WindowTarget.Inv:
                case Game.WindowTarget.Log: case Game.WindowTarget.Logons: case Game.WindowTarget.Room:
                case Game.WindowTarget.Thoughts: case Game.WindowTarget.Combat: case Game.WindowTarget.Portrait:
                case Game.WindowTarget.ActiveSpells: case Game.WindowTarget.Debug: case Game.WindowTarget.Other:
                    return false;
                default:
                    return true;
            }
        }

        // R:4229-4276, 4332-4372 / U:3948-3995, 4051-4091 ClassCommand_EchoText / EchoColorText: an
        // empty window is main ("mono " prefix stripped first); "game"/"main" or a named window
        // print nowhere headless (no such form; "game"/"main" print nowhere in Genie either).
        private void EchoToMain(string sText, string sWindow)
        {
            if ((sWindow ?? "").Length > 0) return;
            if (sText.ToLower().StartsWith("mono ")) sText = sText.Substring(5);
            AddTextToMain(sText, false, false);
        }

        public int LiveScriptCount
        {
            get
            {
                if (Crashed) return 0;
                int n = 0;
                foreach (Script s in m_oScriptList) if (!s.ScriptDone) n++;
                foreach (Script s in m_oScriptListNew) if (!s.ScriptDone) n++;
                return n;
            }
        }

        public IEnumerable<Script> AllScripts()
        {
            foreach (Script s in m_oScriptList) yield return s;
            foreach (Script s in m_oScriptListNew) yield return s;
        }

        private void Crash(string where)
        {
            if (Crashed) return;
            Crashed = true;
            Out.Emit("genie-crash", ("where", where), ("reason", "unbounded recursion: Remix has no re-entrancy/depth guard here; the real client overflows the stack and the process dies"), ("depth", RemixRecursionCapValue));
            Out.Frozen = true;
        }
#if GENIE_REMIX
        private static int RemixRecursionCapValue => RemixRecursionCap;
#else
        private static int RemixRecursionCapValue => 0;
#endif

        // ---------------------------------------------------------------- game input
        // One socket row (Connection.ParseData appends Environment.NewLine == "\r\n" on Windows
        // before raising EventParseRow -> Game.ParseRow -> ParseGameRow).
        public void FeedRow(string row)
        {
            if (Crashed) return;
            if (TraceIn) Out.Emit("in", ("text", row));
            SocketContext = true;
            try { GameObj.ParseGameRow(row + "\r\n"); }
            catch (Exception ex) { Out.Emit("host-exception", ("where", "ParseGameRow"), ("message", ex.Message)); }
            finally { SocketContext = false; }
            if (Delivery == TriggerDelivery.Row) DrainTriggerChannel();
        }

        // End of one socket receive (Connection.DataRecieveEnd -> Game.EventDataRecieveEnd).
        public void Flush()
        {
            if (Crashed) return;
            SocketContext = true;
            try { Simutronics_EventEndUpdate(); }
            finally { SocketContext = false; }
            if (Delivery != TriggerDelivery.Sync) DrainTriggerChannel();
        }

        // R:141-152 StartTriggerConsumer: await foreach (text in channel) { try { ParseTriggers(text); } catch ... }
        private void DrainTriggerChannel()
        {
#if GENIE_REMIX
            while (m_oTriggerChannel.Count > 0 && !Crashed)
            {
                string text = m_oTriggerChannel.Dequeue();
                try { ParseTriggers(text); }
                catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerConsumer"), ("message", ex.Message)); }
            }
#endif
        }

        // R:5620 / U:5398 Simutronics_EventEndUpdate (UI repaint removed)
        private void Simutronics_EventEndUpdate()
        {
            GameObj.SetBufferEnd();
            if (m_oScriptList.AcquireReaderLock())
            {
                try { foreach (Script oScript in m_oScriptList) oScript.SetBufferEnd(); }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:6592-6596 (channel write) / U:6284-6288 (inline ParseTriggers)
        private void Game_EventTriggerParse(string sText)
        {
#if GENIE_REMIX
            if (Delivery == TriggerDelivery.Sync)
            {
                try { ParseTriggers(sText); }
                catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerParse"), ("message", ex.Message)); }
                return;
            }
            m_oTriggerChannel.Enqueue(sText); // _triggerChannel.Writer.TryWrite(sText)
#else
            try { ParseTriggers(sText); }
            catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerParse"), ("message", ex.Message)); }
#endif
        }

        // R:6860 / U:6553
        private void Game_EventTriggerPrompt()
        {
            Out.Emit("prompt-event");
            if (m_oScriptList.AcquireReaderLock())
            {
                try { foreach (Script oScript in m_oScriptList) oScript.TriggerPrompt(); }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:6889 / U:6582
        private void Game_EventTriggerMove()
        {
            Out.Emit("move-event");
            if (m_oScriptList.AcquireReaderLock())
            {
                try { foreach (Script oScript in m_oScriptList) oScript.TriggerMove(); }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:6697-6701 / U:6389-6393 SetSpellTime (verbatim).
        private void SetSpellTime()
        {
            G.SpellTimeStart = GenieClient.DateTime.Now;
            G.VariableList["spellstarttime"] = ((System.DateTimeOffset)(System.DateTime)GenieClient.DateTime.Now).ToUnixTimeSeconds().ToString();
        }

        // R:6703-6707 / U:6395-6398 ClearSpellTime (cast bar removed).
        private void ClearSpellTime()
        {
            G.SpellTimeStart = default;
        }

        // R:6927 / U:6620 SetRoundTime (RT bar removed)
        public void SetRoundTime(int iTime)
        {
            if (iTime == 0) return;
            Out.Emit("roundtime-event", ("seconds", iTime));
            if (m_oScriptList.AcquireReaderLock())
            {
                try { foreach (Script oScript in m_oScriptList) oScript.SetRoundTime(iTime); }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
            G.RoundTimeEnd = GenieClient.DateTime.Now.AddMilliseconds(iTime * 1000 + G.Config.dRTOffset * 1000);
        }

        // R:6918 / U:6611
        private bool HasRoundTime => GenieClient.DateTime.Now < G.RoundTimeEnd;

        // ---------------------------------------------------------------- triggers
        // R:4425 / U:4146 ParseTriggers
        private void ParseTriggers(string sText, bool bBufferWait = true)
        {
            if (Crashed) return;
#if GENIE_UPSTREAM
            // U:4148-4171: re-entrancy guard; a nested #parse still reaches scripts.
            if (m_bParseTriggers)
            {
                if (!bBufferWait && sText.Trim().Length > 0 && m_oScriptList.AcquireReaderLock())
                {
                    try { foreach (Script oScript in m_oScriptList) oScript.TriggerParse(sText, false); }
                    catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerParse(#parse reentrant)"), ("message", ex.Message)); }
                    finally { m_oScriptList.ReleaseReaderLock(); }
                }
                return;
            }
            m_bParseTriggers = true;
#else
            // Remix: no guard (deleted). Recursion model only -- see RemixRecursionCap.
            if (m_iParseTriggersDepth >= RemixRecursionCap) { Crash("ParseTriggers (FormMain.cs:4425 R)"); return; }
            m_iParseTriggersDepth++;
#endif
            try
            {
                if (m_bTriggersEnabled == true && sText.Trim().Length > 0)
                {
                    if (G.TriggerList.AcquireReaderLock())
                    {
                        try
                        {
                            foreach (Globals.Triggers.Trigger oTrigger in G.TriggerList.Values)
                            {
                                if (Crashed) break;
                                if (oTrigger.IsActive && oTrigger.bIsEvalTrigger == false && !Information.IsNothing(oTrigger.oRegexTrigger))
                                {
                                    var m = oTrigger.oRegexTrigger.Match(sText);
                                    if (m.Success == true)
                                    {
                                        var RegExpArg = new GenieClient.Genie.Collections.ArrayList();
                                        for (int J = 1; J <= m.Groups.Count - 1; J++) RegExpArg.Add(m.Groups[J].Value);
                                        Out.Emit("trigger-fire", ("pattern", oTrigger.sTrigger), ("text", sText));
                                        TriggerAction(oTrigger.sAction, RegExpArg);
                                    }
                                }
                            }
                        }
                        catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerAction"), ("message", ex.Message)); }
                        finally { G.TriggerList.ReleaseReaderLock(); }
                    }

                    if (!Crashed && m_oScriptList.AcquireReaderLock())
                    {
                        try { foreach (Script oScript in m_oScriptList) oScript.TriggerParse(sText, bBufferWait); }
                        catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerParse"), ("message", ex.Message)); }
                        finally { m_oScriptList.ReleaseReaderLock(); }
                    }
                }
            }
#if GENIE_UPSTREAM
            finally { m_bParseTriggers = false; }
#else
            finally { m_iParseTriggersDepth--; }
#endif
        }

        // R:4615 / U:4369 TriggerAction (identical in both trees)
        private void TriggerAction(string sAction, GenieClient.Genie.Collections.ArrayList oArgs)
        {
            if (m_bTriggersEnabled != true || Crashed) return;
            if (sAction.Contains("$") == true)
            {
                for (int i = 0, loopTo = G.Config.iArgumentCount - 1; i <= loopTo; i++)
                {
                    if (i > oArgs.Count - 1) sAction = sAction.Replace("$" + (i + 1).ToString(), "");
                    else sAction = sAction.Replace("$" + (i + 1).ToString(), oArgs[i].ToString().Replace("\"", ""));
                }
                if (oArgs.Count > 0) sAction = sAction.Replace("$0", oArgs[0].ToString().Replace("\"", ""));
                else sAction = sAction.Replace("$0", string.Empty);
            }
            try { Cmd.ParseCommand(sAction, true, false, "Trigger"); }
            catch (Exception) { Out.Emit("error", ("text", "Trigger action failed: " + sAction), ("script", "")); }
        }

        // R:4659 / U:4413 ClassCommand_ParseText (#parse): synchronous, bBufferWait=false, in both.
        private void ClassCommand_ParseText(string sText)
        {
            if (sText.Trim().Length > 0) ParseTriggers(sText, false);
        }

        // ---------------------------------------------------------------- variables
        // R:5045 / U:4808 ClassCommand_EventVariableChanged
        private void ClassCommand_EventVariableChanged(string sVariable, string src)
        {
            if (Crashed) return;
            // Game.cs:549-551 R: raised right after m_oSocket.Send -- the send of the innermost frame.
            if (src == "game" && sVariable == "lastcommand" && m_oSendFrames.Count > 0) EmitSocketSend(m_oSendFrames.Peek());
            if (src != "game" || VerboseGameVars)
            {
                string key = sVariable.StartsWith("$") ? sVariable.Substring(1) : sVariable;
                string val = G.VariableList.ContainsKey(key) ? Conversions.ToString(G.VariableList[key]) : null;
                Out.Emit("var", ("name", sVariable), ("value", val), ("src", src));
            }
#if GENIE_UPSTREAM
            if (SocketContext) { m_oPendingVariableChanges.Enqueue(sVariable); return; } // U:4815-4819
#endif
            TriggerVariableChanged(sVariable); // R:5049: always synchronous, on the calling thread
        }

#if GENIE_UPSTREAM
        // U:2885 DrainPendingVariableChanges (called first in the tick, U:7983)
        private void DrainPendingVariableChanges()
        {
            while (m_oPendingVariableChanges.Count > 0)
            {
                string v = m_oPendingVariableChanges.Dequeue();
                try { TriggerVariableChanged(v); }
                catch (Exception ex) { Out.Emit("host-exception", ("where", "VariableChanged"), ("message", ex.Message)); }
            }
        }
#endif

        // R:4725 / U:4482 TriggerVariableChanged (UI bar/icon updates removed; control flow kept)
        public void TriggerVariableChanged(string sVariableName)
        {
            if (Crashed) return;
#if GENIE_UPSTREAM
            if (SocketContext) { m_oPendingVariableChanges.Enqueue(sVariableName); return; } // U:4484-4490
            if (m_iTriggerVariableChangedDepth >= 20) return;                                // U:4492
#else
            if (m_iTriggerVariableChangedDepth >= RemixRecursionCap) { Crash("TriggerVariableChanged (FormMain.cs:4725 R)"); return; }
#endif
            m_iTriggerVariableChangedDepth++;
            try
            {
                switch (sVariableName)
                {
                    case "compass":
                    case "$north": case "$northeast": case "$east": case "$southeast":
                    case "$south": case "$southwest": case "$west": case "$northwest":
                    case "$up": case "$down": case "$out":
                        return; // R:4793 / U:4563 "Block direction triggers"
                }

#if GENIE_UPSTREAM
                if (m_iTriggerVariableChangedDepth > 1) return; // U:4677 (deleted in Remix)
#endif

                if (m_bTriggersEnabled == true) // R:4922 / U:4679
                {
                    if (G.TriggerList.AcquireReaderLock())
                    {
                        try
                        {
                            foreach (Globals.Triggers.Trigger oTrigger in G.TriggerList.Values)
                            {
                                if (Crashed) break;
                                if (oTrigger.IsActive && oTrigger.bIsEvalTrigger == true && oTrigger.sTrigger.Contains(sVariableName))
                                {
                                    string s = "1";
                                    if ((oTrigger.sTrigger ?? "") != (sVariableName ?? ""))
                                    {
                                        string argsText = G.ParseGlobalVars(oTrigger.sTrigger);
                                        s = Cmd.Eval(argsText);
                                    }
                                    if (s.Length > 0 & (s ?? "") != "0")
                                    {
                                        Out.Emit("trigger-fire", ("pattern", oTrigger.sTrigger), ("var", sVariableName));
                                        TriggerAction(oTrigger.sAction, new GenieClient.Genie.Collections.ArrayList());
                                    }
                                }
                            }
                        }
                        finally { G.TriggerList.ReleaseReaderLock(); }
                    }

                    if (!Crashed && m_oScriptList.AcquireReaderLock())
                    {
                        try { foreach (Script oScript in m_oScriptList) oScript.TriggerVariableChanged(sVariableName); }
                        catch (Exception ex) { Out.Emit("host-exception", ("where", "TriggerVariableChange"), ("message", ex.Message)); }
                        finally { m_oScriptList.ReleaseReaderLock(); }
                    }
                }
            }
            finally { m_iTriggerVariableChangedDepth--; }
        }

        // ---------------------------------------------------------------- sending
        // The socket send of Game.SendText (Game.cs:545-552 R / the same lines in U), observed rather
        // than assumed (WPF, 2026-10-20): the headless Connection is never connected, so its Send is a
        // no-op, and the old Host emitted `send` BEFORE calling Game.SendText -- also for a text Game
        // never sends (the cMyCommandChar gate, '/' by default: Game.cs:467, 527, 545 R; an oracle blind
        // spot that hid a parity bug). Now Game.SendText runs inside a frame: m_oLastUserActivity
        // (assigned ONLY on the line right before m_oSocket.Send, Game.cs:546-547 R; Connect /
        // DirectConnect never run here) is reset to MinValue first, and the `send` event is emitted
        // when Game raises the "lastcommand" change right after the socket send (Game.cs:548-551 R),
        // before that change reaches any trigger -- so a capped $lastcommand chain (t51) still shows
        // every send. A frame per nesting level: a send fired from the $lastinput change of a typed
        // send (Game.cs:529-531 R) has its own frame and is emitted first, as the real socket order is.
        private sealed class SocketSendFrame
        {
            public readonly string Text, Origin;
            public readonly bool User;
            public bool Emitted;
            public SocketSendFrame(string text, string origin, bool user) { Text = text; Origin = origin; User = user; }
        }
        private readonly Stack<SocketSendFrame> m_oSendFrames = new Stack<SocketSendFrame>();
        private static readonly FieldInfo LastUserActivity =
            typeof(Game).GetField("m_oLastUserActivity", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingFieldException("Game", "m_oLastUserActivity");

        // Emits the frame's `send` once, iff Game.cs:546-548 ran for it.
        private void EmitSocketSend(SocketSendFrame frame)
        {
            if (frame == null || frame.Emitted) return;
            if (((GenieClient.DateTime)LastUserActivity.GetValue(GameObj)).Equals(GenieClient.DateTime.MinValue)) return;
            frame.Emitted = true;
            Out.Emit("send", ("text", frame.Text), ("origin", frame.Origin), ("user", frame.User));
        }

        // R:4391 / U:4110 ClassCommand_SendText (identical apart from Remix's m_CommandSent flag)
        private void ClassCommand_SendText(string sText, bool bUserInput, string sOrigin)
        {
            if (Crashed) return;
            try
            {
                sText = sText.Replace(@"\@", "¤");
                if (sText.Contains(@"\x") | sText.Contains("@"))
                {
                    // SendTextInputBox -> ParseInputBox (R:4378,1159 / U:4097,1151): text goes to the
                    // input box for the user to finish; NOTHING is sent to the game.
                    Out.Emit("inputbox", ("text", sText), ("origin", sOrigin));
                }
                else
                {
                    sText = sText.Replace("¤", "@");
                    // SafeParsePluginInput: no plugins loaded -> identity.
                    if (sText.Length > 0)
                    {
                        // REAL: sets $lastcommand / $lastinput. The `send` event is emitted from inside
                        // it, at the socket send (SocketSendFrame below) -- never for a mycommandchar
                        // text ('/sort', Game.cs:545 R), which the real client echoes but does not send.
                        var frame = new SocketSendFrame(sText, sOrigin, bUserInput);
                        m_oSendFrames.Push(frame);
                        LastUserActivity.SetValue(GameObj, GenieClient.DateTime.MinValue);
                        try { GameObj.SendText(sText, bUserInput, sOrigin); }
                        finally { m_oSendFrames.Pop(); }
                        EmitSocketSend(frame); // a socket send no "lastcommand" change reported (none today)
                        if (G.Config.bTriggerOnInput == true) ParseTriggers(sText); // synchronous in both trees (not via the channel)
                    }
                }
            }
            catch (Exception ex) { Out.Emit("host-exception", ("where", "SendText"), ("message", ex.Message)); }
        }

        // R:6812 / U:6503 Script_EventSendText
        private void Script_EventSendText(string Text, string ScriptName, bool ToQueue, bool DoCommand)
        {
            if (Crashed) return;
            try
            {
                bool bSendText = true;
                if (Text.StartsWith(Conversions.ToString(G.Config.cCommandChar))) bSendText = false;
                if (!ToQueue)
                {
                    var pcTask = Cmd.ParseCommand(Text, bSendText, false, ScriptName);
#if GENIE_UPSTREAM
                    if (pcTask.IsFaulted) // U:6514-6516 reports it
                        Out.Emit("host-exception", ("where", "Script_ParseCommand"), ("message", pcTask.Exception?.InnerException?.Message ?? "fault"));
#else
                    // R:6823 discards the Task: a fault is silently lost. Bookkeeping event only.
                    if (pcTask.IsFaulted)
                        Out.Emit("swallowed-fault", ("where", "Script_ParseCommand"), ("message", pcTask.Exception?.InnerException?.Message ?? "fault"));
#endif
                }
                else
                {
                    int iPauseTime = 0;
                    string sNumber = string.Empty;
                    foreach (char c in Text.ToCharArray())
                    {
                        if (Information.IsNumeric(c) | c == '.') sNumber += Conversions.ToString(c);
                        else break;
                    }
                    if (sNumber.Length > 0 & (sNumber ?? "") != ".")
                    {
                        Text = Text.Substring(sNumber.Length).Trim();
                        iPauseTime = int.Parse(sNumber);
                    }
                    double argdDelay = iPauseTime;
                    string argsAction = G.ParseGlobalVars(Text);
                    Out.Emit("queue", ("text", argsAction), ("delay", argdDelay), ("script", ScriptName));
                    G.CommandQueue.AddToQueue(argdDelay, argsAction, true, DoCommand, DoCommand);
                }
            }
            catch (Exception ex) { Out.Emit("host-exception", ("where", "Script_SendText"), ("message", ex.Message)); }
        }

        // R:3857 / U:3576 RunQueueCommand
        private void RunQueueCommand(string sAction, string sOrigin)
        {
            if (sAction.Length > 0 && !Crashed) Cmd.ParseCommand(sAction, true, false, sOrigin);
        }

        // User typing into the input box (R:4216 / U:3935 -> m_oCommand.ParseCommand(text, true, true)).
        public void UserInput(string text)
        {
            if (Crashed) return;
            Out.Emit("input", ("text", text));
            Cmd.ParseCommand(text, true, true);
        }

        // ---------------------------------------------------------------- scripts
        // R:4678 / U:4432 ClassCommand_RunScript (identical)
        private void ClassCommand_RunScript(string sText)
        {
            try
            {
                var al = Utility.ParseArgs(sText, true);
                string ScriptName = Conversions.ToString(al[0].ToString().ToLower().Trim().Substring(1));
                if (ScriptName.EndsWith($".{G.Config.ScriptExtension}") == false) ScriptName += $".{G.Config.ScriptExtension}";
                Script oScript = null;
                if (m_oScriptListNew.AcquireWriterLock())
                {
                    try
                    {
                        oScript = LoadScript(ScriptName, al);
                        if (!Information.IsNothing(oScript)) m_oScriptListNew.Add(oScript);
                    }
                    finally { m_oScriptListNew.ReleaseWriterLock(); }
                }
                else Out.Emit("host-exception", ("where", "RunScript"), ("message", "Unable to aquire writer lock."));

                if (!Information.IsNothing(oScript)) oScript.RunScript();
            }
            catch (Exception ex) { Out.Emit("host-exception", ("where", "RunScript"), ("message", ex.Message)); }
        }

        // R:3401 / U:3121 LoadScript (abort-dupe identical; upstream's per-script
        // GenieError.EventGenieError += HandleGenieException (U:3154) is UI-only and dropped)
        private Script LoadScript(string sScriptName, ArrayList oArgList)
        {
            if (G.Config.bAbortDupeScript == true)
            {
                if (m_oScriptList.AcquireReaderLock())
                {
                    try
                    {
                        foreach (Script oThisScript in m_oScriptList)
                            if ((oThisScript.FileName ?? "") == (sScriptName ?? "")) oThisScript.AbortScript();
                    }
                    finally { m_oScriptList.ReleaseReaderLock(); }
                }
            }

            var oScript = new Script(G);
            string id = oScript.ScriptID;
            // R:5668-5676 / U:5446-5454 Script_EventPrintError -> AddText(WindowTarget.Main)
            oScript.EventPrintError += t => { Out.Emit("error", ("text", Clean(t)), ("script", NameOf(id))); AddTextToMain(t, false, false); };
#if GENIE_REMIX
            oScript.EventPrintText += (t, c, bg) => Script_EventPrintText(id, t, c);
#else
            oScript.EventPrintText += (t, c, bg, target) => Script_EventPrintText(id, t, c, target);
#endif
            oScript.EventSendText += Script_EventSendText;
            oScript.EventStatusChanged += (s, st) =>
            {
                m_bScriptListUpdated = true; // R:3483 / U:3204
                if (st == Script.ScriptState.finished && m_oFinished.Add(s.ScriptID))
                    Out.Emit("script-finish", ("script", NameOf(s.ScriptID)));
                else if (st == Script.ScriptState.pausing) Out.Emit("script-pause", ("script", NameOf(s.ScriptID)));
                else if (st == Script.ScriptState.running) Out.Emit("script-resume", ("script", NameOf(s.ScriptID)));
            };
            m_oScriptNames[id] = Path.GetFileNameWithoutExtension(sScriptName);
            var args = new List<string>();
            for (int i = 1; i < oArgList.Count; i++) args.Add(oArgList[i].ToString());
            Out.Emit("script-start", ("script", m_oScriptNames[id]), ("args", string.Join(" ", args)));
            if (oScript.LoadFile(sScriptName, oArgList) == true) return oScript;
            if (m_oFinished.Add(id)) Out.Emit("script-finish", ("script", m_oScriptNames[id]), ("loadfailed", true));
            return null;
        }

        private string NameOf(string id) => m_oScriptNames.TryGetValue(id, out var n) ? n : "?";

#if GENIE_REMIX
        // R:5611-5614 Script_EventPrintText(sText, oColor, oBgColor): Remix's delegate has NO window
        // target (Script.cs:631 R) and AddText always goes to WindowTarget.Main, so script DEBUG
        // output lands in the MAIN window (upstream routes it to the Debug window). Classified by
        // the call-site colours in Script.cs R: PrintDebug = Color.RoyalBlue (4420/4424),
        // PrintEcho = PresetList["scriptecho"].FgColor, PrintText = White.
        private void Script_EventPrintText(string id, string t, Color c)
        {
            string kind = c == Color.RoyalBlue ? "debug"
                : c == G.PresetList["scriptecho"].FgColor ? "echo" : "print";
            Out.Emit(kind, ("text", Clean(t)), ("script", NameOf(id)));
            AddTextToMain(t, false, false);
        }
#else
        // U:5393 Script_EventPrintText -> AddText. Classified by the exact call-site
        // colours in Script.cs U: PrintEcho = PresetList["scriptecho"].FgColor (4382),
        // PrintDebug = RoyalBlue/WindowTarget.Debug (4366), PrintText = White (4377).
        private void Script_EventPrintText(string id, string t, Color c, Game.WindowTarget target)
        {
            string kind = target == Game.WindowTarget.Debug ? "debug"
                : c == G.PresetList["scriptecho"].FgColor ? "echo" : "print";
            Out.Emit(kind, ("text", Clean(t)), ("script", NameOf(id)));
            if (IsMainWindowTarget(target)) AddTextToMain(t, false, false);
        }
#endif

        private void ForEachScript(string sScript, bool bExcept, Action<Script> act)
        {
            // R:5783 ff / U:5561 ff Command_ScriptAbort et al (identical): "<name>|all [except <name>]"
            string sExcept = string.Empty;
            if (bExcept)
            {
                int I = sScript.ToLower().IndexOf("except ");
                if (I > 0) { sExcept = sScript.Substring(I + 7); sScript = sScript.Substring(0, I).TrimEnd(); }
            }
            sScript += " ";
            if (sScript.ToLower().StartsWith("all ")) sScript = string.Empty; else sScript = sScript.Trim();
            if (m_oScriptList.AcquireReaderLock())
            {
                try
                {
                    foreach (Script oScript in m_oScriptList)
                    {
                        if (oScript.ScriptName.Length > 0)
                            if (sScript.Length == 0 | (oScript.ScriptName ?? "") == (sScript ?? ""))
                                if (sExcept.Length == 0 | (oScript.ScriptName ?? "") != (sExcept ?? ""))
                                    act(oScript);
                    }
                }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:6083 / U:5861
        private void Command_ScriptDebugLevel(int iDebugLevel, string sScript)
        {
            if ((sScript.ToLower() ?? "") == "all") sScript = string.Empty;
            if (m_oScriptList.AcquireReaderLock())
            {
                try
                {
                    foreach (Script oScript in m_oScriptList)
                        if (oScript.ScriptName.Length > 0 && (sScript.Length == 0 | (oScript.ScriptName ?? "") == (sScript ?? "")))
                            oScript.DebugLevel = iDebugLevel;
                }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:5678 / U:5456 (display only; dumped as an event)
        private void Command_ScriptVariables(string sScript, string sFilter)
        {
            foreach (Script s in m_oScriptList)
                if (sScript == "all" || s.ScriptName == sScript)
                    Out.Emit("script-vars", ("script", s.ScriptName), ("vars", s.VariableList));
        }

        // R:7483 / U:7163 Command_EventClassChange (identical; highlights are display-only and dropped;
        // the sub/gag toggles are kept since WP10-r1 parity 8a: they gate PrintTextToWindow's gag and
        // ParseSubstitutions, which decide m_bLastRowWasPrompt -- R:7510-7514 / U:7194-7197)
        private void Command_EventClassChange()
        {
            var al = new ArrayList();
            if (G.ClassList.AcquireReaderLock())
            {
                try { foreach (object key in G.ClassList.Keys) al.Add(key); }
                finally
                {
                    G.ClassList.ReleaseReaderLock();
                    foreach (string k in al)
                    {
                        var key = k;
                        bool bState = bool.Parse(Conversions.ToString(G.ClassList[key]));
                        if ((key ?? "") == "default") key = "";
                        G.TriggerList.ToggleClass(key, bState);
                        G.SubstituteList.ToggleClass(key, bState); // R:7510-7511
                        G.GagList.ToggleClass(key, bState);        // R:7513-7514
                    }
                }
            }
        }

        // ---------------------------------------------------------------- the tick
        // R:8313 / U:7975 TimerBgWorker_Tick
        public void Tick()
        {
            if (Crashed) return;
            SocketContext = false;
#if GENIE_UPSTREAM
            DrainPendingVariableChanges(); // U:7983 (deleted in Remix)
#endif
            string argsAction = G.Events.Poll();
            RunQueueCommand(argsAction, "");
            string sCommandQueue = G.CommandQueue.Poll(HasRoundTime, G.VariableList["webbed"].ToString() == "1", G.VariableList["stunned"].ToString() == "1");
            while (sCommandQueue.Length > 0 && !Crashed)
            {
                RunQueueCommand(sCommandQueue, "");
                sCommandQueue = G.CommandQueue.Poll(HasRoundTime, G.VariableList["webbed"].ToString() == "1", G.VariableList["stunned"].ToString() == "1");
            }

            TickScripts();
            AddScripts();
            RemoveExitedScripts();
            if (m_bScriptListUpdated) SetScriptListVariable();
        }

        // R:3185 / U:2905
        private void TickScripts()
        {
            if (m_oScriptList.AcquireReaderLock())
            {
                try { foreach (Script oScript in m_oScriptList) { if (Crashed) break; oScript.TickScript(); } }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }

        // R:3809 / U:3528 AddScripts
        private void AddScripts()
        {
            if (m_oScriptListNew.Count == 0) return;
            m_oScriptList.AcquireWriterLock();
            try
            {
                m_oScriptListNew.AcquireWriterLock();
                try
                {
                    foreach (Script oScript in m_oScriptListNew)
                        if (!Information.IsNothing(oScript)) { m_oScriptList.Add(oScript); m_bScriptListUpdated = true; }
                    m_oScriptListNew.Clear();
                }
                finally { m_oScriptListNew.ReleaseWriterLock(); }
            }
            finally { m_oScriptList.ReleaseWriterLock(); }
        }

        // R:3229 / U:2949
        private void RemoveExitedScripts()
        {
            var removeList = new List<int>();
            if (m_oScriptList.AcquireReaderLock())
            {
                try { for (var i = 0; i < m_oScriptList.Count; i++) if (m_oScriptList[i].ScriptDone) removeList.Add(i); }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
            if (removeList.Count > 0 && m_oScriptList.AcquireWriterLock())
            {
                try { for (var i = removeList.Count - 1; i > -1; i--) m_oScriptList.RemoveAt(removeList[i]); }
                finally { m_oScriptList.ReleaseWriterLock(); }
            }
        }

        // R:4516 / U:4270
        private void SetScriptListVariable()
        {
            if (m_oScriptList.AcquireReaderLock())
            {
                try
                {
                    string sScriptList = string.Empty;
                    foreach (Script oScript in m_oScriptList)
                    {
                        if (!Information.IsNothing(oScript) && !oScript.ScriptDone)
                        {
                            if (sScriptList.Length > 0) sScriptList += "|";
                            sScriptList += Path.GetFileNameWithoutExtension(oScript.FileName);
                        }
                    }
                    if (sScriptList.Length == 0) sScriptList = "none";
                    G.VariableList["scriptlist"] = sScriptList;
                    TriggerVariableChanged("scriptlist");
                    m_bScriptListUpdated = false;
                }
                finally { m_oScriptList.ReleaseReaderLock(); }
            }
        }
    }
}
