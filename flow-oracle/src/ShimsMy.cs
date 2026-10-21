// SHIM for the VB "My" namespace (My.MyProject.Application.Info) that Genie4 uses only
// to stamp $client / $version and the FE connect string.
namespace GenieClient.My
{
    internal static class MyProject
    {
        internal static readonly MyApplication Application = new MyApplication();
        internal static readonly MyForms Forms = new MyForms();
    }
    internal sealed class MyApplication { public readonly AppInfo Info = new AppInfo(); }
    internal sealed class AppInfo
    {
#if GENIE_REMIX
        // Remix: WindowsFormsApplicationBase.Info.Version = AssemblyVersion = $(VersionPrefix).0
        // (Genie4_Remix/Directory.Build.props: VersionPrefix 4.2.4). Matches a real v4.2.4 settings.cfg
        // connectstring "/VERSION:4.2.4.0".
        public System.Version Version = new System.Version(4, 2, 4, 0);
#else
        public System.Version Version = new System.Version(4, 5, 0, 3); // Genie4.csproj ApplicationVersion
#endif
#if GENIE_REMIX
        // Remix: Info.ProductName = the assembly's AssemblyProduct = Genie4.csproj <Product>Genie Remix
        // Client 4</Product> (Genie4.csproj:50 R) -> $client (Globals.cs:890 R). (WP10 fix: was "Genie".)
        public string ProductName = "Genie Remix Client 4";
#else
        public string ProductName = "Genie";
#endif
    }
    internal sealed class MyForms { }
}
