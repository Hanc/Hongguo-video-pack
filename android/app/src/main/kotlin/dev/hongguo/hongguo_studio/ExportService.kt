package dev.hongguo.hongguo_studio

import android.app.*
import android.content.Intent
import android.os.*

class ExportService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("export", "视频导出任务", NotificationManager.IMPORTANCE_LOW))
        val notification = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "export") else Notification.Builder(this)
        startForeground(1, notification.setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("红葡萄正在制作合集")
            .setContentText("点此返回任务。请保留应用，完成后会自动停止后台服务。")
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true).build())
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hongguo:export").apply { acquire(6 * 60 * 60 * 1000L) }
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onTimeout(startId: Int, fgsType: Int) { stopSelf() }
    override fun onDestroy() { if (wakeLock?.isHeld == true) wakeLock?.release(); super.onDestroy() }
}
