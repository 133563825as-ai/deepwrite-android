package ai.deepwrite.mobile;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebChromeClient.FileChooserParams;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.Toast;
import android.graphics.Typeface;
import android.view.Gravity;
import android.util.TypedValue;

import java.util.ArrayList;
import java.util.List;

/**
 * DeepWrite 手机端外壳：加载本机运行的 DeepWrite Web 服务。
 * 服务不通时显示引导页，并允许用户重试或换地址。
 */
public class MainActivity extends Activity {
    private static final String DEFAULT_URL = "http://127.0.0.1:8790/";

    private WebView webView;
    private FrameLayout root;
    private View errorView;
    private String currentUrl = DEFAULT_URL;

    /** 页面发起的文件选择请求；同一时刻只能有一个，未回填前必须保持引用。 */
    private ValueCallback<Uri[]> pendingFileChooser;
    private static final int REQUEST_FILE_CHOOSER = 1001;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#f7f7f6"));

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(true);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);

        webView.setBackgroundColor(Color.parseColor("#f7f7f6"));
        // 没有 onShowFileChooser 的 WebChromeClient，页面里的 <input type="file">
        // 点了完全没反应 —— 这就是手机端「不支持上传文件」的直接原因。
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(
                    WebView view,
                    ValueCallback<Uri[]> filePathCallback,
                    FileChooserParams fileChooserParams) {
                return openFileChooser(filePathCallback, fileChooserParams);
            }
        });
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (uri == null) return false;
                String scheme = uri.getScheme();
                if (scheme != null && (scheme.equals("http") || scheme.equals("https"))) {
                    String host = uri.getHost();
                    if (host != null && (host.equals("127.0.0.1") || host.equals("localhost"))) {
                        return false;
                    }
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                hideError();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    showError();
                }
            }
        });

        root.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        buildErrorView();
        setContentView(root);
        webView.loadUrl(currentUrl);
    }

    private void buildErrorView() {
        FrameLayout layout = new FrameLayout(this);
        layout.setBackgroundColor(Color.parseColor("#f7f7f6"));
        layout.setVisibility(View.GONE);

        TextView text = new TextView(this);
        text.setText("连不上 DeepWrite 服务。\n\n请先在容器里启动服务，再点这里重试。\n服务地址：" + DEFAULT_URL);
        text.setTextColor(Color.parseColor("#3a3a3a"));
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        text.setTypeface(Typeface.DEFAULT);
        text.setGravity(Gravity.CENTER);
        text.setPadding(48, 48, 48, 48);
        text.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                hideError();
                webView.reload();
                Toast.makeText(MainActivity.this, "重新连接中…", Toast.LENGTH_SHORT).show();
            }
        });

        layout.addView(text, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        errorView = layout;
        root.addView(errorView);
    }

    private void showError() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                errorView.setVisibility(View.VISIBLE);
            }
        });
    }

    private void hideError() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                errorView.setVisibility(View.GONE);
            }
        });
    }

    /* ---------------- 文件选择：页面里的 <input type="file"> 落到这里 ---------------- */

    private boolean openFileChooser(ValueCallback<Uri[]> callback, FileChooserParams params) {
        if (pendingFileChooser != null) {
            // 上一次没回填就再来一次，先按取消收尾，否则页面会一直挂着等结果
            pendingFileChooser.onReceiveValue(null);
            pendingFileChooser = null;
        }
        pendingFileChooser = callback;

        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        // webkitdirectory 在 Android WebView 里没有实现，选目录一律回落到页面的手输路径。
        if (params != null && params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }
        List<String> mimeTypes = new ArrayList<>();
        if (params != null && params.getAcceptTypes() != null) {
            for (String accept : params.getAcceptTypes()) {
                // 页面的 accept 写的是扩展名（.md/.txt），这里只挑真正的 MIME
                if (accept != null && accept.contains("/")) {
                    mimeTypes.add(accept);
                }
            }
        }
        if (mimeTypes.size() == 1) {
            intent.setType(mimeTypes.get(0));
        } else if (mimeTypes.size() > 1) {
            intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toArray(new String[0]));
        }

        try {
            startActivityForResult(Intent.createChooser(intent, "选择文件"), REQUEST_FILE_CHOOSER);
            return true;
        } catch (ActivityNotFoundException error) {
            pendingFileChooser = null;
            Toast.makeText(this, "这台设备上没有可用的文件选择器", Toast.LENGTH_LONG).show();
            return false;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_FILE_CHOOSER) {
            super.onActivityResult(requestCode, resultCode, data);
            return;
        }
        if (pendingFileChooser == null) {
            return;
        }
        Uri[] results = null;
        if (resultCode == Activity.RESULT_OK && data != null) {
            if (data.getClipData() != null) {
                int count = data.getClipData().getItemCount();
                results = new Uri[count];
                for (int index = 0; index < count; index += 1) {
                    results[index] = data.getClipData().getItemAt(index).getUri();
                }
            } else if (data.getData() != null) {
                results = new Uri[] { data.getData() };
            }
        }
        // null 就是「用户取消」，这是 WebView 的约定
        pendingFileChooser.onReceiveValue(results);
        pendingFileChooser = null;
    }

    @Override
    protected void onDestroy() {
        if (pendingFileChooser != null) {
            pendingFileChooser.onReceiveValue(null);
            pendingFileChooser = null;
        }
        super.onDestroy();
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && webView != null && webView.canGoBack()) {
            webView.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }
}
