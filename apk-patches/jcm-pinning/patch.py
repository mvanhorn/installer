#!/usr/bin/env python3
"""Neutralize cert pinning in the oven JuneCloudMessaging.apk (system trust only).

Usage:
  python3 patch.py <apktool-decoded-dir>
        Pinning patch only -> the shipped JuneCloudMessaging_nopin_signed.apk.

  python3 patch.py <apktool-decoded-dir> --token-fallback
        Optional, bench-gated layer A1 from docs/identity-generation.md and
        docs/jcm-token-fallback.md.  Patches
        DeferredAuthTokenHolder.getAuthToken()/forceRefresh() and
        AuthDecorator.ensureLatestHeaders(String) so that, when AccountManager
        has no June account / returns no token, the JCM still sends an
        Authorization header.  Resolution order: SystemProperties
        "june.local.token" -> account.token in /data/june/identity.json ->
        compiled-in fallback token.  The AccountManager path stays first.

        Run this AFTER the default (pinning) patch, on the same decoded tree.
        It is UNPROVEN on hardware: do not put the fallback APK into the shipped
        assets/ payload until the P4 bench test passes.
"""
import glob
import os
import re
import sys

PKG = ("com", "junelife", "android", "networkclient")

# New helper class (docs/jcm-token-fallback.md).  Kept dependency-free on the
# JCM: only framework classes plus the app's own Strings/Logr helpers.
TOKEN_HELPER_SMALI = """.class public final Lcom/junelife/android/networkclient/JuneLocalToken;
.super Ljava/lang/Object;
.source "JuneLocalToken.java"

# June Local fallback bearer token.  The local relay does not validate bearer
# tokens, so this only exists to keep the JCM's Authorization header non-null
# when AccountManager has no June account.  Resolution order:
#   1. SystemProperties "june.local.token" (set early at boot by june_reaper)
#   2. account.token in /data/june/identity.json
#   3. compiled-in fallback token
# AccountManager is NOT consulted here: AuthDecorator/AuthTokenHolder still try
# it first and only call this helper when that path produced no token.

# static fields
.field private static sCachedToken:Ljava/lang/String;


# direct methods
.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public static get()Ljava/lang/String;
    .locals 6

    sget-object v0, Lcom/junelife/android/networkclient/JuneLocalToken;->sCachedToken:Ljava/lang/String;

    if-eqz v0, :resolve

    return-object v0

    :resolve
    :try_start_0
    const-string v0, "june.local.token"

    invoke-static {v0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/junelife/device/common/core/Strings;->isNullOrEmpty(Ljava/lang/CharSequence;)Z

    move-result v1

    if-nez v1, :property_empty

    const-string v1, "JuneLocalToken"

    const-string v2, "using bearer token from SystemProperties june.local.token"

    const/4 v3, 0x0

    new-array v3, v3, [Ljava/lang/Object;

    invoke-static {v1, v2, v3}, Lcom/junelife/device/common/logging/Logr;->d(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/Object;)V

    sput-object v0, Lcom/junelife/android/networkclient/JuneLocalToken;->sCachedToken:Ljava/lang/String;

    return-object v0

    :property_empty
    invoke-static {}, Lcom/junelife/android/networkclient/JuneLocalToken;->readIdentityToken()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/junelife/device/common/core/Strings;->isNullOrEmpty(Ljava/lang/CharSequence;)Z

    move-result v1

    if-nez v1, :no_identity

    const-string v1, "JuneLocalToken"

    const-string v2, "using bearer token from /data/june/identity.json"

    const/4 v3, 0x0

    new-array v3, v3, [Ljava/lang/Object;

    invoke-static {v1, v2, v3}, Lcom/junelife/device/common/logging/Logr;->d(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/Object;)V

    sput-object v0, Lcom/junelife/android/networkclient/JuneLocalToken;->sCachedToken:Ljava/lang/String;

    return-object v0

    :no_identity
    const-string v0, "v2:JUNELOCALFAKE000000000000000"

    const-string v1, "JuneLocalToken"

    const-string v2, "no local identity token; using compiled-in fallback bearer token"

    const/4 v3, 0x0

    new-array v3, v3, [Ljava/lang/Object;

    invoke-static {v1, v2, v3}, Lcom/junelife/device/common/logging/Logr;->d(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/Object;)V

    sput-object v0, Lcom/junelife/android/networkclient/JuneLocalToken;->sCachedToken:Ljava/lang/String;

    return-object v0
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catchall_0

    :catchall_0
    move-exception v1

    const-string v0, "v2:JUNELOCALFAKE000000000000000"

    sput-object v0, Lcom/junelife/android/networkclient/JuneLocalToken;->sCachedToken:Ljava/lang/String;

    return-object v0
.end method

.method private static readIdentityToken()Ljava/lang/String;
    .locals 5

    :try_start_0
    new-instance v0, Ljava/io/File;

    const-string v1, "/data/june/identity.json"

    invoke-direct {v0, v1}, Ljava/io/File;-><init>(Ljava/lang/String;)V

    invoke-virtual {v0}, Ljava/io/File;->exists()Z

    move-result v1

    if-eqz v1, :missing

    new-instance v2, Ljava/util/Scanner;

    invoke-direct {v2, v0}, Ljava/util/Scanner;-><init>(Ljava/io/File;)V

    const-string v3, "\\\\A"

    invoke-virtual {v2, v3}, Ljava/util/Scanner;->useDelimiter(Ljava/lang/String;)Ljava/util/Scanner;

    invoke-virtual {v2}, Ljava/util/Scanner;->next()Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v2}, Ljava/util/Scanner;->close()V

    new-instance v4, Lorg/json/JSONObject;

    invoke-direct {v4, v3}, Lorg/json/JSONObject;-><init>(Ljava/lang/String;)V

    const-string v3, "account"

    invoke-virtual {v4, v3}, Lorg/json/JSONObject;->optJSONObject(Ljava/lang/String;)Lorg/json/JSONObject;

    move-result-object v3

    if-eqz v3, :missing

    const-string v4, "token"

    invoke-virtual {v3, v4}, Lorg/json/JSONObject;->optString(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v3

    return-object v3

    :missing
    const/4 v0, 0x0

    return-object v0
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catchall_0

    :catchall_0
    move-exception v1

    const/4 v0, 0x0

    return-object v0
.end method

.method public static orFallback(Ljava/lang/String;)Ljava/lang/String;
    .locals 1

    invoke-static {p0}, Lcom/junelife/device/common/core/Strings;->isNullOrEmpty(Ljava/lang/CharSequence;)Z

    move-result v0

    if-eqz v0, :have_token

    invoke-static {}, Lcom/junelife/android/networkclient/JuneLocalToken;->get()Ljava/lang/String;

    move-result-object v0

    return-object v0

    :have_token
    return-object p0
.end method
"""

