package ai.deepwrite.mobile;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.system.Os;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Iterator;

/**
 * 把 assets 里的运行时与 Web 产物铺到应用私有目录。
 *
 * 首次启动要做一次（约 79MB），之后靠一个「安装指纹」跳过。
 * 用清单文件驱动而不是 AssetManager.list()：空目录和文件在 list() 眼里长得一样，
 * 分不清就会漏文件。
 */
public class RuntimeInstaller {
    private static final String TAG = "DWRuntime";

    private static final int BUFFER = 128 * 1024;

    /**
     * 标记文件。名字固定，**内容**是安装指纹。
     *
     * 历史坑：这里原来是编译期常量 ASSET_VERSION = "1"，只有「资产结构变了」才手动 +1。
     * 结果覆盖安装新 APK 时旧标记还在 → isInstalled() 仍然为真 → 新资产永远铺不下来，
     * 手机上一直跑第一次安装时那份。表现是界面能出来、但每个命令都回
     * "No IPC handler registered for channel deepwrite:command"（主进程模块缺失没加载）。
     * 现在指纹由构建期算的资产哈希 + versionCode 组成，换包必重解压。
     */
    private static final String MARKER_NAME = ".assets";
    private static final String LEGACY_MARKER_PREFIX = ".assets-";

    public interface Progress {
        void onProgress(int percent, String message);
    }

    private final Context context;
    private final File baseDir;
    private String cachedAssetVersion;

    public RuntimeInstaller(Context context) {
        this.context = context.getApplicationContext();
        this.baseDir = this.context.getFilesDir();
    }

    public File runtimeDir() {
        return new File(baseDir, "runtime");
    }

    public File webDir() {
        return new File(baseDir, "web");
    }

    /** node 二进制在 nativeLibraryDir —— 只有那里允许 exec（Android 10+ 的 W^X）。 */
    public File nodeBinary() {
        return new File(context.getApplicationInfo().nativeLibraryDir, "libnode.so");
    }

    private File marker() {
        return new File(baseDir, MARKER_NAME);
    }

    /**
     * 安装指纹 = 资产清单里的 version（构建期按资产内容算出的哈希）+ 本包 versionCode。
     *
     * 带上 versionCode 是为了「资产没变但换了包」也能重解压一次：宁可多解压一次，
     * 也不要让手机上跑着半新半旧的两份资产。
     */
    public String installKey() {
        return assetVersion() + "-vc" + versionCode();
    }

    private String assetVersion() {
        if (cachedAssetVersion == null) {
            cachedAssetVersion = readManifestVersion();
        }
        return cachedAssetVersion;
    }

    private String readManifestVersion() {
        String raw = readAssetText("manifest.json");
        if (raw == null) {
            // 清单都不在，说明包不完整：返回不会撞上的值，逼出一次重新解压。
            return "no-manifest";
        }
        try {
            Object version = new JSONObject(raw).opt("version");
            return version == null ? "unknown" : String.valueOf(version);
        } catch (Exception error) {
            return "bad-manifest";
        }
    }

