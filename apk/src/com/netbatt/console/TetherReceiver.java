package com.netbatt.console;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 供网页 CGI 调用：
 *   am broadcast -n com.netbatt.console/.TetherReceiver --ei type 0 --ez on true
 *   type 0 = 热点，1 = USB 共享
 */
public class TetherReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent it) {
        boolean on = it.getBooleanExtra("on", true);
        int type = it.getIntExtra("type", 0);
        Tether.log(ctx, "broadcast type=" + type + " on=" + on);
        Tether.setType(ctx, type, on);
    }
}
