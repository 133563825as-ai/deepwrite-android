package ai.deepwrite.mobile;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.ActivityManager;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.MimeTypeMap;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebChromeClient.FileChooserParams;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.List;

/**
 * DeepWrite 独立版：APK 自带 Node 运行时与应用本体，不依赖任何外部服务。
 *
 * 启动顺序：要存储权限 → 首次解压 assets（约 63MB）→ exec libnode.so server.mjs
 *          → 等 127.0.0.1:8790 就绪 → WebView 全屏加载。
 *
 * 失败时把 node 的日志尾巴直接显示在屏幕上 —— 这类环境问题没有别的手段可查。
 */
public class MainActivity extends Activity {
    // 故意避开 8790：那是容器里跑的 Web 服务用的端口。两者共享同一个 127.0.0.1，
    // 撞端口会让 App 要么起不来、要么 WebView 连到容器那个服务上（看着正常实则连错）。
    private static final int PORT = 18790;
    private static final int REQUEST_FILE_CHOOSER = 1001;
    private static final int REQUEST_LEGACY_STORAGE = 1002;

    private FrameLayout root;
    private WebView webView;
    private LinearLayout statusPanel;
    private TextView statusTitle;
    private TextView statusDetail;
    private TextView statusLog;
    private Button retryButton;

    private RuntimeInstaller installer;
    private NodeRunner runner;
    private ValueCallback<Uri[]> pendingFileChooser;
    private volatile boolean busy = false;

