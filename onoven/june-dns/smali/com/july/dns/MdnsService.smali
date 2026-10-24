.class public Lcom/july/dns/MdnsService;
.super Landroid/app/Service;
.source "MdnsService.java"

# June Local DNS: a tiny always-on system service that starts Android's mDNS
# responder (mdnsd via NsdManager) and registers a DNS-SD service so other
# hosts can find the oven at <name>.local.
#
# Name source: /system/etc/june_hostname (written by the installer); fallback
# net.hostname, then "june". june_reaper.sh also sets net.hostname from that
# file at boot, and june_bootclear.sh re-asserts it before starting this
# service, because on Android the mDNS host name (the A record clients resolve
# for <name>.local) comes from the device host name, NOT from the service's
# NsdServiceInfo host field. On Android 5.0.1 NsdService.registerService()
# sends only the service name/type/port to netd, so setHost() is best-effort
# only: it is kept so the record is right if a future platform honours it.
#
# Started by /system/bin/june_bootclear.sh after boot_completed:
#   am startservice --user 0 -n com.july.dns/.MdnsService

.field private static final TAG:Ljava/lang/String;

.field private static final DNS_SD_SERVICE_NAME:Ljava/lang/String;

.field private static final DNS_SD_SERVICE_TYPE:Ljava/lang/String;

.field private static final HTTP_PORT:I = 0x50

.field private mMulticastLock:Landroid/net/wifi/WifiManager$MulticastLock;

.field private mNsdManager:Landroid/net/nsd/NsdManager;

.field private mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

.field private mHostName:Ljava/lang/String;

.field private mRegistered:Z


.method static constructor <clinit>()V
    .locals 1

    const-string v0, "JuneLocalDns"

    sput-object v0, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    const-string v0, "June Local"

    sput-object v0, Lcom/july/dns/MdnsService;->DNS_SD_SERVICE_NAME:Ljava/lang/String;

    const-string v0, "_http._tcp"

    sput-object v0, Lcom/july/dns/MdnsService;->DNS_SD_SERVICE_TYPE:Ljava/lang/String;

    return-void
.end method


.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Landroid/app/Service;-><init>()V

    return-void
.end method


.method public onBind(Landroid/content/Intent;)Landroid/os/IBinder;
    .locals 1

    const/4 v0, 0x0

    return-object v0
.end method


.method public onCreate()V
    .locals 3

    invoke-super {p0}, Landroid/app/Service;->onCreate()V

    invoke-direct {p0}, Lcom/july/dns/MdnsService;->acquireMulticastLock()V

    invoke-direct {p0}, Lcom/july/dns/MdnsService;->resolveHostName()Ljava/lang/String;
    move-result-object v0

    iput-object v0, p0, Lcom/july/dns/MdnsService;->mHostName:Ljava/lang/String;

    new-instance v0, Ljava/lang/StringBuilder;
    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    const-string v1, "advertising "

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    iget-object v1, p0, Lcom/july/dns/MdnsService;->mHostName:Ljava/lang/String;

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v1, ".local"

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v0

    sget-object v1, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    invoke-static {v1, v0}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p0}, Lcom/july/dns/MdnsService;->registerMdns()V

    return-void
.end method


.method public onStartCommand(Landroid/content/Intent;II)I
    .locals 1

    # No work items: this service only keeps the mDNS registration alive.
    # Stay resident so the registration (and mdnsd) survive; bootclear starts
    # it once per boot, and a sticky restart re-registers in onCreate.
    invoke-virtual {p0}, Lcom/july/dns/MdnsService;->registerMdns()V

    const/4 v0, 0x1

    return v0
.end method


