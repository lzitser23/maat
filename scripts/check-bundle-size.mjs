// Guards against the entry chunk silently regressing back to shipping Excalidraw (and its
// mermaid/katex/cytoscape deps) eagerly. Reads dist/index.html to find the actual entry script
// (the one the browser downloads and executes before first paint -- lazy chunks are not linked
// there), gzips it the same way a browser transfer would be, and compares against a committed
// budget.
//
// Budget: 150 KB gzip. For context, the entry chunk gzipped size right after splitting Excalidraw
// out via React.lazy (see src/components/Canvas.tsx + src/components/DrawingOverlay.tsx) is
// ~95 KB; before the split it was ~463 KB. 150 KB leaves headroom for normal app growth while still
// catching a regression where Excalidraw (or something similarly heavy) leaks back into the entry
// chunk.
//
// Override the budget for a one-off check (e.g. to demonstrate a failing run) with:
//   BUNDLE_BUDGET_KB=1 node scripts/check-bundle-size.mjs
import { gzipSync } from "node:zlib";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const distDir = path.join(repoRoot, "dist");
const DEFAULT_BUDGET_KB = 150;
const budgetKb = Number(process.env.BUNDLE_BUDGET_KB) || DEFAULT_BUDGET_KB;

async function main() {
  const indexHtml = await readFile(path.join(distDir, "index.html"), "utf8").catch((error) => {
    throw new Error(`Could not read dist/index.html -- run "vite build" first (${error.message})`);
  });

  const scriptMatch = indexHtml.match(/<script[^>]+type="module"[^>]+src="([^"]+)"/);
  if (!scriptMatch) {
    throw new Error("Could not find the entry <script type=\"module\"> tag in dist/index.html");
  }

  const entryRelativePath = scriptMatch[1].replace(/^\//, "");
  const entryPath = path.join(distDir, entryRelativePath);
  const entryBytes = await readFile(entryPath);
  const gzipKb = gzipSync(entryBytes).byteLength / 1024;

  const status = gzipKb <= budgetKb ? "PASS" : "FAIL";
  console.log(
    `[check:bundle] entry chunk ${entryRelativePath}: ${gzipKb.toFixed(2)} KB gzip (budget ${budgetKb} KB) -- ${status}`,
  );

  if (gzipKb > budgetKb) {
    console.error(
      `[check:bundle] entry chunk exceeds the ${budgetKb} KB gzip budget by ${(gzipKb - budgetKb).toFixed(2)} KB. ` +
        "If this is a genuine, reviewed increase, raise DEFAULT_BUDGET_KB in scripts/check-bundle-size.mjs. " +
        "If not, something heavy (e.g. Excalidraw) likely leaked out of its React.lazy boundary back into the entry chunk.",
    );
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(`[check:bundle] ${error.message}`);
  process.exit(1);
});
