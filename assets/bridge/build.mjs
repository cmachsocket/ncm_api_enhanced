// /home/cmach_socket/projects/ncm_api_enhanced/assets/bridge/build.mjs
import * as esbuild from 'esbuild';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const shimXhrWorker = {
  name: 'shim-xhr-worker',
  setup(build) {
    // 1) 拦截 jsdom 内部的 require.resolve('./xhr-sync-worker.js')
    //    标记为 external，保持原样输出，消除警告
    build.onResolve({ filter: /^\.\/xhr-sync-worker\.js$/ }, (args) => {
      if (args.kind === 'require-resolve' && args.importer.includes('jsdom')) {
        return { path: args.path, external: true };
      }
      return null;
    });

    // 2) 构建完成后，把 shim 复制到 dist/，
    //    这样运行时 require.resolve('./xhr-sync-worker.js')
    //    相对 bundle.js 就能找到它
    build.onEnd(() => {
      const src = path.resolve(__dirname, 'shims/xhr-sync-worker.js');
      const dest = path.resolve(__dirname, 'dist/xhr-sync-worker.js');
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(src, dest);
      console.log('[shim] copied xhr-sync-worker.js -> dist/');
    });
  },
};

// Patch util/index.js: it does `path.join(__dirname, '../data/...')`,
// which assumes it lives at <api>/util/index.js. After esbuild bundles
// everything into dist/bundle.js, __dirname is dist/, so the relative
// path resolves to dist/../data/... = <bridge>/data/ — wrong.
// The data file is actually shipped at dist/data/china_ip_ranges.txt
// (see pubspec.yaml asset entry), so rewrite to a bundle-relative path.
const fixChinaIpRangesPath = {
  name: 'fix-china-ip-ranges-path',
  setup(build) {
    build.onLoad({ filter: /util[\\/]+index\.js$/ }, async (args) => {
      const src = await fs.promises.readFile(args.path, 'utf8');
      const patched = src.replace(
        "path.join(__dirname, '../data/china_ip_ranges.txt')",
        "path.join(__dirname, 'data/china_ip_ranges.txt')",
      );
      if (patched === src) {
        // Bail out (return undefined) so esbuild falls back to default
        // load + a warning. Better than silently rewriting nothing.
        return;
      }
      console.log('[patch] rewrote china_ip_ranges.txt path in', path.relative(__dirname, args.path));
      return { contents: patched, loader: 'js' };
    });
  },
};

await esbuild.build({
  entryPoints: ['bridge.js'],
  bundle: true,
  platform: 'node',
  target: 'node18',      // 对齐你的 CI/运行时；你之前写 node20，这里改成 node18 也可以
  format: 'cjs',
  outfile: 'dist/bundle.js',
  sourcemap: false,
  minify: false,
  // music-metadata v11+ is pure ESM with `exports` only exposing
  // `import` / `module-sync`. Activating `module-sync` lets esbuild
  // inline it (and its 10 ESM deps, plus the full dep graph) into
  // the bundle — required because dist/ is shipped as a self-contained
  // asset with no node_modules.
  conditions: ['module-sync'],
  plugins: [shimXhrWorker, fixChinaIpRangesPath],
});