.method public onDestroy()V
    .locals 4

    iget-object v0, p0, Lcom/july/dns/MdnsService;->mNsdManager:Landroid/net/nsd/NsdManager;

    iget-object v1, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    if-eqz v0, :after_unregister

    if-eqz v1, :after_unregister

    :try_start_unreg
    invoke-virtual {v0, v1}, Landroid/net/nsd/NsdManager;->unregisterService(Landroid/net/nsd/NsdManager$RegistrationListener;)V
    :try_end_unreg
    .catch Ljava/lang/Throwable; {:try_start_unreg .. :try_end_unreg} :catch_unreg

    goto :after_unregister

    :catch_unreg
    move-exception v2

    :after_unregister
    const/4 v2, 0x0

    iput-boolean v2, p0, Lcom/july/dns/MdnsService;->mRegistered:Z

    invoke-virtual {p0}, Lcom/july/dns/MdnsService;->cancelRetry()V

    invoke-direct {p0}, Lcom/july/dns/MdnsService;->releaseMulticastLock()V

    invoke-super {p0}, Landroid/app/Service;->onDestroy()V

    return-void
.end method


# registerMdns: register the DNS-SD service once; safe to call repeatedly.
.method public registerMdns()V
    .locals 6

    iget-boolean v0, p0, Lcom/july/dns/MdnsService;->mRegistered:Z

    if-eqz v0, :do_register

    return-void

    :do_register
    iget-object v0, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    if-nez v0, :have_listener

    new-instance v0, Lcom/july/dns/MdnsRegistrationListener;

    invoke-direct {v0, p0}, Lcom/july/dns/MdnsRegistrationListener;-><init>(Lcom/july/dns/MdnsService;)V

    iput-object v0, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    :have_listener
    :try_start_reg
    new-instance v0, Landroid/net/nsd/NsdServiceInfo;

    invoke-direct {v0}, Landroid/net/nsd/NsdServiceInfo;-><init>()V

    sget-object v1, Lcom/july/dns/MdnsService;->DNS_SD_SERVICE_NAME:Ljava/lang/String;

    invoke-virtual {v0, v1}, Landroid/net/nsd/NsdServiceInfo;->setServiceName(Ljava/lang/String;)V

    sget-object v1, Lcom/july/dns/MdnsService;->DNS_SD_SERVICE_TYPE:Ljava/lang/String;

    invoke-virtual {v0, v1}, Landroid/net/nsd/NsdServiceInfo;->setServiceType(Ljava/lang/String;)V

    const/16 v1, 0x50

    invoke-virtual {v0, v1}, Landroid/net/nsd/NsdServiceInfo;->setPort(I)V

    invoke-direct {p0, v0}, Lcom/july/dns/MdnsService;->setMdnsHost(Landroid/net/nsd/NsdServiceInfo;)V

    iget-object v1, p0, Lcom/july/dns/MdnsService;->mNsdManager:Landroid/net/nsd/NsdManager;

    if-nez v1, :have_manager

    const-string v2, "servicediscovery"

    invoke-virtual {p0, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v2

    check-cast v2, Landroid/net/nsd/NsdManager;

    iput-object v2, p0, Lcom/july/dns/MdnsService;->mNsdManager:Landroid/net/nsd/NsdManager;

    move-object v1, v2

    :have_manager
    if-eqz v1, :no_manager

    iget-object v2, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    invoke-virtual {v1, v0, v2}, Landroid/net/nsd/NsdManager;->registerService(Landroid/net/nsd/NsdServiceInfo;Landroid/net/nsd/NsdManager$RegistrationListener;)V

    const/4 v0, 0x1

    iput-boolean v0, p0, Lcom/july/dns/MdnsService;->mRegistered:Z

    sget-object v0, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    const-string v1, "NsdManager.registerService called for June Local/_http._tcp:80"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I
    :try_end_reg
    .catch Ljava/lang/Throwable; {:try_start_reg .. :try_end_reg} :catch_reg

    goto :done

    :catch_reg
    move-exception v0

    sget-object v1, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    const-string v2, "mDNS registration failed; will retry"

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p0}, Lcom/july/dns/MdnsService;->scheduleRetry()V

    goto :done

    :no_manager
    sget-object v1, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    const-string v2, "NsdManager is unavailable; mDNS disabled"

    invoke-static {v1, v2}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    :done
    return-void
.end method


