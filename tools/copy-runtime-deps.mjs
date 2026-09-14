/**
 * 把 pi 包依赖闭包里缺的包补进 APK 的 assets/web/node_modules。
 *
 * 为什么需要：APK 里的 node_modules 是一份**手工清单**（见 fetch-runtime.sh 里
 * 逐个 cp 的那段），只覆盖直接依赖。pi-ai / pi-agent-core 自己声明的依赖
 * （partial-json、http-proxy-agent、pi-telemetry、chord…）不在清单里：
 *   - 容器里跑得通 —— node 会沿目录一路向上找到仓库根的 node_modules；
 *   - 手机上没那一层 —— agent utility 一 fork 就 ERR_MODULE_NOT_FOUND，
 *     退出码 1，supervisor 每 0.25 秒重试，前端只看到 utility.not_running。
 *
 * ⚠️ 这里**不能用 `require.resolve()`** 来找包（3.1.0 就是这么翻车的）：
 * pi-telemetry / chord 是 ESM-only 包，`exports` 里没有 `require` 条件，
 * `require.resolve` 会抛 ERR_PACKAGE_PATH_NOT_EXPORTED。脚本把它当成
 * 「这个包不存在」，静默跳过 —— 而 pi-agent-core 在模块加载期就 eager import
 * 它们，于是真机一 fork 就死。找包**只需要目录和 package.json**，
 * 用 Node 自己的 node_modules 逐级上溯规则即可，与 exports 无关。
 *
 * 另外一个教训：只走「两个根的直接依赖」是不够的（3.1.0 只走了一层），
 * 依赖的依赖同样会缺。这里是**全量传递闭包** BFS。
 *
 * 用法：node copy-runtime-deps.mjs <APK_ROOT> <WEB_OUT>
 * 退出码：0 正常；1 有**必需**依赖解析不到（可选依赖只告警）。
 */
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync
} from "node:fs";
import { dirname, join } from "node:path";

const [apkroot, webOut] = process.argv.slice(2);
if (!apkroot || !webOut) {
  console.error("用法：node copy-runtime-deps.mjs <APK_ROOT> <WEB_OUT>");
  process.exit(2);
}

const target = join(apkroot, "assets/web/node_modules");
const roots = ["@earendil-works/pi-ai", "@earendil-works/pi-agent-core"];

/**
 * 按 Node 的 node_modules 上溯规则找包的**目录**，不碰 exports。
 *
 * 这正是 Node 解析器干的事：从 fromDir 起，每级看 <dir>/node_modules/<name>，
 * 找到 package.json 就停。pnpm 把依赖符号链接在 .pnpm/<pkg>@<ver>/node_modules/
 * 下，上溯正好会命中那里。
 */
