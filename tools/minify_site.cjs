/* Build-only JavaScript compression. SPDX-License-Identifier: AGPL-3.0-or-later. */
"use strict";
if (Number(process.versions.node.split(".")[0]) < 18) throw new Error("Install Node.js 18 or later to build the website.");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const LIMIT = 8 * 1024 * 1024;

async function main() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > LIMIT) throw new Error("Browser source input exceeds its byte limit.");
    chunks.push(chunk);
  }
  const sources = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (!sources || typeof sources !== "object" || Array.isArray(sources) || Object.keys(sources).length > 16) {
    throw new Error("Invalid browser source collection.");
  }
  // Select the official browser-global UMD API, without Node module imports.
  // Source maps are disabled, so the optional source-map library is not used.
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(__dirname, "vendor/terser/bundle.min.js"), "utf8"), context, { timeout: 5000 });
  const output = {};
  for (const [name, source] of Object.entries(sources)) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.js$/.test(name) || typeof source !== "string" || Buffer.byteLength(source) > 1024 * 1024) {
      throw new Error("Invalid browser source file.");
    }
    context.input = { [name]: source };
    const result = vm.runInContext("Terser.minify_sync(input, {sourceMap:false, compress:true, mangle:{properties:false}, format:{comments:'some'}, module:false, toplevel:false})", context, { timeout: 10000 });
    output[name] = result.code;
  }
  const encoded = JSON.stringify(output);
  if (Buffer.byteLength(encoded) > LIMIT) throw new Error("Minified browser output exceeds its byte limit.");
  process.stdout.write(encoded);
}

main().catch((error) => {
  process.stdout.write(JSON.stringify({ error: String(error.message || error).slice(0, 1024) }));
});
