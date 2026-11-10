package com.netbatt.console;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.concurrent.Executor;

/**
 * 热点开关入口：调用系统 TetheringManager（本应用持有 TETHER_PRIVILEGED）。
 * TetheringManager / TetheringRequest 均为 @SystemApi，公开 SDK 中不可见，
 * 故用反射；且 TetheringRequest 在 APEX 里，应用类加载器看不到，
 * 因此参数类型直接从 TetheringManager 的方法签名中取。
 */
final class Tether {

    private static final String TM_CLASS = "android.net.TetheringManager";
    private static final int TETHERING_WIFI = 0;   // ConnectivityManager.TETHERING_WIFI
    private static final int TETHERING_USB = 1;    // ConnectivityManager.TETHERING_USB

    private static Executor mainExecutor() {
        final Handler h = new Handler(Looper.getMainLooper());
        return new Executor() {
            @Override public void execute(Runnable r) { h.post(r); }
        };
    }

    /** 结果写到 files/tether.log，便于用 root 查看 */
    static void log(Context c, String s) {
        try {
            File f = new File(c.getFilesDir(), "tether.log");
            FileOutputStream o = new FileOutputStream(f, true);
            String t = new SimpleDateFormat("MM-dd HH:mm:ss").format(new Date());
            o.write((t + " " + s + "\n").getBytes("UTF-8"));
            o.close();
        } catch (Throwable ignored) { }
    }

    private static Object callback(final Context ctx, Class<?> cbCls) {
        return Proxy.newProxyInstance(cbCls.getClassLoader(), new Class<?>[]{cbCls},
                new InvocationHandler() {
                    @Override public Object invoke(Object p, Method m, Object[] a) {
                        String n = m.getName();
                        if ("onTetheringStarted".equals(n)) {
                            log(ctx, "start OK");
                        } else if ("onTetheringFailed".equals(n)) {
                            log(ctx, "start FAILED error=" + ((a != null && a.length > 0) ? a[0] : "?"));
                        } else if ("toString".equals(n)) {
                            return "NetBattCb";
                        }
                        return null;
                    }
                });
    }

    private static Object buildRequest(Class<?> reqCls, int type) throws Exception {
        Class<?> bld = Class.forName(reqCls.getName() + "$Builder", true, reqCls.getClassLoader());
        Object builder = null;
        for (Constructor<?> c : bld.getConstructors()) {
            Class<?>[] ps = c.getParameterTypes();
            if (ps.length == 1 && ps[0] == int.class) {
                builder = c.newInstance(type);
                break;
            }
        }
        if (builder == null) {
            for (Constructor<?> c : bld.getConstructors()) {
                Class<?>[] ps = c.getParameterTypes();
                if (ps.length == 2 && ps[0] == int.class) {
                    builder = c.newInstance(type, false);
                    break;
                }
            }
        }
        if (builder == null) throw new NoSuchMethodException("TetheringRequest.Builder ctor");
        return bld.getMethod("build").invoke(builder);
    }

    static String setType(Context ctx, int type, boolean on) {
        try {
            Object tm = ctx.getSystemService("tethering");
            if (tm == null) {
                log(ctx, "no TetheringManager");
                return "不可用：没有 TetheringManager";
            }
            Class<?> tmCls = Class.forName(TM_CLASS);

            if (!on) {
                tmCls.getMethod("stopTethering", int.class).invoke(tm, type);
                log(ctx, "stop type=" + type);
                return "已请求关闭共享";
            }

            Method modern = null, legacy = null;
            for (Method m : tmCls.getMethods()) {
                if (!"startTethering".equals(m.getName())) continue;
                Class<?>[] ps = m.getParameterTypes();
                if (ps.length == 3 && ps[0] != int.class && modern == null) modern = m;
                if (ps.length == 3 && ps[0] == int.class) legacy = m;
            }

            if (modern != null) {
                Class<?> reqCls = modern.getParameterTypes()[0];
                Class<?> cbCls = modern.getParameterTypes()[2];
                Object req = buildRequest(reqCls, type);
                modern.invoke(tm, req, mainExecutor(), callback(ctx, cbCls));
                log(ctx, "start type=" + type + " via " + reqCls.getName());
                return "已请求开启共享";
            }
            if (legacy != null) {
                Class<?> cbCls = legacy.getParameterTypes()[2];
                legacy.invoke(tm, type, mainExecutor(), callback(ctx, cbCls));
                log(ctx, "start type=" + type + " via int api");
                return "已请求开启共享";
            }
            log(ctx, "no startTethering method");
            return "失败：找不到 startTethering";
        } catch (Throwable t) {
            Throwable c = t.getCause() != null ? t.getCause() : t;
            log(ctx, "exception " + c);
            return "调用失败：" + c;
        }
    }

    static String setWifi(Context ctx, boolean on) {
        return setType(ctx, TETHERING_WIFI, on);
    }
}