    private long versionCode() {
        try {
            PackageInfo info = context.getPackageManager()
                    .getPackageInfo(context.getPackageName(), 0);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                return info.getLongVersionCode();
            }
            return info.versionCode;
        } catch (Exception error) {
            Log.w(TAG, "读不到 versionCode：" + error.getMessage());
            return 0;
        }
    }

    public boolean isInstalled() {
        if (!marker().exists()) {
            return false;
        }
        if (!new File(webDir(), "server.mjs").exists() || !nodeBinary().exists()) {
            return false;
        }
        try {
            String recorded = new String(readFile(marker()), "UTF-8").trim();
            return recorded.equals(installKey());
        } catch (IOException error) {
            return false;
        }
    }

    public void install(Progress progress) throws Exception {
        deleteLegacyMarkers();
        marker().delete();
        deleteRecursively(runtimeDir());
        deleteRecursively(webDir());
        runtimeDir().mkdirs();
        webDir().mkdirs();

        extractManifest(progress);
        createLibraryLinks();

        try (FileOutputStream out = new FileOutputStream(marker())) {
            out.write(installKey().getBytes("UTF-8"));
        }
        Log.i(TAG, "资产已就位（指纹 " + installKey() + "）：" + runtimeDir() + " / " + webDir());
    }

    /** 清掉老版本留下的 ".assets-1" 那类标记，免得它们干扰判断。 */
    private void deleteLegacyMarkers() {
        File[] children = baseDir.listFiles();
        if (children == null) {
            return;
        }
        for (File child : children) {
            if (child.getName().startsWith(LEGACY_MARKER_PREFIX)) {
                //noinspection ResultOfMethodCallIgnored
                child.delete();
            }
        }
    }

    private void extractManifest(Progress progress) throws Exception {
        String raw = readAssetText("manifest.json");
        if (raw == null) {
            throw new IOException("assets/manifest.json 缺失，APK 打包不完整");
        }
        JSONObject root = new JSONObject(raw);
        JSONArray files = root.getJSONArray("files");
        long total = root.optLong("total", 0);
        long done = 0;
        int lastPercent = -1;
        for (int index = 0; index < files.length(); index += 1) {
            JSONObject entry = files.getJSONObject(index);
            String path = entry.getString("p");
            long size = entry.optLong("s", 0);
            File target = new File(baseDir, path);
            File parent = target.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                throw new IOException("无法创建目录 " + parent);
            }
            copyAsset(path, target);
            done += size;
            if (progress != null && total > 0) {
                int percent = (int) (done * 100 / total);
                if (percent != lastPercent) {
                    lastPercent = percent;
                    progress.onProgress(percent, path);
                }
            }
        }
    }

    /**
     * 重建 .so 的符号链接。
     * 包里为了省空间只放真实文件（libicudata.so.78.3），但链接器按 SONAME 找
     * （libicudata.so.78），所以必须把链接补出来。
     */
    private void createLibraryLinks() throws Exception {
        File libDir = new File(runtimeDir(), "lib");
        String raw = readAssetText("runtime/links.json");
        if (raw == null || raw.isEmpty()) {
            return;
        }
        JSONObject links = new JSONObject(raw);
        int created = 0;
        int copied = 0;
        Iterator<String> keys = links.keys();
        while (keys.hasNext()) {
            String name = keys.next();
            String targetName = links.getString(name);
            File target = new File(libDir, targetName);
            if (!target.exists()) {
                continue;
            }
            File link = new File(libDir, name);
            if (link.exists() || isSymlink(link)) {
                link.delete();
            }
            try {
                Os.symlink(targetName, link.getAbsolutePath());
                created += 1;
            } catch (Exception error) {
                // 退路：复制一份实体。占空间但一定能加载。
                copyFile(target, link);
                copied += 1;
            }
        }
        Log.i(TAG, "符号链接：建立 " + created + " 条，退化为复制 " + copied + " 条");
    }

    private boolean isSymlink(File file) {
        try {
            File canonical = file.getCanonicalFile();
            return !canonical.equals(file.getAbsoluteFile());
        } catch (IOException error) {
            return false;
        }
    }

    private void copyAsset(String assetPath, File target) throws IOException {
        try (InputStream in = context.getAssets().open(assetPath);
             OutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[BUFFER];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
        }
    }

    private void copyFile(File source, File target) throws IOException {
        try (InputStream in = new java.io.FileInputStream(source);
             OutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[BUFFER];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
        }
    }

    private byte[] readFile(File file) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            return out.toByteArray();
        }
    }

    private String readAssetText(String path) {
        try (InputStream in = context.getAssets().open(path)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            return out.toString("UTF-8");
        } catch (IOException error) {
            return null;
        }
    }

    static void deleteRecursively(File file) {
        if (file == null || !file.exists()) {
            return;
        }
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        //noinspection ResultOfMethodCallIgnored
        file.delete();
    }
}
