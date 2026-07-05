import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runnerImport } from "vite";

const currentDir = dirname(fileURLToPath(import.meta.url));
const tauriAppRoot = resolve(currentDir, "../..");

export async function withSsrModules(callback) {
  return callback(async (modulePath) => {
    const resolvedPath = modulePath.startsWith("/")
      ? resolve(tauriAppRoot, `.${modulePath}`)
      : modulePath;
    const { module } = await runnerImport(resolvedPath, {
      configFile: false,
      logLevel: "error",
      root: tauriAppRoot,
    });
    return module;
  });
}
