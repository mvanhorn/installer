.class public Lcom/july/oven/LightBridgeService;
.super Landroid/app/Service;
.source "LightBridgeService.java"

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

.method public onStartCommand(Landroid/content/Intent;II)I
    .locals 10

    if-eqz p1, :stop

    const-string v7, "action"
    invoke-virtual {p1, v7}, Landroid/content/Intent;->getStringExtra(Ljava/lang/String;)Ljava/lang/String;
    move-result-object v7

    const-string v2, "scene_id"
    invoke-virtual {p1, v2}, Landroid/content/Intent;->getStringExtra(Ljava/lang/String;)Ljava/lang/String;
    move-result-object v2

    if-eqz v7, :stop
    if-eqz v2, :stop

    const/16 v3, 0x64

    const-string v4, "left"
    invoke-virtual {p1, v4, v3}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I
    move-result v4

    const-string v5, "right"
    invoke-virtual {p1, v5, v3}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I
    move-result v5

    const-string v6, "priority"
    invoke-virtual {p1, v6, v3}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I
    move-result v6

    const-string v3, "enable"
    invoke-virtual {v3, v7}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
    move-result v3

    move-object v1, p0
    new-instance v0, Lcom/july/oven/LightConnection;
    invoke-direct/range {v0 .. v6}, Lcom/july/oven/LightConnection;-><init>(Lcom/july/oven/LightBridgeService;Ljava/lang/String;ZIII)V

    const-string v2, "com.junelife.device.cookmanager"
    const-string v3, "com.junelife.device.cookmanager.service.AxonService"
    new-instance v8, Landroid/content/ComponentName;
    invoke-direct {v8, v2, v3}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    new-instance v7, Landroid/content/Intent;
    invoke-direct {v7}, Landroid/content/Intent;-><init>()V
    invoke-virtual {v7, v8}, Landroid/content/Intent;->setComponent(Landroid/content/ComponentName;)Landroid/content/Intent;

    const/4 v2, 0x1
    invoke-virtual {p0, v7, v0, v2}, Landroid/content/Context;->bindService(Landroid/content/Intent;Landroid/content/ServiceConnection;I)Z
    move-result v2

    if-eqz v2, :stop

    const/4 v2, 0x2
    return v2

    :stop
    invoke-virtual {p0}, Lcom/july/oven/LightBridgeService;->stopSelf()V
    const/4 v2, 0x2
    return v2
.end method