# Replacement for DeferredAuthTokenHolder.getAuthToken(): AccountManager-backed
# holder first (createRealHolder() may find a late account), local fallback only
# when it still has no usable token.
GET_AUTH_TOKEN_SMALI = """.method public getAuthToken()Ljava/lang/String;
    .locals 3

    iget-object v0, p0, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->mRealHolder:Lcom/junelife/android/networkclient/AuthTokenHolder;

    if-nez v0, :real_holder_ready

    invoke-direct {p0}, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->createRealHolder()V

    iget-object v0, p0, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->mRealHolder:Lcom/junelife/android/networkclient/AuthTokenHolder;

    :real_holder_ready
    if-eqz v0, :fallback

    invoke-virtual {v0}, Lcom/junelife/android/networkclient/AuthTokenHolder;->getAuthToken()Ljava/lang/String;

    move-result-object v1

    invoke-static {v1}, Lcom/junelife/device/common/core/Strings;->isNullOrEmpty(Ljava/lang/CharSequence;)Z

    move-result v2

    if-eqz v2, :have_token

    :fallback
    invoke-static {}, Lcom/junelife/android/networkclient/JuneLocalToken;->get()Ljava/lang/String;

    move-result-object v0

    return-object v0

    :have_token
    return-object v1
.end method"""

