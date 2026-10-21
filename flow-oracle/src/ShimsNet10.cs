// SHIMS for .NET 9/10 BCL APIs that Genie4 Remix (net10.0-windows) uses in linked files, so the
// legacy net8.0 build (GENIE_TFM=net8.0) can compile them; the net10.0 build (the default) uses the
// real BCL types. Same namespace-shadowing trick as ShimsClock.cs: these live in namespace
// GenieClient, which C# searches before the file's `using` imports.
#if GENIE_REMIX && !NET9_0_OR_GREATER
namespace GenieClient
{
    // System.Security.Cryptography.X509Certificates.X509CertificateLoader is .NET 9+.
    // Used only by Utility.ValidateServerCertificate (Utility.cs:150 R), i.e. the TLS login path,
    // which genieflow never exercises. Same bytes -> same certificate as the pre-9 constructor.
    internal static class X509CertificateLoader
    {
        public static System.Security.Cryptography.X509Certificates.X509Certificate2 LoadCertificate(byte[] data)
            => new System.Security.Cryptography.X509Certificates.X509Certificate2(data);
    }
}
#endif
