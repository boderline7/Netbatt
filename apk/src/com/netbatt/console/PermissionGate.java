package com.netbatt.console;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import java.util.ArrayList;
import java.util.List;

/**
 * 首次启动做一次权限自检。
 *
 * 现状：这个应用没有任何「危险权限」——网络/无线状态是 normal 安装即给，
 * 开热点走 TETHER_PRIVILEGED（privapp 白名单，安装即在），所以这里不会弹框。
 * 留着这套机制是为了以后加能力时不用再改启动流程：
 * 新增运行期权限只要写进 wanted()，首次启动就会自动申请一次（只问一次，不骚扰）。
 */
final class PermissionGate {

    private static final String PREF = "netbatt";
    private static final String KEY_DONE = "perm_asked_v1";

    static final int REQ = 1001;

    /** 需要运行期授权的权限清单。通知是 Android 13(API 33) 才有的运行期权限。 */
    private static List<String> wanted() {
        List<String> l = new ArrayList<String>();
        if (Build.VERSION.SDK_INT >= 33) {
            l.add("android.permission.POST_NOTIFICATIONS");
        }
        return l;
    }

    static void runOnce(Activity a) {
        SharedPreferences sp = a.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        if (sp.getBoolean(KEY_DONE, false)) return;

        List<String> miss = new ArrayList<String>();
        for (String p : wanted()) {
            try {
                if (a.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) miss.add(p);
            } catch (Throwable ignored) {
                // 该权限在本 ROM 上不存在，跳过
            }
        }

        sp.edit().putBoolean(KEY_DONE, true).apply();

        if (miss.isEmpty()) {
            Tether.log(a, "权限自检: 无需申请（装机已授予）");
        } else {
            Tether.log(a, "权限自检: 申请 " + miss);
            try {
                a.requestPermissions(miss.toArray(new String[0]), REQ);
            } catch (Throwable t) {
                Tether.log(a, "权限自检: 申请失败 " + t);
            }
        }
    }

    static void onResult(Activity a, String[] perms, int[] grants) {
        if (perms == null) return;
        StringBuilder sb = new StringBuilder("权限自检结果:");
        for (int i = 0; i < perms.length; i++) {
            boolean ok = i < grants.length && grants[i] == PackageManager.PERMISSION_GRANTED;
            sb.append(' ').append(perms[i]).append('=').append(ok ? "授予" : "拒绝");
        }
        Tether.log(a, sb.toString());
    }
}