FORCE_REFRESH_SMALI = """.method public forceRefresh()Ljava/lang/String;
    .locals 3

    iget-object v0, p0, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->mRealHolder:Lcom/junelife/android/networkclient/AuthTokenHolder;

    if-nez v0, :real_holder_ready

    invoke-direct {p0}, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->createRealHolder()V

    iget-object v0, p0, Lcom/junelife/android/networkclient/DeferredAuthTokenHolder;->mRealHolder:Lcom/junelife/android/networkclient/AuthTokenHolder;

    :real_holder_ready
    if-eqz v0, :fallback

    invoke-virtual {v0}, Lcom/junelife/android/networkclient/AuthTokenHolder;->forceRefresh()Ljava/lang/String;

    move-result-object v1

    invoke-static {v1}, Lcom/junelife/device/common/core/Strings;->isNullOrEmpty(Ljava/lang/CharSequence;)Z

    move-result v2

    if-eqz v2, :have_token

    :fallback
    invoke-static {}, Lcom/junelife/android/networkclient/JuneLocalToken;->get()Ljava/lang/String;

    move-result-object v0

    return-object v0

    :have_token
    return-object v1
.end method"""


def find_class(decoded, class_name):
    """Return (networkclient_dir, smali_path) for class_name across smali*/ dirs."""
    for smali in sorted(glob.glob(os.path.join(decoded, "smali*"))):
        directory = os.path.join(smali, *PKG)
        path = os.path.join(directory, class_name + ".smali")
        if os.path.isfile(path):
            return directory, path
    raise SystemExit(
        "missing %s/%s.smali under %s/smali* - is this an apktool-decoded "
        "JuneCloudMessaging tree?" % ("/".join(PKG), class_name, decoded))


def replace_method(text, pattern, replacement, what):
    """Replace exactly one method.  Idempotent: re-running is a no-op when the
    method already equals the replacement (the pattern still matches once)."""
    new_text, count = pattern.subn(lambda m: replacement, text, count=1)
    if count != 1:
        raise SystemExit("%s not found in the decoded smali; refusing to patch" % what)
    return new_text


def patch_pinning(decoded):
    # 1. HttpClientFactory.createCertificatePinner() -> empty pinner
    _, hf_path = find_class(decoded, "HttpClientFactory")
    with open(hf_path, encoding="utf-8") as f:
        hf = f.read()
    new_pinner = """.method private static createCertificatePinner()Lokhttp3/CertificatePinner;
    .locals 1

    new-instance v0, Lokhttp3/CertificatePinner$Builder;

    invoke-direct {v0}, Lokhttp3/CertificatePinner$Builder;-><init>()V

    invoke-virtual {v0}, Lokhttp3/CertificatePinner$Builder;->build()Lokhttp3/CertificatePinner;

    move-result-object v0

    return-object v0
.end method"""
    pat = re.compile(r"\.method private static createCertificatePinner\(\)Lokhttp3/CertificatePinner;\s*.*?\.end method", re.S)
    hf2 = replace_method(hf, pat, new_pinner, "HttpClientFactory.createCertificatePinner")
    with open(hf_path, "w", encoding="utf-8") as f:
        f.write(hf2)

    # 2. PinningTrustManager: delegate to system trust, drop pin enforcement
    _, ptm_path = find_class(decoded, "PinningTrustManager")
    with open(ptm_path, encoding="utf-8") as f:
        ptm = f.read()

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
    ptm2 = replace_method(ptm, pat_server, new_server, "PinningTrustManager.checkServerTrusted")
    pat_client = re.compile(r"\.method public checkClientTrusted\(\[Ljava/security/cert/X509Certificate;Ljava/lang/String;\)V\s*.*?\.end method", re.S)
    ptm3 = replace_method(ptm2, pat_client, new_client, "PinningTrustManager.checkClientTrusted")
    with open(ptm_path, "w", encoding="utf-8") as f:
        f.write(ptm3)
    print("patched: HttpClientFactory + PinningTrustManager (system trust only)")


