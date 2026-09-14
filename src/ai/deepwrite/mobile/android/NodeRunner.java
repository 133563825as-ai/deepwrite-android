package ai.deepwrite.mobile.android;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Map;

/**
 * 在本机拉起 Node 运行时（libnode.so + server.mjs），不做任何跨进程之外的魔法。
 *
 * node 二进制放在 nativeLibraryDir：Android 10 起应用不得 exec 自己可写目录里的文件，
 * 而 APK 的 lib/<abi>/ 是唯一被允许执行的落点，所以它必须叫 libnode.so。
 */
public class NodeRunner {
    private static final String TAG = "DWNode";

    private final Context context;
    private final File logFile;
    private Process process;

    public NodeRunner(Context context, File logFile) {
        this.context = context.getApplicationContext();
        this.logFile = logFile;
    }

    public File logFile() {
        return logFile;
    }

    public void start(
            File nodeBinary,
            File runtimeDir,
            File webDir,
            File dataDir,
            File documentsDir,
            File legacyDocumentsDir,
            int port) throws IOException {
        File libDir = new File(runtimeDir, "lib");
        File home = new File(dataDir, "home");
        File tmp = new File(dataDir, "tmp");
        // 日志目录必须先建：ProcessBuilder 的重定向不会替我们建父目录，
        // 少了这一步会在真正 exec 之前就抛 ENOENT。
        File logDir = logFile.getParentFile();
        if (logDir != null && !logDir.exists() && !logDir.mkdirs()) {
            throw new IOException("无法创建日志目录 " + logDir);
        }
        //noinspection ResultOfMethodCallIgnored
        home.mkdirs();
        //noinspection ResultOfMethodCallIgnored
        tmp.mkdirs();
        //noinspection ResultOfMethodCallIgnored
        documentsDir.mkdirs();

        ProcessBuilder builder = new ProcessBuilder(nodeBinary.getAbsolutePath(), "server.mjs");
        builder.directory(webDir);
        Map<String, String> env = builder.environment();
        // 依赖库不在系统路径里，靠 LD_LIBRARY_PATH 指过去
        env.put("LD_LIBRARY_PATH", libDir.getAbsolutePath());
        // 调模型 API 要走 HTTPS，必须给它一套 CA
        env.put("NODE_EXTRA_CA_CERTS", new File(runtimeDir, "cacert.pem").getAbsolutePath());
        env.put("DEEPWRITE_USER_DATA_PATH", dataDir.getAbsolutePath());
        env.put("DEEPWRITE_DOCUMENTS_PATH", documentsDir.getAbsolutePath());
        // 上一版的默认工作目录。主进程只拿它做**一次性搬家**：配置里存的正好是
        // 这个旧值就重指到新默认值（不搬文件）。见 workspace-directory-store.ts。
        env.put("DEEPWRITE_LEGACY_DOCUMENTS_PATH", legacyDocumentsDir.getAbsolutePath());
        env.put("DEEPWRITE_WEB_PORT", String.valueOf(port));
        env.put("DEEPWRITE_WEB_HOST", "127.0.0.1");
        env.put("HOME", home.getAbsolutePath());
        env.put("TMPDIR", tmp.getAbsolutePath());
        env.put("PATH", "/system/bin:/system/xbin");
        env.put("LANG", "zh_CN.UTF-8");
        env.put("LC_ALL", "zh_CN.UTF-8");
        builder.redirectErrorStream(true);
        builder.redirectOutput(ProcessBuilder.Redirect.appendTo(logFile));

        process = builder.start();
        // 这里不能打 process.pid()：那是 Java 9+ 的 API，Android 的 Process 没有它。
        Log.i(TAG, "node 已启动，cwd=" + webDir);
    }

    /** 轮询 /__status 直到服务就绪、进程死亡或超时。 */
    public boolean waitUntilReady(int port, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (process != null && !process.isAlive()) {
                Log.w(TAG, "node 进程提前退出，exit=" + process.exitValue());
                return false;
            }
            if (probe(port)) {
                return true;
            }
            try {
                Thread.sleep(400);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return false;
    }

    private boolean probe(int port) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL("http://127.0.0.1:" + port + "/__status").openConnection();
            connection.setConnectTimeout(1500);
            connection.setReadTimeout(1500);
            return connection.getResponseCode() == 200;
        } catch (Exception error) {
            return false;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    public boolean isAlive() {
        return process != null && process.isAlive();
    }

    public int exitCode() {
        try {
            return process == null ? -1 : process.exitValue();
        } catch (IllegalThreadStateException error) {
            return -1;
        }
    }

    public void stop() {
        if (process == null) {
            return;
        }
        process.destroy();
        try {
            Thread.sleep(400);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        }
        if (process.isAlive()) {
            process.destroyForcibly();
        }
        process = null;
    }
}