# setMdnsHost: best-effort host field "<name>.local", built from the oven's
# current Wi-Fi IPv4 address (no DNS lookup, so it cannot block the service).
# Android 5.0.1 ignores the host field for registration (netd receives only the
# service name/type/port), so this is informational/forward-compatible; it must
# never make registration fail.
.method private setMdnsHost(Landroid/net/nsd/NsdServiceInfo;)V
    .locals 7

    :try_start_host
    new-instance v0, Ljava/lang/StringBuilder;

    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    iget-object v1, p0, Lcom/july/dns/MdnsService;->mHostName:Ljava/lang/String;

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v1, ".local"

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v0

    const-string v1, "wifi"

    invoke-virtual {p0, v1}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v1

    check-cast v1, Landroid/net/wifi/WifiManager;

    invoke-virtual {v1}, Landroid/net/wifi/WifiManager;->getConnectionInfo()Landroid/net/wifi/WifiInfo;
    move-result-object v1

    invoke-virtual {v1}, Landroid/net/wifi/WifiInfo;->getIpAddress()I
    move-result v1

    if-eqz v1, :host_done

    const/4 v5, 0x4

    new-array v2, v5, [B

    const/4 v3, 0x0

    and-int/lit16 v4, v1, 0xff

    int-to-byte v4, v4

    aput-byte v4, v2, v3

    const/4 v3, 0x1

    shr-int/lit8 v4, v1, 0x8

    and-int/lit16 v4, v4, 0xff

    int-to-byte v4, v4

    aput-byte v4, v2, v3

    const/4 v3, 0x2

    shr-int/lit8 v4, v1, 0x10

    and-int/lit16 v4, v4, 0xff

    int-to-byte v4, v4

    aput-byte v4, v2, v3

    const/4 v3, 0x3

    shr-int/lit8 v4, v1, 0x18

    and-int/lit16 v4, v4, 0xff

    int-to-byte v4, v4

    aput-byte v4, v2, v3

    invoke-static {v0, v2}, Ljava/net/InetAddress;->getByAddress(Ljava/lang/String;[B)Ljava/net/InetAddress;
    move-result-object v0

    invoke-virtual {p1, v0}, Landroid/net/nsd/NsdServiceInfo;->setHost(Ljava/net/InetAddress;)V
    :try_end_host
    .catch Ljava/lang/Throwable; {:try_start_host .. :try_end_host} :catch_host

    goto :host_done

    :catch_host
    move-exception v0

    :host_done
    return-void
.end method


# resolveHostName: chosen oven name from /system/etc/june_hostname, then
# net.hostname, then "june". The ".local" suffix is stripped if present.
.method private resolveHostName()Ljava/lang/String;
    .locals 5

    invoke-static {}, Lcom/july/dns/MdnsService;->readHostnameFile()Ljava/lang/String;
    move-result-object v0

    invoke-virtual {v0}, Ljava/lang/String;->trim()Ljava/lang/String;
    move-result-object v0

    const-string v1, ".local"

    invoke-virtual {v0, v1}, Ljava/lang/String;->endsWith(Ljava/lang/String;)Z
    move-result v1

    if-eqz v1, :after_strip

    const/4 v1, 0x0

    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v2

    add-int/lit8 v2, v2, -0x6

    invoke-virtual {v0, v1, v2}, Ljava/lang/String;->substring(II)Ljava/lang/String;
    move-result-object v0

    :after_strip
    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v1

    if-eqz v1, :fallback

    goto :have_name

    :fallback
    const-string v1, "net.hostname"

    invoke-static {v1}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
    move-result-object v1

    if-eqz v1, :have_name

    invoke-virtual {v1}, Ljava/lang/String;->trim()Ljava/lang/String;
    move-result-object v2

    invoke-virtual {v2}, Ljava/lang/String;->length()I
    move-result v3

    if-eqz v3, :have_name

    move-object v0, v2

    :have_name
    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v1

    if-eqz v1, :set_default

    goto :done

    :set_default
    const-string v0, "june"

    :done
    return-object v0
.end method


.method private static readHostnameFile()Ljava/lang/String;
    .locals 5

    const-string v0, ""

    :try_start_file
    new-instance v1, Ljava/io/FileInputStream;

    const-string v2, "/system/etc/june_hostname"

    invoke-direct {v1, v2}, Ljava/io/FileInputStream;-><init>(Ljava/lang/String;)V

    new-instance v2, Ljava/io/BufferedReader;

    new-instance v3, Ljava/io/InputStreamReader;

    invoke-direct {v3, v1}, Ljava/io/InputStreamReader;-><init>(Ljava/io/InputStream;)V

    invoke-direct {v2, v3}, Ljava/io/BufferedReader;-><init>(Ljava/io/Reader;)V

    invoke-virtual {v2}, Ljava/io/BufferedReader;->readLine()Ljava/lang/String;
    move-result-object v1

    invoke-virtual {v2}, Ljava/io/BufferedReader;->close()V

    if-nez v1, :have_line

    const-string v1, ""

    :have_line
    move-object v0, v1
    :try_end_file
    .catch Ljava/lang/Throwable; {:try_start_file .. :try_end_file} :catch_file

    goto :file_done

    :catch_file
    move-exception v1

    const-string v0, ""

    :file_done
    return-object v0
.end method


.method private acquireMulticastLock()V
    .locals 4

    :try_start_lock
    const-string v0, "wifi"

    invoke-virtual {p0, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0

    check-cast v0, Landroid/net/wifi/WifiManager;

    if-eqz v0, :after_lock

    const-string v1, "june-local-dns"

    invoke-virtual {v0, v1}, Landroid/net/wifi/WifiManager;->createMulticastLock(Ljava/lang/String;)Landroid/net/wifi/WifiManager$MulticastLock;
    move-result-object v1

    if-eqz v1, :after_lock

    const/4 v2, 0x0

    invoke-virtual {v1, v2}, Landroid/net/wifi/WifiManager$MulticastLock;->setReferenceCounted(Z)V

    invoke-virtual {v1}, Landroid/net/wifi/WifiManager$MulticastLock;->acquire()V

    iput-object v1, p0, Lcom/july/dns/MdnsService;->mMulticastLock:Landroid/net/wifi/WifiManager$MulticastLock;
    :try_end_lock
    .catch Ljava/lang/Throwable; {:try_start_lock .. :try_end_lock} :catch_lock

    goto :after_lock

    :catch_lock
    move-exception v0

    sget-object v1, Lcom/july/dns/MdnsService;->TAG:Ljava/lang/String;

    const-string v2, "could not acquire the Wi-Fi MulticastLock; mDNS may miss queries"

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    :after_lock
    return-void
.end method


.method private releaseMulticastLock()V
    .locals 4

    :try_start_rel
    iget-object v0, p0, Lcom/july/dns/MdnsService;->mMulticastLock:Landroid/net/wifi/WifiManager$MulticastLock;

    if-eqz v0, :after_rel

    invoke-virtual {v0}, Landroid/net/wifi/WifiManager$MulticastLock;->isHeld()Z
    move-result v1

    if-eqz v1, :after_rel

    invoke-virtual {v0}, Landroid/net/wifi/WifiManager$MulticastLock;->release()V
    :try_end_rel
    .catch Ljava/lang/Throwable; {:try_start_rel .. :try_end_rel} :catch_rel

    goto :after_rel

    :catch_rel
    move-exception v1

    :after_rel
    const/4 v0, 0x0

    iput-object v0, p0, Lcom/july/dns/MdnsService;->mMulticastLock:Landroid/net/wifi/WifiManager$MulticastLock;

    return-void
.end method


.method public setMdnsRegistered(Z)V
    .locals 0

    iput-boolean p1, p0, Lcom/july/dns/MdnsService;->mRegistered:Z

    return-void
.end method


.method public scheduleRetry()V
    .locals 2

    iget-object v0, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    if-eqz v0, :done

    invoke-virtual {v0}, Lcom/july/dns/MdnsRegistrationListener;->scheduleRetry()V

    :done
    return-void
.end method


.method public cancelRetry()V
    .locals 1

    iget-object v0, p0, Lcom/july/dns/MdnsService;->mNsdListener:Lcom/july/dns/MdnsRegistrationListener;

    if-eqz v0, :done

    invoke-virtual {v0}, Lcom/july/dns/MdnsRegistrationListener;->cancel()V

    :done
    return-void
.end method
