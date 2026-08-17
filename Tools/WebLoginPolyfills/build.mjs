import { transformAsync } from "@babel/core";
import presetEnv from "@babel/preset-env";
import * as esbuild from "esbuild";
import { copyFile, mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolDirectory, "../..");
const sourcePath = path.join(toolDirectory, "src/index.js");
const outputDirectory = path.join(
  repositoryRoot,
  "ThirdParty/web-login-polyfills",
);
const outputPath = path.join(outputDirectory, "web-login-polyfills.js");

const packageJSON = JSON.parse(
  await readFile(path.join(toolDirectory, "package.json"), "utf8"),
);
const coreJSVersion = packageJSON.devDependencies["core-js"];
const source = await readFile(sourcePath, "utf8");
const transformed = await transformAsync(source, {
  babelrc: false,
  configFile: false,
  filename: sourcePath,
  presets: [
    [
      presetEnv,
      {
        corejs: { version: coreJSVersion, proposals: false },
        modules: false,
        targets: { ios: "16.0" },
        useBuiltIns: "entry",
      },
    ],
  ],
});

if (!transformed?.code) {
  throw new Error("Babel did not produce a web-login compatibility entry");
}

await mkdir(outputDirectory, { recursive: true });
await esbuild.build({
  bundle: true,
  format: "iife",
  legalComments: "none",
  minify: true,
  outfile: outputPath,
  platform: "browser",
  stdin: {
    contents: transformed.code,
    loader: "js",
    resolveDir: path.dirname(sourcePath),
    sourcefile: sourcePath,
  },
  target: ["safari16"],
  supported: {
    "template-literal": false,
  },
  banner: {
    js: "/* Generated from core-js 3.49.0 for Dexo web login. core-js is MIT licensed. */",
  },
});

await copyFile(
  path.join(toolDirectory, "node_modules/core-js/LICENSE"),
  path.join(outputDirectory, "LICENSE.core-js"),
);
