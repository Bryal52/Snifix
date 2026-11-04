using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Snifix.Core;

/// The CA key file (PFX) is encrypted with a random password that only this Windows user can read (DPAPI).
static class KeyVault
{
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Snifix CA key");

    /// Returns the PFX password; moves an old PFX without a password over to an encrypted one.
    /// true means the root certificate is already loaded into the PFX on disk and must be loaded from it.
    public static bool PreparePfx(string directory, string pfxPath, out string password)
    {
        password = "";
        if (!OperatingSystem.IsWindows()) return false;
        var secretPath = Path.Combine(directory, "snifix-ca.key");
        if (File.Exists(secretPath))
        {
            // A password that cannot be decrypted is an error, never a reason to make a new CA: phones trust the old one
            password = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(secretPath), Entropy, DataProtectionScope.CurrentUser));
            return false;
        }
        password = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        if (File.Exists(pfxPath))
        {
            using var old = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, "", X509KeyStorageFlags.Exportable);
            File.WriteAllBytes(pfxPath, old.Export(X509ContentType.Pkcs12, password));
        }
        File.WriteAllBytes(secretPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(password), Entropy, DataProtectionScope.CurrentUser));
        return false;
    }
}