function findPackageDir(fromDir, name) {
  let dir = fromDir;
  for (;;) {
    const candidate = join(dir, "node_modules", name);
    if (existsSync(join(candidate, "package.json"))) {
      // realpath：pnpm 存储里全是软链，按软链路径去复制会拿到链接本身。
      return realpathSync(candidate);
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function manifestOf(packageDir) {
  return JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8"));
}

/**
 * 该不该把这个包打进 APK。
 *
 * 这里的裁剪**不是**凭感觉挑包（§6.5 那个「手工清单」的教训），
 * 而是两条有依据的规则：
 *   - `@types/*` 是 DefinitelyTyped 的类型声明包，只有 .d.ts，运行期不存在；
 *   - optionalDependencies 按 npm 的契约「装不上也必须能跑」，
 *     而且它们绝大多数是**宿主机平台二进制**（@esbuild/linux-arm64、
 *     @rollup/rollup-darwin-* …），装进 Android 包纯属死重量。
 */
function shouldSkip(name) {
  return name.startsWith("@types/");
}

/** 必需依赖 = dependencies；可选/peer 依赖单独返回（解析不到不算错）。 */
function declaredDeps(packageDir) {
  const manifest = manifestOf(packageDir);
  const clean = (names) => Object.keys(names ?? {}).filter((n) => !n.startsWith("node:") && !shouldSkip(n));
  return {
    required: clean(manifest.dependencies),
    optional: clean(manifest.optionalDependencies),
    // peerDependencies 在 pnpm 里是真装了的（看 .pnpm 目录名的 _zod@4.4.3 后缀就知道了），
    // 漏掉它们同样会在手机上炸。但它按契约也可以由使用方提供，所以缺了只告警。
    peers: clean(manifest.peerDependencies),
    name: manifest.name,
    version: manifest.version
  };
}

const missingRequired = [];
const missingPeers = [];
const copyFailed = [];
const versionConflicts = [];
const seenDirs = new Set();
/** 包名 → 已落地的版本，用来发现「同名不同版本」这种手机才会炸的情况。 */
const landed = new Map();
let copied = 0;
let optionalDepsSeen = 0;

const queue = roots.map((name) => ({ name, fromDir: webOut, requiredBy: "(根)" }));

while (queue.length > 0) {
  const { name, fromDir, requiredBy, tolerateMissing } = queue.shift();
  const packageDir = findPackageDir(fromDir, name);
  if (!packageDir) {
    (tolerateMissing ? missingPeers : missingRequired).push(`${name} ← ${requiredBy}`);
    continue;
  }
  // 同一个实体目录只处理一次（两个根可能依赖同一个包）。
  // 注意 dedupe 用目录而不是包名：pnpm 里同名不同版本是两个不同目录。
  if (seenDirs.has(packageDir)) continue;
  seenDirs.add(packageDir);

  const { required, optional: optionalDeps, peers, version } = declaredDeps(packageDir);

  const destination = join(target, name);
  const previous = landed.get(name);
  if (previous && previous !== version) {
    versionConflicts.push(`${name}: 已有 ${previous}，又来了 ${version}`);
  }
  landed.set(name, version);

  if (!existsSync(destination)) {
    try {
      mkdirSync(dirname(destination), { recursive: true });
      // 用 GNU cp -rL 而不是 cpSync：pnpm 存储里有些包含指向外部的软链，
      // cpSync 会抛 EINVAL，cp 能正常解引用复制。
      execFileSync("cp", ["-rL", packageDir, destination], { stdio: "ignore" });
      copied += 1;
    } catch (error) {
      copyFailed.push(`${name}: ${error.code ?? error.message}`);
    }
  }
  // 落点已存在也要继续往下走：手工清单里已经有的包（typebox / zod）
  // 一样需要把它们的依赖补齐。

  for (const dependency of required) {
    queue.push({ name: dependency, fromDir: packageDir, requiredBy: name });
  }
  for (const dependency of peers) {
    queue.push({ name: dependency, fromDir: packageDir, requiredBy: `${name}(peer)`, tolerateMissing: true });
  }
  // 可选依赖只统计、不进包（见 shouldSkip 上方说明）。
  optionalDepsSeen += optionalDeps.length;
}

console.log(
  `   依赖闭包：遍历 ${seenDirs.size} 个包，补齐 ${copied} 个` +
    `（跳过可选依赖 ${optionalDepsSeen} 项 / @types）`
);

// ---- 运行期用不到的重量：source map 与类型声明 ----
// 这两类文件运行期绝不会被加载（.map 只给调试器定位栈帧，.d.ts 只给 tsc 看），
// 但在依赖闭包里合计能有几十 MB。剔掉它们是**有依据的裁剪**，不是凭感觉挑包。
const PRUNE_SUFFIXES = [".map", ".d.ts", ".d.mts", ".d.cts"];
const PRUNE_SKIP_DIRS = new Set(["node_modules"]);

let prunedFiles = 0;
let prunedBytes = 0;

function pruneDeadWeight(dir) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      // 不动嵌套的 node_modules：那是别人家的依赖树，别越界。
      if (PRUNE_SKIP_DIRS.has(entry.name)) continue;
      pruneDeadWeight(full);
    } else if (entry.isFile() && PRUNE_SUFFIXES.some((suffix) => entry.name.endsWith(suffix))) {
      try {
        prunedBytes += statSync(full).size;
        rmSync(full);
        prunedFiles += 1;
      } catch {
        // 删不掉就算了，不值得让整条打包链失败。
      }
    }
  }
}

pruneDeadWeight(target);
console.log(`   剔除死重量：${prunedFiles} 个文件 / ${(prunedBytes / 1048576).toFixed(1)} MB（source map + 类型声明）`);
if (missingPeers.length > 0) {
  console.log(`   peer 依赖未解析 ${missingPeers.length} 个（多为使用方提供）：${missingPeers.slice(0, 3).join(", ")}`);
}
if (versionConflicts.length > 0) {
  console.log(`   ⚠️ 同名多版本被压平 ${versionConflicts.length} 处：${versionConflicts.slice(0, 3).join(" / ")}`);
}
if (copyFailed.length > 0) {
  console.log(`   ⚠️ 复制失败 ${copyFailed.length} 个：${copyFailed.slice(0, 3).join(" / ")}`);
}
if (missingRequired.length > 0) {
  console.error(`   ✗ 必需依赖解析不到 ${missingRequired.length} 个：`);
  for (const item of missingRequired.slice(0, 12)) console.error(`       ${item}`);
  console.error("   → 真机上这些包会 ERR_MODULE_NOT_FOUND，构建中止。");
  process.exit(1);
}
