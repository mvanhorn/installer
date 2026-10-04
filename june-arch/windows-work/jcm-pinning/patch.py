#!/usr/bin/env python3
"""Neutralize cert pinning in the oven JuneCloudMessaging.apk (system trust only).

Usage: python3 patch.py <apktool-decoded-dir>
"""
import re, os, sys

decoded = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    r"C:\Users\Gene\AppData\Local\Temp\jcm_pinning", "decoded")
base = os.path.join(decoded, "smali", "com", "junelife", "android", "networkclient")

# 1. HttpClientFactory.createCertificatePinner() -> empty pinner
hf_path = os.path.join(base, "HttpClientFactory.smali")
hf = open(hf_path, encoding="utf-8").read()
new_pinner = """.method private static createCertificatePinner()Lokhttp3/CertificatePinner;
    .locals 1

    new-instance v0, Lokhttp3/CertificatePinner$Builder;

    invoke-direct {v0}, Lokhttp3/CertificatePinner$Builder;-><init>()V

    invoke-virtual {v0}, Lokhttp3/CertificatePinner$Builder;->build()Lokhttp3/CertificatePinner;

    move-result-object v0

    return-object v0
.end method"""
pat = re.compile(r"\.method private static createCertificatePinner\(\)Lokhttp3/CertificatePinner;\s*.*?\.end method", re.S)
hf2 = pat.sub(lambda m: new_pinner, hf, count=1)
assert hf2 != hf, "createCertificatePinner not replaced"
open(hf_path, "w", encoding="utf-8").write(hf2)

# 2. PinningTrustManager: delegate to system trust, drop pin enforcement
ptm_path = os.path.join(base, "PinningTrustManager.smali")
ptm = open(ptm_path, encoding="utf-8").read()

new_server = """.method public checkServerTrusted([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V
    .locals 2
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/security/cert/CertificateException;
        }
    .end annotation

    const-string v0, "X509"

    invoke-static {v0}, Ljavax/net/ssl/TrustManagerFactory;->getInstance(Ljava/lang/String;)Ljavax/net/ssl/TrustManagerFactory;

    move-result-object v0

    const/4 v1, 0x0

    check-cast v1, Ljava/security/KeyStore;

    invoke-virtual {v0, v1}, Ljavax/net/ssl/TrustManagerFactory;->init(Ljava/security/KeyStore;)V

    invoke-virtual {v0}, Ljavax/net/ssl/TrustManagerFactory;->getTrustManagers()[Ljavax/net/ssl/TrustManager;

    move-result-object v0

    const/4 v1, 0x0

    aget-object v0, v0, v1

    check-cast v0, Ljavax/net/ssl/X509TrustManager;

    invoke-interface {v0, p1, p2}, Ljavax/net/ssl/X509TrustManager;->checkServerTrusted([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V

    return-void
.end method"""

new_client = """.method public checkClientTrusted([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V
    .locals 0
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/security/cert/CertificateException;
        }
    .end annotation

    return-void
.end method"""

pat_server = re.compile(r"\.method public checkServerTrusted\(\[Ljava/security/cert/X509Certificate;Ljava/lang/String;\)V\s*.*?\.end method", re.S)
ptm2 = pat_server.sub(lambda m: new_server, ptm, count=1)
assert ptm2 != ptm, "checkServerTrusted not replaced"
pat_client = re.compile(r"\.method public checkClientTrusted\(\[Ljava/security/cert/X509Certificate;Ljava/lang/String;\)V\s*.*?\.end method", re.S)
ptm3 = pat_client.sub(lambda m: new_client, ptm2, count=1)
assert ptm3 != ptm2, "checkClientTrusted not replaced"
open(ptm_path, "w", encoding="utf-8").write(ptm3)
print("patched: HttpClientFactory + PinningTrustManager (system trust only)")