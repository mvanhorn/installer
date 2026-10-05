.class public Lcom/july/oven/LightConnection;
.super Ljava/lang/Object;
.implements Landroid/content/ServiceConnection;
.source "LightConnection.java"

.field private final mEnable:Z

.field private final mLeft:I

.field private final mPriority:I

.field private final mRight:I

.field private final mSceneId:Ljava/lang/String;

.field private final mService:Lcom/july/oven/LightBridgeService;

.method public constructor <init>(Lcom/july/oven/LightBridgeService;Ljava/lang/String;ZIII)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/july/oven/LightConnection;->mService:Lcom/july/oven/LightBridgeService;
    iput-object p2, p0, Lcom/july/oven/LightConnection;->mSceneId:Ljava/lang/String;
    iput-boolean p3, p0, Lcom/july/oven/LightConnection;->mEnable:Z
    iput p4, p0, Lcom/july/oven/LightConnection;->mLeft:I
    iput p5, p0, Lcom/july/oven/LightConnection;->mRight:I
    iput p6, p0, Lcom/july/oven/LightConnection;->mPriority:I

    return-void
.end method

.method public onServiceConnected(Landroid/content/ComponentName;Landroid/os/IBinder;)V
    .locals 6

    invoke-static {}, Landroid/os/Parcel;->obtain()Landroid/os/Parcel;
    move-result-object v0
    invoke-static {}, Landroid/os/Parcel;->obtain()Landroid/os/Parcel;
    move-result-object v1

    :try_start
    const-string v2, "com.junelife.device.cookmanager.AxonServiceInterface"
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeInterfaceToken(Ljava/lang/String;)V

    const/4 v2, 0x1
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeInt(I)V

    iget-object v2, p0, Lcom/july/oven/LightConnection;->mSceneId:Ljava/lang/String;
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeString(Ljava/lang/String;)V

    iget v2, p0, Lcom/july/oven/LightConnection;->mLeft:I
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeInt(I)V

    iget v2, p0, Lcom/july/oven/LightConnection;->mRight:I
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeInt(I)V

    iget v2, p0, Lcom/july/oven/LightConnection;->mPriority:I
    invoke-virtual {v0, v2}, Landroid/os/Parcel;->writeInt(I)V

    iget-boolean v2, p0, Lcom/july/oven/LightConnection;->mEnable:Z
    if-eqz v2, :disable

    const/16 v2, 0xc
    goto :transact

    :disable
    const/16 v2, 0xd

    :transact
    const/4 v3, 0x0
    invoke-interface {p2, v2, v0, v1, v3}, Landroid/os/IBinder;->transact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z
    invoke-virtual {v1}, Landroid/os/Parcel;->readException()V
    :try_end
    .catch Ljava/lang/Throwable; {:try_start .. :try_end} :catch

    goto :cleanup

    :catch
    invoke-virtual {v1}, Landroid/os/Parcel;->recycle()V
    invoke-virtual {v0}, Landroid/os/Parcel;->recycle()V
    iget-object v0, p0, Lcom/july/oven/LightConnection;->mService:Lcom/july/oven/LightBridgeService;
    invoke-virtual {v0}, Lcom/july/oven/LightBridgeService;->stopSelf()V
    return-void

    :cleanup
    invoke-virtual {v1}, Landroid/os/Parcel;->recycle()V
    invoke-virtual {v0}, Landroid/os/Parcel;->recycle()V
    iget-object v0, p0, Lcom/july/oven/LightConnection;->mService:Lcom/july/oven/LightBridgeService;
    invoke-virtual {v0, p0}, Landroid/content/Context;->unbindService(Landroid/content/ServiceConnection;)V
    iget-object v0, p0, Lcom/july/oven/LightConnection;->mService:Lcom/july/oven/LightBridgeService;
    invoke-virtual {v0}, Lcom/july/oven/LightBridgeService;->stopSelf()V

    return-void
.end method

.method public onServiceDisconnected(Landroid/content/ComponentName;)V
    .locals 1

    iget-object v0, p0, Lcom/july/oven/LightConnection;->mService:Lcom/july/oven/LightBridgeService;
    invoke-virtual {v0}, Lcom/july/oven/LightBridgeService;->stopSelf()V

    return-void
.end method
