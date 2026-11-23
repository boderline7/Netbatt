package com.netbatt.console;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.view.ViewGroup;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {

    private WebView web;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        // 页面在设备上会随时更新，不能吃 WebView 缓存
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        web.clearCache(true);
        web.setWebViewClient(new WebViewClient());
        web.addJavascriptInterface(new Bridge(this), "NetBatt");
        setContentView(web, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        web.loadUrl("http://127.0.0.1:8080/");

        // 首次启动做一次权限自检（该申请的申请，只问一次）
        PermissionGate.runOnce(this);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] grants) {
        super.onRequestPermissionsResult(code, perms, grants);
        if (code == PermissionGate.REQ) PermissionGate.onResult(this, perms, grants);
    }

    /**
     * 返回键：有历史才回退，没历史直接结束。
     * 旧版这里走 super.onBackPressed()，再叠上标准启动模式，
     * 反复从外部拉起时会留下多个实例，按返回像是「退不出去」。
     */
    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
            return;
        }
        finish();
    }
}
