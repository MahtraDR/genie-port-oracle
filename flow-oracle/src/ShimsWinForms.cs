// SHIMS for Windows-only framework types that Genie4's script-path files merely
// *mention* (types in signatures/fields, UI side effects). None of these carry
// script semantics. Kept deliberately tiny: compile surface + inert behaviour.
using System;
using System.Collections.Generic;

namespace System.Windows.Forms
{
    // Genie4 KeyCode.cs mirrors the WinForms Keys values in its own KeyCode.Keys enum;
    // reuse that table so name<->value conversions stay identical.
    public enum Keys
    {
        None = 0,
    }

    public class KeysConverter
    {
        public object ConvertFromString(string s)
        {
            // Inert approximation (macros are not part of script flow): resolve via Genie's
            // own KeyCode.Keys names ("F1", "Control+F1" not supported -> None).
            if (Enum.TryParse(typeof(GenieClient.Genie.KeyCode.Keys), s, true, out var v)) return (int)v;
            throw new ArgumentException("bad key " + s);
        }
    }

    public static class Application
    {
        public static void Exit() { }
        public static string StartupPath => AppContext.BaseDirectory;
        public static string ProductName => "Genie";
    }

    public class Form { }
}

namespace System.Drawing
{
    public enum FontStyle { Regular = 0, Bold = 1, Italic = 2, Underline = 4, Strikeout = 8 }
    public enum GraphicsUnit { World, Display, Pixel, Point, Inch, Document, Millimeter }

    public class Font
    {
        public string Name; public float Size; public FontStyle Style;
        public Font(string family, float size, FontStyle style = FontStyle.Regular) { Name = family; Size = size; Style = style; }
        public Font(string family, float size, FontStyle style, GraphicsUnit unit) : this(family, size, style) { }
        public Font(Font f, FontStyle style) : this(f.Name, f.Size, style) { }
        public bool Bold => (Style & FontStyle.Bold) != 0;
        public bool Italic => (Style & FontStyle.Italic) != 0;
        public float SizeInPoints => Size;
        public FontFamily FontFamily => new FontFamily(Name);
    }

    public class FontFamily { public string Name; public FontFamily(string n) { Name = n; } }

    public class Image : IDisposable
    {
        public int Width, Height;
        public static Image FromFile(string f) => new Image();
        public void Dispose() { }
    }

    public class Bitmap : Image
    {
        public Bitmap(Image i, Size s) { Width = s.Width; Height = s.Height; }
    }
}

namespace GeniePlugin.Plugins
{
    // C# mirror of Genie4 Plugin/IPlugin.vb + IHost.vb (VB project not buildable here).
    public interface IHost
    {
        void EchoText(string Text);
        void SendText(string Text);
        string get_Variable(string Var);
        void set_Variable(string Var, string value);
        System.Windows.Forms.Form ParentForm { get; }
        bool get_IsVerified(string key);
        bool get_IsPremium(string key);
        int InterfaceVersion { get; }
        string PluginKey { get; set; }
    }

    public interface IPlugin
    {
        string Name { get; }
        string Version { get; }
        string Description { get; }
        string Author { get; }
        void Initialize(IHost Host);
        void Show();
        void VariableChanged(string Variable);
        string ParseText(string Text, string Window);
        string ParseInput(string Text);
        void ParseXML(string XML);
        bool Enabled { get; set; }
        void ParentClosing();
    }
}
