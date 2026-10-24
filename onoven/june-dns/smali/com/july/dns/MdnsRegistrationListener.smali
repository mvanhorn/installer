.class public Lcom/july/dns/MdnsRegistrationListener;
.super Ljava/lang/Object;
.implements Landroid/net/nsd/NsdManager$RegistrationListener;
.implements Ljava/lang/Runnable;
.source "MdnsRegistrationListener.java"

# RegistrationListener for com.july.dns/.MdnsService. Logs the outcome and, on
# failure, schedules a bounded retry (NsdManager registration can fail while
# Wi-Fi is still coming up at boot). The retry also implements Runnable so no
# extra class is needed for Handler.postDelayed.

.field private static final TAG:Ljava/lang/String;

.field private static final MAX_RETRIES:I = 0x14

.field private static final RETRY_MS:J

.field private mAttempts:I

.field private final mHandler:Landroid/os/Handler;

.field private final mService:Lcom/july/dns/MdnsService;


.method static constructor <clinit>()V
    .locals 2

    const-string v0, "JuneLocalDns"

    sput-object v0, Lcom/july/dns/MdnsRegistrationListener;->TAG:Ljava/lang/String;

    const-wide/16 v0, 0x3a98

    sput-wide v0, Lcom/july/dns/MdnsRegistrationListener;->RETRY_MS:J

    return-void
.end method


.method public constructor <init>(Lcom/july/dns/MdnsService;)V
    .locals 3

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/july/dns/MdnsRegistrationListener;->mService:Lcom/july/dns/MdnsService;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;
    move-result-object v0

    new-instance v1, Landroid/os/Handler;

    invoke-direct {v1, v0}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    iput-object v1, p0, Lcom/july/dns/MdnsRegistrationListener;->mHandler:Landroid/os/Handler;

    const/4 v0, 0x0

    iput v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mAttempts:I

    return-void
.end method


.method public onServiceRegistered(Landroid/net/nsd/NsdServiceInfo;)V
    .locals 3

    const/4 v0, 0x0

    iput v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mAttempts:I

    iget-object v1, p0, Lcom/july/dns/MdnsRegistrationListener;->mService:Lcom/july/dns/MdnsService;

    const/4 v2, 0x1

    invoke-virtual {v1, v2}, Lcom/july/dns/MdnsService;->setMdnsRegistered(Z)V

    sget-object v1, Lcom/july/dns/MdnsRegistrationListener;->TAG:Ljava/lang/String;

    const-string v2, "mDNS service registered"

    invoke-static {v1, v2}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


.method public onRegistrationFailed(Landroid/net/nsd/NsdServiceInfo;I)V
    .locals 3

    iget-object v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mService:Lcom/july/dns/MdnsService;

    const/4 v1, 0x0

    invoke-virtual {v0, v1}, Lcom/july/dns/MdnsService;->setMdnsRegistered(Z)V

    sget-object v1, Lcom/july/dns/MdnsRegistrationListener;->TAG:Ljava/lang/String;

    const-string v2, "mDNS registration failed; retrying"

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p0}, Lcom/july/dns/MdnsRegistrationListener;->scheduleRetry()V

    return-void
.end method


.method public onServiceUnregistered(Landroid/net/nsd/NsdServiceInfo;)V
    .locals 3

    iget-object v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mService:Lcom/july/dns/MdnsService;

    const/4 v1, 0x0

    invoke-virtual {v0, v1}, Lcom/july/dns/MdnsService;->setMdnsRegistered(Z)V

    sget-object v1, Lcom/july/dns/MdnsRegistrationListener;->TAG:Ljava/lang/String;

    const-string v2, "mDNS service unregistered"

    invoke-static {v1, v2}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


.method public run()V
    .locals 1

    iget-object v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mService:Lcom/july/dns/MdnsService;

    invoke-virtual {v0}, Lcom/july/dns/MdnsService;->registerMdns()V

    return-void
.end method


.method public scheduleRetry()V
    .locals 4

    iget v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mAttempts:I

    sget v1, Lcom/july/dns/MdnsRegistrationListener;->MAX_RETRIES:I

    if-ge v0, v1, :give_up

    add-int/lit8 v0, v0, 0x1

    iput v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mAttempts:I

    iget-object v1, p0, Lcom/july/dns/MdnsRegistrationListener;->mHandler:Landroid/os/Handler;

    sget-wide v2, Lcom/july/dns/MdnsRegistrationListener;->RETRY_MS:J

    invoke-virtual {v1, p0, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void

    :give_up
    sget-object v0, Lcom/july/dns/MdnsRegistrationListener;->TAG:Ljava/lang/String;

    const-string v1, "giving up mDNS retries until the next service start"

    invoke-static {v0, v1}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


.method public cancel()V
    .locals 1

    iget-object v0, p0, Lcom/july/dns/MdnsRegistrationListener;->mHandler:Landroid/os/Handler;

    invoke-virtual {v0, p0}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    return-void
.end method
