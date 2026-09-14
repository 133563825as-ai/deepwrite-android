/**
 * 构建期冒烟：从**打包好的资产树**里 fork 三个 utility，验证它们能加载。
 *
 * 为什么这个测试可信（也是它值钱的地方）：
 * 资产树 build/apk/assets/web 自带 node_modules，而它的**任何祖先目录都没有
 * node_modules**。也就是说 node 在这棵树里做模块解析时没有向上逃逸的余地 ——
 * 行为和手机上 /data/.../files/web 完全一致。于是「容器跑得通、手机跑不通」
 * 这类问题（3.0.0 的绝对路径、3.1.0 的 ESM-only 漏包）可以在构建期 2 秒内
 * 暴露，而不是等用户装到手机上、截图、我猜、再打包 —— 一轮 5 分钟。
 *
 * ⚠️ 所以脚本会**主动断言祖先目录里没有 node_modules**：一旦有，这个测试就
 * 失去意义（会假阳性通过），必须报错而不是悄悄放过。
 *
 * 用法：node verify-utilities.mjs <WEB_DIR>
 * 退出码：0 三个都活着；1 有 utility 起不来。
 */
import { existsSync } from "node:fs";
import { fork } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { mkdirSync } from "node:fs";

const web = resolve(process.argv[2] ?? "");
if (!web || !existsSync(web)) {
  console.error("用法：node verify-utilities.mjs <WEB_DIR>");
  process.exit(2);
}

// --- 前置断言：这棵树必须没有向上逃逸的余地 ---
const escapeHatches = [];
for (let dir = dirname(web); dir !== dirname(dir); dir = dirname(dir)) {
  if (existsSync(join(dir, "node_modules"))) escapeHatches.push(join(dir, "node_modules"));
}
if (escapeHatches.length > 0) {
  console.error("✗ 冒烟测试失效：资产树的祖先目录里存在 node_modules，");
  console.error("  node 会向上逃逸解析，测出来的结果不能代表真机：");
  for (const hatch of escapeHatches) console.error(`      ${hatch}`);
  process.exit(1);
}

const ENTRIES = [
  "main/utilities/agent-entry.js",
  "main/utilities/core-entry.js",
  "main/utilities/tool-entry.js"
];
const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS ?? 12000);
const preload = join(web, "node_modules/electron/utility-parent-port.cjs");
const sandbox = process.env.SMOKE_DATA ?? "/tmp/dw-smoke-data";
mkdirSync(sandbox, { recursive: true });

if (!existsSync(preload)) {
  console.error(`✗ 缺少 preload：${preload}`);
  process.exit(1);
}

/**
 * 起一个 utility，等它「安静地活着」或者「报错退出」。
 * 活着 = 模块闭包完整（它在等 IPC 握手，不会自己退出）。
 */
function probe(entryRel) {
  return new Promise((done) => {
    const entry = join(web, entryRel);
    if (!existsSync(entry)) {
      done({ entryRel, ok: false, reason: "入口文件不存在" });
      return;
    }
    const child = fork(entry, [], {
      cwd: web,
      stdio: ["ignore", "pipe", "pipe", "ipc"],
      serialization: "json",
      execArgv: ["--require", preload],
      env: {
        ...process.env,
        DEEPWRITE_USER_DATA_PATH: sandbox,
        DEEPWRITE_DOCUMENTS_PATH: sandbox,
        DEEPWRITE_WEB_PORT: "18799",
        DEEPWRITE_WEB_HOST: "127.0.0.1",
        HOME: sandbox,
        TMPDIR: sandbox
      }
    });

    let stderr = "";
    let settled = false;
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        child.kill("SIGKILL");
      } catch {
        /* 已经退出了 */
      }
      done({ entryRel, ...result });
    };

    const timer = setTimeout(() => finish({ ok: true, reason: "活着（在等 IPC 握手）" }), TIMEOUT_MS);

    child.on("exit", (code) => {
      // 退出码 0 等同于「它自己干完活了」，也算加载成功；
      // 非 0 基本就是 ERR_MODULE_NOT_FOUND 那一类，把 stderr 带出去。
      if (code === 0) finish({ ok: true, reason: "已正常退出" });
      else finish({ ok: false, reason: `exit=${code}`, stderr });
    });
    child.on("error", (error) => finish({ ok: false, reason: String(error?.message ?? error) }));
  });
}

const results = [];
for (const entryRel of ENTRIES) {
  results.push(await probe(entryRel));
}

let failed = 0;
for (const result of results) {
  if (result.ok) {
    console.log(`   ✓ ${result.entryRel.padEnd(18)} ${result.reason}`);
  } else {
    failed += 1;
    console.error(`   ✗ ${result.entryRel.padEnd(18)} ${result.reason}`);
    if (result.stderr) {
      // 只留最能说明问题的那几行：模块解析错误在第一段。
      const lines = result.stderr.trim().split("\n").slice(0, 8);
      for (const line of lines) console.error(`       ${line}`);
    }
  }
}

if (failed > 0) {
  console.error(`\n✗ ${failed} 个 utility 在真机同等的模块解析条件下起不来，构建中止。`);
  console.error("  多数情况是依赖闭包又缺包了 —— 检查 tools/copy-runtime-deps.mjs。");
  process.exit(1);
}
console.log("   utility 冒烟通过：三个入口在无向上逃逸的条件下均可加载");