def patch_token_fallback(decoded):
    # 1. Jump in front of the header decision: replace a null/empty token with
    #    the local fallback so the Authorization header is still attached.
    base, ad_path = find_class(decoded, "AuthDecorator")
    with open(ad_path, encoding="utf-8") as f:
        ad = f.read()
    pat_ens = re.compile(r"\.method private ensureLatestHeaders\(Ljava/lang/String;\)V\b.*?\.end method", re.S)
    match = pat_ens.search(ad)
    if match is None:
        raise SystemExit("AuthDecorator.ensureLatestHeaders(Ljava/lang/String;)V not found")
    if "JuneLocalToken" in match.group(0):
        raise SystemExit("AuthDecorator is already token-fallback patched; refusing to patch twice")
    locals_match = re.search(r"^[ \t]*\.locals[ \t]+\d+[ \t]*$", match.group(0), re.M)
    if locals_match is None:
        raise SystemExit("could not find .locals in AuthDecorator.ensureLatestHeaders")
    injection = (
        "\n\n    # June Local: keep the Authorization header non-null when"
        "\n    # AccountManager has no June account/token (docs/jcm-token-fallback.md)."
        "\n    invoke-static {p1}, Lcom/junelife/android/networkclient/JuneLocalToken;->orFallback(Ljava/lang/String;)Ljava/lang/String;"
        "\n\n    move-result-object p1"
    )
    start, end = match.span()
    block = match.group(0)
    block = block[:locals_match.end()] + injection + block[locals_match.end():]
    ad2 = ad[:start] + block + ad[end:]
    with open(ad_path, "w", encoding="utf-8") as f:
        f.write(ad2)
    print("patched: AuthDecorator.ensureLatestHeaders (token fallback)")

    # 2. Make getAuthToken()/forceRefresh() hand out the fallback too, so callers
    #    that inspect the token see the same value the header gets.
    _, dth_path = find_class(decoded, "DeferredAuthTokenHolder")
    with open(dth_path, encoding="utf-8") as f:
        dth = f.read()
    if "mRealHolder" not in dth:
        raise SystemExit("DeferredAuthTokenHolder has no mRealHolder field")
    if "JuneLocalToken" in dth:
        raise SystemExit("DeferredAuthTokenHolder is already token-fallback patched; refusing to patch twice")
    pat_get = re.compile(r"\.method public getAuthToken\(\)Ljava/lang/String;\s*.*?\.end method", re.S)
    pat_refresh = re.compile(r"\.method public forceRefresh\(\)Ljava/lang/String;\s*.*?\.end method", re.S)
    dth2 = replace_method(dth, pat_get, GET_AUTH_TOKEN_SMALI, "DeferredAuthTokenHolder.getAuthToken")
    dth3 = replace_method(dth2, pat_refresh, FORCE_REFRESH_SMALI, "DeferredAuthTokenHolder.forceRefresh")
    with open(dth_path, "w", encoding="utf-8") as f:
        f.write(dth3)
    print("patched: DeferredAuthTokenHolder.getAuthToken/forceRefresh (token fallback)")

    # 3. Add the helper class next to AuthDecorator (same dex/package).
    helper_path = os.path.join(base, "JuneLocalToken.smali")
    if os.path.exists(helper_path):
        raise SystemExit("%s already exists; refusing to overwrite" % helper_path)
    with open(helper_path, "w", encoding="utf-8") as f:
        f.write(TOKEN_HELPER_SMALI)
    print("added: %s" % helper_path)


def main(argv):
    args = [a for a in argv[1:]]
    token_fallback = "--token-fallback" in args
    args = [a for a in args if a != "--token-fallback"]
    unknown = [a for a in args if a.startswith("-")]
    if unknown:
        raise SystemExit("unknown option(s): %s" % " ".join(unknown))
    if len(args) != 1:
        raise SystemExit(
            "usage: python3 patch.py <apktool-decoded-dir> [--token-fallback]")
    decoded = args[0]
    if token_fallback:
        patch_token_fallback(decoded)
    else:
        patch_pinning(decoded)


if __name__ == "__main__":
    main(sys.argv)