    /**
     * 小窗（freeform）与最近任务里那个标题栏图标，来自 Activity 的 TaskDescription。
     *
     * 不设的话，多数 ROM 会自己回退到清单里的 android:icon；但 vivo 这类定制 ROM
     * 会直接显示**系统默认图标**（用户实测：「开小窗，软件的图标变成原始的了」）。
     * 所以这里显式设一次，走正路。
     */
    @SuppressWarnings("deprecation")
    private void applyTaskDescription() {
        CharSequence label = getApplicationInfo().loadLabel(getPackageManager());
        Bitmap icon = BitmapFactory.decodeResource(getResources(), R.mipmap.ic_launcher);
        setTaskDescription(new ActivityManager.TaskDescription(label.toString(), icon));
    }

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        applyTaskDescription();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        installer = new RuntimeInstaller(this);
        runner = new NodeRunner(this, new File(getFilesDir(), "logs/node.log"));

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#f7f7f6"));

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        webView.setBackgroundColor(Color.parseColor("#f7f7f6"));
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(
                    WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                return openFileChooser(callback, params);
            }
        });
        webView.setWebViewClient(new WebViewClient());
        root.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        buildStatusPanel();
        root.addView(statusPanel, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        setContentView(root);
        applyWindowInsets();
        startFlow();
    }

    /**
     * targetSdk 35+ 强制 edge-to-edge：窗口会一直画到状态栏和导航栏底下。
     * 不给内容留边距的话，顶部会被状态栏压住、底部被手势条压住。
     * 这里直接按系统栏 + 刘海 insets 给根布局加 padding。
     */
    private void applyWindowInsets() {
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View view, WindowInsets insets) {
                int left;
                int top;
                int right;
                int bottom;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Insets bars = insets.getInsets(
                            WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                    left = bars.left;
                    top = bars.top;
                    right = bars.right;
                    bottom = bars.bottom;
                } else {
                    //noinspection deprecation
                    left = insets.getSystemWindowInsetLeft();
                    //noinspection deprecation
                    top = insets.getSystemWindowInsetTop();
                    //noinspection deprecation
                    right = insets.getSystemWindowInsetRight();
                    //noinspection deprecation
                    bottom = insets.getSystemWindowInsetBottom();
                }
                if (view.getPaddingLeft() != left || view.getPaddingTop() != top
                        || view.getPaddingRight() != right || view.getPaddingBottom() != bottom) {
                    view.setPadding(left, top, right, bottom);
                }
                return insets;
            }
        });
        root.requestApplyInsets();
    }

    /* ---------------- 状态面板 ---------------- */

    private void buildStatusPanel() {
        statusPanel = new LinearLayout(this);
        statusPanel.setOrientation(LinearLayout.VERTICAL);
        statusPanel.setBackgroundColor(Color.parseColor("#f7f7f6"));
        statusPanel.setGravity(Gravity.CENTER);
        int pad = dp(28);
        statusPanel.setPadding(pad, pad, pad, pad);

        statusTitle = new TextView(this);
        statusTitle.setText("DeepWrite");
        statusTitle.setTextColor(Color.parseColor("#2b2b2b"));
        statusTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 21);
        statusTitle.setTypeface(Typeface.DEFAULT_BOLD);
        statusTitle.setGravity(Gravity.CENTER);
        statusPanel.addView(statusTitle);

        statusDetail = new TextView(this);
        statusDetail.setTextColor(Color.parseColor("#5a5a5a"));
        statusDetail.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        statusDetail.setGravity(Gravity.CENTER);
        statusDetail.setPadding(0, dp(12), 0, dp(12));
        statusPanel.addView(statusDetail);

        statusLog = new TextView(this);
        statusLog.setTextColor(Color.parseColor("#8a4a4a"));
        statusLog.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10);
        statusLog.setGravity(Gravity.START);
        statusLog.setVisibility(View.GONE);
        statusPanel.addView(statusLog);

        retryButton = new Button(this);
        retryButton.setText("重试");
        retryButton.setVisibility(View.GONE);
        retryButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                startFlow();
            }
        });
        statusPanel.addView(retryButton);
    }

    private int dp(int value) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }

    private void setStatus(final String title, final String detail, final boolean showRetry) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                statusPanel.setVisibility(View.VISIBLE);
                statusTitle.setText(title);
                statusDetail.setText(detail);
                retryButton.setVisibility(showRetry ? View.VISIBLE : View.GONE);
            }
        });
    }

    private void showFailure(final String detail) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                statusPanel.setVisibility(View.VISIBLE);
                statusTitle.setText("启动失败");
                statusDetail.setText(detail + "\n\nnode 退出码 " + runner.exitCode()
                        + "\n日志：" + runner.logFile().getAbsolutePath());
                statusLog.setVisibility(View.VISIBLE);
                statusLog.setText(tailLog(24));
                retryButton.setVisibility(View.VISIBLE);
            }
        });
    }

    private String tailLog(int maxLines) {
        File file = runner.logFile();
        if (!file.exists()) {
            return "(还没有日志)";
        }
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            long length = raf.length();
            long start = Math.max(0, length - 48 * 1024);
            raf.seek(start);
            byte[] buffer = new byte[(int) (length - start)];
            raf.readFully(buffer);
            String[] lines = new String(buffer, "UTF-8").split("\n");
            StringBuilder builder = new StringBuilder();
            for (int index = Math.max(0, lines.length - maxLines); index < lines.length; index += 1) {
                builder.append(lines[index]).append('\n');
            }
            return builder.toString();
        } catch (Exception error) {
            return "(读取日志失败：" + error.getMessage() + ")";
        }
    }

    /* ---------------- 启动流程 ---------------- */

    private void startFlow() {
        if (busy) {
            return;
        }
        busy = true;
        retryButton.setVisibility(View.GONE);
        statusLog.setVisibility(View.GONE);

        if (!hasStorageAccess()) {
            busy = false;
            setStatus("需要文件访问权限",
                    "作品要存在手机的 Documents/DeepWrite 里，\n授权后回到本页面会自动继续。", true);
            requestStorageAccess();
            return;
        }

        setStatus("正在启动", "准备运行时…", false);
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    if (runner.isAlive()) {
                        runner.stop();
                    }
                    File dataDir = new File(getFilesDir(), "data");
                    File documentsDir = new File(
                            Environment.getExternalStorageDirectory(), "Documents/DeepWrite");

                    if (!installer.isInstalled()) {
                        setStatus("首次启动", "正在解压运行时（约 137MB），只需一次…", false);
                        installer.install(new RuntimeInstaller.Progress() {
                            @Override
                            public void onProgress(int percent, String message) {
                                setStatus("正在准备", percent + "%", false);
                            }
                        });
                    }

                    setStatus("正在启动", "拉起 Node 运行时…", false);
                    runner.start(installer.nodeBinary(), installer.runtimeDir(),
                            installer.webDir(), dataDir, documentsDir, PORT);

                    setStatus("正在启动", "等待服务就绪…", false);
                    if (!runner.waitUntilReady(PORT, 90_000L)) {
                        showFailure("Node 服务没有在 90 秒内就绪。");
                        return;
                    }

                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            webView.loadUrl("http://127.0.0.1:" + PORT + "/");
                            statusPanel.setVisibility(View.GONE);
                        }
                    });
                } catch (final Throwable error) {
                    showFailure(String.valueOf(
                            error.getMessage() == null ? error : error.getMessage()));
                } finally {
                    busy = false;
                }
            }
        }, "dw-boot").start();
    }

    /* ---------------- 存储权限 ---------------- */

    private boolean hasStorageAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager();
        }
        return checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestStorageAccess() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } else {
                requestPermissions(
                        new String[] { Manifest.permission.WRITE_EXTERNAL_STORAGE },
                        REQUEST_LEGACY_STORAGE);
            }
        } catch (ActivityNotFoundException error) {
            Toast.makeText(this, "请手动到系统设置里授予「所有文件访问权限」", Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 从权限页回来时自动续上
        if (!busy && hasStorageAccess() && !runner.isAlive()) {
            startFlow();
        }
    }

    /* ---------------- 文件选择（页面里的 <input type=file>） ---------------- */

    private boolean openFileChooser(ValueCallback<Uri[]> callback, FileChooserParams params) {
        if (pendingFileChooser != null) {
            pendingFileChooser.onReceiveValue(null);
            pendingFileChooser = null;
        }
        pendingFileChooser = callback;

        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        if (params != null && params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }
        // 页面给的 accept 列表长这样：".txt,.md,.markdown,.pdf,image/png,image/jpeg,…"
        // 里面既有扩展名写法也有 MIME 写法。Android 的取文件界面只认 MIME，
        // 之前把不带 "/" 的项直接丢掉 —— 于是 .txt/.md/.pdf 全没了，只剩 image/*，
        // 表现就是「只能选图片」。所以：扩展名先映射成 MIME，映射不出来就记一笔，
        // 这时干脆不收窄（宁可让用户选到不支持的格式，也不能把支持的全挡住）。
        List<String> mimeTypes = new ArrayList<>();
        boolean sawUnknownExtension = false;
        if (params != null && params.getAcceptTypes() != null) {
            for (String accept : params.getAcceptTypes()) {
                if (accept == null || accept.isEmpty() || "*/*".equals(accept)) {
                    continue;
                }
                if (accept.contains("/")) {
                    mimeTypes.add(accept);
                    continue;
                }
                String mapped = extensionToMimeType(accept);
                if (mapped != null) {
                    mimeTypes.add(mapped);
                } else {
                    sawUnknownExtension = true;
                }
            }
        }
        if (!sawUnknownExtension && !mimeTypes.isEmpty()) {
            if (mimeTypes.size() == 1) {
                intent.setType(mimeTypes.get(0));
            } else {
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toArray(new String[0]));
            }
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

    /**
     * 扩展名 → MIME。
     *
     * 只覆盖页面 accept 里真正会出现的那几个；查不到就返回 null，
     * 调用方据此放弃按类型收窄 —— 猜错比不收窄更糟（会把能选的文件挡掉）。
     */
    private String extensionToMimeType(String accept) {
        String extension = accept.startsWith(".") ? accept.substring(1) : accept;
        String fromSystem = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                extension.toLowerCase(java.util.Locale.ROOT));
        if (fromSystem != null) {
            return fromSystem;
        }
        switch (extension.toLowerCase(java.util.Locale.ROOT)) {
            case "md":
            case "markdown":
                // 不少系统不认 text/markdown，退到 text/plain 才看得见 .md
                return "text/plain";
            case "txt":
                return "text/plain";
            case "pdf":
                return "application/pdf";
            default:
                return null;
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
        pendingFileChooser.onReceiveValue(results);
        pendingFileChooser = null;
    }

    /* ---------------- 生命周期 ---------------- */

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && webView != null && webView.canGoBack()) {
            webView.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onDestroy() {
        if (pendingFileChooser != null) {
            pendingFileChooser.onReceiveValue(null);
            pendingFileChooser = null;
        }
        if (runner != null) {
            runner.stop();
        }
        super.onDestroy();
    }
}
