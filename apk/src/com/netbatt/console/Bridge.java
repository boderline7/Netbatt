package com.netbatt.console;

import android.content.Context;
import android.webkit.JavascriptInterface;

/** WebView 内的 JS 桥：window.NetBatt.setHotspot(true/false) */
public class Bridge {

    private final Context ctx;

    public Bridge(Context c) { ctx = c; }

    @JavascriptInterface
    public String setHotspot(boolean on) {
        return Tether.setWifi(ctx, on);
    }
}
